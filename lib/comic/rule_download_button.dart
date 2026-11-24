import 'services/rule_video_support.dart';
import 'package:flutter/material.dart';

import 'services/rule_browse_client.dart';
import 'services/rule_downloads.dart';
import 'services/site_rule_store.dart';
import 'sources/source_adapter.dart';

class RuleDownloadButton extends StatefulWidget {
  const RuleDownloadButton({
    super.key,
    required this.site,
    required this.chapter,
    required this.workTitle,
    required this.renderedFetcher,
  });

  final SavedSiteRule site;
  final ComicChapter chapter;
  final String workTitle;
  final RenderedRulePageFetcher renderedFetcher;

  @override
  State<RuleDownloadButton> createState() => _RuleDownloadButtonState();
}

class _RuleDownloadButtonState extends State<RuleDownloadButton> {
  RuleDownloads? _downloads;
  bool _saved = false;
  bool _checking = true;
  String? _error;
  int _readGeneration = 0;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  Future<void> _attach() async {
    if (usesRuleVideo(widget.site)) return;
    try {
      final downloads = await RuleDownloads.open();
      if (!mounted) return;
      _downloads = downloads;
      downloads.state.addListener(_changed);
      await _refresh();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _error = error.toString();
      });
    }
  }

  @override
  void didUpdateWidget(covariant RuleDownloadButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chapter.storageId != widget.chapter.storageId) {
      _saved = false;
      _checking = true;
      _error = null;
      _refresh();
    }
  }

  Future<void> _refresh() async {
    final downloads = _downloads;
    if (downloads == null) return;

    final generation = ++_readGeneration;

    try {
      final files = await downloads.files(widget.chapter);
      if (!mounted || generation != _readGeneration) return;

      setState(() {
        _saved = files.isNotEmpty;
        _checking = false;
      });
    } catch (error) {
      if (!mounted || generation != _readGeneration) return;
      setState(() {
        _saved = false;
        _checking = false;
        _error = error.toString();
      });
    }
  }

  void _changed() {
    final downloads = _downloads;
    if (!mounted || downloads == null) return;

    final current = downloads.state.value;
    final mine = current.chapterId == widget.chapter.storageId;

    if (mine && !current.running) {
      _error = current.failed ? current.message : null;
      _refresh();
    }

    // 他の話が保存中の場合も、重複開始を防ぐため状態を更新する。
    setState(() {});
  }

  @override
  void dispose() {
    _readGeneration++;
    _downloads?.state.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (usesRuleVideo(widget.site)) return const SizedBox.shrink();
    final downloads = _downloads;
    final current = downloads?.state.value;
    final mine = current?.chapterId == widget.chapter.storageId;
    final active = mine && current?.running == true;
    final busy = downloads?.isBusy ?? false;

    final String tooltip;
    if (active) {
      tooltip = '${current!.message}\n押すと中断';
    } else if (_saved) {
      tooltip = '保存済み';
    } else if (widget.site.images == null) {
      tooltip = '本文画像ルールが未設定です';
    } else if (busy) {
      tooltip = '別の話を保存中です';
    } else {
      tooltip = _error == null ? 'ダウンロード' : '再試行できます\n$_error';
    }

    return SizedBox(
      width: 48,
      height: 48,
      child: IconButton(
        tooltip: tooltip,
        onPressed: active
            ? downloads!.stop
            : downloads == null ||
                  _checking ||
                  _saved ||
                  busy ||
                  widget.site.images == null
            ? null
            : () {
                _error = null;
                downloads.save(
                  site: widget.site,
                  chapter: widget.chapter,
                  workTitle: widget.workTitle,
                  renderedFetcher: widget.renderedFetcher,
                );
              },
        icon: active
            ? SizedBox(
                width: 28,
                height: 28,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox.expand(
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: current!.total > 0
                            ? current.done / current.total
                            : null,
                      ),
                    ),
                    const Icon(Icons.pause, size: 16),
                  ],
                ),
              )
            : Icon(
                _saved
                    ? Icons.download_done
                    : _error != null
                    ? Icons.refresh
                    : Icons.download_outlined,
                color: _saved ? Colors.tealAccent : null,
              ),
      ),
    );
  }
}
