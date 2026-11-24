import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html;

import 'html_probe.dart';

enum VideoUrlSource { jsonLd, attribute }

class VideoSourceSettings {
  const VideoSourceSettings({
    required this.pageUrl,
    this.source = VideoUrlSource.jsonLd,
    this.selector = 'video, source',
    this.attribute = 'src',
    this.allowedOrigins = const [],
  });

  final String pageUrl;
  final VideoUrlSource source;
  final String selector;
  final String attribute;

  /// 最初に抽出した動画URLの許可元。
  /// HLSの内部通信を制限するネットワーク境界ではない。
  final List<String> allowedOrigins;

  void validate() {
    htmlProbeUri(pageUrl);

    if (selector.length > 8192 ||
        (source == VideoUrlSource.attribute &&
            (selector.trim().isEmpty ||
                !RegExp(r'^[A-Za-z_][A-Za-z0-9_:.-]*$').hasMatch(attribute)))) {
      throw const FormatException('動画要素のセレクター・属性が不正です');
    }

    if (allowedOrigins.isEmpty || allowedOrigins.length > 32) {
      throw const FormatException('動画URLの許可元を1～32件指定してください');
    }

    final seen = <String>{};

    for (final value in allowedOrigins) {
      final raw = Uri.parse(value);
      final uri = htmlProbeUri(value);

      if (raw.hasQuery ||
          raw.hasFragment ||
          (raw.path.isNotEmpty && raw.path != '/') ||
          !seen.add(uri.origin)) {
        throw const FormatException('許可元は重複しない https://ホスト名 の形式で指定してください');
      }
    }

    if (utf8.encode(jsonEncode(toJson())).length > 24 * 1024) {
      throw const FormatException('動画設定が大きすぎます');
    }
  }

  void validateFor(Iterable<String> sampleUrls) {
    validate();

    final origin = htmlProbeUri(pageUrl).origin;
    var count = 0;

    for (final url in sampleUrls) {
      count++;
      if (htmlProbeUri(url).origin != origin) {
        throw const FormatException('動画掲載ページとサイトの一覧ルールの取得元が異なります');
      }
    }

    if (count == 0) {
      throw const FormatException('サイトの一覧ルールがありません');
    }
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'pageUrl': pageUrl,
    'source': source.name,
    'selector': selector,
    'attribute': attribute,
    'allowedOrigins': allowedOrigins,
  };

  factory VideoSourceSettings.fromJson(Map<String, dynamic> data) {
    if (data['version'] != 1 ||
        data['pageUrl'] is! String ||
        data['source'] is! String ||
        data['selector'] is! String ||
        data['attribute'] is! String ||
        data['allowedOrigins'] is! List ||
        data.keys.any(
          (key) => !const {
            'version',
            'pageUrl',
            'source',
            'selector',
            'attribute',
            'allowedOrigins',
          }.contains(key),
        )) {
      throw const FormatException('未対応の動画設定です');
    }

    final sources = VideoUrlSource.values.where(
      (value) => value.name == data['source'],
    );
    final origins = data['allowedOrigins'] as List;

    if (sources.length != 1 || origins.any((value) => value is! String)) {
      throw const FormatException('動画設定の値が不正です');
    }

    final result = VideoSourceSettings(
      pageUrl: data['pageUrl'] as String,
      source: sources.single,
      selector: data['selector'] as String,
      attribute: data['attribute'] as String,
      allowedOrigins: List<String>.unmodifiable(origins.cast<String>()),
    );

    result.validate();
    return result;
  }
}

class VideoExtractionResult {
  VideoExtractionResult({
    required Iterable<Uri> urls,
    required Iterable<String> issues,
  }) : urls = List<Uri>.unmodifiable(urls),
       issues = List<String>.unmodifiable(issues);

  final List<Uri> urls;
  final List<String> issues;

  bool get hasSingleUrl => urls.length == 1;
}

