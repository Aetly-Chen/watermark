package cn.shuiyin.watermark_remover.media

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.SystemClock
import android.util.Log
import org.opencv.android.OpenCVLoader
import org.opencv.android.Utils
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.MatOfDouble
import org.opencv.core.MatOfPoint
import org.opencv.core.Point
import org.opencv.core.Rect
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc
import org.opencv.photo.Photo
import java.io.File
import java.io.FileOutputStream

/**
 * 单帧修复。第一版只做 Telea 传统修复，不做任何 AI 补全。
 *
 * 契约（与 Dart 侧对齐，改这里必须同步改 MaskComposer）：
 * - inputPath / maskPath 都是 Flutter 已经「压平方向」的 PNG，尺寸必须一致；
 * - mask 白 = 需要修复；
 * - 输出 PNG，尺寸与输入一致。
 *
 * 两个 OpenCV 的坑（都在真机上踩过）：
 * 1. 4.14 的 `inpaint` 在 `org.opencv.photo.Photo`，不在 `Imgproc` —— 老教程写的 `Imgproc.inpaint` 编不过；
 * 2. `inpaint` 只吃 8UC1 / 8UC3，`Utils.bitmapToMat` 给的是 4 通道 RGBA，
 *    直接传会抛 `(-210:Unsupported format or combination of formats)`。必须先转 BGR，出来再转回 RGBA。
 */
object ImageProcessor {
    private const val TAG = "WmImageProcessor"

    /**
     * 细分后的 Mask 至少要占原框的 0.5%，否则认为「框里没抠出东西」→ 退回整框。
     * 太少会是噪声误判，修出来是零星几点；太多说明这区域本来就全是高频，细分没有意义。
     */
    private const val MIN_REFINED_RATIO = 0.005

    class InvalidMaskException(message: String) : IllegalArgumentException(message)

    fun inpaint(
        inputPath: String,
        maskPath: String,
        outputPath: String,
        radius: Int,
        refine: Boolean = true,
    ): Map<String, Any> {
        val started = SystemClock.elapsedRealtime()

        // OpenCV 4.9 起官方 Maven 包用 initLocal()，不需要再手动拷 .so 到 jniLibs
        if (!OpenCVLoader.initLocal()) {
            throw IllegalStateException("OpenCV 初始化失败")
        }

        // detail 现在是**直接给用户看**的（见 ProcessingException.message），
        // 所以这里不能带内部路径 —— 路径进日志，用户只看到「为什么不行、该怎么办」。
        val srcBitmap = BitmapFactory.decodeFile(inputPath)
            ?: run {
                Log.e(TAG, "decodeFile 失败：$inputPath")
                throw IllegalArgumentException(
                    "打不开这张图：格式系统不支持，或文件已损坏。换 JPG / PNG 再试。",
                )
            }
        val maskBitmap = BitmapFactory.decodeFile(maskPath)
            ?: run {
                Log.e(TAG, "decodeFile 失败：$maskPath")
                throw IllegalArgumentException("选区蒙版生成失败，请重新框选")
            }

        if (srcBitmap.width != maskBitmap.width || srcBitmap.height != maskBitmap.height) {
            throw InvalidMaskException(
                "Mask 尺寸 ${maskBitmap.width}x${maskBitmap.height} " +
                    "与原图 ${srcBitmap.width}x${srcBitmap.height} 不一致",
            )
        }

        val srcRgba = Mat()
        val maskRgba = Mat()
        val rectMask = Mat()
        var usedMask: Mat? = null
        val srcBgr = Mat()
        val dstRgba = Mat()
        try {
            Utils.bitmapToMat(srcBitmap, srcRgba)
            Utils.bitmapToMat(maskBitmap, maskRgba)

            Imgproc.cvtColor(maskRgba, rectMask, Imgproc.COLOR_RGBA2GRAY)
            // 抗锯齿边缘会留下 1~254 的灰值，不阈值化会被当成「半修复」
            Imgproc.threshold(rectMask, rectMask, 127.0, 255.0, Imgproc.THRESH_BINARY)
            val rectArea = Core.countNonZero(rectMask)
            if (rectArea == 0) {
                throw InvalidMaskException("Mask 全黑，没有需要修复的区域")
            }

            // 框内细分：只修「真的像水印」的像素，而不是把整块矩形糊掉
            val finalMask: Mat
            if (refine) {
                usedMask = refineMask(srcRgba, rectMask)
                finalMask = usedMask
                val refinedArea = Core.countNonZero(finalMask)
                Log.i(
                    TAG,
                    "refine rect=$rectArea -> $refinedArea " +
                        "(${refinedArea * 100 / rectArea}%)",
                )
            } else {
                finalMask = rectMask
            }

            // 4 通道 → 3 通道，inpaint 的唯一合法输入
            Imgproc.cvtColor(srcRgba, srcBgr, Imgproc.COLOR_RGBA2BGR)
            val repaired = inpaintBgr(srcBgr, finalMask, radius)
            // 回 4 通道，matToBitmap 要 RGBA
            Imgproc.cvtColor(repaired, dstRgba, Imgproc.COLOR_BGR2RGBA)
            repaired.release()

            val outBitmap = Bitmap.createBitmap(dstRgba.cols(), dstRgba.rows(), Bitmap.Config.ARGB_8888)
            try {
                Utils.matToBitmap(dstRgba, outBitmap)
                val file = File(outputPath)
                file.parentFile?.mkdirs()
                FileOutputStream(file).use { out ->
                    if (!outBitmap.compress(Bitmap.CompressFormat.PNG, 100, out)) {
                        throw IllegalStateException("写文件失败：$outputPath")
                    }
                }
                val elapsed = SystemClock.elapsedRealtime() - started
                Log.i(TAG, "inpaint ok ${dstRgba.cols()}x${dstRgba.rows()} radius=$radius ${elapsed}ms")
                return mapOf(
                    "outputPath" to file.absolutePath,
                    "width" to dstRgba.cols(),
                    "height" to dstRgba.rows(),
                    "elapsedMs" to elapsed,
                    "maskPixels" to Core.countNonZero(finalMask),
                    "rectPixels" to rectArea,
                )
            } finally {
                outBitmap.recycle()
            }
        } finally {
            srcRgba.release()
            maskRgba.release()
            rectMask.release()
            usedMask?.release()
            srcBgr.release()
            dstRgba.release()
            srcBitmap.recycle()
            maskBitmap.recycle()
        }
    }

