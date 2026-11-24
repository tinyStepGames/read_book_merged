import 'html_probe.dart';

Uri siteVideoBrowserUri(String value) {
  if (value.length > 16384) {
    throw const FormatException('掲載ページのURLが長すぎます');
  }

  final uri = htmlProbeUri(value);
  final host = uri.host.toLowerCase();

  if (host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local')) {
    throw const FormatException('ローカルホストは掲載ページに指定できません');
  }

  return uri;
}

/// 画面遷移の判定。
/// Webページ内部の全通信を制限するネットワーク境界ではない。
class SiteVideoBrowserPolicy {
  SiteVideoBrowserPolicy(String input) : initial = siteVideoBrowserUri(input);

  final Uri initial;

  bool allowsMainFrame(String value) {
    try {
      return siteVideoBrowserUri(value).origin == initial.origin;
    } catch (_) {
      return false;
    }
  }

  bool allowsSubframe(String value) {
    if (value == 'about:blank' || value == 'about:srcdoc') return true;

    // ブラウザー内で生成されたHTTPSページ由来のblobフレーム。
    // blob URLをアプリの動画URLとして保存・転用するものではない。
    if (value.startsWith('blob:')) {
      try {
        siteVideoBrowserUri(value.substring('blob:'.length));
        return true;
      } catch (_) {
        return false;
      }
    }

    try {
      siteVideoBrowserUri(value);
      return true;
    } catch (_) {
      return false;
    }
  }
}
