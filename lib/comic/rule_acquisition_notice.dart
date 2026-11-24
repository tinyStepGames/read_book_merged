import 'package:flutter/material.dart';

/// 編集中の取得方式を表示するだけの部品。
/// 通信・保存・取得方式の変更は行いません。
class RuleAcquisitionNotice extends StatelessWidget {
  const RuleAcquisitionNotice({
    super.key,
    required this.acquisition,
    required this.pageAvailable,
    required this.saveHint,
    this.title = '現在の取得方式（保存対象）',
    this.canFetchStaticHere = true,
  });

  final String acquisition;
  final bool pageAvailable;
  final String saveHint;
  final String title;
  final bool canFetchStaticHere;

  @override
  Widget build(BuildContext context) {
    final label = switch (acquisition) {
      'staticHtml' => '通常HTML',
      'renderedDom' => '表示後HTML',
      _ => '未対応の取得方式',
    };

    final explanation = switch (acquisition) {
      'staticHtml' =>
        'サーバーから受け取ったHTMLを使います。'
            'JavaScriptで後から追加される内容は含まれない場合があります。',
      'renderedDom' =>
        'WebViewでページを表示した後のHTMLを使います。'
            '通常HTMLでは取れない内容に対応できる場合がありますが、'
            '表示処理の待ち時間が発生します。',
      _ => '取得方式の設定を確認してください。',
    };

    final color = acquisition == 'staticHtml'
        ? Colors.tealAccent
        : Colors.orangeAccent;

    return Card(
      margin: EdgeInsets.zero,
      color: Colors.white.withValues(alpha: 0.06),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: color.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(
              label,
              key: const ValueKey('rule-acquisition-mode'),
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 8),
            Text(explanation),
            const SizedBox(height: 12),
            Text(
              pageAvailable ? '対象URLのHTML：取得済み' : '対象URLのHTML：未取得、または入力URL変更後',
              key: const ValueKey('rule-acquisition-page'),
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 4),
            const Text(
              '取得方式の設定と、HTML取得・抽出の成功は別です。'
              'テスト結果も確認してください。',
              style: TextStyle(color: Colors.white60, fontSize: 12),
            ),
            const Divider(height: 24),
            const Text(
              '「ページから選ぶ」の結果を反映すると、'
              '表示後HTMLに切り替わります。'
              '選択をキャンセルしただけでは切り替わりません。',
            ),
            const SizedBox(height: 8),
            Text(
              canFetchStaticHere
                  ? '通常HTMLの取得に成功すると、'
                        '通常HTMLに切り替わります。'
                        '切り替えた後は、必要な項目が取れるか再テストしてください。'
                  : '通常HTMLに戻して確認する場合は、'
                        '前の一覧設定画面で通常HTMLを取得してください。',
            ),
            const SizedBox(height: 12),
            Text(
              saveHint,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