VideoExtractionResult extractVideoUrls({
  required HtmlProbePage page,
  required VideoSourceSettings settings,
}) {
  settings.validate();

  if (page.uri.origin != htmlProbeUri(settings.pageUrl).origin) {
    throw const FormatException('取得したページの取得元が動画設定と異なります');
  }

  final document = html.parse(page.source);
  final allowed = settings.allowedOrigins
      .map((value) => htmlProbeUri(value).origin)
      .toSet();
  final urls = <String, Uri>{};
  final issues = <String>[];

  void add(Object? value) {
    if (value is! String || value.trim().isEmpty) return;

    try {
      final uri = htmlProbeUri(page.uri.resolve(value.trim()).toString());

      if (!allowed.contains(uri.origin)) {
        issues.add('許可元に含まれない動画URLを除外しました：${uri.origin}');
        return;
      }

      urls.putIfAbsent(uri.toString(), () => uri);
    } on FormatException {
      issues.add('HTTPS以外・認証情報付き・blob等の動画URLを除外しました');
    }
  }

  if (settings.source == VideoUrlSource.attribute) {
    for (final element in document.querySelectorAll(settings.selector)) {
      add(element.attributes[settings.attribute]);
    }
  } else {
    var visited = 0;

    void visit(Object? value, int depth) {
      visited++;
      if (depth > 40 || visited > 20000) {
        throw const FormatException('構造化データの入れ子・要素数が多すぎます');
      }

      if (value is List) {
        for (final child in value) {
          visit(child, depth + 1);
        }
        return;
      }

      if (value is! Map) return;

      final type = value['@type'];
      final types = type is List ? type : [type];
      final isVideo = types.any(
        (item) =>
            item == 'VideoObject' ||
            item == 'https://schema.org/VideoObject' ||
            item == 'http://schema.org/VideoObject',
      );

      if (isVideo) {
        final content = value['contentUrl'];
        if (content is List) {
          for (final entry in content) {
            add(entry);
          }
        } else {
          add(content);
        }
      }

      for (final child in value.values) {
        if (child is Map || child is List) {
          visit(child, depth + 1);
        }
      }
    }

    for (final script in document.querySelectorAll(
      'script[type="application/ld+json"]',
    )) {
      try {
        visit(jsonDecode(script.text), 0);
      } on FormatException {
        issues.add('読み取れない、または複雑すぎる構造化データがあります');
      }
    }
  }

  if (urls.isEmpty) {
    issues.add(
      '利用可能な動画URLがありません。'
      '取得方法・許可元・通常HTMLに含まれる情報を確認してください。',
    );
  } else if (urls.length > 1) {
    issues.add(
      '動画URLが複数あります。先頭を自動採用しません。'
      '要素の指定を絞るなどして1件にしてください。',
    );
  }

  return VideoExtractionResult(urls: urls.values, issues: issues);
}

typedef VideoHtmlFetcher =
    Future<HtmlProbePage> Function(
      String input, {
      required CancelToken cancelToken,
      required String allowedOrigin,
    });

class VideoSourceClient {
  VideoSourceClient({VideoHtmlFetcher? fetcher}) : _fetcher = fetcher;

  final VideoHtmlFetcher? _fetcher;
  final HtmlProbeClient _client = HtmlProbeClient();

  Future<VideoExtractionResult> load({
    required VideoSourceSettings settings,
    required String targetUrl,
    required CancelToken cancelToken,
  }) async {
    settings.validate();

    if (cancelToken.isCancelled) {
      throw StateError('動画URLの取得を中止しました');
    }

    final target = htmlProbeUri(targetUrl);
    final origin = htmlProbeUri(settings.pageUrl).origin;

    if (target.origin != origin) {
      throw const FormatException('動画掲載ページの取得元が異なります');
    }

    final fetcher = _fetcher;
    final page = fetcher == null
        ? await _client.fetch(
            target.toString(),
            cancelToken: cancelToken,
            allowedOrigin: origin,
          )
        : await fetcher(
            target.toString(),
            cancelToken: cancelToken,
            allowedOrigin: origin,
          );

    if (cancelToken.isCancelled) {
      throw StateError('動画URLの取得を中止しました');
    }

    return extractVideoUrls(page: page, settings: settings);
  }

  void close() => _client.close();
}
