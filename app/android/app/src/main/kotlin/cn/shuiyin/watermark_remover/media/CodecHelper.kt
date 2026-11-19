package cn.shuiyin.watermark_remover.media

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.util.Log

/**
 * Android `MediaCodec` 编解码器安全初始化与候选降级工具。
 *
 * 解决单一 `createDecoderByType` / `createEncoderByType` 在不同厂商设备上的常见链路失败：
 * 1. 某些硬件编码器拒绝 HDR10/HLG 色彩标签，需过滤为安全的 8-bit SDR 参数或剥离后重试；
 * 2. 个别厂商硬件解码器遇到非常规流会 `configure` 失败，遍历所有硬解与系统软解候选提升兼容性；
 * 3. `getInputImage` 不兼容或超限码率导致硬编异常时，支持排除已失败编码器并平滑切到下一个候选（含软编）。
 */
object CodecHelper {
    private const val TAG = "WmCodecHelper"
    private const val MIME_AVC = "video/avc"
    private const val FALLBACK_MAX_BITRATE = 12_000_000

    /**
     * 按硬解优先、软解兜底顺序打开并启动视频解码器。
     * 克隆输入 `MediaFormat` 并移除解码器旋转键，确保像素坐标与容器旋转分离设计一致。
     */
    fun openDecoder(sourceFormat: MediaFormat): MediaCodec {
        val mime = sourceFormat.getString(MediaFormat.KEY_MIME)
            ?: throw VideoProcessor.VideoUnsupportedException("视频轨缺少 MIME 类型")

        val candidates = findCodecs(mime, isEncoder = false, excludedNames = emptySet())
        var lastError: Throwable? = null

        for (info in candidates) {
            val format = cloneVideoFormat(sourceFormat)
            val supportsFlexible = supportsColorFormat(
                info,
                mime,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible,
            )
            if (supportsFlexible) {
                format.setInteger(
                    MediaFormat.KEY_COLOR_FORMAT,
                    MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible,
                )
            }
            val codec = try {
                MediaCodec.createByCodecName(info.name)
            } catch (e: Throwable) {
                lastError = e
                continue
            }
            try {
                codec.configure(format, null, null, 0)
                codec.start()
                Log.i(TAG, "打开解码器成功: ${info.name} ($mime)")
                return codec
            } catch (e: Throwable) {
                lastError = e
                Log.w(TAG, "解码器 ${info.name} 启动失败，尝试下一个候选: ${e.message}")
                safeRelease(codec)
            }
        }

        // 最后兜底交给系统默认选择器再试一次
        val fallbackFormat = cloneVideoFormat(sourceFormat)
        val fallback = try {
            MediaCodec.createDecoderByType(mime)
        } catch (e: Throwable) {
            throw VideoProcessor.VideoUnsupportedException(
                "没有可用的视频解码器（$mime）：${lastError?.message ?: e.message}",
            )
        }
        return try {
            fallback.configure(fallbackFormat, null, null, 0)
            fallback.start()
            Log.i(TAG, "使用系统默认解码器成功: ${fallback.name}")
            fallback
        } catch (e: Throwable) {
            safeRelease(fallback)
            throw VideoProcessor.VideoUnsupportedException(
                "解码器无法初始化（$mime）：${lastError?.message ?: e.message}",
            )
        }
    }

