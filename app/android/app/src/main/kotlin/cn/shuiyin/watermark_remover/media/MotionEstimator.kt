package cn.shuiyin.watermark_remover.media

import android.graphics.BitmapFactory
import android.util.Log
import org.opencv.android.Utils
import org.opencv.calib3d.Calib3d
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.MatOfByte
import org.opencv.core.MatOfFloat
import org.opencv.core.MatOfPoint
import org.opencv.core.MatOfPoint2f
import org.opencv.core.Point
import org.opencv.core.Size
import org.opencv.core.TermCriteria
import org.opencv.imgproc.Imgproc
import org.opencv.video.Video
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.hypot
import kotlin.math.sqrt

/**
 * 帧间全局运动估计：**相似变换**（旋转 + 等比缩放 + 平移，4 自由度），不是完整单应。
 *
 * ## 为什么是相似变换而不是单应
 *
 * 单应（8 自由度）能表达透视，但水印贴在平面素材上时，透视只有 8 个参数里的 2 个有意义，
 * 其余 6 个自由度全在拟合噪声 —— 素材纹理弱（天空、纯色墙）时它会解出带明显切变/拉伸的矩阵，
 * 水印框被拉歪。4 个自由度的相似变换**不会被噪声推歪**，代价是拍倾斜屏幕那种真透视跟不住。
 * 第一版选稳的那条。
 *
 * ## 为什么在 320 宽上用算
 *
 * goodFeaturesToTrack 的代价跟像素数线性相关：960×540 是 518k 像素，320×180 只有 58k。
 * 位移是全局的，缩到 1/3 之后精度损失不到 1 像素（LK 亚像素插值本来就有 ~0.1px 误差），
 * 但耗时能降到 1/9。解出来的平移量再乘回去。
 *
 * ## 判据：内点数量
 *
 * 低于 [MIN_INLIERS] 就认为「这一帧估不准」，返回 `ok=false` —— 调用方应当**沿用上一帧的变换**，
 * 而不是接受一个乱解。素材纹理太弱时这是常态（比如整帧纯色）。
 */
object MotionEstimator {
    private const val TAG = "WmMotion"

    /** 估计用的工作分辨率宽度。见类注释。 */
    private const val WORK_WIDTH = 320.0

    private const val MAX_CORNERS = 200
    private const val QUALITY_LEVEL = 0.01
    private const val MIN_DISTANCE = 8.0

    /** 内点少于这个数就不接受这次估计。12 个点解 4 个自由度，留有 3 倍冗余。 */
    private const val MIN_INLIERS = 12

    /** RANSAC 重投影阈值（工作分辨率下的像素）。 */
    private const val RANSAC_PX = 3.0

    class Motion(
        /** 2×3 行主序：`[a, b, tx, c, d, ty]`，单位是**原图**像素。 */
        val m: DoubleArray,
        val tracked: Int,
        val inliers: Int,
        val residualPx: Double,
        val ok: Boolean,
    ) {
        val scale: Double get() = sqrt(m[0] * m[0] + m[1] * m[1])
        val rotationDeg: Double get() = Math.toDegrees(atan2(m[3], m[0]))
        val translation: Point get() = Point(m[2], m[5])

        fun apply(x: Double, y: Double): Point =
            Point(m[0] * x + m[1] * y + m[2], m[3] * x + m[4] * y + m[5])

        /** 位移量（像素），只在日志里用。 */
        val shiftPx: Double get() = hypot(m[2], m[5])

        companion object {
            val IDENTITY = Motion(doubleArrayOf(1.0, 0.0, 0.0, 0.0, 1.0, 0.0), 0, 0, 0.0, false)
        }
    }

