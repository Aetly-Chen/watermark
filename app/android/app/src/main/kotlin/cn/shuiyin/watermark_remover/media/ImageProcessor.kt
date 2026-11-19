package cn.shuiyin.watermark_remover.media

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.ExifInterface
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
import org.opencv.core.Scalar
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc
import org.opencv.photo.Photo
import java.io.File
import java.io.FileOutputStream

/**
 * 单帧图像去水印修复引擎。
 *
 * 修复策略：
 * - 默认优先使用端侧 AI 模型（MI-GAN ONNX）在局部上下文内生成自然背景结构，彻底避免传统扩散算法的马赛克与糊斑；
 * - 若未传入 `Context`、显式指定 `method="telea"` 或模型不可用时，安全降级为纯净 OpenCV Telea + 羽化过渡；
 * - 框外像素与原始 Alpha 通道 100% 保持原样，JPEG 源图保留高质量输出并完整迁移 EXIF 元数据。
 *
 * 契约（与 Dart 侧对齐，改这里必须同步改 MaskComposer）：
 * - inputPath / maskPath 都是 Flutter 已经「压平方向」的 PNG，尺寸必须一致；
 * - mask 白 = 需要修复；
 * - 输出 PNG 或 JPEG，尺寸与输入一致。
 */
object ImageProcessor {
    private const val TAG = "WmImageProcessor"

    /**
     * 细分后的 Mask 至少要占原框的 0.5%，否则认为「框里没抠出东西」→ 退回整框。
     * 太少会是噪声误判，修出来是零星几点；太多说明这区域本来就全是高频，细分没有意义。
     */
    private const val MIN_REFINED_RATIO = 0.005

    /** 传统 Telea 路径的自适应外扩范围（像素）。 */
    private const val MIN_GROW_PX = 2
    private const val MAX_GROW_PX = 6

    /** 传统路径与 AI 路径的边界羽化宽度（像素）。 */
    private const val FEATHER_PX = 3
    private const val MIGAN_FEATHER_PX = 4

    /** 输出 JPEG 的压缩质量。 */
    private const val JPEG_QUALITY = 98

    private val EXIF_COPY_TAGS = arrayOf(
        ExifInterface.TAG_DATETIME,
        ExifInterface.TAG_DATETIME_ORIGINAL,
        ExifInterface.TAG_DATETIME_DIGITIZED,
        ExifInterface.TAG_SUBSEC_TIME,
        ExifInterface.TAG_SUBSEC_TIME_ORIGINAL,
        ExifInterface.TAG_SUBSEC_TIME_DIGITIZED,
        "OffsetTime",
        "OffsetTimeOriginal",
        "OffsetTimeDigitized",
        ExifInterface.TAG_MAKE,
        ExifInterface.TAG_MODEL,
        "LensMake",
        "LensModel",
        ExifInterface.TAG_F_NUMBER,
        ExifInterface.TAG_EXPOSURE_TIME,
        ExifInterface.TAG_ISO_SPEED_RATINGS,
        ExifInterface.TAG_FOCAL_LENGTH,
        ExifInterface.TAG_FOCAL_LENGTH_IN_35MM_FILM,
        ExifInterface.TAG_FLASH,
        ExifInterface.TAG_WHITE_BALANCE,
        ExifInterface.TAG_APERTURE_VALUE,
        ExifInterface.TAG_SHUTTER_SPEED_VALUE,
        ExifInterface.TAG_EXPOSURE_BIAS_VALUE,
        ExifInterface.TAG_METERING_MODE,
        ExifInterface.TAG_LIGHT_SOURCE,
        ExifInterface.TAG_SCENE_CAPTURE_TYPE,
        ExifInterface.TAG_GPS_LATITUDE,
        ExifInterface.TAG_GPS_LATITUDE_REF,
        ExifInterface.TAG_GPS_LONGITUDE,
        ExifInterface.TAG_GPS_LONGITUDE_REF,
        ExifInterface.TAG_GPS_ALTITUDE,
        ExifInterface.TAG_GPS_ALTITUDE_REF,
        ExifInterface.TAG_GPS_TIMESTAMP,
        ExifInterface.TAG_GPS_DATESTAMP,
        ExifInterface.TAG_COLOR_SPACE,
        ExifInterface.TAG_IMAGE_DESCRIPTION,
        ExifInterface.TAG_ARTIST,
        ExifInterface.TAG_COPYRIGHT,
        ExifInterface.TAG_SOFTWARE,
        ExifInterface.TAG_USER_COMMENT,
    )

