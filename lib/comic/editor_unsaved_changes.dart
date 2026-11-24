import 'dart:convert';

import 'package:flutter/material.dart';

String encodeEditorSnapshot(Object? value) =>
    jsonEncode(_canonicalEditorValue(value));

Object? _canonicalEditorValue(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonicalEditorValue(value[key])};
  }
  if (value is List) {
    return value.map(_canonicalEditorValue).toList();
  }
  return value;
}

mixin EditorUnsavedChanges<T extends StatefulWidget> on State<T> {
  String get editorSnapshot;

  bool get editorBusy => false;

  List<TextEditingController> get editorInputs => const [];

  String? _editorBaseline;
  List<TextEditingController> _trackedEditorInputs = const [];
  bool _editorExitPending = false;
  bool _editorExitAllowed = false;

  bool get editorHasChanges =>
      _editorBaseline != null && editorSnapshot != _editorBaseline;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_editorBaseline != null) return;

    _editorBaseline = editorSnapshot;
    _trackedEditorInputs = List.of(editorInputs);

    for (final input in _trackedEditorInputs) {
      input.addListener(_onEditorInput);
    }
  }

  void _onEditorInput() {
    if (mounted) setState(() {});
  }

  /// 永続保存の成功時だけ呼び出す。
  /// 下書き保存・コピー・プレビューでは呼び出さない。
  void markEditorSaved() {
    _editorBaseline = editorSnapshot;
  }

  Widget? get editorBackButton {
    if (!Navigator.of(context).canPop()) return null;

    return BackButton(
      onPressed: () async {
        await requestEditorExit();
      },
    );
  }

  Widget guardEditor(Widget child) => PopScope<Object?>(
    canPop: _editorExitAllowed || (!editorBusy && !editorHasChanges),
    onPopInvokedWithResult: (didPop, result) async {
      if (!didPop) await requestEditorExit(result);
    },
    child: child,
  );

  Future<void> requestEditorExit([Object? result]) async {
    if (!mounted || editorBusy || _editorExitPending) return;

    final route = ModalRoute.of(context);
    if (route?.isCurrent != true) return;

    _editorExitPending = true;

    try {
      if (editorHasChanges) {
        FocusScope.of(context).unfocus();

        final discard = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            title: const Text('変更が保存されていません'),
            content: const Text(
              '変更を破棄して前の画面へ戻りますか？\n\n'
              '保存済みの設定は変更しません。'
              '下書き保存はサイトへの本保存とは別です。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('編集を続ける'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('変更を破棄して戻る'),
              ),
            ],
          ),
        );

        if (!mounted || discard != true) return;
      }

      if (!mounted || editorBusy || route?.isCurrent != true) return;

      await _finishEditorExit(result);
    } finally {
      _editorExitPending = false;
    }
  }

  /// 検証済みの設定を親画面へ返す操作。
  /// 端末への永続保存を意味しない。
  Future<void> applyEditorResult(Object? result) async {
    if (!mounted || editorBusy || _editorExitPending) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;

    _editorExitPending = true;

    try {
      await _finishEditorExit(result);
    } finally {
      _editorExitPending = false;
    }
  }

  Future<void> _finishEditorExit(Object? result) async {
    if (!mounted) return;

    final route = ModalRoute.of(context);
    setState(() => _editorExitAllowed = true);

    await WidgetsBinding.instance.endOfFrame;

    if (!mounted) return;

    if (route?.isCurrent != true || !Navigator.of(context).canPop()) {
      setState(() => _editorExitAllowed = false);
      return;
    }

    Navigator.of(context).pop(result);
  }

  @override
  void dispose() {
    for (final input in _trackedEditorInputs) {
      input.removeListener(_onEditorInput);
    }
    _trackedEditorInputs = const [];
    super.dispose();
  }
}
