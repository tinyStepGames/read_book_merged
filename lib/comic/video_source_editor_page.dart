import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import 'editor_unsaved_changes.dart';
import 'services/site_reading_settings.dart';
import 'services/site_rule_store.dart';
import 'services/video_source.dart';
import 'video_playback_page.dart';

class VideoSourceEditorPage extends StatefulWidget {
  const VideoSourceEditorPage({
    super.key,
    required this.repository,
    required this.site,
  });

  final SiteRuleStore repository;
  final SavedSiteRule site;

  @override
  State<VideoSourceEditorPage> createState() => _VideoSourceEditorPageState();
}

class _VideoSourceEditorPageState extends State<VideoSourceEditorPage>
    with EditorUnsavedChanges<VideoSourceEditorPage> {
  late final TextEditingController _url;
  late final TextEditingController _origins;
  late final TextEditingController _selector;
  late final TextEditingController _attribute;

  final _client = VideoSourceClient();
  VideoUrlSource _source = VideoUrlSource.jsonLd;
  CancelToken? _cancel;
  VideoExtractionResult? _result;
  bool _busy = false;
  bool _previewVisited = false;
  String _status = '動画を掲載している話ページのURLを指定してください。';

  @override
  bool get editorBusy => _busy;

  @override
  List<TextEditingController> get editorInputs => [
    _url,
    _origins,
    _selector,
    _attribute,
  ];

  @override
  String get editorSnapshot => encodeEditorSnapshot({
    'url': _url.text,
    'origins': _origins.text,
    'source': _source.name,
    'selector': _selector.text,
    'attribute': _attribute.text,
  });

  @override
  void initState() {
    super.initState();

    final saved = widget.site.readingSettings?.video;
    _url = TextEditingController(
      text: saved?.pageUrl ?? widget.site.rules.values.first.pageUrl,
    );
    _origins = TextEditingController(
      text: saved?.allowedOrigins.join('\n') ?? '',
    );
    _selector = TextEditingController(text: saved?.selector ?? 'video, source');
    _attribute = TextEditingController(text: saved?.attribute ?? 'src');
    _source = saved?.source ?? VideoUrlSource.jsonLd;
  }

  VideoSourceSettings _settings() => VideoSourceSettings(
    pageUrl: _url.text.trim(),
    source: _source,
    selector: _selector.text.trim(),
    attribute: _attribute.text.trim(),
    allowedOrigins: List<String>.unmodifiable(
      _origins.text
          .split(RegExp(r'[\r\n,]+'))
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty),
    ),
  );

  void _invalidate() {
    setState(() {
      _result = null;
      _previewVisited = false;
      _status = '設定を変更しました。動画URLを抽出し直してください。';
    });
  }

  Future<void> _extract() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();

    final token = CancelToken();
    _cancel = token;

    setState(() {
      _busy = true;
      _result = null;
      _previewVisited = false;
      _status = '通常HTMLから動画URLを抽出しています…';
    });

    try {
      final settings = _settings();
      settings.validateFor(
        widget.site.rules.values.map((rule) => rule.pageUrl),
      );

      final result = await _client.load(
        settings: settings,
        targetUrl: settings.pageUrl,
        cancelToken: token,
      );

      if (!mounted || token.isCancelled) return;

      setState(() {
        _result = result;
        _status = result.hasSingleUrl
            ? '動画URLを1件取得しました。再生テストで映像と音声を確認してください。'
            : '動画URLは${result.urls.length}件でした。診断内容を確認してください。';
      });
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _status = token.isCancelled ? '取得を中止しました。' : '動画URLを取得できませんでした：$error';
      });
    } finally {
      if (identical(_cancel, token)) _cancel = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _preview() async {
    final result = _result;
    if (_busy || result == null || !result.hasSingleUrl) return;

    setState(() => _busy = true);

    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => VideoPlaybackPage(url: result.urls.single),
        ),
      );

      if (!mounted) return;

      setState(() {
        _previewVisited = true;
        _status =
            '再生テストから戻りました。'
            '映像・音声が正常だった場合だけ設定を保存してください。';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy || _result?.hasSingleUrl != true || !_previewVisited) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('動画設定を保存'),
        content: const Text(
          '映像・音声・シークを確認できましたか？\n\n'
          '保存するのは取得方法・サンプルURL・許可元などの設定だけです。'
          '動画本体・Cookieは保存しません。\n\n'
          '保存すると、このサイトでは画像より動画再生を優先します。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('戻る'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('確認したので保存'),
          ),
        ],
      ),
    );

    if (!mounted || confirmed != true) return;
    setState(() => _busy = true);

    try {
      final video = _settings();
      video.validateFor(widget.site.rules.values.map((rule) => rule.pageUrl));

      final reading =
          (widget.site.readingSettings ?? const SiteReadingSettings())
              .withVideo(video);

      await widget.repository.saveReadingSettings(
        id: widget.site.id,
        settings: reading,
        expectedUpdatedAt: widget.site.updatedAt,
      );

      if (!mounted) return;
      markEditorSaved();
      Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() => _status = '保存できませんでした：$error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    if (_busy || widget.site.readingSettings?.video == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('動画設定を削除'),
        content: const Text(
          'このサイトの動画設定だけを削除します。'
          '一覧・開き方・本文画像などの設定は残します。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('動画設定だけ削除'),
          ),
        ],
      ),
    );

    if (!mounted || confirmed != true) return;
    setState(() => _busy = true);

    try {
      await widget.repository.saveReadingSettings(
        id: widget.site.id,
        settings: widget.site.readingSettings!.withVideo(null),
        expectedUpdatedAt: widget.site.updatedAt,
      );

      if (!mounted) return;
      markEditorSaved();
      Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(() => _status = '削除できませんでした：$error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _cancel?.cancel('動画設定画面終了');
    _client.close();
    _url.dispose();
    _origins.dispose();
    _selector.dispose();
    _attribute.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => guardEditor(_buildEditor(context));

  Widget _buildEditor(BuildContext context) {
    final result = _result;

    return Scaffold(
      appBar: AppBar(
        leading: editorBackButton,
        title: const Text('動画設定・再生テスト'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('保存先：${widget.site.name}'),
          const SizedBox(height: 8),
          const Text(
            '通常HTMLからの動画URL抽出と再生を確認します。\n'
            '動画設定を保存したサイトでは動画を優先します。'
            '一覧・詳細・履歴から動画を開けます。\n'
            '表示後HTML・iframe内の探索・動画保存・DRMには対応しません。',
            style: TextStyle(color: Colors.white60),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _url,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '動画掲載ページのサンプルURL',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => _invalidate(),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<VideoUrlSource>(
            initialValue: _source,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: '動画URLの取得元',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(
                value: VideoUrlSource.jsonLd,
                child: Text('構造化データ：VideoObject.contentUrl'),
              ),
              DropdownMenuItem(
                value: VideoUrlSource.attribute,
                child: Text('HTML要素の属性：video / source等'),
              ),
            ],
            onChanged: _busy
                ? null
                : (value) {
                    if (value == null) return;
                    _source = value;
                    _invalidate();
                  },
          ),
          if (_source == VideoUrlSource.attribute) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _selector,
              enabled: !_busy,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: '動画要素のCSSセレクター',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => _invalidate(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _attribute,
              enabled: !_busy,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: '動画URLの属性',
                hintText: 'src',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => _invalidate(),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _origins,
            enabled: !_busy,
            minLines: 2,
            maxLines: 5,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: '最初の動画URLの許可元',
              hintText: 'https://rumble.com',
              helperText:
                  'https://ホスト名 を1行1件で指定します。'
                  'ワイルドカードは使えません。',
              helperMaxLines: 3,
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => _invalidate(),
          ),
          const SizedBox(height: 8),
          const Text(
            '許可元は最初に抽出した動画URLの確認に使います。'
            'HLS内部の別プレイリスト・映像断片・転送等は、'
            '再生ライブラリが通信します。\n'
            'Cookie・認証ヘッダーは引き継ぎません。'
            'アクセス条件のある配信は再生できない場合があります。',
            style: TextStyle(fontSize: 12, color: Colors.white60),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : _extract,
                icon: const Icon(Icons.search),
                label: const Text('動画URLを抽出'),
              ),
              OutlinedButton.icon(
                onPressed: !_busy && result?.hasSingleUrl == true
                    ? _preview
                    : null,
                icon: const Icon(Icons.play_arrow),
                label: const Text('再生テスト'),
              ),
              if (_cancel != null)
                TextButton(
                  onPressed: () => _cancel?.cancel('利用者が中止'),
                  child: const Text('取得を中止'),
                ),
            ],
          ),
          if (_busy) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
          const SizedBox(height: 12),
          SelectableText(_status),
          if (result != null) ...[
            const SizedBox(height: 12),
            Text('抽出した動画URL：${result.urls.length}件'),
            for (final url in result.urls)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SelectableText(url.toString()),
              ),
            for (final issue in result.issues)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  issue,
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
              ),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: !_busy && result?.hasSingleUrl == true && _previewVisited
                ? _save
                : null,
            icon: const Icon(Icons.save_outlined),
            label: const Text('確認した動画設定をサイトに保存'),
          ),
          if (widget.site.readingSettings?.video != null) ...[
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _busy ? null : _remove,
              child: const Text('動画設定だけ削除'),
            ),
          ],
        ],
      ),
    );
  }
}
