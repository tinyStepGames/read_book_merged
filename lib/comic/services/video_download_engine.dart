import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import 'hls_download_plan.dart';

typedef VideoOriginApproval = Future<bool> Function(String origin);

typedef VideoDownloadTransport =
    Future<Response<ResponseBody>> Function(Uri url, CancelToken cancelToken);

void _checkVideoCancel(CancelToken token) {
  if (token.isCancelled) {
    throw StateError('動画の保存を中止しました');
  }
}

bool _looksLikeMp4(List<int> bytes) =>
    bytes.length >= 12 &&
    ascii.decode(bytes.sublist(4, 8), allowInvalid: true) == 'ftyp';

class VideoInspection {
  const VideoInspection({
    required this.url,
    required this.isMp4,
    this.playlist,
  });

  final Uri url;
  final bool isMp4;
  final String? playlist;

  bool get isMaster => !isMp4 && playlist!.contains('#EXT-X-STREAM-INF:');

  List<HlsDownloadChoice> get choices => isMaster
      ? parseHlsChoices(url, playlist!)
      : [HlsDownloadChoice(url: url, label: isMp4 ? 'MP4・元の画質' : 'HLS・配信元の画質')];
}

class VideoDownloadHttp {
  VideoDownloadHttp({
    required Iterable<String> allowedOrigins,
    required this.approveOrigin,
    VideoDownloadTransport? transport,
  }) : _transport = transport,
       _allowed = allowedOrigins
           .map((value) => videoDownloadUri(value).origin)
           .toSet();

  final VideoOriginApproval approveOrigin;
  final VideoDownloadTransport? _transport;
  final Set<String> _allowed;

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 45),
    ),
  );

  Future<({Uri url, Response<ResponseBody> response})> _open(
    Uri input,
    CancelToken token,
  ) async {
    var url = videoDownloadUri(input.toString());

    for (var redirects = 0; redirects <= 5; redirects++) {
      _checkVideoCancel(token);

      if (!_allowed.contains(url.origin)) {
        final approved = await approveOrigin(url.origin);
        _checkVideoCancel(token);

        if (!approved) {
          throw StateError('配信元への通信が許可されませんでした：${url.origin}');
        }

        _allowed.add(url.origin);
      }

      final transport = _transport;
      final response = transport == null
          ? await _dio.getUri<ResponseBody>(
              url,
              options: Options(
                responseType: ResponseType.stream,
                followRedirects: false,
                validateStatus: (_) => true,
                headers: const {'Accept-Encoding': 'identity'},
              ),
              cancelToken: token,
            )
          : await transport(url, token);

      final status = response.statusCode ?? 0;

      if (const [301, 302, 303, 307, 308].contains(status)) {
        await response.data?.stream.listen((_) {}).cancel();

        final location = response.headers.value('location');
        if (location == null || redirects == 5) {
          throw StateError('転送先が不明、または転送回数が多すぎます');
        }

        // 転送後もHTTPS・認証情報・配信元の確認を行う。
        url = videoDownloadUri(url.resolve(location).toString());
        continue;
      }

      if (status != 200 && status != 206) {
        await response.data?.stream.listen((_) {}).cancel();
        throw StateError(
          '動画の取得に失敗しました：HTTP $status。'
          'アクセス条件は回避せず停止しました。',
        );
      }

      if (response.data == null) {
        throw StateError('配信元からデータが返りませんでした');
      }

      return (url: url, response: response);
    }

    throw StateError('転送を完了できませんでした');
  }

  Future<VideoInspection> inspect(Uri url, CancelToken token) async {
    final opened = await _open(url, token);
    final bytes = BytesBuilder(copy: false);

    await for (final chunk in opened.response.data!.stream) {
      _checkVideoCancel(token);

      // MP4の場合、ヘッダーを確認した段階でストリームを閉じる。
      if (bytes.length < 12) {
        bytes.add(chunk);

        if (bytes.length >= 12 && _looksLikeMp4(bytes.toBytes())) {
          return VideoInspection(url: opened.url, isMp4: true);
        }
      } else {
        bytes.add(chunk);
      }

      if (bytes.length > 2 * 1024 * 1024) {
        throw const FormatException('プレイリストが2MiBを超えています');
      }
    }

    _checkVideoCancel(token);

    final text = utf8.decode(bytes.takeBytes());
    if (!text.trimLeft().replaceFirst('\uFEFF', '').startsWith('#EXTM3U')) {
      throw const FormatException('MP4・対応HLS以外の応答です');
    }

    return VideoInspection(url: opened.url, isMp4: false, playlist: text);
  }

  Future<int> saveBinary({
    required Uri url,
    required File file,
    required bool mp4,
    required int maximumBytes,
    required CancelToken token,
    required void Function(int bytes) onProgress,
  }) async {
    final opened = await _open(url, token);
    final response = opened.response;
    final encoding = response.headers.value('content-encoding');

    if (encoding != null &&
        encoding.isNotEmpty &&
        encoding.toLowerCase() != 'identity') {
      await response.data!.stream.listen((_) {}).cancel();
      throw const FormatException('圧縮転送された動画の保存は現在対象外です');
    }

    final declared = int.tryParse(
      response.headers.value('content-length') ?? '',
    );

    if (declared != null && (declared <= 0 || declared > maximumBytes)) {
      await response.data!.stream.listen((_) {}).cancel();
      throw const FormatException('動画の応答サイズが不正、または上限超過です');
    }

    var count = 0;
    var flushedAt = 0;
    final prefix = <int>[];
    final sink = file.openWrite();

    try {
      await for (final chunk in response.data!.stream) {
        _checkVideoCancel(token);

        count += chunk.length;
        if (count > maximumBytes) {
          throw const FormatException('動画の保存サイズが上限を超えました');
        }

        if (prefix.length < 376) {
          prefix.addAll(chunk.take(376 - prefix.length));
        }

        sink.add(chunk);
        onProgress(count);

        // ディスクが遅い場合にメモリへ溜め続けない。
        if (count - flushedAt >= 4 * 1024 * 1024) {
          await sink.flush();
          flushedAt = count;
        }
      }

      _checkVideoCancel(token);
      await sink.flush();
    } finally {
      await sink.close();
    }

    if (count == 0 || (declared != null && count != declared)) {
      throw const FormatException('動画の取得が途中で終了しました');
    }

    if (mp4) {
      if (!_looksLikeMp4(prefix)) {
        throw const FormatException('MP4ではない応答を受け取りました');
      }
    } else if (count < 188 ||
        prefix.isEmpty ||
        prefix.first != 0x47 ||
        (prefix.length > 188 && prefix[188] != 0x47)) {
      throw const FormatException(
        '対応するMPEG-TSデータではありません。'
        'HTMLエラーや未対応形式の可能性があります。',
      );
    }

    return count;
  }

  void close() => _dio.close(force: true);
}

