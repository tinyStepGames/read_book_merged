import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../sources/source_adapter.dart';

enum ChapterReadState { unread, reading, completed }

String chapterReadStateKey(ComicChapter chapter) => jsonEncode([
  chapter.sourceId,
  chapter.language,
  chapter.workId,
  chapter.id,
]);

class ChapterReadStateStore extends ChangeNotifier {
  ChapterReadStateStore(this.root);

  static final Map<String, ChapterReadStateStore> _instances = {};

  static ChapterReadStateStore forRoot(Directory root) => _instances
      .putIfAbsent(root.absolute.path, () => ChapterReadStateStore(root));

  final Directory root;

  Map<String, ChapterReadState> _states = {};
  Future<void>? _initializing;
  Future<void> _pending = Future<void>.value();

  File get _file =>
      File(p.join(root.path, '_library', 'chapter-read-states.json'));

  Future<void> load() => _initializing ??= _read();

  Future<void> _read() async {
    if (!await _file.exists()) return;

    final data = jsonDecode(await _file.readAsString());

    if (data is! Map || data['version'] != 1 || data['states'] is! Map) {
      throw const FormatException('読書状態の保存形式が不正です');
    }

    final states = <String, ChapterReadState>{};

    for (final entry in (data['states'] as Map).entries) {
      if (entry.key is! String || entry.value is! String) {
        throw const FormatException('読書状態の記録が不正です');
      }

      states[entry.key as String] = ChapterReadState.values.firstWhere(
        (state) => state.name == entry.value,
        orElse: () => throw const FormatException('未対応の読書状態です'),
      );
    }

    _states = states;
    notifyListeners();
  }

  bool hasRecord(ComicChapter chapter) =>
      _states.containsKey(chapterReadStateKey(chapter));

  ChapterReadState stateOf(ComicChapter chapter) =>
      _states[chapterReadStateKey(chapter)] ?? ChapterReadState.unread;

  Future<void> _serialize(Future<void> Function() action) {
    final operation = _pending.then((_) async {
      await load();
      await action();
    });

    _pending = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );

    return operation;
  }

  Future<void> _write(String key, ChapterReadState state) async {
    if (_states[key] == state) return;

    final next = {..._states, key: state};
    final file = _file;
    await file.parent.create(recursive: true);

    final temporary = File('${file.path}.part');

    await temporary.writeAsString(
      jsonEncode({
        'version': 1,
        'states': next.map((key, value) => MapEntry(key, value.name)),
      }),
      flush: true,
    );

    await temporary.rename(file.path);

    _states = next;
    notifyListeners();
  }

  Future<void> setChapterState(ComicChapter chapter, ChapterReadState state) =>
      _serialize(() => _write(chapterReadStateKey(chapter), state));

  /// 開いた話を読書中にする。ただし読了は維持する。
  Future<void> markOpened(ComicChapter chapter) => _serialize(() async {
    if (stateOf(chapter) == ChapterReadState.completed) return;

    await _write(chapterReadStateKey(chapter), ChapterReadState.reading);
  });

  /// 既存の閲覧位置がある話を移行する。
  /// 手動で未読へ戻した記録などは上書きしない。
  Future<void> importStarted(ComicChapter chapter) => _serialize(() async {
    if (hasRecord(chapter)) return;

    await _write(chapterReadStateKey(chapter), ChapterReadState.reading);
  });
}
