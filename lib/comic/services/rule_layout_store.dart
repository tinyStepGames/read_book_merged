import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// サイトルール本体とは別に、この端末の表示形式だけを保存する。
class RuleLayoutStore {
  RuleLayoutStore({Directory? directory}) : _directory = directory;

  final Directory? _directory;
  static final Map<String, Future<void>> _queues = {};

  Future<File> _file(String siteId) async {
    final root = _directory ?? await getApplicationSupportDirectory();
    final key = sha256.convert(utf8.encode(siteId)).toString();
    return File(p.join(root.path, '_ui_preferences', 'rule-layout-$key.json'));
  }

  Future<T> _locked<T>(File file, Future<T> Function() action) {
    final key = p.normalize(file.absolute.path);
    final previous = _queues[key] ?? Future<void>.value();
    final task = previous.then((_) => action());

    // 保存に失敗しても、次の保存・読み込みを妨げない。
    _queues[key] = task.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );

    return task;
  }

  /// 未設定・読み込み失敗・未対応形式ならTableを使う。
  Future<bool> read(String siteId) async {
    try {
      final file = await _file(siteId);
      return await _locked(file, () async {
        if (!await file.exists()) return false;
        if (await file.length() > 4096) return false;

        final data = jsonDecode(await file.readAsString());
        return data is Map &&
            data['version'] == 1 &&
            data['layout'] == 'collection';
      });
    } catch (_) {
      return false;
    }
  }

  /// サイトごとに直列保存し、連続タップでも最後の選択を残す。
  Future<void> write(String siteId, bool collection) async {
    final file = await _file(siteId);
    await _locked(file, () async {
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.part');
      await temporary.writeAsString(
        jsonEncode({
          'version': 1,
          'layout': collection ? 'collection' : 'table',
        }),
        flush: true,
      );
      await temporary.rename(file.path);
    });
  }
}
