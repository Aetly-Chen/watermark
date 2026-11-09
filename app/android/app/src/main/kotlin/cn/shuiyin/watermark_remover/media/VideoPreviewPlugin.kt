package cn.shuiyin.watermark_remover.media

import android.graphics.SurfaceTexture
import android.media.MediaPlayer
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.view.TextureRegistry

/** 预览插件的日志标签（探针与失败都走它）。 */
private const val TAG = "WmVideoPreview"

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
                    val s2 = Session(e, ready, s)
                    session = s2
                    // 走 play() 而不是直接 ready.start()：探针挂在 play() 里，
                    // 直接调 start() 会让「打开就自动播」这条路径漏掉统计
                    s2.play()
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
        private val probe = FrameProbe(entry.surfaceTexture())

        fun play() {
            if (!player.isPlaying) {
                player.start()
                probe.start()
            }
        }

        fun pause() {
            if (player.isPlaying) {
                player.pause()
                probe.stop()
            }
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
            probe.stop()
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

    /**
     * 帧到达探针：只读 [SurfaceTexture.getTimestamp]，每 50ms 采一次。
     *
     * ## 为什么需要它
     *
     * 预览是 `MediaPlayer` 直接把帧送进 SurfaceTexture → Flutter 的 `Texture`，
     * **没有独立图层**，所以 `dumpsys gfxinfo`（只统计 App 自己的绘制）和
     * `dumpsys SurfaceFlinger --latency`（要图层名）都看不见视频帧。
     * 之前「循环接缝会不会打盹」只能靠连拍截图猜（精度 930ms），
     * 100~500ms 级别的卡顿根本量不出来。
     *
     * ## 为什么不挂 OnFrameAvailableListener
     *
     * `setOnFrameAvailableListener` 是**单槽**的，Flutter 的
     * `SurfaceTextureEntry` 已经占用了它去驱动引擎。我们再设一次会把引擎的顶掉，
     * 画面直接不动。所以这里只做轮询：`getTimestamp()` 由 `updateTexImage` 刷新，
     * 引擎刷一次，我们读一次，互不干扰。
     *
     * 没有新帧时时间戳不变 —— 这正是判据：**时间戳连续不变超过阈值 = 卡了**。
     *
     * 只打异常和结束时的汇总，正常播放时一行都不输出。
     */
    private class FrameProbe(private val st: SurfaceTexture) {
        private val handler = Handler(Looper.getMainLooper())
        private var lastTs = -1L
        private var lastChangeAt = 0L
        private var frames = 0
        private var maxGapMs = 0L
        private var slowCount = 0
        private var stallCount = 0
        private var running = false

        private val tick = object : Runnable {
            override fun run() {
                if (!running) return
                val ts = try {
                    st.timestamp
                } catch (e: Throwable) {
                    -1L
                }
                val now = SystemClock.elapsedRealtime()
                if (ts > 0 && ts != lastTs) {
                    if (lastChangeAt > 0) {
                        val gap = now - lastChangeAt
                        if (gap > SLOW_GAP_MS) {
                            slowCount++
                            // **媒体时间增量**是判「真停顿」还是「采样漏掉」的关键：
                            //   mediaDelta ≈ 0  → 画面真的冻住了（解码器 / 循环在 flush）
                            //   mediaDelta ≈ gap → 播放时间正常推进，是我 50ms 采样漏了帧
                            //
                            // 这条判据是后加的，加之前我差点把「7 次 202ms 空档」当成
                            // 「每次循环卡 200ms」报出去 —— 其实媒体增量也是 200ms 上下，
                            // 播放根本没停。**没有媒体增量就不要对空档下结论。**
                            val mediaDelta = (ts - lastTs) / 1_000_000
                            val stall = mediaDelta < gap / 2
                            // **只在真停顿时出声**：50ms 采样天然会漏掉 30fps 的帧，
                            // 那些「空档」媒体增量都≈间隔，打出来只会刷屏、还会误导人。
                            // 实测 70 秒 / 约 14 次循环：空档 11 次，真停顿 0 次。
                            if (stall) {
                                stallCount++
                                Log.w(
                                    TAG,
                                    "preview 真停顿 ${gap}ms（媒体只推进 ${mediaDelta}ms）",
                                )
                            }
                        }
                        if (gap > maxGapMs) maxGapMs = gap
                    }
                    lastTs = ts
                    lastChangeAt = now
                    frames++
                }
                handler.postDelayed(this, SAMPLE_MS)
            }
        }

        fun start() {
            if (running) return
            running = true
            lastTs = -1L
            lastChangeAt = 0L
            frames = 0
            maxGapMs = 0L
            slowCount = 0
            stallCount = 0
            handler.post(tick)
        }

        fun stop() {
            if (!running) return
            running = false
            handler.removeCallbacks(tick)
            // frames=0 说明这个探针在拿不到时间戳，别拿它的数字当证据
            Log.i(
                TAG,
                "preview 帧统计: 有帧的采样=$frames maxGap=${maxGapMs}ms " +
                    "空档(>${SLOW_GAP_MS}ms)=$slowCount 其中真停顿=$stallCount" +
                    "（采样 ${SAMPLE_MS}ms，帧数不能当帧率看）",
            )
        }

        private companion object {
            const val SAMPLE_MS = 50L
            const val SLOW_GAP_MS = 200L
        }
    }
}
