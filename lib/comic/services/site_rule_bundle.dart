import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'list_extraction_rule.dart';
import 'rule_browse_client.dart';
import 'site_rule_store.dart';

/// 保存画像・個人データを含めない、1サイト分の共有形式。
class SiteRuleBundle {
  SiteRuleBundle._(this.site);

  final SavedSiteRule site;

  static const format = 'offline-comic-reader.site-bundle';
  static const prefix = 'ocr-site:1:gzip:';

  static const maxJsonBytes = 256 * 1024;

  /// 誤り訂正Mの1枚のQRに収めるためのアプリ側上限。
  static const maxQrCharacters = 2200;

  factory SiteRuleBundle.fromSite(SavedSiteRule site) {
    final checked = SavedSiteRule.fromJson(site.toJson());
    return SiteRuleBundle._(checked);
  }

  Map<String, dynamic> toJson() => {
    'format': format,
    'version': site.readingSettings != null
        ? 5
        : site.browseTabs.isNotEmpty
        ? 4
        : (site.searchSettings != null
              ? 3
              : (site.tagNavigation == null ? 1 : 2)),
    'name': site.name,
    if (site.readingSettings != null)
      'readingSettings': site.readingSettings!.toJson(),
    if (site.browseTabs.isNotEmpty)
      'browseTabs': site.browseTabs.map((tab) => tab.toJson()).toList(),
    if (site.searchSettings != null)
      'searchSettings': site.searchSettings!.toJson(),
    'rules': site.rules.map((key, value) => MapEntry(key, value.toJson())),
    if (site.images != null) 'images': site.images!.toJson(),
    if (site.tagNavigation != null)
      'tagNavigation': site.tagNavigation!.toJson(),
  };

  String encodeJson() {
    final text = const JsonEncoder.withIndent('  ').convert(toJson());

    if (utf8.encode(text).length > maxJsonBytes) {
      throw const FormatException('サイト一式のJSONが大きすぎます');
    }

    return text;
  }

  String encodeQr() {
    // JSON形式としてのサイズ上限も確認する。
    encodeJson();

    final compressed = gzip.encode(utf8.encode(jsonEncode(toJson())));

    final payload =
        '$prefix${base64Url.encode(compressed).replaceAll('=', '')}';

    if (payload.length > maxQrCharacters) {
      throw const FormatException(
        '圧縮後も1枚のQRの容量を超えています。'
        '設定は省略していません。JSONで共有してください',
      );
    }

    return payload;
  }

