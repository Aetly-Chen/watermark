package cn.shuiyin.watermark_remover

import cn.shuiyin.watermark_remover.media.MediaBridge
import cn.shuiyin.watermark_remover.media.VideoPreviewPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var mediaBridge: MediaBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 通道注册放在这里：configureFlutterEngine 与 engine 生命周期一致，
        // 放 onCreate 里重复注册，热重启后会拿到旧 messenger。
        mediaBridge = MediaBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
            .also { it.attach() }

        // 预览播放器要 TextureRegistry，而它只能从 FlutterPluginBinding 拿到，
        // 所以走 FlutterPlugin 注册（GeneratedPluginRegistrant 也是这么做的）。
        flutterEngine.plugins.add(VideoPreviewPlugin())
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        mediaBridge?.dispose()
        mediaBridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