class SavedVideoPackage {
  const SavedVideoPackage({
    required this.id,
    required this.title,
    required this.entry,
    required this.files,
    required this.metadata,
  });

  final String id;
  final String title;
  final String entry;
  final Map<String, Map<String, dynamic>> files;
  final Map<String, dynamic> metadata;
}

class VideoDownloadRepository {
  VideoDownloadRepository(Directory comicRoot)
    : root = Directory(p.join(comicRoot.path, '_video_downloads_v1'));

  final Directory root;

  static String idFor(String identity) =>
      sha256.convert(utf8.encode('video-v1:$identity')).toString();

  static bool _validId(String value) =>
      RegExp(r'^[a-f0-9]{64}$').hasMatch(value);

  static bool _validName(String value) =>
      value == 'video.mp4' ||
      value == 'main.m3u8' ||
      RegExp(r'^s[0-9]{5}\.ts$').hasMatch(value);

  Future<void> _ensureRoot() async {
    final type = await FileSystemEntity.type(root.path, followLinks: false);

    if (type == FileSystemEntityType.notFound) {
      await root.create(recursive: true);
    } else if (type != FileSystemEntityType.directory) {
      throw const FormatException('動画保存先が通常のフォルダーではありません');
    }
  }

  Directory directory(String id) {
    if (!_validId(id)) {
      throw const FormatException('動画の保存IDが不正です');
    }
    return Directory(p.join(root.path, id));
  }

  Future<SavedVideoPackage?> load(
    String id, {
    bool verifyHashes = false,
  }) async {
    await _ensureRoot();
    final folder = directory(id);
    final type = await FileSystemEntity.type(folder.path, followLinks: false);

    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.directory) {
      throw const FormatException('動画保存フォルダーが不正です');
    }

