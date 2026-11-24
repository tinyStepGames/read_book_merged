import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../sources/source_adapter.dart';

class FavoriteUpdateSnapshot {
  const FavoriteUpdateSnapshot({
    required this.workKey,
    required this.knownIds,
    required this.newIds,
    required this.chapters,
    required this.checkedAt,
  });

  final String workKey;
  final Set<String> knownIds;
  final Set<String> newIds;
  final List<ComicChapter> chapters;
  final DateTime checkedAt;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'workKey': workKey,
    'knownIds': knownIds.toList(),
    'newIds': newIds.toList(),
    'chapters': chapters.map((chapter) => chapter.toJson()).toList(),
    'checkedAt': checkedAt.toUtc().toIso8601String(),
  };

  factory FavoriteUpdateSnapshot.fromJson(Map<String, dynamic> data) {
    if (data['version'] != 1) {
      throw const FormatException('新着記録の形式が不正です');
    }

    return FavoriteUpdateSnapshot(
      workKey: data['workKey'] as String,
      knownIds: Set<String>.from(data['knownIds'] as List),
      newIds: Set<String>.from(data['newIds'] as List),
      chapters: (data['chapters'] as List)
          .map(
            (entry) =>
                ComicChapter.fromJson(Map<String, dynamic>.from(entry as Map)),
          )
          .toList(),
      checkedAt: DateTime.parse(data['checkedAt'] as String),
    );
  }
}

/// サイトのHTML・公開日・URL構造を知らない共通の差分管理。
/// applyには、取得に成功した作品の全チャプター一覧を渡す。
class FavoriteUpdateStore {
  FavoriteUpdateStore(this.root);

  static final Map<String, FavoriteUpdateStore> _instances = {};

  static FavoriteUpdateStore forRoot(Directory root) => _instances.putIfAbsent(
    root.absolute.path,
    () => FavoriteUpdateStore(root),
  );

  final Directory root;

  Future<void> _pending = Future<void>.value();

  File _file(String key) {
    final hash = sha256.convert(utf8.encode(key)).toString();
    return File(p.join(root.path, '_library', 'updates', '$hash.json'));
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final operation = _pending.then((_) => action());

    _pending = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );

    return operation;
  }

  Future<FavoriteUpdateSnapshot?> _read(String key) async {
    final file = _file(key);
    if (!await file.exists()) return null;

    final result = FavoriteUpdateSnapshot.fromJson(
      Map<String, dynamic>.from(jsonDecode(await file.readAsString()) as Map),
    );

    if (result.workKey != key) {
      throw const FormatException('新着記録の作品情報が一致しません');
    }

    return result;
  }

  Future<FavoriteUpdateSnapshot?> read(String key) =>
      _serialize(() => _read(key));

  Future<void> _write(FavoriteUpdateSnapshot snapshot) async {
    final file = _file(snapshot.workKey);
    await file.parent.create(recursive: true);

    final temporary = File('${file.path}.part');

    await temporary.writeAsString(jsonEncode(snapshot.toJson()), flush: true);

    await temporary.rename(file.path);
  }

  /// 初回はnull、2回目以降は今回検出した追加件数を返す。
  Future<int?> apply(String key, List<ComicChapter> chapters) =>
      _serialize(() async {
        if (chapters.isEmpty) {
          throw const FormatException('空の一覧では新着記録を更新しません');
        }

        final ids = chapters.map((chapter) => chapter.id).toSet();

        if (ids.length != chapters.length || ids.any((id) => id.isEmpty)) {
          throw const FormatException('チャプターIDが不正です');
        }

        final previous = await _read(key);

        final additions = previous == null
            ? <String>{}
            : ids.difference(previous.knownIds);

        await _write(
          FavoriteUpdateSnapshot(
            workKey: key,
            // 一時的に一覧から消えた話が再登場しても、
            // 再び新着扱いにしない。
            knownIds: {...?previous?.knownIds, ...ids},
            newIds: {...?previous?.newIds, ...additions},
            chapters: List.of(chapters),
            checkedAt: DateTime.now().toUtc(),
          ),
        );

        return previous == null ? null : additions.length;
      });

  Future<void> markRead(String key, String chapterId) => _serialize(() async {
    final previous = await _read(key);

    if (previous == null || !previous.newIds.contains(chapterId)) {
      return;
    }

    await _write(
      FavoriteUpdateSnapshot(
        workKey: key,
        knownIds: previous.knownIds,
        newIds: {...previous.newIds}..remove(chapterId),
        chapters: previous.chapters,
        checkedAt: previous.checkedAt,
      ),
    );
  });
}
