package cn.shuiyin.watermark_remover.media

import android.graphics.SurfaceTexture
import android.media.MediaPlayer
import android.os.Handler
import android.os.Looper
import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.view.TextureRegistry

/**
 * 修好的视频预览播放器。
 *
 * **为什么不用 `video_player`（内部的 ExoPlayer）**：这台华为 JER-AN10（Android 12）上，
 * media3 1.9.2 的 `MediaCodecSelector` 挑中了 `OMX.hisi.video.decoder.avc`，
 * 而那个解码器 `configure/start` 直接失败：
 *
 * ```
 * Caused by: Decoder init failed: OMX.hisi.video.decoder.avc
 * Caused by: java.lang.IllegalStateException at android.media.MediaCodec.native_stop
 * ```
 *
 * 同一个文件我们自己用 `MediaCodec.createDecoderByType("video/avc")` 能一帧不落地解完
 * （150 帧全解），ffmpeg 全解码零错误，`avcC` 也规范（1 SPS + 1 PPS、lengthSize=4）。
 * 所以既不是码流坏了，也不是设备解不了 —— 是 ExoPlayer 选错了解码器，而
 * `video_player` 不暴露 `MediaCodecSelector`，没法让它换。
 *
 * `MediaPlayer` 走系统播放器同一条通路（`MediaPlayerService` 自己选解码器，等价于
 * `createDecoderByType` 的结果），音视频同步也由它负责，不用自己写 A/V 对齐。
 *
 * 输出的画面通过 `TextureRegistry` 的 SurfaceTexture 交给 Flutter 的 `Texture` widget。
 */
class VideoPreviewPlugin : FlutterPlugin, MethodCallHandler {
    companion object {
        const val CHANNEL = "cn.shuiyin.watermark_remover/video_preview"
    }

    private var registry: TextureRegistry? = null
    private var channel: MethodChannel? = null
    private var session: Session? = null
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPluginBinding) {
        registry = binding.textureRegistry
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        // engine 都要销毁了，播放器必须跟着走：否则 codec 泄漏，
        // 下一次冷启动会撞「无法分配解码器」（这个机型上很敏感）
        session?.close()
        session = null
        registry = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "open" -> open(call.argument<String>("path"), result)
            "play" -> {
                session?.play()
                result.success(null)
            }
            "pause" -> {
                session?.pause()
                result.success(null)
            }
            "seek" -> {
                session?.seekTo((call.argument<Number>("ms") ?: 0).toLong())
                result.success(null)
            }
            "position" -> result.success(session?.positionMs() ?: 0)
            "close" -> {
                session?.close()
                session = null
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun open(path: String?, result: MethodChannel.Result) {
        val reg = registry
        if (reg == null) {
            result.error("no_registry", "纹理注册表不可用", null)
            return
        }
        if (path == null) {
            result.error("bad_args", "缺少 path", null)
            return
        }
        session?.close()
        session = null

        // MediaPlayer 必须在有 Looper 的线程上创建与使用；回调同样回到主线程
        main.post {
            var entry: TextureRegistry.SurfaceTextureEntry? = null
            var player: MediaPlayer? = null
            var surface: Surface? = null
            var replied = false

            fun fail(code: String, message: String) {
                if (replied) return
                replied = true
                try {
                    player?.release()
                } catch (ignored: Throwable) {
                }
                surface?.release()
                entry?.release()
                result.error(code, message, null)
            }

            try {
                val e = reg.createSurfaceTexture()
                entry = e
                val st: SurfaceTexture = e.surfaceTexture()
                val s = Surface(st)
                surface = s

                val mp = MediaPlayer()
                player = mp
                mp.setDataSource(path)
                mp.setSurface(s)
                mp.isLooping = true

                mp.setOnPreparedListener { ready ->
                    if (replied) return@setOnPreparedListener
                    replied = true
                    val w = ready.videoWidth
                    val h = ready.videoHeight
                    // SurfaceTexture 的默认缓冲尺寸要跟视频一致，
                    // 否则画面会被拉伸（Texture 只会按我们给的宽高比铺满）
                    if (w > 0 && h > 0) st.setDefaultBufferSize(w, h)
                    ready.start()
                    val s2 = Session(e, ready, s)
                    session = s2
                    result.success(
                        mapOf(
                            "textureId" to e.id(),
                            "width" to w,
                            "height" to h,
                            "durationMs" to ready.duration,
                        ),
                    )
                }
                mp.setOnErrorListener { _, what, extra ->
                    fail("preview_failed", "解码失败（what=$what extra=$extra）")
                    true
                }
                // 异步准备：prepare() 在主线程上会卡住整帧动画
                mp.prepareAsync()
            } catch (e: Throwable) {
                fail("preview_failed", "${e.javaClass.simpleName}: ${e.message}")
            }
        }
    }

    private class Session(
        private val entry: TextureRegistry.SurfaceTextureEntry,
        private val player: MediaPlayer,
        private val surface: Surface,
    ) {
        fun play() {
            if (!player.isPlaying) player.start()
        }

        fun pause() {
            if (player.isPlaying) player.pause()
        }

        fun seekTo(ms: Long) {
            player.seekTo(ms.toInt())
        }

        fun positionMs(): Long = try {
            player.currentPosition.toLong()
        } catch (e: IllegalStateException) {
            0L
        }

        fun close() {
            try {
                player.stop()
            } catch (ignored: Throwable) {
            }
            try {
                player.release()
            } catch (ignored: Throwable) {
            }
            surface.release()
            entry.release()
        }
    }
}