    final manifest = File(p.join(folder.path, 'complete.json'));
    if (await FileSystemEntity.type(manifest.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FormatException('動画の保存完了情報がありません');
    }

    if (await manifest.length() > 4 * 1024 * 1024) {
      throw const FormatException('動画の保存完了情報が大きすぎます');
    }

    final data = jsonDecode(await manifest.readAsString());
    if (data is! Map ||
        data['version'] != 1 ||
        data['id'] != id ||
        data['title'] is! String ||
        data['entry'] is! String ||
        data['files'] is! Map ||
        data['metadata'] is! Map) {
      throw const FormatException('動画の保存完了情報が不正です');
    }

    final entry = data['entry'] as String;
    if (entry != 'video.mp4' && entry != 'main.m3u8') {
      throw const FormatException('動画の再生ファイル名が不正です');
    }

    final rawFiles = data['files'] as Map;
    if (rawFiles.isEmpty || rawFiles.length > 10001) {
      throw const FormatException('動画の保存ファイル数が不正です');
    }

    final files = <String, Map<String, dynamic>>{};

    for (final item in rawFiles.entries) {
      final name = item.key;
      final value = item.value;

      if (name is! String || !_validName(name) || value is! Map) {
        throw const FormatException('動画の保存ファイル情報が不正です');
      }

      final size = value['bytes'];
      final hash = value['sha256'];

      if (size is! int ||
          size <= 0 ||
          hash is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
        throw const FormatException('動画のサイズ・ハッシュ情報が不正です');
      }

      final file = File(p.join(folder.path, name));
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await file.length() != size) {
        throw const FormatException('動画の保存ファイルが不足・破損しています');
      }

      if (verifyHashes) {
        final actual = await sha256.bind(file.openRead()).first;
        if (actual.toString() != hash) {
          throw const FormatException('動画の保存ファイルのハッシュが一致しません');
        }
      }

      files[name] = Map<String, dynamic>.from(value);
    }

    if (!files.containsKey(entry)) {
      throw const FormatException('動画の再生ファイルがありません');
    }

    if (entry == 'video.mp4') {
      if (files.length != 1) {
        throw const FormatException('MP4の保存ファイル構成が不正です');
      }
    } else {
      final playlistFile = File(p.join(folder.path, entry));

      if (await playlistFile.length() > 2 * 1024 * 1024) {
        throw const FormatException('保存プレイリストが大きすぎます');
      }

      final segmentNames = files.keys
          .where((name) => name != 'main.m3u8')
          .toSet();

      validateLocalHls(await playlistFile.readAsString(), segmentNames);
    }

    return SavedVideoPackage(
      id: id,
      title: data['title'] as String,
      entry: entry,
      files: files,
      metadata: Map<String, dynamic>.from(data['metadata'] as Map),
    );
  }

  Future<({List<SavedVideoPackage> videos, List<String> issues})> scan() async {
    await _ensureRoot();
    final videos = <SavedVideoPackage>[];
    final issues = <String>[];

    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;

      final id = p.basename(entity.path);
      if (!_validId(id)) continue;

      try {
        final video = await load(id);
        if (video != null) videos.add(video);
      } catch (error) {
        issues.add('$id：$error');
      }
    }

    videos.sort((a, b) => a.title.compareTo(b.title));
    return (
      videos: List<SavedVideoPackage>.unmodifiable(videos),
      issues: List<String>.unmodifiable(issues),
    );
  }

  Future<void> delete(String id) async {
    await _ensureRoot();
    final folder = directory(id);
    final type = await FileSystemEntity.type(folder.path, followLinks: false);

    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.directory) {
      throw const FormatException('削除対象の動画フォルダーが不正です');
    }

    await folder.delete(recursive: true);
  }
}

class VideoDownloadEngine {
  VideoDownloadEngine(this.repository);

  final VideoDownloadRepository repository;
  bool _busy = false;

  bool get busy => _busy;

  static const maximumTotalBytes = 20 * 1024 * 1024 * 1024;
  static const maximumSegmentBytes = 256 * 1024 * 1024;