    /**
     * 估计 `prevGray` → `nextGray` 的全局运动。
     *
     * 两张都必须是 `CV_8UC1` 且同尺寸。返回的矩阵把**上一帧的坐标**映到**当前帧**，
     * 所以「把水印框跟着画面走」就是直接把框的四角用这个矩阵变换一次。
     */
    fun estimate(prevGray: Mat, nextGray: Mat): Motion {
        if (prevGray.empty() || nextGray.empty()) return Motion.IDENTITY
        if (prevGray.type() != CvType.CV_8UC1 || nextGray.type() != CvType.CV_8UC1) {
            throw IllegalArgumentException("需要 8UC1 灰度图")
        }
        if (prevGray.size() != nextGray.size()) return Motion.IDENTITY

        val w = prevGray.cols()
        val h = prevGray.rows()
        val scale = if (w > WORK_WIDTH) WORK_WIDTH / w else 1.0
        val pw = (w * scale).toInt().coerceAtLeast(32)
        val ph = (h * scale).toInt().coerceAtLeast(32)
        val size = Size(pw.toDouble(), ph.toDouble())

        val a = Mat()
        val b = Mat()
        val corners = MatOfPoint()
        val p0 = MatOfPoint2f()
        val p1 = MatOfPoint2f()
        val status = MatOfByte()
        val errs = MatOfFloat()
        val inliers = Mat()
        try {
            if (scale < 1.0) {
                Imgproc.resize(prevGray, a, size, 0.0, 0.0, Imgproc.INTER_AREA)
                Imgproc.resize(nextGray, b, size, 0.0, 0.0, Imgproc.INTER_AREA)
            } else {
                prevGray.copyTo(a)
                nextGray.copyTo(b)
            }

            Imgproc.goodFeaturesToTrack(a, corners, MAX_CORNERS, QUALITY_LEVEL, MIN_DISTANCE)
            val cornerArr = corners.toArray()
            if (cornerArr.size < MIN_INLIERS) {
                Log.w(TAG, "特征点只有 ${cornerArr.size} 个，跳过这一帧的运动估计")
                return Motion.IDENTITY
            }
            p0.fromArray(*cornerArr)

            Video.calcOpticalFlowPyrLK(
                a, b, p0, p1, status, errs,
                Size(21.0, 21.0), 3,
                TermCriteria(TermCriteria.COUNT or TermCriteria.EPS, 30, 0.01),
                0, 1e-4,
            )

            val arr0 = p0.toArray()
            val arr1 = p1.toArray()
            val st = status.toArray()
            val from = ArrayList<Point>(arr0.size)
            val to = ArrayList<Point>(arr0.size)
            for (i in arr0.indices) {
                if (st[i].toInt() != 1) continue
                // LK 跟丢的点会给到画面外或 NaN，喂给 RANSAC 只会拉低稳定性
                if (!isFinite(arr1[i]) || !insideFrame(arr1[i], pw, ph)) continue
                from.add(arr0[i])
                to.add(arr1[i])
            }
            val tracked = from.size
            if (tracked < MIN_INLIERS) {
                Log.w(TAG, "光流只跟上 $tracked 个点，跳过这一帧")
                return Motion(IDENTITY_M, tracked, 0, 0.0, false)
            }

            val fromM = MatOfPoint2f(*from.toTypedArray())
            val toM = MatOfPoint2f(*to.toTypedArray())
            val affine = try {
                Calib3d.estimateAffinePartial2D(
                    fromM, toM, inliers, Calib3d.RANSAC, RANSAC_PX, 2000, 0.99, 10,
                )
            } finally {
                fromM.release()
                toM.release()
            }
            if (affine == null || affine.empty()) {
                Log.w(TAG, "RANSAC 没解出矩阵")
                return Motion(IDENTITY_M, tracked, 0, 0.0, false)
            }

            val inlierCount = Core.countNonZero(inliers)
            val d = DoubleArray(6)
            affine.get(0, 0, d)
            val residual = meanResidual(d, from, to, inliers)
            affine.release()

            if (inlierCount < MIN_INLIERS) {
                Log.w(TAG, "内点只有 $inlierCount 个，跳过这一帧")
                return Motion(d, tracked, inlierCount, residual, false)
            }

            // 工作分辨率 → 原图：旋转/缩放分量不变，平移除以缩放比
            d[2] /= scale
            d[5] /= scale
            return Motion(d, tracked, inlierCount, residual, true)
        } finally {
            a.release(); b.release(); corners.release()
            p0.release(); p1.release(); status.release(); errs.release(); inliers.release()
        }
    }

