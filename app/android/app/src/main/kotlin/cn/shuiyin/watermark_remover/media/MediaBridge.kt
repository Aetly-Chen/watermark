package cn.shuiyin.watermark_remover.media

import android.content.Context
import android.graphics.RectF
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.opencv.android.OpenCVLoader
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Flutter ↔ Kotlin 的唯一入口。
 *
 * 三条纪律：
 * 1. 重活一律丢到单独线程，主线程只负责回结果 —— 解码 2000 万像素的图放主线程会直接 ANR；
 * 2. 错误用**字符串错误码**回传（与 Dart 的 ProcessingErrorCode 一一对应），不要把 exception 抛给 Flutter；
 * 3. 取消是标记位，能中断的地方自己检查（图片是单帧，实际意义在视频引擎接入后才体现）。
 */
class MediaBridge(
    private val context: Context,
    private val messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "WmMediaBridge"
        const val CHANNEL_NAME = "cn.shuiyin.watermark/media"

        // 与 Dart 侧 ProcessingErrorCode.code 必须一致
        private const val ERR_UNSUPPORTED = "unsupported_format"
        private const val ERR_DECODE = "decode_failed"
        private const val ERR_INVALID_MASK = "invalid_mask"
        private const val ERR_OOM = "out_of_memory"
        private const val ERR_CANCELLED = "cancelled"
        private const val ERR_NATIVE = "native_failure"
    }

    private val channel = MethodChannel(messenger, CHANNEL_NAME)
    private val executor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val cancelledTasks = ConcurrentHashMap<String, AtomicBoolean>()

    fun attach() {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        executor.shutdownNow()
        cancelledTasks.clear()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "inpaintImage" -> handleInpaint(call, result)
            "saveImage" -> handleSave(call, result)
            "saveVideo" -> handleSaveVideo(call, result)
            "probeVideo" -> handleProbeVideo(call, result)
            "extractVideoFrame" -> handleExtractFrame(call, result)
            "repairVideo" -> handleRepairVideo(call, result)
            "motionSelfTest" -> handleMotionSelfTest(call, result)
            "cancel" -> {
                val taskId = call.argument<String>("taskId")
                if (taskId != null) {
                    cancelledTasks.computeIfAbsent(taskId) { AtomicBoolean(false) }.set(true)
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /** 保存到相册。回来的是 MediaStore 的 content:// URI。 */
    private fun handleSave(call: MethodCall, result: MethodChannel.Result) {
        val sourcePath = call.argument<String>("sourcePath")
        if (sourcePath == null) {
            result.error(ERR_UNSUPPORTED, "缺少 sourcePath", null)
            return
        }
        val displayName = call.argument<String>("displayName")
            ?: "watermark_${System.currentTimeMillis()}.png"

        executor.execute {
            try {
                val uri = GallerySaver.save(context, sourcePath, displayName)
                mainHandler.post { result.success(uri) }
            } catch (e: Throwable) {
                mainHandler.post { result.error(ERR_NATIVE, e.message, null) }
            }
        }
    }

    /** 保存视频到相册（Movies/水印工坊）。同样是丢线程里做，几百 MB 的拷贝不能占主线程。 */
    private fun handleSaveVideo(call: MethodCall, result: MethodChannel.Result) {
        val sourcePath = call.argument<String>("sourcePath")
        if (sourcePath == null) {
            result.error(ERR_UNSUPPORTED, "缺少 sourcePath", null)
            return
        }
        val displayName = call.argument<String>("displayName")
            ?: "watermark_${System.currentTimeMillis()}.mp4"

        executor.execute {
            try {
                val uri = GallerySaver.saveVideo(context, sourcePath, displayName)
                mainHandler.post { result.success(uri) }
            } catch (e: Throwable) {
                Log.e(TAG, "saveVideo failed: ${e.javaClass.simpleName}: ${e.message}", e)
                mainHandler.post { result.error(ERR_NATIVE, e.message, null) }
            }
        }
    }

    /** 读视频元数据。失败信息要能区分「文件没了」和「不是视频」。 */    private fun handleProbeVideo(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path == null) {
            result.error(ERR_UNSUPPORTED, "缺少 path", null)
            return
        }
        executor.execute {
            try {
                val meta = VideoProbe.probe(path)
                mainHandler.post { result.success(meta) }
            } catch (e: java.io.IOException) {
                mainHandler.post { result.error(ERR_DECODE, e.message, null) }
            } catch (e: Throwable) {
                mainHandler.post { result.error(ERR_NATIVE, e.message, null) }
            }
        }
    }

    /** 抽一张封面帧写成 PNG。Mask 的坐标要对着这张帧来算，所以必须回传真实尺寸。 */
    private fun handleExtractFrame(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        val outputPath = call.argument<String>("outputPath")
        val positionMs = (call.argument<Int>("positionMs") ?: 0).toLong()
        if (path == null || outputPath == null) {
            result.error(ERR_UNSUPPORTED, "缺少 path / outputPath", null)
            return
        }
        executor.execute {
            try {
                val frame = VideoProbe.extractFrame(path, outputPath, positionMs)
                mainHandler.post { result.success(frame) }
            } catch (e: java.io.IOException) {
                mainHandler.post { result.error(ERR_DECODE, e.message, null) }
            } catch (e: Throwable) {
                mainHandler.post { result.error(ERR_NATIVE, e.message, null) }
            }
        }
    }

    /**
     * 视频修复。这是唯一一个「长任务」——5 秒 30fps 的片子要走 150 帧解码 + 修复 + 编码，
     * 所以它多了两样别人没有的东西：**进度回传** 和 **逐帧取消检查**。
     *
     * 进度用 `channel.invokeMethod("onVideoProgress")` 反向推给 Dart —— 注意这是
     * Kotlin → Dart 的调用，Dart 侧没有 handler 时框架会静默忽略，不会炸。
     */
    private fun handleRepairVideo(call: MethodCall, result: MethodChannel.Result) {
        val inputPath = call.argument<String>("inputPath")
        val outputPath = call.argument<String>("outputPath")
        val left = call.argument<Double>("left")
        val top = call.argument<Double>("top")
        val right = call.argument<Double>("right")
        val bottom = call.argument<Double>("bottom")
        val radius = call.argument<Int>("radius") ?: 4
        // 默认关闭：静态水印用一张 Mask 就够；开了追踪反而可能把框带偏
        // （手上没有真水印素材，追得准不准无法用肉眼验证）
        val trackMotion = call.argument<Boolean>("trackMotion") ?: false
        val taskId = call.argument<String>("taskId") ?: "video-${System.nanoTime()}"

        if (inputPath == null || outputPath == null ||
            left == null || top == null || right == null || bottom == null
        ) {
            result.error(ERR_UNSUPPORTED, "缺少 inputPath / outputPath / 选区", null)
            return
        }
        if (right <= left || bottom <= top) {
            result.error(ERR_INVALID_MASK, "选区为空：($left,$top)-($right,$bottom)", null)
            return
        }

        val flag = cancelledTasks.computeIfAbsent(taskId) { AtomicBoolean(false) }
        val replied = AtomicBoolean(false)
        fun replyOnce(block: () -> Unit) {
            if (replied.compareAndSet(false, true)) block()
        }

        executor.execute {
            try {
                val mask = RectF(left.toFloat(), top.toFloat(), right.toFloat(), bottom.toFloat())
                val out = VideoProcessor.repair(
                    inputPath = inputPath,
                    outputPath = outputPath,
                    mask = mask,
                    radius = radius,
                    trackMotion = trackMotion,
                    onProgress = { phase, done, total ->
                        mainHandler.post {
                            channel.invokeMethod(
                                "onVideoProgress",
                                mapOf(
                                    "taskId" to taskId,
                                    // phase: VideoProcessor.PHASE_MOTION / PHASE_REPAIR
                                    "phase" to phase,
                                    "done" to done,
                                    "total" to total,
                                ),
                            )
                        }
                    },
                    isCancelled = { flag.get() },
                )
                mainHandler.post { replyOnce { result.success(out) } }
            } catch (e: VideoProcessor.VideoCancelledException) {
                mainHandler.post { replyOnce { result.error(ERR_CANCELLED, e.message, null) } }
            } catch (e: VideoProcessor.VideoUnsupportedException) {
                mainHandler.post { replyOnce { result.error(ERR_UNSUPPORTED, e.message, null) } }
            } catch (e: OutOfMemoryError) {
                // 同 inpaint：原文是系统英文，日志留档、通道传 null
                Log.e(TAG, "repairVideo OOM", e)
                mainHandler.post { replyOnce { result.error(ERR_OOM, null, null) } }
            } catch (e: Throwable) {
                // 一定要把堆栈打出来：Dart 侧只会拿到一个 native_failure 码，
                // 具体是哪个平面越界、哪个 cvtColor 参数不对，全靠这一行（栽过一次）。
                Log.e(TAG, "repairVideo failed: ${e.javaClass.simpleName}: ${e.message}", e)
                mainHandler.post { replyOnce { result.error(ERR_NATIVE, e.message, null) } }
            } finally {
                cancelledTasks.remove(taskId)
            }
        }
    }

    /**
     * 运动估计器的已知真值自检。**只在测试里用**，产品流程不经过这里。
     *
     * 为什么在原生侧做而不是在 Dart 里：造真值要用 `Imgproc.warpAffine`，
     * 让「造真值的代码」和「被估计的对象」在同一侧，才不会出现坐标系/插值方式的错配。
     */
    private fun handleMotionSelfTest(call: MethodCall, result: MethodChannel.Result) {
        val imagePath = call.argument<String>("imagePath")
        if (imagePath == null) {
            result.error(ERR_INVALID_MASK, "缺少 imagePath", null)
            return
        }
        executor.execute {
            try {
                // OpenCV 的 .so 是懒加载的，第一次真正用到才 init
                if (!OpenCVLoader.initLocal()) {
                    throw IllegalStateException("OpenCV 初始化失败")
                }
                val cases = MotionEstimator.selfTest(imagePath)
                mainHandler.post { result.success(cases) }
            } catch (e: Throwable) {
                Log.e(TAG, "motionSelfTest failed", e)
                mainHandler.post { result.error(ERR_NATIVE, e.message, null) }
            }
        }
    }

    private fun handleInpaint(call: MethodCall, result: MethodChannel.Result) {
        val taskId = call.argument<String>("taskId")
        val inputPath = call.argument<String>("inputPath")
        val maskPath = call.argument<String>("maskPath")
        val outputPath = call.argument<String>("outputPath")
        val radius = call.argument<Int>("radius") ?: 6
        // 默认开：框内细分能把「框大了就糊一片」压回只修水印笔画
        val refine = call.argument<Boolean>("refine") ?: true

        if (inputPath == null || maskPath == null || outputPath == null) {
            result.error(ERR_UNSUPPORTED, "缺少 inputPath / maskPath / outputPath", null)
            return
        }

        val flag = cancelledTasks.computeIfAbsent(taskId ?: "anonymous") {
            AtomicBoolean(false)
        }

        // result 只能回一次：后面的每个分支都要保证只走一条
        val replied = AtomicBoolean(false)
        fun replyOnce(block: () -> Unit) {
            if (replied.compareAndSet(false, true)) {
                block()
            }
        }

        executor.execute {
            try {
                if (flag.get()) {
                    mainHandler.post { replyOnce { result.error(ERR_CANCELLED, "任务已取消", null) } }
                    return@execute
                }

                val out = ImageProcessor.inpaint(inputPath, maskPath, outputPath, radius, refine)
                mainHandler.post { replyOnce { result.success(out) } }
            } catch (e: ImageProcessor.InvalidMaskException) {
                mainHandler.post { replyOnce { result.error(ERR_INVALID_MASK, e.message, null) } }
            } catch (e: OutOfMemoryError) {
                // ⚠ 不要传 e.message：那是
                // 「Failed to allocate a 46080012 byte allocation with ...」这种系统英文。
                // Dart 侧现在 detail 优先（见 ProcessingException.message），传过去就是
                // 一整段英文怼在用户脸上。原始信息进日志，通道传 null 让 Dart 回落到中文话术。
                Log.e(TAG, "inpaint OOM", e)
                mainHandler.post { replyOnce { result.error(ERR_OOM, null, null) } }
            } catch (e: IllegalArgumentException) {
                mainHandler.post { replyOnce { result.error(ERR_DECODE, e.message, null) } }
            } catch (e: Throwable) {
                mainHandler.post { replyOnce { result.error(ERR_NATIVE, e.message, null) } }
            } finally {
                cancelledTasks.remove(taskId ?: "anonymous")
            }
        }
    }
}