  Future<SavedVideoPackage> save({
    required String identity,
    required String title,
    required Map<String, dynamic> metadata,
    required VideoDownloadHttp http,
    required VideoInspection inspection,
    required HlsDownloadChoice choice,
    required CancelToken cancelToken,
    required void Function(int done, int total, int bytes) onProgress,
  }) async {
    if (_busy) throw StateError('別の動画を保存中です');
    _busy = true;

    Directory? temporary;

    try {
      _checkVideoCancel(cancelToken);
      final id = VideoDownloadRepository.idFor(identity);
      final existing = await repository.load(id, verifyHashes: true);

      if (existing != null) return existing;

      VideoInspection selected = inspection;

      if (inspection.isMaster) {
        if (!inspection.choices.any((item) => item.url == choice.url)) {
          throw const FormatException('選択した画質が候補にありません');
        }

        selected = await http.inspect(choice.url, cancelToken);
        if (selected.isMp4 || selected.isMaster) {
          throw const FormatException('入れ子の画質一覧・異なる配信形式は対象外です');
        }
      } else if (choice.url != inspection.url) {
        throw const FormatException('選択した動画URLが一致しません');
      }

      HlsDownloadPlan? plan;
      if (!selected.isMp4) {
        plan = parseHlsMedia(selected.url, selected.playlist!);
      }

      _checkVideoCancel(cancelToken);
      await repository._ensureRoot();

      temporary = Directory(
        p.join(
          repository.root.path,
          '_part_${id}_${DateTime.now().microsecondsSinceEpoch}',
        ),
      );
      await temporary.create();

      final hashes = <String, Map<String, dynamic>>{};
      var bytes = 0;

      Future<void> rememberFile(String name) async {
        final file = File(p.join(temporary!.path, name));
        final hash = await sha256.bind(file.openRead()).first;
        hashes[name] = {
          'bytes': await file.length(),
          'sha256': hash.toString(),
        };
      }

      if (selected.isMp4) {
        final file = File(p.join(temporary.path, 'video.mp4'));

        bytes = await http.saveBinary(
          url: selected.url,
          file: file,
          mp4: true,
          maximumBytes: maximumTotalBytes,
          token: cancelToken,
          onProgress: (current) => onProgress(0, 1, current),
        );

        await rememberFile('video.mp4');
        onProgress(1, 1, bytes);
      } else {
        final media = plan!;

        for (var index = 0; index < media.segments.length; index++) {
          _checkVideoCancel(cancelToken);

          final before = bytes;
          final remaining = maximumTotalBytes - before;
          if (remaining <= 0) {
            throw const FormatException('動画全体が20GiBを超えています');
          }

          final name = media.localName(index);
          final count = await http.saveBinary(
            url: media.segments[index].url,
            file: File(p.join(temporary.path, name)),
            mp4: false,
            maximumBytes: remaining < maximumSegmentBytes
                ? remaining
                : maximumSegmentBytes,
            token: cancelToken,
            onProgress: (current) =>
                onProgress(index, media.segments.length, before + current),
          );

          bytes += count;
          await rememberFile(name);
          onProgress(index + 1, media.segments.length, bytes);
        }

        final playlist = media.localPlaylist();
        validateLocalHls(playlist, hashes.keys.toSet());

        await File(
          p.join(temporary.path, 'main.m3u8'),
        ).writeAsString(playlist, flush: true);
        await rememberFile('main.m3u8');
      }

      _checkVideoCancel(cancelToken);

      final manifest = {
        'version': 1,
        'id': id,
        'title': title,
        'entry': selected.isMp4 ? 'video.mp4' : 'main.m3u8',
        'quality': choice.label,
        'savedAt': DateTime.now().toUtc().toIso8601String(),
        'files': hashes,
        'metadata': metadata,
      };

      final encoded = jsonEncode(manifest);
      if (utf8.encode(encoded).length > 4 * 1024 * 1024) {
        throw const FormatException('動画の保存完了情報が大きすぎます');
      }

      // 完了情報は必要なファイルの取得・確認が終わってから書く。
      await File(
        p.join(temporary.path, 'complete.json'),
      ).writeAsString(encoded, flush: true);

      _checkVideoCancel(cancelToken);

      final destination = repository.directory(id);
      if (await FileSystemEntity.type(destination.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError('同じ動画の保存先が既にあります。上書きせず停止しました');
      }

      await temporary.rename(destination.path);
      temporary = null;

      final saved = await repository.load(id, verifyHashes: true);
      if (saved == null) {
        throw StateError('保存後の動画を確認できませんでした');
      }

      return saved;
    } finally {
      final incomplete = temporary;
      try {
        if (incomplete != null && await incomplete.exists()) {
          await incomplete.delete(recursive: true);
        }
      } finally {
        _busy = false;
      }
    }
  }
}