    private val IDENTITY_M = doubleArrayOf(1.0, 0.0, 0.0, 0.0, 1.0, 0.0)

    private fun isFinite(p: Point) = !p.x.isNaN() && !p.y.isNaN() && abs(p.x) < 1e6 && abs(p.y) < 1e6

    private fun insideFrame(p: Point, w: Int, h: Int) =
        p.x >= 0 && p.y >= 0 && p.x <= w && p.y <= h

    /** 内点上的平均残差（工作分辨率像素）。用来判断这次估计是不是「勉强凑出来」的。 */
    private fun meanResidual(m: DoubleArray, from: List<Point>, to: List<Point>, inliers: Mat): Double {
        var sum = 0.0
        var n = 0
        val mask = ByteArray(inliers.rows() * inliers.cols())
        inliers.get(0, 0, mask)
        for (i in from.indices) {
            if (mask.getOrNull(i)?.toInt() != 1) continue
            val px = m[0] * from[i].x + m[1] * from[i].y + m[2]
            val py = m[3] * from[i].x + m[4] * from[i].y + m[5]
            sum += hypot(px - to[i].x, py - to[i].y)
            n++
        }
        return if (n == 0) 0.0 else sum / n
    }

    // ------------------------------------------------------------------ 自检

    /**
     * 用**已知真值**验证估计器：把一张真实照片用指定的相似变换 warp 一遍，
     * 再让 [estimate] 去还原，比对误差。
     *
     * 这是唯一能在没有「带真水印的视频」时验证算法正确性的办法 ——
     * 真值是我自己造的，所以误差可以逐项断言，不依赖肉眼。
     *
     * 每个 case 返回：`name / posErrPx / angleErrDeg / scaleErrPx / tracked / inliers / residualPx`。
     */
    fun selfTest(imagePath: String, workWidth: Int = 960): List<Map<String, Any>> {
        val bmp = BitmapFactory.decodeFile(imagePath)
            ?: throw IllegalArgumentException("读不到图片：$imagePath")
        val rgba = Mat()
        val bgr = Mat()
        val gray = Mat()
        try {
            Utils.bitmapToMat(bmp, rgba)
            Imgproc.cvtColor(rgba, bgr, Imgproc.COLOR_RGBA2BGR)
            val scale = workWidth.toDouble() / bgr.cols()
            val resized = Mat()
            Imgproc.resize(
                bgr, resized,
                Size(workWidth.toDouble(), (bgr.rows() * scale).toInt().toDouble()),
                0.0, 0.0, Imgproc.INTER_AREA,
            )
            Imgproc.cvtColor(resized, gray, Imgproc.COLOR_BGR2GRAY)
            resized.release()

            val w = gray.cols().toDouble()
            val h = gray.rows().toDouble()
            val cx = w / 2
            val cy = h / 2

            val cases = listOf(
                Triple("平移", doubleArrayOf(1.0, 0.0, 12.0, 0.0, 1.0, -7.0), 0.0),
                Triple("旋转 3°", rotateAbout(cx, cy, 3.0), 3.0),
                Triple("缩放 1.04 + 平移", scaleAbout(cx, cy, 1.04, 5.0, 9.0), 0.0),
                Triple("复合：旋转 -2.5° + 缩放 0.97 + 平移", compose(rotateAbout(cx, cy, -2.5), scaleAbout(cx, cy, 0.97, -8.0, 6.0)), -2.5),
            )

            val out = ArrayList<Map<String, Any>>(cases.size + 1)
            for ((name, truth, deg) in cases) {
                val warped = Mat()
                try {
                    val tm = Mat(2, 3, CvType.CV_64F)
                    // Kotlin 里 `double...` 是 vararg，直接传 DoubleArray 不匹配，必须解构
                    tm.put(0, 0, *truth)
                    Imgproc.warpAffine(
                        gray, warped, tm, gray.size(),
                        Imgproc.INTER_LINEAR, Core.BORDER_REPLICATE,
                    )
                    tm.release()
                    val est = estimate(gray, warped)
                    out.add(
                        mapOf(
                            "name" to name,
                            "posErrPx" to cornerError(truth, est.m, w, h),
                            "angleErrDeg" to abs(est.rotationDeg - deg),
                            "scaleErr" to abs(est.scale - truthScale(truth)),
                            "tracked" to est.tracked,
                            "inliers" to est.inliers,
                            "residualPx" to est.residualPx,
                            "ok" to est.ok,
                        ),
                    )
                } finally {
                    warped.release()
                }
            }
            return out
        } finally {
            rgba.release(); bgr.release(); gray.release()
            bmp.recycle()
        }
    }

