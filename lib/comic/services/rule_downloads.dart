import 'rule_video_support.dart';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../sources/source_adapter.dart';
import 'download_store.dart';
import 'chapter_reading_order.dart';
import 'html_probe.dart';
import 'headless_download_page.dart';
import 'rule_browse_client.dart';
import 'rule_content_client.dart';
import 'saved_download_repository.dart';
import 'site_rule_store.dart';
import 'serial_download_batch.dart';

final _ruleSiteId = RegExp(r'^[A-Za-z0-9_-]{22}$');

String _sourceId(String siteId) {
  if (!_ruleSiteId.hasMatch(siteId)) {
    throw const FormatException('サイトIDが不正です');
  }
  return 'custom-site:$siteId';
}

/// サイトIDとチャプターURLが同じなら、同じ保存IDになる。
/// フラグメントだけ除き、クエリ文字列は保持する。
ComicChapter ruleSavedChapter({
  required String siteId,
  required String workUrl,
  required String chapterUrl,
  required String title,
  String? publishedDateText,
}) {
  final source = _sourceId(siteId);
  final work = htmlProbeUri(workUrl);
  final url = htmlProbeUri(chapterUrl);

  if (work.origin != url.origin) {
    throw const FormatException('作品とチャプターの取得元が異なります');
  }

  final canonical = url.toString();
  final hash = sha256.convert(utf8.encode(jsonEncode([source, canonical])));

  return ComicChapter(
    sourceId: source,
    language: '',
    workId: work.toString(),
    id: canonical,
    title: title,
    url: url,
    storageId: 'custom-$hash',
    progressSourceId: source,
    progressChapterId: canonical,
    publishedDateText: publishedDateText,
  );
}

void _validateChapter(ComicChapter chapter) {
  const prefix = 'custom-site:';
  if (!chapter.sourceId.startsWith(prefix)) {
    throw const FormatException('汎用サイトの保存情報ではありません');
  }

  final expected = ruleSavedChapter(
    siteId: chapter.sourceId.substring(prefix.length),
    workUrl: chapter.workId,
    chapterUrl: chapter.url.toString(),
    title: chapter.title,
  );

  if (chapter.storageId != expected.storageId ||
      chapter.id != expected.id ||
      chapter.language != '' ||
      chapter.progressSourceId != expected.progressSourceId ||
      chapter.progressChapterId != expected.progressChapterId) {
    throw const FormatException('保存情報の識別子が一致しません');
  }
}

class RuleTransferState {
  const RuleTransferState({
    this.chapterId = '',
    this.running = false,
    this.done = 0,
    this.total = 0,
    this.message = '',
    this.failed = false,
  });

  final String chapterId;
  final bool running;
  final int done;
  final int total;
  final String message;
  final bool failed;
}

/// アプリ内で共有し、同時に保存する話は1話に制限する。
/// その話の画像は最大4件並列取得する。
class RuleDownloads {
  RuleDownloads(this.store);

  final DownloadStore store;

  static Future<RuleDownloads>? _shared;

  static Future<RuleDownloads> open() => _shared ??= _open();

  static Future<RuleDownloads> _open() async {
    final support = await getApplicationSupportDirectory();
    final root = Directory(p.join(support.path, 'comics'));
    await root.create(recursive: true);
    return RuleDownloads(DownloadStore(root, maxConcurrentImages: 4));
  }

  final state = ValueNotifier<RuleTransferState>(const RuleTransferState());

  final batch = SerialDownloadBatch<ComicChapter>();

  bool _singleBusy = false;

  bool get isBusy =>
      _singleBusy || batch.state.value.running || state.value.running;

  void _notifyTransferState() {
    final current = state.value;
    state.value = RuleTransferState(
      chapterId: current.chapterId,
      running: current.running,
      done: current.done,
      total: current.total,
      message: current.message,
      failed: current.failed,
    );
  }

  CancelToken? _token;
  DownloadStore? _transfer;

