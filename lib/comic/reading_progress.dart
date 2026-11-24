import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// サイト固有のURL形式に依存しない閲覧位置の識別情報。
class ReadingKey {
  const ReadingKey({required this.sourceId, required this.chapterId});

  final String sourceId;
  final String chapterId;

  String get fileId =>
      sha256.convert(utf8.encode(jsonEncode([sourceId, chapterId]))).toString();
}

class ReadingProgress {
  const ReadingProgress({
    required this.pageIndex,
    required this.pageCount,
    required this.mode,
    required this.updatedAt,
  });

  final int pageIndex;
  final int pageCount;
  final String mode;
  final DateTime updatedAt;

  Map<String, dynamic> toJson(ReadingKey key) => {
    'version': 1,
    'sourceId': key.sourceId,
    'chapterId': key.chapterId,
    'pageIndex': pageIndex,
    'pageCount': pageCount,
    'mode': mode,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };
}

/// アプリ共通の閲覧位置ストア。
/// ダウンロード画像とは別の領域に保存する。
class ReadingProgressStore {
  ReadingProgressStore._();

  static final instance = ReadingProgressStore._();

  Future<void> _pending = Future<void>.value();

  Future<File> _file(ReadingKey key) async {
    final root = await getApplicationSupportDirectory();
    final directory = Directory(p.join(root.path, 'reading_progress'));
    await directory.create(recursive: true);

    return File(p.join(directory.path, '${key.fileId}.json'));
  }

  Future<ReadingProgress?> load(ReadingKey key) async {
    try {
      // 先行している保存があれば完了を待つ。
      await _pending.catchError((Object error) {});

      final file = await _file(key);
      if (!await file.exists()) return null;

      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;

      if (data['version'] != 1 ||
          data['sourceId'] != key.sourceId ||
          data['chapterId'] != key.chapterId) {
        return null;
      }

      final index = data['pageIndex'] as int;
      final count = data['pageCount'] as int;
      final mode = data['mode'] as String;

      if (index < 0 ||
          count < 1 ||
          index >= count ||
          !['vertical', 'horizontal'].contains(mode)) {
        return null;
      }

      return ReadingProgress(
        pageIndex: index,
        pageCount: count,
        mode: mode,
        updatedAt: DateTime.parse(data['updatedAt'] as String),
      );
    } catch (_) {
      // 不正・破損した記録は使わず、先頭から開く。
      return null;
    }
  }

  Future<void> save(ReadingKey key, ReadingProgress progress) {
    // 保存要求を直列化し、古い書き込みが後から上書きしないようにする。
    final operation = _pending.catchError((Object error) {}).then((_) async {
      final file = await _file(key);
      final temporary = File('${file.path}.part');

      await temporary.writeAsString(
        jsonEncode(progress.toJson(key)),
        flush: true,
      );

      await temporary.rename(file.path);
    });

    _pending = operation;
    return operation;
  }
}
