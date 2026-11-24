import 'peppercarrot_metadata.dart';
import 'package:dio/dio.dart';
import 'package:html/parser.dart' as html;

import 'source_adapter.dart';

class PepperCarrotAdapter extends SourceAdapter {
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );

  static const _host = 'www.peppercarrot.com';

  static const _groups = {
    'peppercarrot': ['peppercarrot', 'webcomic', 'ペッパー＆キャロット'],
    'mini': ['miniFantasyTheater', 'miniFantasyTheater', 'ミニファンタジーシアター'],
    'misc': ['misc', 'webcomic-misc', 'その他'],
  };

  @override
  String get id => 'peppercarrot';

  @override
  String get name => 'Pepper&Carrot';

  @override
  List<SourceTab> get defaultTabs => const [
    SourceTab('ja', '日本語', BrowseQuery(language: 'ja')),
    SourceTab('en', 'English', BrowseQuery(language: 'en')),
  ];

  String _language(BrowseQuery query) {
    if (!RegExp(r'^[a-z][a-z0-9-]{0,15}$').hasMatch(query.language)) {
      throw const FormatException('言語コードが不正です');
    }
    return query.language;
  }

  Uri _index(String language, String file) =>
      Uri.parse('https://$_host/$language/webcomics/$file.html');

  Future<String> _get(Uri url) async {
    if (url.scheme != 'https' || url.host != _host) {
      throw const FormatException('未対応の取得先です');
    }

    final response = await _dio.get<String>(
      url.toString(),
      options: Options(responseType: ResponseType.plain),
    );
    return response.data ?? '';
  }

  @override
  Future<List<SourceTab>> discoverTabs() async {
    final base = _index('ja', 'peppercarrot');
    final document = html.parse(await _get(base));
    final tabs = <String, SourceTab>{
      for (final tab in defaultTabs) tab.id: tab,
    };

    for (final link in document.querySelectorAll(
      '.responsive-langmenu ul.langmenu a[href]',
    )) {
      final url = base.resolve(link.attributes['href']!);

      if (url.host != _host) continue;

      final match = RegExp(
        r'^/([a-z][a-z0-9-]*)/webcomics/peppercarrot\.html$',
      ).firstMatch(url.path);

      if (match == null) continue;

      final language = match.group(1)!;
      final title = link.querySelector('span[dir]')?.text.trim() ?? language;

      tabs.putIfAbsent(
        language,
        () => SourceTab(language, title, BrowseQuery(language: language)),
      );
    }

    return tabs.values.toList();
  }

  @override
  List<ComicWork> fallbackWorks(BrowseQuery query) {
    final language = _language(query);

    return [
      for (final entry in _groups.entries)
        ComicWork(
          id: entry.key,
          title: entry.value[2],
          url: _index(language, entry.value[0]),
        ),
    ];
  }

  @override
  Future<List<ComicWork>> fetchWorks(BrowseQuery query) async {
    final language = _language(query);
    final base = _index(language, 'peppercarrot');
    final document = html.parse(await _get(base));
    final results = <String, ComicWork>{};

    final cssUrl = RegExp(
      r'''url\(\s*(['"]?)(.*?)\1\s*\)''',
      caseSensitive: false,
    );

    for (final link in document.querySelectorAll('a.sidebar-img-btn[id]')) {
      for (final group in _groups.entries) {
        if (link.id != group.value[0]) continue;

        final url = base.resolve(link.attributes['href'] ?? '');
        if (url.host != _host ||
            url.path != '/$language/webcomics/${group.value[0]}.html') {
          continue;
        }

        final image = cssUrl
            .firstMatch(link.attributes['style'] ?? '')
            ?.group(2)
            ?.trim();

        final thumbnail = image == null ? null : base.resolve(image);

        results[group.key] = ComicWork(
          id: group.key,
          title: language == 'ja'
              ? group.value[2]
              : link.text.trim().isEmpty
              ? group.value[2]
              : link.text.trim(),
          url: url,
          thumbnail: thumbnail?.scheme == 'https' && thumbnail?.host == _host
              ? thumbnail.toString()
              : null,
        );
      }
    }

    if (results.isEmpty) {
      throw StateError('作品一覧が見つかりません');
    }

    return [
      for (final key in _groups.keys)
        if (results.containsKey(key)) results[key]!,
    ];
  }

  ComicChapter parseChapter(
    String address,
    String title, {
    String? publishedDateText,
  }) {
    final url = Uri.parse(address);

    if (url.scheme != 'https' ||
        url.host != _host ||
        url.hasQuery ||
        url.hasFragment) {
      throw const FormatException('未対応のチャプターURLです');
    }

    final match = RegExp(
      r'^/([a-z][a-z0-9-]*)/'
      r'(webcomic|miniFantasyTheater|webcomic-misc)/'
      r'([A-Za-z0-9_-]+)\.html$',
    ).firstMatch(url.path);

    if (match == null) {
      throw const FormatException('チャプターURLではありません');
    }

    final language = match.group(1)!;
    final section = match.group(2)!;
    final slug = match.group(3)!;

    final workId = _groups.entries
        .firstWhere((entry) => entry.value[1] == section)
        .key;

    String storageId;

    if (workId == 'peppercarrot') {
      final episode = RegExp(r'^ep(\d+)_').firstMatch(slug);
      if (episode == null) {
        throw const FormatException('話数形式が不正です');
      }
      final number = int.parse(episode.group(1)!);
      storageId =
          'peppercarrot-$language-ep${number.toString().padLeft(2, '0')}';
    } else {
      storageId = '$workId-$language-$slug';
    }

    return ComicChapter(
      sourceId: id,
      language: language,
      workId: workId,
      id: slug,
      title: title.trim().isEmpty ? slug : title.trim(),
      url: url,
      storageId: storageId,
      // 既存の閲覧位置のキーを維持する。
      progressSourceId: url.host,
      progressChapterId: url.path,
      publishedDateText: publishedDateText,
    );
  }

  @override
  Future<List<ComicChapter>> fetchChapters(
    ComicWork work,
    BrowseQuery query,
  ) async {
    final language = _language(query);
    final document = html.parse(await _get(work.url));
    final chapters = <String, ComicChapter>{};

    for (final link in document.querySelectorAll(
      'figure.thumbnail figcaption a[href]',
    )) {
      try {
        final chapter = parseChapter(
          work.url.resolve(link.attributes['href']!).toString(),
          link.text,
          publishedDateText: pepperCarrotPublishedDate(
            link.parent?.querySelector('span.caption-smaller')?.text,
          ),
        );

        if (chapter.language == language && chapter.workId == work.id) {
          chapters[chapter.id] = chapter;
        }
      } catch (_) {
        // 別言語・特殊リンクは取り込まない。
      }
    }

    if (chapters.isEmpty) {
      throw StateError('この言語のチャプターが見つかりません');
    }

    return chapters.values.toList()..sort((a, b) => a.id.compareTo(b.id));
  }

  @override
  Future<ChapterContent> fetchContent(ComicChapter chapter) async {
    final document = html.parse(await _get(chapter.url));
    final images = <Uri>[];
    final seen = <String>{};

    for (final image in document.querySelectorAll(
      '.webcomic-page img, #panel-all img.mft-cv-image',
    )) {
      final src = image.attributes['src'];
      if (src == null || src.isEmpty) continue;

      final url = chapter.url.resolve(src);
      if (url.scheme != 'https' ||
          url.host != _host ||
          !RegExp(
            r'\.(?:jpe?g|png|webp|gif)$',
            caseSensitive: false,
          ).hasMatch(url.path)) {
        throw const FormatException('未対応の画像URLです');
      }

      if (seen.add(url.toString())) images.add(url);
    }

    if (images.isEmpty) {
      throw StateError('本文画像が見つかりません');
    }

    final notes = <String>[
      chapter.title,
      '出典: ${chapter.url}',
      '本アプリは非公式リーダーです。画像データは変更していません。',
    ];

    final sections = document.querySelectorAll(
      '.webcomic-footer-box, .mft-cv-credits',
    );

    if (sections.isEmpty) {
      // 構造が異なる作品でも、本文のクレジットを落とさないための保険。
      notes.add(document.body?.text.trim() ?? '');
    } else {
      for (final section in sections) {
        notes.add(section.text.trim());
      }
    }

    for (final link in document.querySelectorAll('a[href]')) {
      final href = link.attributes['href']!;
      if (href.contains('creativecommons.org')) {
        notes.add(chapter.url.resolve(href).toString());
      }
    }

    return ChapterContent(images: images, credits: notes.toSet().join('\n\n'));
  }

  @override
  ComicChapter? restoreChapter(Map<String, dynamic> data) {
    try {
      final nested = data['chapter'];
      final values = nested is Map ? Map<String, dynamic>.from(nested) : data;

      return parseChapter(
        (values['url'] ?? values['sourceUrl']) as String,
        values['title'] as String,
        publishedDateText: values['publishedDateText'] is String
            ? values['publishedDateText'] as String
            : null,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  void close() => _dio.close(force: true);
}
