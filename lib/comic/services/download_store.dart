import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../sources/source_adapter.dart';

part 'resumable_downloads.dart';

class DownloadStore {
  DownloadStore(this.root, {this.maxConcurrentImages = 3}) {
    if (maxConcurrentImages < 1 || maxConcurrentImages > 4) {
      throw ArgumentError.value(
        maxConcurrentImages,
        'maxConcurrentImages',
        '同時取得数は1～4で指定してください',
      );
    }
  }

  /// 1話の中で同時取得する画像数。
  final int maxConcurrentImages;

  final Directory root;

  final Set<String> _activeDownloads = {};

  bool get hasActiveDownloads => _activeDownloads.isNotEmpty;

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 60),
    ),
  );

  Directory directory(ComicChapter chapter) {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(chapter.storageId)) {
      throw const FormatException('保存IDが不正です');
    }
    return Directory(p.join(root.path, chapter.storageId));
  }

  File _manifest(ComicChapter chapter) =>
      File(p.join(directory(chapter).path, 'manifest.json'));

  Future<void> _writeJson(File file, Object data) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.part');
    await temporary.writeAsString(jsonEncode(data), flush: true);
    await temporary.rename(file.path);
  }

  File _cacheFile(String key) {
    final hash = sha256.convert(utf8.encode(key)).toString();
    return File(p.join(root.path, '_cache', '$hash.json'));
  }

  Future<dynamic> readCache(String key) async {
    try {
      return jsonDecode(await _cacheFile(key).readAsString());
    } catch (_) {
      return null;
    }
  }

  Future<void> writeCache(String key, Object data) =>
      _writeJson(_cacheFile(key), data);

  Future<List<File>> load(ComicChapter chapter) async {
    final manifest = _manifest(chapter);
    if (!await manifest.exists()) return [];

    final data =
        jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;

    if (data['complete'] != true || data['episodeId'] != chapter.storageId) {
      throw const FormatException('保存情報が不正です');
    }

    final names = List<String>.from(data['pages'] as List);
    if (names.isEmpty) {
      throw const FormatException('保存ページがありません');
    }

    final files = <File>[];
    for (final name in names) {
      if (!RegExp(r'^\d{4,}\.jpg$').hasMatch(name)) {
        throw const FormatException('保存ファイル名が不正です');
      }

      final file = File(p.join(directory(chapter).path, name));
      if (!await file.exists() || await file.length() == 0) {
        throw const FormatException('保存画像が不足しています');
      }
      files.add(file);
    }
    return files;
  }

  Future<List<ComicChapter>> localChapters(SourceAdapter adapter) async {
    final result = <ComicChapter>[];
    await root.create(recursive: true);

    await for (final entry in root.list(followLinks: false)) {
      if (entry is! Directory || p.basename(entry.path) == '_cache') {
        continue;
      }

      try {
        final data =
            jsonDecode(
                  await File(
                    p.join(entry.path, 'manifest.json'),
                  ).readAsString(),
                )
                as Map<String, dynamic>;

        final chapter = adapter.restoreChapter(data);
        if (chapter != null && p.basename(entry.path) == chapter.storageId) {
          result.add(chapter);
        }
      } catch (_) {
        // 他サイト・未完了・破損した記録は復元しない。
      }
    }
    return result;
  }

  Future<void> rememberCredits(ComicChapter chapter, String credits) async {
    final target = File(p.join(directory(chapter).path, 'credits.txt'));
    await target.parent.create(recursive: true);
    await target.writeAsString(credits, flush: true);
  }

  Future<String?> readCredits(ComicChapter chapter) async {
    try {
      return await File(
        p.join(directory(chapter).path, 'credits.txt'),
      ).readAsString();
    } catch (_) {
      return null;
    }
  }

  Future<void> download(
    ComicChapter chapter,
    ChapterContent content,
    void Function(int done, int total) progress,
  ) => _downloadResumable(chapter, content, progress);
  Future<void> delete(ComicChapter chapter) async {
    final target = directory(chapter);
    if (await target.exists()) {
      await target.delete(recursive: true);
    }
  }

  void close() => _dio.close(force: true);
}
