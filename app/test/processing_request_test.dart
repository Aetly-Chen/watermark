import 'package:flutter_test/flutter_test.dart';
import 'package:watermark_remover/core/processing/mask_plan.dart';
import 'package:watermark_remover/core/processing/processing_request.dart';

/// 修复半径这一条链路的「单一事实来源」。
///
/// 半径以前只能由 [OutputQuality] 推导（标准 6 / 高清 8），界面上没有入口；
/// 现在多了一个 `radius` 覆盖字段。这类「推导 + 覆盖」最容易出的错是**覆盖没生效**
/// （字段加了、getter 忘记用），而它的症状是「用户拖了滑块，成品一模一样」——
/// 肉眼几乎看不出来，只能靠断言。
void main() {
  ProcessingRequest request({
    int? radius,
    OutputQuality quality = OutputQuality.standard,
  }) => ProcessingRequest(
    taskId: 't',
    inputPath: '/in.png',
    outputPath: '/out.png',
    mediaKind: MediaKind.image,
    plan: MaskPlan.fixed(maskPath: '/mask.png'),
    outputQuality: quality,
    radius: radius,
  );

  test('不传半径：按质量档位推导（标准 6 / 高清 8）', () {
    expect(request().inpaintRadius, 6);
    expect(request(quality: OutputQuality.high).inpaintRadius, 8);
  });

  test('传了半径就以它为准（滑块真的能改成品）', () {
    expect(request(radius: 12).inpaintRadius, 12);
    expect(
      request(radius: 3, quality: OutputQuality.high).inpaintRadius,
      3,
      reason: '显式值必须压过档位推导，否则滑块是装饰',
    );
  });

  test('通道里带上的是算出来的那个值，不是 null', () {
    final map = request(radius: 11).toChannelMap();
    expect(map['radius'], 11);
    expect(map.containsKey('radius'), isTrue);
  });
}
