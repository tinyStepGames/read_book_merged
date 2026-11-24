import 'site_video_browser_page.dart';
import 'services/site_video_browser_policy.dart';
import 'video_download_page.dart';
import 'video_speed_button.dart';
import 'services/video_playback_speed.dart';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'rule_library_widgets.dart';
import 'services/download_store.dart';
import 'services/opened_chapter_store.dart';
import 'services/rule_browse_client.dart';
import 'services/rule_downloads.dart';
import 'services/rule_library.dart';
import 'services/site_rule_store.dart';
import 'services/video_progress.dart';
import 'services/video_source.dart';

class RuleVideoReaderPage extends StatefulWidget {
  const RuleVideoReaderPage({
    super.key,
    required this.site,
    required this.chapters,
    required this.initialIndex,
    this.workUrl,
    this.workTitle,
    this.workThumbnail,
  }) : assert(chapters.length > 0),
       assert(initialIndex >= 0 && initialIndex < chapters.length);

  final SavedSiteRule site;
  final List<RuleBrowseItem> chapters;
  final int initialIndex;
  final String? workUrl;
  final String? workTitle;
  final Uri? workThumbnail;

  @override
  State<RuleVideoReaderPage> createState() => _RuleVideoReaderPageState();
}

class _VideoSession {
  _VideoSession({
    required this.index,
    required this.player,
    required this.controller,
    required this.store,
    required this.progress,
    required this.progressKey,
  }) {
    // open中のエラーも後からawaitできるように保持。
    ready.future.ignore();
  }

  final int index;
  final Player player;
  final VideoController controller;
  final DownloadStore store;
  final VideoProgressStore progress;
  final String progressKey;
  final Completer<Duration> ready = Completer<Duration>();
  final List<StreamSubscription<dynamic>> subscriptions = [];

  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool restoring = true;
  bool hasPlayed = false;
  bool dirty = false;
  bool historyAttempted = false;
  Future<void>? lastWrite;
  Future<void>? _releaseFuture;

  Future<void> release() => _releaseFuture ??= _release();

  Future<void> _release() async {
    if (!ready.isCompleted) {
      ready.completeError(StateError('動画を閉じました'));
    }

    for (final subscription in subscriptions) {
      await subscription.cancel();
    }

    await player.dispose();
  }
}

