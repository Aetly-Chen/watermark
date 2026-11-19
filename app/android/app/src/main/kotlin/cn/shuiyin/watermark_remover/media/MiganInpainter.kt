package cn.shuiyin.watermark_remover.media

import ai.onnxruntime.OnnxJavaType
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import android.util.Log
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.Rect
import org.opencv.core.Scalar
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import kotlin.math.max
import kotlin.math.min

/**
 * 基于开源 MI-GAN（ICCV 2023，MIT 许可）ONNX 模型的端侧 AI 图像修复引擎。
 *
 * 模型契约（`migan_pipeline_v2.onnx`）：
 * - 输入 `image`: `[1, 3, H, W]`，数据类型 `UINT8`，通道序为 RGB；
 * - 输入 `mask`:  `[1, 1, H, W]`，数据类型 `UINT8`，极性为 **`0 = 待修复水印`，`255 = 保留原图`**；
 * - 输出 `result`: `[1, 3, H, W]`，数据类型 `UINT8`，通道序为 RGB。
 *
 * 工程关键点：
 * 1. 按连通域分簇后截取局部上下文（最小尽量 512px）独立推理，多处分散水印互不拉低分辨率；
 * 2. 开启 `setCPUArenaAllocator(false)` 避免移动端预分配上百 MB 内存，并通过文件路径加载降低峰值堆占用；
 * 3. 仅在膨胀掩膜及窄羽化带内将 AI 结果融回原图，掩膜外 100% 保留原始像素，绝不模糊未选区背景。
 */
object MiganInpainter {
    private const val TAG = "WmMiganInpainter"
    const val ASSET_PATH = "models/migan_pipeline_v2.onnx"
    const val EXPECTED_MODEL_BYTES = 28_079_181L

    /** 多块涂抹/选区合并成同一推理簇的最大间距（像素）。 */
    private const val CLUSTER_MERGE_GAP = 96

    /** 局部上下文最小建议尺寸与单次推理最大边长上限（防高分辨率选区 OOM）。 */
    private const val MIN_CONTEXT_EDGE = 512
    private const val MIN_INFER_EDGE = 64
    private const val MAX_INFER_EDGE = 1024

    @Volatile
    private var cachedSession: OrtSession? = null

