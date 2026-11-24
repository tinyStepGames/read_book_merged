/// Pepper&Carrotの公開日キャプションから、
/// 年月日が明確で有効な日付だけを取得する。
String? pepperCarrotPublishedDate(String? caption) {
  if (caption == null || caption.trim().isEmpty) return null;

  final matches = RegExp(
    r'\b(\d{4})-(\d{2})-(\d{2})\b',
  ).allMatches(caption).toList();

  // 日付が複数ある場合は、どれが公開日か推測しない。
  if (matches.length != 1) return null;

  final match = matches.single;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);

  if (year < 1 || month < 1 || month > 12 || day < 1 || day > 31) {
    return null;
  }

  // 暦上の妥当性だけを確認する。
  // 公開時刻やタイムゾーンを付与するためではない。
  final checked = DateTime.utc(year, month, day);

  if (checked.year != year || checked.month != month || checked.day != day) {
    return null;
  }

  return match.group(0);
}
