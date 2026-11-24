import 'dart:math' as math;

import 'html_probe.dart';

Uri videoDownloadUri(String value) {
  final uri = htmlProbeUri(value);
  final host = uri.host.toLowerCase();

  if (host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local')) {
    throw const FormatException('ローカルホストは動画の配信元に指定できません');
  }

  return uri;
}

Map<String, String> hlsAttributes(String input) {
  final result = <String, String>{};
  final pattern = RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)');
  var end = 0;

  for (final match in pattern.allMatches(input)) {
    final gap = input.substring(end, match.start);
    if ((end == 0 && gap.trim().isNotEmpty) ||
        (end != 0 && gap.trim() != ',')) {
      throw const FormatException('HLSの属性リストが不正です');
    }

    final name = match.group(1)!;
    var value = match.group(2)!;
    if (value.startsWith('"')) {
      value = value.substring(1, value.length - 1);
    }

    if (result.containsKey(name)) {
      throw const FormatException('HLSの属性が重複しています');
    }

    result[name] = value;
    end = match.end;
  }

  if (end == 0 || input.substring(end).trim().isNotEmpty) {
    throw const FormatException('HLSの属性リストを読み取れません');
  }

  return result;
}

List<String> _hlsLines(String text) {
  final lines = text
      .replaceFirst(RegExp(r'^\uFEFF'), '')
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList();

  if (lines.isEmpty || lines.first != '#EXTM3U' || lines.length > 40000) {
    throw const FormatException('対応するHLSプレイリストではありません');
  }

  if (text.contains(r'{$')) {
    throw const FormatException('変数を使用するHLSにはまだ対応していません');
  }

  return lines;
}

class HlsDownloadChoice {
  const HlsDownloadChoice({
    required this.url,
    required this.label,
    this.bandwidth = 0,
  });

  final Uri url;
  final String label;
  final int bandwidth;
}

List<HlsDownloadChoice> parseHlsChoices(Uri base, String text) {
  final lines = _hlsLines(text);
  final externalAudio = <String>{};

  for (final line in lines) {
    if (line.startsWith('#EXT-X-SESSION-KEY:') ||
        line.startsWith('#EXT-X-DEFINE:')) {
      throw const FormatException('暗号化・変数付きHLSは保存対象外です');
    }

    if (line.startsWith('#EXT-X-MEDIA:')) {
      final attributes = hlsAttributes(line.substring('#EXT-X-MEDIA:'.length));
      if (attributes['TYPE'] == 'AUDIO' &&
          attributes['URI']?.isNotEmpty == true) {
        externalAudio.add(attributes['GROUP-ID'] ?? '');
      }
    }
  }

  final result = <HlsDownloadChoice>[];

  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;

    final attributes = hlsAttributes(
      line.substring('#EXT-X-STREAM-INF:'.length),
    );

    if (index + 1 >= lines.length || lines[index + 1].startsWith('#')) {
      throw const FormatException('HLSの画質別URLがありません');
    }

    final next = lines[++index];
    final audio = attributes['AUDIO'];
    final subtitles = attributes['SUBTITLES'];
    final video = attributes['VIDEO'];

    if ((audio != null && externalAudio.contains(audio)) ||
        (subtitles != null && subtitles != 'NONE') ||
        video != null) {
      continue;
    }

    final bandwidth = int.tryParse(attributes['BANDWIDTH'] ?? '');
    if (bandwidth == null || bandwidth <= 0) {
      throw const FormatException('HLSの帯域情報が不正です');
    }

    final resolution = attributes['RESOLUTION'];
    result.add(
      HlsDownloadChoice(
        url: videoDownloadUri(base.resolve(next).toString()),
        bandwidth: bandwidth,
        label: [
          if (resolution != null) resolution,
          '${(bandwidth / 1000000).toStringAsFixed(2)} Mbps',
        ].join(' / '),
      ),
    );
  }

  if (result.isEmpty) {
    throw const FormatException('保存できる画質がありません。別音声・字幕等を使う構成は現在対象外です。');
  }

  if (result.length > 32) {
    throw const FormatException('HLSの画質候補が多すぎます');
  }

  result.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
  return List<HlsDownloadChoice>.unmodifiable(result);
}

class HlsDownloadSegment {
  const HlsDownloadSegment({
    required this.url,
    required this.seconds,
    required this.discontinuity,
  });

  final Uri url;
  final double seconds;
  final bool discontinuity;
}

class HlsDownloadPlan {
  HlsDownloadPlan(Iterable<HlsDownloadSegment> segments)
    : segments = List<HlsDownloadSegment>.unmodifiable(segments);

  final List<HlsDownloadSegment> segments;

  String localName(int index) => 's${index.toString().padLeft(5, '0')}.ts';

