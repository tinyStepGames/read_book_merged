import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html;
import 'package:path/path.dart' as p;

// offline-comic-reader の EpisodeStore を抽出したもの。

const episodeId = 'peppercarrot-en-ep01';
const episodeTitle = 'Pepper&Carrot 第1話（英語版）';

final episodeUrl = Uri.parse(
  'https://www.peppercarrot.com/en/webcomic/'
  'ep01_Potion-of-Flight.html',
);

const attribution = '''
Pepper&Carrot by David Revoy
https://www.peppercarrot.com
CC BY 4.0
https://creativecommons.org/licenses/by/4.0/

Based on the universe of Hereva created by David Revoy
with contributions by Craig Maloney.
Corrections by Willem Sonke, Moini, Hali, CGand and Alex Gryson.

画像は取得したデータを変更せず保存します。
本アプリは非公式の閲覧サンプルです。
''';


class EpisodeStore {
  EpisodeStore(this.directory, {String? id, Uri? url, String? title})
    : episodeId = id ?? 'peppercarrot-en-ep01',
      episodeUrl =
          url ??
          Uri.parse(
            'https://www.peppercarrot.com/en/webcomic/'
            'ep01_Potion-of-Flight.html',
          ),
      episodeTitle = title ?? 'Pepper&Carrot 第1話（英語版）';

  final String episodeId;
  final Uri episodeUrl;
  final String episodeTitle;

  final Directory directory;

  final Dio dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 60),
    ),
  );

  File get manifest => File(p.join(directory.path, 'manifest.json'));

  // ネットワークを使わず、保存済みの話を復元する。
  Future<List<File>> load() async {
    if (!await manifest.exists()) return [];

    final data =
        jsonDecode(await manifest.readAsString()) as Map<String, dynamic>;

    if (data['episodeId'] != episodeId || data['complete'] != true) {
      throw const FormatException('保存情報が不正です');
    }

    final names = List<String>.from(data['pages'] as List);
    if (names.isEmpty) {
      throw const FormatException('ページがありません');
    }

    final files = <File>[];

    for (final name in names) {
      // JSON内のパスをそのまま信用しない。
      if (!RegExp(r'^\d{4}\.jpg$').hasMatch(name)) {
        throw const FormatException('ファイル名が不正です');
      }

      final file = File(p.join(directory.path, name));
      if (!await file.exists() || await file.length() == 0) {
        throw const FormatException('保存画像が不足しています');
      }
      files.add(file);
    }

    return files;
  }

  Future<List<File>> download(
    void Function(int done, int total) onProgress,
  ) async {
    // 完了済みなら再取得しない。
    try {
      final saved = await load();
      if (saved.isNotEmpty) return saved;
    } catch (_) {
      // 破損・不足時は全体を再ダウンロードする。
    }

    if (await manifest.exists()) {
      await manifest.delete();
    }

    final response = await dio.get<String>(
      episodeUrl.toString(),
      options: Options(responseType: ResponseType.plain),
    );

    final document = html.parse(response.data ?? '');
    final urls = <Uri>[];
    final seen = <String>{};

    for (final image in document.querySelectorAll(
      '.webcomic-page img, #panel-all img.mft-cv-image',
    )) {
      final src = image.attributes['src'];
      if (src == null || src.isEmpty) continue;

      final url = episodeUrl.resolve(src);

      // 初期版は確認した公式ホスト・JPEGだけに限定。
      if (url.scheme != 'https' ||
          url.host != episodeUrl.host ||
          !RegExp(
            r'\.(?:jpe?g|png|webp|gif)$',
            caseSensitive: false,
          ).hasMatch(url.path)) {
        throw const FormatException('未対応の画像URLです');
      }

      if (seen.add(url.toString())) {
        urls.add(url);
      }
    }

    if (urls.isEmpty) {
      throw StateError('漫画画像が見つかりません。取得ルールを確認してください。');
    }

    final names = <String>[];
    onProgress(0, urls.length);

    // サーバーへの負荷を抑えるため、まずは直列で取得。
    for (var i = 0; i < urls.length; i++) {
      final name = '${i.toString().padLeft(4, '0')}.jpg';
      final target = File(p.join(directory.path, name));
      final temporary = File('${target.path}.part');

      await dio.download(
        urls[i].toString(),
        temporary.path,
        deleteOnError: true,
      );

      // HTMLのエラーページなどを画像として保存しないよう、
      // 実際にデコードできることを確認。
      final codec = await ui.instantiateImageCodec(
        await temporary.readAsBytes(),
        targetWidth: 64,
      );
      try {
        final frame = await codec.getNextFrame();
        frame.image.dispose();
      } finally {
        codec.dispose();
      }

      if (await target.exists()) {
        await target.delete();
      }
      await temporary.rename(target.path);

      names.add(name);
      onProgress(i + 1, urls.length);
    }

    final data = {
      'version': 1,
      'episodeId': episodeId,
      'title': episodeTitle,
      'sourceUrl': episodeUrl.toString(),
      'attribution': attribution,
      'complete': true,
      'pages': names,
    };

    final temporaryManifest = File('${manifest.path}.part');

    await temporaryManifest.writeAsString(jsonEncode(data), flush: true);
    await temporaryManifest.rename(manifest.path);

    return load();
  }
}