    class InvalidMaskException(message: String) : IllegalArgumentException(message)

    fun inpaint(
        inputPath: String,
        maskPath: String,
        outputPath: String,
        radius: Int,
        refine: Boolean = false,
        exifSourcePath: String? = null,
        context: Context? = null,
        method: String = "auto",
    ): Map<String, Any> {
        val started = SystemClock.elapsedRealtime()

        // OpenCV 4.9 起官方 Maven 包用 initLocal()，不需要再手动拷 .so 到 jniLibs
        if (!OpenCVLoader.initLocal()) {
            throw IllegalStateException("OpenCV 初始化失败")
        }

        // detail 现在是**直接给用户看**的，不能带内部路径 —— 路径进日志，用户只看原因和建议
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
            srcBitmap.recycle()
            maskBitmap.recycle()
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

            // 框内细分（默认关闭）
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

            // 4 通道 → 3 通道，修复输入统一为 8UC3 BGR
            Imgproc.cvtColor(srcRgba, srcBgr, Imgproc.COLOR_RGBA2BGR)

            var usedEngine = "telea"
            var repaired: Mat? = null
            var changedRoi: Rect? = null

            val miganGrow = (radius / 2 + 1).coerceIn(3, 10)
            if (context != null && method != "telea" && MiganInpainter.isAvailable(context)) {
                try {
                    repaired = MiganInpainter.inpaintBgr(
                        context = context,
                        srcBgr = srcBgr,
                        mask = finalMask,
                        growPx = miganGrow,
                        featherPx = MIGAN_FEATHER_PX,
                    )
                    usedEngine = "migan"
                    changedRoi = computeRoiWithMargin(
                        finalMask,
                        srcBgr.cols(),
                        srcBgr.rows(),
                        marginPx = miganGrow + MIGAN_FEATHER_PX + 2,
                    )
                } catch (oom: OutOfMemoryError) {
                    throw oom
                } catch (e: Throwable) {
                    Log.e(TAG, "MI-GAN 推理失败，降级使用 OpenCV TELEA: ${e.message}", e)
                    repaired?.release()
                    repaired = null
                }
            }

            if (repaired == null) {
                val grow = (radius / 2).coerceIn(MIN_GROW_PX, MAX_GROW_PX)
                repaired = inpaintBgr(
                    srcBgr,
                    finalMask,
                    radius,
                    growPx = grow,
                    featherPx = FEATHER_PX,
                )
                usedEngine = "telea"
                changedRoi = computeInpaintRoi(
                    finalMask,
                    srcBgr.cols(),
                    srcBgr.rows(),
                    radius,
                    growPx = grow,
                    featherPx = FEATHER_PX,
                )
            }

            try {
                // 框外像素及原始 Alpha 通道 100% 保留，只写回实际修改过的 ROI
                srcRgba.copyTo(dstRgba)
                if (changedRoi != null) {
                    writeRepairedRoiRgba(srcRgba, repaired, dstRgba, changedRoi)
                }
            } finally {
                repaired.release()
            }

            val outBitmap = Bitmap.createBitmap(dstRgba.cols(), dstRgba.rows(), Bitmap.Config.ARGB_8888)
            try {
                Utils.matToBitmap(dstRgba, outBitmap)
                val file = File(outputPath)
                file.parentFile?.mkdirs()
                val isJpegOut = isJpegPath(outputPath)
                val format = if (isJpegOut) Bitmap.CompressFormat.JPEG else Bitmap.CompressFormat.PNG
                val quality = if (isJpegOut) JPEG_QUALITY else 100
                FileOutputStream(file).use { out ->
                    if (!outBitmap.compress(format, quality, out)) {
                        throw IllegalStateException("写文件失败：$outputPath")
                    }
                }
                if (isJpegOut && exifSourcePath != null && File(exifSourcePath).exists()) {
                    copyExif(exifSourcePath, file.absolutePath, dstRgba.cols(), dstRgba.rows())
                }
                val elapsed = SystemClock.elapsedRealtime() - started
                Log.i(
                    TAG,
                    "inpaint ok engine=$usedEngine ${dstRgba.cols()}x${dstRgba.rows()} " +
                        "radius=$radius jpeg=$isJpegOut ${elapsed}ms",
                )
                return mapOf(
                    "outputPath" to file.absolutePath,
                    "width" to dstRgba.cols(),
                    "height" to dstRgba.rows(),
                    "elapsedMs" to elapsed,
                    "maskPixels" to Core.countNonZero(finalMask),
                    "rectPixels" to rectArea,
                    "engine" to usedEngine,
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

    /** 把 [repairedBgr] 中 [roi] 区域的 RGB 写回 [dstRgba]，同时保留 [srcRgba] 的原始 Alpha 通道。 */
    private fun writeRepairedRoiRgba(
        srcRgba: Mat,
        repairedBgr: Mat,
        dstRgba: Mat,
        roi: Rect,
    ) {
        val srcRoiRgba = srcRgba.submat(roi)
        val dstRoiRgba = dstRgba.submat(roi)
        val repRoiBgr = repairedBgr.submat(roi)
        val repRoiRgba = Mat()
        val mergedRoi = Mat()
        val srcChannels = ArrayList<Mat>(4)
        val repChannels = ArrayList<Mat>(4)
        try {
            Imgproc.cvtColor(repRoiBgr, repRoiRgba, Imgproc.COLOR_BGR2RGBA)
            Core.split(srcRoiRgba, srcChannels)
            Core.split(repRoiRgba, repChannels)
            Core.merge(
                listOf(repChannels[0], repChannels[1], repChannels[2], srcChannels[3]),
                mergedRoi,
            )
            mergedRoi.copyTo(dstRoiRgba)
        } finally {
            srcChannels.forEach { it.release() }
            repChannels.forEach { it.release() }
            mergedRoi.release()
            repRoiRgba.release()
            repRoiBgr.release()
            dstRoiRgba.release()
            srcRoiRgba.release()
        }
    }

    private fun isJpegPath(path: String): Boolean {
        val lower = path.lowercase()
        return lower.endsWith(".jpg") || lower.endsWith(".jpeg")
    }

    /** 将原图的拍摄参数、时间、GPS、色彩空间等 EXIF 元数据复制到输出 JPEG，并重置方向为正常。 */
    private fun copyExif(
        sourcePath: String,
        targetPath: String,
        width: Int,
        height: Int,
    ) {
        try {
            val srcExif = ExifInterface(sourcePath)
            val dstExif = ExifInterface(targetPath)
            for (tag in EXIF_COPY_TAGS) {
                val value = srcExif.getAttribute(tag) ?: continue
                dstExif.setAttribute(tag, value)
            }
            // 像素方向已在 Flutter 解码阶段摆正，必须把 Orientation 重置为 NORMAL，否则相册会二次旋转
            dstExif.setAttribute(
                ExifInterface.TAG_ORIENTATION,
                ExifInterface.ORIENTATION_NORMAL.toString(),
            )
            dstExif.setAttribute(ExifInterface.TAG_IMAGE_WIDTH, width.toString())
            dstExif.setAttribute(ExifInterface.TAG_IMAGE_LENGTH, height.toString())
            dstExif.setAttribute(ExifInterface.TAG_PIXEL_X_DIMENSION, width.toString())
            dstExif.setAttribute(ExifInterface.TAG_PIXEL_Y_DIMENSION, height.toString())
            dstExif.saveAttributes()
        } catch (e: Throwable) {
            Log.w(TAG, "copyExif 失败（保留图片本身）：${e.message}")
        }
    }

    /**
     * 按选区短边自适应收紧掩膜外扩像素，避免小水印被过度膨胀成大片模糊。
     * `requestedGrowPx <= 0` 时返回 0，保持旧调用零外扩语义。
     */
    fun computeAdaptiveGrowPx(mask: Mat, requestedGrowPx: Int): Int {
        val rect = boundingBox(mask) ?: return 0
        return adaptiveGrowFromRect(rect, requestedGrowPx)
    }

    private fun adaptiveGrowFromRect(rect: Rect, requestedGrowPx: Int): Int {
        val clamped = requestedGrowPx.coerceIn(0, 16)
        if (clamped == 0) return 0
        val minSide = minOf(rect.width, rect.height)
        val limit = (minSide * 0.18).toInt().coerceIn(1, 6)
        return minOf(clamped, limit)
    }

    private fun resolveEffectiveFeather(effectiveGrow: Int, featherPx: Int): Int {
        val base = featherPx.coerceIn(0, 16)
        return if (effectiveGrow > 0) maxOf(base, effectiveGrow.coerceIn(2, 5)) else base
    }

    /** 按指定外扩像素计算掩膜外接矩形（夹在图像范围内）。 */
    fun computeRoiWithMargin(
        mask: Mat,
        width: Int,
        height: Int,
        marginPx: Int,
    ): Rect? {
        if (width <= 0 || height <= 0) return null
        val rect = boundingBox(mask) ?: return null
        val margin = marginPx.coerceAtLeast(0)
        val x0 = (rect.x - margin).coerceAtLeast(0)
        val y0 = (rect.y - margin).coerceAtLeast(0)
        val x1 = (rect.x + rect.width + margin).coerceAtMost(width)
        val y1 = (rect.y + rect.height + margin).coerceAtMost(height)
        if (x1 <= x0 || y1 <= y0) return null
        return Rect(x0, y0, x1 - x0, y1 - y0)
    }

    /**
     * 供图片与视频传统路径共用的「实际发生像素修改的 ROI」计算。
     * 包含自适应外扩、边界羽化以及 2px 安全余量，框外像素在修复前后完全一致。
     */
    fun computeInpaintRoi(
        mask: Mat,
        width: Int,
        height: Int,
        radius: Int,
        growPx: Int = 0,
        featherPx: Int = 0,
    ): Rect? {
        if (width <= 0 || height <= 0) return null
        val rect = boundingBox(mask) ?: return null
        val effectiveGrow = adaptiveGrowFromRect(rect, growPx)
        val effectiveFeather = resolveEffectiveFeather(effectiveGrow, featherPx)
        val margin = effectiveGrow + effectiveFeather + 2
        val x0 = (rect.x - margin).coerceAtLeast(0)
        val y0 = (rect.y - margin).coerceAtLeast(0)
        val x1 = (rect.x + rect.width + margin).coerceAtMost(width)
        val y1 = (rect.y + rect.height + margin).coerceAtMost(height)
        if (x1 <= x0 || y1 <= y0) return null
        return Rect(x0, y0, x1 - x0, y1 - y0)
    }

    /**
     * 纯净 OpenCV TELEA 兜底修复（返回新的 8UC3 BGR Mat，调用方负责 release）。
     *
     * 采用自适应外扩与边缘羽化融合，去除粗尺度降采样与随机噪声颗粒注入，避免二次涂抹感。
     */
    fun inpaintBgr(
        srcBgr: Mat,
        mask: Mat,
        radius: Int,
        growPx: Int = 0,
        featherPx: Int = 0,
    ): Mat {
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

        val maskRect = boundingBox(mask) ?: return srcBgr.clone()
        val effectiveGrow = adaptiveGrowFromRect(maskRect, growPx)
        val effectiveFeather = resolveEffectiveFeather(effectiveGrow, featherPx)
        val workMask = if (effectiveGrow > 0) dilateMask(mask, effectiveGrow) else mask

        try {
            // ROI 余量要把上下文、外扩与羽化都算进去，否则 Telea 采样或羽化带会被裁掉
            val roi = inpaintRoi(
                workMask,
                srcBgr.cols(),
                srcBgr.rows(),
                radius + effectiveGrow + effectiveFeather,
            ) ?: return srcBgr.clone()

            val out = srcBgr.clone()
            val srcRoi = srcBgr.submat(roi)
            val outRoi = out.submat(roi)
            val maskRoi = workMask.submat(roi)
            val restored = Mat()
            try {
                // inpaint 不保证接受非连续内存（submat 可能就是），clone 一份只有几十 KB
                val srcCopy = srcRoi.clone()
                val maskCopy = maskRoi.clone()
                try {
                    Photo.inpaint(
                        srcCopy,
                        maskCopy,
                        restored,
                        radius.toDouble(),
                        Photo.INPAINT_TELEA,
                    )
                } finally {
                    srcCopy.release()
                    maskCopy.release()
                }
                restored.copyTo(outRoi)
                if (effectiveFeather > 0) {
                    blendSeam(srcRoi, outRoi, maskRoi, effectiveFeather)
                }
            } finally {
                restored.release()
                maskRoi.release()
                outRoi.release()
                srcRoi.release()
            }
            return out
        } finally {
            if (workMask !== mask) workMask.release()
        }
    }

    /** 椭圆结构元做形态学膨胀，让掩膜整体向外吃 `px` 像素。 */
    private fun dilateMask(mask: Mat, px: Int): Mat {
        val size = (px * 2 + 1).toDouble()
        val kernel = Imgproc.getStructuringElement(Imgproc.MORPH_ELLIPSE, Size(size, size))
        val grown = Mat()
        try {
            Imgproc.dilate(mask, grown, kernel)
        } finally {
            kernel.release()
        }
        return grown
    }

    /**
     * 把修复结果与原图在掩膜边界处过渡。
     * 只动边界，不动内部：alpha 是掩膜模糊后的灰度，洞内强制为 1（全用修复结果），外侧很快降到 0。
     */
    private fun blendSeam(srcRoi: Mat, dstRoi: Mat, maskRoi: Mat, feather: Int) {
        val alpha = Mat()
        val alpha3 = Mat()
        val srcF = Mat()
        val dstF = Mat()
        val delta = Mat()
        val scaled = Mat()
        val result = Mat()
        try {
            maskRoi.convertTo(alpha, CvType.CV_32F, 1.0 / 255.0)
            val k = (feather * 2 + 1).toDouble()
            Imgproc.GaussianBlur(alpha, alpha, Size(k, k), 0.0)
            alpha.setTo(Scalar(1.0), maskRoi)
            Core.merge(listOf(alpha, alpha, alpha), alpha3)

            srcRoi.convertTo(srcF, CvType.CV_32FC3)
            dstRoi.convertTo(dstF, CvType.CV_32FC3)
            // out = src + (inpainted - src) * alpha
            Core.subtract(dstF, srcF, delta)
            Core.multiply(delta, alpha3, scaled)
            Core.add(srcF, scaled, result)
            result.convertTo(dstRoi, CvType.CV_8UC3)
        } finally {
            alpha.release()
            alpha3.release()
            srcF.release()
            dstF.release()
            delta.release()
            scaled.release()
            result.release()
        }
    }

    private fun boundingBox(mask: Mat): Rect? {
        val points = MatOfPoint()
        return try {
            Core.findNonZero(mask, points)
            if (points.empty()) null else Imgproc.boundingRect(points)
        } finally {
            points.release()
        }
    }

    /** 算出实际要做 inpaint 的局部矩形：Mask 外接矩形 + 采样上下文。 */
    private fun inpaintRoi(mask: Mat, width: Int, height: Int, radius: Int): Rect? {
        val rect = boundingBox(mask) ?: return null
        val pad = (radius * 3 + 8).coerceAtLeast(8)
        val x0 = (rect.x - pad).coerceAtLeast(0)
        val y0 = (rect.y - pad).coerceAtLeast(0)
        val x1 = (rect.x + rect.width + pad).coerceAtMost(width)
        val y1 = (rect.y + rect.height + pad).coerceAtMost(height)
        if (x1 <= x0 || y1 <= y0) return null
        return Rect(x0, y0, x1 - x0, y1 - y0)
    }

    /** 把矩形框细分成「像水印的像素」（默认关闭，保留管线实验开关）。 */
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

            Imgproc.Sobel(gray, gx, CvType.CV_16S, 1, 0, 3)
            Imgproc.Sobel(gray, gy, CvType.CV_16S, 0, 1, 3)
            Core.convertScaleAbs(gx, ax)
            Core.convertScaleAbs(gy, ay)
            Core.addWeighted(ax, 0.5, ay, 0.5, 0.0, mag)

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
