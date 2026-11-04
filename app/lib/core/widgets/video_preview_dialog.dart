import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../media/video_previewer.dart';
import '../theme/app_tokens.dart';

/// 全屏播放修好的视频。
///
/// 为什么需要它：结果页只有「首帧对比」—— 看得见一帧，看不见整段。
/// 开了「跟随画面」之后水印会不会抖、修完有没有跳帧、音轨在不在，
/// 只有真的播一遍才知道。之前用户必须导出到相册才能看到这些。
///
/// 播放能力来自原生 `MediaPlayer`（见 [VideoPreviewer] 的注释：
/// 这台机器上 ExoPlayer 会选错解码器，`video_player` 用不了）。
///
/// 生命周期上做三件事，三件都必须做：
///   * [dispose] 关掉原生播放器（不关就一直占着解码器，这个机型上第二次预览会失败）；
///   * App 退到后台就暂停，否则黑屏了声音还在放；
///   * 轮询进度，让进度条真的走。
class VideoPreviewDialog extends ConsumerStatefulWidget {
  const VideoPreviewDialog({super.key, required this.path, this.title});

  /// 修好的视频（临时目录里的 mp4）
  final String path;

  /// 顶部标题，默认「预览」
  final String? title;

  static Future<void> show(BuildContext context, String path, {String? title}) {
    return showDialog<void>(
      context: context,
      // 点外面不关：这是播放器，误触一下就得从头看。关闭只有右上角那个按钮。
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.88),
      builder: (_) => VideoPreviewDialog(path: path, title: title),
    );
  }

  @override
  ConsumerState<VideoPreviewDialog> createState() => _VideoPreviewDialogState();
}

