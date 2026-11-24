import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'services/html_probe.dart';

/// サイト全体ではなく、単一の抽出設定を運ぶ形式。
class ExtractionDraft {
  const ExtractionDraft({
    required this.pageUrl,
    required this.selector,
    required this.attribute,
    required this.mode,
    required this.resolveUrls,
    required this.acquisition,
  });

  static const prefix = 'ocr-extraction:1:';
  static const maxJsonBytes = 65536;
  static const maxQrCharacters = 1500;

  final String pageUrl;
  final String selector;
  final String attribute;
  final HtmlValueMode mode;
  final bool resolveUrls;
  final String acquisition;

  void validate() {
    htmlProbeUri(pageUrl);

    if (pageUrl.length > 4096 ||
        selector.length > 2048 ||
        attribute.length > 128) {
      throw const FormatException('設定値が長すぎます');
    }

    if (!const ['staticHtml', 'renderedDom'].contains(acquisition)) {
      throw const FormatException('取得方式が不正です');
    }

    if (mode == HtmlValueMode.attribute &&
        !RegExp(r'^[A-Za-z_:][A-Za-z0-9_:.-]*$').hasMatch(attribute)) {
      throw const FormatException('属性名が不正です');
    }
  }

  Map<String, dynamic> toJson() => {
    'format': 'offline-comic-reader.extraction',
    'version': 1,
    'pageUrl': pageUrl,
    'selector': selector,
    'attribute': attribute,
    'mode': mode.name,
    'resolveUrls': resolveUrls,
    'acquisition': acquisition,
  };

  String encodeJson() {
    validate();
    return const JsonEncoder.withIndent('  ').convert(toJson());
  }

  String encodeQr() {
    validate();
    final payload =
        '$prefix${base64Url.encode(utf8.encode(jsonEncode(toJson())))}';

    if (payload.length > maxQrCharacters) {
      throw const FormatException('設定が大きいため、この初版では1枚のQRにできません。JSONで共有してください');
    }
    return payload;
  }

  static ExtractionDraft parse(String input) {
    var value = input.trim();

    if (utf8.encode(value).length > maxJsonBytes) {
      throw const FormatException('設定が大きすぎます');
    }

    if (value.startsWith(prefix)) {
      value = utf8.decode(
        base64Url.decode(base64Url.normalize(value.substring(prefix.length))),
      );
    }

    if (utf8.encode(value).length > maxJsonBytes) {
      throw const FormatException('設定が大きすぎます');
    }

    final data = Map<String, dynamic>.from(jsonDecode(value) as Map);

    const allowed = {
      'format',
      'version',
      'pageUrl',
      'selector',
      'attribute',
      'mode',
      'resolveUrls',
      'acquisition',
    };

    if (data.keys.any((key) => !allowed.contains(key)) ||
        data['format'] != 'offline-comic-reader.extraction' ||
        data['version'] != 1 ||
        data['resolveUrls'] is! bool) {
      throw const FormatException('未対応、または不正な抽出設定です');
    }

    final modes = HtmlValueMode.values.where(
      (value) => value.name == data['mode'],
    );
    if (modes.length != 1) {
      throw const FormatException('抽出方式が不正です');
    }

    final draft = ExtractionDraft(
      pageUrl: data['pageUrl'] as String,
      selector: data['selector'] as String,
      attribute: data['attribute'] as String,
      mode: modes.single,
      resolveUrls: data['resolveUrls'] as bool,
      acquisition: data['acquisition'] as String,
    );

    draft.validate();
    return draft;
  }
}

class ExtractionTransferPage extends StatefulWidget {
  const ExtractionTransferPage({super.key, required this.draft});

  final ExtractionDraft draft;

  @override
  State<ExtractionTransferPage> createState() => _ExtractionTransferPageState();
}

class _ExtractionTransferPageState extends State<ExtractionTransferPage> {
  late final TextEditingController _json;
  String? _qr;
  String _message = '現在の抽出設定です。読み込みたい内容への貼り替えもできます。';

  @override
  void initState() {
    super.initState();
    _json = TextEditingController(text: widget.draft.encodeJson());
  }

  @override
  void dispose() {
    _json.dispose();
    super.dispose();
  }

  void _showQr() {
    try {
      final draft = ExtractionDraft.parse(_json.text);
      setState(() {
        _qr = draft.encodeQr();
        _message = 'QRに設定本体を格納しています。公開サーバーは不要です。';
      });
    } catch (error) {
      setState(() {
        _qr = null;
        _message = 'QRを作成できませんでした：$error';
      });
    }
  }

  Future<void> _copyJson() async {
    try {
      final draft = ExtractionDraft.parse(_json.text);
      await Clipboard.setData(ClipboardData(text: draft.encodeJson()));
      if (mounted) setState(() => _message = 'JSONをコピーしました');
    } catch (error) {
      if (mounted) setState(() => _message = 'コピーできませんでした：$error');
    }
  }

  Future<void> _import() async {
    try {
      final draft = ExtractionDraft.parse(_json.text);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('抽出設定を取り込みますか？'),
          content: SingleChildScrollView(
            child: Text(
              '対象：${draft.pageUrl}\n\n'
              'セレクター：${draft.selector}\n'
              '取得：${draft.mode.name} / ${draft.attribute}\n'
              '方式：${draft.acquisition}\n\n'
              '現在の編集欄を置き換えます。'
              '通信と下書き保存はまだ行いません。',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('取り込む'),
            ),
          ],
        ),
      );

      if (confirmed == true && mounted) {
        Navigator.pop(context, draft);
      }
    } catch (error) {
      if (mounted) setState(() => _message = '取り込めませんでした：$error');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('抽出設定のJSON・QR')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '独自形式の「単一の抽出設定」です。サイト全体のルールや'
            'Yealico互換形式ではありません。\n'
            '共有前に、URLへ個人用トークンなどが含まれていないか確認してください。',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _json,
            minLines: 8,
            maxLines: 14,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'JSON または QR内容の文字列',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() => _qr = null),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: _copyJson,
                child: const Text('JSONをコピー'),
              ),
              OutlinedButton(onPressed: _showQr, child: const Text('QRを表示')),
              FilledButton(
                onPressed: _import,
                child: const Text('内容を確認して取り込む'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SelectableText(_message),
          if (_qr != null) ...[
            const SizedBox(height: 20),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: ColoredBox(
                  color: Colors.white,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: QrImageView(
                      data: _qr!,
                      version: QrVersions.auto,
                      errorCorrectionLevel: QrErrorCorrectLevel.M,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'QR画像はスクリーンショットで共有できます。'
              'カメラ読み取り・画像読み込みは次の段階で追加します。',
            ),
          ],
        ],
      ),
    ),
  );
}