  String localPlaylist() {
    final target = segments
        .map((segment) => segment.seconds.ceil())
        .reduce(math.max);

    final output = <String>[
      '#EXTM3U',
      '#EXT-X-VERSION:3',
      '#EXT-X-PLAYLIST-TYPE:VOD',
      '#EXT-X-TARGETDURATION:$target',
      '#EXT-X-MEDIA-SEQUENCE:0',
    ];

    for (var index = 0; index < segments.length; index++) {
      final segment = segments[index];
      if (segment.discontinuity) {
        output.add('#EXT-X-DISCONTINUITY');
      }
      output
        ..add('#EXTINF:${segment.seconds.toStringAsFixed(6)},')
        ..add(localName(index));
    }

    output.add('#EXT-X-ENDLIST');
    return '${output.join('\n')}\n';
  }
}

HlsDownloadPlan parseHlsMedia(Uri base, String text) {
  final lines = _hlsLines(text);

  if (!lines.contains('#EXT-X-ENDLIST')) {
    throw const FormatException('ライブ・未完結HLSは保存対象外です');
  }

  final segments = <HlsDownloadSegment>[];
  double? seconds;
  var discontinuity = false;

  for (final line in lines.skip(1)) {
    if (line.startsWith('#EXTINF:')) {
      if (seconds != null) {
        throw const FormatException('HLSの分割データURLが不足しています');
      }

      seconds = double.tryParse(
        line.substring('#EXTINF:'.length).split(',').first,
      );

      if (seconds == null ||
          !seconds.isFinite ||
          seconds <= 0 ||
          seconds > 86400) {
        throw const FormatException('HLSの分割時間が不正です');
      }
    } else if (line == '#EXT-X-DISCONTINUITY') {
      discontinuity = true;
    } else if (line.startsWith('#EXT-X-KEY:')) {
      final attributes = hlsAttributes(line.substring('#EXT-X-KEY:'.length));

      if (attributes['METHOD'] != 'NONE') {
        throw const FormatException('暗号化されたHLSの保存には対応していません');
      }
    } else if (line.startsWith('#')) {
      final tag = line.split(':').first;

      if (line.startsWith('#EXT-X-') &&
          !const {
            '#EXT-X-VERSION',
            '#EXT-X-TARGETDURATION',
            '#EXT-X-MEDIA-SEQUENCE',
            '#EXT-X-DISCONTINUITY-SEQUENCE',
            '#EXT-X-ENDLIST',
            '#EXT-X-PLAYLIST-TYPE',
            '#EXT-X-ALLOW-CACHE',
            '#EXT-X-INDEPENDENT-SEGMENTS',
            '#EXT-X-PROGRAM-DATE-TIME',
          }.contains(tag)) {
        throw FormatException(
          'このHLS形式にはまだ対応していません：$tag'
          '（別音声・バイト範囲・初期化データ等は対象外）',
        );
      }
    } else {
      if (seconds == null) {
        throw const FormatException('HLSの分割データに時間情報がありません');
      }

      segments.add(
        HlsDownloadSegment(
          url: videoDownloadUri(base.resolve(line).toString()),
          seconds: seconds,
          discontinuity: discontinuity,
        ),
      );

      seconds = null;
      discontinuity = false;

      if (segments.length > 10000) {
        throw const FormatException('HLSの分割数が上限を超えています');
      }
    }
  }

  if (seconds != null || segments.isEmpty) {
    throw const FormatException('HLSの分割データが不完全です');
  }

  return HlsDownloadPlan(segments);
}

/// 保存済みプレイリストにネットワーク・任意ファイル参照がないか確認する。
void validateLocalHls(String text, Set<String> files) {
  // URL解決は ../ 等を正規化するため、必ず解決前に検証する。
  // 絶対URL・親パス・区切り文字・クエリ・エスケープ表現を許可しない。
  final rawLines = _hlsLines(text);

  for (final line in rawLines) {
    if (line.startsWith('#')) continue;

    if (!RegExp(r'^s[0-9]{5}\.ts$').hasMatch(line) || !files.contains(line)) {
      throw const FormatException('保存プレイリストには保存済み分割ファイル名だけを指定できます');
    }
  }

  final plan = parseHlsMedia(Uri.parse('https://offline.invalid/'), text);

  final references = <String>{};

  for (final segment in plan.segments) {
    final uri = segment.url;
    final name = uri.path.startsWith('/') ? uri.path.substring(1) : uri.path;

    if (uri.origin != 'https://offline.invalid' ||
        uri.hasQuery ||
        uri.hasFragment ||
        !RegExp(r'^s[0-9]{5}\.ts$').hasMatch(name) ||
        !files.contains(name)) {
      throw const FormatException('保存プレイリストに不正な参照があります');
    }

    references.add(name);
  }

  if (references.length != files.length) {
    throw const FormatException('保存プレイリストと保存ファイルが一致しません');
  }
}
