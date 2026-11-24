import 'dart:io';

import 'package:path/path.dart' as p;

import 'hls_download_plan.dart';

/// 保存済みHLSを、再生時だけ明示的なローカル参照へ変換する。
/// 保存パッケージ本体・ハッシュ・完了情報は変更しない。
String localHlsPlaybackPlaylist({
  required String playlist,
  required Directory directory,
  required Set<String> segments,
}) {
  validateLocalHls(playlist, segments);

  final folder = directory.absolute.path;

  // file:形式で曖昧に解釈される可能性のある保存先は採用しない。
  if (folder.contains(RegExp(r'[\r\n?#]')) || folder.contains('\u0000')) {
    throw const FormatException('この保存先の文字をローカルHLS再生に使用できません');
  }

  return playlist
      .replaceFirst(RegExp(r'^\uFEFF'), '')
      .split(RegExp(r'\r?\n'))
      .map((raw) {
        final line = raw.trim();
        if (line.isEmpty || line.startsWith('#')) return line;

        // validateLocalHls後も、参照できる名前をここで限定。
        if (!RegExp(r'^s[0-9]{5}\.ts$').hasMatch(line) ||
            !segments.contains(line)) {
          throw const FormatException('再生用HLSに不正な分割ファイル名があります');
        }

        final path = p.join(folder, line).replaceAll(r'\', '/');
        return 'file:$path';
      })
      .join('\n');
}
