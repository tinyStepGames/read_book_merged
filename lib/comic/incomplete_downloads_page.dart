import 'package:flutter/material.dart';

import 'services/download_store.dart';
import 'services/saved_download_repository.dart';
import 'sources/source_adapter.dart';

class IncompleteDownloadsPage extends StatefulWidget {
  const IncompleteDownloadsPage({
    super.key,
    required this.adapter,
    required this.store,
  });

  final SourceAdapter adapter;
  final DownloadStore store;

  @override
  State<IncompleteDownloadsPage> createState() =>
      _IncompleteDownloadsPageState();
}

class _IncompleteDownloadsPageState extends State<IncompleteDownloadsPage> {
  List<IncompleteDownload> _items = [];
  bool _busy = true;
  String _status = '未完了データを確認中';

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final items = await widget.store.incompleteDownloads(widget.adapter.id);

      if (!mounted) return;
      final bytes = items.fold<int>(0, (sum, item) => sum + item.bytes);

      setState(() {
        _items = items;
        _status =
            '${items.length}話・${savedSizeLabel(bytes)}\n'
            'この更新後に再開記録を作ったデータが対象';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _status = '一覧を読み込めませんでした：$error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _retry(IncompleteDownload item) async {
    if (_busy || widget.store.hasActiveDownloads) return;

    setState(() {
      _busy = true;
      _status = '${item.chapter.title}\n画像一覧を確認中';
    });

    try {
      // サイト固有処理はアダプターに任せる。
      // URLの変更・期限切れ等にも対応するため一覧を取り直す。
      final content = await widget.adapter.fetchContent(item.chapter);

      await widget.store.download(item.chapter, content, (done, total) {
        if (mounted) {
          setState(() {
            _status =
                '${item.chapter.title}\n'
                '$done / $total ページ（再利用分を含む）';
          });
        }
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('再試行に失敗しました：$error')));
      }
    } finally {
      if (mounted) await _refresh();
    }
  }

  Future<void> _delete(IncompleteDownload item) async {
    if (_busy || widget.store.hasActiveDownloads) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('未完了データを削除'),
        content: Text(
          '${item.chapter.title}\n'
          '${savedSizeLabel(item.bytes)}\n\n'
          'この話の途中データを削除します。\n'
          'お気に入り・履歴・閲覧位置・読了状態は残します。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);

    try {
      await widget.store.deleteIncomplete(item, widget.adapter.id);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('削除できませんでした：$error')));
      }
    } finally {
      if (mounted) await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final statusHeight = (scaler.scale(14) * 1.4 * 2).ceilToDouble() + 20;

    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: const Text('未完了ダウンロード'),
          automaticallyImplyLeading: !_busy,
          actions: [
            IconButton(
              tooltip: '一覧を更新',
              onPressed: _busy
                  ? null
                  : () {
                      setState(() => _busy = true);
                      _refresh();
                    },
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: Column(
          children: [
            SizedBox(
              height: statusHeight,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Tooltip(
                    message: _status,
                    child: Text(
                      _status,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, height: 1.4),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              height: 3,
              child: _busy
                  ? const LinearProgressIndicator(minHeight: 3)
                  : const SizedBox.expand(),
            ),
            Expanded(
              child: _items.isEmpty
                  ? Center(child: Text(_busy ? '確認中…' : '未完了のダウンロードはありません'))
                  : ListView.separated(
                      itemCount: _items.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final item = _items[index];

                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.downloading_outlined),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.chapter.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${item.chapter.language}・'
                                      '画像ファイル '
                                      '${item.savedPages}/${item.totalPages}\n'
                                      '${savedSizeLabel(item.bytes)}'
                                      '・再開時に画像を検証',
                                      style: const TextStyle(
                                        color: Colors.white60,
                                        fontSize: 12,
                                        height: 1.4,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              SizedBox(
                                width: 48,
                                child: IconButton(
                                  tooltip: '再試行',
                                  onPressed: _busy ? null : () => _retry(item),
                                  icon: const Icon(Icons.refresh),
                                ),
                              ),
                              SizedBox(
                                width: 48,
                                child: IconButton(
                                  tooltip: '途中データを削除',
                                  onPressed: _busy ? null : () => _delete(item),
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
