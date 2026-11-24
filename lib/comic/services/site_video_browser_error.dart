/// ページ読み込みエラーを前面表示するか判定する。
/// HTTPエラーとサイト内プレーヤー自身のエラー表示は別に扱う。
bool showSiteVideoBrowserLoadError({
  required bool mainFrame,
  required bool connectionAborted,
  required bool pageLoaded,
  required bool explicitlyBlocked,
}) {
  if (!mainFrame) return false;

  // 中断だけを限定的に扱う。接続失敗等は隠さない。
  if (connectionAborted && (pageLoaded || explicitlyBlocked)) {
    return false;
  }

  return true;
}
