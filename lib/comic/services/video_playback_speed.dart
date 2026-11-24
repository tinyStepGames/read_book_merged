class VideoPlaybackSpeed {
  VideoPlaybackSpeed._();

  static const values = <double>[0.5, 0.75, 1, 1.25, 1.5, 1.75, 2];

  // アプリ起動中だけ共有。利用者の設定ファイルは変更しない。
  static double _rate = 1;

  static double get rate => _rate;

  static void validate(double value) {
    if (!values.contains(value)) {
      throw ArgumentError.value(value, 'rate', '未対応の再生速度です');
    }
  }

  static void remember(double value) {
    validate(value);
    _rate = value;
  }

  static String label(double value) {
    validate(value);
    return '${value == value.roundToDouble() ? value.toInt() : value}×';
  }
}
