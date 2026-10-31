/// 字节数的展示格式化。
///
/// 原来是 `history_format.dart` 里的 `formatHistoryBytes`，但「我的」页要显示缓存
/// 占用、结果卡要显示视频体积都要用它 —— 它从来不是历史专用的，搬到 core 免得
/// 两个 feature 各自再写一份。
library;

/// `900 KB` / `1.2 MB` / `8.4 MB`。进制用 1024，和系统「文件大小」一致。
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;
  if (bytes < mb) return '${(bytes / kb).round()} KB';
  if (bytes < gb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  return '${(bytes / gb).toStringAsFixed(1)} GB';
}
