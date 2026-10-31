import 'package:flutter_test/flutter_test.dart';
import 'package:watermark_remover/core/processing/processing_error.dart';

/// 错误文案：**detail 必须能到用户眼前**。
///
/// 这条路曾经断在 `ProcessingException.message` —— 它固定返回 `code.userMessage`，
/// 于是原生侧写清楚的原因（「打不开这个视频：可能是封装格式系统不支持…」）
/// 一句都没显示过，用户永远只看到「文件读不出来，可能已损坏」。
/// 失败原因的颗粒度就是这么丢的，而且**看不出丢了**：界面有提示、没报错、看着正常。
void main() {
  group('ProcessingException.message', () {
    test('有 detail 时用 detail，不用通用话术', () {
      const error = ProcessingException(
        ProcessingErrorCode.decodeFailed,
        detail: '打不开这个视频：可能是封装格式系统不支持（AVI / RMVB / WMV 等）',
      );
      expect(error.message, contains('封装格式'));
      expect(error.message, isNot('文件读不出来，可能已损坏'));
    });

    test('没有 detail 时回落通用话术', () {
      const error = ProcessingException(ProcessingErrorCode.outOfMemory);
      expect(error.message, startsWith('图片太大'));
      // 光说「内存不够」用户没出路，得告诉他下一步做什么
      expect(error.message, contains('裁掉无关部分'));
    });

    // OOM 的系统 message 是
    // 「Failed to allocate a 46080012 byte allocation with ...」这种英文。
    // MediaBridge 那边已经改成传 null（原文进日志），这条守住「不把英文怼给用户」。
    test('detail 为空时不会露出系统英文', () {
      const error = ProcessingException(
        ProcessingErrorCode.outOfMemory,
        detail: null,
      );
      expect(error.message, isNot(contains('Failed to allocate')));
      expect(error.message, startsWith('图片太大'));
    });

    test('detail 是空白串也回落，不显示空消息', () {
      const error = ProcessingException(
        ProcessingErrorCode.nativeFailure,
        detail: '   ',
      );
      expect(error.message, '修复引擎出错');
    });

    test('toString 带上 detail，日志里能追溯', () {
      const error = ProcessingException(
        ProcessingErrorCode.unsupportedFormat,
        detail: '形变水印第一版不支持',
      );
      expect(error.toString(), contains('unsupported_format'));
      expect(error.toString(), contains('形变水印'));
    });
  });

  group('ProcessingErrorCode', () {
    test('陌生 code 回落 unknown，不抛', () {
      expect(
        ProcessingErrorCode.fromCode('native-崩溃-新码'),
        ProcessingErrorCode.unknown,
      );
      expect(ProcessingErrorCode.fromCode(null), ProcessingErrorCode.unknown);
    });

    test('已知 code 往返', () {
      for (final value in ProcessingErrorCode.values) {
        expect(ProcessingErrorCode.fromCode(value.code), value);
      }
    });
  });
}
