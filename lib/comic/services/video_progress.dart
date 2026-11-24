import 'download_store.dart';
import 'rule_downloads.dart';

String ruleVideoProgressKey({
  required String siteId,
  required String chapterUrl,
}) {
  final chapter = ruleSavedChapter(
    siteId: siteId,
    workUrl: chapterUrl,
    chapterUrl: chapterUrl,
    title: '',
  );

  return 'rule-video-progress-v1:${chapter.storageId}';
}

class VideoPosition {
  const VideoPosition({required this.position, required this.duration});

  final Duration position;
  final Duration duration;

  Duration resumeFor(Duration currentDuration) {
    if (currentDuration <= Duration.zero) return Duration.zero;

    return Duration(
      milliseconds: position.inMilliseconds
          .clamp(0, currentDuration.inMilliseconds)
          .toInt(),
    );
  }

  Map<String, dynamic> toJson() {
    if (position.isNegative || duration.isNegative) {
      throw const FormatException('動画の再生位置が不正です');
    }

    return {
      'version': 1,
      'positionMs': duration > Duration.zero
          ? position.inMilliseconds.clamp(0, duration.inMilliseconds).toInt()
          : position.inMilliseconds,
      'durationMs': duration.inMilliseconds,
    };
  }

  static VideoPosition? decode(Object? raw) {
    if (raw is! Map ||
        raw['version'] != 1 ||
        raw['positionMs'] is! int ||
        raw['durationMs'] is! int) {
      return null;
    }

    final position = raw['positionMs'] as int;
    final duration = raw['durationMs'] as int;

    // JSONの整数として正確に扱える範囲に限定。
    const maximum = 9007199254740991;

    if (position < 0 ||
        duration < 0 ||
        position > maximum ||
        duration > maximum) {
      return null;
    }

    return VideoPosition(
      position: Duration(milliseconds: position),
      duration: Duration(milliseconds: duration),
    );
  }
}

class VideoProgressStore {
  VideoProgressStore(this.store);

  final DownloadStore store;
  Future<void> _tail = Future<void>.value();

  Future<VideoPosition?> read(String key) async {
    await _tail;
    return VideoPosition.decode(await store.readCache(key));
  }

  Future<void> save(String key, VideoPosition value) {
    final data = value.toJson();

    // 同じストア内では書き込み順を維持する。
    final task = _tail.then<void>((_) => store.writeCache(key, data));

    // 1回の失敗で後続の保存キューを壊さない。
    // 失敗自体は、返すtaskを通して呼び出し元へ通知。
    _tail = task.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );

    return task;
  }
}
