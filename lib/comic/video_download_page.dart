import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import 'saved_video_player_page.dart';
import 'services/download_store.dart';
import 'services/hls_download_plan.dart';
import 'services/rule_downloads.dart';
import 'services/saved_video_record.dart';
import 'services/site_rule_store.dart';
import 'services/video_download_engine.dart';
import 'services/video_source.dart';

class VideoDownloadButton extends StatelessWidget {
  const VideoDownloadButton({
    super.key,
    required this.site,
    required this.workUrl,
    required this.chapterUrl,
    required this.title,
    required this.workTitle,
    this.enabled = true,
    this.onBeforeOpen,
  });

  final SavedSiteRule site;
  final String workUrl;
  final String chapterUrl;
  final String title;
  final String workTitle;
  final bool enabled;
  final Future<void> Function()? onBeforeOpen;

  Future<void> _open(BuildContext context) async {
    try {
      if (VideoDownloadPage.isActive) {
        throw StateError('別の動画保存画面が開いています');
      }

      await onBeforeOpen?.call();
      if (!context.mounted) return;

      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => VideoDownloadPage(
            site: site,
            workUrl: workUrl,
            chapterUrl: chapterUrl,
            title: title,
            workTitle: workTitle,
          ),
        ),
      );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('動画保存を開けませんでした：$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'この話の動画を保存',
    onPressed: enabled ? () => _open(context) : null,
    icon: const Icon(Icons.download_outlined),
  );
}

class VideoDownloadPage extends StatefulWidget {
  const VideoDownloadPage({
    super.key,
    required this.site,
    required this.workUrl,
    required this.chapterUrl,
    required this.title,
    required this.workTitle,
  });

  final SavedSiteRule site;
  final String workUrl;
  final String chapterUrl;
  final String title;
  final String workTitle;

  static bool _active = false;
  static bool get isActive => _active;

  @override
  State<VideoDownloadPage> createState() => _VideoDownloadPageState();
}

class _VideoDownloadPageState extends State<VideoDownloadPage> {
  final _client = VideoSourceClient();

  VideoDownloadHttp? _http;
  VideoDownloadRepository? _repository;
  DownloadStore? _store;
  SavedVideoRecord? _record;
  VideoInspection? _inspection;
  List<HlsDownloadChoice> _choices = [];
  HlsDownloadChoice? _choice;
  SavedVideoPackage? _saved;
  CancelToken? _token;
  Future<void>? _task;

  bool _ownsLease = false;
  bool _busy = false;
  String _status = '取得準備中';
  int _done = 0;
  int _total = 0;
  int _bytes = 0;
  DateTime _lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();

    if (VideoDownloadPage._active) {
      _status = '別の動画保存画面が開いています。戻ってからお試しください。';
      return;
    }

