/// 处理失败的统一错误码。
///
/// 跨平台通道只传字符串 code，Dart 侧翻译成枚举；
/// UI 拿 `userMessage` 显示，拿 `code` 决定是否给重试入口。
enum ProcessingErrorCode {
  unsupportedFormat('unsupported_format', '这个格式暂不支持'),
  decodeFailed('decode_failed', '文件读不出来，可能已损坏'),
  invalidMask('invalid_mask', '选区无效，请重新框选'),
  outOfMemory('out_of_memory', '图片太大，内存不够处理。先裁掉无关部分，或换一张小一点的图'),
  cancelled('cancelled', '任务已取消'),
  nativeFailure('native_failure', '修复引擎出错'),

  /// Android 9 及以下保存到相册需要「存储」权限，用户拒绝（或系统没给）时。
  /// 话术要指路，因为这是唯一一个用户自己能当场解决掉的失败。
  permissionDenied(
    'permission_denied',
    '没有存储权限，存不进相册。到「设置 → 应用 → 水印工坊 → 权限」里打开后再试',
  ),
  unknown('unknown', '处理失败');

  const ProcessingErrorCode(this.code, this.userMessage);

  /// 通道上传输的字符串
  final String code;

  /// 直接给用户看的话术
  final String userMessage;

  static ProcessingErrorCode fromCode(String? code) {
    for (final value in ProcessingErrorCode.values) {
      if (value.code == code) return value;
    }
    return ProcessingErrorCode.unknown;
  }
}

class ProcessingException implements Exception {
  const ProcessingException(this.code, {this.detail});

  final ProcessingErrorCode code;

  /// 具体原因：**面向用户**的中文短句（「打不开这个视频：可能是封装格式不支持…」）。
  ///
  /// 这里曾经写的是「不直接展示给用户」，结果 `message` 只返回 `code.userMessage`，
  /// 原生侧辛苦写清楚的原因**一句都没到用户眼前** —— 用户永远只看到
  /// 「文件读不出来，可能已损坏」。失败原因的颗粒度就这么丢了。
  /// 现在反过来：有 detail 就用 detail，通用话术只作兜底。
  /// （约束：detail 必须是能和用户对话的话，内部路径、堆栈一律留在日志里。）
  final String? detail;

  String get message {
    final reason = detail?.trim();
    if (reason == null || reason.isEmpty) return code.userMessage;
    return reason;
  }

  @override
  String toString() =>
      'ProcessingException(${code.code})${detail == null ? '' : ': $detail'}';
}