  Future<List<File>> files(ComicChapter chapter) async {
    _validateChapter(chapter);

    final folder = store.directory(chapter);
    final folderType = await FileSystemEntity.type(
      folder.path,
      followLinks: false,
    );

    if (folderType == FileSystemEntityType.notFound) {
      return const <File>[];
    }
    if (folderType != FileSystemEntityType.directory) {
      throw const FormatException('通常の保存フォルダではありません');
    }

    final manifest = File(p.join(folder.path, 'manifest.json'));
    final manifestType = await FileSystemEntity.type(
      manifest.path,
      followLinks: false,
    );

    if (manifestType == FileSystemEntityType.notFound) {
      return const <File>[];
    }
    if (manifestType != FileSystemEntityType.file) {
      throw const FormatException('通常の保存情報ファイルではありません');
    }

    final result = await store.load(chapter);

    final data = Map<String, dynamic>.from(
      jsonDecode(await manifest.readAsString()) as Map,
    );
    final recorded = ComicChapter.fromJson(
      Map<String, dynamic>.from(data['chapter'] as Map),
    );
    _validateChapter(recorded);

    if (recorded.storageId != chapter.storageId ||
        recorded.sourceId != chapter.sourceId) {
      throw const FormatException('別のチャプターの保存情報です');
    }

    for (final file in result) {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const FormatException('通常の画像ファイルではありません');
      }
    }