class _RuleVideoReaderPageState extends State<RuleVideoReaderPage>
    with WidgetsBindingObserver {
  final _client = VideoSourceClient();

  late int _index;
  CancelToken? _cancel;
  VideoProgressStore? _progress;
  _VideoSession? _session;
  _VideoSession? _pending;
  Timer? _saveTimer;

  bool _loading = false;
  bool _changingRate = false;
  double _rate = VideoPlaybackSpeed.rate;
  bool _leaving = false;
  bool _allowPop = false;
  bool _saveWarningShown = false;
  int _generation = 0;
  String? _error;
  bool _openingSiteBrowser = false;
  int? _siteBrowserTarget;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    WidgetsBinding.instance.addObserver(this);

    _saveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final session = _session;
      if (session != null) unawaited(_saveQuietly(session));
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load(_index);
    });
  }

  bool _current(int generation, CancelToken token) =>
      mounted && !_leaving && !token.isCancelled && generation == _generation;

  void _notice(String message) {
    if (!mounted || _leaving) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _savePosition(_VideoSession session) async {
    if (!session.dirty || !session.hasPlayed || session.restoring) {
      final pendingWrite = session.lastWrite;
      if (pendingWrite != null) await pendingWrite;
      return;
    }

    final snapshot = VideoPosition(
      position: session.position,
      duration: session.duration,
    );
    session.dirty = false;

    final task = session.progress.save(session.progressKey, snapshot);
    session.lastWrite = task;

    try {
      await task;
    } catch (_) {
      session.dirty = true;
      rethrow;
    }
  }

  Future<void> _saveQuietly(_VideoSession session) async {
    try {
      await _savePosition(session);
    } catch (error) {
      if (!_saveWarningShown) {
        _saveWarningShown = true;
        _notice('再生位置を保存できませんでした：$error');
      }
    }
  }

  Future<void> _remember(_VideoSession session) async {
    final chapter = widget.chapters[session.index];
    final url = chapter.url;
    if (url == null) return;

    try {
      await rememberRuleLibrary(
        store: session.store,
        record: ruleLibraryWork(
          site: widget.site,
          workUrl: widget.workUrl ?? url.toString(),
          title: widget.workTitle ?? chapter.title,
          thumbnail: widget.workThumbnail,
        ),
        chapter: chapter,
        chapters: widget.chapters,
      );

      await OpenedChapterStore.shared.mark(
        siteId: widget.site.id,
        chapterUrl: url.removeFragment().toString(),
      );
    } catch (error) {
      _notice('動画の履歴を保存できませんでした：$error');
    }
  }

  void _listen(_VideoSession session) {
    session.subscriptions.add(
      session.player.stream.duration.listen((value) {
        if (value <= Duration.zero) return;

        session.duration = value;
        if (!session.ready.isCompleted) {
          session.ready.complete(value);
        }
      }),
    );

    session.subscriptions.add(
      session.player.stream.error.listen((message) {
        if (!session.ready.isCompleted) {
          session.ready.completeError(StateError(message));
        }

        if (identical(_session, session) && mounted && !_leaving) {
          setState(() => _error = '動画の再生中に問題が発生しました：$message');
        }
      }),
    );

    session.subscriptions.add(
      session.player.stream.position.listen((value) {
        if (!identical(_session, session) || session.restoring || _leaving) {
          return;
        }

        final playing = session.player.state.playing;

        // 復元用シークや、未再生で閉じただけでは履歴・位置を上書きしない。
        if (playing && value > Duration.zero) {
          session.hasPlayed = true;
        }
        if (!session.hasPlayed) return;

        // 再生完了後、プレーヤーが0へ戻しても末尾の位置を残す。
        if (session.player.state.completed && value == Duration.zero) {
          return;
        }

        session.position = value;
        session.dirty = true;

        if (playing && value > Duration.zero && !session.historyAttempted) {
          session.historyAttempted = true;
          unawaited(_remember(session));
        }
      }),
    );

    session.subscriptions.add(
      session.player.stream.playing.listen((playing) {
        if (!playing && identical(_session, session)) {
          unawaited(_saveQuietly(session));
        }
      }),
    );

    session.subscriptions.add(
      session.player.stream.completed.listen((completed) {
        if (!completed || !identical(_session, session) || !session.hasPlayed) {
          return;
        }

        if (session.duration > Duration.zero) {
          session.position = session.duration;
          session.dirty = true;
          unawaited(_saveQuietly(session));
        }

        // 自動で次の話には進まない。
      }),
    );
  }

  Future<void> _changeRate(double value) async {
    VideoPlaybackSpeed.validate(value);
    final session = _session;

    if (_loading || _changingRate || _leaving || session == null) {
      throw StateError('現在は再生速度を変更できません');
    }

    setState(() => _changingRate = true);

    try {
      await session.player.setRate(value).timeout(const Duration(seconds: 10));

      if (!mounted || _leaving || !identical(_session, session)) return;

      VideoPlaybackSpeed.remember(value);
      setState(() => _rate = value);
    } finally {
      if (mounted) setState(() => _changingRate = false);
    }
  }

  Future<void> _load(int target) async {
    if (_loading ||
        _changingRate ||
        _leaving ||
        _openingSiteBrowser ||
        target < 0 ||
        target >= widget.chapters.length) {
      return;
    }

    final token = CancelToken();
    _cancel = token;
    final generation = ++_generation;
    _VideoSession? candidate;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final settings = widget.site.readingSettings?.video;
      final chapter = widget.chapters[target];
      final url = chapter.url;

      if (settings == null || url == null) {
        throw const FormatException('動画設定または話のURLがありません');
      }

      settings.validateFor(
        widget.site.rules.values.map((rule) => rule.pageUrl),
      );

      // 作品・話の組み合わせを、既存の共通ライブラリと同じ方法で検証。
      final record = ruleLibraryWork(
        site: widget.site,
        workUrl: widget.workUrl ?? url.toString(),
        title: widget.workTitle ?? chapter.title,
        thumbnail: widget.workThumbnail,
      );
      ruleLibraryChapter(record: record, chapter: chapter);

      // リトライ時には現在の位置を先に保存。
      final existing = _session;
      if (existing != null && existing.index == target) {
        await _saveQuietly(existing);
      }

      final result = await _client.load(
        settings: settings,
        targetUrl: url.toString(),
        cancelToken: token,
      );

      if (!_current(generation, token)) return;

      if (!result.hasSingleUrl) {
        throw FormatException(
          '動画URLを1件に決定できませんでした。\n'
          '${result.issues.take(4).join('\n')}',
        );
      }

      final downloads = await RuleDownloads.open();
      if (!_current(generation, token)) return;

      final progress = _progress ??= VideoProgressStore(downloads.store);
      final progressKey = ruleVideoProgressKey(
        siteId: widget.site.id,
        chapterUrl: url.toString(),
      );
      final saved = await progress.read(progressKey);

      if (!_current(generation, token)) return;

      MediaKit.ensureInitialized();
      final player = Player();
      final next = _VideoSession(
        index: target,
        player: player,
        controller: VideoController(player),
        store: downloads.store,
        progress: progress,
        progressKey: progressKey,
      );

      candidate = next;
      _pending = next;
      _listen(next);

      // 選択した話だけを開き、自動再生・先読みはしない。
      await player
          .open(Media(result.urls.single.toString()), play: false)
          .timeout(const Duration(seconds: 40));

      if (!_current(generation, token)) return;

      final playbackRate = VideoPlaybackSpeed.rate;
      await player.setRate(playbackRate).timeout(const Duration(seconds: 10));

      if (!_current(generation, token)) return;

      final knownDuration = player.state.duration;
      if (knownDuration > Duration.zero && !next.ready.isCompleted) {
        next.duration = knownDuration;
        next.ready.complete(knownDuration);
      }

      final duration = await next.ready.future.timeout(
        const Duration(seconds: 40),
        onTimeout: () => throw StateError(
          '動画の長さを確認できませんでした。'
          '現在は長さのある動画の再生に対応しています。',
        ),
      );

      if (!_current(generation, token)) return;

      final resume = saved?.resumeFor(duration) ?? Duration.zero;
      next.duration = duration;
      next.position = resume;

      if (resume > Duration.zero) {
        await player.seek(resume).timeout(const Duration(seconds: 15));
      }

      if (!_current(generation, token)) return;

      final previous = _session;
      if (previous != null) {
        await previous.player.pause();
        await _saveQuietly(previous);
      }

      if (!_current(generation, token)) return;

      next.restoring = false;
      setState(() {
        _session = next;
        _siteBrowserTarget = null;
        _rate = playbackRate;
        _index = target;
        _error = null;
      });

      if (identical(_pending, next)) _pending = null;

      // 古いVideoウィジェットの取り外し後にプレーヤーを破棄。
      await WidgetsBinding.instance.endOfFrame;
      if (previous != null) {
        await previous.release();
      }
    } catch (error) {
      if (_current(generation, token)) {
        final message = '「${widget.chapters[target].title}」を開けませんでした。\n$error';
        setState(() => _siteBrowserTarget = target);

        if (_session == null) {
          setState(() => _error = message);
        } else {
          _notice(message);
        }
      }
    } finally {
      final unused = candidate;
      if (unused != null && !identical(_session, unused)) {
        try {
          await unused.release();
        } catch (error) {
          debugPrint('[rule-video] release_failed=$error');
        }
      }

      if (identical(_pending, candidate)) _pending = null;
      if (identical(_cancel, token)) _cancel = null;

      if (mounted && generation == _generation && !_leaving) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _openSitePlayer() async {
    if (_loading || _changingRate || _leaving || _openingSiteBrowser) return;

    final target = _siteBrowserTarget ?? _index;
    final chapter = widget.chapters[target];
    final url = chapter.url;
    if (url == null) return;

    setState(() => _openingSiteBrowser = true);

    try {
      final settings = widget.site.readingSettings?.video;
      if (settings == null) {
        throw const FormatException('動画サイトの設定がありません');
      }

      settings.validateFor(
        widget.site.rules.values.map((rule) => rule.pageUrl),
      );

      final page = siteVideoBrowserUri(url.toString());
      final configured = siteVideoBrowserUri(settings.pageUrl);

      if (page.origin != configured.origin) {
        throw const FormatException('選択した話と動画サイトの取得元が異なります');
      }

      final session = _session;
      if (session != null) {
        await session.player.pause();
        await _saveQuietly(session);
      }

      if (!mounted || _leaving) return;

      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) =>
              SiteVideoBrowserPage(url: page.toString(), title: chapter.title),
        ),
      );

      // 戻ったときに通常プレーヤーを勝手に再生しない。
    } catch (error) {
      _notice('サイトプレーヤーを開けませんでした：$error');
    } finally {
      if (mounted) setState(() => _openingSiteBrowser = false);
    }
  }

  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    _generation++;
    _cancel?.cancel('動画画面を閉じました');

    if (mounted) setState(() {});

    final session = _session;
    if (session != null) {
      try {
        await session.player.pause();
      } catch (error) {
        debugPrint('[rule-video] pause_failed=$error');
      }

      try {
        await _savePosition(session);
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('再生位置を保存できませんでした：$error')));
        }
      }
    }

    if (!mounted) return;
    setState(() => _allowPop = true);
    await WidgetsBinding.instance.endOfFrame;

    if (mounted) Navigator.of(context).pop();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      final session = _session;
      if (session != null) unawaited(_saveQuietly(session));
    }
  }

  Future<void> _shutdown(_VideoSession session) async {
    try {
      await _savePosition(session);
    } catch (error) {
      debugPrint('[rule-video] final_save_failed=$error');
    }

    try {
      await session.release();
    } catch (error) {
      debugPrint('[rule-video] final_release_failed=$error');
    }
  }

  @override
  void dispose() {
    _generation++;
    _saveTimer?.cancel();
    _cancel?.cancel('動画画面終了');
    _client.close();
    WidgetsBinding.instance.removeObserver(this);

    final session = _session;
    final pending = _pending;

    if (session != null) unawaited(_shutdown(session));
    if (pending != null && !identical(pending, session)) {
      unawaited(_shutdown(pending));
    }

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final chapter = widget.chapters[_index];
    final locked = _loading || _changingRate || _leaving || _openingSiteBrowser;
    final siteBrowserUrl = widget.chapters[_siteBrowserTarget ?? _index].url;
    final url = chapter.url;

    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          leading: BackButton(onPressed: _leave),
          title: Text(
            chapter.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            SiteVideoBrowserButton(
              key: const ValueKey('rule-video-site-browser-toolbar'),
              compact: true,
              onPressed: locked || siteBrowserUrl == null
                  ? null
                  : _openSitePlayer,
            ),
            if (url != null)
              VideoDownloadButton(
                site: widget.site,
                workUrl: widget.workUrl ?? url.toString(),
                chapterUrl: url.toString(),
                title: chapter.title,
                workTitle: widget.workTitle ?? chapter.title,
                enabled: !locked,
                onBeforeOpen: () async {
                  if (session != null) {
                    await session.player.pause();
                    await _saveQuietly(session);
                  }
                },
              ),
            VideoSpeedButton(
              rate: _rate,
              enabled: !locked && session != null,
              onChanged: _changeRate,
            ),
            if (url != null)
              RuleLibraryFavoriteButton(
                site: widget.site,
                workUrl: widget.workUrl ?? url.toString(),
                title: widget.workTitle ?? chapter.title,
                thumbnail: widget.workThumbnail,
              ),
            IconButton(
              tooltip: '前の話',
              onPressed: !locked && _index > 0 ? () => _load(_index - 1) : null,
              icon: const Icon(Icons.skip_previous),
            ),
            IconButton(
              tooltip: '次の話',
              onPressed: !locked && _index + 1 < widget.chapters.length
                  ? () => _load(_index + 1)
                  : null,
              icon: const Icon(Icons.skip_next),
            ),
            IconButton(
              tooltip: '現在の話を読み込み直す',
              onPressed: locked ? null : () => _load(_index),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: session == null
            ? Center(
                child: _loading
                    ? const CircularProgressIndicator()
                    : SingleChildScrollView(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _error ?? '動画を開く準備ができました。',
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),
                            FilledButton.icon(
                              onPressed: locked ? null : () => _load(_index),
                              icon: const Icon(Icons.refresh),
                              label: const Text('再試行'),
                            ),
                            const SizedBox(height: 12),
                            SiteVideoBrowserButton(
                              key: const ValueKey(
                                'rule-video-site-browser-error',
                              ),
                              onPressed: locked || siteBrowserUrl == null
                                  ? null
                                  : _openSitePlayer,
                            ),
                          ],
                        ),
                      ),
              )
            : Stack(
                fit: StackFit.expand,
                children: [
                  AbsorbPointer(
                    absorbing: locked,
                    child: Video(
                      key: ObjectKey(session),
                      controller: session.controller,
                    ),
                  ),
                  if (_loading)
                    const Align(
                      alignment: Alignment.topCenter,
                      child: LinearProgressIndicator(),
                    ),
                  if (_error != null)
                    Align(
                      alignment: Alignment.topCenter,
                      child: Material(
                        color: Colors.black87,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            _error!,
                            style: const TextStyle(color: Colors.orangeAccent),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
