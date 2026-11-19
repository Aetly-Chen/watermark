package cn.shuiyin.watermark_remover.media

import android.content.Context
import android.graphics.RectF
import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.os.SystemClock
import android.util.Log
import org.opencv.android.OpenCVLoader
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.MatOfPoint
import org.opencv.core.Point
import org.opencv.core.Rect as CvRect
import org.opencv.core.Scalar
import org.opencv.core.Size
import org.opencv.imgcodecs.Imgcodecs
import org.opencv.imgproc.Imgproc
import java.io.File
import java.nio.ByteBuffer
import kotlin.math.abs

/**
 * 视频去水印转码与逐帧修复引擎。
 *
 * 完整链路：
 * `MediaExtractor`（视频轨 + 容错音轨）→ `CodecHelper.openDecoder`（多硬解/软解兜底）
 * → YUV_420_888 ↔ BGR（仅对修复 ROI 做色彩转换，框外原始 YUV 直通）
 * → `MiganInpainter`（端侧 AI 无痕修复 + 参考环缓存与时序防闪烁，异常降级 OpenCV TELEA）
 * → `CodecHelper.openEncoder`（支持退回候选与软编）→ `MediaMuxer`（单调 PTS 保护封装）
 */
object VideoProcessor {
    private const val TAG = "WmVideoProcessor"

    /** 解码与编码轮询超时（10ms）。 */
    private const val DEQUEUE_TIMEOUT_US = 10_000L

    /** 编码器输入等待与解码空闲保护上限（毫秒 / 连续空转次数）。 */
    private const val ENCODER_INPUT_WAIT_MS = 10_000L
    private const val MAX_IDLE_LOOPS = 1200

    private const val MIME_AUDIO = "audio/"

    /** 音轨搬运缓冲范围（256KB ~ 2MB）。 */
    private const val AUDIO_BUFFER_BYTES = 256 * 1024
    private const val AUDIO_BUFFER_MAX_BYTES = 2 * 1024 * 1024

    /** 每处理这么多帧报一次进度，避免频繁刷主线程。 */
    private const val PROGRESS_EVERY = 5

    /** 视频掩膜外扩与边界羽化参数。 */
    private const val VIDEO_GROW_PX = 6
    private const val VIDEO_BRUSH_GROW_PX = 2
    private const val VIDEO_AI_RECT_GROW_PX = 5
    private const val VIDEO_AI_BRUSH_GROW_PX = 3
    private const val VIDEO_FEATHER_PX = 3

    /** 掩膜占比警戒阈值（用于 UI 提示）。 */
    private const val BIG_MASK_RATIO = 0.12

    /** AI 视频帧参考环缓存与时序融合阈值。 */
    private const val RING_INNER_PAD_PX = 4
    private const val RING_OUTER_PAD_PX = 18
    private const val AI_REUSE_STATIC_MAE = 2.2
    private const val AI_REUSE_DYNAMIC_MAE = 4.5
    private const val AI_MAX_SKIP_GAP = 2
    private const val AI_EMA_SCENE_CUT_MAE = 10.0

    const val PHASE_MOTION = "motion"
    const val PHASE_REPAIR = "repair"

    private val SPOT_POINTS = arrayOf(
        0.17 to 0.23,
        0.50 to 0.50,
        0.83 to 0.77,
        0.31 to 0.62,
        0.71 to 0.41,
    )

    /** 调用方主动取消。 */
    class VideoCancelledException : RuntimeException("任务已取消")

    /** 环境或素材不支持（缺 codec、编码器不兼容等）。 */
    class VideoUnsupportedException(message: String) : IllegalArgumentException(message)

    /**
     * 执行视频去水印处理，返回输出文件信息与统计指标。
     *
     * @param mask 归一化选区（0..1，显示坐标系）
     * @param context Android 上下文（传入后默认启用 MI-GAN 端侧 AI 修复，失败自动降级 OpenCV）
     * @param method 修复模式（`"auto"` / `"migan"` / `"telea"`）
     */
    fun repair(
        inputPath: String,
        outputPath: String,
        mask: RectF,
        radius: Int,
        trackMotion: Boolean = false,
        maskPath: String? = null,
        onProgress: ((String, Int, Int) -> Unit)? = null,
        isCancelled: (() -> Boolean)? = null,
        context: Context? = null,
        method: String = "auto",
    ): Map<String, Any> {
        val started = SystemClock.elapsedRealtime()

        if (!OpenCVLoader.initLocal()) {
            throw IllegalStateException("OpenCV 初始化失败")
        }
        if (!File(inputPath).exists()) {
            throw VideoUnsupportedException("视频不存在：$inputPath")
        }
        File(outputPath).parentFile?.mkdirs()

        val extractor = MediaExtractor()
        val muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var audioExtractor: MediaExtractor? = null
        var muxerClosed = false
        var succeeded = false
        try {
            extractor.setDataSource(inputPath)

            val videoTrack = findVideoTrack(extractor)
                ?: throw VideoUnsupportedException("这个文件里没有视频轨")
            val format = extractor.getTrackFormat(videoTrack)
            extractor.selectTrack(videoTrack)

            val rotation = readInt(format, MediaFormat.KEY_ROTATION, 0)
            val sourceFps = readInt(format, MediaFormat.KEY_FRAME_RATE, 30).coerceIn(1, 120)
            val sourceBitrate = readInt(format, MediaFormat.KEY_BIT_RATE, 0)
            val sourceWidth = readInt(format, MediaFormat.KEY_WIDTH, 0)
            val sourceHeight = readInt(format, MediaFormat.KEY_HEIGHT, 0)

            // 音轨容错挂载：不兼容音轨（Opus/AC3/PCM 等）自动跳过，避免炸毁整条视频链路
            val audioInit = openAudioTrack(inputPath, muxer)
            audioExtractor = audioInit.setup?.extractor
            val audioTrackIndex = audioInit.setup?.trackIndex
            val audioMaxInputSize = audioInit.setup?.maxInputSize ?: AUDIO_BUFFER_BYTES

            val durationUs = readLong(format, MediaFormat.KEY_DURATION, 0L)
            val estimatedFrames = if (durationUs > 0) {
                (durationUs / 1_000_000.0 * sourceFps).toInt().coerceAtLeast(1)
            } else {
                0
            }

            val transcode = Transcode(
                extractor = extractor,
                decoderFormat = format,
                rotation = rotation,
                normalizedMask = mask,
                radius = radius,
                muxer = muxer,
                frameRate = sourceFps,
                sourceBitrate = sourceBitrate,
                sourceWidth = sourceWidth,
                sourceHeight = sourceHeight,
                estimatedFrames = estimatedFrames,
                trackMotion = trackMotion,
                maskPath = maskPath,
                onProgress = onProgress,
                isCancelled = isCancelled,
                context = context,
                method = method,
            )
            val videoStats = transcode.run()

            val audioBytes = if (audioTrackIndex != null && audioExtractor != null) {
                copyAudio(
                    audioExtractor,
                    audioTrackIndex,
                    muxer,
                    transcode.isMuxerStarted(),
                    audioMaxInputSize,
                )
            } else {
                0L
            }

            muxer.stop()
            muxer.release()
            muxerClosed = true

            val elapsed = SystemClock.elapsedRealtime() - started
            val outFile = File(outputPath)
            val engineName = if (transcode.aiFrames > 0 || (transcode.reusedFrames > 0 && !transcode.aiBroken)) {
                "migan"
            } else {
                "telea"
            }
            val result = mapOf(
                "outputPath" to outFile.absolutePath,
                "width" to transcode.frameWidth,
                "height" to transcode.frameHeight,
                "rotation" to rotation,
                "frames" to videoStats.frames,
                "skippedFrames" to videoStats.skipped,
                "videoBytes" to videoStats.bytes,
                "audioBytes" to audioBytes,
                "hasAudio" to (audioTrackIndex != null),
                "audioSkipped" to audioInit.audioSkipped,
                "maskPixels" to transcode.maskPixels,
                "maskRatio" to if (transcode.frameWidth * transcode.frameHeight > 0) {
                    transcode.maskPixels.toDouble() /
                        (transcode.frameWidth.toDouble() * transcode.frameHeight)
                } else {
                    0.0
                },
                "motionTracked" to transcode.motionOk,
                "motionFailed" to transcode.motionFailed,
                "motionShiftPx" to transcode.cumulativeShiftPx,
                "motionShiftX" to transcode.cumulativeShiftX,
                "motionShiftY" to transcode.cumulativeShiftY,
                "motionScale" to transcode.cumulativeScale,
                "motionRotationDeg" to transcode.cumulativeRotationDeg,
                "directShiftPx" to transcode.directShiftPx,
                "directScale" to transcode.directScale,
                "driftPx" to transcode.driftPx,
                "keyframeSwitches" to transcode.keyframeSwitches,
                "motionInliers" to transcode.lastInliers,
                "engine" to engineName,
                "aiFrames" to transcode.aiFrames,
                "reusedFrames" to transcode.reusedFrames,
                "sizeBytes" to outFile.length(),
                "elapsedMs" to elapsed,
            )
            succeeded = true
            Log.i(
                TAG,
                "repair ok engine=$engineName ${transcode.frameWidth}x${transcode.frameHeight} rot=$rotation " +
                    "frames=${videoStats.frames} skipped=${videoStats.skipped} " +
                    "ai=${transcode.aiFrames} reuse=${transcode.reusedFrames} " +
                    "video=${videoStats.bytes}B audio=${audioBytes}B audioSkipped=${audioInit.audioSkipped} " +
                    "file=${outFile.length()}B ${elapsed}ms",
            )
            return result
        } finally {
            audioExtractor?.release()
            extractor.release()
            if (!muxerClosed) {
                try {
                    muxer.stop()
                } catch (_: Throwable) {
                }
                try {
                    muxer.release()
                } catch (_: Throwable) {
                }
            }
            if (!succeeded) {
                try {
                    val f = File(outputPath)
                    if (f.exists()) f.delete()
                } catch (_: Throwable) {
                }
            }
        }
    }

