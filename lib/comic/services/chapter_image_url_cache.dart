/// 取得済みの本文画像URLだけを短時間保持する。
/// HTMLや画像ファイルの先行取得は行わない。
class ChapterImageUrlCache {
  ChapterImageUrlCache({
    this.maxAge = const Duration(minutes: 3),
    this.maxEntries = 12,
    this.maxImages = 6000,
  }) : assert(maxEntries > 0),
       assert(maxImages > 0);

  static final shared = ChapterImageUrlCache();

  final Duration maxAge;
  final int maxEntries;
  final int maxImages;

  final Map<String, _ChapterImageUrlEntry> _entries = {};
  int _imageCount = 0;

  List<Uri>? get(String key, {DateTime? now}) {
    final entry = _entries[key];
    if (entry == null) return null;

    final current = now ?? DateTime.now();

    if (current.isBefore(entry.savedAt) ||
        current.difference(entry.savedAt) >= maxAge) {
      _remove(key);
      return null;
    }

    _entries.remove(key);
    _entries[key] = entry;
    return entry.images;
  }

  void put(String key, List<Uri> images, {DateTime? now}) {
    _remove(key);

    if (images.isEmpty || images.length > maxImages) return;

    final copied = List<Uri>.unmodifiable(images);

    _entries[key] = _ChapterImageUrlEntry(
      images: copied,
      savedAt: now ?? DateTime.now(),
    );

    _imageCount += copied.length;

    while (_entries.length > maxEntries || _imageCount > maxImages) {
      _remove(_entries.keys.first);
    }
  }

  void _remove(String key) {
    final removed = _entries.remove(key);
    if (removed != null) {
      _imageCount -= removed.images.length;
    }
  }

  void clear() {
    _entries.clear();
    _imageCount = 0;
  }
}

class _ChapterImageUrlEntry {
  const _ChapterImageUrlEntry({required this.images, required this.savedAt});

  final List<Uri> images;
  final DateTime savedAt;
}