    VideoDownloadPage._active = true;
    _ownsLease = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _startPrepare();
    });
  }

  void _startPrepare() {
    if (!_ownsLease || _busy) return;
    _task = _prepare();
  }

  Future<bool> _approve(String origin) async {
    if (!mounted || _token?.isCancelled == true) return false;

    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            title: const Text('追加の配信元への通信'),
            content: SelectableText(
              '動画の取得先として次の配信元が指定されました。\n\n'
              '$origin\n\n'
              'この保存画面を開いている間だけ通信を許可しますか？',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('許可しない'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('許可する'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _prepare() async {
    final token = CancelToken();
    _token = token;

    setState(() {
      _busy = true;
      _status = '保存済みデータと動画URLを確認中';
      _inspection = null;
      _choices = [];
      _choice = null;
      _saved = null;
      _done = 0;
      _total = 0;
      _bytes = 0;
    });

    try {
      final settings = widget.site.readingSettings?.video;
      if (settings == null) {
        throw const FormatException('動画設定がありません');
      }
      settings.validateFor(
        widget.site.rules.values.map((rule) => rule.pageUrl),
      );

      final record = SavedVideoRecord.create(
        siteId: widget.site.id,
        siteName: widget.site.name,
        workUrl: widget.workUrl,
        chapterUrl: widget.chapterUrl,
        title: widget.title,
        workTitle: widget.workTitle,
      );

      final downloads = await RuleDownloads.open();
      if (!mounted || token.isCancelled) return;

      final repository = VideoDownloadRepository(downloads.store.root);
      _record = record;
      _repository = repository;
      _store = downloads.store;

      final existing = await repository.load(record.id, verifyHashes: true);
      if (!mounted || token.isCancelled) return;

      if (existing != null) {
        SavedVideoRecord.forPackage(existing);
        setState(() {
          _saved = existing;
          _status = 'この話は保存済みです。再ダウンロードは行いません。';
        });
        return;
      }

      final result = await _client.load(
        settings: settings,
        targetUrl: widget.chapterUrl,
        cancelToken: token,
      );
      if (!mounted || token.isCancelled) return;

      if (!result.hasSingleUrl) {
        throw FormatException(
          '動画URLを1件に決定できませんでした。\n${result.issues.join('\n')}',
        );
      }

      _http?.close();
      final http = VideoDownloadHttp(
        allowedOrigins: settings.allowedOrigins,
        approveOrigin: _approve,
      );
      _http = http;

      final inspection = await http.inspect(result.urls.single, token);
      final choices = inspection.choices;

      if (!mounted || token.isCancelled) return;

      setState(() {
        _inspection = inspection;
        _choices = choices;
        _choice = choices.first;
        _status = '画質を確認して「保存を開始」を押してください。';
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = token.isCancelled
              ? '取得をキャンセルしました。'
              : '保存の準備ができませんでした：$error';
        });
      }
    } finally {
      if (identical(_token, token)) _token = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  void _startSave() {
    if (!_ownsLease || _busy) return;
    _task = _save();
  }

  Future<void> _save() async {
    final record = _record;
    final repository = _repository;
    final http = _http;
    final inspection = _inspection;
    final choice = _choice;

    if (record == null ||
        repository == null ||
        http == null ||
        inspection == null ||
        choice == null) {
      return;
    }

    final token = CancelToken();
    _token = token;

    setState(() {
      _busy = true;
      _status = '動画を保存中';
      _done = 0;
      _total = 0;
      _bytes = 0;
    });

    try {
      final saved = await VideoDownloadEngine(repository).save(
        identity: record.identity,
        title: record.chapter.title,
        metadata: record.toJson(),
        http: http,
        inspection: inspection,
        choice: choice,
        cancelToken: token,
        onProgress: (done, total, bytes) {
          if (!mounted) return;

          final now = DateTime.now();
          if (done != total &&
              now.difference(_lastUpdate).inMilliseconds < 150) {
            return;
          }
          _lastUpdate = now;

          setState(() {
            _done = done;
            _total = total;
            _bytes = bytes;
            _status = done == total ? 'ファイルを確認して保存完了情報を作成中' : '動画を保存中';
          });
        },
      );

      SavedVideoRecord.forPackage(saved);

      if (mounted) {
        setState(() {
          _saved = saved;
          _bytes = savedVideoBytes(saved);
          _status = '保存が完了しました。ネット接続なしで再生できます。';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = token.isCancelled
              ? '保存をキャンセルしました。未完了の一時ファイルは削除しました。'
              : '保存できませんでした：$error';
        });
      }
    } finally {
      if (identical(_token, token)) _token = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  void _cancel() {
    _token?.cancel('ユーザーによるキャンセル');
    setState(() => _status = 'キャンセル処理中です…');
  }

  @override
  void dispose() {
    _token?.cancel('保存画面を閉じました');
    _http?.close();
    _client.close();

    if (_ownsLease) {
      final task = _task;
      if (task == null) {
        VideoDownloadPage._active = false;
      } else {
        task.whenComplete(() {
          VideoDownloadPage._active = false;
        }).ignore();
      }
    }

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final saved = _saved;
    final store = _store;

    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('動画を保存'),
          automaticallyImplyLeading: !_busy,
        ),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              widget.workTitle,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(widget.title),
            const SizedBox(height: 8),
            Text(
              widget.site.name,
              style: const TextStyle(color: Colors.white60),
            ),
            const SizedBox(height: 24),
            if (_choices.isNotEmpty && saved == null) ...[
              const Text('保存する画質'),
              DropdownButton<HlsDownloadChoice>(
                isExpanded: true,
                value: _choice,
                items: [
                  for (final choice in _choices)
                    DropdownMenuItem(
                      value: choice,
                      child: Text(
                        choice.label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _busy
                    ? null
                    : (choice) => setState(() => _choice = choice),
              ),
              const SizedBox(height: 16),
            ],
            SelectableText(_status),
            if (_busy) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(
                value: _total > 1 ? _done / _total : null,
              ),
            ],
            if (_bytes > 0 || _total > 0) ...[
              const SizedBox(height: 10),
              Text(
                '${savedVideoSize(_bytes)}'
                '${_total > 1 ? '・$_done / $_total 分割' : ''}',
              ),
            ],
            const SizedBox(height: 20),
            if (_busy)
              OutlinedButton.icon(
                onPressed: _cancel,
                icon: const Icon(Icons.close),
                label: const Text('キャンセル'),
              )
            else if (saved != null && store != null)
              FilledButton.icon(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        SavedVideoPlayerPage(store: store, videoId: saved.id),
                  ),
                ),
                icon: const Icon(Icons.play_arrow),
                label: const Text('保存した動画を再生'),
              )
            else if (_inspection != null)
              FilledButton.icon(
                onPressed: _startSave,
                icon: const Icon(Icons.download),
                label: const Text('保存を開始'),
              )
            else if (_ownsLease)
              FilledButton.icon(
                onPressed: _startPrepare,
                icon: const Icon(Icons.refresh),
                label: const Text('もう一度確認'),
              ),
            const SizedBox(height: 20),
            const Text(
              '保存する権利・許可のある動画に使用してください。\n'
              'MP4、または対応する非暗号化HLSを保存します。\n'
              '保存中はこの画面でお待ちください。中断再開・一括保存は未対応です。\n'
              '保存済みの話は再利用します。画質変更は保存済み動画を削除してから行ってください。',
              style: TextStyle(fontSize: 12, color: Colors.white60),
            ),
          ],
        ),
      ),
    );
  }
}
