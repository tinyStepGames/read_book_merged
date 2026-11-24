import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'reading_progress.dart';
import 'reader_page_counter.dart';
import 'reader_horizontal_pager.dart';
import 'reader_network_image.dart';
import 'services/reader_look_ahead.dart';

enum ReadingMode { vertical, horizontal }

/// 取得元に依存しない、共通の画像リーダー。
class ReaderPage extends StatefulWidget {
  const ReaderPage({
    super.key,
    required this.files,
    this.title = '漫画リーダー',
    this.imageUrls = const [],
    this.progressKey,
    this.onPreviousChapter,
    this.onNextChapter,
    this.chapterStateAction,
    this.onOpened,
  });

  final List<File> files;
  final List<Uri> imageUrls;
  final String title;
  final ReadingKey? progressKey;
  final VoidCallback? onPreviousChapter;
  final VoidCallback? onNextChapter;
  final Widget? chapterStateAction;

  /// 本文画像を一度表示したことを通知する。
  /// 最後まで読んだことを意味するものではない。
  final VoidCallback? onOpened;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> with WidgetsBindingObserver {
  // 起動中は、話ごとの古い設定より直近の読み方を優先する。
  static ReadingMode? _sessionReadingMode;
  final ItemScrollController _verticalController = ItemScrollController();

  final ItemPositionsListener _positions = ItemPositionsListener.create();

  PageController? _horizontalController;
  Timer? _saveTimer;

  late final ReaderLookAhead _lookAhead;
  final Set<int> _networkReady = <int>{};

  // 初回表示までは、復元した現在ページの画像を優先する。
  // 画面外の先読みは既存のReaderLookAheadに任せる。
  bool _initialNetworkImageReady = false;
  final Stopwatch _readerOpenClock = Stopwatch()..start();

  int get _readerDecodeWidth {
    final media = MediaQuery.maybeOf(context);
    final pixels = media == null
        ? 1080.0
        : media.size.width * media.devicePixelRatio;
    return pixels.round().clamp(1, 1800).toInt();
  }

  ImageProvider<Object> _networkProvider(
    int index, {
    bool fullResolution = false,
  }) {
    final original = NetworkImage(widget.imageUrls[index].toString());
    if (fullResolution) return original;

    return ResizeImage.resizeIfNeeded(_readerDecodeWidth, null, original);
  }

  void _updateLookAhead() {
    if (!mounted ||
        !_ready ||
        widget.imageUrls.isEmpty ||
        !_networkReady.contains(_index)) {
      _lookAhead.update(const <int>[]);
      return;
    }

    final targets = <int>[];
    for (var offset = 1; offset <= 2; offset++) {
      final target = _index + offset;
      if (target < widget.imageUrls.length) {
        targets.add(target);
      }
    }
    _lookAhead.update(targets);
  }

  bool _chapterOpenedNotified = false;

  void _notifyChapterOpened() {
    if (_chapterOpenedNotified) return;
    _chapterOpenedNotified = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onOpened?.call();
    });
  }

  void _onNetworkReady(int index) {
    if (!mounted) return;

    _networkReady.add(index);

    if (index == _index) {
      _notifyChapterOpened();

      if (!_initialNetworkImageReady) {
        setState(() {
          _initialNetworkImageReady = true;
        });

        assert(() {
          debugPrint(
            '[reader-image] '
            'first_active_frame=${_readerOpenClock.elapsedMilliseconds}ms '
            'page=${index + 1} '
            'count=$_count',
          );
          return true;
        }());
      }

      _updateLookAhead();
    }
  }

  ReadingMode _mode = ReadingMode.vertical;
  bool _controlsVisible = false;
  bool _ready = false;
  bool _saveFailed = false;

  int _index = 0;
  int _verticalStart = 0;

  int get _count => widget.imageUrls.isNotEmpty
      ? widget.imageUrls.length
      : widget.files.length;

  @override
  void initState() {
    super.initState();

    _lookAhead = ReaderLookAhead(
      load: (index) async {
        if (!mounted || index >= widget.imageUrls.length) return;

        // 画面表示と同じ画像キーでキャッシュする。
        // エラーは先読みだけで処理し、読書画面全体を失敗にしない。
        var failed = false;
        await precacheImage(
          _networkProvider(index),
          context,
          onError: (Object error, StackTrace? stack) {
            failed = true;
          },
        );

        if (mounted && !failed) {
          _networkReady.add(index);
        }
      },
    );
    WidgetsBinding.instance.addObserver(this);
    _positions.itemPositions.addListener(_onVisibleItemsChanged);
    _restore();
  }

  Future<void> _restore() async {
    final restoreClock = Stopwatch()..start();
    ReadingProgress? saved;

    final key = widget.progressKey;
    if (key != null && _count > 0) {
      saved = await ReadingProgressStore.instance.load(key);
    }

    if (!mounted) return;

    if (saved != null && _count > 0) {
      // 画像数が変わっていても、存在する範囲に収める。
      _index = saved.pageIndex.clamp(0, _count - 1).toInt();
    }

    _mode =
        _sessionReadingMode ??
        (saved?.mode == 'horizontal'
            ? ReadingMode.horizontal
            : ReadingMode.vertical);

    _sessionReadingMode ??= _mode;

    _verticalStart = _index;
    _horizontalController = PageController(
      initialPage: _index,
      keepPage: false,
    );

    setState(() => _ready = true);

    assert(() {
      debugPrint(
        '[reader-state] '
        'restore=${restoreClock.elapsedMilliseconds}ms '
        'page=${_index + 1} '
        'count=$_count '
        'mode=${_mode.name}',
      );
      return true;
    }());
  }

  void _onVisibleItemsChanged() {
    if (!_ready || _mode != ReadingMode.vertical) return;

    final visible =
        _positions.itemPositions.value
            .where(
              (item) => item.itemTrailingEdge > 0 && item.itemLeadingEdge < 1,
            )
            .toList()
          ..sort((a, b) => a.index.compareTo(b.index));

    if (visible.isNotEmpty) {
      final offset = _hasChapterNavigation ? 1 : 0;
      final pageItems = visible.where(
        (item) => item.index >= offset && item.index < _count + offset,
      );

      if (pageItems.isNotEmpty) {
        _setIndex(pageItems.first.index - offset);
      }
    }
  }

  void _setIndex(int index) {
    if (index == _index || index < 0 || index >= _count) return;

    setState(() => _index = index);
    _updateLookAhead();
    _scheduleSave();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 450), _saveNow);
  }

  void _saveNow() {
    _saveTimer?.cancel();

    final key = widget.progressKey;
    if (!_ready || key == null || _count == 0) return;

    final progress = ReadingProgress(
      pageIndex: _index,
      pageCount: _count,
      mode: _mode.name,
      updatedAt: DateTime.now(),
    );

    unawaited(
      ReadingProgressStore.instance
          .save(key, progress)
          .then(
            (_) {
              if (mounted && _saveFailed) {
                setState(() => _saveFailed = false);
              }
            },
            onError: (Object error, StackTrace stackTrace) {
              if (mounted) {
                setState(() => _saveFailed = true);
              }
            },
          ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _saveNow();
    }
  }

  @override
  void dispose() {
    _lookAhead.dispose();
    _saveNow();
    _saveTimer?.cancel();
    _positions.itemPositions.removeListener(_onVisibleItemsChanged);
    WidgetsBinding.instance.removeObserver(this);
    _horizontalController?.dispose();
    super.dispose();
  }

  void _changeMode(ReadingMode next) {
    _sessionReadingMode = next;
    if (_mode == next) return;

    if (next == ReadingMode.horizontal) {
      // 縦読み中なので、このコントローラーは画面に接続されていない。
      _horizontalController?.dispose();
      _horizontalController = PageController(
        initialPage: _index,
        keepPage: false,
      );
    } else {
      _verticalStart = _index;
    }

    setState(() => _mode = next);
    _saveNow();
  }

  void _move(int offset) {
    final target = _index + offset;
    final controller = _horizontalController;

    if (target < 0 ||
        target >= _count ||
        controller == null ||
        !controller.hasClients) {
      return;
    }

    controller.animateToPage(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  Widget _imageError(
    BuildContext context,
    Object error,
    StackTrace? stackTrace,
  ) {
    return const SizedBox(
      height: 240,
      child: Center(
        child: Text(
          '画像を開けません。\n通信状態または保存データを確認してください。',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white70),
        ),
      ),
    );
  }

  Widget _image(
    int index, {
    double? width,
    BoxFit fit = BoxFit.contain,
    bool fullResolution = false,
  }) {
    if (widget.imageUrls.isEmpty) {
      return Image.file(
        widget.files[index],
        width: width,
        fit: fit,
        frameBuilder: (context, child, frame, synchronouslyLoaded) {
          if (index == _index && (synchronouslyLoaded || frame != null)) {
            _notifyChapterOpened();
          }
          return child;
        },
        errorBuilder: _imageError,
      );
    }

    // 読み始める画像が表示されるまでは、
    // 別ページの通常表示用リクエストを開始しない。
    // 拡大表示は明示的な操作なので、この制限の対象外とする。
    if (!fullResolution && !_initialNetworkImageReady && index != _index) {
      return SizedBox(
        width: width,
        height: 240,
        child: const ColoredBox(color: Colors.black),
      );
    }

    return ReaderNetworkImage(
      provider: _networkProvider(index, fullResolution: fullResolution),
      width: width,
      fit: fit,
      onReady: fullResolution ? null : () => _onNetworkReady(index),
    );
  }

  void _zoom(int index) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(title: Text('拡大表示 ${index + 1} / $_count')),
          body: SafeArea(
            child: SizedBox.expand(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 5,
                child: Center(child: _image(index, fullResolution: true)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool get _hasChapterNavigation =>
      widget.onPreviousChapter != null || widget.onNextChapter != null;

  Widget _chapterNavigation({bool overlay = false}) {
    if (!_hasChapterNavigation) {
      return const SizedBox.shrink();
    }

    return SizedBox(
      height: 64,
      child: Material(
        color: overlay ? Colors.black54 : Colors.black,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: widget.onPreviousChapter == null
                      ? null
                      : () {
                          _saveNow();
                          widget.onPreviousChapter!();
                        },
                  icon: const Icon(Icons.skip_previous),
                  label: const Text('前の話'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: widget.onNextChapter == null
                      ? null
                      : () {
                          _saveNow();
                          widget.onNextChapter!();
                        },
                  icon: const Icon(Icons.skip_next),
                  label: const Text('次の話'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _verticalReader() {
    final offset = _hasChapterNavigation ? 1 : 0;

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: ScrollablePositionedList.builder(
            initialScrollIndex: _verticalStart + offset,
            itemScrollController: _verticalController,
            itemPositionsListener: _positions,
            padding: EdgeInsets.zero,
            itemCount: _count + offset * 2,
            itemBuilder: (context, itemIndex) {
              if (_hasChapterNavigation &&
                  (itemIndex == 0 || itemIndex == _count + 1)) {
                return _chapterNavigation();
              }

              final index = itemIndex - offset;

              return GestureDetector(
                onDoubleTap: () => _zoom(index),
                child: _image(
                  index,
                  width: double.infinity,
                  fit: BoxFit.fitWidth,
                ),
              );
            },
          ),
        ),

        // Vertical chapter navigation overlay
        // 途中のページでも、操作表示中は話移動ボタンを重ねる。
        // スクロール領域のサイズや余白は変更しない。
        if (_controlsVisible && _hasChapterNavigation)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _chapterNavigation(overlay: true),
          ),
      ],
    );
  }

  Widget _horizontalReader() {
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: ReaderHorizontalPager(
            controller: _horizontalController!,
            itemCount: _count,
            onPageChanged: _setIndex,
            onPrevious: _index > 0 ? () => _move(-1) : null,
            onNext: _index < _count - 1 ? () => _move(1) : null,
            onToggleControls: () {
              setState(() {
                _controlsVisible = !_controlsVisible;
              });
            },
            onZoom: _zoom,
            imageBuilder: (context, index) => _image(index),
          ),
        ),

        // 下端のページ送り操作と重ならない位置に表示する。
        // Positionedなので画像の表示領域は変化しない。
        if (_controlsVisible && _hasChapterNavigation)
          Positioned(
            left: 0,
            right: 0,
            bottom: 64,
            child: _chapterNavigation(overlay: true),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(backgroundColor: Colors.black);
    }

    final showControls = _controlsVisible || _count == 0;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () {
                  setState(() {
                    _controlsVisible = !_controlsVisible;
                  });
                },
                child: _count == 0
                    ? const Center(
                        child: Text(
                          '保存された画像がありません',
                          style: TextStyle(color: Colors.white),
                        ),
                      )
                    : _mode == ReadingMode.vertical
                    ? _verticalReader()
                    : _horizontalReader(),
              ),
            ),
            if (showControls)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Material(
                  color: Colors.black87,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            IconButton(
                              tooltip: '一覧に戻る',
                              onPressed: () {
                                _saveNow();
                                Navigator.of(context).maybePop();
                              },
                              icon: const Icon(Icons.arrow_back),
                            ),
                            Expanded(
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      widget.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                      ),
                                    ),
                                  ),
                                  if (_count > 0) ...[
                                    const SizedBox(width: 8),
                                    Flexible(
                                      child: ReaderPageCounter(
                                        current: _index + 1,
                                        total: _count,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            if (widget.chapterStateAction != null)
                              widget.chapterStateAction!,
                            IconButton(
                              tooltip: '操作部分を隠す',
                              onPressed: () {
                                setState(() {
                                  _controlsVisible = false;
                                });
                              },
                              icon: const Icon(Icons.visibility_off_outlined),
                            ),
                          ],
                        ),
                        SegmentedButton<ReadingMode>(
                          segments: const [
                            ButtonSegment(
                              value: ReadingMode.vertical,
                              icon: Icon(Icons.swap_vert),
                              label: Text('縦読み'),
                            ),
                            ButtonSegment(
                              value: ReadingMode.horizontal,
                              icon: Icon(Icons.swap_horiz),
                              label: Text('横読み'),
                            ),
                          ],
                          selected: {_mode},
                          onSelectionChanged: (selection) {
                            _changeMode(selection.first);
                          },
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _saveFailed
                              ? '閲覧位置を保存できませんでした'
                              : widget.progressKey == null
                              ? 'この呼び出しでは閲覧位置の保存は無効です'
                              : '閲覧位置を自動保存します',
                          style: TextStyle(
                            color: _saveFailed
                                ? Colors.redAccent
                                : Colors.white60,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (showControls && _mode == ReadingMode.horizontal && _count > 0)
              Positioned(
                bottom: _hasChapterNavigation ? 64 : 0,
                left: 0,
                right: 0,
                child: ColoredBox(
                  color: Colors.black87,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        tooltip: '前のページ',
                        onPressed: _index > 0 ? () => _move(-1) : null,
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Text(
                        '${_index + 1} / $_count',
                        style: const TextStyle(color: Colors.white),
                      ),
                      IconButton(
                        tooltip: '次のページ',
                        onPressed: _index < _count - 1 ? () => _move(1) : null,
                        icon: const Icon(Icons.chevron_right),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