    /** 检查 APK 资产或本地缓存中是否具备完整的 MI-GAN 模型文件。 */
    fun isAvailable(context: Context): Boolean {
        val localFile = File(context.filesDir, ASSET_PATH)
        if (localFile.exists() && localFile.length() == EXPECTED_MODEL_BYTES) {
            return true
        }
        return try {
            context.assets.open(ASSET_PATH).use { true }
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * 使用 MI-GAN 对 8UC3 BGR 图像执行局部去水印修复，返回新的 BGR `Mat`（调用方负责 release）。
     *
     * @param context Android 上下文，用于定位和缓存模型文件
     * @param srcBgr 输入图像（`CV_8UC3` BGR）
     * @param mask 待修复掩膜（`CV_8UC1`，白色 > 127 表示水印区域）
     * @param growPx 椭圆形态学外扩像素（自动抵消模型内部边界保护与压缩振铃）
     * @param featherPx 掩膜边缘高斯羽化宽度（像素），消除回贴硬接缝
     */
    fun inpaintBgr(
        context: Context,
        srcBgr: Mat,
        mask: Mat,
        growPx: Int = 5,
        featherPx: Int = 4,
    ): Mat {
        require(srcBgr.type() == CvType.CV_8UC3) {
            "MiganInpainter 只接受 8UC3 BGR，收到 type=${srcBgr.type()}"
        }
        require(mask.type() == CvType.CV_8UC1) {
            "MiganInpainter 的 mask 只接受 8UC1，收到 type=${mask.type()}"
        }
        require(srcBgr.size() == mask.size()) {
            "BGR ${srcBgr.cols()}x${srcBgr.rows()} 与 Mask ${mask.cols()}x${mask.rows()} 尺寸不一致"
        }

        val binaryMask = Mat()
        var workMask: Mat? = null
        try {
            Imgproc.threshold(mask, binaryMask, 127.0, 255.0, Imgproc.THRESH_BINARY)
            if (Core.countNonZero(binaryMask) == 0) {
                return srcBgr.clone()
            }

            // 膨胀掩膜：彻底包住文字抗锯齿、边缘半透明光晕及压缩块效应
            val clampedGrow = growPx.coerceIn(2, 12)
            val kSize = (clampedGrow * 2 + 1).toDouble()
            val kernel = Imgproc.getStructuringElement(Imgproc.MORPH_ELLIPSE, Size(kSize, kSize))
            val grown = Mat()
            try {
                Imgproc.dilate(binaryMask, grown, kernel)
            } finally {
                kernel.release()
            }
            workMask = grown

            val clusters = extractClusterBoxes(grown)
            if (clusters.isEmpty()) {
                return srcBgr.clone()
            }

            val session = getOrCreateSession(context)
            val out = srcBgr.clone()
            val clampedFeather = featherPx.coerceIn(0, 12)
            for (clusterBox in clusters) {
                inpaintCluster(
                    session = session,
                    srcBgr = srcBgr,
                    workMask = grown,
                    outBgr = out,
                    clusterBox = clusterBox,
                    featherPx = clampedFeather,
                )
            }
            return out
        } finally {
            binaryMask.release()
            workMask?.release()
        }
    }

    /** 释放 ONNX 会话资源（正常生命周期内可长期复用）。 */
    fun closeSession() {
        synchronized(this) {
            try {
                cachedSession?.close()
            } catch (_: Throwable) {
            }
            cachedSession = null
        }
    }

    /** 提取并合并邻近的掩膜连通域外接矩形，避免多处水印互相拉低推理清晰度。 */
    private fun extractClusterBoxes(workMask: Mat): List<Rect> {
        val labels = Mat()
        val stats = Mat()
        val centroids = Mat()
        val rawBoxes = ArrayList<Rect>()
        try {
            val count = Imgproc.connectedComponentsWithStats(
                workMask,
                labels,
                stats,
                centroids,
                8,
                CvType.CV_32S,
            )
            for (i in 1 until count) {
                val x = stats.get(i, Imgproc.CC_STAT_LEFT)[0].toInt()
                val y = stats.get(i, Imgproc.CC_STAT_TOP)[0].toInt()
                val w = stats.get(i, Imgproc.CC_STAT_WIDTH)[0].toInt()
                val h = stats.get(i, Imgproc.CC_STAT_HEIGHT)[0].toInt()
                if (w > 0 && h > 0) {
                    rawBoxes.add(Rect(x, y, w, h))
                }
            }
        } finally {
            labels.release()
            stats.release()
            centroids.release()
        }
        if (rawBoxes.size <= 1) return rawBoxes

        val merged = ArrayList(rawBoxes)
        var changed = true
        while (changed) {
            changed = false
            var i = 0
            while (i < merged.size) {
                var j = i + 1
                while (j < merged.size) {
                    if (rectsOverlapWithGap(merged[i], merged[j], CLUSTER_MERGE_GAP)) {
                        merged[i] = unionRect(merged[i], merged[j])
                        merged.removeAt(j)
                        changed = true
                    } else {
                        j++
                    }
                }
                i++
            }
        }
        return merged
    }

    private fun rectsOverlapWithGap(a: Rect, b: Rect, gap: Int): Boolean {
        val ax0 = a.x - gap
        val ay0 = a.y - gap
        val ax1 = a.x + a.width + gap
        val ay1 = a.y + a.height + gap
        return ax0 <= b.x + b.width &&
            ax1 >= b.x &&
            ay0 <= b.y + b.height &&
            ay1 >= b.y
    }

    private fun unionRect(a: Rect, b: Rect): Rect {
        val x0 = min(a.x, b.x)
        val y0 = min(a.y, b.y)
        val x1 = max(a.x + a.width, b.x + b.width)
        val y1 = max(a.y + a.height, b.y + b.height)
        return Rect(x0, y0, x1 - x0, y1 - y0)
    }

    /** 计算带足量背景上下文的裁剪区域（夹紧在图像边界内）。 */
    private fun computeContextCropRect(box: Rect, imgW: Int, imgH: Int): Rect {
        val pad = max(128, max(box.width, box.height) / 2)
        val desiredW = max(box.width + pad * 2, min(MIN_CONTEXT_EDGE, imgW)).coerceAtMost(imgW)
        val desiredH = max(box.height + pad * 2, min(MIN_CONTEXT_EDGE, imgH)).coerceAtMost(imgH)

        val cx = box.x + box.width / 2
        val cy = box.y + box.height / 2
        var x0 = cx - desiredW / 2
        var y0 = cy - desiredH / 2
        if (x0 + desiredW > imgW) x0 = imgW - desiredW
        if (y0 + desiredH > imgH) y0 = imgH - desiredH
        x0 = x0.coerceAtLeast(0)
        y0 = y0.coerceAtLeast(0)
        val w = desiredW.coerceAtMost(imgW - x0)
        val h = desiredH.coerceAtMost(imgH - y0)
        return Rect(x0, y0, w, h)
    }

    /** 对单个修复簇执行裁剪、预处理、ONNX 推理和窄羽化融合回写。 */
    private fun inpaintCluster(
        session: OrtSession,
        srcBgr: Mat,
        workMask: Mat,
        outBgr: Mat,
        clusterBox: Rect,
        featherPx: Int,
    ) {
        val cropRect = computeContextCropRect(clusterBox, srcBgr.cols(), srcBgr.rows())
        if (cropRect.width <= 0 || cropRect.height <= 0) return

        val srcSub = srcBgr.submat(cropRect)
        val maskSub = workMask.submat(cropRect)
        val outSub = outBgr.submat(cropRect)
        val cropBgr = srcSub.clone()
        val cropMask = maskSub.clone()
        var paddedBgr: Mat? = null
        var paddedMask: Mat? = null
        var feedBgr: Mat? = null
        var feedMask: Mat? = null
        var inferOut: Mat? = null
        var restoredPadded: Mat? = null
        try {
            // 若局部裁剪太小（例如原图本身 < 64px），用镜像填充补足到模型安全尺寸
            val padLeft = ((MIN_INFER_EDGE - cropRect.width).coerceAtLeast(0)) / 2
            val padRight = (MIN_INFER_EDGE - cropRect.width).coerceAtLeast(0) - padLeft
            val padTop = ((MIN_INFER_EDGE - cropRect.height).coerceAtLeast(0)) / 2
            val padBottom = (MIN_INFER_EDGE - cropRect.height).coerceAtLeast(0) - padTop

            val workInputBgr: Mat
            val workInputMask: Mat
            if (padLeft > 0 || padRight > 0 || padTop > 0 || padBottom > 0) {
                paddedBgr = Mat()
                paddedMask = Mat()
                Core.copyMakeBorder(
                    cropBgr,
                    paddedBgr,
                    padTop,
                    padBottom,
                    padLeft,
                    padRight,
                    Core.BORDER_REFLECT_101,
                )
                Core.copyMakeBorder(
                    cropMask,
                    paddedMask,
                    padTop,
                    padBottom,
                    padLeft,
                    padRight,
                    Core.BORDER_CONSTANT,
                    Scalar(0.0),
                )
                workInputBgr = paddedBgr
                workInputMask = paddedMask
            } else {
                workInputBgr = cropBgr
                workInputMask = cropMask
            }

            val baseW = workInputBgr.cols()
            val baseH = workInputBgr.rows()
            val maxEdge = max(baseW, baseH)
            val needResize = maxEdge > MAX_INFER_EDGE
            val tw: Int
            val th: Int
            if (needResize) {
                val scale = MAX_INFER_EDGE.toDouble() / maxEdge.toDouble()
                tw = (baseW * scale).toInt().coerceAtLeast(MIN_INFER_EDGE)
                th = (baseH * scale).toInt().coerceAtLeast(MIN_INFER_EDGE)
                feedBgr = Mat()
                feedMask = Mat()
                Imgproc.resize(workInputBgr, feedBgr, Size(tw.toDouble(), th.toDouble()), 0.0, 0.0, Imgproc.INTER_AREA)
                Imgproc.resize(workInputMask, feedMask, Size(tw.toDouble(), th.toDouble()), 0.0, 0.0, Imgproc.INTER_NEAREST)
            } else {
                tw = baseW
                th = baseH
                feedBgr = workInputBgr
                feedMask = workInputMask
            }

            val rawOut = runModel(session, feedBgr, feedMask) ?: return
            inferOut = rawOut

            val fullRestored = if (needResize) {
                restoredPadded = Mat()
                Imgproc.resize(rawOut, restoredPadded, Size(baseW.toDouble(), baseH.toDouble()), 0.0, 0.0, Imgproc.INTER_CUBIC)
                restoredPadded
            } else {
                rawOut
            }

            val cropRestored = if (padLeft > 0 || padRight > 0 || padTop > 0 || padBottom > 0) {
                fullRestored.submat(Rect(padLeft, padTop, cropRect.width, cropRect.height))
            } else {
                fullRestored
            }
            try {
                // 仅在掩膜与窄羽化带内将 AI 修复结果融回原图，掩膜外 100% 保留原始像素
                blendMaskedRegion(cropBgr, cropRestored, cropMask, outSub, featherPx)
            } finally {
                if (cropRestored !== fullRestored) cropRestored.release()
            }
        } finally {
            restoredPadded?.release()
            inferOut?.release()
            if (feedBgr !== paddedBgr && feedBgr !== cropBgr) feedBgr?.release()
            if (feedMask !== paddedMask && feedMask !== cropMask) feedMask?.release()
            paddedBgr?.release()
            paddedMask?.release()
            cropBgr.release()
            cropMask.release()
            srcSub.release()
            maskSub.release()
            outSub.release()
        }
    }

    /** 执行单次 ONNX Runtime 推理（返回新 BGR `Mat`，若无有效掩膜则返回 null）。 */
    private fun runModel(session: OrtSession, bgrMat: Mat, maskMat: Mat): Mat? {
        val w = bgrMat.cols()
        val h = bgrMat.rows()
        val planeSize = w * h
        val bgrCont = if (bgrMat.isContinuous) bgrMat else bgrMat.clone()
        val maskCont = if (maskMat.isContinuous) maskMat else maskMat.clone()

        val bgrBytes = ByteArray(planeSize * 3)
        val maskBytes = ByteArray(planeSize)
        try {
            bgrCont.get(0, 0, bgrBytes)
            maskCont.get(0, 0, maskBytes)
        } finally {
            if (bgrCont !== bgrMat) bgrCont.release()
            if (maskCont !== maskMat) maskCont.release()
        }

        // ⚠️ MI-GAN 掩膜极性：0 = 待修复区域，255 = 保留原始背景（与 OpenCV 白=修复 刚好相反）
        var holePixels = 0
        val maskChw = ByteBuffer.allocateDirect(planeSize)
        for (i in 0 until planeSize) {
            val v = maskBytes[i].toInt() and 0xFF
            if (v > 127) {
                maskChw.put(0.toByte())
                holePixels++
            } else {
                maskChw.put(255.toByte())
            }
        }
        if (holePixels == 0) return null
        maskChw.rewind()

        // 图像布局转成 NCHW RGB UINT8
        val imgChw = ByteBuffer.allocateDirect(planeSize * 3)
        val imgArr = ByteArray(planeSize * 3)
        var srcIdx = 0
        val gOffset = planeSize
        val bOffset = planeSize * 2
        for (i in 0 until planeSize) {
            imgArr[i] = bgrBytes[srcIdx + 2]           // R
            imgArr[gOffset + i] = bgrBytes[srcIdx + 1] // G
            imgArr[bOffset + i] = bgrBytes[srcIdx]     // B
            srcIdx += 3
        }
        imgChw.put(imgArr)
        imgChw.rewind()

        val env = OrtEnvironment.getEnvironment()
        var imgTensor: OnnxTensor? = null
        var maskTensor: OnnxTensor? = null
        var results: OrtSession.Result? = null
        try {
            // ⚠️ Java byte 有符号，必须显式指定 OnnxJavaType.UINT8，否则 ORT 拒绝输入
            imgTensor = OnnxTensor.createTensor(
                env,
                imgChw,
                longArrayOf(1L, 3L, h.toLong(), w.toLong()),
                OnnxJavaType.UINT8,
            )
            maskTensor = OnnxTensor.createTensor(
                env,
                maskChw,
                longArrayOf(1L, 1L, h.toLong(), w.toLong()),
                OnnxJavaType.UINT8,
            )
            results = session.run(mapOf("image" to imgTensor, "mask" to maskTensor))

            val outTensor = results[0] as? OnnxTensor
                ?: throw IllegalStateException("MI-GAN 输出不是 OnnxTensor")
            val outBuf = outTensor.byteBuffer?.duplicate()
                ?: throw IllegalStateException("MI-GAN 输出 byteBuffer 为空")

            val outBgrBytes = ByteArray(planeSize * 3)
            var dstIdx = 0
            for (i in 0 until planeSize) {
                outBgrBytes[dstIdx] = outBuf.get(bOffset + i)     // B
                outBgrBytes[dstIdx + 1] = outBuf.get(gOffset + i) // G
                outBgrBytes[dstIdx + 2] = outBuf.get(i)           // R
                dstIdx += 3
            }

            val outMat = Mat(h, w, CvType.CV_8UC3)
            outMat.put(0, 0, outBgrBytes)
            return outMat
        } finally {
            results?.close()
            imgTensor?.close()
            maskTensor?.close()
        }
    }

    /** 仅将 `mask` 与 `featherPx` 窄过渡带内的 AI 输出写回 `dst`，外部像素保持原样零改动。 */
    private fun blendMaskedRegion(
        src: Mat,
        repaired: Mat,
        mask: Mat,
        dst: Mat,
        featherPx: Int,
    ) {
        if (featherPx <= 0) {
            repaired.copyTo(dst, mask)
            return
        }
        val alpha = Mat()
        val alpha3 = Mat()
        val srcF = Mat()
        val repF = Mat()
        val delta = Mat()
        val scaled = Mat()
        val blended = Mat()
        try {
            mask.convertTo(alpha, CvType.CV_32F, 1.0 / 255.0)
            val k = (featherPx * 2 + 1).toDouble()
            Imgproc.GaussianBlur(alpha, alpha, Size(k, k), 0.0)
            // 保证原掩膜内部严格为 1.0，防止边缘模糊反过来把水印像素带回洞内
            alpha.setTo(Scalar(1.0), mask)
            Core.merge(listOf(alpha, alpha, alpha), alpha3)

            src.convertTo(srcF, CvType.CV_32FC3)
            repaired.convertTo(repF, CvType.CV_32FC3)
            Core.subtract(repF, srcF, delta)
            Core.multiply(delta, alpha3, scaled)
            Core.add(srcF, scaled, blended)
            blended.convertTo(dst, CvType.CV_8UC3)
        } finally {
            alpha.release()
            alpha3.release()
            srcF.release()
            repF.release()
            delta.release()
            scaled.release()
            blended.release()
        }
    }

    private fun getOrCreateSession(context: Context): OrtSession {
        cachedSession?.let { return it }
        synchronized(this) {
            cachedSession?.let { return it }
            val modelFile = ensureModelFile(context)
            val env = OrtEnvironment.getEnvironment()
            val options = OrtSession.SessionOptions()
            try {
                // 手机端关闭 CPU Arena 内存池：同速下峰值内存从 +132MB 压降到 +14MB
                options.setCPUArenaAllocator(false)
                options.setIntraOpNumThreads(
                    Runtime.getRuntime().availableProcessors().coerceIn(2, 4),
                )
                options.setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
                val session = env.createSession(modelFile.absolutePath, options)
                cachedSession = session
                Log.i(TAG, "MI-GAN 会话初始化完成: ${modelFile.absolutePath}")
                return session
            } finally {
                options.close()
            }
        }
    }

    private fun ensureModelFile(context: Context): File {
        val target = File(context.filesDir, ASSET_PATH)
        if (target.exists() && target.length() == EXPECTED_MODEL_BYTES) {
            return target
        }
        target.parentFile?.mkdirs()
        val tmp = File(target.parentFile, "${target.name}.tmp")
        if (tmp.exists()) tmp.delete()

        var copied = 0L
        context.assets.open(ASSET_PATH).use { input ->
            FileOutputStream(tmp).use { output ->
                val buf = ByteArray(1024 * 1024)
                while (true) {
                    val read = input.read(buf)
                    if (read <= 0) break
                    output.write(buf, 0, read)
                    copied += read
                }
                output.fd.sync()
            }
        }
        if (copied != EXPECTED_MODEL_BYTES) {
            tmp.delete()
            throw IllegalStateException("MI-GAN 模型体积校验失败：期望 $EXPECTED_MODEL_BYTES 字节，实际 $copied 字节")
        }
        if (target.exists()) target.delete()
        if (!tmp.renameTo(target)) {
            tmp.delete()
            throw IllegalStateException("MI-GAN 模型落盘重命名失败：${target.absolutePath}")
        }
        return target
    }
}
