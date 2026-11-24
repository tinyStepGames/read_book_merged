class BrowseQuery {
  const BrowseQuery({
    this.language = '',
    this.feed = 'catalog',
    this.genre,
    this.cursor,
  });

  final String language;
  final String feed;
  final String? genre;
  final String? cursor;

  Map<String, dynamic> toJson() => {
    'language': language,
    'feed': feed,
    'genre': genre,
    'cursor': cursor,
  };

  factory BrowseQuery.fromJson(Map<String, dynamic> data) {
    return BrowseQuery(
      language: data['language'] as String? ?? '',
      feed: data['feed'] as String? ?? 'catalog',
      genre: data['genre'] as String?,
      cursor: data['cursor'] as String?,
    );
  }
}

class SourceTab {
  const SourceTab(this.id, this.title, this.query);

  final String id;
  final String title;
  final BrowseQuery query;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'query': query.toJson(),
  };

  factory SourceTab.fromJson(Map<String, dynamic> data) {
    return SourceTab(
      data['id'] as String,
      data['title'] as String,
      BrowseQuery.fromJson(Map<String, dynamic>.from(data['query'] as Map)),
    );
  }
}

class ComicWork {
  const ComicWork({
    required this.id,
    required this.title,
    required this.url,
    this.thumbnail,
  });

  final String id;
  final String title;
  final Uri url;
  final String? thumbnail;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'url': url.toString(),
    'thumbnail': thumbnail,
  };

  factory ComicWork.fromJson(Map<String, dynamic> data) {
    return ComicWork(
      id: data['id'] as String,
      title: data['title'] as String,
      url: Uri.parse(data['url'] as String),
      thumbnail: data['thumbnail'] as String?,
    );
  }
}

class ComicChapter {
  const ComicChapter({
    required this.sourceId,
    required this.language,
    required this.workId,
    required this.id,
    required this.title,
    required this.url,
    required this.storageId,
    required this.progressSourceId,
    required this.progressChapterId,
    this.publishedDateText,
  });

  final String sourceId;
  final String language;
  final String workId;
  final String id;
  final String title;
  final Uri url;

  // ローカル保存用。サイトのURLとは別に扱う。
  final String storageId;

  // 既存データとの互換性を保ちつつ、取得元ごとに決められる。
  final String progressSourceId;
  final String progressChapterId;

  /// サイト側が提供する公開日の表示文字列。
  /// 共通側では形式・タイムゾーン・日付精度を推測しない。
  final String? publishedDateText;

  Map<String, dynamic> toJson() => {
    'sourceId': sourceId,
    'language': language,
    'workId': workId,
    'id': id,
    'title': title,
    'url': url.toString(),
    'storageId': storageId,
    'progressSourceId': progressSourceId,
    'progressChapterId': progressChapterId,
    'publishedDateText': publishedDateText,
  };

  factory ComicChapter.fromJson(Map<String, dynamic> data) {
    return ComicChapter(
      sourceId: data['sourceId'] as String,
      language: data['language'] as String,
      workId: data['workId'] as String,
      id: data['id'] as String,
      title: data['title'] as String,
      url: Uri.parse(data['url'] as String),
      storageId: data['storageId'] as String,
      progressSourceId: data['progressSourceId'] as String,
      progressChapterId: data['progressChapterId'] as String,
      publishedDateText: data['publishedDateText'] as String?,
    );
  }
}

class ChapterContent {
  const ChapterContent({required this.images, required this.credits});

  final List<Uri> images;
  final String credits;
}

abstract class SourceAdapter {
  String get id;
  String get name;

  List<SourceTab> get defaultTabs;

  Future<List<SourceTab>> discoverTabs();

  // オフラインや初回表示向けの任意の初期データ。
  List<ComicWork> fallbackWorks(BrowseQuery query) => [];

  Future<List<ComicWork>> fetchWorks(BrowseQuery query);

  Future<List<ComicChapter>> fetchChapters(ComicWork work, BrowseQuery query);

  Future<ChapterContent> fetchContent(ComicChapter chapter);

  // 旧形式のmanifestからも、取得元側で復元できる。
  ComicChapter? restoreChapter(Map<String, dynamic> data);

  void close();
}