    private data class VideoStats(val frames: Int, val skipped: Int, val bytes: Long)

    private class Transcode(
        private val extractor: MediaExtractor,
        private val decoderFormat: MediaFormat,
        private val rotation: Int,
        private val normalizedMask: RectF,
        private val radius: Int,
        private val muxer: MediaMuxer,
        private val frameRate: Int,
        private val sourceBitrate: Int,
        private val sourceWidth: Int,
        private val sourceHeight: Int,
        private val estimatedFrames: Int,
        private val trackMotion: Boolean,
        private val maskPath: String?,
        private val onProgress: ((String, Int, Int) -> Unit)?,
        private val isCancelled: (() -> Boolean)?,
        private val context: Context?,
        private val method: String,
    ) {
        private var encoder: MediaCodec? = null
        private val failedEncoders = HashSet<String>()
        private var encoderStride = 0
        private var encoderSliceHeight = 0
        private var encoderDone = false
        private var videoTrackIndex = -1
        private var muxerStarted = false
        private var lastVideoPtsUs = -1L

        var frameWidth = 0
            private set
        var frameHeight = 0
            private set
        var maskPixels = 0
            private set

        private var visibleWidth = 0
        private var visibleHeight = 0

        private lateinit var maskMat: Mat
        private var maskBase: Mat? = null
        private lateinit var frameBgr: Mat
        private lateinit var scratch: ByteArray

        // ---- 镜头运动追踪 ----
        private var maskQuad: Array<Point> = emptyArray()
        private var cumulative = doubleArrayOf(1.0, 0.0, 0.0, 0.0, 1.0, 0.0)
        private var grayMat: Mat? = null
        private var keyGray: Mat? = null
        private var keyCumulative = doubleArrayOf(1.0, 0.0, 0.0, 0.0, 1.0, 0.0)
        private var framesSinceKey = 0
        private var firstGray: Mat? = null
        private var lastGray: Mat? = null
        var motionOk = 0
        var motionFailed = 0
        var keyframeSwitches = 0
        var lastInliers = 0

        private val MAX_KEY_SPAN = 60
        private val MAX_KEY_SHIFT = 45.0
        private val MIN_INLIERS_HEALTHY = 60

        var directShiftPx = 0.0
        var directScale = 1.0
        var directOk = false
        var driftPx = 0.0

        // ---- YUV 快路径与框外原始 YUV 直通 ----
        private var packed = ByteArray(0)
        private var origYuv = ByteArray(0)
        /** 标志本帧是否已由快路径完整填充 `origYuv`，避免慢路径解码时拷出全零绿屏。 */
        private var origYuvValid = false
        private var packedMat: Mat? = null
        private var i420Mat: Mat? = null
        private var uvMat: Mat? = null
        private var uvBytes = ByteArray(0)
        private var roiI420Mat: Mat? = null
        private var roiI420Bytes = ByteArray(0)
        private var decoderUFirst = true
        private var encoderUFirst = true
        private var decoderUvProbed = false
        private var decoderUvVerified = false
        private var encoderUvProbed = false
        private var fastPathBroken = false

        // ---- AI 去水印缓存与时序防闪烁 ----
        private val useAi = context != null && method != "telea" && MiganInpainter.isAvailable(context)
        var aiBroken = false
            private set
        var aiFrames = 0
            private set
        var reusedFrames = 0
            private set
        private var lastAiOrigRoi: Mat? = null
        private var lastAiRepairedRoi: Mat? = null
        private var lastAiRoiRect: CvRect? = null
        private var lastAiRingMean: Scalar? = null
        private var lastAiShiftX = 0.0
        private var lastAiShiftY = 0.0
        private var lastAiScale = 1.0
        private var framesSinceAi = 0
        private var staticAiWorkMask: Mat? = null
        private var staticAiRingMask: Mat? = null
        private var staticAiRoiRect: CvRect? = null

        private var decoded = 0
        private var skipped = 0
        private var videoBytes = 0L
        private var loggedGeometry = false
        private var loggedEncoderGeometry = false

        private var motionTable: List<DoubleArray>? = null
        private var trackedFrames = 0
        private var progressTotal = 0

        private var tDecode = 0L
        private var tTrack = 0L
        private var tInpaint = 0L
        private var tEncode = 0L

        private fun logGeometry(tag: String, image: Image, w: Int, h: Int) {
            val planes = image.planes.joinToString(" | ") { plane ->
                "row=${plane.rowStride} pix=${plane.pixelStride} " +
                    "cap=${plane.buffer.capacity()} lim=${plane.buffer.limit()}"
            }
            Log.i(
                TAG,
                "$tag image=${image.width}x${image.height} frame=${w}x$h " +
                    "format=${image.format} :: $planes",
            )
        }

        fun isMuxerStarted() = muxerStarted

        val cumulativeShiftPx: Double
            get() = Math.sqrt(cumulative[2] * cumulative[2] + cumulative[5] * cumulative[5])

        val cumulativeShiftX: Double get() = cumulative[2]
        val cumulativeShiftY: Double get() = cumulative[5]

        val cumulativeScale: Double
            get() = Math.sqrt(cumulative[0] * cumulative[0] + cumulative[1] * cumulative[1])

        val cumulativeRotationDeg: Double
            get() = Math.toDegrees(Math.atan2(cumulative[3], cumulative[0]))

        private fun ensurePacked(w: Int, h: Int) {
            val need = w * h * 3 / 2
            val current = packedMat
            if (packed.size == need && current != null &&
                current.cols() == w && current.rows() == h * 3 / 2
            ) {
                return
            }
            packed = ByteArray(need)
            origYuv = ByteArray(need)
            origYuvValid = false
            uvBytes = ByteArray(w * h / 2)
            packedMat?.release()
            packedMat = Mat(h * 3 / 2, w, CvType.CV_8UC1)
            i420Mat?.release()
            i420Mat = Mat(h * 3 / 2, w, CvType.CV_8UC1)
            uvMat?.release()
            uvMat = Mat(h / 2, w / 2, CvType.CV_8UC2)
            Log.i(TAG, "yuv buffers ${w}x$h → packed ${need}B")
        }

        fun run(): VideoStats {
            if (trackMotion) {
                analyzeMotionPass()
                extractor.seekTo(0, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                decoderUvProbed = false
                decoderUvVerified = false
                fastPathBroken = false
                origYuvValid = false
            }
            progressTotal = if (trackedFrames > 0) trackedFrames else estimatedFrames
            return repairPass()
        }

        private fun analyzeMotionPass() {
            val mime = decoderFormat.getString(MediaFormat.KEY_MIME)
                ?: throw VideoUnsupportedException("视频轨没有 MIME")
            val decoder = CodecHelper.openDecoder(decoderFormat)

            val decInfo = MediaCodec.BufferInfo()
            var inputDone = false
            var done = false
            var idleLoops = 0
            val table = ArrayList<DoubleArray>()
            val mark0 = SystemClock.elapsedRealtime()

            try {
                while (!done) {
                    if (isCancelled?.invoke() == true) throw VideoCancelledException()
                    var progressed = false

                    if (!inputDone) {
                        val inIndex = decoder.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
                        if (inIndex >= 0) {
                            progressed = true
                            val buffer = decoder.getInputBuffer(inIndex)
                            val size = if (buffer == null) -1 else extractor.readSampleData(buffer, 0)
                            if (buffer == null || size < 0) {
                                decoder.queueInputBuffer(
                                    inIndex, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                                )
                                inputDone = true
                            } else {
                                decoder.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                                extractor.advance()
                            }
                        }
                    }

                    val decIndex = decoder.dequeueOutputBuffer(decInfo, DEQUEUE_TIMEOUT_US)
                    if (decIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        updateVisibleSize(decoder.outputFormat, "analyze")
                        progressed = true
                    } else if (decIndex >= 0) {
                        progressed = true
                        val eos = decInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                        if (decInfo.size != 0) {
                            val image = try {
                                decoder.getOutputImage(decIndex)
                            } catch (e: IllegalStateException) {
                                Log.w(TAG, "analyze getOutputImage 失败：${e.message}")
                                null
                            }
                            if (image != null) {
                                try {
                                    analyzeFrame(image)
                                } finally {
                                    image.close()
                                }
                                table.add(cumulative.copyOf())
                                if (table.size % PROGRESS_EVERY == 0) {
                                    onProgress?.invoke(PHASE_MOTION, table.size, estimatedFrames)
                                }
                            }
                        }
                        decoder.releaseOutputBuffer(decIndex, false)
                        if (eos) done = true
                    }

                    idleLoops = if (progressed) 0 else idleLoops + 1
                    if (inputDone && idleLoops > MAX_IDLE_LOOPS) {
                        throw VideoUnsupportedException("分析镜头运动时解码器无响应")
                    }
                }
            } finally {
                try {
                    decoder.stop()
                } catch (_: Throwable) {
                }
                decoder.release()
            }

            if (table.isEmpty()) {
                throw VideoUnsupportedException("一帧都没解出来（解码器 $mime 可能不支持这个编码）")
            }

            motionTable = table
            trackedFrames = table.size
            computeDirectMotion()
            onProgress?.invoke(PHASE_MOTION, table.size, table.size)
            Log.i(
                TAG,
                "motion pass done frames=${table.size} keyframes=$keyframeSwitches " +
                    "ok=$motionOk fail=$motionFailed cost=${SystemClock.elapsedRealtime() - mark0}ms",
            )
        }

        private fun analyzeFrame(image: Image) {
            val size = resolveFrameSize(image)
            ensureFrameBuffers(size.first, size.second)
            yuvToBgr(image, frameBgr, scratch, frameWidth, frameHeight)
            updateMaskByMotion(applyToMask = false)
        }

        private fun repairPass(): VideoStats {
            val mime = decoderFormat.getString(MediaFormat.KEY_MIME)
                ?: throw VideoUnsupportedException("视频轨没有 MIME")
            val decoder = CodecHelper.openDecoder(decoderFormat)

            val decInfo = MediaCodec.BufferInfo()
            val encInfo = MediaCodec.BufferInfo()
            var decoderInputDone = false
            var decoderDone = false
            encoderDone = false
            var idleLoops = 0

            try {
                while (!decoderDone || !encoderDone) {
                    if (isCancelled?.invoke() == true) throw VideoCancelledException()
                    var progressed = false

                    // 1) 喂解码器
                    if (!decoderInputDone) {
                        val inIndex = decoder.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
                        if (inIndex >= 0) {
                            progressed = true
                            val buffer = decoder.getInputBuffer(inIndex)
                            val size = if (buffer == null) -1 else extractor.readSampleData(buffer, 0)
                            if (buffer == null || size < 0) {
                                decoder.queueInputBuffer(
                                    inIndex, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                                )
                                decoderInputDone = true
                            } else {
                                decoder.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                                extractor.advance()
                            }
                        }
                    }

                    // 2) 取解码帧 → 修复 → 喂编码器
                    if (!decoderDone) {
                        val decIndex = decoder.dequeueOutputBuffer(decInfo, DEQUEUE_TIMEOUT_US)
                        if (decIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                            updateVisibleSize(decoder.outputFormat, "repair")
                            progressed = true
                        } else if (decIndex >= 0) {
                            progressed = true
                            val eos = decInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                            if (decInfo.size != 0) {
                                val image = try {
                                    decoder.getOutputImage(decIndex)
                                } catch (e: IllegalStateException) {
                                    Log.w(TAG, "getOutputImage 失败：${e.message}")
                                    null
                                }
                                if (image != null) {
                                    try {
                                        encodeFrame(image, decInfo.presentationTimeUs, encInfo)
                                    } finally {
                                        image.close()
                                    }
                                } else {
                                    skipped++
                                }
                            }
                            decoder.releaseOutputBuffer(decIndex, false)
                            if (eos) {
                                decoderDone = true
                                signalEncoderEos(encInfo)
                            }
                        }
                    }

                    // 3) 收编码结果 → 写 muxer
                    if (!encoderDone) {
                        if (encoder == null && decoderDone) {
                            encoderDone = true
                        } else if (drainEncoder(encInfo)) {
                            encoderDone = true
                            progressed = true
                        }
                    }

                    idleLoops = if (progressed) 0 else idleLoops + 1
                    if (decoderInputDone && idleLoops > MAX_IDLE_LOOPS) {
                        throw VideoUnsupportedException("视频转码超时：编解码器长时间无输出响应")
                    }
                }
            } finally {
                try {
                    decoder.stop()
                } catch (_: Throwable) {
                }
                decoder.release()
                encoder?.let {
                    try {
                        it.stop()
                    } catch (_: Throwable) {
                    }
                    it.release()
                }
                encoder = null
                if (this::maskMat.isInitialized) maskMat.release()
                maskBase?.release()
                maskBase = null
                if (this::frameBgr.isInitialized) frameBgr.release()
                packedMat?.release()
                packedMat = null
                i420Mat?.release()
                i420Mat = null
                uvMat?.release()
                uvMat = null
                roiI420Mat?.release()
                roiI420Mat = null
                grayMat?.release()
                grayMat = null
                keyGray?.release()
                keyGray = null
                lastGray?.release()
                lastGray = null
                firstGray?.release()
                firstGray = null
                releaseAiBuffers()
            }

            if (decoded == 0) {
                throw VideoUnsupportedException("一帧都没解出来（解码器 $mime 可能不支持这个编码）")
            }
            if (!muxerStarted) {
                throw VideoUnsupportedException("编码器没有产出视频轨，无法封装")
            }
            return VideoStats(frames = decoded, skipped = skipped, bytes = videoBytes)
        }

        private fun releaseAiBuffers() {
            lastAiOrigRoi?.release()
            lastAiOrigRoi = null
            lastAiRepairedRoi?.release()
            lastAiRepairedRoi = null
            staticAiWorkMask?.release()
            staticAiWorkMask = null
            staticAiRingMask?.release()
            staticAiRingMask = null
        }

        private fun updateVisibleSize(out: MediaFormat, stage: String) {
            val cw = if (out.containsKey("crop-right") && out.containsKey("crop-left")) {
                out.getInteger("crop-right") - out.getInteger("crop-left") + 1
            } else {
                readInt(out, MediaFormat.KEY_WIDTH, 0)
            }
            val ch = if (out.containsKey("crop-bottom") && out.containsKey("crop-top")) {
                out.getInteger("crop-bottom") - out.getInteger("crop-top") + 1
            } else {
                readInt(out, MediaFormat.KEY_HEIGHT, 0)
            }
            visibleWidth = cw
            visibleHeight = ch
            Log.i(TAG, "$stage decoder output ${visibleWidth}x$visibleHeight")
        }

        private fun ensureEncoder(rawW: Int, rawH: Int) {
            if (encoder != null) return
            if (rawW < 2 || rawH < 2) {
                throw VideoUnsupportedException("视频分辨率过小（${rawW}x$rawH）")
            }

            val bitrate = if (sourceBitrate > 0) {
                (sourceBitrate * 1.25)
                    .toLong()
                    .coerceIn(sourceBitrate.toLong(), 50_000_000L)
                    .toInt()
            } else {
                (rawW * rawH * frameRate * 0.18).toInt().coerceIn(2_000_000, 35_000_000)
            }

            val codec = CodecHelper.openEncoder(
                width = rawW,
                height = rawH,
                bitrate = bitrate,
                fps = frameRate,
                sourceFormat = decoderFormat,
                excludedNames = failedEncoders,
            )
            encoder = codec
            val inFmt = try {
                codec.inputFormat
            } catch (_: Throwable) {
                null
            }
            encoderStride = inFmt?.let { readInt(it, MediaFormat.KEY_STRIDE, rawW) } ?: rawW
            encoderSliceHeight = inFmt?.let { readInt(it, MediaFormat.KEY_SLICE_HEIGHT, rawH) } ?: rawH

            if (!this::maskMat.isInitialized) {
                maskMat = buildMask(rawW, rawH)
                maskPixels = countMaskPixels(maskMat)
                initStaticAiMasksIfNeeded(rawW, rawH)
            }
            ensureFrameBuffers(rawW, rawH)
            val ratio = maskPixels.toDouble() / (rawW.toDouble() * rawH)
            Log.i(
                TAG,
                "encoder ready ${codec.name} ${rawW}x$rawH stride=$encoderStride slice=$encoderSliceHeight " +
                    "bitrate=$bitrate fps=$frameRate mask=$maskPixels px (${"%.1f".format(ratio * 100)}%) ai=$useAi",
            )
            if (ratio > BIG_MASK_RATIO) {
                Log.w(
                    TAG,
                    "选区占画面 ${"%.1f".format(ratio * 100)}%，超过 ${"%.0f".format(BIG_MASK_RATIO * 100)}%",
                )
            }
        }

        /** 阻塞等待编码器空闲输入缓冲，等待期间持续排空输出队列防止硬编死锁。 */
        private fun dequeueEncoderInputWithDrain(
            codec: MediaCodec,
            encInfo: MediaCodec.BufferInfo,
        ): Int {
            val startedAt = SystemClock.elapsedRealtime()
            while (true) {
                if (isCancelled?.invoke() == true) throw VideoCancelledException()
                val idx = codec.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
                if (idx >= 0) return idx
                if (!encoderDone && drainEncoder(encInfo)) {
                    encoderDone = true
                }
                if (SystemClock.elapsedRealtime() - startedAt > ENCODER_INPUT_WAIT_MS) {
                    throw IllegalStateException("编码器 10s 内未提供空闲输入缓冲")
                }
            }
        }

        /**
         * 画幅优先级：容器里的源尺寸 > 解码器 outputFormat > Image 尺寸。
         * YUV420 要求宽高为偶数，遇到奇数视频自动向下取偶防止编码器崩掉。
         */
        private fun resolveFrameSize(image: Image): Pair<Int, Int> {
            val vw = when {
                sourceWidth in 2..image.width -> sourceWidth
                visibleWidth in 2..image.width -> visibleWidth
                else -> image.width
            }
            val vh = when {
                sourceHeight in 2..image.height -> sourceHeight
                visibleHeight in 2..image.height -> visibleHeight
                else -> image.height
            }
            val evenW = (vw and 1.inv()).coerceAtLeast(2)
            val evenH = (vh and 1.inv()).coerceAtLeast(2)
            return evenW to evenH
        }

        private fun ensureFrameBuffers(w: Int, h: Int) {
            if (frameWidth == w && frameHeight == h && this::frameBgr.isInitialized) return
            frameWidth = w
            frameHeight = h
            if (this::frameBgr.isInitialized) frameBgr.release()
            frameBgr = Mat(h, w, CvType.CV_8UC3)
            scratch = ByteArray(w * h * 3)
            ensurePacked(w, h)
        }

        private fun encodeFrame(image: Image, ptsUs: Long, encInfo: MediaCodec.BufferInfo) {
            val size = resolveFrameSize(image)
            ensureEncoder(size.first, size.second)
            if (!loggedGeometry) {
                loggedGeometry = true
                logGeometry("decoder", image, frameWidth, frameHeight)
            }

            // 首帧 getInputImage 失败时无缝排除当前编码器并切换下一候选（直到软编）
            var codec: MediaCodec
            var inIndex: Int
            var inImage: Image
            while (true) {
                codec = encoder ?: error("编码器未初始化")
                inIndex = dequeueEncoderInputWithDrain(codec, encInfo)
                val obtained = try {
                    codec.getInputImage(inIndex)
                } catch (e: Throwable) {
                    Log.w(TAG, "编码器 ${codec.name} getInputImage 抛异常：${e.message}")
                    null
                }
                if (obtained != null) {
                    inImage = obtained
                    break
                }
                if (decoded == 0 && !muxerStarted && failedEncoders.size < 6) {
                    val badName = codec.name
                    Log.w(TAG, "编码器 $badName 不支持 getInputImage，切换下一编码器")
                    failedEncoders.add(badName)
                    try {
                        codec.stop()
                    } catch (_: Throwable) {
                    }
                    codec.release()
                    encoder = null
                    loggedEncoderGeometry = false
                    encoderUvProbed = false
                    ensureEncoder(size.first, size.second)
                    continue
                }
                throw VideoUnsupportedException("编码器 ${codec.name} 不支持 getInputImage")
            }

            if (!loggedEncoderGeometry) {
                loggedEncoderGeometry = true
                logGeometry("encoder", inImage, frameWidth, frameHeight)
            }

            var mark = SystemClock.elapsedRealtime()
            yuvToBgr(image, frameBgr, scratch, frameWidth, frameHeight)
            tDecode += SystemClock.elapsedRealtime() - mark
            mark = SystemClock.elapsedRealtime()

            if (trackMotion) {
                applyTrackedMotion()
                tTrack += SystemClock.elapsedRealtime() - mark
                mark = SystemClock.elapsedRealtime()
            }

            val repairOutcome = repairCurrentFrame()
            val repaired = repairOutcome.repairedBgr
            val evenRoi = alignEvenRoi(repairOutcome.changedRoi, frameWidth, frameHeight)
            tInpaint += SystemClock.elapsedRealtime() - mark
            mark = SystemClock.elapsedRealtime()

            try {
                bgrToYuv(
                    repaired,
                    inImage,
                    scratch,
                    frameWidth,
                    frameHeight,
                    evenRoi = evenRoi,
                    origImage = image,
                )
            } finally {
                repaired.release()
                try {
                    inImage.close()
                } catch (_: Throwable) {
                }
            }

            val minFrameBytes = frameWidth * frameHeight * 3 / 2
            val paddedNeed = maxOf(encoderStride, frameWidth) *
                maxOf(encoderSliceHeight, frameHeight) * 3 / 2
            val rawCap = try {
                codec.getInputBuffer(inIndex)?.remaining() ?: minFrameBytes
            } catch (_: Throwable) {
                minFrameBytes
            }
            val submitBytes = if (rawCap >= minFrameBytes) {
                minOf(rawCap, maxOf(minFrameBytes, paddedNeed))
            } else {
                minFrameBytes
            }

            val safePtsUs = maxOf(0L, ptsUs).let { p ->
                if (lastVideoPtsUs >= 0 && p <= lastVideoPtsUs) lastVideoPtsUs + 1L else p
            }
            lastVideoPtsUs = safePtsUs

            codec.queueInputBuffer(inIndex, 0, submitBytes, safePtsUs, 0)
            tEncode += SystemClock.elapsedRealtime() - mark

            decoded++
            if (decoded % 30 == 0) {
                val tx = Math.round(cumulative[2] * 100) / 100.0
                val ty = Math.round(cumulative[5] * 100) / 100.0
                Log.i(
                    TAG,
                    "perf ${decoded}f decode=${tDecode}ms track=${tTrack}ms " +
                        "inpaint=${tInpaint}ms encode=${tEncode}ms ai=$aiFrames reuse=$reusedFrames " +
                        "cum=[$tx, $ty] motion=${motionOk}ok/${motionFailed}fail " +
                        "keyframes=$keyframeSwitches inliers=$lastInliers",
                )
            }
            if (decoded % PROGRESS_EVERY == 0) {
                onProgress?.invoke(PHASE_REPAIR, decoded, progressTotal)
            }
        }

        private data class FrameRepairOutcome(val repairedBgr: Mat, val changedRoi: CvRect?)

        /** 预计算静态水印（未开跟随）的膨胀掩膜、外围参考环掩膜与局部 ROI，避免逐帧重算形态学。 */
        private fun initStaticAiMasksIfNeeded(w: Int, h: Int) {
            if (!useAi || trackMotion) return
            val growPx = if (maskBase != null) VIDEO_AI_BRUSH_GROW_PX else VIDEO_AI_RECT_GROW_PX
            val work = dilateBinaryMask(maskMat, growPx)
            val ring = buildReferenceRingMask(work)
            val roi = ImageProcessor.computeRoiWithMargin(
                maskMat,
                w,
                h,
                marginPx = growPx + RING_OUTER_PAD_PX + 2,
            )
            staticAiWorkMask = work
            staticAiRingMask = ring
            staticAiRoiRect = roi
        }

        /** 对当前帧执行 AI 去水印（含参考环缓存复用与轻度时序平滑），或降级使用 TELEA。 */
        private fun repairCurrentFrame(): FrameRepairOutcome {
            val isBrush = maskBase != null
            if (useAi && !aiBroken && context != null) {
                val growPx = if (isBrush) VIDEO_AI_BRUSH_GROW_PX else VIDEO_AI_RECT_GROW_PX
                try {
                    val outcome = repairFrameWithAi(context, growPx)
                    if (outcome != null) return outcome
                } catch (oom: OutOfMemoryError) {
                    throw oom
                } catch (e: Throwable) {
                    Log.e(TAG, "视频 MI-GAN 推理异常，后续帧降级 OpenCV TELEA: ${e.message}", e)
                    aiBroken = true
                }
            }
            val teleaGrow = if (isBrush) VIDEO_BRUSH_GROW_PX else VIDEO_GROW_PX
            val rawRoi = ImageProcessor.computeInpaintRoi(
                maskMat,
                frameWidth,
                frameHeight,
                radius,
                growPx = teleaGrow,
                featherPx = VIDEO_FEATHER_PX,
            )
            val repaired = ImageProcessor.inpaintBgr(
                frameBgr,
                maskMat,
                radius,
                growPx = teleaGrow,
                featherPx = VIDEO_FEATHER_PX,
            )
            return FrameRepairOutcome(repaired, rawRoi)
        }

        private fun repairFrameWithAi(ctx: Context, growPx: Int): FrameRepairOutcome? {
            val useStaticCache = !trackMotion && staticAiWorkMask != null && staticAiRingMask != null
            val workMask = if (useStaticCache) {
                staticAiWorkMask!!
            } else {
                dilateBinaryMask(maskMat, growPx)
            }
            val ringMask = if (useStaticCache) {
                staticAiRingMask!!
            } else {
                buildReferenceRingMask(workMask)
            }
            val roi = if (useStaticCache) {
                staticAiRoiRect
            } else {
                ImageProcessor.computeRoiWithMargin(
                    maskMat,
                    frameWidth,
                    frameHeight,
                    marginPx = growPx + RING_OUTER_PAD_PX + 2,
                )
            }

            try {
                if (roi == null || roi.width < 2 || roi.height < 2) {
                    return FrameRepairOutcome(frameBgr.clone(), null)
                }

                val curOrigSub = frameBgr.submat(roi)
                val workSub = workMask.submat(roi)
                val ringSub = ringMask.submat(roi)
                try {
                    val curRingMean = if (Core.countNonZero(ringSub) > 0) {
                        Core.mean(curOrigSub, ringSub)
                    } else {
                        null
                    }
                    val sameWindow = lastAiRoiRect == roi &&
                        lastAiOrigRoi != null &&
                        lastAiRepairedRoi != null &&
                        abs(cumulative[2] - lastAiShiftX) < 0.8 &&
                        abs(cumulative[5] - lastAiShiftY) < 0.8 &&
                        abs(cumulativeScale - lastAiScale) < 0.005

                    var ringMae = Double.POSITIVE_INFINITY
                    if (sameWindow && curRingMean != null) {
                        ringMae = computeMaskedMae(curOrigSub, lastAiOrigRoi!!, ringSub)
                        val canReuseStatic = !trackMotion && ringMae < AI_REUSE_STATIC_MAE
                        val canReuseDynamic = trackMotion &&
                            ringMae < AI_REUSE_DYNAMIC_MAE &&
                            framesSinceAi < AI_MAX_SKIP_GAP
                        if (canReuseStatic || canReuseDynamic) {
                            val out = frameBgr.clone()
                            val outSub = out.submat(roi)
                            val compensated = applyRingExposureCompensation(
                                lastAiRepairedRoi!!,
                                lastAiRingMean,
                                curRingMean,
                            )
                            try {
                                blendRoiWithFeather(curOrigSub, compensated, workSub, outSub, VIDEO_FEATHER_PX)
                            } finally {
                                compensated.release()
                                outSub.release()
                            }
                            framesSinceAi++
                            reusedFrames++
                            val changedRoi = ImageProcessor.computeRoiWithMargin(
                                maskMat,
                                frameWidth,
                                frameHeight,
                                marginPx = growPx + VIDEO_FEATHER_PX + 2,
                            )
                            return FrameRepairOutcome(out, changedRoi)
                        }
                    }

                    // 执行真实的端侧 AI 推理
                    val inferred = MiganInpainter.inpaintBgr(
                        context = ctx,
                        srcBgr = frameBgr,
                        mask = maskMat,
                        growPx = growPx,
                        featherPx = VIDEO_FEATHER_PX,
                    )
                    val inferredSub = inferred.submat(roi)
                    try {
                        // 相邻帧背景连续变化时做轻度时序 EMA，消除微弱纹理解码闪烁
                        if (sameWindow && ringMae < AI_EMA_SCENE_CUT_MAE) {
                            blendTemporalEma(
                                current = inferredSub,
                                previous = lastAiRepairedRoi!!,
                                mask = workSub,
                                weightCurrent = 0.78,
                            )
                        }
                        updateAiCache(roi, curOrigSub, inferredSub, curRingMean)
                    } finally {
                        inferredSub.release()
                    }
                    aiFrames++
                    framesSinceAi = 0
                    val changedRoi = ImageProcessor.computeRoiWithMargin(
                        maskMat,
                        frameWidth,
                        frameHeight,
                        marginPx = growPx + VIDEO_FEATHER_PX + 2,
                    )
                    return FrameRepairOutcome(inferred, changedRoi)
                } finally {
                    ringSub.release()
                    workSub.release()
                    curOrigSub.release()
                }
            } finally {
                if (!useStaticCache) {
                    workMask.release()
                    ringMask.release()
                }
            }
        }

        private fun updateAiCache(
            roi: CvRect,
            origSub: Mat,
            repairedSub: Mat,
            ringMean: Scalar?,
        ) {
            lastAiOrigRoi?.release()
            lastAiRepairedRoi?.release()
            lastAiOrigRoi = origSub.clone()
            lastAiRepairedRoi = repairedSub.clone()
            lastAiRoiRect = roi
            lastAiRingMean = ringMean
            lastAiShiftX = cumulative[2]
            lastAiShiftY = cumulative[5]
            lastAiScale = cumulativeScale
        }

        private fun dilateBinaryMask(mask: Mat, px: Int): Mat {
            if (px <= 0) return mask.clone()
            val size = (px * 2 + 1).toDouble()
            val kernel = Imgproc.getStructuringElement(Imgproc.MORPH_ELLIPSE, Size(size, size))
            val out = Mat()
            try {
                Imgproc.dilate(mask, out, kernel)
            } finally {
                kernel.release()
            }
            return out
        }

        /** 构造水印外围干净背景参考环：`dilate(workMask, 18) - dilate(workMask, 4)`。 */
        private fun buildReferenceRingMask(workMask: Mat): Mat {
            val inner = dilateBinaryMask(workMask, RING_INNER_PAD_PX)
            val outer = dilateBinaryMask(workMask, RING_OUTER_PAD_PX)
            val ring = Mat()
            try {
                Core.subtract(outer, inner, ring)
                return ring
            } finally {
                inner.release()
                outer.release()
            }
        }

        private fun computeMaskedMae(a: Mat, b: Mat, mask: Mat): Double {
            if (Core.countNonZero(mask) == 0) return Double.POSITIVE_INFINITY
            val diff = Mat()
            try {
                Core.absdiff(a, b, diff)
                val mean = Core.mean(diff, mask)
                return (mean.`val`[0] + mean.`val`[1] + mean.`val`[2]) / 3.0
            } finally {
                diff.release()
            }
        }

        private fun applyRingExposureCompensation(
            cachedRepaired: Mat,
            prevMean: Scalar?,
            curMean: Scalar?,
        ): Mat {
            if (prevMean == null || curMean == null) return cachedRepaired.clone()
            val db = (curMean.`val`[0] - prevMean.`val`[0]).coerceIn(-12.0, 12.0)
            val dg = (curMean.`val`[1] - prevMean.`val`[1]).coerceIn(-12.0, 12.0)
            val dr = (curMean.`val`[2] - prevMean.`val`[2]).coerceIn(-12.0, 12.0)
            if (abs(db) < 0.5 && abs(dg) < 0.5 && abs(dr) < 0.5) {
                return cachedRepaired.clone()
            }
            val out = Mat()
            Core.add(cachedRepaired, Scalar(db, dg, dr), out)
            return out
        }

        private fun blendRoiWithFeather(
            src: Mat,
            repaired: Mat,
            mask: Mat,
            dst: Mat,
            feather: Int,
        ) {
            if (feather <= 0) {
                src.copyTo(dst)
                repaired.copyTo(dst, mask)
                return
            }
            val alpha = Mat()
            val alpha3 = Mat()
            val srcF = Mat()
            val repF = Mat()
            val delta = Mat()
            val scaled = Mat()
            val outF = Mat()
            try {
                mask.convertTo(alpha, CvType.CV_32F, 1.0 / 255.0)
                val k = (feather * 2 + 1).toDouble()
                Imgproc.GaussianBlur(alpha, alpha, Size(k, k), 0.0)
                alpha.setTo(Scalar(1.0), mask)
                Core.merge(listOf(alpha, alpha, alpha), alpha3)

                src.convertTo(srcF, CvType.CV_32FC3)
                repaired.convertTo(repF, CvType.CV_32FC3)
                Core.subtract(repF, srcF, delta)
                Core.multiply(delta, alpha3, scaled)
                Core.add(srcF, scaled, outF)
                outF.convertTo(dst, CvType.CV_8UC3)
            } finally {
                alpha.release()
                alpha3.release()
                srcF.release()
                repF.release()
                delta.release()
                scaled.release()
                outF.release()
            }
        }

        /** 仅在 `mask` 内做时序滑动平均：`weightCurrent * current + (1 - weightCurrent) * previous`。 */
        private fun blendTemporalEma(
            current: Mat,
            previous: Mat,
            mask: Mat,
            weightCurrent: Double,
        ) {
            val blended = Mat()
            try {
                Core.addWeighted(current, weightCurrent, previous, 1.0 - weightCurrent, 0.0, blended)
                blended.copyTo(current, mask)
            } finally {
                blended.release()
            }
        }

        private fun signalEncoderEos(encInfo: MediaCodec.BufferInfo) {
            val codec = encoder
            if (codec == null) {
                encoderDone = true
                return
            }
            val index = dequeueEncoderInputWithDrain(codec, encInfo)
            codec.queueInputBuffer(index, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
        }

        /** @return true 表示编码器已经吐完 EOS */
        private fun drainEncoder(info: MediaCodec.BufferInfo): Boolean {
            val codec = encoder ?: return false
            while (true) {
                val index = codec.dequeueOutputBuffer(info, 0)
                if (index == MediaCodec.INFO_TRY_AGAIN_LATER) return false
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    videoTrackIndex = muxer.addTrack(codec.outputFormat)
                    muxer.setOrientationHint(rotation)
                    muxer.start()
                    muxerStarted = true
                    continue
                }
                if (index < 0) continue

                if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                    info.size = 0
                }
                if (info.size > 0) {
                    if (!muxerStarted) {
                        throw IllegalStateException("编码器在 muxer 启动前就吐了数据")
                    }
                    val buffer: ByteBuffer? = codec.getOutputBuffer(index)
                    if (buffer != null) {
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        muxer.writeSampleData(videoTrackIndex, buffer, info)
                        videoBytes += info.size
                    }
                }
                codec.releaseOutputBuffer(index, false)

                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return true
            }
        }

        private fun mapMaskToFrame(rect: RectF, rot: Int, w: Int, h: Int): FracRect {
            val u0 = rect.left.coerceIn(0f, 1f).toDouble()
            val v0 = rect.top.coerceIn(0f, 1f).toDouble()
            val u1 = rect.right.coerceIn(0f, 1f).toDouble()
            val v1 = rect.bottom.coerceIn(0f, 1f).toDouble()
            return when (((rot % 360) + 360) % 360) {
                90 -> FracRect(v0, 1.0 - u1, v1, 1.0 - u0)
                180 -> FracRect(1.0 - u1, 1.0 - v1, 1.0 - u0, 1.0 - v0)
                270 -> FracRect(1.0 - v1, u0, 1.0 - v0, u1)
                else -> FracRect(u0, v0, u1, v1)
            }
        }

        private fun loadMaskFile(path: String, w: Int, h: Int): Mat? {
            val raw = Imgcodecs.imread(path, Imgcodecs.IMREAD_GRAYSCALE) ?: return null
            if (raw.empty()) {
                raw.release()
                return null
            }
            var oriented = raw
            try {
                Imgproc.threshold(raw, raw, 127.0, 255.0, Imgproc.THRESH_BINARY)
                oriented = when (((rotation % 360) + 360) % 360) {
                    90 -> Mat().also { Core.rotate(raw, it, Core.ROTATE_90_COUNTERCLOCKWISE) }
                    180 -> Mat().also { Core.rotate(raw, it, Core.ROTATE_180) }
                    270 -> Mat().also { Core.rotate(raw, it, Core.ROTATE_90_CLOCKWISE) }
                    else -> raw
                }
                val out = Mat()
                Imgproc.resize(
                    oriented,
                    out,
                    Size(w.toDouble(), h.toDouble()),
                    0.0,
                    0.0,
                    Imgproc.INTER_NEAREST,
                )
                if (out.empty() || Core.countNonZero(out) == 0) {
                    out.release()
                    return null
                }
                return out
            } finally {
                if (oriented !== raw) oriented.release()
                raw.release()
            }
        }

        private fun buildMask(w: Int, h: Int): Mat {
            maskPath?.let { path ->
                loadMaskFile(path, w, h)?.let { mat ->
                    maskBase = mat
                    val copy = mat.clone()
                    Log.i(
                        TAG,
                        "mask 来自 PNG: $path -> ${w}x$h px=${Core.countNonZero(copy)} rot=$rotation",
                    )
                    return copy
                }
                Log.w(TAG, "maskPath 给了但读不出: $path —— 退回按选框建 Mask")
            }
            val frac = mapMaskToFrame(normalizedMask, rotation, w, h)
            val left = (frac.left * w).toInt().coerceIn(0, w - 1)
            val top = (frac.top * h).toInt().coerceIn(0, h - 1)
            val right = (frac.right * w).toInt().coerceIn(left + 1, w)
            val bottom = (frac.bottom * h).toInt().coerceIn(top + 1, h)

            maskQuad = arrayOf(
                Point(left.toDouble(), top.toDouble()),
                Point((right - 1).toDouble(), top.toDouble()),
                Point((right - 1).toDouble(), (bottom - 1).toDouble()),
                Point(left.toDouble(), (bottom - 1).toDouble()),
            )

            val mat = Mat.zeros(h, w, CvType.CV_8UC1)
            Imgproc.rectangle(
                mat,
                Point(left.toDouble(), top.toDouble()),
                Point((right - 1).toDouble(), (bottom - 1).toDouble()),
                Scalar(255.0),
                -1,
            )
            Log.i(
                TAG,
                "mask display=${normalizedMask.left},${normalizedMask.top}," +
                    "${normalizedMask.right},${normalizedMask.bottom} rot=$rotation " +
                    "frame=${w}x$h -> px=($left,$top)-($right,$bottom)",
            )
            return mat
        }

        private fun computeDirectMotion() {
            val a = firstGray ?: return
            val b = lastGray ?: return
            val direct = MotionEstimator.estimate(a, b)
            directOk = direct.ok
            directShiftPx = direct.shiftPx
            directScale = direct.scale
            driftPx = Math.hypot(cumulative[2] - direct.m[2], cumulative[5] - direct.m[5])
            Log.i(
                TAG,
                "motion direct shift=${"%.2f".format(directShiftPx)}px " +
                    "scale=${"%.3f".format(directScale)} ok=$directOk " +
                    "inliers=${direct.inliers} | cumulative shift=${"%.2f".format(cumulativeShiftPx)}px " +
                    "drift=${"%.2f".format(driftPx)}px | keyframes=$keyframeSwitches lastInliers=$lastInliers",
            )
        }

        private fun updateMaskByMotion(applyToMask: Boolean = true) {
            val gray = grayMat ?: Mat(frameHeight, frameWidth, CvType.CV_8UC1).also {
                grayMat = it
            }
            Imgproc.cvtColor(frameBgr, gray, Imgproc.COLOR_BGR2GRAY)

            val lg = lastGray
            if (lg == null) lastGray = Mat().also { gray.copyTo(it) } else gray.copyTo(lg)

            val key = keyGray
            if (key == null) {
                keyGray = Mat().also { gray.copyTo(it) }
                firstGray = Mat().also { gray.copyTo(it) }
                keyCumulative = doubleArrayOf(1.0, 0.0, 0.0, 0.0, 1.0, 0.0)
                framesSinceKey = 0
                if (applyToMask) drawMaskQuad()
                return
            }

            val motion = MotionEstimator.estimate(key, gray)
            lastInliers = motion.inliers

            if (motion.ok && motion.inliers >= MIN_INLIERS_HEALTHY) {
                motionOk++
                cumulative = MotionEstimator.compose(keyCumulative, motion.m)
            } else {
                motionFailed++
            }

            framesSinceKey++
            val weak = motion.ok && motion.inliers < MIN_INLIERS_HEALTHY
            val movedTooFar = motion.ok && motion.shiftPx > MAX_KEY_SHIFT
            if (framesSinceKey >= MAX_KEY_SPAN || weak || !motion.ok || movedTooFar) {
                promoteKeyframe(gray)
            }

            if (applyToMask) drawMaskQuad()
        }

        private fun applyTrackedMotion() {
            val table = motionTable ?: return
            if (decoded !in table.indices) return
            cumulative = table[decoded]
            drawMaskQuad()
        }

        private fun promoteKeyframe(gray: Mat) {
            val key = keyGray ?: Mat().also { keyGray = it }
            gray.copyTo(key)
            keyCumulative = cumulative.copyOf()
            framesSinceKey = 0
            keyframeSwitches++
        }

        private fun drawMaskQuad() {
            val base = maskBase
            if (base != null) {
                val m = Mat(2, 3, CvType.CV_64F)
                for (i in 0 until 6) {
                    m.put(i / 3, i % 3, cumulative[i])
                }
                try {
                    Imgproc.warpAffine(
                        base,
                        maskMat,
                        m,
                        Size(base.cols().toDouble(), base.rows().toDouble()),
                        Imgproc.INTER_NEAREST,
                        Core.BORDER_CONSTANT,
                        Scalar(0.0),
                    )
                } finally {
                    m.release()
                }
                return
            }
            if (maskQuad.isEmpty()) return
            val pts = Array(maskQuad.size) { i ->
                val p = maskQuad[i]
                Point(
                    cumulative[0] * p.x + cumulative[1] * p.y + cumulative[2],
                    cumulative[3] * p.x + cumulative[4] * p.y + cumulative[5],
                )
            }
            maskMat.setTo(Scalar(0.0))
            Imgproc.fillConvexPoly(maskMat, MatOfPoint(*pts), Scalar(255.0))
        }

        private fun countMaskPixels(mat: Mat): Int = Core.countNonZero(mat)

        private data class FracRect(val left: Double, val top: Double, val right: Double, val bottom: Double)

        // ------------------------------------------------------------------ YUV ↔ BGR

        private fun yuvToBgr(image: Image, dst: Mat, scratch: ByteArray, w: Int, h: Int) {
            origYuvValid = false
            val planes = image.planes
            val semiPlanar = planes[1].pixelStride == 2 && planes[2].pixelStride == 2
            if (fastPathBroken || !semiPlanar || planes[0].pixelStride != 1) {
                yuvToBgrSlow(image, dst, scratch, w, h)
                return
            }

            ensurePacked(w, h)
            val mat = packedMat ?: error("packedMat 未初始化")

            val yBuf = planes[0].buffer
            val yRow = planes[0].rowStride
            val yLimit = yBuf.limit()
            for (y in 0 until h) {
                val off = y * yRow
                if (off + w > yLimit) {
                    fastPathBroken = true
                    Log.w(TAG, "Y 平面行偏移越界 (off=$off, w=$w, limit=$yLimit)，退回逐像素路径")
                    yuvToBgrSlow(image, dst, scratch, w, h)
                    return
                }
                yBuf.position(off)
                yBuf.get(packed, y * w, w)
            }

            if (!decoderUvProbed) {
                decoderUvProbed = true
                decoderUFirst = detectUFirst(planes[1].buffer, planes[2].buffer)
                Log.i(TAG, "decoder UV order probed → uFirst=$decoderUFirst (NV12=$decoderUFirst)")
            }
            if (!packDecodeUv(planes, decoderUFirst, w, h)) {
                fastPathBroken = true
                Log.w(TAG, "UV 平面边界不足，退回逐像素路径")
                yuvToBgrSlow(image, dst, scratch, w, h)
                return
            }

            mat.put(0, 0, packed)
            Imgproc.cvtColor(mat, dst, decodeCvt(decoderUFirst))

            if (!decoderUvVerified) {
                decoderUvVerified = true
                if (!spotCheckDecode(image, dst, w, h)) {
                    decoderUFirst = !decoderUFirst
                    if (!packDecodeUv(planes, decoderUFirst, w, h)) {
                        fastPathBroken = true
                        Log.w(TAG, "翻转 UV 顺序后边界不足，退回逐像素路径")
                        yuvToBgrSlow(image, dst, scratch, w, h)
                        return
                    }
                    mat.put(0, 0, packed)
                    Imgproc.cvtColor(mat, dst, decodeCvt(decoderUFirst))
                    if (spotCheckDecode(image, dst, w, h)) {
                        Log.w(TAG, "UV 顺序探测错了，翻转成 uFirst=$decoderUFirst 后自检通过")
                    } else {
                        fastPathBroken = true
                        Log.e(TAG, "快路径两种 UV 顺序都过不了自检 → 永久退回逐像素路径")
                        yuvToBgrSlow(image, dst, scratch, w, h)
                        return
                    }
                }
                Log.i(TAG, "fast yuv decode OK, uFirst=$decoderUFirst")
            }

            if (origYuv.size == packed.size) {
                System.arraycopy(packed, 0, origYuv, 0, packed.size)
                origYuvValid = true
            }
        }

        private fun decodeCvt(uFirst: Boolean) =
            if (uFirst) Imgproc.COLOR_YUV2BGR_NV12 else Imgproc.COLOR_YUV2BGR_NV21

        /**
         * 将 semi-planar UV 平面按行拷入 `packed` 尾部。
         *
         * 处理 Android 规范中最后一行的尾字节跨越主平面 `limit` 的情况（从另一互补色度平面补齐），
         * 避免在标准 720p/1080p 无底部 padding 视频上抛出 `BufferUnderflowException`。
         */
        private fun packDecodeUv(
            planes: Array<Image.Plane>,
            uFirst: Boolean,
            w: Int,
            h: Int,
        ): Boolean {
            val primary = if (uFirst) planes[1] else planes[2]
            val sibling = if (uFirst) planes[2] else planes[1]
            val uvBuf = primary.buffer
            val sibBuf = sibling.buffer
            val uvRow = primary.rowStride
            val uvLimit = uvBuf.limit()
            val sibLimit = sibBuf.limit()
            val uvBase = w * h
            for (y in 0 until h / 2) {
                val off = y * uvRow
                val dstOff = uvBase + y * w
                if (off >= uvLimit) return false
                val n = (uvLimit - off).coerceIn(0, w)
                if (n > 0) {
                    uvBuf.position(off)
                    uvBuf.get(packed, dstOff, n)
                }
                var i = n
                while (i < w) {
                    val abs = off + i
                    if (abs < uvLimit) {
                        packed[dstOff + i] = uvBuf.get(abs)
                    } else {
                        val sibIdx = abs - 1
                        if (sibIdx in 0 until sibLimit) {
                            packed[dstOff + i] = sibBuf.get(sibIdx)
                        } else {
                            return false
                        }
                    }
                    i++
                }
            }
            return true
        }

        private fun detectUFirst(uBuf: ByteBuffer, vBuf: ByteBuffer): Boolean {
            val limit = minOf(uBuf.limit(), vBuf.limit())
            if (limit < 8) return true
            val samples = 16
            val step = ((limit / 2) / samples).coerceAtLeast(1)
            var votesU = 0
            var votesV = 0
            for (k in 0 until samples) {
                val base = 2 * (k * step)
                if (base + 1 >= limit) break
                val u0 = uBuf.get(base).toInt() and 0xFF
                val u1 = uBuf.get(base + 1).toInt() and 0xFF
                val v0 = vBuf.get(base).toInt() and 0xFF
                val v1 = vBuf.get(base + 1).toInt() and 0xFF
                val uFirst = u1 == v0
                val vFirst = v1 == u0
                if (uFirst && !vFirst) votesU++ else if (vFirst && !uFirst) votesV++
            }
            return votesU >= votesV
        }

        private fun spotCheckDecode(image: Image, bgr: Mat, w: Int, h: Int): Boolean {
            val planes = image.planes
            val yBuf = planes[0].buffer
            val uBuf = planes[1].buffer
            val vBuf = planes[2].buffer
            val yRow = planes[0].rowStride
            val yPix = planes[0].pixelStride
            val uRow = planes[1].rowStride
            val uPix = planes[1].pixelStride
            val vRow = planes[2].rowStride
            val vPix = planes[2].pixelStride

            var ok = 0
            var total = 0
            for ((fx, fy) in SPOT_POINTS) {
                val x = (fx * (w - 1)).toInt()
                val y = (fy * (h - 1)).toInt()
                val ci = x shr 1
                val yv = yBuf.get(y * yRow + x * yPix).toInt() and 0xFF
                val uv = uBuf.get((y shr 1) * uRow + ci * uPix).toInt() and 0xFF
                val vv = vBuf.get((y shr 1) * vRow + ci * vPix).toInt() and 0xFF

                val c = yv - 16
                val d = uv - 128
                val e = vv - 128
                val r = ((298 * c + 409 * e + 128) shr 8).coerceIn(0, 255)
                val g = ((298 * c - 100 * d - 208 * e + 128) shr 8).coerceIn(0, 255)
                val b = ((298 * c + 516 * d + 128) shr 8).coerceIn(0, 255)

                val actual = bgr.get(y, x) ?: continue
                total++
                val diff = maxOf(
                    abs(actual[0] - b),
                    abs(actual[1] - g),
                    abs(actual[2] - r),
                )
                if (diff <= 12.0) ok++
            }
            return total == 0 || ok * 2 > total
        }

        private fun yuvToBgrSlow(image: Image, dst: Mat, scratch: ByteArray, w: Int, h: Int) {
            val planes = image.planes
            val yBuf = planes[0].buffer
            val uBuf = planes[1].buffer
            val vBuf = planes[2].buffer
            val yRow = planes[0].rowStride
            val yPix = planes[0].pixelStride
            val uRow = planes[1].rowStride
            val uPix = planes[1].pixelStride
            val vRow = planes[2].rowStride
            val vPix = planes[2].pixelStride

            var p = 0
            for (y in 0 until h) {
                val yBase = y * yRow
                val uBase = (y shr 1) * uRow
                val vBase = (y shr 1) * vRow
                for (x in 0 until w) {
                    val yi = yBase + x * yPix
                    val ci = x shr 1
                    val yv = yBuf.get(yi).toInt() and 0xFF
                    val uv = uBuf.get(uBase + ci * uPix).toInt() and 0xFF
                    val vv = vBuf.get(vBase + ci * vPix).toInt() and 0xFF

                    val c = yv - 16
                    val d = uv - 128
                    val e = vv - 128
                    val r = ((298 * c + 409 * e + 128) shr 8).coerceIn(0, 255)
                    val g = ((298 * c - 100 * d - 208 * e + 128) shr 8).coerceIn(0, 255)
                    val b = ((298 * c + 516 * d + 128) shr 8).coerceIn(0, 255)

                    scratch[p++] = b.toByte()
                    scratch[p++] = g.toByte()
                    scratch[p++] = r.toByte()
                }
            }
            dst.put(0, 0, scratch)
        }

        private fun alignEvenRoi(rawRoi: CvRect?, w: Int, h: Int): CvRect? {
            if (rawRoi == null || w < 2 || h < 2) return null
            val maxW = w and 1.inv()
            val maxH = h and 1.inv()
            val x0 = (rawRoi.x and 1.inv()).coerceIn(0, (maxW - 2).coerceAtLeast(0))
            var y0 = (rawRoi.y and 1.inv()).coerceIn(0, (maxH - 2).coerceAtLeast(0))
            val x1 = ((rawRoi.x + rawRoi.width + 1) and 1.inv()).coerceIn(x0 + 2, maxW)
            var y1 = ((rawRoi.y + rawRoi.height + 1) and 1.inv()).coerceIn(y0 + 2, maxH)
            if (x1 <= x0 || y1 <= y0) return null
            if (maxH >= 4 && (y1 - y0) % 4 != 0) {
                if (y1 + 2 <= maxH) {
                    y1 += 2
                } else if (y0 >= 2) {
                    y0 -= 2
                }
            }
            return CvRect(x0, y0, x1 - x0, y1 - y0)
        }

        private fun ensureRoiI420(rw: Int, rh: Int) {
            val need = rw * rh * 3 / 2
            val current = roiI420Mat
            if (current != null && current.cols() == rw && current.rows() == rh * 3 / 2 && roiI420Bytes.size == need) {
                return
            }
            roiI420Mat?.release()
            roiI420Mat = Mat(rh * 3 / 2, rw, CvType.CV_8UC1)
            roiI420Bytes = ByteArray(need)
        }

        private fun bgrToYuv(
            src: Mat,
            image: Image,
            scratch: ByteArray,
            w: Int,
            h: Int,
            evenRoi: CvRect? = null,
            origImage: Image? = null,
        ) {
            val planes = image.planes
            val semiPlanar = planes[1].pixelStride == 2 && planes[2].pixelStride == 2
            if (fastPathBroken || !semiPlanar || planes[0].pixelStride != 1) {
                bgrToYuvSlow(src, image, scratch, w, h, evenRoi, origImage)
                return
            }

            ensurePacked(w, h)
            if (!encoderUvProbed) {
                encoderUvProbed = true
                encoderUFirst = probeEncoderUFirst(planes)
                Log.i(TAG, "encoder UV order probed → uFirst=$encoderUFirst (NV12=$encoderUFirst)")
            }

            val totalNeed = w * h * 3 / 2
            if (origYuvValid && origYuv.size == totalNeed) {
                copyOrigYuvToPacked(w, h)
                if (evenRoi != null && evenRoi.width >= 2 && evenRoi.height >= 2) {
                    writeRoiBgrToPacked(src, evenRoi, w, h)
                }
            } else {
                val i420 = i420Mat ?: error("i420Mat 未初始化")
                val uv = uvMat ?: error("uvMat 未初始化")

                Imgproc.cvtColor(src, i420, Imgproc.COLOR_BGR2YUV_I420)
                val uRows = i420.rowRange(h, h + h / 4)
                val vRows = i420.rowRange(h + h / 4, h * 3 / 2)
                val uMat = uRows.reshape(1, h / 2)
                val vMat = vRows.reshape(1, h / 2)
                uRows.release()
                vRows.release()
                try {
                    Core.merge(
                        if (encoderUFirst) listOf(uMat, vMat) else listOf(vMat, uMat),
                        uv,
                    )
                } finally {
                    uMat.release()
                    vMat.release()
                }

                i420.get(0, 0, packed)
                uv.get(0, 0, uvBytes)
                System.arraycopy(uvBytes, 0, packed, w * h, uvBytes.size)
            }

            val yPlane = planes[0]
            fillPlane(yPlane.buffer, 16)
            fillPlane(planes[1].buffer, 128)
            fillPlane(planes[2].buffer, 128)

            val yWrite = yPlane.buffer
            val yLimit = yWrite.limit()
            if (yPlane.rowStride == w && yLimit >= w * h) {
                yWrite.clear()
                yWrite.put(packed, 0, w * h)
            } else {
                for (y in 0 until h) {
                    val off = y * yPlane.rowStride
                    val n = (yLimit - off).coerceIn(0, w)
                    if (n > 0) {
                        yWrite.position(off)
                        yWrite.put(packed, y * w, n)
                    }
                }
            }

            val uvPlane = if (encoderUFirst) planes[1] else planes[2]
            val uvSibling = (if (encoderUFirst) planes[2] else planes[1]).buffer
            val uvWrite = uvPlane.buffer
            val uvBase = w * h
            val uvRow = uvPlane.rowStride
            val uvLimit = uvWrite.limit()
            val sibLimit = uvSibling.limit()
            for (y in 0 until h / 2) {
                val off = y * uvRow
                val srcOff = uvBase + y * w
                val n = (uvLimit - off).coerceIn(0, w)
                if (n > 0) {
                    uvWrite.position(off)
                    uvWrite.put(packed, srcOff, n)
                }
                var i = n
                while (i < w) {
                    val abs = off + i
                    if (abs < uvLimit) {
                        uvWrite.put(abs, packed[srcOff + i])
                    } else if (abs - 1 in 0 until sibLimit) {
                        uvSibling.put(abs - 1, packed[srcOff + i])
                    }
                    i++
                }
            }
        }

        private fun copyOrigYuvToPacked(w: Int, h: Int) {
            val yBytes = w * h
            System.arraycopy(origYuv, 0, packed, 0, yBytes)
            val uvLen = w * h / 2
            if (decoderUFirst == encoderUFirst) {
                System.arraycopy(origYuv, yBytes, packed, yBytes, uvLen)
            } else {
                var i = yBytes
                val end = yBytes + uvLen
                while (i + 1 < end) {
                    packed[i] = origYuv[i + 1]
                    packed[i + 1] = origYuv[i]
                    i += 2
                }
            }
        }

        private fun writeRoiBgrToPacked(src: Mat, evenRoi: CvRect, w: Int, h: Int) {
            val rw = evenRoi.width
            val rh = evenRoi.height
            val x0 = evenRoi.x
            val y0 = evenRoi.y
            ensureRoiI420(rw, rh)
            val roiI420 = roiI420Mat ?: error("roiI420Mat 未初始化")
            val roiSub = src.submat(evenRoi)
            val roiCopy = roiSub.clone()
            try {
                Imgproc.cvtColor(roiCopy, roiI420, Imgproc.COLOR_BGR2YUV_I420)
            } finally {
                roiCopy.release()
                roiSub.release()
            }
            roiI420.get(0, 0, roiI420Bytes)

            for (ry in 0 until rh) {
                System.arraycopy(roiI420Bytes, ry * rw, packed, (y0 + ry) * w + x0, rw)
            }

            val cw = rw / 2
            val ch = rh / 2
            val uOff = rw * rh
            val vOff = uOff + cw * ch
            val uvBase = w * h
            val cx0 = x0 / 2
            val cy0 = y0 / 2
            for (cy in 0 until ch) {
                val dstRow = uvBase + (cy0 + cy) * w + cx0 * 2
                val uRow = uOff + cy * cw
                val vRow = vOff + cy * cw
                for (cx in 0 until cw) {
                    val uByte = roiI420Bytes[uRow + cx]
                    val vByte = roiI420Bytes[vRow + cx]
                    val idx = dstRow + cx * 2
                    if (encoderUFirst) {
                        packed[idx] = uByte
                        packed[idx + 1] = vByte
                    } else {
                        packed[idx] = vByte
                        packed[idx + 1] = uByte
                    }
                }
            }
        }

        private fun probeEncoderUFirst(planes: Array<Image.Plane>): Boolean {
            val uBuf = planes[1].buffer
            val vBuf = planes[2].buffer
            if (uBuf.limit() < 2 || vBuf.limit() < 1) return true
            fillPlane(uBuf, 100)
            fillPlane(vBuf, 100)
            vBuf.put(0, 200.toByte())
            return (uBuf.get(1).toInt() and 0xFF) == 200
        }

        private fun bgrToYuvSlow(
            src: Mat,
            image: Image,
            scratch: ByteArray,
            w: Int,
            h: Int,
            evenRoi: CvRect? = null,
            origImage: Image? = null,
        ) {
            val planes = image.planes
            val yPlane = planes[0]
            val uPlane = planes[1]
            val vPlane = planes[2]

            fillPlane(yPlane.buffer, 16)
            fillPlane(uPlane.buffer, 128)
            fillPlane(vPlane.buffer, 128)

            if (origImage != null) {
                val origPlanes = origImage.planes
                copyPlane(origPlanes[0], yPlane, w, h)
                copyPlane(origPlanes[1], uPlane, w / 2, h / 2)
                copyPlane(origPlanes[2], vPlane, w / 2, h / 2)
                if (evenRoi == null || evenRoi.width < 2 || evenRoi.height < 2) return

                val x0 = evenRoi.x
                val y0 = evenRoi.y
                val rw = evenRoi.width
                val rh = evenRoi.height
                val roiBytes: ByteArray
                val roiSub = src.submat(evenRoi)
                val roiCopy = roiSub.clone()
                try {
                    roiBytes = ByteArray(rw * rh * 3)
                    roiCopy.get(0, 0, roiBytes)
                } finally {
                    roiCopy.release()
                    roiSub.release()
                }
                writeBgrBytesToYuvPlanes(roiBytes, x0, y0, rw, rh, yPlane, uPlane, vPlane)
                return
            }

            src.get(0, 0, scratch)
            writeBgrBytesToYuvPlanes(scratch, 0, 0, w, h, yPlane, uPlane, vPlane)
        }

        private fun writeBgrBytesToYuvPlanes(
            bgr: ByteArray,
            x0: Int,
            y0: Int,
            rw: Int,
            rh: Int,
            yPlane: Image.Plane,
            uPlane: Image.Plane,
            vPlane: Image.Plane,
        ) {
            var p = 0
            for (ry in 0 until rh) {
                val y = y0 + ry
                val yBase = y * yPlane.rowStride
                val uBase = (y shr 1) * uPlane.rowStride
                val vBase = (y shr 1) * vPlane.rowStride
                for (rx in 0 until rw) {
                    val x = x0 + rx
                    val b = bgr[p].toInt() and 0xFF
                    val g = bgr[p + 1].toInt() and 0xFF
                    val r = bgr[p + 2].toInt() and 0xFF
                    p += 3

                    val yv = (((66 * r + 129 * g + 25 * b + 128) shr 8) + 16).coerceIn(0, 255)
                    yPlane.buffer.put(yBase + x * yPlane.pixelStride, yv.toByte())

                    if ((x and 1) == 0 && (y and 1) == 0) {
                        val ci = x shr 1
                        val uv = (((-38 * r - 74 * g + 112 * b + 128) shr 8) + 128).coerceIn(0, 255)
                        val vv = (((112 * r - 94 * g - 18 * b + 128) shr 8) + 128).coerceIn(0, 255)
                        uPlane.buffer.put(uBase + ci * uPlane.pixelStride, uv.toByte())
                        vPlane.buffer.put(vBase + ci * vPlane.pixelStride, vv.toByte())
                    }
                }
            }
        }

        private fun copyPlane(srcPlane: Image.Plane, dstPlane: Image.Plane, pw: Int, ph: Int) {
            val srcBuf = srcPlane.buffer
            val dstBuf = dstPlane.buffer
            val srcRow = srcPlane.rowStride
            val dstRow = dstPlane.rowStride
            val srcPix = srcPlane.pixelStride
            val dstPix = dstPlane.pixelStride
            if (srcPix == 1 && dstPix == 1) {
                val rowBuf = ByteArray(pw)
                for (y in 0 until ph) {
                    val sOff = y * srcRow
                    val dOff = y * dstRow
                    val n = minOf(pw, (srcBuf.limit() - sOff).coerceAtLeast(0), (dstBuf.limit() - dOff).coerceAtLeast(0))
                    if (n > 0) {
                        srcBuf.position(sOff)
                        srcBuf.get(rowBuf, 0, n)
                        dstBuf.position(dOff)
                        dstBuf.put(rowBuf, 0, n)
                    }
                }
                return
            }
            for (y in 0 until ph) {
                val sOff = y * srcRow
                val dOff = y * dstRow
                for (x in 0 until pw) {
                    val si = sOff + x * srcPix
                    val di = dOff + x * dstPix
                    if (si < srcBuf.limit() && di < dstBuf.limit()) {
                        dstBuf.put(di, srcBuf.get(si))
                    }
                }
            }
        }

        private fun fillPlane(buffer: ByteBuffer, value: Int) {
            val byte = value.toByte()
            buffer.clear()
            val chunk = ByteArray(4096) { byte }
            while (buffer.remaining() >= chunk.size) buffer.put(chunk)
            while (buffer.hasRemaining()) buffer.put(byte)
        }
    }

