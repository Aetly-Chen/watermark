import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../domain/history_item.dart';

/// 历史记录的持久化接口。和 `ThemeModeStore` 同一个套路：
/// App 私有目录里一个 JSON 文件，测试可注入内存实现或临时目录。
abstract interface class HistoryStore {
  Future<List<HistoryItem>> read();

  Future<void> write(List<HistoryItem> items);
}

class MemoryHistoryStore implements HistoryStore {
  MemoryHistoryStore([List<HistoryItem>? initial])
    : items = List<HistoryItem>.of(initial ?? const <HistoryItem>[]);

  List<HistoryItem> items;
  int writeCount = 0;

  @override
  Future<List<HistoryItem>> read() async => List<HistoryItem>.of(items);

  @override
  Future<void> write(List<HistoryItem> items) async {
    this.items = List<HistoryItem>.of(items);
    writeCount++;
  }
}

/// `<应用支持目录>/history.json`。
///
/// 结构：`{"version":1,"items":[...]}`。带 version 是为了以后加字段时能升级，
/// 而不是把旧文件当成坏数据删掉。
class FileHistoryStore implements HistoryStore {
  const FileHistoryStore({this.directory});

  final Future<Directory> Function()? directory;

  static const String fileName = 'history.json';
  static const int schemaVersion = 1;

  Future<File> _file() async {
    final dir = directory != null
        ? await directory!()
        : await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$fileName');
  }

  @override
  Future<List<HistoryItem>> read() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return const <HistoryItem>[];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) return const <HistoryItem>[];
      final raw = decoded['items'];
      if (raw is! List) return const <HistoryItem>[];
      return raw
          .whereType<Map<String, Object?>>()
          .map(HistoryItem.fromJson)
          .where((item) => item.id.isNotEmpty)
          .toList(growable: false);
    } on Object {
      // 文件坏了就当没有 —— 丢历史不能比「打不开 App」更严重。
      return const <HistoryItem>[];
    }
  }

  @override
  Future<void> write(List<HistoryItem> items) async {
    try {
      final file = await _file();
      await file.writeAsString(
        jsonEncode(<String, Object?>{
          'version': schemaVersion,
          'items': items.map((item) => item.toJson()).toList(growable: false),
        }),
        flush: true,
      );
    } on Object {
      // 存不下只影响「下次还能看到」，不该打断当前任务。
    }
  }
}