    /**
     * 修复一个 8UC3 BGR Mat，返回**新的** Mat（调用方负责 release）。
     *
     * 抽出来的原因：视频逐帧也要走同一份 OpenCV 逻辑。视频那条路径上帧已经是 NV12 / I420，
     * 先转成 BGR 再进来，能省掉一次「BGR→RGBA→bitmapToMat→RGBA2BGR」的往返。
     * 两条路径共用这一个函数，就不会出现「图片修得对、视频修得不一样」这种鬼故事。
     *
     * **只在 Mask 的外接矩形上跑 inpaint**，不碰整幅图。
     * Telea 是局部算法（只用到洞周围 radius 内的像素），外接矩形外再多留一圈
     * 上下文就够了，结果与全图修复等价。收益是实测出来的：
     * 960×540 上框 172×92，单帧从 **116 ms 降到 6 ms**（视频 150 帧的总耗时砍掉一半）。
     *
     * mask 必须是 8UC1，非零 = 修。
     */
    fun inpaintBgr(srcBgr: Mat, mask: Mat, radius: Int): Mat {
        require(srcBgr.type() == CvType.CV_8UC3) {
            "inpaintBgr 只接受 8UC3，收到 type=${srcBgr.type()}"
        }
        require(mask.type() == CvType.CV_8UC1) {
            "inpaintBgr 的 mask 只接受 8UC1，收到 type=${mask.type()}"
        }
        require(srcBgr.size() == mask.size()) {
            "BGR ${srcBgr.cols()}x${srcBgr.rows()} 与 Mask " +
                "${mask.cols()}x${mask.rows()} 尺寸不一致"
        }

        val roi = inpaintRoi(mask, srcBgr.cols(), srcBgr.rows(), radius)
            ?: return srcBgr.clone() // mask 全黑：没有要修的地方，原样返回

        val srcRoi = srcBgr.submat(roi)
        val maskRoi = mask.submat(roi)
        val restored = Mat()
        try {
            // inpaint 不保证接受非连续内存（submat 可能就是），clone 一份只有几十 KB，别赌
            val srcCopy = srcRoi.clone()
            val maskCopy = maskRoi.clone()
            try {
                Photo.inpaint(srcCopy, maskCopy, restored, radius.toDouble(), Photo.INPAINT_TELEA)
            } finally {
                srcCopy.release()
                maskCopy.release()
            }
        } finally {
            srcRoi.release()
            maskRoi.release()
        }

        val out = srcBgr.clone()
        val outRoi = out.submat(roi)
        try {
            restored.copyTo(outRoi)
        } finally {
            outRoi.release()
            restored.release()
        }
        return out
    }