    // ------------------------------------------------------------------ 音轨

    private class AudioSetup(
        val extractor: MediaExtractor,
        val trackIndex: Int,
        val maxInputSize: Int,
    )

    private class AudioSetupResult(
        val setup: AudioSetup?,
        val audioSkipped: Boolean,
    )

    /** 容错挂载音轨：跳过不被 MP4 容器支持的多媒体编码（如 Opus/AC3），防止炸毁整条视频链路。 */
    private fun openAudioTrack(inputPath: String, muxer: MediaMuxer): AudioSetupResult {
        val extractor = MediaExtractor()
        var hasAudioTrack = false
        try {
            extractor.setDataSource(inputPath)
            for (i in 0 until extractor.trackCount) {
                val fmt = extractor.getTrackFormat(i)
                val mime = fmt.getString(MediaFormat.KEY_MIME) ?: continue
                if (!mime.startsWith(MIME_AUDIO)) continue
                hasAudioTrack = true
                try {
                    val trackIndex = muxer.addTrack(fmt)
                    extractor.selectTrack(i)
                    val maxSize = readInt(fmt, MediaFormat.KEY_MAX_INPUT_SIZE, AUDIO_BUFFER_BYTES)
                        .coerceIn(AUDIO_BUFFER_BYTES, AUDIO_BUFFER_MAX_BYTES)
                    Log.i(TAG, "audio track $i mime=$mime maxInput=$maxSize")
                    return AudioSetupResult(AudioSetup(extractor, trackIndex, maxSize), audioSkipped = false)
                } catch (e: Throwable) {
                    Log.w(TAG, "音轨 $i ($mime) 不支持封装进 MP4，跳过：${e.message}")
                }
            }
            if (hasAudioTrack) {
                Log.w(TAG, "源文件音轨均不兼容 MP4 容器，将导出纯视频")
            } else {
                Log.i(TAG, "源文件没有音轨，输出只有视频")
            }
            extractor.release()
            return AudioSetupResult(null, audioSkipped = hasAudioTrack)
        } catch (e: Throwable) {
            extractor.release()
            Log.w(TAG, "读取音轨失败，跳过音轨继续处理视频：${e.message}")
            return AudioSetupResult(null, audioSkipped = true)
        }
    }

