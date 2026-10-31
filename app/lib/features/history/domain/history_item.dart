import 'package:flutter/foundation.dart';

import 'history_format.dart';

enum HistoryKind {
  image('图片'),
  video('视频');

  const HistoryKind(this.label);

  /// 界面直接显示这个。原来详情页显示的是 `kind.name`（英文 `image` / `video`），
  /// 中文界面里冒一个英文单词出来，是 bug 不是风格。
  final String label;
}

enum TaskStatus {
  succeeded('已完成'),
  failed('失败'),
  cancelled('已取消');

  const TaskStatus(this.label);

  final String label;
}

/// 一条处理记录。字段按「历史页要显示什么」倒推，不预先塞将来可能用不到的字段。
@immutable
class HistoryItem {
  const HistoryItem({
    required this.id,
    required this.title,
    required this.kind,
    required this.status,
    required this.timeLabel,
    required this.metaLabel,
    this.detail,
    this.createdAt = 0,
    this.thumbPath,
  });

  /// 宽容解析：字段缺了或写坏了按默认值走，**绝不因为一条坏记录让整页历史打不开**。
  factory HistoryItem.fromJson(Map<String, Object?> map) => HistoryItem(
    id: map['id'] as String? ?? '',
    title: map['title'] as String? ?? '未命名',
    kind: _byName(HistoryKind.values, map['kind'], HistoryKind.image),
    status: _byName(TaskStatus.values, map['status'], TaskStatus.succeeded),
    timeLabel: map['timeLabel'] as String? ?? '',
    metaLabel: map['metaLabel'] as String? ?? '',
    detail: map['detail'] as String?,
    createdAt: (map['createdAt'] as num?)?.toInt() ?? 0,
    thumbPath: map['thumbPath'] as String?,
  );

  final String id;
  final String title;
  final HistoryKind kind;
  final TaskStatus status;

  /// 写入当时算好的展示字符串（如「今天 14:20」）。
  ///
  /// ⚠ 这只是**老数据的兜底**，界面不要直接拿它显示。原来的注释写着「隔天再打开，
  /// 『今天』自然就变成『昨天』了」—— 那句是错的：字符串一旦落盘就冻住了。
  /// 2026-10-22 在真机上抓到现场：8 条记录跨 10-20～10-22，**全部显示「今天」**。
  /// 一律用 [timeLabelAt] 按 [createdAt] 现算。
  final String timeLabel;

  /// 按 [now] 现算的展示时间。
  ///
  /// [createdAt] 为 0 的是加时间戳之前的旧记录，只能退回落盘字符串 ——
  /// 对它们「今天」确实永远停在写入那天，但至少不会显示成 1970。
  String timeLabelAt(DateTime now) {
    if (createdAt <= 0) return timeLabel;
    return formatHistoryTime(
      DateTime.fromMillisecondsSinceEpoch(createdAt),
      now: now,
    );
  }

  /// 展示用元信息（尺寸 / 时长 / 体积）
  final String metaLabel;

  final String? detail;

  /// 排序依据（越大越新）。为 0 表示老数据，排在最后。
  final int createdAt;

  /// 缩略图文件的绝对路径（`<应用支持目录>/thumbs/<id>.png`）。
  ///
  /// 可空且**永远要按「可能不存在」处理**：生成失败、用户清了数据、或者这条记录
  /// 来自加缩略图之前的版本。列表和详情页都要有图标兜底。
  final String? thumbPath;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'kind': kind.name,
    'status': status.name,
    'timeLabel': timeLabel,
    'metaLabel': metaLabel,
    'detail': detail,
    'createdAt': createdAt,
    'thumbPath': thumbPath,
  };

  static T _byName<T extends Enum>(List<T> values, Object? raw, T fallback) {
    if (raw is! String) return fallback;
    for (final value in values) {
      if (value.name == raw) return value;
    }
    return fallback;
  }
}
