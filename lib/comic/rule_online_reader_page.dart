import 'services/rule_video_support.dart';
import 'rule_video_reader_page.dart';
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import 'reader_page.dart';
import 'reading_progress.dart';
import 'rendered_rule_page.dart';
import 'services/html_probe.dart';
import 'services/rule_browse_client.dart';
import 'services/rule_content_client.dart';
import 'services/chapter_image_url_cache.dart';
import 'services/opened_chapter_store.dart';
import 'services/rule_downloads.dart';
import 'services/site_rule_store.dart';
import 'services/rule_library.dart';
import 'rule_library_widgets.dart';

class RuleOnlineReaderPage extends StatefulWidget {
  const RuleOnlineReaderPage({
    super.key,
    required this.site,
    required this.chapters,
    required this.initialIndex,
    this.workThumbnail,
    this.workUrl,
    this.workTitle,
  }) : assert(chapters.length > 0),
       assert(initialIndex >= 0 && initialIndex < chapters.length);

  final SavedSiteRule site;

  /// 開いた時点の一覧表示順を維持する。
  final List<RuleBrowseItem> chapters;
  final int initialIndex;
  final Uri? workThumbnail;
  final String? workUrl;
  final String? workTitle;

  @override
  State<RuleOnlineReaderPage> createState() => _RuleOnlineReaderPageState();
}

class _RuleOnlineReaderPageState extends State<RuleOnlineReaderPage> {
  final _client = RuleContentClient(imageUrlCache: ChapterImageUrlCache.shared);

  CancelToken? _cancel;
  late int _index;
  List<Uri> _images = [];
  List<File> _files = [];
  bool _loading = false;
  bool _opened = false;
  bool _waitingControls = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;

