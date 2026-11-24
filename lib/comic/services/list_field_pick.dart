import 'html_probe.dart';
import 'list_extraction_rule.dart';

/// 画面から選んだ結果を一覧の1項目へ変換する。
/// セレクター空欄は、まとまりの要素自身を表す。
ListFieldRule listFieldFromPick({
  required String key,
  required String selector,
  required HtmlValueMode mode,
  required String attribute,
}) {
  if (!listFieldLabels.containsKey(key)) {
    throw const FormatException('未対応の項目です');
  }
  if (mode == HtmlValueMode.innerHtml) {
    throw const FormatException('一覧の項目には文字列または属性を指定してください');
  }
  if (selector.length > 2048) {
    throw const FormatException('セレクターが長すぎます');
  }

  final isText = mode == HtmlValueMode.text;
  final attr = isText ? '' : attribute.trim();

  if (!isText &&
      (attr.length > 128 ||
          !RegExp(r'^[A-Za-z_:][A-Za-z0-9_:.-]*$').hasMatch(attr))) {
    throw const FormatException('属性名を確認してください');
  }

  return ListFieldRule(
    selector: selector,
    mode: isText
        ? ListValueMode.text
        : key == 'thumbnail' && attr.toLowerCase() == 'style'
        ? ListValueMode.cssUrl
        : ListValueMode.attribute,
    attribute: attr,
    enabled: true,
  );
}
