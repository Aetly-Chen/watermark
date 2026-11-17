package cn.shuiyin.watermark_remover.media

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
 * 单帧修复。第一版只做 Telea 传统修复，不做任何 AI 补全。
 *
 * 契约（与 Dart 侧对齐，改这里必须同步改 MaskComposer）：
 * - inputPath / maskPath 都是 Flutter 已经「压平方向」的 PNG，尺寸必须一致；
 * - mask 白 = 需要修复；
 * - 输出 PNG 或 JPEG，尺寸与输入一致。
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

    /** 图片路径的自适应外扩范围（像素），避免细水印被过度膨胀成大洞。 */
    private const val MIN_GROW_PX = 2
    private const val MAX_GROW_PX = 6

    /** 边界羽化宽度（像素）。实测接缝梯度 3.33x → 1.66x。 */
    private const val FEATHER_PX = 3

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
            val grow = (radius / 2).coerceIn(MIN_GROW_PX, MAX_GROW_PX)
            val repaired = inpaintBgr(
                srcBgr,
                finalMask,
                radius,
                growPx = grow,
                featherPx = FEATHER_PX,
            )
            try {
                // 框外像素及原始 Alpha 通道 100% 保留，只写回实际修改过的 ROI
                srcRgba.copyTo(dstRgba)
                val changedRoi = computeInpaintRoi(
                    finalMask,
                    srcBgr.cols(),
                    srcBgr.rows(),
                    radius,
                    growPx = grow,
                    featherPx = FEATHER_PX,
                )
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
                    "inpaint ok ${dstRgba.cols()}x${dstRgba.rows()} radius=$radius " +
                        "grow=${grow}px feather=${FEATHER_PX}px jpeg=$isJpegOut ${elapsed}ms",
                )
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

    /**
     * 供图片与视频路径共用的「实际发生像素修改的 ROI」计算。
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
     * 修复一个 8UC3 BGR Mat，返回**新的** Mat（调用方负责 release）。
     *
     * 在原有 TELEA 的基础上叠加三层保护：
     * 1. 按选区短边自适应收紧 `growPx`，防止小水印被过度外扩破坏干净背景；
     * 2. 对中大选区（短边 > 24 px）做 0.5× 粗尺度金字塔融合，削弱大洞对角线 X 形色斑；
     * 3. 统计周围干净背景的高频残差并向洞内注入微纹理，消除纯色扩散带来的涂抹感。
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
        val minSide = minOf(maskRect.width, maskRect.height)
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
            val dist = Mat()
            try {
                // inpaint 不保证接受非连续内存（submat 可能就是），clone 一份只有几十 KB，别赌
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
                    Imgproc.distanceTransform(maskCopy, dist, Imgproc.DIST_L2, 3)
                    if (minSide > 24 && srcCopy.cols() >= 16 && srcCopy.rows() >= 16) {
                        blendCoarsePyramid(srcCopy, maskCopy, restored, dist, radius)
                    }
                    injectContextGrain(srcCopy, maskCopy, restored, dist)
                } finally {
                    srcCopy.release()
                    maskCopy.release()
                }
                restored.copyTo(outRoi)
                if (effectiveFeather > 0) {
                    blendSeam(srcRoi, outRoi, maskRoi, effectiveFeather)
                }
            } finally {
                dist.release()
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

    /**
     * 对中大选区做 0.5× 低分辨率引导融合：
     * 仅在远离边界的洞深处（dist > radius）混入粗尺度修复结果，保留边缘和细笔画全分辨率精度。
     */
    private fun blendCoarsePyramid(
        srcCopy: Mat,
        maskCopy: Mat,
        restored: Mat,
        dist: Mat,
        radius: Int,
    ) {
        val smallW = (srcCopy.cols() / 2).coerceAtLeast(1)
        val smallH = (srcCopy.rows() / 2).coerceAtLeast(1)
        val smallSrc = Mat()
        val smallMask = Mat()
        val smallRestored = Mat()
        val coarseRestored = Mat()
        val alpha = Mat()
        val alpha3 = Mat()
        val fineF = Mat()
        val coarseF = Mat()
        val delta = Mat()
        val scaled = Mat()
        val blended = Mat()
        try {
            Imgproc.resize(
                srcCopy,
                smallSrc,
                Size(smallW.toDouble(), smallH.toDouble()),
                0.0,
                0.0,
                Imgproc.INTER_AREA,
            )
            Imgproc.resize(
                maskCopy,
                smallMask,
                Size(smallW.toDouble(), smallH.toDouble()),
                0.0,
                0.0,
                Imgproc.INTER_NEAREST,
            )
            if (Core.countNonZero(smallMask) == 0) return

            Photo.inpaint(
                smallSrc,
                smallMask,
                smallRestored,
                maxOf(2.0, radius * 0.5),
                Photo.INPAINT_TELEA,
            )
            Imgproc.resize(
                smallRestored,
                coarseRestored,
                srcCopy.size(),
                0.0,
                0.0,
                Imgproc.INTER_LINEAR,
            )

            val r = radius.coerceAtLeast(1).toDouble()
            Core.subtract(dist, Scalar(r), alpha)
            Core.multiply(alpha, Scalar(1.0 / (r * 2.0)), alpha)
            Imgproc.threshold(alpha, alpha, 0.0, 0.0, Imgproc.THRESH_TOZERO)
            Imgproc.threshold(alpha, alpha, 0.65, 0.65, Imgproc.THRESH_TRUNC)
            Core.merge(listOf(alpha, alpha, alpha), alpha3)

            restored.convertTo(fineF, CvType.CV_32FC3)
            coarseRestored.convertTo(coarseF, CvType.CV_32FC3)
            Core.subtract(coarseF, fineF, delta)
            Core.multiply(delta, alpha3, scaled)
            Core.add(fineF, scaled, blended)
            blended.convertTo(restored, CvType.CV_8UC3)
        } finally {
            smallSrc.release()
            smallMask.release()
            smallRestored.release()
            coarseRestored.release()
            alpha.release()
            alpha3.release()
            fineF.release()
            coarseF.release()
            delta.release()
            scaled.release()
            blended.release()
        }
    }

    /**
     * 基于 ROI 内非掩膜区域的局部高频残差，在洞内（dist > 1.5）补偿轻度微纹理，
     * 消除纯色扩散带来的平滑补丁感；纯色背景（grainStd < 0.8）保持零扰动。
     */
    private fun injectContextGrain(
        srcCopy: Mat,
        maskCopy: Mat,
        restored: Mat,
        dist: Mat,
    ) {
        val bgMask = Mat()
        val blur = Mat()
        val diff = Mat()
        val noise = Mat()
        val grainWeight = Mat()
        val noise3 = Mat()
        val restoredF = Mat()
        val added = Mat()
        try {
            Core.bitwise_not(maskCopy, bgMask)
            if (Core.countNonZero(bgMask) == 0) return

            Imgproc.GaussianBlur(srcCopy, blur, Size(3.0, 3.0), 0.0)
            Core.absdiff(srcCopy, blur, diff)
            val m = Core.mean(diff, bgMask)
            val grainStd = ((m.`val`[0] + m.`val`[1] + m.`val`[2]) / 3.0).coerceIn(0.0, 4.5)
            if (grainStd < 0.8) return

            noise.create(srcCopy.rows(), srcCopy.cols(), CvType.CV_32FC1)
            Core.randn(noise, 0.0, grainStd * 1.8)
            Imgproc.GaussianBlur(noise, noise, Size(3.0, 3.0), 0.7)

            Core.subtract(dist, Scalar(1.5), grainWeight)
            Core.multiply(grainWeight, Scalar(1.0 / 2.5), grainWeight)
            Imgproc.threshold(grainWeight, grainWeight, 0.0, 0.0, Imgproc.THRESH_TOZERO)
            Imgproc.threshold(grainWeight, grainWeight, 1.0, 1.0, Imgproc.THRESH_TRUNC)

            Core.multiply(noise, grainWeight, noise)
            Core.merge(listOf(noise, noise, noise), noise3)

            restored.convertTo(restoredF, CvType.CV_32FC3)
            Core.add(restoredF, noise3, added)
            added.convertTo(restored, CvType.CV_8UC3)
        } finally {
            bgMask.release()
            blur.release()
            diff.release()
            noise.release()
            grainWeight.release()
            noise3.release()
            restoredF.release()
            added.release()
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
     *
     * **只动边界，不动内部**：alpha 是「掩膜模糊后的灰度」，洞中心仍是 1（全用修复结果），
     * 外侧很快降到 0（全用原图）。所以既不会把水印带回来（水印远在洞内），
     * 也不会让修复结果漏到背景上。
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
            Core.merge(listOf(alpha, alpha, alpha), alpha3)

            srcRoi.convertTo(srcF, CvType.CV_32FC3)
            dstRoi.convertTo(dstF, CvType.CV_32FC3)
            // out = src + (inpainted - src) * alpha，省掉一次算 1-alpha
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

    /**
     * 算出「真正要做 inpaint 的那块矩形」：Mask 外接矩形 + 一圈上下文。
     *
     * 留多少上下文：Telea 的填充只依赖洞边缘 radius 内的已知像素，
     * 再给 2×radius + 8 的余量足够；夹在图像边界内。
     * 返回 null 表示 mask 全黑。
     */
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