    /** 四角 + 中心，用两个矩阵分别变换后取最大位移。比逐个比对矩阵元素直观得多。 */
    private fun cornerError(truth: DoubleArray, est: DoubleArray, w: Double, h: Double): Double {
        val pts = arrayOf(
            doubleArrayOf(0.0, 0.0), doubleArrayOf(w, 0.0),
            doubleArrayOf(0.0, h), doubleArrayOf(w, h),
            doubleArrayOf(w / 2, h / 2),
        )
        var maxErr = 0.0
        for (p in pts) {
            val tx = truth[0] * p[0] + truth[1] * p[1] + truth[2]
            val ty = truth[3] * p[0] + truth[4] * p[1] + truth[5]
            val ex = est[0] * p[0] + est[1] * p[1] + est[2]
            val ey = est[3] * p[0] + est[4] * p[1] + est[5]
            maxErr = maxOf(maxErr, hypot(tx - ex, ty - ey))
        }
        return maxErr
    }

    private fun truthScale(m: DoubleArray) = sqrt(m[0] * m[0] + m[1] * m[1])

    /** 绕 (cx,cy) 旋转 deg 度。 */
    private fun rotateAbout(cx: Double, cy: Double, deg: Double): DoubleArray {
        val r = Math.toRadians(deg)
        val c = Math.cos(r)
        val s = Math.sin(r)
        return doubleArrayOf(
            c, -s, cx - c * cx + s * cy,
            s, c, cy - s * cx - c * cy,
        )
    }

    /** 绕 (cx,cy) 缩放 k 倍，再平移 (dx,dy)。 */
    private fun scaleAbout(cx: Double, cy: Double, k: Double, dx: Double, dy: Double): DoubleArray =
        doubleArrayOf(k, 0.0, cx - k * cx + dx, 0.0, k, cy - k * cy + dy)

    /**
     * 先 `first` 后 `second`（共同作用于一个点）：结果 = second · first。
     *
     * 写成 3×3 齐次矩阵乘法再取前两行 —— 2×3 直接手推公式最容易在 `t` 那一列漏项。
     */
    fun compose(first: DoubleArray, second: DoubleArray): DoubleArray {
        val a0 = first[0]; val a1 = first[1]; val a2 = first[2]
        val a3 = first[3]; val a4 = first[4]; val a5 = first[5]
        val b0 = second[0]; val b1 = second[1]; val b2 = second[2]
        val b3 = second[3]; val b4 = second[4]; val b5 = second[5]
        return doubleArrayOf(
            b0 * a0 + b1 * a3, b0 * a1 + b1 * a4, b0 * a2 + b1 * a5 + b2,
            b3 * a0 + b4 * a3, b3 * a1 + b4 * a4, b3 * a2 + b4 * a5 + b5,
        )
    }
}
