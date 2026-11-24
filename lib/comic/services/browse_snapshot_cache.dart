import 'dart:collection';
import 'dart:convert';

import 'rule_browse_client.dart';
import 'site_rule_store.dart';

class BrowseSnapshot {
  const BrowseSnapshot({
    required this.result,
    required this.fetchedAt,
    required this.lastPage,
    required this.pagesLoaded,
    required this.hasMore,
    required this.pagingEnd,
    required this.scrollOffset,
    required this.collection,
  });

  final RuleBrowseResult result;

  /// キャッシュへ保存し直しても、取得日時は延長しない。
  final DateTime fetchedAt;

  final int lastPage;
  final int pagesLoaded;
  final bool hasMore;
  final String pagingEnd;
  final double scrollOffset;
  final bool collection;
}

String browseSnapshotKey({
  required SavedSiteRule site,
  required String kind,
  required String? targetUrl,
}) => jsonEncode({
  'siteId': site.id,
  'updatedAt': site.updatedAt.toUtc().toIso8601String(),
  'kind': kind,
  'targetUrl': targetUrl,
  'rule': site.rules[kind]?.toJson(),
  'chapterOriginSample': site.rules['chapters']?.pageUrl,
  'readingSettings': site.readingSettings?.toJson(),
});

class BrowseSnapshotCache {
  BrowseSnapshotCache({
    this.ttl = const Duration(seconds: 60),
    this.maxEntries = 12,
    this.maxItems = 20000,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    if (ttl <= Duration.zero || maxEntries < 1 || maxItems < 1) {
      throw ArgumentError('キャッシュ上限は正の値で指定してください');
    }
  }

  static final shared = BrowseSnapshotCache();

  final Duration ttl;
  final int maxEntries;

  /// 全エントリーに含まれる一覧項目数の上限。
  /// 画像のデコード済みデータはここには保存しない。
  final int maxItems;

  final DateTime Function() _now;

  final _entries = LinkedHashMap<String, BrowseSnapshot>();

  bool _expired(BrowseSnapshot value) {
    final age = _now().difference(value.fetchedAt);
    return age.isNegative || age >= ttl;
  }

  void _removeExpired() {
    _entries.removeWhere((key, value) => _expired(value));
  }

  BrowseSnapshot? get(String key) {
    _removeExpired();

    final value = _entries.remove(key);
    if (value == null) return null;

    // 最近使用したものを末尾へ移す。
    _entries[key] = value;
    return value;
  }

  void put(String key, BrowseSnapshot value) {
    _removeExpired();
    _entries.remove(key);

    if (_expired(value) ||
        value.result.items.isEmpty ||
        !value.result.items.any((item) => item.url != null) ||
        value.result.items.length > maxItems) {
      return;
    }

    _entries[key] = value;

    while (_entries.length > maxEntries ||
        _entries.values.fold<int>(
              0,
              (sum, snapshot) => sum + snapshot.result.items.length,
            ) >
            maxItems) {
      _entries.remove(_entries.keys.first);
    }
  }

  void remove(String key) => _entries.remove(key);

  void clear() => _entries.clear();
}
