import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:watermark_remover/core/processing/processing_error.dart';

/// **Dart ↔ Kotlin 的错误码契约**。
///
/// `MediaBridge.kt` 里那 7 个 `ERR_*` 常量靠一行注释约束「与 Dart 侧
/// `ProcessingErrorCode.code` 必须一致」—— 但注释不会报警。
/// 只要有一边改了名字，用户看到的就是 `ProcessingErrorCode.unknown`
/// 的通用「处理失败」，而真正的原因（OOM？权限？格式？）全被吞掉。
///
/// 这类「字符串契约」的漂移**编译期查不出、单侧单测也查不出**，
/// 只能跨文件比对。所以这里直接把 Kotlin 源码读出来，逐个对。
void main() {
  late String kotlin;

  setUpAll(() {
    final file = File(
      'android/app/src/main/kotlin/cn/shuiyin/watermark_remover/media/MediaBridge.kt',
    );
    expect(
      file.existsSync(),
      isTrue,
      reason: '找不到 MediaBridge.kt —— 测试要从 app/ 目录跑（flutter test 的默认 cwd）',
    );
    kotlin = file.readAsStringSync();
  });

  /// 抽 `const val ERR_X = "value"` 里的 value
  List<String> nativeCodes() {
    // 值里允许数字：第一版写成 `[a-z_]+`，结果 `"timeout_v2"` 这种直接被正则跳过，
    // 变异验证时**测试照样绿** —— 一条永远测不出问题的测试。
    final re = RegExp(r'const val ERR_\w+ = "([a-z0-9_]+)"');
    return re.allMatches(kotlin).map((m) => m.group(1)!).toList();
  }

  /// 文件里**声明了几个** ERR_ 常量（不管值长什么样）
  int declaredCount() =>
      RegExp(r'const val ERR_\w+ =').allMatches(kotlin).length;

  test('原生侧的每个错误码，Dart 都认得', () {
    final codes = nativeCodes();
    expect(codes, isNotEmpty, reason: '一个都没抽到，正则或文件结构变了');
    // 抽到的条数必须等于声明的条数 —— 否则有常量因为「值长得不符合正则」被静默跳过，
    // 那这条契约测试就成了摆设
    expect(
      codes.length,
      declaredCount(),
      reason: '有 ERR_ 常量的值没被正则抽到（可能用了大写/数字/特殊字符），契约没被检查到',
    );

    final known = ProcessingErrorCode.values.map((e) => e.code).toSet();
    for (final code in codes) {
      expect(
        known,
        contains(code),
        reason:
            '原生会回 "$code"，但 Dart 的 ProcessingErrorCode 里没有它 —— '
            '用户会看到「处理失败」，真正原因被吞掉',
      );
    }
  });

  test('permission_denied 这类«指路型»错误码必须有可操作的话术', () {
    // 只有这一个码是用户当场能自己解决的，话术里必须能指出去哪儿开
    final code = ProcessingErrorCode.fromCode('permission_denied');
    expect(code, ProcessingErrorCode.permissionDenied);
    expect(code.userMessage, contains('设置'));
  });

  test('未知错误码一律落到 unknown，不抛异常', () {
    expect(ProcessingErrorCode.fromCode('未来才会有的码'), ProcessingErrorCode.unknown);
    expect(ProcessingErrorCode.fromCode(null), ProcessingErrorCode.unknown);
  });
}