    return List<File>.unmodifiable(result);
  }

  Future<SavedDownloadScan> scan(String siteId) async {
    final repository = SavedDownloadRepository(
      store,
      _RuleOfflineAdapter(_sourceId(siteId)),
    );
    final scanned = await repository.scan();
    final accepted = <SavedChapter>[];
    final issues = List<String>.of(scanned.issues);

    for (final item in scanned.chapters) {
      try {
        _validateChapter(item.chapter);
        accepted.add(item);
      } catch (error) {
        issues.add('${item.chapter.title}：$error');
      }
    }

    return SavedDownloadScan(
      List<SavedChapter>.unmodifiable(
        chapterReadingOrder<SavedChapter>(
          accepted,
          titleOf: (item) => item.chapter.title,
          workKeyOf: (item) => item.chapter.workId,
        ),
      ),
      List<String>.unmodifiable(issues),
    );
  }

  String _workCacheKey(ComicChapter chapter) =>
      'custom-download-work:${chapter.sourceId}:${chapter.workId}';

  Future<String> workTitle(ComicChapter chapter) async {
    final data = await store.readCache(_workCacheKey(chapter));
    if (data is Map && data['title'] is String) {
      final title = (data['title'] as String).trim();
      if (title.isNotEmpty) return title;
    }
    return chapter.workId;
  }

  Future<void> save({
    required SavedSiteRule site,
    required ComicChapter chapter,
    required String workTitle,
    RenderedRulePageFetcher? renderedFetcher,
  }) async {
    requireRuleImageDownload(site);
    if (isBusy) return;

    _singleBusy = true;
    try {
      await _saveOne(
        site: site,
        chapter: chapter,
        workTitle: workTitle,
        renderedFetcher: renderedFetcher,
      );
    } finally {
      _singleBusy = false;
      _notifyTransferState();
    }
  }

  Future<void> saveBatch({
    required SavedSiteRule site,
    required String workUrl,
    required String workTitle,
    required Iterable<ComicChapter> chapters,
  }) async {
    if (isBusy) {
      throw StateError('別のダウンロードを実行中です');
    }
    requireRuleImageDownload(site);
    if (site.images == null) {
      throw const FormatException('本文画像ルールが未設定です');
    }

    final canonicalWork = htmlProbeUri(workUrl).toString();
    final tasks = List<ComicChapter>.of(chapters);

    // 別作品・別サイトが紛れた状態で保存を開始しない。
    for (final chapter in tasks) {
      _validateChapter(chapter);
      if (chapter.sourceId != _sourceId(site.id) ||
          chapter.workId != canonicalWork) {
        throw const FormatException('一括保存に別作品のチャプターが含まれています');
      }
    }

    try {
      await batch.run(
        tasks,
        scope: jsonEncode([site.id, canonicalWork]),
        keyOf: (chapter) => chapter.storageId,
        titleOf: (chapter) => chapter.title,
        isSaved: (chapter) async {
          try {
            return (await files(chapter)).isNotEmpty;
          } catch (_) {
            // 不足・破損のある保存はスキップせず、再構築する。
            return false;
          }
        },
        save: (chapter) async {
          await _saveOne(site: site, chapter: chapter, workTitle: workTitle);

          if (state.value.failed) {
            throw StateError(state.value.message);
          }
        },
      );
    } finally {
      _notifyTransferState();
    }
  }

  Future<void> _saveOne({
    required SavedSiteRule site,
    required ComicChapter chapter,
    required String workTitle,
    RenderedRulePageFetcher? renderedFetcher,
  }) async {
    if (state.value.running) return;

    final token = CancelToken();
    _token = token;

    state.value = RuleTransferState(
      chapterId: chapter.storageId,
      running: true,
      message: '保存を準備中',
    );

    final client = RuleContentClient();
    final transfer = DownloadStore(store.root, maxConcurrentImages: 4);
    _transfer = transfer;

    try {
      requireRuleImageDownload(site);
      _validateChapter(chapter);
      if (chapter.sourceId != _sourceId(site.id)) {
        throw const FormatException('別サイトのチャプターは保存できません');
      }

      // 完了済みなら、HTMLも画像も取り直さない。
      List<File> existing;
      try {
        existing = await files(chapter);
      } catch (_) {
        // 不足・破損した完了情報は、既存エンジンで再構築する。
        existing = const <File>[];
      }

      if (existing.isNotEmpty) {
        state.value = RuleTransferState(
          chapterId: chapter.storageId,
          done: existing.length,
          total: existing.length,
          message: '保存済み',
        );
        return;
      }

      if (token.isCancelled) throw StateError('保存を中断しました');

      state.value = RuleTransferState(
        chapterId: chapter.storageId,
        running: true,
        message: '本文画像URLを取得中',
      );

      final images = await client.load(
        site: site,
        chapterUrl: chapter.url.toString(),
        cancelToken: token,
        renderedFetcher: fetchRenderedDownloadPage,
      );

      if (token.isCancelled) throw StateError('保存を中断しました');

      if (workTitle.trim().isNotEmpty) {
        await store.writeCache(_workCacheKey(chapter), {
          'title': workTitle.trim(),
        });
      }

      if (token.isCancelled) throw StateError('保存を中断しました');

      await transfer.download(
        chapter,
        ChapterContent(
          images: images,
          credits: [
            'Site: ${site.name}',
            'Work: ${chapter.workId}',
            'Chapter: ${chapter.title}',
            'Source: ${chapter.url}',
            'Saved: ${DateTime.now().toUtc().toIso8601String()}',
            '権利は各権利者に帰属します。利用条件は取得元で確認してください。',
          ].join('\n'),
        ),
        (done, total) {
          state.value = RuleTransferState(
            chapterId: chapter.storageId,
            running: true,
            done: done,
            total: total,
            message: token.isCancelled ? '中断処理中' : '$done / $total ページ',
          );
        },
      );

      state.value = RuleTransferState(
        chapterId: chapter.storageId,
        done: images.length,
        total: images.length,
        message: '保存済み',
      );
    } catch (error) {
      state.value = RuleTransferState(
        chapterId: chapter.storageId,
        message: token.isCancelled
            ? '中断しました。もう一度押すと再開します。'
            : '保存に失敗しました：$error',
        failed: true,
      );
    } finally {
      client.close();
      transfer.close();
      if (identical(_token, token)) _token = null;
      if (identical(_transfer, transfer)) _transfer = null;
    }
  }

  void stop() {
    // 現在の話を止め、次の話への進行も止める。
    batch.stop();
    if (!state.value.running) return;
    _token?.cancel('ユーザーによる保存中断');
    _transfer?.close();
  }

  Future<void> delete(SavedChapter item) async {
    if (isBusy) {
      throw StateError('保存中は削除できません');
    }

    _validateChapter(item.chapter);
    await SavedDownloadRepository(
      store,
      _RuleOfflineAdapter(item.chapter.sourceId),
    ).deleteChapter(item);

    state.value = RuleTransferState(
      chapterId: item.chapter.storageId,
      message: '削除しました',
    );
  }
}

/// 保存済みリポジトリのサイト絞り込みに使用する。
/// ネットワーク取得は担当しない。
class _RuleOfflineAdapter extends SourceAdapter {
  _RuleOfflineAdapter(this.id);

  @override
  final String id;

  @override
  String get name => '汎用サイトの保存済み';

  @override
  List<SourceTab> get defaultTabs => const [];

  @override
  Future<List<SourceTab>> discoverTabs() async => const [];

  @override
  Future<List<ComicWork>> fetchWorks(BrowseQuery query) async =>
      throw UnsupportedError('保存済み専用です');

  @override
  Future<List<ComicChapter>> fetchChapters(
    ComicWork work,
    BrowseQuery query,
  ) async => throw UnsupportedError('保存済み専用です');

  @override
  Future<ChapterContent> fetchContent(ComicChapter chapter) async =>
      throw UnsupportedError('保存済み専用です');

  @override
  ComicChapter? restoreChapter(Map<String, dynamic> data) => null;

  @override
  void close() {}
}
