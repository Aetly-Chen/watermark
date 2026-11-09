package cn.shuiyin.watermark_remover

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import cn.shuiyin.watermark_remover.media.MediaBridge
import cn.shuiyin.watermark_remover.media.VideoPreviewPlugin
import cn.shuiyin.watermark_remover.media.WritePermissionDelegate
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity(), WritePermissionDelegate {
    private var mediaBridge: MediaBridge? = null

    private companion object {
        const val REQ_WRITE_STORAGE = 4101
    }

    /** 权限弹窗是异步的，回来的结果要交给发起时挂上的那个回调。 */
    private var pendingWritePermission: ((Boolean) -> Unit)? = null

    override fun ensureWriteStorage(onResult: (Boolean) -> Unit) {
        // Android 10 起走分区存储，插 MediaStore 不需要权限 —— 别多弹一个
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            onResult(true)
            return
        }
        if (checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            onResult(true)
            return
        }
        // 上一次的请求还没回来就再点保存：先把它结果掉，别让那次调用永远挂着
        pendingWritePermission?.invoke(false)
        pendingWritePermission = onResult
        requestPermissions(
            arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),
            REQ_WRITE_STORAGE,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_WRITE_STORAGE) return
        val callback = pendingWritePermission
        pendingWritePermission = null
        callback?.invoke(
            grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED,
        )
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // 通道注册放在这里：configureFlutterEngine 与 engine 生命周期一致，
        // 放 onCreate 里重复注册，热重启后会拿到旧 messenger。
        mediaBridge = MediaBridge(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
            .also { it.attach(permissionDelegate = this) }

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