    // 画面を開く遷移中に別のWebView画面をpushしない。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      _load(_index);
    });
  }

  Future<HtmlProbePage> _fetchRendered(
    String input, {
    required CancelToken cancelToken,
    required String allowedOrigin,
    required String groupSelector,
  }) async {
    await WidgetsBinding.instance.endOfFrame;

    if (!mounted ||
        cancelToken.isCancelled ||
        ModalRoute.of(context)?.isCurrent != true) {
      throw StateError('本文画像の取得を中止しました');
    }

    final page = await Navigator.of(context).push<HtmlProbePage>(
      MaterialPageRoute<HtmlProbePage>(
        builder: (_) => RenderedRulePage(
          url: input,
          allowedOrigin: allowedOrigin,
          groupSelector: groupSelector,
          cancelToken: cancelToken,
          backgroundMode: true,
          silentMode: true,
          imageAttribute: widget.site.images?.rule.attribute,
        ),
      ),
    );

    if (page == null || cancelToken.isCancelled) {
      throw StateError('本文画像の取得を中止しました');
    }

    return page;
  }

  Future<void> _load(int target) async {
    if (usesRuleVideo(widget.site)) return;
    if (_loading ||
        target < 0 ||
        target >= widget.chapters.length ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }

    final chapter = widget.chapters[target];
    final url = chapter.url;

    if (url == null) return;

    final token = CancelToken();
    _cancel = token;

    final openingClock = Stopwatch()..start();

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final downloads = await RuleDownloads.open();
      if (!mounted || token.isCancelled) return;

      // 保存IDはサイトIDとチャプターURLで決まる。
      // 作品URLを知らない読書画面からも同じ保存を参照できる。
      final local = await downloads.files(
        ruleSavedChapter(
          siteId: widget.site.id,
          workUrl: url.toString(),
          chapterUrl: url.toString(),
          title: chapter.title,
        ),
      );

      if (!mounted || token.isCancelled) return;

      final localCheckMs = openingClock.elapsedMilliseconds;

      // 保存済みならHTML取得も画像通信も行わない。
      final images = local.isNotEmpty
          ? const <Uri>[]
          : await _client.load(
              site: widget.site,
              chapterUrl: url.toString(),
              cancelToken: token,
              renderedFetcher: _fetchRendered,
            );

      if (!mounted || token.isCancelled) return;

      setState(() {
        _index = target;
        _images = images;
        _files = local;
        _opened = true;
      });

      assert(() {
        debugPrint(
          '[reader-open] '
          'local_check=${localCheckMs}ms '
          'urls_ready=${openingClock.elapsedMilliseconds}ms '
          'source=${local.isNotEmpty ? 'offline' : 'network'} '
          'pages=${local.isNotEmpty ? local.length : images.length}',
        );
        return true;
      }());
    } catch (error) {
      if (!mounted || token.isCancelled) return;

      final message = '「${chapter.title}」を開けませんでした。\n$error';

      if (_opened) {
        // 前後の話の取得失敗で、現在読めている本文は消さない。
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(message),
              action: SnackBarAction(
                label: '再試行',
                onPressed: () => _load(target),
              ),
            ),
          );
      } else {
        setState(() => _error = message);
      }
    } finally {
      if (identical(_cancel, token)) _cancel = null;
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _rememberChapterOpened(String chapterUrl) async {
    try {
      final chapter = widget.chapters.firstWhere(
        (item) => item.url?.removeFragment().toString() == chapterUrl,
      );
      final downloads = await RuleDownloads.open();

      await rememberRuleLibrary(
        store: downloads.store,
        record: ruleLibraryWork(
          site: widget.site,
          workUrl: widget.workUrl ?? chapterUrl,
          title: widget.workTitle ?? chapter.title,
          thumbnail: widget.workThumbnail,
        ),
        chapter: chapter,
        chapters: widget.chapters,
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('履歴を保存できませんでした：$error')));
      }
    }
    try {
      await OpenedChapterStore.shared.mark(
        siteId: widget.site.id,
        chapterUrl: chapterUrl,
      );
    } catch (error) {
      // 記録失敗で読書を中断しない。
      assert(() {
        debugPrint('[opened-chapter] save_failed=$error');
        return true;
      }());
    }
  }

  @override
  void dispose() {
    _cancel?.cancel('読書画面終了');
    _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (usesRuleVideo(widget.site)) {
      return RuleVideoReaderPage(
        site: widget.site,
        chapters: widget.chapters,
        initialIndex: widget.initialIndex,
        workUrl: widget.workUrl,
        workTitle: widget.workTitle,
        workThumbnail: widget.workThumbnail,
      );
    }
    final chapter = widget.chapters[_index];

    if (!_opened && (_loading || _error == null)) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            setState(() => _waitingControls = !_waitingControls);
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Colors.black),
              const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text(
                      '画像を準備しています…',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),
              if (_waitingControls)
                const SafeArea(
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: BackButton(color: Colors.white),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    if (!_opened) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(title: Text(chapter.title)),
        body: Center(
          child: _loading
              ? const CircularProgressIndicator()
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _error ?? '本文画像を取得する準備ができました。',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: () => _load(_index),
                        icon: const Icon(Icons.refresh),
                        label: const Text('再試行'),
                      ),
                    ],
                  ),
                ),
        ),
      );
    }

    final chapterUrl = chapter.url!.removeFragment().toString();

    return Stack(
      fit: StackFit.expand,
      children: [
        AbsorbPointer(
          absorbing: _loading,
          child: ReaderPage(
            key: ValueKey('${widget.site.id}:$chapterUrl'),
            files: _files,
            imageUrls: _images,
            title: chapter.title,
            onOpened: () {
              unawaited(_rememberChapterOpened(chapterUrl));
            },
            chapterStateAction: RuleLibraryFavoriteButton(
              site: widget.site,
              workUrl: widget.workUrl ?? chapterUrl,
              title: widget.workTitle ?? chapter.title,
              thumbnail: widget.workThumbnail,
            ),
            progressKey: ReadingKey(
              // 既存の組み込みサイトの識別子とは分離する。
              sourceId: 'custom-site:${widget.site.id}',
              chapterId: chapterUrl,
            ),
            onPreviousChapter: _index > 0 ? () => _load(_index - 1) : null,
            onNextChapter: _index + 1 < widget.chapters.length
                ? () => _load(_index + 1)
                : null,
          ),
        ),
        if (_loading)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                setState(() => _waitingControls = !_waitingControls);
              },
              child: ColoredBox(
                color: Colors.black,
                child: _waitingControls
                    ? const SafeArea(
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: BackButton(color: Colors.white),
                        ),
                      )
                    : const SizedBox.expand(),
              ),
            ),
          ),
      ],
    );
  }
}
