import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'catalog_page.dart';
import 'services/download_store.dart';
import 'sources/peppercarrot_adapter.dart';

/// 漫画タブの画面。
///
/// 保存領域（Application Support/comics）を用意して
/// offline-comic-reader 側の SourceHome を表示する。
///
/// SourceHome は起動時にダウンロード処理などを始めるため、
/// タブの初期構築では読み込まず、ユーザーが開いた時点で初期化する
/// （遅延読み込み。テストやオフライン起動でも安全にするため）。
class ComicTabScreen extends StatefulWidget {
  const ComicTabScreen({super.key});

  @override
  State<ComicTabScreen> createState() => _ComicTabScreenState();
}

class _ComicTabScreenState extends State<ComicTabScreen> {
  bool _started = false;
  Directory? _root;
  String? _error;

  Future<void> _start() async {
    setState(() => _started = true);

    try {
      final support = await getApplicationSupportDirectory();
      final root = Directory(p.join(support.path, 'comics'));
      await root.create(recursive: true);

      if (mounted) {
        setState(() => _root = root);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_started) {
      return Scaffold(
        appBar: AppBar(title: const Text('漫画')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.image, size: 56, color: Colors.white54),
              const SizedBox(height: 16),
              const Text('オフライン漫画リーダー'),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _start,
                icon: const Icon(Icons.open_in_new),
                label: const Text('漫画カタログを開く'),
              ),
            ],
          ),
        ),
      );
    }

    final error = _error;

    if (error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('漫画')),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('保存領域を準備できませんでした。'),
              const SizedBox(height: 8),
              Text(error, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }

    final root = _root;

    if (root == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return SourceHome(
      adapter: PepperCarrotAdapter(),
      store: DownloadStore(root),
    );
  }
}