    /** 音轨透传：压缩样本直接搬运，钳位非负单调 PTS 并跳过损坏样本。 */
    private fun copyAudio(
        extractor: MediaExtractor,
        trackIndex: Int,
        muxer: MediaMuxer,
        muxerStarted: Boolean,
        bufferBytes: Int,
    ): Long {
        if (!muxerStarted) {
            Log.w(TAG, "muxer 未启动，跳过音轨搬运")
            return 0L
        }
        val buffer = ByteBuffer.allocateDirect(bufferBytes)
        val info = MediaCodec.BufferInfo()
        var bytes = 0L
        var samples = 0
        var lastAudioPtsUs = -1L
        while (true) {
            buffer.clear()
            val size = try {
                extractor.readSampleData(buffer, 0)
            } catch (e: Throwable) {
                Log.w(TAG, "读取音频样本失败（终止音轨搬运）：${e.message}")
                break
            }
            if (size < 0) break
            val rawPts = extractor.sampleTime
            val safePts = maxOf(0L, rawPts).let { p ->
                if (lastAudioPtsUs >= 0 && p <= lastAudioPtsUs) lastAudioPtsUs + 1L else p
            }
            lastAudioPtsUs = safePts
            val flags = if (extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) {
                MediaCodec.BUFFER_FLAG_KEY_FRAME
            } else {
                0
            }
            info.set(0, size, safePts, flags)
            try {
                muxer.writeSampleData(trackIndex, buffer, info)
                bytes += size
                samples++
            } catch (e: Throwable) {
                Log.w(TAG, "写入音频样本失败（跳过该样本）：${e.message}")
            }
            if (!extractor.advance()) break
        }
        Log.i(TAG, "audio copied $samples samples / $bytes bytes")
        return bytes
    }

    private fun findVideoTrack(extractor: MediaExtractor): Int? {
        for (i in 0 until extractor.trackCount) {
            val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("video/")) return i
        }
        return null
    }

    private fun readInt(format: MediaFormat, key: String, fallback: Int): Int =
        if (format.containsKey(key)) format.getInteger(key) else fallback

    private fun readLong(format: MediaFormat, key: String, fallback: Long): Long =
        if (format.containsKey(key)) format.getLong(key) else fallback
}