    /**
     * 按硬编优先、软编兜底顺序打开并启动 H.264 编码器，可排除已知不兼容的编码器名称。
     * 每个候选编码器依次尝试：透传安全 SDR 色彩参数 → 剥离色彩参数 → 保守码率上限。
     */
    fun openEncoder(
        width: Int,
        height: Int,
        bitrate: Int,
        fps: Int,
        sourceFormat: MediaFormat,
        excludedNames: Set<String> = emptySet(),
    ): MediaCodec {
        val candidates = findCodecs(MIME_AVC, isEncoder = true, excludedNames = excludedNames)
        var lastError: Throwable? = null

        for (info in candidates) {
            if (!isSizeSupported(info, MIME_AVC, width, height)) {
                Log.d(TAG, "编码器 ${info.name} 声明不支持 ${width}x$height，跳过")
                continue
            }

            val attempts = buildEncoderAttempts(width, height, bitrate, fps, sourceFormat)
            for ((desc, fmt) in attempts) {
                val codec = try {
                    MediaCodec.createByCodecName(info.name)
                } catch (e: Throwable) {
                    lastError = e
                    break
                }
                try {
                    codec.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                    codec.start()
                    Log.i(TAG, "打开编码器成功: ${info.name} ($desc ${width}x$height)")
                    return codec
                } catch (e: Throwable) {
                    lastError = e
                    Log.w(TAG, "编码器 ${info.name} ($desc) 配置失败: ${e.message}")
                    safeRelease(codec)
                }
            }
        }

        // 若未在排除名单内，再尝试一次系统默认 createEncoderByType
        val defaultCodec = try {
            MediaCodec.createEncoderByType(MIME_AVC)
        } catch (e: Throwable) {
            throw VideoProcessor.VideoUnsupportedException(
                "没有可用的 H.264 编码器：${lastError?.message ?: e.message}",
            )
        }
        if (defaultCodec.name in excludedNames) {
            safeRelease(defaultCodec)
            throw VideoProcessor.VideoUnsupportedException(
                "所有可用 H.264 编码器均不支持当前参数（${lastError?.message ?: "未知错误"}）",
            )
        }
        return try {
            val fmt = buildEncoderFormat(width, height, bitrate.coerceAtMost(FALLBACK_MAX_BITRATE), fps, null)
            defaultCodec.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            defaultCodec.start()
            Log.i(TAG, "使用系统默认编码器成功: ${defaultCodec.name}")
            defaultCodec
        } catch (e: Throwable) {
            safeRelease(defaultCodec)
            throw VideoProcessor.VideoUnsupportedException(
                "编码器无法初始化（${e.javaClass.simpleName}: ${lastError?.message ?: e.message}）",
            )
        }
    }

    /** 列出匹配 MIME 且未被排除的编解码器：硬件实现排前面，软件实现放最后兜底。 */
    private fun findCodecs(
        mime: String,
        isEncoder: Boolean,
        excludedNames: Set<String>,
    ): List<MediaCodecInfo> {
        val list = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
        val hardware = ArrayList<MediaCodecInfo>()
        val software = ArrayList<MediaCodecInfo>()
        for (info in list) {
            if (info.isEncoder != isEncoder) continue
            if (info.name in excludedNames) continue
            if (!info.supportedTypes.any { it.equals(mime, ignoreCase = true) }) continue
            if (isSoftwareCodec(info)) {
                software.add(info)
            } else {
                hardware.add(info)
            }
        }
        return hardware + software
    }

