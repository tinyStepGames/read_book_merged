import 'favorite_update_store.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../sources/source_adapter.dart';

class LibraryItem {
  const LibraryItem({
    required this.sourceId,
    required this.tab,
    required this.work,
    required this.updatedAt,
    this.chapter,
  });

  final String sourceId;
  final SourceTab tab;
  final ComicWork work;
  final ComicChapter? chapter;
  final DateTime updatedAt;

  String get workKey => jsonEncode([sourceId, tab.query.language, work.id]);

  String get historyKey =>
      jsonEncode([sourceId, tab.query.language, work.id, chapter?.id]);

  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'tab': tab.toJson(),
    'work': work.toJson(),
    'chapter': chapter?.toJson(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  factory LibraryItem.fromJson(Map<String, dynamic> data) {
    final chapter = data['chapter'];

    return LibraryItem(
      sourceId: data['sourceId'] as String,
      tab: SourceTab.fromJson(Map<String, dynamic>.from(data['tab'] as Map)),
      work: ComicWork.fromJson(Map<String, dynamic>.from(data['work'] as Map)),
      chapter: chapter == null
          ? null
          : ComicChapter.fromJson(Map<String, dynamic>.from(chapter as Map)),
      updatedAt: DateTime.parse(data['updatedAt'] as String),
    );
  }
}

/// HTMLやサイトのURL構造を知らない、共通のユーザーデータ保存層。
class UserLibraryStore extends ChangeNotifier {
  UserLibraryStore(this.root);

  static final Map<String, UserLibraryStore> _instances = {};

  static UserLibraryStore forRoot(Directory root) =>
      _instances.putIfAbsent(root.absolute.path, () => UserLibraryStore(root));

  final Directory root;

  List<LibraryItem> _favorites = [];
  List<LibraryItem> _history = [];

  Future<void>? _initializing;
  Future<void> _pending = Future<void>.value();

  List<LibraryItem> get favorites => List.unmodifiable(_favorites);
  List<LibraryItem> get history => List.unmodifiable(_history);

  File get _file => File(p.join(root.path, '_library', 'user-library.json'));

  Future<void> load() => _initializing ??= _read();

  Future<void> _read() async {
    if (!await _file.exists()) return;

    final data = jsonDecode(await _file.readAsString());

    if (data is! Map || data['version'] != 1) {
      throw const FormatException('お気に入り・履歴の保存形式が不正です');
    }

    List<LibraryItem> decode(Object? value) {
      return (value as List)
          .map(
            (item) =>
                LibraryItem.fromJson(Map<String, dynamic>.from(item as Map)),
          )
          .toList();
    }

    final favorites = decode(data['favorites']);
    final history = decode(data['history']);

    if (history.any((item) => item.chapter == null)) {
      throw const FormatException('閲覧履歴の情報が不正です');
    }

    _favorites = favorites;
    // latest-history-per-work-v1
    final ordered = List<LibraryItem>.of(history)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    final seenWorks = <String>{};

    _history = ordered
        .where((item) => seenWorks.add(item.workKey))
        .take(200)
        .toList();

    notifyListeners();
  }

  bool isFavorite(String sourceId, SourceTab tab, ComicWork work) {
    final key = jsonEncode([sourceId, tab.query.language, work.id]);
    return _favorites.any((item) => item.workKey == key);
  }

  Future<void> _serialize(Future<void> Function() action) {
    final operation = _pending.then((_) async {
      await load();
      await action();
    });

    // 失敗は呼び出し元へ返し、後続処理のキューは継続可能にする。
    _pending = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );

    return operation;
  }

  Future<void> _commit(
    List<LibraryItem> favorites,
    List<LibraryItem> history,
  ) async {
    final file = _file;
    await file.parent.create(recursive: true);

    final temporary = File('${file.path}.part');

    await temporary.writeAsString(
      jsonEncode({
        'version': 1,
        'favorites': favorites.map((item) => item.toJson()).toList(),
        'history': history.map((item) => item.toJson()).toList(),
      }),
      flush: true,
    );

    await temporary.rename(file.path);

    // 書き込みに成功してから画面へ反映。
    _favorites = favorites;
    _history = history;
    notifyListeners();
  }

  Future<void> toggleFavorite(String sourceId, SourceTab tab, ComicWork work) =>
      _serialize(() async {
        final item = LibraryItem(
          sourceId: sourceId,
          tab: tab,
          work: work,
          updatedAt: DateTime.now().toUtc(),
        );

        final exists = _favorites.any((entry) => entry.workKey == item.workKey);

        final next = _favorites
            .where((entry) => entry.workKey != item.workKey)
            .toList();

        if (!exists) next.insert(0, item);

        await _commit(next, List.of(_history));
      });

  Future<void> remember(
    String sourceId,
    SourceTab tab,
    ComicWork work,
    ComicChapter chapter,
  ) => _serialize(() async {
    if (chapter.sourceId != sourceId ||
        chapter.language != tab.query.language ||
        chapter.workId != work.id) {
      throw const FormatException('作品とチャプターの組み合わせが不正です');
    }

    final item = LibraryItem(
      sourceId: sourceId,
      tab: tab,
      work: work,
      chapter: chapter,
      updatedAt: DateTime.now().toUtc(),
    );

    final next = [
      item,
      ..._history.where((entry) => entry.workKey != item.workKey),
    ].take(200).toList();

    await _commit(List.of(_favorites), next);

    await FavoriteUpdateStore.forRoot(root).markRead(item.workKey, chapter.id);
  });

  Future<void> removeHistory(LibraryItem item) => _serialize(() async {
    await _commit(
      List.of(_favorites),
      _history.where((entry) => entry.historyKey != item.historyKey).toList(),
    );
  });

  Future<void> clearHistory(String sourceId) => _serialize(() async {
    await _commit(
      List.of(_favorites),
      _history.where((entry) => entry.sourceId != sourceId).toList(),
    );
  });
}
