import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 閲覧位置やサイト共有設定とは独立した、端末内の記録。
class OpenedChapterStore {
  OpenedChapterStore({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? _defaultDirectory;

  static final shared = OpenedChapterStore();

  static const _maxEntries = 5000;
  static const _maxBytes = 8 * 1024 * 1024;

  final Future<Directory> Function() _directoryProvider;
  Future<void> _pending = Future<void>.value();

  static Future<Directory> _defaultDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, '_opened_chapters'));
  }

  Future<T> _locked<T>(Future<T> Function() action) {
    final task = _pending.then<T>((_) => action());

    _pending = task.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );

    return task;
  }

  String _canonical(String input) {
    if (input.length > 4096) {
      throw const FormatException('チャプターURLが長すぎます');
    }

    final uri = Uri.tryParse(input);

    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('チャプターURLが不正です');
    }

    return uri.removeFragment().toString();
  }

  Future<File> _file(String siteId) async {
    if (siteId.isEmpty || siteId.length > 200) {
      throw const FormatException('サイトIDが不正です');
    }

    final directory = await _directoryProvider();
    await directory.create(recursive: true);

    final id = sha256.convert(utf8.encode(siteId)).toString();
    return File(p.join(directory.path, '$id.json'));
  }

  Future<List<String>> _read(File file, String siteId) async {
    if (!await file.exists()) return <String>[];

    if (await file.length() > _maxBytes) {
      throw const FormatException('開いたチャプター記録が大きすぎます');
    }

    final Object? decoded = jsonDecode(await file.readAsString());

    if (decoded is! Map ||
        decoded['version'] != 1 ||
        decoded['siteId'] != siteId ||
        decoded['urls'] is! List) {
      throw const FormatException('開いたチャプター記録が不正です');
    }

    final raw = decoded['urls'] as List;

    if (raw.length > _maxEntries) {
      throw const FormatException('開いた記録の件数が不正です');
    }

    final urls = <String>[];

    for (final value in raw) {
      if (value is! String || _canonical(value) != value) {
        throw const FormatException('記録内のURLが不正です');
      }
      urls.add(value);
    }

    if (urls.toSet().length != urls.length) {
      throw const FormatException('開いた記録が重複しています');
    }

    return urls;
  }

  Future<Set<String>> read({required String siteId}) {
    return _locked(() async {
      final file = await _file(siteId);
      final urls = await _read(file, siteId);
      return Set<String>.unmodifiable(urls);
    });
  }

  Future<void> mark({required String siteId, required String chapterUrl}) {
    return _locked(() async {
      final canonical = _canonical(chapterUrl);
      final file = await _file(siteId);
      final urls = await _read(file, siteId);

      if (urls.contains(canonical)) return;

      final updated = [canonical, ...urls].take(_maxEntries).toList();

      final text = jsonEncode({
        'version': 1,
        'siteId': siteId,
        'urls': updated,
      });

      if (utf8.encode(text).length > _maxBytes) {
        throw const FormatException('開いた記録の容量上限です');
      }

      final temporary = File('${file.path}.part');
      await temporary.writeAsString(text, flush: true);
      await temporary.rename(file.path);
    });
  }
}