    private fun isSoftwareCodec(info: MediaCodecInfo): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            return info.isSoftwareOnly
        }
        val lower = info.name.lowercase()
        return lower.startsWith("omx.google.") ||
            lower.startsWith("c2.android.") ||
            lower.contains(".sw.")
    }

    private fun isSizeSupported(info: MediaCodecInfo, mime: String, width: Int, height: Int): Boolean {
        return try {
            val caps = info.getCapabilitiesForType(mime).videoCapabilities ?: return true
            caps.isSizeSupported(width, height)
        } catch (_: Throwable) {
            true
        }
    }

    private fun supportsColorFormat(info: MediaCodecInfo, mime: String, colorFormat: Int): Boolean {
        return try {
            info.getCapabilitiesForType(mime).colorFormats.contains(colorFormat)
        } catch (_: Throwable) {
            false
        }
    }

    /** 构造按兼容度降级的多组编码参数。 */
    private fun buildEncoderAttempts(
        width: Int,
        height: Int,
        bitrate: Int,
        fps: Int,
        sourceFormat: MediaFormat,
    ): List<Pair<String, MediaFormat>> {
        val attempts = ArrayList<Pair<String, MediaFormat>>(3)
        val safeColor = extractSafeSdrColorMeta(sourceFormat)
        if (safeColor.isNotEmpty()) {
            attempts.add("sdrColor" to buildEncoderFormat(width, height, bitrate, fps, safeColor))
        }
        attempts.add("noColorMeta" to buildEncoderFormat(width, height, bitrate, fps, null))
        if (bitrate > FALLBACK_MAX_BITRATE) {
            attempts.add(
                "cappedBitrate" to buildEncoderFormat(width, height, FALLBACK_MAX_BITRATE, fps, null),
            )
        }
        return attempts
    }

    private fun buildEncoderFormat(
        width: Int,
        height: Int,
        bitrate: Int,
        fps: Int,
        colorMeta: Map<String, Int>?,
    ): MediaFormat {
        val fmt = MediaFormat.createVideoFormat(MIME_AVC, width, height)
        fmt.setInteger(
            MediaFormat.KEY_COLOR_FORMAT,
            MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible,
        )
        fmt.setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
        fmt.setInteger(MediaFormat.KEY_FRAME_RATE, fps)
        // 1 秒一个关键帧，保证进度拖动与预览定位准确
        fmt.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        if (colorMeta != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            for ((k, v) in colorMeta) {
                fmt.setInteger(k, v)
            }
        }
        return fmt
    }

    /**
     * 仅提取对 8-bit H.264 安全兼容的 SDR 色彩标签。
     * 遇到 HDR10（ST2084）/ HLG 等 10-bit 传输特性时主动过滤，防止硬编码器直接拒绝 configure。
     */
    private fun extractSafeSdrColorMeta(sourceFormat: MediaFormat): Map<String, Int> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return emptyMap()
        val out = LinkedHashMap<String, Int>()
        if (sourceFormat.containsKey(MediaFormat.KEY_COLOR_STANDARD)) {
            val std = sourceFormat.getInteger(MediaFormat.KEY_COLOR_STANDARD)
            if (std == MediaFormat.COLOR_STANDARD_BT709 ||
                std == MediaFormat.COLOR_STANDARD_BT601_PAL ||
                std == MediaFormat.COLOR_STANDARD_BT601_NTSC
            ) {
                out[MediaFormat.KEY_COLOR_STANDARD] = std
            }
        }
        if (sourceFormat.containsKey(MediaFormat.KEY_COLOR_RANGE)) {
            val range = sourceFormat.getInteger(MediaFormat.KEY_COLOR_RANGE)
            if (range == MediaFormat.COLOR_RANGE_LIMITED ||
                range == MediaFormat.COLOR_RANGE_FULL
            ) {
                out[MediaFormat.KEY_COLOR_RANGE] = range
            }
        }
        if (sourceFormat.containsKey(MediaFormat.KEY_COLOR_TRANSFER)) {
            val transfer = sourceFormat.getInteger(MediaFormat.KEY_COLOR_TRANSFER)
            if (transfer == MediaFormat.COLOR_TRANSFER_SDR_VIDEO) {
                out[MediaFormat.KEY_COLOR_TRANSFER] = transfer
            }
        }
        return out
    }

    private fun cloneVideoFormat(source: MediaFormat): MediaFormat {
        val copy = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaFormat(source)
        } else {
            val mime = source.getString(MediaFormat.KEY_MIME) ?: MIME_AVC
            val w = if (source.containsKey(MediaFormat.KEY_WIDTH)) source.getInteger(MediaFormat.KEY_WIDTH) else 0
            val h = if (source.containsKey(MediaFormat.KEY_HEIGHT)) source.getInteger(MediaFormat.KEY_HEIGHT) else 0
            MediaFormat.createVideoFormat(mime, w, h).also { dst ->
                for (key in arrayOf("csd-0", "csd-1", "csd-2")) {
                    if (source.containsKey(key)) {
                        source.getByteBuffer(key)?.let { dst.setByteBuffer(key, it) }
                    }
                }
                for (key in arrayOf(
                    MediaFormat.KEY_MAX_INPUT_SIZE,
                    MediaFormat.KEY_FRAME_RATE,
                    MediaFormat.KEY_BIT_RATE,
                )) {
                    if (source.containsKey(key)) {
                        dst.setInteger(key, source.getInteger(key))
                    }
                }
            }
        }
        // 移除旋转元数据，避免部分 Android 12+ 解码器在 Buffer 模式下自动重排尺寸导致宽高错位
        if (copy.containsKey(MediaFormat.KEY_ROTATION)) {
            copy.setInteger(MediaFormat.KEY_ROTATION, 0)
        }
        return copy
    }

    private fun safeRelease(codec: MediaCodec) {
        try {
            codec.stop()
        } catch (_: Throwable) {
        }
        try {
            codec.release()
        } catch (_: Throwable) {
        }
    }
}
