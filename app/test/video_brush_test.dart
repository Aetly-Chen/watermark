import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:watermark_remover/features/image_editor/domain/mask_draft.dart';
import 'package:watermark_remover/features/image_editor/infrastructure/mask_composer.dart';
import 'package:watermark_remover/features/video_editor/application/video_edit_controller.dart';

/// 视频「涂抹」这条新路径的两半：
/// 1. 遮罩 PNG 到底画成了什么（[MaskComposer.renderMaskPng]）
/// 2. 状态层的判据（只有笔迹算不算有东西要修、草稿怎么合）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 把 PNG 解出来，读某个点的灰度
  Future<int> gray(ByteData png, int x, int y, int width) async {
    final codec = await ui.instantiateImageCodec(png.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    final raw = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final i = (y * width + x) * 4;
    final v = raw!.getUint8(i); // R 通道，黑白图的灰度
    frame.image.dispose();
    codec.dispose();
    return v;
  }

  group('renderMaskPng', () {
    test('尺寸与传入一致，涂抹处是白、别处是黑', () async {
      const w = 200;
      const h = 100;
      // 在 (0.1,0.1)-(0.3,0.3) 涂一笔
      final draft = MaskDraft(
        strokes: <MaskStroke>[
          MaskStroke(
            points: const <Offset>[
              Offset(0.1, 0.1),
              Offset(0.3, 0.3),
            ],
            width: 0.05,
            erase: false,
          ),
        ],
      );

      final bytes = await MaskComposer.renderMaskPng(
        width: w,
        height: h,
        draft: draft,
      );
      final png = ByteData.sublistView(bytes);

      // 笔迹中间：白
      expect(await gray(png, 40, 20, w), greaterThan(200),
          reason: '涂抹处必须进遮罩');
      // 远离笔迹：黑
      expect(await gray(png, 180, 90, w), lessThan(50), reason: '没涂的地方不能进遮罩');
    });

    test('橡皮把涂过的地方擦回去', () async {
      const w = 120;
      const h = 120;
      final draft = MaskDraft(
        strokes: <MaskStroke>[
          // 先涂满一条横线
          MaskStroke(
            points: const <Offset>[Offset(0.1, 0.5), Offset(0.9, 0.5)],
            width: 0.2,
            erase: false,
          ),
          // 再从中间擦掉
          MaskStroke(
            points: const <Offset>[Offset(0.4, 0.5), Offset(0.6, 0.5)],
            width: 0.2,
            erase: true,
          ),
        ],
      );

      final bytes = await MaskComposer.renderMaskPng(
        width: w,
        height: h,
        draft: draft,
      );
      final png = ByteData.sublistView(bytes);

      expect(await gray(png, 60, 60, w), lessThan(50), reason: '擦过的地方要变黑');
      expect(await gray(png, 15, 60, w), greaterThan(200),
          reason: '没擦到的笔画还要留着');
    });

    test('空草稿直接拒绝，不生成一张全黑的遮罩', () async {
      expect(
        () => MaskComposer.renderMaskPng(
          width: 10,
          height: 10,
          draft: const MaskDraft.empty(),
        ),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('VideoEditState 的草稿判据', () {
    test('只有橡皮 = 什么都没涂，不能开始修复', () {
      const state = VideoEditState(
        strokes: <MaskStroke>[
          MaskStroke(points: <Offset>[Offset(0.2, 0.2)], width: 0.05, erase: true),
        ],
      );
      expect(state.hasMask, isFalse);
      expect(state.draft.isEmpty, isTrue);
    });

    test('矩形和笔迹可以共存，draft 把两者都带上', () {
      const state = VideoEditState(
        selection: Rect.fromLTRB(0.1, 0.1, 0.4, 0.4),
        strokes: <MaskStroke>[
          MaskStroke(points: <Offset>[Offset(0.6, 0.6)], width: 0.05, erase: false),
        ],
      );
      expect(state.hasMask, isTrue);
      expect(state.draft.rect, isNotNull);
      expect(state.draft.strokes, hasLength(1));
    });

    test('clearSelection 会把笔迹一起清掉（「清除」按钮只清一半会很怪）', () {
      const state = VideoEditState(
        selection: Rect.fromLTRB(0.1, 0.1, 0.4, 0.4),
        strokes: <MaskStroke>[
          MaskStroke(points: <Offset>[Offset(0.6, 0.6)], width: 0.05, erase: false),
        ],
      );
      final cleared = state.copyWith(clearSelection: true);
      expect(cleared.selection, isNull);
      expect(cleared.strokes, isEmpty);
      expect(cleared.hasMask, isFalse);
    });
  });
}
