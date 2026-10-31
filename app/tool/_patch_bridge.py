import io
import re

p = 'MediaBridge.kt'
s = io.open(p, encoding='utf-8').read()

s = s.replace(
    '            "repairVideo" -> handleRepairVideo(call, result)',
    '            "repairVideo" -> handleRepairVideo(call, result)\n'
    '            "motionSelfTest" -> handleMotionSelfTest(call, result)',
    1,
)

old_radius = '        val radius = call.argument<Int>("radius") ?: 4\n'
new_radius = (
    '        val radius = call.argument<Int>("radius") ?: 4\n'
    '        // 默认关闭：静态水印用一张 Mask 就够；开了追踪反而可能把框带偏\n'
    '        // （手上没有真水印素材，追得准不准无法用肉眼验证）\n'
    '        val trackMotion = call.argument<Boolean>("trackMotion") ?: false\n'
)
assert old_radius in s
s = s.replace(old_radius, new_radius, 1)

s = s.replace(
    '                    mask = mask,\n                    radius = radius,\n',
    '                    mask = mask,\n                    radius = radius,\n'
    '                    trackMotion = trackMotion,\n',
    1,
)

anchor = '    private fun handleInpaint(call: MethodCall, result: MethodChannel.Result) {'
addition = '''    /**
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

'''
assert anchor in s
s = s.replace(anchor, addition + anchor, 1)

s = s.replace(
    'import io.flutter.plugin.common.MethodChannel\n',
    'import io.flutter.plugin.common.MethodChannel\nimport org.opencv.android.OpenCVLoader\n',
    1,
)

io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('ok')
