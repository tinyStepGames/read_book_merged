import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../sources/source_adapter.dart';
import 'download_store.dart';

String savedWorkKey(ComicChapter chapter) =>
    jsonEncode([chapter.sourceId, chapter.language, chapter.workId]);

String savedSizeLabel(int bytes) {
  if (bytes < 1024) return '$bytes B';

  const units = ['KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes / 1024;
  var unit = 0;

  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }

  return '${value.toStringAsFixed(1)} ${units[unit]}';
}

class SavedChapter {
  const SavedChapter({
    required this.chapter,
    required this.files,
    required this.bytes,
  });

  final ComicChapter chapter;
  final List<File> files;
  final int bytes;
}

class SavedDownloadScan {
  const SavedDownloadScan(this.chapters, this.issues);

  final List<SavedChapter> chapters;
  final List<String> issues;

  int get bytes => chapters.fold(0, (sum, item) => sum + item.bytes);
}

class SavedDownloadRepository {
  SavedDownloadRepository(this.store, this.adapter);

  final DownloadStore store;
  final SourceAdapter adapter;

  Future<void> _checkDirectory(ComicChapter chapter) async {
    final folder = store.directory(chapter);

    if (!p.equals(
      p.normalize(folder.absolute.parent.path),
      p.normalize(store.root.absolute.path),
    )) {
      throw const FormatException('保存先が管理対象外です');
    }

    if (await FileSystemEntity.type(folder.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FormatException('通常の保存フォルダではありません');
    }

    if (await FileSystemEntity.type(
          p.join(folder.path, 'manifest.json'),
          followLinks: false,
        ) !=
        FileSystemEntityType.file) {
      throw const FormatException('通常の保存情報ファイルではありません');
    }
  }

  Future<SavedChapter> _inspect(ComicChapter chapter) async {
    await _checkDirectory(chapter);

    final files = await store.load(chapter);

    if (files.isEmpty) {
      throw const FormatException('保存が完了していません');
    }

    for (final file in files) {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const FormatException('通常の画像ファイルではありません');
      }
    }

    var bytes = 0;

    await for (final entry
        in store.directory(chapter).list(recursive: true, followLinks: false)) {
      if (entry is File) bytes += await entry.length();
    }

    return SavedChapter(
      chapter: chapter,
      files: List.unmodifiable(files),
      bytes: bytes,
    );
  }

  Future<SavedDownloadScan> scan() async {
    await store.root.create(recursive: true);

    final chapters = <SavedChapter>[];
    final issues = <String>[];

    await for (final entry in store.root.list(followLinks: false)) {
      if (entry is! Directory) continue;

      final manifest = File(p.join(entry.path, 'manifest.json'));

      if (await FileSystemEntity.type(manifest.path, followLinks: false) !=
          FileSystemEntityType.file) {
        continue;
      }

      try {
        final data = Map<String, dynamic>.from(
          jsonDecode(await manifest.readAsString()) as Map,
        );

        final nested = data['chapter'];

        final chapter = nested is Map
            ? ComicChapter.fromJson(Map<String, dynamic>.from(nested))
            : adapter.restoreChapter(data);

        // この画面は現在のサイトの保存データを表示する。
        if (chapter == null || chapter.sourceId != adapter.id) continue;

        if (p.basename(entry.path) != chapter.storageId) {
          throw const FormatException('フォルダと保存IDが一致しません');
        }

        chapters.add(await _inspect(chapter));
      } catch (error) {
        issues.add('${p.basename(entry.path)}：$error');
      }
    }

    chapters.sort((a, b) {
      final work = savedWorkKey(a.chapter).compareTo(savedWorkKey(b.chapter));
      return work != 0 ? work : a.chapter.id.compareTo(b.chapter.id);
    });

    return SavedDownloadScan(
      List.unmodifiable(chapters),
      List.unmodifiable(issues),
    );
  }

  Future<void> deleteChapter(SavedChapter item) async {
    if (item.chapter.sourceId != adapter.id) {
      throw const FormatException('別サイトの保存データは削除しません');
    }

    // 削除直前にも管理対象の通常フォルダか確認する。
    await _checkDirectory(item.chapter);
    await store.delete(item.chapter);
  }
}