  static SiteRuleBundle parse(String input) {
    try {
      var text = input.trim();

      if (text.length > maxJsonBytes ||
          utf8.encode(text).length > maxJsonBytes) {
        throw const FormatException('サイト一式の設定が大きすぎます');
      }

      if (text.startsWith(prefix)) {
        if (text.length > maxQrCharacters) {
          throw const FormatException('QR内容が容量上限を超えています');
        }

        final encoded = text.substring(prefix.length);
        final compressed = base64Url.decode(base64Url.normalize(encoded));

        final output = _LimitedBytes(maxJsonBytes);
        final decoder = gzip.decoder.startChunkedConversion(output);

        // 展開時にも容量を制限する。
        decoder.add(compressed);
        decoder.close();

        text = utf8.decode(output.bytes);
      }

      if (utf8.encode(text).length > maxJsonBytes) {
        throw const FormatException('展開したJSONが大きすぎます');
      }

      final value = jsonDecode(text);

      if (value is! Map) {
        throw const FormatException('サイト一式のJSONはオブジェクト形式です');
      }

      final data = Map<String, dynamic>.from(value);

      if (data['format'] != format ||
          !const [1, 2, 3, 4, 5].contains(data['version']) ||
          data.keys.any(
            (key) => !const {
              'format',
              'version',
              'name',
              'rules',
              'images',
              'tagNavigation',
              'searchSettings',
              'browseTabs',
              'readingSettings',
            }.contains(key),
          )) {
        throw const FormatException('未対応のサイト一式形式です');
      }

      if (data.containsKey('tagNavigation') &&
          !const [2, 3, 4, 5].contains(data['version'])) {
        throw const FormatException('タグ先設定を含む共有JSONにはバージョン2が必要です');
      }

      if (data.containsKey('searchSettings') &&
          !const [3, 4, 5].contains(data['version'])) {
        throw const FormatException('検索設定を含む共有JSONにはバージョン3が必要です');
      }

      if (data.containsKey('browseTabs') &&
          !const [4, 5].contains(data['version'])) {
        throw const FormatException('タブ設定を含む共有JSONにはバージョン4が必要です');
      }

      if (data.containsKey('readingSettings') && data['version'] != 5) {
        throw const FormatException('開き方設定を含む共有JSONにはバージョン5が必要です');
      }

      // 共有元のIDと保存日時は移植しない。
      // 新規追加時は新しいID、更新時は保存先のIDを使用する。
      final checked = SavedSiteRule.fromJson({
        'id': 'AAAAAAAAAAAAAAAAAAAAAA',
        'name': data['name'],
        'updatedAt': '2000-01-01T00:00:00.000Z',
        'rules': data['rules'],
        if (data.containsKey('readingSettings'))
          'readingSettings': data['readingSettings'],
        if (data.containsKey('browseTabs')) 'browseTabs': data['browseTabs'],
        if (data.containsKey('searchSettings'))
          'searchSettings': data['searchSettings'],
        if (data.containsKey('images')) 'images': data['images'],
        if (data.containsKey('tagNavigation'))
          'tagNavigation': data['tagNavigation'],
      });

      return SiteRuleBundle._(checked);
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException(
        'サイト一式を読み取れません。'
        'JSONまたはQR内容を確認してください',
      );
    }
  }
}

class _LimitedBytes implements Sink<List<int>> {
  _LimitedBytes(this.limit);

  final int limit;
  final BytesBuilder _builder = BytesBuilder(copy: false);

  int _length = 0;

  Uint8List get bytes => _builder.toBytes();

  @override
  void add(List<int> data) {
    _length += data.length;

    if (_length > limit) {
      throw const FormatException('圧縮設定の展開サイズが上限を超えています');
    }

    _builder.add(data);
  }

  @override
  void close() {}
}

/// 保存設定自体は変更せず、通常HTMLで先頭の一覧を確認する。
/// 作品一覧がない場合はチャプターのサンプルページを使用する。
Future<RuleBrowseResult> checkSiteBundleStatic(
  SiteRuleBundle bundle, {
  required CancelToken cancelToken,
  RulePageFetcher? fetcher,
}) async {
  final site = bundle.site;
  final kind = site.rules.containsKey('works') ? 'works' : 'chapters';
  final source = site.rules[kind]!;

  final staticRule = ListExtractionRule(
    pageUrl: source.pageUrl,
    groupSelector: source.groupSelector,
    fields: Map.of(source.fields),
    kind: source.kind,
    acquisition: 'staticHtml',
    details: Map.of(source.details),
    paginationUrl: source.paginationUrl,
  );

  final temporarySite = SavedSiteRule(
    id: site.id,
    name: site.name,
    updatedAt: site.updatedAt,
    rules: {...site.rules, kind: staticRule},
    images: site.images,
    tagNavigation: site.tagNavigation,
    searchSettings: site.searchSettings,
    browseTabs: site.browseTabs,
    readingSettings: site.readingSettings,
  );

  final client = RuleBrowseClient(fetcher: fetcher);

  try {
    final result = await client.load(
      site: temporarySite,
      kind: kind,
      cancelToken: cancelToken,
      targetUrl: kind == 'chapters' ? source.pageUrl : null,
    );

    if (!result.items.any((item) => item.url != null)) {
      throw const FormatException(
        '通常HTMLでは開ける一覧項目を取得できませんでした。'
        '表示後HTMLが必要なサイト、または設定が合っていない'
        '可能性があります',
      );
    }

    return result;
  } finally {
    client.close();
  }
}
