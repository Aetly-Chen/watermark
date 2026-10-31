package cn.shuiyin.watermark_remover.media

import android.graphics.Bitmap
import android.graphics.Matrix
import android.media.MediaMetadataRetriever
import android.os.SystemClock
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.io.IOException

/**
 * 视频元数据与封面帧。
 *
 * 只做「读」，不做任何解码链路 —— 处理管线（Extractor → Codec → Muxer）在下一步，
 * 到那时这个类仍然只负责探测，别把解码逻辑混进来。
 *
 * 两个必须处理的现实问题：
 * 1. **旋转**：手机竖拍视频常常是「1920x1080 + rotation=90」。
 *    MediaMetadataRetriever 报的 WIDTH/HEIGHT 是**编码尺寸**，不是用户看到的尺寸。
 *    所以这里同时返回 `displayWidth/displayHeight`（按 rotation 交换过），
 *    UI 用显示尺寸，Mask 用真实帧尺寸 —— 两者搞混就会框歪。
 * 2. **封面帧**：`getScaledFrameAtTime` 只有 API 27+ 有，低版本要自己缩。
 *    而且它取的是「≤ 目标时间点的关键帧」，不一定正好是 0 秒，所以要把实际时间回传。
 */
object VideoProbe {
    private const val TAG = "WmVideoProbe"

    /** 封面帧最长边上限：再大对框选没帮助，只是白占内存。 */
    private const val MAX_POSTER_EDGE = 1080

    /**
     * 打开 retriever，失败时翻译成人话。
     *
     * 系统能解哪些封装取决于厂商的 Stagefright：MP4 / MOV / MKV 基本都有，
     * **AVI / RMVB / WMV 通常没有解析器**，`setDataSource` 会直接抛
     * 「Failed to instantiate extractor」。原始异常用户看不懂，扔到界面上
     * 只会得到一句英文堆栈。这里换成「该换什么文件」，原始异常留在 cause 里供日志追溯。
     */
    private fun openRetriever(path: String): MediaMetadataRetriever {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            return retriever
        } catch (e: Exception) {
            retriever.release()
            Log.w(TAG, "setDataSource 失败 ${File(path).name}", e)
            throw IOException(
                "打不开这个视频：可能是封装格式系统不支持（AVI / RMVB / WMV 等），" +
                    "也可能文件已损坏。转成 MP4（H.264 + AAC）再试。",
                e,
            )
        }
    }

    fun probe(path: String): Map<String, Any> {
        val file = File(path)
        if (!file.exists()) throw IOException("视频不存在：$path")

        val retriever = openRetriever(path)
        try {
            val width = retriever.intMeta(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
            val height = retriever.intMeta(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
            if (width <= 0 || height <= 0) {
                throw IOException("读不到视频尺寸（可能是音频文件或已损坏）")
            }
            val rotation = retriever.intMeta(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
            val duration = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 0L
            val hasAudio = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_AUDIO) == "yes"

            val swapped = rotation == 90 || rotation == 270
            val displayWidth = if (swapped) height else width
            val displayHeight = if (swapped) width else height

            Log.i(TAG, "probe ${file.name} ${width}x$height rot=$rotation dur=${duration}ms audio=$hasAudio")
            return mapOf(
                "path" to file.absolutePath,
                "width" to width,
                "height" to height,
                "rotation" to rotation,
                "displayWidth" to displayWidth,
                "displayHeight" to displayHeight,
                "durationMs" to duration,
                "hasAudio" to hasAudio,
                "sizeBytes" to file.length(),
            )
        } finally {
            retriever.release()
        }
    }

    /**
     * 取一张封面帧并写成 PNG。[positionMs] 传 0 就是取第一张可解码的帧。
     * 返回的是**这张 PNG 的真实尺寸**（可能与 probe 报的宽高不同，尤其是旋转视频）。
     */
    fun extractFrame(path: String, outputPath: String, positionMs: Long): Map<String, Any> {
        val started = SystemClock.elapsedRealtime()
        val retriever = openRetriever(path)
        try {
            // 直接用原尺寸帧，不用 getScaledFrameAtTime。
            //
            // 为什么不用：它要传 targetW/targetH，而本机上 METADATA_KEY_VIDEO_WIDTH/HEIGHT
            // 返回的是**旋转后**的尺寸（540x960）。把未旋转的 960x540 帧按比例塞进
            // 540x960 的框里，得到的是 540x304 —— 一个既不竖也不原始的畸形尺寸。
            // 实测栽过：集成测试里抽出来的「竖屏帧」横着，红块位置全错。
            val bitmap: Bitmap = retriever.getFrameAtTime(
                positionMs * 1000,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
            ) ?: throw IOException("取不到封面帧（position=${positionMs}ms）")

            val rotation = retriever.intMeta(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
            val wantPortrait = rotation == 90 || rotation == 270
            val isPortrait = bitmap.height > bitmap.width

            // 判据只有一条：**该竖却是横的，就自己转**。
            //
            // 早先写的是 `wantSwapped != gotSwapped`，其中 gotSwapped = width > height，
            // 意思是「已经是横的」。两个都是 true 时反而不转 —— 正好把唯一该转的情况漏掉。
            // 这条分支以前从没在真机上跑过（素材全是 rotation=0），所以一直没暴露。
            //
            // 反过来「已经是竖的」也不能再转一次：有些机型的 retriever 已经替我们转好了，
            // 再转就是歪 90°。所以只认「该竖却横」这一种情况。
            var upright: Bitmap = if (wantPortrait && !isPortrait) {
                val matrix = Matrix().apply { postRotate(rotation.toFloat()) }
                Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
                    .also { if (it !== bitmap) bitmap.recycle() }
            } else {
                bitmap
            }

            // 最后统一缩放到最长边上限。用 createScaledBitmap 而不是
            // getScaledFrameAtTime，是因为此时尺寸已经是「真正想要的方向」，没有歧义。
            val longEdge = maxOf(upright.width, upright.height)
            if (longEdge > MAX_POSTER_EDGE) {
                val k = MAX_POSTER_EDGE.toFloat() / longEdge
                val sw = (upright.width * k).toInt().coerceAtLeast(1)
                val sh = (upright.height * k).toInt().coerceAtLeast(1)
                val scaled = Bitmap.createScaledBitmap(upright, sw, sh, true)
                if (scaled !== upright) upright.recycle()
                upright = scaled
            }

            try {
                val out = File(outputPath)
                out.parentFile?.mkdirs()
                FileOutputStream(out).use { stream ->
                    if (!upright.compress(Bitmap.CompressFormat.PNG, 100, stream)) {
                        throw IOException("写封面失败：$outputPath")
                    }
                }
                val elapsed = SystemClock.elapsedRealtime() - started
                Log.i(TAG, "frame ${upright.width}x${upright.height} rot=$rotation ${elapsed}ms")
                return mapOf(
                    "framePath" to out.absolutePath,
                    "width" to upright.width,
                    "height" to upright.height,
                    "rotation" to rotation,
                    "elapsedMs" to elapsed,
                )
            } finally {
                upright.recycle()
            }
        } finally {
            retriever.release()
        }
    }

    private fun MediaMetadataRetriever.intMeta(key: Int): Int =
        extractMetadata(key)?.toIntOrNull() ?: 0
}
