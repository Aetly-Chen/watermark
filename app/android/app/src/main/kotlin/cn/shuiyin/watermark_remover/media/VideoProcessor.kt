package cn.shuiyin.watermark_remover.media

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
import org.opencv.core.Scalar
import org.opencv.imgproc.Imgproc
import java.io.File
import java.nio.ByteBuffer
import kotlin.math.abs

/**
 * 视频转码 + 逐帧修复。**第一版只做「镜头静止 + 同一张 Mask 套所有帧」**，不做光流追踪。
 *
 * 链路：MediaExtractor 读视频轨 → MediaCodec 解码 → YUV_420_888 → BGR Mat
 *      → ImageProcessor.inpaintBgr（与图片路径同一份 OpenCV 逻辑）
 *      → BGR → YUV_420_888 → MediaCodec 编码 → MediaMuxer 封装（音轨原样透传）
 *
 * ## 这一段真正的难点不是 OpenCV，是三件别的事
 *
 * **1. YUV 不是 RGB。** MediaCodec 解出来的原始帧是 YUV_420_888，一个亮度平面 + 两个
 * 色度平面，而且三个平面各自有 rowStride / pixelStride —— 不是「宽 × 高」连续排的。
 * 有些机型是 planar（I420），有些是 semi-planar（NV12，U/V 交错共用一块内存）。
 * 用 `getOutputImage()` 拿 Image 对象，它能告诉你每个平面的 stride，两种布局都能正确处理；
 * 靠 `ByteBuffer` 自己算偏移一定会踩到某个厂商。
 *
 * **2. PTS 必须原样带过去。** 解码出来的每一帧带一个 `presentationTimeUs`，
 * 这个值就是播放时间轴。重新编码时**必须把它原样喂给编码器**，
 * 不能从 0 开始按帧号 × (1e6/fps) 自己算 —— 那样 VFR（可变帧率）视频会音画不同步，
 * 而且慢镜头/抽帧的地方会累积漂移。PTS 是这条链上唯一可信的时间来源。
 *
 * **3. 音轨不需要解码。** 音轨是压缩数据（AAC），直接把 sample 从输入 MP4 搬到输出 MP4 就行，
 * 一个字节都不用碰。解码再编码只会掉质量、浪费时间，还容易踩采样率/声道数的坑。
 *
 * ## 两个「不猜」的设计
 *
 * - **编码尺寸取第一帧的真实尺寸**，不信 `MediaFormat` 报的 width/height。
 *   解码器输出可能带编码器对齐用的 padding（如 1080 → 1088），
 *   以 Image 的实际宽高为准，Mask 和编码器都按它建，天然自洽。
 * - **旋转不靠重排像素**。解码出来的帧是「编码朝向」的，我们就在这个朝向上修，
 *   最后只把 rotation 写进容器（`setOrientationHint`），播放器自己会转。
 *   代价是 Mask 的归一化坐标要从**显示坐标系**逆变换到**帧坐标系** —— 见 [mapMaskToFrame]。
 */
object VideoProcessor {
    private const val TAG = "WmVideoProcessor"

    /** 等不到 buffer 就再来一轮。视频解码单帧通常几毫秒，10ms 足够。 */
    private const val DEQUEUE_TIMEOUT_US = 10_000L

    private const val MIME_VIDEO = "video/avc"
    private const val MIME_AUDIO = "audio/"

    /** 音轨搬运用的缓冲区。AAC 一帧最多几 KB，256KB 绰绰有余。 */
    private const val AUDIO_BUFFER_BYTES = 256 * 1024

    /** 每处理这么多帧报一次进度。太密会把主线程刷爆。 */
    private const val PROGRESS_EVERY = 5

    /**
     * 进度阶段。两趟化之后一条任务会先报 [PHASE_MOTION]、再报 [PHASE_REPAIR]；
     * 静止水印只有一趟，只会报 [PHASE_REPAIR]。
     *
     * 为什么要分阶段而不是只给一个百分比：两趟的两个百分比各自归零重来，
     * 用户看到进度条从 100% 跳回 0% 会以为出了两次任务。
     */
    const val PHASE_MOTION = "motion"
    const val PHASE_REPAIR = "repair"

    /**
     * 自检取样点（归一化坐标）。要**分散**：解码器输出的平面偏移是整块性质的，
     * 取点全挤在左上角，万一那块恰好是纯色（比如黑边）就判不出 UV 顺序。
     */
    private val SPOT_POINTS = arrayOf(
        0.17 to 0.23,
        0.50 to 0.50,
        0.83 to 0.77,
        0.31 to 0.62,
        0.71 to 0.41,
    )

    /** 调用方主动取消。与「出错」区分开，Dart 侧要收 cancelled 而不是 native_failure。 */
    class VideoCancelledException : RuntimeException("任务已取消")

    /** 环境或素材不支持（缺 codec、尺寸奇数、编码器不认 YUV420Flexible 等）。 */
    class VideoUnsupportedException(message: String) : IllegalArgumentException(message)

