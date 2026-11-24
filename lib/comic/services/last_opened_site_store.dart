import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 端末内だけで使うホーム設定。
/// サイトルールのJSON/QRには含めない。
class LastOpenedSiteStore {
  LastOpenedSiteStore(Directory comicsRoot)
    : _file = File(
        p.join(
          comicsRoot.parent.path,
          '_ui_preferences',
          'last-opened-site.json',
        ),
      );

  static const builtinSiteId = '@builtin:peppercarrot';
  static const maxBytes = 4096;

  final File _file;
  static final Map<String, Future<void>> _queues = {};

  static bool isValidId(String value) =>
      value == builtinSiteId || RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(value);

  Future<String?> read() async {
    final key = p.normalize(_file.absolute.path);

    try {
      final pending = _queues[key];
      if (pending != null) await pending;

      if (!await _file.exists()) return null;
      if (await _file.length() > maxBytes) return null;

      final decoded = jsonDecode(await _file.readAsString());

      if (decoded is! Map ||
          decoded['version'] != 1 ||
          decoded['siteId'] is! String) {
        return null;
      }

      final id = decoded['siteId'] as String;
      return isValidId(id) ? id : null;
    } catch (_) {
      // UI設定の不具合でアプリを起動不能にしない。
      return null;
    }
  }

  Future<void> write(String siteId) {
    if (!isValidId(siteId)) {
      return Future<void>.error(const FormatException('起動サイトIDが不正です'));
    }

    final key = p.normalize(_file.absolute.path);
    final previous = _queues[key] ?? Future<void>.value();

    final task = previous.then((_) async {
      await _file.parent.create(recursive: true);

      final temporary = File('${_file.path}.part');

      await temporary.writeAsString(
        jsonEncode({'version': 1, 'siteId': siteId}),
        flush: true,
      );

      await temporary.rename(_file.path);
    });

    // 連続操作時も呼び出された順に保存する。
    _queues[key] = task.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );

    return task;
  }
}
