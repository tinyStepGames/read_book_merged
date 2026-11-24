import 'package:flutter/material.dart';

import 'saved_video_player_page.dart';
import 'services/download_store.dart';
import 'services/saved_video_record.dart';
import 'services/video_download_engine.dart';
import 'video_download_page.dart';

class SavedVideosPage extends StatefulWidget {
  const SavedVideosPage({super.key, required this.store});

  final DownloadStore store;

  @override
  State<SavedVideosPage> createState() => _SavedVideosPageState();
}

class _SavedVideosPageState extends State<SavedVideosPage> {
  late final VideoDownloadRepository _repository;
  List<SavedVideoPackage> _videos = [];
  List<String> _issues = [];
  bool _busy = false;
  String _status = '保存動画を確認中';

  @override
  void initState() {
    super.initState();
    _repository = VideoDownloadRepository(widget.store.root);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh();
    });
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() => _busy = true);

    try {
      final result = await _repository.scan();
      final videos = <SavedVideoPackage>[];
      final issues = List<String>.of(result.issues);

      for (final video in result.videos) {
        try {
          SavedVideoRecord.forPackage(video);
          videos.add(video);
        } catch (error) {
          issues.add('${video.title}：$error');
        }
      }

      if (!mounted) return;
      setState(() {
        _videos = videos;
        _issues = issues;
        _status =
            '${videos.length}話・'
            '${savedVideoSize(videos.fold<int>(0, (sum, v) => sum + savedVideoBytes(v)))}'
            '${issues.isEmpty ? '' : '・確認事項${issues.length}件'}';
      });
    } catch (error) {
      if (mounted) setState(() => _status = '一覧を開けませんでした：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(SavedVideoPackage video) async {
    if (_busy) return;

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            SavedVideoPlayerPage(store: widget.store, videoId: video.id),
      ),
    );

    if (mounted) await _refresh();
  }

  Future<void> _delete(SavedVideoPackage video) async {
    if (_busy) return;

    if (VideoDownloadPage.isActive) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('動画保存画面を閉じてから削除してください。')));
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('保存動画を削除'),
        content: Text(
          '${video.title}\n${savedVideoSize(savedVideoBytes(video))}\n\n'
          'この話の保存動画だけを削除します。\n'
          '画像・サイト設定・お気に入り・履歴・再生位置は残します。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('削除する'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await _repository.delete(video.id);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('削除できませんでした：$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }

    if (mounted) await _refresh();
  }

  void _showIssues() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('保存動画の確認事項'),
        content: SingleChildScrollView(
          child: SelectableText(_issues.join('\n\n')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('保存済み動画'),
      actions: [
        IconButton(
          tooltip: '確認事項',
          onPressed: _busy || _issues.isEmpty ? null : _showIssues,
          icon: const Icon(Icons.info_outline),
        ),
        IconButton(
          tooltip: '一覧を更新',
          onPressed: _busy ? null : _refresh,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(padding: const EdgeInsets.all(12), child: Text(_status)),
        SizedBox(
          height: 3,
          child: _busy
              ? const LinearProgressIndicator()
              : const SizedBox.expand(),
        ),
        Expanded(
          child: _videos.isEmpty
              ? const Center(child: Text('保存済みの動画はありません'))
              : ListView.builder(
                  itemCount: _videos.length,
                  itemBuilder: (context, index) {
                    final video = _videos[index];
                    final record = SavedVideoRecord.forPackage(video);

                    return ListTile(
                      leading: const Icon(Icons.video_file_outlined),
                      title: Text(video.title),
                      subtitle: Text(
                        '${record.workTitle}\n'
                        '${record.siteName}・${savedVideoSize(savedVideoBytes(video))}',
                      ),
                      isThreeLine: true,
                      onTap: _busy ? null : () => _open(video),
                      trailing: IconButton(
                        tooltip: 'この保存動画を削除',
                        onPressed: _busy ? null : () => _delete(video),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    );
                  },
                ),
        ),
      ],
    ),
  );
}