    /**
     * 算出「真正要做 inpaint 的那块矩形」：Mask 外接矩形 + 一圈上下文。
     *
     * 留多少上下文：Telea 的填充只依赖洞边缘 radius 内的已知像素，
     * 再给 2×radius + 8 的余量足够；夹在图像边界内。
     * 返回 null 表示 mask 全黑。
     */
    private fun inpaintRoi(mask: Mat, width: Int, height: Int, radius: Int): Rect? {
        val points = MatOfPoint()
        val rect = try {
            Core.findNonZero(mask, points)
            if (points.empty()) return null
            Imgproc.boundingRect(points)
        } finally {
            points.release()
        }
        val pad = (radius * 3 + 8).coerceAtLeast(8)
        val x0 = (rect.x - pad).coerceAtLeast(0)
        val y0 = (rect.y - pad).coerceAtLeast(0)
        val x1 = (rect.x + rect.width + pad).coerceAtMost(width)
        val y1 = (rect.y + rect.height + pad).coerceAtMost(height)
        if (x1 <= x0 || y1 <= y0) return null
        return Rect(x0, y0, x1 - x0, y1 - y0)
    }

    /**
     * 把矩形框细分成「像水印的像素」。**实测不解决问题，默认关闭**（见 Dart 侧 refineMask 注释）。
     *
     * 依据：水印是细的、高对比的笔画，而它周围的背景通常平缓。
     * 但这条在纹理背景上不成立 —— 木纹、布料、树叶同样高频。实测把 Mask 从 28728 px
     * 缩到 9996 px（34%），水印条带之外的改动像素**一个没少**（3356 → 3356）：
     * 因为删掉的是平坦区域（那儿修了本来也看不出来），真正造成涂抹的高频纹理全留下了。
     *
     * 保留它的理由：管道（参数、阈值、三道保险、A/B 用例）在做文字级检测时能直接复用。
     * 要真的解决，判据得换 top-hat / 笔画宽度 / 连通域长宽比这类文字特征，或者直接上 LaMa。
     *
     * 三道保险：
     * 1. 阈值取「框内梯度均值 + 0.8σ」，并夹在 [12, 200]，避免极端图把阈值顶飞；
     * 2. 膨胀 2 次补回笔画边缘的抗锯齿，再与原框求交 —— 结果永远是原框的子集；
     * 3. 细分结果不足原框 0.5% 就整体退回原框（宁可多修，不可漏修）。
     */
    private fun refineMask(srcRgba: Mat, rectMask: Mat): Mat {
        val gray = Mat()
        val gx = Mat()
        val gy = Mat()
        val ax = Mat()
        val ay = Mat()
        val mag = Mat()
        val refined = Mat()
        val kernel = Imgproc.getStructuringElement(Imgproc.MORPH_ELLIPSE, Size(3.0, 3.0))
        try {
            Imgproc.cvtColor(srcRgba, gray, Imgproc.COLOR_RGBA2GRAY)

            // 梯度幅值（Sobel x / y 各取绝对值再平均，比平方和便宜且够用）
            Imgproc.Sobel(gray, gx, CvType.CV_16S, 1, 0, 3)
            Imgproc.Sobel(gray, gy, CvType.CV_16S, 0, 1, 3)
            Core.convertScaleAbs(gx, ax)
            Core.convertScaleAbs(gy, ay)
            Core.addWeighted(ax, 0.5, ay, 0.5, 0.0, mag)

            // 只看框内：均值和标准差都带 mask 统计，避免框外的高频把阈值抬高
            // 注意 Java 绑定的 MatOfDouble 没有 `val` 字段，要用 toArray()
            val mean = MatOfDouble()
            val std = MatOfDouble()
            Core.meanStdDev(mag, mean, std, rectMask)
            val threshold = (mean.toArray()[0] + 0.8 * std.toArray()[0]).coerceIn(12.0, 200.0)

            Imgproc.threshold(mag, refined, threshold, 255.0, Imgproc.THRESH_BINARY)
            Core.bitwise_and(refined, rectMask, refined)
            Imgproc.dilate(refined, refined, kernel, Point(-1.0, -1.0), 2)
            Core.bitwise_and(refined, rectMask, refined)

            val rectArea = Core.countNonZero(rectMask)
            val refinedArea = Core.countNonZero(refined)
            if (refinedArea < rectArea * MIN_REFINED_RATIO) {
                Log.w(TAG, "refine 结果太小 ($refinedArea/$rectArea)，退回整框")
                return rectMask.clone()
            }
            return refined.clone()
        } finally {
            gray.release()
            gx.release()
            gy.release()
            ax.release()
            ay.release()
            mag.release()
            refined.release()
            kernel.release()
        }
    }
}
