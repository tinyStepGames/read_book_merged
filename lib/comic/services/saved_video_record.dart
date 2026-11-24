import 'dart:convert';

import '../sources/source_adapter.dart';
import 'rule_downloads.dart';
import 'video_download_engine.dart';
import 'video_progress.dart';

/// 配信URLではなく、サイト・作品・話の識別情報を保存する。
class SavedVideoRecord {
  SavedVideoRecord({
    required this.siteId,
    required this.siteName,
    required this.workTitle,
    required this.chapter,
  }) {
    _validate();
  }

  final String siteId;
  final String siteName;
  final String workTitle;
  final ComicChapter chapter;

  factory SavedVideoRecord.create({
    required String siteId,
    required String siteName,
    required String workUrl,
    required String chapterUrl,
    required String title,
    required String workTitle,
  }) {
    final label = title.trim().isEmpty ? chapterUrl : title.trim();

    return SavedVideoRecord(
      siteId: siteId,
      siteName: siteName,
      workTitle: workTitle.trim().isEmpty ? label : workTitle.trim(),
      chapter: ruleSavedChapter(
        siteId: siteId,
        workUrl: workUrl,
        chapterUrl: chapterUrl,
        title: label,
      ),
    );
  }

  void _validate() {
    if (siteName.length > 8192 ||
        workTitle.length > 8192 ||
        chapter.title.isEmpty ||
        chapter.title.length > 8192) {
      throw const FormatException('保存動画の表示情報が不正です');
    }

    final expected = ruleSavedChapter(
      siteId: siteId,
      workUrl: chapter.workId,
      chapterUrl: chapter.url.toString(),
      title: chapter.title,
      publishedDateText: chapter.publishedDateText,
    );

    if (jsonEncode(expected.toJson()) != jsonEncode(chapter.toJson())) {
      throw const FormatException('保存動画のサイト・作品・話の識別情報が一致しません');
    }
  }

  String get identity => jsonEncode([siteId, chapter.workId, chapter.id]);

  String get id => VideoDownloadRepository.idFor(identity);

  String get progressKey =>
      ruleVideoProgressKey(siteId: siteId, chapterUrl: chapter.url.toString());

  Map<String, dynamic> toJson() => {
    'version': 1,
    'siteId': siteId,
    'siteName': siteName,
    'workTitle': workTitle,
    'chapter': chapter.toJson(),
  };

  factory SavedVideoRecord.fromJson(Map<String, dynamic> data) {
    if (data['version'] != 1 ||
        data['siteId'] is! String ||
        data['siteName'] is! String ||
        data['workTitle'] is! String ||
        data['chapter'] is! Map) {
      throw const FormatException('保存動画の作品情報が不正です');
    }

    try {
      return SavedVideoRecord(
        siteId: data['siteId'] as String,
        siteName: data['siteName'] as String,
        workTitle: data['workTitle'] as String,
        chapter: ComicChapter.fromJson(
          Map<String, dynamic>.from(data['chapter'] as Map),
        ),
      );
    } catch (_) {
      throw const FormatException('保存動画の識別情報を復元できませんでした');
    }
  }

  static SavedVideoRecord forPackage(SavedVideoPackage package) {
    final record = SavedVideoRecord.fromJson(package.metadata);

    if (record.id != package.id || record.chapter.title != package.title) {
      throw const FormatException('保存動画と作品情報が一致しません');
    }
    return record;
  }
}

int savedVideoBytes(SavedVideoPackage video) => video.files.values.fold<int>(
  0,
  (sum, file) => sum + (file['bytes'] as int),
);

String savedVideoSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
}
