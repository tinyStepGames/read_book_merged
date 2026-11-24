/// テンプレートに現れる参照番号を列挙する。
/// $$ は文字としてのドル記号、$0 は一致全体。
Iterable<int> _references(String template) sync* {
  for (var i = 0; i < template.length; i++) {
    if (template[i] != r'$') continue;
    if (i + 1 < template.length && template[i + 1] == r'$') {
      i++;
      continue;
    }

    var end = i + 1;
    while (end < template.length) {
      final code = template.codeUnitAt(end);
      if (code < 48 || code > 57) break;
      end++;
    }

    if (end == i + 1) {
      throw const FormatException(r'テンプレートのドル記号は $1・$0・$$ などで指定してください');
    }

    final number = int.tryParse(template.substring(i + 1, end));
    if (number == null) {
      throw const FormatException('参照番号が大きすぎます');
    }
    yield number;
    i = end - 1;
  }
}

/// コピー・貼り付け等で境界に付いた実際のCR/LFのみを除く。
/// 正規表現中の文字列としての \r や \n は変更しない。
String _trimTransformBoundaryLineBreaks(String value) =>
    value.replaceAll(RegExp(r'^[\r\n]+|[\r\n]+$'), '');

void validateListTransform(String pattern, String replacement) {
  pattern = _trimTransformBoundaryLineBreaks(pattern);
  replacement = _trimTransformBoundaryLineBreaks(replacement);
  if (pattern.length > 512 || replacement.length > 2048) {
    throw const FormatException('正規表現または整形テンプレートが長すぎます');
  }

  if (pattern.isEmpty) return;
  RegExp(pattern);
  // 一致処理はしない。テンプレートの構文だけを検証する。
  _references(replacement).toList();
}

String transformListText(
  String input, {
  required String pattern,
  required String replacement,
}) {
  pattern = _trimTransformBoundaryLineBreaks(pattern);
  replacement = _trimTransformBoundaryLineBreaks(replacement);
  validateListTransform(pattern, replacement);
  if (pattern.isEmpty) return input;

  // 取得できていない値から、固定文字列だけを作らない。
  if (input.isEmpty) return '';

  if (input.length > 4096) {
    throw const FormatException('整形対象が長すぎます。取得範囲を狭めてください');
  }

  final match = RegExp(pattern).firstMatch(input);
  if (match == null) {
    throw const FormatException('正規表現に一致しません');
  }

  for (final number in _references(replacement)) {
    if (number > match.groupCount) {
      throw FormatException('存在しない参照です：\$$number');
    }
  }

  final output = StringBuffer();

  for (var i = 0; i < replacement.length; i++) {
    final char = replacement[i];

    if (char != r'$') {
      output.write(char);
      continue;
    }

    if (replacement[i + 1] == r'$') {
      output.write(r'$');
      i++;
      continue;
    }

    var end = i + 1;
    while (end < replacement.length) {
      final code = replacement.codeUnitAt(end);
      if (code < 48 || code > 57) break;
      end++;
    }

    final number = int.parse(replacement.substring(i + 1, end));
    output.write(match.group(number) ?? '');
    i = end - 1;
  }

  final value = output.toString().trim();
  if (value.length > 8192) {
    throw const FormatException('整形結果が長すぎます');
  }
  return value;
}
