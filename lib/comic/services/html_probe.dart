import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html;

enum HtmlValueMode { text, innerHtml, attribute }

class HtmlProbePage {
  const HtmlProbePage({
    required this.uri,
    required this.source,
    required this.bytes,
  });

  final Uri uri;
  final String source;
  final int bytes;
}

class HtmlProbeResult {
  const HtmlProbeResult(this.matchedCount, this.values);

  final int matchedCount;
  final List<String> values;
}

Uri htmlProbeUri(String value) {
  final uri = Uri.parse(value.trim());

  if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    throw const FormatException('認証情報を含まない https:// のURLを入力してください');
  }

  return uri.removeFragment();
}

String decodeProbeHtml(List<int> bytes, String contentType) {
  final charset = RegExp(
    r'''charset\s*=\s*["']?([a-zA-Z0-9_-]+)''',
    caseSensitive: false,
  );

  bool supported(String value) =>
      const ['utf-8', 'utf8', 'us-ascii'].contains(value.toLowerCase());

  final headerEncoding = charset.firstMatch(contentType)?.group(1);
  if (headerEncoding != null && !supported(headerEncoding)) {
    throw FormatException('この文字コードは初版では未対応です: $headerEncoding');
  }

  final source = utf8.decode(bytes);

  // 通常のmeta charsetとhttp-equiv形式の宣言を検査する。
  final document = html.parse(source);
  for (final meta in document.querySelectorAll('meta')) {
    final direct = meta.attributes['charset'];
    final content = meta.attributes['content'] ?? '';
    final declared = direct ?? charset.firstMatch(content)?.group(1);

    if (declared != null && !supported(declared)) {
      throw FormatException('この文字コードは初版では未対応です: $declared');
    }
  }

  return source;
}

/// HTML取得時のHTTPエラー。従来と同じStateError系として扱う。
class HtmlProbeHttpException extends StateError {
  HtmlProbeHttpException(this.statusCode)
    : super('HTMLを取得できませんでした: HTTP $statusCode');

  final int statusCode;
}

class HtmlProbeClient {
  static const maxBytes = 2 * 1024 * 1024;

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );

  Future<HtmlProbePage> fetch(
    String input, {
    required CancelToken cancelToken,
    String? allowedOrigin,
  }) async {
    var uri = htmlProbeUri(input);

    // 自動転送を無効にし、転送先もHTTPSかを検証する。
    for (var redirects = 0; redirects <= 5; redirects++) {
      if (allowedOrigin != null && uri.origin != allowedOrigin) {
        throw const FormatException('設定した取得元とは異なる転送先です。URLとサイト設定を確認してください');
      }
      final response = await _dio.get<ResponseBody>(
        uri.toString(),
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          followRedirects: false,
          validateStatus: (_) => true,
        ),
      );

      final body = response.data;
      if (body == null) {
        throw StateError('応答本文がありません');
      }

      final status = response.statusCode ?? 0;

      if (const [301, 302, 303, 307, 308].contains(status)) {
        final location = response.headers.value('location');
        await body.stream.listen((_) {}).cancel();

        if (location == null || redirects == 5) {
          throw StateError('転送先が不明、または転送回数が多すぎます');
        }

        uri = htmlProbeUri(uri.resolve(location).toString());
        continue;
      }

      if (status < 200 || status >= 300) {
        await body.stream.listen((_) {}).cancel();
        throw HtmlProbeHttpException(status);
      }

      final contentType = response.headers.value('content-type') ?? '';

      if (contentType.isNotEmpty &&
          !contentType.toLowerCase().contains('text/html') &&
          !contentType.toLowerCase().contains('application/xhtml+xml') &&
          !contentType.toLowerCase().contains('text/plain')) {
        await body.stream.listen((_) {}).cancel();
        throw FormatException('HTMLではない応答です: $contentType');
      }

      final builder = BytesBuilder(copy: false);
      var received = 0;

      await for (final chunk in body.stream) {
        received += chunk.length;

        if (received > maxBytes) {
          cancelToken.cancel('サイズ上限');
          throw StateError('HTMLが上限の2MiBを超えています');
        }

        builder.add(chunk);
      }

      return HtmlProbePage(
        uri: uri,
        source: decodeProbeHtml(builder.takeBytes(), contentType),
        bytes: received,
      );
    }

    throw StateError('転送を完了できませんでした');
  }

  void close() => _dio.close(force: true);
}

HtmlProbeResult extractProbeValues({
  required HtmlProbePage page,
  required String selector,
  required HtmlValueMode mode,
  String attribute = '',
  bool resolveUrls = true,
}) {
  if (selector.trim().isEmpty) {
    throw const FormatException('CSSセレクターを入力してください');
  }

  if (mode == HtmlValueMode.attribute && attribute.trim().isEmpty) {
    throw const FormatException('属性名を入力してください');
  }

  final document = html.parse(page.source);
  var baseUri = page.uri;

  final base = document.querySelector('base[href]')?.attributes['href'];

  if (base != null) {
    final resolved = page.uri.resolve(base);

    if (const ['http', 'https'].contains(resolved.scheme)) {
      baseUri = resolved;
    }
  }

  final elements = document.querySelectorAll(selector);
  final values = <String>[];
  final name = attribute.trim();

  // プレビュー表示は先頭200件。総一致件数は別に保持する。
  for (final element in elements.take(200)) {
    var value = switch (mode) {
      HtmlValueMode.text => element.text.trim(),
      HtmlValueMode.innerHtml => element.innerHtml,
      HtmlValueMode.attribute => element.attributes[name] ?? '',
    };

    if (mode == HtmlValueMode.attribute &&
        resolveUrls &&
        const ['href', 'src', 'data-src', 'poster'].contains(name) &&
        value.trim().isNotEmpty) {
      value = baseUri.resolve(value.trim()).toString();
    }

    values.add(value);
  }

  return HtmlProbeResult(elements.length, List.unmodifiable(values));
}
