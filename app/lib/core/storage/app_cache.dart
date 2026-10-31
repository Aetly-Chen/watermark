import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// 缓存目录的体检与清理。
///
/// 为什么不是「把 cache 目录清空」：临时目录里混着两类东西 ——
///   * **可再生**的中间产物（封面帧、Mask、示例视频、重编码后的输入图）；
///   * **不可再生**的成果（修好的图 `out_*.png` / 修好的视频 `fixed_*.mp4`）。
/// 用户修完但还没点「保存到相册」时，成果只存在于临时目录。一刀清空等于把
/// 刚做完的活删掉，而界面上的文案还写着「清理缓存」—— 看起来什么都没错。
///
/// 所以规则是**白名单 + 保护名单**：
///   1. 只碰本应用自己生成的文件（按文件名前缀），第三方 SDK 的临时文件不归我们管；
///   2. 成果类前缀在**保护期内（24h）**跳过，并在报告里说明保留了多少；
///      过期的按不可达垃圾清掉 —— 理由见 [_protectedTtl]。
///
/// 这一条是后来补的：最初是「成果永久保护」，结果临时目录只增不减，
/// 而「保留 N 个未导出的成果」这句文案在骗人 —— 那些成果早就没有任何入口了。
///
/// 这在 Android 上另有意义：系统本身会在空间紧张时清 cache 目录，所以任何
/// 「成果」长期只放在 cache 里都是错的 —— 保存到相册才是唯一的持久化路径。

/// 一次体检的结果。
@immutable
class CacheSnapshot {
  const CacheSnapshot({
    this.removableBytes = 0,
    this.keptBytes = 0,
    this.keptCount = 0,
  });

  /// 可以清掉的字节数
  final int removableBytes;

  /// 受保护（保护期内的未导出成果）占用的字节数
  final int keptBytes;

  /// 受保护的文件个数
  final int keptCount;

  bool get isEmpty => removableBytes == 0 && keptCount == 0;
}

/// 一次清理的结果。
@immutable
class CacheClearReport {
  const CacheClearReport({
    this.freedBytes = 0,
    this.failedCount = 0,
    this.keptBytes = 0,
    this.keptCount = 0,
  });

  final int freedBytes;

  /// 删除失败的文件数（被占用 / 权限），不为 0 时界面要如实说
  final int failedCount;
  final int keptBytes;
  final int keptCount;

  bool get hasKept => keptCount > 0;
}

abstract interface class AppCacheStore {
  Future<CacheSnapshot> inspect();

  Future<CacheClearReport> clear();
}

/// 应用自己写在临时目录里的文件前缀。清单来自各链路实际生成的名字：
///   * 图片：`in_<task>.png` / `mask_<task>.png` / `out_<task>.png`
///   * 视频：`poster_<ts>.png` / `fixed_<ts>.mp4` / `result_<ts>.png` / `sample_video.mp4`
///
/// ⚠ 新增任何写进临时目录的文件，**必须把前缀加到这里**，否则它永远清不掉
/// （「清理缓存」只认白名单）。`result_` 是结果页对比用的「修复后首帧」。
const List<String> _ownPrefixes = <String>[
  'in_',
  'mask_',
  'out_',
  'poster_',
  'result_',
  'fixed_',
  'sample_video',
];

/// 成果类前缀：删了就没法重来，必须留 —— **但在保护期内**。
const List<String> _protectedPrefixes = <String>['out_', 'fixed_'];

/// 成果的保护期。
///
/// 一开始这里是「永久保护」，结果临时目录只增不减：每修一次就多一个
/// `out_*.png`（1~2 MB），再也不会被清掉，「清理缓存」还把它们算作
/// 「保留 N 个未导出的成果」—— 而那些东西用户其实**已经拿不到了**：
/// 编辑页的 state 在内存里，App 一重启就没了；历史记录只存元信息，不带
/// `resultPath`。所以超过一天还留在临时目录里的成果，就是不可达的垃圾。
///
/// 24 小时是保守值：够用户「修完去干别的、回来再保存」，又不至于让
/// 几十上百个成果永远堆着。判断依据是文件的真实 mtime。
const Duration _protectedTtl = Duration(hours: 24);

String _basename(String path) => path.split(RegExp(r'[/\\]')).last;

bool _isOwn(String name) => _ownPrefixes.any(name.startsWith);