    /**
     * @param mask 归一化选区 (0..1)，**相对用户看到的画面**（= 显示坐标系）。
     * @param onProgress (阶段, 已完成, 总数)。阶段见 [PHASE_MOTION] / [PHASE_REPAIR]。
     * @param isCancelled 每帧检查一次。
     */
    fun repair(
        inputPath: String,
        outputPath: String,
        mask: RectF,
        radius: Int,
        trackMotion: Boolean = false,
        onProgress: ((String, Int, Int) -> Unit)? = null,
        isCancelled: (() -> Boolean)? = null,
    ): Map<String, Any> {
        val started = SystemClock.elapsedRealtime()

        // OpenCV 4.9 起官方 Maven 包用 initLocal()，不需要再手动拷 .so 到 jniLibs
        if (!OpenCVLoader.initLocal()) {
            throw IllegalStateException("OpenCV 初始化失败")
        }
        if (!File(inputPath).exists()) {
            throw VideoUnsupportedException("视频不存在：$inputPath")
        }

        val extractor = MediaExtractor()
        val muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var audioExtractor: MediaExtractor? = null
        var muxerClosed = false
        try {
            extractor.setDataSource(inputPath)

            val videoTrack = findVideoTrack(extractor)
                ?: throw VideoUnsupportedException("这个文件里没有视频轨")
            val format = extractor.getTrackFormat(videoTrack)
            extractor.selectTrack(videoTrack)

            val rotation = readInt(format, MediaFormat.KEY_ROTATION, 0)
            val sourceFps = readInt(format, MediaFormat.KEY_FRAME_RATE, 30).coerceIn(1, 120)
            val sourceBitrate = readInt(format, MediaFormat.KEY_BIT_RATE, 0)
            // 容器里记的画面尺寸。**比解码器报的小**：华为把 960x540 解成 960x544
            // （540 不是 16 的倍数，补齐到 544），多出来的 4 行是 padding。
            // 按源尺寸出片，成品才和原件同分辨率。
            val sourceWidth = readInt(format, MediaFormat.KEY_WIDTH, 0)
            val sourceHeight = readInt(format, MediaFormat.KEY_HEIGHT, 0)

            // ---- 音轨先挂上去：MediaMuxer 要求所有 track 在 start() 之前 addTrack ----
            // 视频轨的 format 要等编码器吐出第一帧才知道，所以顺序必须是「音频先、视频后、再 start」。
            val audioSetup = openAudioTrack(inputPath, muxer)
            audioExtractor = audioSetup?.extractor
            val audioTrackIndex = audioSetup?.trackIndex

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
                onProgress = onProgress,
                isCancelled = isCancelled,
            )
            val videoStats = transcode.run()

            // ---- 音轨原样搬运 ----
            val audioBytes = if (audioTrackIndex != null && audioExtractor != null) {
                copyAudio(audioExtractor, audioTrackIndex, muxer, transcode.isMuxerStarted())
            } else {
                0L
            }

            // 主动收尾再量体积。MediaMuxer 是带缓冲的，不 stop() 直接读 File.length()
            // 拿到的是「已经刷出去的那部分」—— 踩过：报 1,304,248 B，实际 1,562,172 B。
            muxer.stop()
            muxer.release()
            muxerClosed = true

            val elapsed = SystemClock.elapsedRealtime() - started
            val outFile = File(outputPath)
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
                "maskPixels" to transcode.maskPixels,
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
                "sizeBytes" to outFile.length(),
                "elapsedMs" to elapsed,
            )
            Log.i(
                TAG,
                "repair ok ${transcode.frameWidth}x${transcode.frameHeight} rot=$rotation " +
                    "frames=${videoStats.frames} skipped=${videoStats.skipped} " +
                    "video=${videoStats.bytes}B audio=${audioBytes}B " +
                    "file=${outFile.length()}B ${elapsed}ms",
            )
            return result
        } finally {
            audioExtractor?.release()
            extractor.release()
            if (!muxerClosed) {
                try {
                    muxer.stop()
                } catch (ignored: Throwable) {
                    // 没 start 过就 stop 会抛 IllegalStateException —— 出错路径上正常
                }
                muxer.release()
            }
        }
    }

    // ------------------------------------------------------------------ 转码主体

    private data class VideoStats(val frames: Int, val skipped: Int, val bytes: Long)

    /**
     * 一次转码的状态机。写成类而不是一个大函数，是因为要跨「解码 / 编码 / 封装」三段
     * 共享十几个可变状态，局部变量会膨胀到看不清主流程。
     */
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
        private val onProgress: ((String, Int, Int) -> Unit)?,
        private val isCancelled: (() -> Boolean)?,
    ) {
        // 编码器要等第一帧解码出来才知道准确尺寸，所以全部延迟初始化
        private var encoder: MediaCodec? = null
        private var videoTrackIndex = -1
        private var muxerStarted = false

        var frameWidth = 0
            private set
        var frameHeight = 0
            private set
        var maskPixels = 0
            private set

        /**
         * **可见尺寸**。解码器给的 `Image` 尺寸可能比画面大 —— 华为这颗解码器把 960×540
         * 的流解成 960×544（540 向上对齐到 16 的倍数），多出来的 4 行是 padding。
         *
         * 这是踩过的坑：直接把 `image.height` 当画幅用，色度平面按 960×272 有界，
         * 而我们按 544 行去读，读到第 481 列的偶数列就越界
         * （`index=261120 out of bounds (limit=261120)`）。
         * 正确来源是解码器 outputFormat 的 width/height —— 那才是画面尺寸。
         */
        private var visibleWidth = 0
        private var visibleHeight = 0

        private lateinit var maskMat: Mat
        private lateinit var frameBgr: Mat
        private lateinit var scratch: ByteArray

        // ---- 镜头运动（trackMotion=true 时才动） ----
        /** 用户框在**首帧**坐标系里的四角；每帧用累计变换推一次 */
        private var maskQuad: Array<Point> = emptyArray()
        /** 首帧 → 当前帧的累计相似变换，2×3 行主序 */
        private var cumulative = doubleArrayOf(1.0, 0.0, 0.0, 0.0, 1.0, 0.0)
        private var grayMat: Mat? = null
        /**
         * 当前**关键帧**的灰度 —— 跟踪的基准，不是「上一帧」。
         *
         * 对上一帧估会把每帧的亚像素偏置乘上帧数（150 帧就是 150 次链式累积）；
         * 对关键帧估时，一次增量就能从关键帧直接跳到当前帧，误差只在
         * 「换关键帧的那几次」里累积。
         */
        private var keyGray: Mat? = null
        /** 关键帧自身相对首帧的累计变换。关键帧算出的增量要左乘它。 */
        private var keyCumulative = doubleArrayOf(1.0, 0.0, 0.0, 0.0, 1.0, 0.0)
        /** 距上次换关键帧过了多少帧 */
        private var framesSinceKey = 0
        /** 首帧灰度。只在诊断用：收尾时拿它跟末帧**直接**估一次。 */
        private var firstGray: Mat? = null
        /** 末帧灰度。收尾诊断用（[keyGray] 在跑的过程中会被覆盖）。 */
        private var lastGray: Mat? = null
        var motionOk = 0
        var motionFailed = 0
        /** 关键帧换了多少次。理论下限 = 总帧数 / [MAX_KEY_SPAN]，实际会更多。 */
        var keyframeSwitches = 0
        /** 最后一次估计的内点数。掉到 [MIN_INLIERS_HEALTHY] 以下说明基准帧该换了。 */
        var lastInliers = 0

        /**
         * 关键帧最多用这么多帧就换（兜底）。
         *
         * 主判据其实是位移（[MAX_KEY_SHIFT]）—— 光流跟不跟得住取决于基准帧与
         * 当前帧差了多远，不是隔了几帧。这条只管「镜头几乎不动但场景慢慢变了」
         * 那种情况：特征点会老化、纹理会被替换，硬撑下去估计会退化成噪声。
         */
        private val MAX_KEY_SPAN = 60

        /**
         * 基准帧与当前帧的位移超过这么多原图像素就换关键帧。
         *
         * 工作分辨率是 320 宽（960 宽素材 → 缩 1/3），LK 用 3 层金字塔、
         * winSize 21，能跟住的位移上限约 20px（工作分辨率）。
         * 20px × 3 = 60px 原图，留一点余量取 45px。
         */
        private val MAX_KEY_SHIFT = 45.0

        /**
         * 内点数掉到这个值以下就换关键帧。
         *
         * 自检里干净照片有 190~200 个内点；真实素材纹理弱，几十个是常态。
         * 从 200 掉到 60 意味着已经跟丢了大半特征点，继续用这个基准估就是拿噪声拟合。
         */
        private val MIN_INLIERS_HEALTHY = 60

        // ---- 诊断：逐帧累加 vs 首末帧直接估计 ----
        /** 首帧 ↔ 末帧直接估计出来的平移（像素）；不累积，所以没有漂移。 */
        var directShiftPx = 0.0
        var directScale = 1.0
        var directOk = false
        /** 累计平移与直接平移之差的模长。接近 0 说明累加是诚实的。 */
        var driftPx = 0.0

        // ---- 快路径：整块搬运 + OpenCV cvtColor，避免逐像素 Kotlin 循环 ----
        /** 打包成 NV12 的连续缓冲（Y 全部 + UV 交错），长度 = w*h*3/2。按画幅懒分配。 */
        private var packed = ByteArray(0)
        /** 把 packed 当 Mat 用，避免每帧新建（OpenCV 侧要的是 (h*3/2) x w 的单通道） */
        private var packedMat: Mat? = null
        /** BGR → I420 的中间结果（planar）；前 h 行是 Y，后面两块是 U/V */
        private var i420Mat: Mat? = null
        /** U/V 合并成的双通道矩阵，内存布局就是 NV12 的 UV 平面 */
        private var uvMat: Mat? = null
        /** uvMat 的字节快照，长度 w*h/2 */
        private var uvBytes = ByteArray(0)
        /** 解码帧的 UV 是「U 在前」(NV12) 还是「V 在前」(NV21) */
        private var decoderUFirst = true
        /** 编码器输入缓冲的 UV 顺序，可能与解码器不同 */
        private var encoderUFirst = true
        private var decoderUvProbed = false
        private var decoderUvVerified = false
        private var encoderUvProbed = false
        /** 首帧自检都没过 → 整条快路径不可信，永久退回逐像素（慢但一定对） */
        private var fastPathBroken = false

        private var decoded = 0
        private var skipped = 0
        private var videoBytes = 0L
        private var loggedGeometry = false
        private var loggedEncoderGeometry = false

        // ---- 两趟化（只有 trackMotion=true 时才有第一趟） ----
        /**
         * 第一趟的产物：每帧相对首帧的累计相似变换（2×3 行主序）。
         * 第二趟按帧号直接查表，不再跑光流。为空表示没有第一趟（静止水印）。
         */
        private var motionTable: List<DoubleArray>? = null
        /** 第一趟数出来的真帧数。0 表示没数过，进度只能用估计值。 */
        private var trackedFrames = 0
        /** 进度条的分母：有真帧数就用真的。 */
        private var progressTotal = 0

        // 分段耗时累计（毫秒），每 30 帧打一行
        private var tDecode = 0L
        private var tTrack = 0L
        private var tInpaint = 0L
        private var tEncode = 0L

        /** 打一次平面几何：Image 尺寸 vs 实际画幅、每个平面的 stride 与容量。 */
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

        /** 首帧 → 末帧的累计平移（像素）。开了 trackMotion 才有意义。 */
        val cumulativeShiftPx: Double
            get() = Math.sqrt(cumulative[2] * cumulative[2] + cumulative[5] * cumulative[5])

        /**
         * 累计平移的 X / Y 分量。
         *
         * 只给模长没法断言方向 —— 真值 (-298, -149) 和 (+298, +149) 的模长一样，
         * 但前者是内容往左上走、后者往右下走，完全是两回事。
         */
        val cumulativeShiftX: Double get() = cumulative[2]
        val cumulativeShiftY: Double get() = cumulative[5]

        /** 首帧 → 末帧的累计缩放（1.0 表示没有缩放）。 */
        val cumulativeScale: Double
            get() = Math.sqrt(cumulative[0] * cumulative[0] + cumulative[1] * cumulative[1])

        /**
         * 首帧 → 末帧的累计旋转（度）。
         *
         * 符号约定与 [MotionEstimator.Motion.rotationDeg] 一致（`atan2(m[3], m[0])`）——
         * 两条路径必须用同一个公式，否则「自检里 3° 是正的、累计里变成负的」这种
         * 符号错会被当成算法漂移。
         */
        val cumulativeRotationDeg: Double
            get() = Math.toDegrees(Math.atan2(cumulative[3], cumulative[0]))

        /**
         * 按当前画幅准备打包缓冲与复用的 Mat。
         *
         * 必须是「正好 w×h」：`Mat.put(0, 0, byte[])` 要求数组长度与 Mat 一致，
         * 用 `rawW*rawH` 的缓冲去喂 `w×h` 的 Mat，在「解码尺寸 544 / 画面 540」这种
         * 带对齐 padding 的机型上会直接抛断言。
         */
        private fun ensurePacked(w: Int, h: Int) {
            val need = w * h * 3 / 2
            val current = packedMat
            if (packed.size == need && current != null &&
                current.cols() == w && current.rows() == h * 3 / 2
            ) {
                return
            }
            packed = ByteArray(need)
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
            // 动态水印走两趟：第一趟只算「每一帧相对首帧的变换」，不修也不编。
            // 为什么拆：单趟里「分析镜头运动」和「逐帧修复」是按帧交错的，
            // 一个百分比里混着两件事，文案只能笼统写「逐帧修复」。
            // 拆开之后第一趟数出的是**真帧数**，第二趟的百分比才不是「约」。
            // 代价是一次额外解码 —— 实测 960x540/150 帧解码只要 373ms，
            // 而 inpaint 占整条任务的 92%（23.6s / 25.7s），多这一趟可以忽略。
            if (trackMotion) {
                analyzeMotionPass()
                extractor.seekTo(0, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                // 第二个解码器未必与第一个同 UV 顺序，让它自己再自检一次
                decoderUvProbed = false
                decoderUvVerified = false
                fastPathBroken = false
            }
            progressTotal = if (trackedFrames > 0) trackedFrames else estimatedFrames
            return repairPass()
        }

        /**
         * 第一趟：解码全片，只算镜头运动。
         *
         * 不 inpaint、不建编码器 —— 这一趟要快，让用户先看到「在分析」。
         * 每帧存一份 2×3 变换（6 个 double，48 B/帧；150 帧约 7 KB）。
         */
        private fun analyzeMotionPass() {
            val mime = decoderFormat.getString(MediaFormat.KEY_MIME)
                ?: throw VideoUnsupportedException("视频轨没有 MIME")
            val decoder = MediaCodec.createDecoderByType(mime)
            decoder.configure(decoderFormat, null, null, 0)
            decoder.start()

            val decInfo = MediaCodec.BufferInfo()
            var inputDone = false
            var done = false
            val table = ArrayList<DoubleArray>()
            val mark0 = SystemClock.elapsedRealtime()

            try {
                while (!done) {
                    if (isCancelled?.invoke() == true) throw VideoCancelledException()

                    if (!inputDone) {
                        val inIndex = decoder.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
                        if (inIndex >= 0) {
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
                        val out = decoder.outputFormat
                        visibleWidth = readInt(out, MediaFormat.KEY_WIDTH, 0)
                        visibleHeight = readInt(out, MediaFormat.KEY_HEIGHT, 0)
                        Log.i(TAG, "analyze decoder output ${visibleWidth}x$visibleHeight")
                    }
                    if (decIndex >= 0) {
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
                                // 这一趟的分母只能是估计值：真帧数要等它跑完才知道
                                if (table.size % PROGRESS_EVERY == 0) {
                                    onProgress?.invoke(PHASE_MOTION, table.size, estimatedFrames)
                                }
                            }
                        }
                        decoder.releaseOutputBuffer(decIndex, false)
                        if (eos) done = true
                    }
                }
            } finally {
                try {
                    decoder.stop()
                } catch (ignored: Throwable) {
                }
                decoder.release()
            }

            if (table.isEmpty()) {
                throw VideoUnsupportedException("一帧都没解出来（解码器 $mime 可能不支持这个编码）")
            }

            motionTable = table
            trackedFrames = table.size
            // 收尾诊断必须放在这一趟末尾：它比的是首帧与末帧的灰度，这两份 Mat
            // 正是这一趟填的；放到第二趟末尾会比到同一份数据，白跑。
            computeDirectMotion()
            onProgress?.invoke(PHASE_MOTION, table.size, table.size)
            Log.i(
                TAG,
                "motion pass done frames=${table.size} keyframes=$keyframeSwitches " +
                    "ok=$motionOk fail=$motionFailed cost=${SystemClock.elapsedRealtime() - mark0}ms",
            )
        }

        /** 第一趟的单帧：解码帧 → BGR，只为喂运动估计。不修复、不编码。 */
        private fun analyzeFrame(image: Image) {
            val size = resolveFrameSize(image)
            ensureFrameBuffers(size.first, size.second)
            yuvToBgr(image, frameBgr, scratch, frameWidth, frameHeight)
            updateMaskByMotion(applyToMask = false)
        }

        private fun repairPass(): VideoStats {
            val mime = decoderFormat.getString(MediaFormat.KEY_MIME)
                ?: throw VideoUnsupportedException("视频轨没有 MIME")
            val decoder = MediaCodec.createDecoderByType(mime)
            decoder.configure(decoderFormat, null, null, 0)
            decoder.start()

            val decInfo = MediaCodec.BufferInfo()
            val encInfo = MediaCodec.BufferInfo()
            var decoderInputDone = false
            var decoderDone = false
            var encoderDone = false

            try {
                while (!decoderDone || !encoderDone) {
                    if (isCancelled?.invoke() == true) throw VideoCancelledException()

                    // 1) 喂解码器
                    if (!decoderInputDone) {
                        val inIndex = decoder.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
                        if (inIndex >= 0) {
                            val buffer = decoder.getInputBuffer(inIndex)
                            val size = if (buffer == null) -1 else extractor.readSampleData(buffer, 0)
                            if (buffer == null || size < 0) {
                                decoder.queueInputBuffer(
                                    inIndex, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                                )
                                decoderInputDone = true
                            } else {
                                // PTS 原样带过去 —— 这是全链路唯一可信的时间来源
                                decoder.queueInputBuffer(inIndex, 0, size, extractor.sampleTime, 0)
                                extractor.advance()
                            }
                        }
                    }

                    // 2) 取解码帧 → 修复 → 喂编码器
                    val decIndex = decoder.dequeueOutputBuffer(decInfo, DEQUEUE_TIMEOUT_US)
                    if (decIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        // 这里报的宽高才是**画面**尺寸；Image 的宽高可能带对齐 padding
                        val out = decoder.outputFormat
                        visibleWidth = readInt(out, MediaFormat.KEY_WIDTH, 0)
                        visibleHeight = readInt(out, MediaFormat.KEY_HEIGHT, 0)
                        Log.i(TAG, "decoder output ${visibleWidth}x$visibleHeight")
                    }
                    if (decIndex >= 0) {
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
                                    encodeFrame(image, decInfo.presentationTimeUs)
                                } finally {
                                    image.close()
                                }
                            } else {
                                // 表面上看是「帧丢了」，其实多数是厂商解码器给了个空 buffer。
                                // 计数出来，真丢多了说明这条通路在这个机型上不可用。
                                skipped++
                            }
                        }
                        decoder.releaseOutputBuffer(decIndex, false)
                        if (eos) {
                            decoderDone = true
                            signalEncoderEos()
                        }
                    }

                    // 3) 收编码结果 → 写 muxer
                    if (!encoderDone && drainEncoder(encInfo)) {
                        encoderDone = true
                    }
                }

                // 收尾诊断（首帧 ↔ 末帧直接估一次）不在这里做：开了跟踪时第一趟末尾
                // 已经算过，而那一趟的 firstGray/lastGray 才是「末帧」的真值。
                // 静止水印（没第一趟）根本没有灰度序列，算了也是空。
            } finally {
                try {
                    decoder.stop()
                } catch (ignored: Throwable) {
                }
                decoder.release()
                encoder?.let {
                    try {
                        it.stop()
                    } catch (ignored: Throwable) {
                    }
                    it.release()
                }
                encoder = null
                if (this::maskMat.isInitialized) maskMat.release()
                if (this::frameBgr.isInitialized) frameBgr.release()
                packedMat?.release()
                packedMat = null
                i420Mat?.release()
                i420Mat = null
                uvMat?.release()
                uvMat = null
                grayMat?.release()
                grayMat = null
                keyGray?.release()
                keyGray = null
                lastGray?.release()
                lastGray = null
                firstGray?.release()
                firstGray = null
            }

            if (decoded == 0) {
                throw VideoUnsupportedException("一帧都没解出来（解码器 $mime 可能不支持这个编码）")
            }
            if (!muxerStarted) {
                throw VideoUnsupportedException("编码器没有产出视频轨，无法封装")
            }
            return VideoStats(frames = decoded, skipped = skipped, bytes = videoBytes)
        }

        /** 第一帧到了才知道准确尺寸，这里一次性把编码器、Mask、复用缓冲都建好。 */
        private fun ensureEncoder(rawW: Int, rawH: Int) {
            if (encoder != null) return
            if (rawW % 2 != 0 || rawH % 2 != 0) {
                throw VideoUnsupportedException("暂不支持奇数尺寸（${rawW}x$rawH）")
            }

            val bitrate = if (sourceBitrate > 0) {
                sourceBitrate
            } else {
                // 源文件没报码率时给个保守值：0.12 bit/像素 ≈ 720p30 约 3Mbps，肉眼够用
                (rawW * rawH * frameRate * 0.12).toInt().coerceIn(1_000_000, 20_000_000)
            }

            val format = MediaFormat.createVideoFormat(MIME_VIDEO, rawW, rawH)
            format.setInteger(
                MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible,
            )
            format.setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
            format.setInteger(MediaFormat.KEY_FRAME_RATE, frameRate)
            // 1 秒一个关键帧：让成品可以随便拖动，代价是体积略大
            format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)

            val codec = MediaCodec.createEncoderByType(MIME_VIDEO)
            try {
                codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            } catch (e: Throwable) {
                codec.release()
                throw VideoUnsupportedException(
                    "编码器不接受 YUV420Flexible（${e.javaClass.simpleName}: ${e.message}）",
                )
            }
            codec.start()

            encoder = codec

            maskMat = buildMask(rawW, rawH)
            maskPixels = countMaskPixels(maskMat)
            ensureFrameBuffers(rawW, rawH)
            Log.i(TAG, "encoder ready ${rawW}x$rawH bitrate=$bitrate fps=$frameRate mask=$maskPixels px")
        }

        /**
         * 画幅优先级：容器里的源尺寸 > 解码器 outputFormat > Image 尺寸。
         * 三者都可能带 padding，所以都要先夹在 Image 尺寸以内。
         */
        private fun resolveFrameSize(image: Image): Pair<Int, Int> {
            val vw = when {
                sourceWidth in 1..image.width -> sourceWidth
                visibleWidth in 1..image.width -> visibleWidth
                else -> image.width
            }
            val vh = when {
                sourceHeight in 1..image.height -> sourceHeight
                visibleHeight in 1..image.height -> visibleHeight
                else -> image.height
            }
            return vw to vh
        }

        /**
         * 逐帧都要的 CPU 侧缓冲。
         *
         * 与 [ensureEncoder] 分开的理由：第一趟只解码、不建编码器，但一样要这两块。
         * 尺寸没变就复用 —— 两趟之间画幅必然相同，不该重分配一遍 1.5 倍画幅的内存。
         */
        private fun ensureFrameBuffers(w: Int, h: Int) {
            if (frameWidth == w && frameHeight == h && this::frameBgr.isInitialized) return
            frameWidth = w
            frameHeight = h
            if (this::frameBgr.isInitialized) frameBgr.release()
            frameBgr = Mat(h, w, CvType.CV_8UC3)
            scratch = ByteArray(w * h * 3)
            ensurePacked(w, h)
        }

        private fun encodeFrame(image: Image, ptsUs: Long) {
            val size = resolveFrameSize(image)
            ensureEncoder(size.first, size.second)
            // 只在第一帧打一次平面几何：YUV 相关的 bug 全靠这几个数字定位，
            // 没有它们只能靠猜（那一次就是这么浪费掉的）。
            if (!loggedGeometry) {
                loggedGeometry = true
                logGeometry("decoder", image, frameWidth, frameHeight)
            }

            val codec = encoder ?: error("编码器未初始化")
            var inIndex = -1
            repeat(5) {
                if (inIndex < 0) inIndex = codec.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
            }
            if (inIndex < 0) throw IllegalStateException("编码器 50ms 内没给出空闲输入缓冲")

            // getInputImage 而不是 getInputBuffer：前者把「平面 + stride」摊给你，
            // 后者拿到的是一块布局未定义的裸内存，写进去颜色一定错。
            val inImage = try {
                codec.getInputImage(inIndex)
            } catch (e: Throwable) {
                Log.w(TAG, "getInputImage 抛异常：${e.message}")
                null
            } ?: throw VideoUnsupportedException(
                "编码器 ${codec.name} 不支持 getInputImage，需要改走 Surface 通路",
            )
            if (!loggedEncoderGeometry) {
                loggedEncoderGeometry = true
                logGeometry("encoder", inImage, frameWidth, frameHeight)
            }

            // 三段分别计时。上一轮只知道「150 帧 57 秒」，看不出是哪一段慢 ——
            // 这种时候加计数器比猜有用。
            var mark = SystemClock.elapsedRealtime()
            // 解码帧 → BGR（只取可见区域，padding 丢掉）
            yuvToBgr(image, frameBgr, scratch, frameWidth, frameHeight)
            tDecode += SystemClock.elapsedRealtime() - mark
            mark = SystemClock.elapsedRealtime()
            // 镜头运动：把 Mask 推到当前帧。必须在 inpaint 之前。
            // 两趟化之后这里是**查表**，不再跑光流 —— 轨迹在第一趟就算完了。
            if (trackMotion) {
                applyTrackedMotion()
                tTrack += SystemClock.elapsedRealtime() - mark
                mark = SystemClock.elapsedRealtime()
            }
            // 与图片路径同一份修复逻辑（共用 ImageProcessor.inpaintBgr）
            val repaired = ImageProcessor.inpaintBgr(frameBgr, maskMat, radius)
            tInpaint += SystemClock.elapsedRealtime() - mark
            mark = SystemClock.elapsedRealtime()
            try {
                // 编码器的输入 Image 也可能比画幅大，这里同样只写可见区域
                bgrToYuv(repaired, inImage, scratch, frameWidth, frameHeight)
            } finally {
                repaired.release()
            }

            // 尺寸必须与编码器 configure 时一致，否则这个 buffer 大小对不上
            val bytes = frameWidth * frameHeight * 3 / 2
            codec.queueInputBuffer(inIndex, 0, bytes, ptsUs, 0)
            tEncode += SystemClock.elapsedRealtime() - mark

            decoded++
            if (decoded % 30 == 0) {
                val tx = Math.round(cumulative[2] * 100) / 100.0
                val ty = Math.round(cumulative[5] * 100) / 100.0
                Log.i(
                    TAG,
                    "perf ${decoded}f decode=${tDecode}ms track=${tTrack}ms " +
                        "inpaint=${tInpaint}ms encode=${tEncode}ms " +
                        "cum=[$tx, $ty] motion=${motionOk}ok/${motionFailed}fail " +
                        "keyframes=$keyframeSwitches inliers=$lastInliers",
                )
            }
            if (decoded % PROGRESS_EVERY == 0) {
                onProgress?.invoke(PHASE_REPAIR, decoded, progressTotal)
            }
        }

        private fun signalEncoderEos() {
            val codec = encoder ?: return
            var index = -1
            repeat(5) {
                if (index < 0) index = codec.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
            }
            if (index >= 0) {
                codec.queueInputBuffer(index, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            }
        }

        /** @return true 表示编码器已经吐完 EOS */
        private fun drainEncoder(info: MediaCodec.BufferInfo): Boolean {
            val codec = encoder ?: return false
            while (true) {
                val index = codec.dequeueOutputBuffer(info, 0)
                if (index == MediaCodec.INFO_TRY_AGAIN_LATER) return false
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    // 视频轨的 format 到这一刻才确定。必须在 muxer.start() 之前 addTrack。
                    videoTrackIndex = muxer.addTrack(codec.outputFormat)
                    // 旋转信息写进容器，而不是重排像素 —— 播放器自己会转
                    muxer.setOrientationHint(rotation)
                    muxer.start()
                    muxerStarted = true
                    continue
                }
                if (index < 0) continue

                if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                    // SPS/PPS 已经随 format 一起进 muxer 了，这份是重复的
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

        /**
         * 归一化选区（显示坐标系）→ 帧坐标系里的像素矩形。
         *
         * 三个坐标系的顺序是：UI 手势 → 显示矩形 → 归一化 0..1（唯一对外格式）。
         * 到了 native 这边，归一化坐标要**逆着 rotation 转回去**，才能落在解码帧上。
         *
         * 以 rotation=90（顺时针转 90° 才是正的）为例：帧上一点 (x,y) 转到显示坐标系是
         * (frameH-1-y, x)。反解就是 x = v*frameW、y = (1-u)*frameH。
         * 四种情况都是仿射，矩形转完仍然是轴对齐矩形，不用做多边形。
         */
        private fun mapMaskToFrame(rect: RectF, rot: Int, w: Int, h: Int): FracRect {
            // 先按 0..1 夹紧，UI 那边可能因为手势误差给出 -0.001 这种值
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

        private fun buildMask(w: Int, h: Int): Mat {
            val frac = mapMaskToFrame(normalizedMask, rotation, w, h)
            val left = (frac.left * w).toInt().coerceIn(0, w - 1)
            val top = (frac.top * h).toInt().coerceIn(0, h - 1)
            val right = (frac.right * w).toInt().coerceIn(left + 1, w)
            val bottom = (frac.bottom * h).toInt().coerceIn(top + 1, h)

            // 四角要存下来：开镜头运动跟踪后，每帧都从**这一份**原始框重新推导 Mask
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

        /**
         * 首帧 ↔ 末帧的**直接**估计（不累积），作为逐帧累加的对照。
         *
         * 为什么需要它：光流有系统性的亚像素偏置，逐帧累加会把偏置乘上帧数。
         * 一段「几乎静止」的素材上如果累计出几十像素，光看累计值无法判断
         * 是素材真在动还是算法在飘 —— 必须有一个不含累积的独立参照。
         */
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
                    "inliers=${direct.inliers} | " +
                    "cumulative shift=${"%.2f".format(cumulativeShiftPx)}px " +
                    "drift=${"%.2f".format(driftPx)}px | " +
                    "keyframes=$keyframeSwitches lastInliers=$lastInliers",
            )
        }

        /**
         * 用全局运动把 Mask 推到当前帧。
         *
         * **基准帧是关键帧，不是上一帧。** 早先的写法是「对上一帧估、把增量乘进累计」，
         * 150 帧就是 150 次链式累积。现在每次增量都直接从关键帧算，
         * 误差只在换关键帧的那几次里传递（150 帧约 2~7 次）。
         *
         * PC 端等价复现（同 OpenCV 4.14.0、同参数）在真值素材上的收益：
         * 末帧对齐首帧的 MAE，平移 14.70→1.52、变焦 7.16→2.93、抖动 10.11→3.85。
         *
         * ⚠ **适用前提：场景刚性 + 相机在动。** 相似变换只有 4 个自由度，装不下
         * 画面内容本身的变形。实测 `sample.mp4`（花瓣绽放）上 f0↔f149：
         * 相似 15.60 dB、仿射 13.34 dB、单应 11.83 dB —— **自由度越高越差**，
         * 而且都约等于「完全不对齐」的 16.25 dB。这类素材上跟随必然偏，
         * 靠调阈值或换模型都救不了，只能让用户关掉它（UI 上的「水印静止」）。
         *
         * 跟踪失败（纹理太弱、光流跟不上）时**保持上一帧的变换**，不清零 ——
         * 清零等于让 Mask 突然跳回原位，画面上会看到「修到一半水印跳出来」。
         *
         * @param applyToMask 是否顺手把结果画进 Mask。第一趟只算轨迹、不修图，
         *   这时 Mask 还没建（`maskMat` 是 `lateinit`），不能碰。
         */
        private fun updateMaskByMotion(applyToMask: Boolean = true) {
            val gray = grayMat ?: Mat(frameHeight, frameWidth, CvType.CV_8UC1).also {
                grayMat = it
            }
            Imgproc.cvtColor(frameBgr, gray, Imgproc.COLOR_BGR2GRAY)

            // 末帧留一份给收尾诊断（keyGray 在过程中会被覆盖）。
            // 注意不能写成 `lastGray?.let { ... } ?: run { ... }` —— let 返回的是
            // copyTo 的 Mat（非 null），?: 分支永远走不到，lastGray 会一直是 null。
            val lg = lastGray
            if (lg == null) lastGray = Mat().also { gray.copyTo(it) } else gray.copyTo(lg)

            val key = keyGray
            if (key == null) {
                // 首帧：它自己就是关键帧，累计变换是单位矩阵
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
                // 关键帧 → 当前帧的增量，左乘关键帧自身的累计
                cumulative = MotionEstimator.compose(keyCumulative, motion.m)
            } else {
                // 不采信：要么完全失败，要么内点太少（拟合出来的是噪声）。
                // 两种情况都保持上一帧的变换，并立刻换基准帧重新抓一次特征。
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

        /**
         * 第二趟：直接查第一趟存下来的轨迹，把 Mask 推到**当前帧**。
         *
         * 查不到（表比实际帧数短，或者压根没有第一趟）就保持上一帧的变换 ——
         * 与「跟踪失败」同一策略：宁可停在原地，也不让 Mask 跳回首帧位置。
         */
        private fun applyTrackedMotion() {
            val table = motionTable ?: return
            if (decoded !in table.indices) return
            cumulative = table[decoded]
            drawMaskQuad()
        }

        /**
         * 把当前帧升成新关键帧。
         *
         * 注意 `keyCumulative` 取的是**当前**累计变换 —— 也就是说新关键帧
         * 接管了「首帧 → 现在」的全部历史，之后每一帧都相对它算增量。
         * 这一步是唯一的误差传递点，所以换得越少越好（但不能不换，
         * 否则帧间位移超出光流的能力）。
         */
        private fun promoteKeyframe(gray: Mat) {
            val key = keyGray ?: Mat().also { keyGray = it }
            gray.copyTo(key)
            keyCumulative = cumulative.copyOf()
            framesSinceKey = 0
            keyframeSwitches++
        }

        /** 把首帧的框按累计变换推到当前帧，重画 Mask（四边形，fillConvexPoly）。 */
        private fun drawMaskQuad() {
            if (maskQuad.isEmpty()) return
            val pts = Array(maskQuad.size) { i ->
                val p = maskQuad[i]
                Point(
                    cumulative[0] * p.x + cumulative[1] * p.y + cumulative[2],
                    cumulative[3] * p.x + cumulative[4] * p.y + cumulative[5],
                )
            }
            // 变换可能把框推出画面（镜头大幅平移），fillConvexPoly 会自己裁
            maskMat.setTo(Scalar(0.0))
            Imgproc.fillConvexPoly(maskMat, MatOfPoint(*pts), Scalar(255.0))
        }

        private fun countMaskPixels(mat: Mat): Int = Core.countNonZero(mat)

        /** 帧坐标系里的归一化矩形（0..1）。 */
        private data class FracRect(val left: Double, val top: Double, val right: Double, val bottom: Double)

        // ------------------------------------------------------------------ YUV ↔ BGR

        /**
         * YUV_420_888 → BGR。
         *
         * ## 为什么有两条路
         *
         * 手写逐像素循环（[yuvToBgrSlow]）在 debug 构建下慢得离谱：960×540 一帧要 **122 ms**，
         * 150 帧就是 18 秒。原因是这个循环在 ART 里基本是**解释执行**的 —— 方法只被调用 150 次，
         * 远不到 JIT 的编译阈值，而热点在方法内部的循环里，OSR 也没进来。
         * 从 30 帧到 150 帧每帧耗时一模一样（122.3 / 122.9 / 119.3 / 119.7 / 120.9 ms），
         * 完全没有预热曲线 —— 这就是「一直是解释执行」的证据。
         *
         * ## 快路径怎么绕开它
         *
         * 只要平面是 semi-planar（`pixelStride == 2`，即 NV12/NV21），**内存里 UV 本来就是
         * 交错存放的**，那就根本不需要逐像素解交织 —— 把 Y 和 UV 按行整块 memcpy 进一个连续缓冲，
         * 拼成标准 NV12，交给 `Imgproc.cvtColor` 在 C++ 里做。Kotlin 只做 memcpy，谁都能快。
         *
         * 剩一个问题：NV12 是 U 在前、NV21 是 V 在前，Android 不告诉你。
         * 见 [detectUFirst]（按平面偏移判断）与 [spotCheckDecode]（解完再抽查，**判断错了一定会被抓**）。
         *
         * planar（`pixelStride == 1`，I420）走不了这条路（解交织必须逐字节），继续用老循环。
         * **那条分支在本机没被走过**（这台机器的编解码器都是 semi-planar），保持原实现不动。
         *
         * [w]/[h] 传**可见尺寸**而不是 `image.width/height`：Image 可能带编码对齐的 padding。
         */
        private fun yuvToBgr(image: Image, dst: Mat, scratch: ByteArray, w: Int, h: Int) {
            val planes = image.planes
            val semiPlanar = planes[1].pixelStride == 2 && planes[2].pixelStride == 2
            if (fastPathBroken || !semiPlanar || planes[0].pixelStride != 1) {
                yuvToBgrSlow(image, dst, scratch, w, h)
                return
            }

            ensurePacked(w, h)
            val mat = packedMat ?: error("packedMat 未初始化")

            // Y：每行 w 字节，行间可能有 padding，所以要逐行拷
            val yBuf = planes[0].buffer
            val yRow = planes[0].rowStride
            for (y in 0 until h) {
                yBuf.position(y * yRow)
                yBuf.get(packed, y * w, w)
            }

            if (!decoderUvProbed) {
                decoderUvProbed = true
                decoderUFirst = detectUFirst(planes[1].buffer, planes[2].buffer)
                Log.i(TAG, "decoder UV order probed → uFirst=$decoderUFirst (NV12=${decoderUFirst})")
            }
            packDecodeUv(planes, decoderUFirst, w, h)

            mat.put(0, 0, packed)
            Imgproc.cvtColor(mat, dst, decodeCvt(decoderUFirst))

            // 首帧自检。探测器靠「平面内存偏移」这个隐含前提，一旦这个前提不成立，
            // 结果是「颜色错了但没有任何异常」—— 最坏的一类 bug。所以解完立刻抽查几个像素，
            // 拿慢速公式的结果对照。对不上就翻转顺序再试一次；还不对就永久退回慢路径。
            if (!decoderUvVerified) {
                decoderUvVerified = true
                if (!spotCheckDecode(image, dst, w, h)) {
                    decoderUFirst = !decoderUFirst
                    packDecodeUv(planes, decoderUFirst, w, h)
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
        }

        private fun decodeCvt(uFirst: Boolean) =
            if (uFirst) Imgproc.COLOR_YUV2BGR_NV12 else Imgproc.COLOR_YUV2BGR_NV21

        /**
         * 把 UV 平面按行整块拷进 [packed] 的尾部。
         *
         * **起点必须选对**：semi-planar 下两个平面互为 ±1 字节偏移，哪个平面是「第 0 字节」取决于
         * UV 顺序。U 在前 → U 平面起点就是 UV 区起点，读它就得到 `U0 V0 U1 V1…`；
         * V 在前 → 得从 V 平面读，才是 `V0 U0 V1 U1…`。读错平面等于整块右移一个字节，
         * 色度全歪，但画幅、时长、帧数**全都正常** —— 只有颜色不对。
         */
        private fun packDecodeUv(planes: Array<Image.Plane>, uFirst: Boolean, w: Int, h: Int) {
            val plane = if (uFirst) planes[1] else planes[2]
            val uvBuf = plane.buffer
            val uvRow = plane.rowStride
            val uvBase = w * h
            for (y in 0 until h / 2) {
                uvBuf.position(y * uvRow)
                uvBuf.get(packed, uvBase + y * w, w)
            }
        }

        /**
         * 判断 UV 交错区里 **U 在前面还是 V 在前面**。
         *
         * Android 只保证 `planes[1]` 是 U、`planes[2]` 是 V，但**内存先后**两种都可能：
         * NV12 是 `U0 V0 U1 V1…`，NV21 是 `V0 U0 V1 U1…`，两个 buffer 互为 ±1 字节偏移。
         *
         * 用「同一字节是否被两个平面同时看到」来判：
         * - U 在前 → `u[2i+1]` 与 `v[2i]` 是同一个字节（都是 V_i）；
         * - V 在前 → `v[2i+1]` 与 `u[2i]` 是同一个字节（都是 U_i）。
         *
         * 色度本身很平滑，「相邻两个色度值相等」会带来误判，所以两个条件**同时成立的点记作无效票**
         * （说明这片区域太平，判不出来），只统计只有一边成立的点。全无效时按 NV12 处理（常见情况），
         * 真错了还有 [spotCheckDecode] 兜底。
         */
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
                val u0 = uBuf.get(base).toInt() and 0xFF       // U_i（若 U 在前）
                val u1 = uBuf.get(base + 1).toInt() and 0xFF   // V_i（若 U 在前）
                val v0 = vBuf.get(base).toInt() and 0xFF       // V_i（若 U 在前）
                val v1 = vBuf.get(base + 1).toInt() and 0xFF   // U_{i+1}（若 U 在前）
                val uFirst = u1 == v0
                val vFirst = v1 == u0
                if (uFirst && !vFirst) votesU++ else if (vFirst && !uFirst) votesV++
            }
            return votesU >= votesV
        }

        /**
         * 解码自检：挑 5 个分散的点，用慢速公式（BT.601 定点）重算一次，与快路径解出的 BGR 比。
         *
         * 容差 12：OpenCV 内部用定点 + 更好的舍入，与这里的整数系数有 1~2 的差，留点余量。
         * 这不是在验证 OpenCV，是在验证**我自己对 UV 布局的假设** —— 假设错了，RB 互换，
         * 三个通道里至少有一个会偏出去几十上百。
         */
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

        /** 手写逐像素版本。planar（I420）走这条；semi-planar 在快路径被否掉时也走这条。 */
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
                // 色度是按 2x2 下采样过的，行号、列号都要除 2
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
                    // 定点 BT.601（整数系数 = 浮点系数 × 256）
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

        /**
         * BGR → 编码器的 YUV_420_888（semi-planar）。
         *
         * ## 为什么不是一句 cvtColor
         *
         * OpenCV **只提供解码方向**的 NV12 转换（`COLOR_YUV2BGR_NV12`），反向的
         * `COLOR_BGR2YUV_NV12` **根本不存在** —— 写了是编译错误，不是运行时报错。
         *
         * 所以拆成两步，两步都在 C++ 里：
         * 1. `cvtColor(bgr, i420, COLOR_BGR2YUV_I420)` —— 得到 Y、U 平面、V 平面三块；
         * 2. `Core.merge(listOf(u, v))` —— 两个单通道平面合成双通道矩阵，
         *    内存布局就是 `U0 V0 U1 V1…`，正好是 NV12 的 UV 平面。
         *
         * Kotlin 侧只有两次整块 memcpy 加按行写平面，一个像素都不碰。
         * （逐像素版本 [bgrToYuvSlow] 是 122 ms/帧，见 [yuvToBgr] 的说明。）
         *
         * 注意两边要**各自判** UV 顺序：解码器的 NV12 不代表编码器也是 NV12。
         * 编码器输入缓冲里是垃圾数据，内容上判不出来，所以用 [probeEncoderUFirst] 自己造证据。
         *
         * 另外 **不能用** `buffer.put(index, src, off, len)` —— 那是 Java 13 才加的绝对批量写，
         * Android 上要 API 33 才有，真机（API 29）会直接 `NoSuchMethodError`。
         * 这里一律改成「先 position 再 put」，API 1 就有。
         */
        private fun bgrToYuv(src: Mat, image: Image, scratch: ByteArray, w: Int, h: Int) {
            val planes = image.planes
            val semiPlanar = planes[1].pixelStride == 2 && planes[2].pixelStride == 2
            if (fastPathBroken || !semiPlanar || planes[0].pixelStride != 1) {
                bgrToYuvSlow(src, image, scratch, w, h)
                return
            }

            ensurePacked(w, h)
            val i420 = i420Mat ?: error("i420Mat 未初始化")
            val uv = uvMat ?: error("uvMat 未初始化")

            if (!encoderUvProbed) {
                encoderUvProbed = true
                encoderUFirst = probeEncoderUFirst(planes)
                Log.i(TAG, "encoder UV order probed → uFirst=$encoderUFirst (NV12=${encoderUFirst})")
            }

            // 1) BGR → I420（C++ SIMD）
            Imgproc.cvtColor(src, i420, Imgproc.COLOR_BGR2YUV_I420)

            // 2) I420 的色度是两块连续平面：第 h 行起 h/4 行是 U，接着 h/4 行是 V。
            //    reshape 成 (h/2)×(w/2) 再 merge 成双通道 → 内存天然交错
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

            i420.get(0, 0, packed)                 // 前 w*h 字节就是 Y 平面
            uv.get(0, 0, uvBytes)                  // w*h/2 字节，已经交错好
            System.arraycopy(uvBytes, 0, packed, w * h, uvBytes.size)

            val yPlane = planes[0]
            // 只写可见区域；padding 铺成中性值，不给硬编码器留上一帧的脏数据
            fillPlane(yPlane.buffer, 16)
            fillPlane(planes[1].buffer, 128)
            fillPlane(planes[2].buffer, 128)

            // rowStride 与宽度相等、且 buffer 装得下时一次写完，否则逐行（行间可能有 padding）
            val yWrite = yPlane.buffer
            if (yPlane.rowStride == w && yWrite.limit() >= w * h) {
                yWrite.clear()
                yWrite.put(packed, 0, w * h)
            } else {
                for (y in 0 until h) {
                    yWrite.position(y * yPlane.rowStride)
                    yWrite.put(packed, y * w, w)
                }
            }

            val uvPlane = if (encoderUFirst) planes[1] else planes[2]
            val uvSibling = (if (encoderUFirst) planes[2] else planes[1]).buffer
            val uvWrite = uvPlane.buffer
            val uvBase = w * h
            val uvRow = uvPlane.rowStride
            val uvLimit = uvWrite.limit()
            for (y in 0 until h / 2) {
                val off = y * uvRow
                val src = uvBase + y * w
                val n = (uvLimit - off).coerceIn(0, w)
                if (n > 0) {
                    uvWrite.position(off)
                    uvWrite.put(packed, src, n)
                }
                // 每个平面的 buffer 都比整块 UV 区短语 1 个字节（两个平面互相 ±1 偏移，
                // 谁也够不到对方那一头）。正常只有最后一个字节会掉进这里，
                // 而它恰好落在**另一个**平面的 buffer 里，用单字节写补上。
                var i = n
                while (i < w) {
                    val abs = off + i
                    if (abs < uvLimit) {
                        uvWrite.put(abs, packed[src + i])
                    } else {
                        uvSibling.put(abs - 1, packed[src + i])
                    }
                    i++
                }
            }
        }

        /**
         * 探测**编码器输入平面**的 UV 顺序。
         *
         * 编码器刚拿到手的 buffer 内容不确定（多半是全 0），没有可用的内容特征，所以自己造：
         * 1. 把 U、V 两个平面都铺成 100（两个平面在同一块内存上，铺完整个 UV 区都是 100）；
         * 2. 在 V 平面的第 0 字节写 200；
         * 3. 看 U 平面的第 1 字节是不是 200。
         *    - 是 → V 平面起点 = U 平面起点 + 1 → 内存是 `U0 V0 U1 V1…` → **NV12**
         *    - 否 → V 平面起点在 U 平面之前 → `V0 U0 V1 U1…` → **NV21**
         * 4. 平面随后会被 [bgrToYuv] 重新铺成中性值并写入真实数据，这里的探测值不会留在成品里。
         */
        private fun probeEncoderUFirst(planes: Array<Image.Plane>): Boolean {
            val uBuf = planes[1].buffer
            val vBuf = planes[2].buffer
            if (uBuf.limit() < 2 || vBuf.limit() < 1) return true
            fillPlane(uBuf, 100)
            fillPlane(vBuf, 100)
            vBuf.put(0, 200.toByte())
            return (uBuf.get(1).toInt() and 0xFF) == 200
        }

        /** 手写逐像素版本（planar 用）。先把整帧读进本地数组，再在数组上换算。 */
        private fun bgrToYuvSlow(src: Mat, image: Image, scratch: ByteArray, w: Int, h: Int) {
            val planes = image.planes
            val yPlane = planes[0]
            val uPlane = planes[1]
            val vPlane = planes[2]

            fillPlane(yPlane.buffer, 16)
            fillPlane(uPlane.buffer, 128)
            fillPlane(vPlane.buffer, 128)

            src.get(0, 0, scratch)

            var p = 0
            for (y in 0 until h) {
                val yBase = y * yPlane.rowStride
                val uBase = (y shr 1) * uPlane.rowStride
                val vBase = (y shr 1) * vPlane.rowStride
                for (x in 0 until w) {
                    val b = scratch[p].toInt() and 0xFF
                    val g = scratch[p + 1].toInt() and 0xFF
                    val r = scratch[p + 2].toInt() and 0xFF
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

        /** 把整个平面填成同一个值（覆盖 stride padding）。 */
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
    )

    /** 找到音频轨并把它 addTrack 到 muxer（必须在 start() 之前）。没有音轨返回 null。 */
    private fun openAudioTrack(inputPath: String, muxer: MediaMuxer): AudioSetup? {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(inputPath)
            for (i in 0 until extractor.trackCount) {
                val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
                if (!mime.startsWith(MIME_AUDIO)) continue
                val trackIndex = muxer.addTrack(extractor.getTrackFormat(i))
                extractor.selectTrack(i)
                Log.i(TAG, "audio track $i mime=$mime")
                return AudioSetup(extractor, trackIndex)
            }
            Log.i(TAG, "源文件没有音轨，输出只有视频")
            extractor.release()
            return null
        } catch (e: Throwable) {
            extractor.release()
            throw e
        }
    }

    /**
     * 音轨透传：压缩数据逐条搬过去，不解码。
     *
     * 需要注意 sampleFlags —— MediaExtractor 的 SAMPLE_FLAG_SYNC(1) 和
     * MediaCodec 的 BUFFER_FLAG_KEY_FRAME(1) 恰好同值，所以直接透传是合法的。
     *
     * @param muxerStarted muxer 没 start 过就不能写，写了会抛 IllegalStateException
     */
    private fun copyAudio(
        extractor: MediaExtractor,
        trackIndex: Int,
        muxer: MediaMuxer,
        muxerStarted: Boolean,
    ): Long {
        if (!muxerStarted) {
            Log.w(TAG, "muxer 未启动，跳过音轨搬运")
            return 0L
        }
        val buffer = ByteBuffer.allocateDirect(AUDIO_BUFFER_BYTES)
        val info = MediaCodec.BufferInfo()
        var bytes = 0L
        var samples = 0
        while (true) {
            buffer.clear()
            val size = extractor.readSampleData(buffer, 0)
            if (size < 0) break
            info.set(0, size, extractor.sampleTime, extractor.sampleFlags)
            muxer.writeSampleData(trackIndex, buffer, info)
            bytes += size
            samples++
            if (!extractor.advance()) break
        }
        Log.i(TAG, "audio copied $samples samples / $bytes bytes")
        return bytes
    }

    // ------------------------------------------------------------------ 工具

    private fun findVideoTrack(extractor: MediaExtractor): Int? {
        for (i in 0 until extractor.trackCount) {
            val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("video/")) return i
        }
        return null
    }

    /** MediaFormat 的 key 不一定存在，取不到就用默认值，别直接 getInteger 崩掉。 */
    private fun readInt(format: MediaFormat, key: String, fallback: Int): Int =
        if (format.containsKey(key)) format.getInteger(key) else fallback

    private fun readLong(format: MediaFormat, key: String, fallback: Long): Long =
        if (format.containsKey(key)) format.getLong(key) else fallback
}
