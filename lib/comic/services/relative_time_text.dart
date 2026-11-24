/// 英語の相対時間を、日本語の表示文字列へ変換する。
///
/// 日時への変換は行わない。
/// 文字列全体が対応形式に一致した場合だけ変換し、
/// 未対応の文章や数のない表示は元の文字列のまま返す。
String localizeEnglishRelativeTime(String input) {
  // 本文全体などを誤って渡した場合は、変換対象にしない。
  if (input.length > 256) return input;

  final text = input.trim().replaceAll(RegExp(r'\s+'), ' ');

  if (text.toLowerCase() == 'just now') {
    return 'たった今';
  }

  final match = RegExp(
    r'^(\d+(?:\.\d+)?|an?)\s+'
    r'(seconds?|minutes?|hours?|days?|weeks?|months?|years?)'
    r'\s+ago$',
    caseSensitive: false,
  ).firstMatch(text);

  if (match == null || match.end != text.length) return input;

  final rawNumber = match.group(1)!;
  final lowerNumber = rawNumber.toLowerCase();
  final number = lowerNumber == 'a' || lowerNumber == 'an' ? '1' : rawNumber;

  var unit = match.group(2)!.toLowerCase();
  if (unit.endsWith('s')) {
    unit = unit.substring(0, unit.length - 1);
  }

  const labels = {
    'second': '秒',
    'minute': '分',
    'hour': '時間',
    'day': '日',
    'week': '週間',
    'month': 'か月',
    'year': '年',
  };

  final label = labels[unit];
  if (label == null) return input;
  return '$number$label前';
}