/// 这个文件是不是「还在保护期内的成果」。
///
/// 读 mtime 失败时**当作受保护**：宁可多留一个，也不要因为一次 stat 异常
/// 把用户刚修好的东西删了。保守的方向永远是「留」。
bool _isProtected(File file, String name, DateTime now) {
  if (!_protectedPrefixes.any(name.startsWith)) return false;
  try {
    final age = now.difference(file.statSync().modified);
    return age < _protectedTtl;
  } on FileSystemException {
    return true;
  }
}

/// 真文件系统实现。`cacheDirectory` 只为测试注入 ——
/// 单测里没有 platform channel，`getTemporaryDirectory()` 会抛 MissingPluginException。
class TempDirCacheStore implements AppCacheStore {
  const TempDirCacheStore({this.cacheDirectory});

  final Future<Directory> Function()? cacheDirectory;

  Future<Directory> _dir() async => cacheDirectory != null
      ? await cacheDirectory!()
      : await getTemporaryDirectory();

  /// `length()` 会在「列表之后、读大小之前被删掉」时抛 —— 那种文件直接当 0，
  /// 不能因为一个文件把整次体检炸掉。
  Future<int> _length(File file) async {
    try {
      return await file.length();
    } on FileSystemException {
      return 0;
    }
  }

  @override
  Future<CacheSnapshot> inspect() async {
    final dir = await _dir();
    // 同步 stat 在 UI 线程上是更快的那个选择：异步版要走一次事件循环往返，
    // 而这里只是一次 lstat。lint 的 avoid_slow_async_io 说的就是这个。
    if (!dir.existsSync()) return const CacheSnapshot();

    var removable = 0;
    var kept = 0;
    var keptCount = 0;
    final now = DateTime.now();

    // 只看顶层、不跟随链接：我们的中间产物都写在顶层，子目录属于第三方 SDK，
    // 那些不归本应用管，也不该被计进「我的缓存」。
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = _basename(entity.path);
      if (!_isOwn(name)) continue;

      final length = await _length(entity);
      if (_isProtected(entity, name, now)) {
        kept += length;
        keptCount++;
      } else {
        removable += length;
      }
    }

    return CacheSnapshot(
      removableBytes: removable,
      keptBytes: kept,
      keptCount: keptCount,
    );
  }

  @override
  Future<CacheClearReport> clear() async {
    final dir = await _dir();
    if (!dir.existsSync()) return const CacheClearReport();

    var freed = 0;
    var failed = 0;
    var kept = 0;
    var keptCount = 0;
    final now = DateTime.now();

    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = _basename(entity.path);
      if (!_isOwn(name)) continue;

      final length = await _length(entity);
      if (_isProtected(entity, name, now)) {
        kept += length;
        keptCount++;
        continue;
      }

      try {
        await entity.delete();
        freed += length;
      } on FileSystemException catch (error) {
        // 被 native 侧占着（OpenCV 刚读完的图）也会落到这里。不中断，计入失败数。
        debugPrint('[cache] 删除失败 ${entity.path}: $error');
        failed++;
      }
    }

    return CacheClearReport(
      freedBytes: freed,
      failedCount: failed,
      keptBytes: kept,
      keptCount: keptCount,
    );
  }
}

/// 测试用：不碰文件系统，直接给定体检/清理结果。
class MemoryCacheStore implements AppCacheStore {
  MemoryCacheStore({
    this.snapshot = const CacheSnapshot(),
    this.report = const CacheClearReport(),
  });

  /// 当前体检结果。清理后会就地更新，测试可据此断言「清完数字变了」。
  CacheSnapshot snapshot;
  final CacheClearReport report;
  int clearCalls = 0;

  @override
  Future<CacheSnapshot> inspect() async => snapshot;

  @override
  Future<CacheClearReport> clear() async {
    clearCalls++;
    snapshot = CacheSnapshot(
      keptBytes: report.keptBytes,
      keptCount: report.keptCount,
    );
    return report;
  }
}

final Provider<AppCacheStore> appCacheStoreProvider = Provider(
  (ref) => const TempDirCacheStore(),
);

/// 「我的」页展示用。清理之后 `ref.invalidate` 它即可刷新。
final FutureProvider<CacheSnapshot> cacheSnapshotProvider =
    FutureProvider<CacheSnapshot>(
      (ref) => ref.watch(appCacheStoreProvider).inspect(),
    );