class _VideoPreviewDialogState extends ConsumerState<VideoPreviewDialog>
    with WidgetsBindingObserver {
  VideoPreviewHandle? _handle;
  String? _error;
  bool _playing = false;
  Duration _position = Duration.zero;
  Timer? _ticker;

  /// 在 initState 里取一次就存住。
  ///
  /// 不能在 dispose 里 `ref.read` —— provider 已经在拆解中，会抛
  /// `Cannot use "ref" after the provider was disposed`，而那时候播放器
  /// 恰好最需要被关掉（不关就占着解码器）。
  late final VideoPreviewer _previewer;

  @override
  void initState() {
    super.initState();
    _previewer = ref.read(videoPreviewerProvider);
    WidgetsBinding.instance.addObserver(this);
    _open();
  }

  Future<void> _open() async {
    try {
      final handle = await _previewer.open(widget.path);
      if (!mounted) {
        // 等开的时候用户已经关掉了 —— 这时候没人再来 close 它
        await _previewer.close();
        return;
      }
      setState(() {
        _handle = handle;
        _playing = true;
      });
      _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) async {
        if (!mounted || _handle == null) return;
        final pos = await _previewer.position();
        if (!mounted) return;
        setState(() => _position = pos);
      });
    } on VideoPreviewException catch (error) {
      // 文件被清掉了、codec 被别的应用占满、容器不支持 —— 都不该让对话框崩掉
      debugPrint('[preview] 打开失败：$error');
      if (mounted) setState(() => _error = '这段视频暂时播不了');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_handle == null) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _previewer.pause();
      if (mounted && _playing) setState(() => _playing = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _ticker = null;
    // 不 await：dispose 不能异步，原生侧 close 是同步释放
    _previewer.close();
    super.dispose();
  }

  Future<void> _togglePlay() async {
    final handle = _handle;
    if (handle == null) return;
    if (_playing) {
      await _previewer.pause();
      if (mounted) setState(() => _playing = false);
    } else {
      // 原生侧 `isLooping = true`，播到末尾会自己回到开头，所以正常不会停在末尾；
      // 这条只兜「原生把 position 恰好报成末尾」的边界，否则按了播放像没反应。
      if (_position >= handle.duration - const Duration(milliseconds: 200)) {
        await _previewer.seek(Duration.zero);
        if (mounted) setState(() => _position = Duration.zero);
      }
      await _previewer.play();
      if (mounted) setState(() => _playing = true);
    }
  }

  Future<void> _seekTo(double fraction) async {
    final handle = _handle;
    if (handle == null) return;
    final target = Duration(
      milliseconds: (handle.duration.inMilliseconds * fraction).round(),
    );
    await _previewer.seek(target);
    if (mounted) setState(() => _position = target);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final handle = _handle;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 40),
      // 不要在这里用 Flexible/Expanded：Column 是 mainAxisSize.min，
      // 弹性子项在有界高度下会抢走空间，内容反而被挤没。
      // 高度交给 AspectRatio 按宽度算出来。
      //
      // 底板必须是**不透明**的一整块：Dialog 本身是透明的，第一版没有这块板，
      // 真机上背后页面的「修复前 / 对比 / 修复后」和「保存到相册」直接透到
      // 标题与控制条之间，看着像对话框里混进了别的东西（B6/C5 截图）。
      child: Container(
        key: const ValueKey('preview-panel'),
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        decoration: BoxDecoration(
          color: t.media,
          borderRadius: BorderRadius.circular(16),
        ),
        // 画面高度按**对话框自己的可用高度**算，不看 MediaQuery ——
        // 对话框里拿到的 MediaQuery 未必是当前视口（测试环境就差了 360 vs 600）。
        child: LayoutBuilder(
          builder: (context, panel) {
            final avail = panel.maxHeight;
            // 扣掉标题 / 控制条 / 说明这几块固定开销（实测约 150dp）。
            // 矮视口（横屏）必须扣，否则一定溢出：画面吃满对话框、控制条整块消失。
            final stageMaxH = avail.isFinite
                ? math.max(72.0, math.min(avail * 0.55, avail - 150))
                : 220.0;
            final ratio = handle?.aspectRatio ?? 16 / 9;
            var stageW = panel.maxWidth;
            var stageH = stageW / ratio;
            if (stageH > stageMaxH) {
              stageH = stageMaxH;
              stageW = stageH * ratio;
            }
            // 兜底：再矮也让它滚，而不是把控制条裁掉。
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Header(
                    title: widget.title ?? '预览',
                    onClose: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(height: 4),
                  if (_error != null)
                    _ErrorBox(message: _error!)
                  else if (handle == null)
                    const _Loading()
                  else ...[
                    // 用 SizedBox 把尺寸算死，不靠 AspectRatio 自己缩：
                    // Column 是 stretch，子项拿到的是**紧宽度**，AspectRatio 在紧宽度下
                    // 没有收缩余地，只能按 maxHeight 被裁 —— 真机横屏实测画面被拉成
                    // 3.46:1（正常 1.78），控制条被顶出对话框。
                    // Center 把宽度约束放松，画面才能按比例缩窄。
                    Center(
                      child: SizedBox(
                        width: stageW,
                        height: stageH,
                        child: _Stage(
                          textureId: handle.textureId,
                          aspectRatio: handle.aspectRatio,
                          playing: _playing,
                          onTap: _togglePlay,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    _Controls(
                      position: _position,
                      duration: handle.duration,
                      playing: _playing,
                      onToggle: _togglePlay,
                      onSeek: _seekTo,
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    '画面来自刚修好的文件，声音与进度都在。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: t.cream.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.onClose});

  final String title;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: t.cream,
            ),
          ),
        ),
        IconButton(
          key: const ValueKey('preview-close'),
          onPressed: onClose,
          icon: Icon(Icons.close_rounded, color: t.cream, size: 22),
          tooltip: '关闭',
        ),
      ],
    );
  }
}

/// 画面本体。`Texture` 只是把原生的 SurfaceTexture 贴过来，
/// 解码、缩放、音视频同步全在原生侧。
class _Stage extends StatelessWidget {
  const _Stage({
    required this.textureId,
    required this.aspectRatio,
    required this.playing,
    required this.onTap,
  });

  final int textureId;
  final double aspectRatio;
  final bool playing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(
                color: Colors.black,
                child: Texture(
                  key: const ValueKey('preview-texture'),
                  textureId: textureId,
                ),
              ),
              // 暂停时盖一个播放标记，不然「点了没反应」会被当成卡住
              if (!playing)
                Center(
                  child: Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation(t.flame),
            ),
          ),
          const SizedBox(height: 12),
          Text('正在准备…', style: TextStyle(fontSize: 12, color: t.cream)),
        ],
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.videocam_off_outlined,
            size: 28,
            color: t.cream.withValues(alpha: 0.7),
          ),
          const SizedBox(height: 10),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12.5, color: t.cream),
          ),
          const SizedBox(height: 4),
          Text(
            '文件本身可能没坏：可以保存到相册后用系统播放器打开。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              color: t.cream.withValues(alpha: 0.6),
            ),
          ),
        ],
      ),
    );
  }
}

/// 底部控制条：播放/暂停、进度、时间。
class _Controls extends StatelessWidget {
  const _Controls({
    required this.position,
    required this.duration,
    required this.playing,
    required this.onToggle,
    required this.onSeek,
  });

  final Duration position;
  final Duration duration;
  final bool playing;
  final VoidCallback onToggle;
  final ValueChanged<double> onSeek;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final total = duration;
    final pos = position > total ? total : position;
    return Row(
      children: [
        IconButton(
          key: const ValueKey('preview-toggle'),
          onPressed: onToggle,
          icon: Icon(
            playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            color: t.cream,
          ),
          tooltip: playing ? '暂停' : '播放',
        ),
        Text(_clock(pos), style: TextStyle(fontSize: 11, color: t.cream)),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              activeTrackColor: t.flame,
              inactiveTrackColor: t.cream.withValues(alpha: 0.25),
              thumbColor: t.flame,
            ),
            child: Slider(
              key: const ValueKey('preview-seek'),
              value: total.inMilliseconds == 0
                  ? 0
                  : (pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0),
              onChanged: onSeek,
            ),
          ),
        ),
        Text(
          _clock(total),
          style: TextStyle(fontSize: 11, color: t.cream.withValues(alpha: 0.7)),
        ),
        const SizedBox(width: 6),
      ],
    );
  }

  static String _clock(Duration d) {
    final seconds = d.inSeconds;
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}
