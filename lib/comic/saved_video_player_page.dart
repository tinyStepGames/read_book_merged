import 'services/local_hls_playback.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

import 'services/download_store.dart';
import 'services/saved_video_record.dart';
import 'services/video_download_engine.dart';
import 'services/video_playback_speed.dart';
import 'services/video_progress.dart';
import 'video_speed_button.dart';

class SavedVideoPlayerPage extends StatefulWidget {
  const SavedVideoPlayerPage({
    super.key,
    required this.store,
    required this.videoId,
  });

  final DownloadStore store;
  final String videoId;

  @override
  State<SavedVideoPlayerPage> createState() => _SavedVideoPlayerPageState();
}

class _SavedVideoPlayerPageState extends State<SavedVideoPlayerPage>
    with WidgetsBindingObserver {
  Player? _player;
  VideoController? _controller;
  VideoProgressStore? _progress;
  SavedVideoRecord? _record;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  final _durationReady = Completer<Duration>();

  Future<void>? _releaseFuture;
  Directory? _runtimeDirectory;
  Future<void>? _lastWrite;
  Timer? _timer;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _restoring = true;
  bool _hasPlayed = false;
  bool _dirty = false;
  bool _loading = true;
  bool _changingRate = false;
  bool _closing = false;
  bool _allowPop = false;
  bool _warningShown = false;
  String? _error;
  double _rate = VideoPlaybackSpeed.rate;

  @override
  void initState() {
    super.initState();
    _durationReady.future.ignore();
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_saveQuietly());
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  bool get _alive => mounted && !_closing;

  void _listen(Player player) {
    _subscriptions.add(
      player.stream.duration.listen((value) {
        if (value <= Duration.zero) return;
        _duration = value;
        if (!_durationReady.isCompleted) _durationReady.complete(value);
      }),
    );

    _subscriptions.add(
      player.stream.position.listen((value) {
        if (_restoring || _closing) return;

        if (player.state.playing && value > Duration.zero) {
          _hasPlayed = true;
        }
        if (!_hasPlayed) return;
        if (player.state.completed && value == Duration.zero) return;

        _position = value;
        _dirty = true;
      }),
    );

    _subscriptions.add(
      player.stream.playing.listen((playing) {
        if (!playing && !_restoring) unawaited(_saveQuietly());
      }),
    );

    _subscriptions.add(
      player.stream.completed.listen((completed) {
        if (!completed || !_hasPlayed || _restoring) return;
        if (_duration > Duration.zero) {
          _position = _duration;
          _dirty = true;
          unawaited(_saveQuietly());
        }
      }),
    );

    _subscriptions.add(
      player.stream.error.listen((message) {
        if (!_durationReady.isCompleted) {
          _durationReady.completeError(StateError(message));
        }
        if (_alive) setState(() => _error = '保存動画を再生できませんでした：$message');
      }),
    );
  }

  Future<void> _load() async {
    try {
      final repository = VideoDownloadRepository(widget.store.root);

      // 毎回、サイズ・SHA-256・ローカルHLS参照を確認してから開く。
      final video = await repository.load(widget.videoId, verifyHashes: true);
      if (!_alive) return;
      if (video == null) throw const FormatException('保存動画が見つかりません');

      final record = SavedVideoRecord.forPackage(video);
      final progress = VideoProgressStore(widget.store);
      final saved = await progress.read(record.progressKey);
      if (!_alive) return;

      _record = record;
      _progress = progress;

      MediaKit.ensureInitialized();
      final player = Player();
      _player = player;
      final controller = VideoController(player);
      _controller = controller;
      _listen(player);

      final platform = player.platform;
      if (platform is! NativePlayer) {
        throw UnsupportedError('保存動画の再生は現在Windows等のネイティブ環境向けです');
      }

      // このプレーヤーは検証済みのローカルファイルだけを開く。
      await platform.setProperty('demuxer-lavf-o', 'protocol_whitelist=[file]');
      if (!_alive) return;

      var entry = File(
        p.join(repository.directory(video.id).path, video.entry),
      );

      if (video.entry == 'main.m3u8') {
        final playlist = await entry.readAsString();
        if (!_alive) return;

        final localPlaylist = localHlsPlaybackPlaylist(
          playlist: playlist,
          directory: repository.directory(video.id),
          segments: video.files.keys
              .where((name) => name != 'main.m3u8')
              .toSet(),
        );

        final runtime = await Directory.systemTemp.createTemp(
          'offline-reader-hls-playback-',
        );
        _runtimeDirectory = runtime;

        // 画面終了と一時フォルダー作成が競合した場合も残さない。
        if (!_alive) {
          if (await runtime.exists()) {
            await runtime.delete(recursive: true);
          }
          _runtimeDirectory = null;
          return;
        }

        entry = File(p.join(runtime.path, 'main.m3u8'));
        await entry.writeAsString(localPlaylist, flush: true);
        if (!_alive) return;

        // HLSとして開く。個別TSのプレイリスト再生には退避しない。
        await platform.setProperty('demuxer', 'lavf');
        if (!_alive) return;
        await platform.setProperty('demuxer-lavf-format', 'hls');
        if (!_alive) return;
      }

      await player
          .open(Media(entry.uri.toString()), play: false)
          .timeout(const Duration(seconds: 40));
      if (!_alive) return;

      final rate = VideoPlaybackSpeed.rate;
      await player.setRate(rate).timeout(const Duration(seconds: 10));
      if (!_alive) return;

      if (player.state.duration > Duration.zero &&
          !_durationReady.isCompleted) {
        _durationReady.complete(player.state.duration);
      }

      final duration = await _durationReady.future.timeout(
        const Duration(seconds: 40),
      );
      if (!_alive) return;

      _duration = duration;
      _position = saved?.resumeFor(duration) ?? Duration.zero;

      if (_position > Duration.zero) {
        await player.seek(_position).timeout(const Duration(seconds: 15));
      }
      if (!_alive) return;

      _restoring = false;
      setState(() {
        _rate = rate;
        _loading = false;
      });
    } catch (error) {
      if (_alive) {
        setState(() {
          _loading = false;
          _error = '保存動画を開けませんでした：$error';
        });
      }
    }
  }

  Future<void> _save() async {
    final progress = _progress;
    final record = _record;

    if (!_dirty ||
        !_hasPlayed ||
        _restoring ||
        progress == null ||
        record == null) {
      final pending = _lastWrite;
      if (pending != null) await pending;
      return;
    }

    final value = VideoPosition(position: _position, duration: _duration);
    _dirty = false;
    final task = progress.save(record.progressKey, value);
    _lastWrite = task;

    try {
      await task;
    } catch (_) {
      _dirty = true;
      rethrow;
    }
  }

  Future<void> _saveQuietly() async {
    try {
      await _save();
    } catch (error) {
      if (_alive && !_warningShown) {
        _warningShown = true;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('再生位置を保存できませんでした：$error')));
      }
    }
  }

  Future<void> _changeRate(double value) async {
    VideoPlaybackSpeed.validate(value);
    final player = _player;
    if (player == null || _loading || _closing || _changingRate) {
      throw StateError('現在は速度を変更できません');
    }

    setState(() => _changingRate = true);
    try {
      await player.setRate(value).timeout(const Duration(seconds: 10));
      if (!_alive) return;
      VideoPlaybackSpeed.remember(value);
      setState(() => _rate = value);
    } finally {
      if (mounted) setState(() => _changingRate = false);
    }
  }

  Future<void> _leave() async {
    if (_closing) return;
    _closing = true;
    _timer?.cancel();
    if (mounted) setState(() {});

    try {
      await _player?.pause();
      await _save();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('再生位置の保存時に問題が発生しました：$error')));
      }
    }

    if (!mounted) return;
    setState(() => _allowPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _release() => _releaseFuture ??= _releaseOnce();

  Future<void> _releaseOnce() async {
    if (!_durationReady.isCompleted) {
      _durationReady.completeError(StateError('保存動画を閉じました'));
    }

    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    try {
      await _player?.dispose();
    } finally {
      final runtime = _runtimeDirectory;
      _runtimeDirectory = null;
      if (runtime != null && await runtime.exists()) {
        await runtime.delete(recursive: true);
      }
    }
  }

  Future<void> _shutdown() async {
    try {
      await _save();
    } catch (error) {
      debugPrint('[saved-video] save_failed=$error');
    } finally {
      try {
        await _release();
      } catch (error) {
        debugPrint('[saved-video] release_failed=$error');
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) unawaited(_saveQuietly());
  }

  @override
  void dispose() {
    _closing = true;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_shutdown());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final locked = _loading || _closing || _changingRate;

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
            _record?.chapter.title ?? '保存動画を確認中',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            VideoSpeedButton(
              rate: _rate,
              enabled: !locked && _error == null,
              onChanged: _changeRate,
            ),
          ],
        ),
        body: _loading
            ? const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('端末内の動画ファイルを確認しています…'),
                  ],
                ),
              )
            : _error != null
            ? Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: SelectableText(_error!),
                ),
              )
            : controller == null
            ? const Center(child: Text('再生用ファイルがありません'))
            : AbsorbPointer(
                absorbing: locked,
                child: Video(controller: controller),
              ),
      ),
    );
  }
}
