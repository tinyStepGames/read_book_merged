part of 'download_store.dart';

/// 再開用記録が残っている、未完了のダウンロード。
class IncompleteDownload {
  const IncompleteDownload({
    required this.chapter,
    required this.bytes,
    required this.savedPages,
    required this.totalPages,
  });

  final ComicChapter chapter;
  final int bytes;
  final int savedPages;
  final int totalPages;
}

extension DownloadRecovery on DownloadStore {
  File _pendingFile(ComicChapter chapter) =>
      File(p.join(directory(chapter).path, 'download-pending.json'));

  String _pageName(int index) => '${index.toString().padLeft(4, '0')}.jpg';

  Future<void> _normalFolder(ComicChapter chapter) async {
    final folder = directory(chapter);
    final type = await FileSystemEntity.type(folder.path, followLinks: false);

    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.directory) {
      throw const FormatException('通常の保存フォルダではありません');
    }
  }

  Future<void> _normalFile(File file) async {
    final type = await FileSystemEntity.type(file.path, followLinks: false);

    if (type != FileSystemEntityType.notFound &&
        type != FileSystemEntityType.file) {
      throw const FormatException('通常の保存ファイルではありません');
    }
  }

  Future<void> _checkImage(File file) async {
    final codec = await ui.instantiateImageCodec(
      await file.readAsBytes(),
      targetWidth: 64,
    );

    try {
      final frame = await codec.getNextFrame();
      frame.image.dispose();
    } finally {
      codec.dispose();
    }
  }

  Future<String> _fileHash(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  Future<bool> _reusable(File target, Uri url) async {
    final metadata = File('${target.path}.resume.json');

    // リンク等は「破損扱いで上書き」せず、安全のため停止する。
    await _normalFile(target);
    await _normalFile(metadata);

    if (!await target.exists() || !await metadata.exists()) {
      return false;
    }

    try {
      final data = Map<String, dynamic>.from(
        jsonDecode(await metadata.readAsString()) as Map,
      );

      if (data['url'] != url.toString() ||
          data['bytes'] != await target.length() ||
          data['sha256'] != await _fileHash(target)) {
        return false;
      }

      await _checkImage(target);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> _readPending(ComicChapter chapter) async {
    await _normalFolder(chapter);

    final pending = _pendingFile(chapter);
    await _normalFile(pending);

    final data = Map<String, dynamic>.from(
      jsonDecode(await pending.readAsString()) as Map,
    );

    final recorded = ComicChapter.fromJson(
      Map<String, dynamic>.from(data['chapter'] as Map),
    );

    if (data['version'] != 1 ||
        recorded.storageId != chapter.storageId ||
        recorded.sourceId != chapter.sourceId ||
        recorded.language != chapter.language ||
        recorded.workId != chapter.workId ||
        recorded.id != chapter.id) {
      throw const FormatException('再開情報とチャプターが一致しません');
    }

    final images = List<String>.from(data['images'] as List);

    if (images.isEmpty) {
      throw const FormatException('再開対象のページがありません');
    }

    return data;
  }

  Future<void> _downloadResumable(
    ComicChapter chapter,
    ChapterContent content,
    void Function(int done, int total) progress,
  ) async {
    if (!_activeDownloads.add(chapter.storageId)) {
      throw StateError('この話はすでにダウンロード中です');
    }

    try {
      final images = List<Uri>.unmodifiable(content.images);

      if (images.isEmpty) {
        throw const FormatException('保存対象の画像がありません');
      }

      for (final url in images) {
        if (!['http', 'https'].contains(url.scheme) ||
            url.host.isEmpty ||
            url.userInfo.isNotEmpty) {
          throw const FormatException('未対応の画像取得方式です');
        }
      }

      await _normalFolder(chapter);
      final folder = directory(chapter);
      await folder.create(recursive: true);

      // 完了済みの話を誤って未完了に戻さない。
      await _normalFile(_manifest(chapter));
      try {
        final saved = await load(chapter);
        if (saved.isNotEmpty) {
          progress(saved.length, saved.length);
          return;
        }
      } catch (_) {
        // 不足・破損した保存情報は、下で再構築する。
      }

      final pending = _pendingFile(chapter);
      await _normalFile(pending);
      await _normalFile(File('${pending.path}.part'));

      // 通信開始前に、アプリ再起動後も使える再開情報を保存する。
      await _writeJson(pending, {
        'version': 1,
        'chapter': chapter.toJson(),
        'images': images.map((url) => url.toString()).toList(),
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      });

      final manifest = _manifest(chapter);
      if (await manifest.exists()) await manifest.delete();

      await _normalFile(File(p.join(folder.path, 'credits.txt')));
      await rememberCredits(chapter, content.credits);

      final names = List<String>.generate(
        images.length,
        _pageName,
        growable: false,
      );

      final missing = <int>[];
      var completed = 0;

      // URL・サイズ・ハッシュ・画像デコードで再利用の可否を確認。
      for (var index = 0; index < images.length; index++) {
        final target = File(p.join(folder.path, names[index]));

        if (await _reusable(target, images[index])) {
          completed++;
        } else {
          missing.add(index);
        }
      }

      progress(completed, images.length);

      var cursor = 0;
      var stopped = false;

      Future<void> saveImage(int index) async {
        final target = File(p.join(folder.path, names[index]));
        final temporary = File('${target.path}.part');
        final metadata = File('${target.path}.resume.json');

        for (final file in [
          target,
          temporary,
          metadata,
          File('${metadata.path}.part'),
        ]) {
          await _normalFile(file);
        }

        try {
          await _dio.download(
            images[index].toString(),
            temporary.path,
            deleteOnError: true,
          );

          await _checkImage(temporary);

          final length = await temporary.length();
          final hash = await _fileHash(temporary);

          if (await target.exists()) await target.delete();
          await temporary.rename(target.path);

          // 画像が確定してから再利用用の検証情報を記録する。
          await _writeJson(metadata, {
            'url': images[index].toString(),
            'bytes': length,
            'sha256': hash,
          });
        } finally {
          try {
            if (await temporary.exists()) await temporary.delete();
          } catch (_) {
            // 次回再試行時に同じ一時パスを使う。
          }
        }
      }

      Future<void> worker() async {
        while (!stopped) {
          final position = cursor;
          if (position >= missing.length) return;
          cursor++;

          try {
            await saveImage(missing[position]);
            completed++;
            progress(completed, images.length);
          } catch (_) {
            stopped = true;
            rethrow;
          }
        }
      }

      final workers = missing.length < maxConcurrentImages
          ? missing.length
          : maxConcurrentImages;

      await Future.wait<void>(
        List.generate(workers, (_) => worker()),
        eagerError: false,
      );

      await _normalFile(File('${manifest.path}.part'));

      // 全ページが揃った場合だけ、従来互換の完了情報を書く。
      await _writeJson(manifest, {
        'version': 2,
        'episodeId': chapter.storageId,
        'title': chapter.title,
        'sourceUrl': chapter.url.toString(),
        'chapter': chapter.toJson(),
        'complete': true,
        'pages': names,
      });

      // 完了情報の確定後なので、片付け失敗で保存失敗にはしない。
      try {
        await pending.delete();

        for (final name in names) {
          final metadata = File(p.join(folder.path, '$name.resume.json'));
          if (await metadata.exists()) await metadata.delete();
        }
      } catch (_) {
        // 次回も完了情報を優先する。
      }
    } finally {
      _activeDownloads.remove(chapter.storageId);
    }
  }

  Future<List<IncompleteDownload>> incompleteDownloads(String sourceId) async {
    await root.create(recursive: true);
    final result = <IncompleteDownload>[];

    await for (final entry in root.list(followLinks: false)) {
      if (entry is! Directory) continue;

      final pending = File(p.join(entry.path, 'download-pending.json'));

      if (await FileSystemEntity.type(pending.path, followLinks: false) !=
          FileSystemEntityType.file) {
        continue;
      }

      try {
        final data = Map<String, dynamic>.from(
          jsonDecode(await pending.readAsString()) as Map,
        );

        final chapter = ComicChapter.fromJson(
          Map<String, dynamic>.from(data['chapter'] as Map),
        );

        if (chapter.sourceId != sourceId ||
            chapter.storageId != p.basename(entry.path) ||
            _activeDownloads.contains(chapter.storageId)) {
          continue;
        }

        final verified = await _readPending(chapter);

        // 完了後に再開記録の片付けだけ失敗した話は除外。
        try {
          if ((await load(chapter)).isNotEmpty) continue;
        } catch (_) {
          // 保存未完了として扱う。
        }

        final images = List<String>.from(verified['images'] as List);
        var savedPages = 0;
        var bytes = 0;

        for (var index = 0; index < images.length; index++) {
          final image = File(p.join(entry.path, _pageName(index)));

          if (await FileSystemEntity.type(image.path, followLinks: false) ==
              FileSystemEntityType.file) {
            if (await image.length() > 0) savedPages++;
          }
        }

        await for (final file in entry.list(
          recursive: true,
          followLinks: false,
        )) {
          if (file is File) bytes += await file.length();
        }

        result.add(
          IncompleteDownload(
            chapter: chapter,
            bytes: bytes,
            savedPages: savedPages,
            totalPages: images.length,
          ),
        );
      } catch (_) {
        // 所属を安全に確認できないデータは削除対象にしない。
      }
    }

    result.sort((a, b) {
      final work = a.chapter.workId.compareTo(b.chapter.workId);
      return work != 0 ? work : a.chapter.id.compareTo(b.chapter.id);
    });

    return List.unmodifiable(result);
  }

  Future<void> deleteIncomplete(
    IncompleteDownload item,
    String sourceId,
  ) async {
    final chapter = item.chapter;

    if (chapter.sourceId != sourceId ||
        _activeDownloads.contains(chapter.storageId)) {
      throw StateError('別サイトまたは取得中のデータは削除できません');
    }

    await _readPending(chapter);

    var complete = false;
    try {
      complete = (await load(chapter)).isNotEmpty;
    } catch (_) {
      // 保存情報が不足しているデータは未完了扱い。
    }

    if (complete) {
      throw StateError('保存が完了しています。保存済み一覧から操作してください');
    }

    final folder = directory(chapter);

    // この機能の保存フォルダはフラットな通常ファイルのみ。
    await for (final entry in folder.list(followLinks: false)) {
      if (entry is! File) {
        throw const FormatException('想定外のフォルダまたはリンクがあるため削除を中止しました');
      }
    }

    await folder.delete(recursive: true);
  }
}
