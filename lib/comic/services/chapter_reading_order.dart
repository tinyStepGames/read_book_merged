/// 全角数字を含む話数表記を数値判定用にそろえる。
String _normalizeChapterText(String value) {
  return value.replaceAllMapped(RegExp(r'[０-９．]'), (match) {
    final character = match.group(0)!;
    if (character == '．') return '.';
    return String.fromCharCode(character.codeUnitAt(0) - 0xFEE0);
  }).trim();
}

double? _plainNumber(String value) {
  if (!RegExp(r'^\d+(?:\.\d+)?$').hasMatch(value)) return null;

  final number = double.tryParse(value);
  return number != null && number.isFinite ? number : null;
}

/// 無関係な日付や巻数を拾わないよう、話数らしい表記だけ判定する。
///
/// 対応例:
/// 2 / 2.5 / Chapter 2 / Ch. 2 / 第2話 / 2話 / 第２話
///
/// 複数の話数が含まれるタイトルは曖昧なため判定しない。
double? chapterNumberForReading(String value) {
  if (value.length > 4096) return null;

  final text = _normalizeChapterText(value);
  final plain = _plainNumber(text);
  if (plain != null) return plain;

  final patterns = <RegExp>[
    RegExp(
      r'\b(?:chapter|chap\.?|ch\.)\s*#?\s*(\d+(?:\.\d+)?)(?![\d.])',
      caseSensitive: false,
    ),
    RegExp(r'第\s*(\d+(?:\.\d+)?)\s*(?:話|回)'),
    RegExp(r'(?<![\d.])(\d+(?:\.\d+)?)\s*話'),
  ];

  // 「第2話」と「2話」のように重なる候補は同じ話数として扱う。
  final numbers = <double>{};

  for (final pattern in patterns) {
    for (final match in pattern.allMatches(text)) {
      final number = _plainNumber(match.group(1)!);
      if (number != null) numbers.add(number);
    }
  }

  return numbers.length == 1 ? numbers.single : null;
}

/// 一覧の表示順とは独立した読書用の順番を作る。
///
/// 番号付きは小さい順。
/// 同じ話数・番号不明の項目は元の取得順を維持する。
/// workKeyOf指定時は作品を混ぜずに並べる。
///
/// 元のリストは変更しない。
List<T> chapterReadingOrder<T>(
  Iterable<T> source, {
  required String Function(T) titleOf,
  String Function(T)? explicitNumberOf,
  String Function(T)? workKeyOf,
}) {
  final indexed = source.toList().asMap().entries.toList();
  final numbers = <int, double?>{};
  final works = <int, String>{};

  for (final entry in indexed) {
    final explicit = explicitNumberOf?.call(entry.value) ?? '';

    numbers[entry.key] =
        chapterNumberForReading(explicit) ??
        chapterNumberForReading(titleOf(entry.value));

    works[entry.key] = workKeyOf?.call(entry.value) ?? '';
  }

  indexed.sort((a, b) {
    final workComparison = works[a.key]!.compareTo(works[b.key]!);
    if (workComparison != 0) return workComparison;

    final x = numbers[a.key];
    final y = numbers[b.key];

    if (x == null && y == null) return a.key.compareTo(b.key);
    if (x == null) return 1;
    if (y == null) return -1;

    final compared = x.compareTo(y);
    return compared == 0 ? a.key.compareTo(b.key) : compared;
  });

  return indexed.map((entry) => entry.value).toList();
}
