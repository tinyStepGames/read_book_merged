import 'dart:async';

import 'package:dio/dio.dart';

import 'html_probe.dart';
import 'list_extraction_rule.dart';

enum RuleDiagnosticStage { fetch, extraction, browsing }

String _detailOf(Object error) {
  if (error is FormatException) return error.message;
  if (error is StateError) return error.message.toString();
  return error.toString();
}

String _withDetail(String title, String advice, Object error) =>
    '$title\n$advice\n詳細：${_detailOf(error)}';

String _httpFailure(int status) {
  final advice = switch (status) {
    401 || 403 =>
      'サイト側にアクセスを拒否されました。'
          'URLや、通常のブラウザーで閲覧できるかを確認してください。'
          'アプリは制限の回避や自動再試行を行いません。',
    404 =>
      '指定ページが見つかりませんでした。'
          'URLが正しいか、ページが移動していないかを確認してください。',
    429 =>
      'サイト側でアクセスが制限されています。'
          '連続取得を避け、時間を置いてから手動で再試行してください。',
    >= 500 && <= 599 =>
      'サイト側でエラーが発生しています。'
          '時間を置いてから手動で再試行してください。',
    _ =>
      '正常なHTML応答を取得できませんでした。'
          'URLとサイトの状態を確認してください。',
  };

  return 'HTML取得に失敗しました（HTTP $status）。\n$advice';
}

String ruleFailureMessage(Object error, {required RuleDiagnosticStage stage}) {
  if (error is HtmlProbeHttpException) {
    return _httpFailure(error.statusCode);
  }

  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.cancel:
        return '取得を中止しました。';

      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '通信がタイムアウトしました。\n'
            '通信環境やサイトの状態を確認し、手動で再試行してください。'
            '自動再試行は行いません。';

      case DioExceptionType.transformTimeout:
        return '応答データの変換処理がタイムアウトしました。\n'
            '接続や受信のタイムアウトとは別です。'
            '自動再試行は行いません。'
            '繰り返す場合は、取得対象や応答データの状態を確認してください。';

      case DioExceptionType.connectionError:
        return 'サイトへ接続できませんでした。\n'
            '通信環境・URL・サイトが稼働しているかを確認してください。';

      case DioExceptionType.badCertificate:
        return '安全な接続を確認できませんでした。\n'
            '証明書の検証は無効にしません。'
            '端末の日時やサイトの状態を確認してください。';

      case DioExceptionType.badResponse:
        final status = error.response?.statusCode;
        if (status != null) return _httpFailure(status);

        return 'サイトから正常な応答を取得できませんでした。\n'
            'URLとサイトの状態を確認してください。';

      case DioExceptionType.unknown:
        return _withDetail(
          '取得処理に失敗しました。',
          '原因を通信障害と断定できません。下の詳細を確認してください。',
          error,
        );
    }
  }

  if (error is TimeoutException) {
    return _withDetail(
      '処理が時間内に完了しませんでした。',
      '通信・ページ表示・抽出処理のいずれかで待ち時間が発生しています。'
          '詳細を確認してください。',
      error,
    );
  }

  final detail = _detailOf(error);

  if (detail.contains('まとまりのセレクターが不正です') || detail.contains('項目のセレクターが不正です')) {
    return _withDetail(
      'セレクターの設定を確認してください。',
      '一致0件ではなく、セレクターを解釈できない状態です。'
          '括弧・引用符・記号の指定を確認してください。',
      error,
    );
  }

  if (detail.contains('正規表現・整形テンプレートの設定が不正です')) {
    return _withDetail(
      '正規表現・整形テンプレートの設定を確認してください。',
      '詳細に表示されている項目の設定を修正してください。',
      error,
    );
  }

  if (detail.contains('一覧テストが時間上限を超えました')) {
    return _withDetail(
      '一覧の抽出処理が時間上限を超えました。',
      '通信のタイムアウトとは別です。'
          '正規表現やセレクターを簡単にして再テストしてください。',
      error,
    );
  }

  if (error is FormatException) {
    return _withDetail(
      'URL・設定・取得データの形式を確認してください。',
      '通信エラーとは限りません。下の詳細を確認してください。',
      error,
    );
  }

  final title = switch (stage) {
    RuleDiagnosticStage.fetch => 'HTMLを取得できませんでした。',
    RuleDiagnosticStage.extraction => '一覧を抽出できませんでした。',
    RuleDiagnosticStage.browsing => '一覧を取得・抽出できませんでした。',
  };

  return _withDetail(title, '原因を特定できないため、下の詳細を確認してください。', error);
}

/// 元の診断は保持し、既知の問題だけ対処案内を付ける。
String ruleIssueMessage(String issue) {
  if (issue.contains('正規表現に一致しません')) {
    return '$issue\n'
        '取得した値に正規表現が一致していません。'
        '「一致候補・採用結果」で加工前の値と式を確認してください。';
  }

  if (issue.contains('存在しない参照です')) {
    return '$issue\n'
        r'整形テンプレートの $1・$2 などと、'
        '正規表現の括弧の数を確認してください。';
  }

  if (issue.contains('項目のセレクターが不正です')) {
    return '$issue\n'
        'この項目の「内側のセレクター」を確認してください。';
  }

  return issue;
}

String _staticHtmlAdvice(String acquisition) => acquisition == 'staticHtml'
    ? '\n通常HTMLで一致しない理由は、'
          'ページ内容・セレクター・表示後に追加される要素などが考えられます。'
          '必要なら編集画面の「まとまりをページから選ぶ」で確認してください。'
          '取得方式は自動変更していません。'
    : '';

String emptyListAdvice({required int total, required String acquisition}) {
  final message = total == 0
      ? '取得したHTMLでは、まとまりのセレクターに一致する要素が0件でした。'
            '対象URL・ページ内容・まとまりの設定を確認してください。'
            '作品やチャプターが存在しないとは断定できません。'
      : '$total件のまとまりに一致しましたが、表示対象の項目がありませんでした。'
            '空のレイアウト枠や各項目の設定を、一覧テストで確認してください。';

  return '$message${_staticHtmlAdvice(acquisition)}';
}

String listReportAdvice(
  ListExtractionReport report, {
  required String acquisition,
}) {
  if (report.total == 0) {
    return '\n${emptyListAdvice(total: 0, acquisition: acquisition)}';
  }

  if (report.rows.isNotEmpty &&
      report.rows.every(
        (row) =>
            (row.values['title'] ?? '').trim().isEmpty &&
            (row.values['url'] ?? '').trim().isEmpty,
      )) {
    return '\n一致したまとまりはありますが、'
        '表示中の全項目でタイトルとリンクが空です。'
        '各カードの診断と「一致候補・採用結果」を確認してください。';
  }

  return '';
}

String browseListStatus({
  required int total,
  required int itemCount,
  required int openableCount,
  required String acquisition,
}) {
  if (itemCount == 0) {
    return emptyListAdvice(total: total, acquisition: acquisition);
  }

  if (openableCount == 0) {
    return '$itemCount件の項目がありますが、開ける項目がありません。'
        'タイトル・リンクの設定と各項目の診断を確認してください。';
  }

  // 正常時のヘッダーを非表示にする既存の判定用文言を維持する。
  return '$itemCount件を取得しました';
}
