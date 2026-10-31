/// 历史记录的展示格式化。
///
/// 全部是纯函数，`now` 可注入 —— 这样「今天/昨天/更早」这三条分支能在单测里
/// 用固定时间点断言，不用等到第二天再验。
library;

String _two(int n) => n.toString().padLeft(2, '0');

/// `今天 14:20` / `昨天 17:40` / `10-15 09:12` / `2025-12-03 08:00`
String formatHistoryTime(DateTime at, {DateTime? now}) {
  final ref = now ?? DateTime.now();
  final day = DateTime(at.year, at.month, at.day);
  final today = DateTime(ref.year, ref.month, ref.day);
  final diff = today.difference(day).inDays;
  final clock = '${_two(at.hour)}:${_two(at.minute)}';

  if (diff == 0) return '今天 $clock';
  if (diff == 1) return '昨天 $clock';
  if (at.year == ref.year) return '${_two(at.month)}-${_two(at.day)} $clock';
  return '${at.year}-${_two(at.month)}-${_two(at.day)} $clock';
}

/// `00:24` / `1:02:03`
String formatHistoryDuration(Duration d) {
  final hours = d.inHours;
  final minutes = _two(d.inMinutes.remainder(60));
  final seconds = _two(d.inSeconds.remainder(60));
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}
