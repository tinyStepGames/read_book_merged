import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'sources/source_adapter.dart';

/// 本文とは独立した、サイト共通の表紙キャッシュ。
class _CoverCache {
  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );

  static final Map<String, Future<File?>> _jobs = {};
  static Future<void> _queue = Future<void>.value();

  static Future<File?> load(String url) async {
    final existing = _jobs[url];
    if (existing != null) return existing;

    final task = _queue.then((_) => _download(url));

    // 表紙の通信は順番に実行し、大量の同時アクセスを避ける。
    _queue = task.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );

    _jobs[url] = task;

    try {
      return await task;
    } finally {
      if (identical(_jobs[url], task)) {
        _jobs.remove(url);
      }
    }
  }

  static Future<File?> _download(String rawUrl) async {
    File? temporary;

    try {
      final uri = Uri.parse(rawUrl);

      if (!['https', 'http'].contains(uri.scheme) || uri.host.isEmpty) {
        return null;
      }

      final root = await getApplicationSupportDirectory();
      final folder = Directory(p.join(root.path, 'cover_cache'));
      await folder.create(recursive: true);

      final hash = sha256.convert(utf8.encode(rawUrl)).toString();
      final file = File(p.join(folder.path, '$hash.img'));

      if (await file.exists() && await file.length() > 0) {
        return file;
      }

      temporary = File('${file.path}.part');

      await _dio.download(uri.toString(), temporary.path, deleteOnError: true);

      final codec = await ui.instantiateImageCodec(
        await temporary.readAsBytes(),
        targetWidth: 32,
      );

      try {
        final frame = await codec.getNextFrame();
        frame.image.dispose();
      } finally {
        codec.dispose();
      }

      await temporary.rename(file.path);
      return file;
    } catch (_) {
      return null;
    } finally {
      try {
        if (temporary != null && await temporary.exists()) {
          await temporary.delete();
        }
      } catch (_) {
        // 表紙の片付け失敗で画面操作を止めない。
      }
    }
  }
}

class WorkCover extends StatefulWidget {
  const WorkCover({super.key, required this.url, this.placeholderBuilder});

  final String? url;
  final Widget Function()? placeholderBuilder;

  @override
  State<WorkCover> createState() => _WorkCoverState();
}

class _WorkCoverState extends State<WorkCover> {
  late Future<File?> _future;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void didUpdateWidget(covariant WorkCover oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.url != widget.url) {
      _prepare();
    }
  }

  void _prepare() {
    final url = widget.url;

    _future = url == null || url.isEmpty
        ? Future<File?>.value(null)
        : _CoverCache.load(url);
  }

  Widget _placeholder() =>
      widget.placeholderBuilder?.call() ??
      const ColoredBox(
        color: Color(0xFF252525),
        child: Center(
          child: Icon(Icons.menu_book_outlined, color: Colors.white38),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: FutureBuilder<File?>(
        future: _future,
        builder: (context, snapshot) {
          final file = snapshot.data;

          if (file == null) return _placeholder();

          return Image.file(
            file,
            width: double.infinity,
            height: double.infinity,
            fit: BoxFit.cover,
            errorBuilder: (_, error, stack) => _placeholder(),
          );
        },
      ),
    );
  }
}

/// 作品一覧・お気に入りで共用する、画面幅に応じたグリッド。
class CoverGrid<T> extends StatelessWidget {
  const CoverGrid({
    super.key,
    required this.items,
    required this.workOf,
    required this.onOpen,
    this.subtitleOf,
    this.badgeBuilder,
    this.placeholderBuilder,
  });

  final List<T> items;
  final ComicWork Function(T item) workOf;
  final void Function(T item) onOpen;
  final String Function(T item)? subtitleOf;
  final Widget Function(T item)? badgeBuilder;
  final Widget Function()? placeholderBuilder;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final int columns;

        if (width < 330) {
          columns = 2;
        } else if (width < 600) {
          columns = 3;
        } else {
          columns = (width / 170).floor().clamp(3, 8).toInt();
        }

        const gap = 10.0;
        final cardWidth = (width - 20 - gap * (columns - 1)) / columns;

        final scaler = MediaQuery.textScalerOf(context);
        final titleHeight = (scaler.scale(14) * 1.4 * 2).ceilToDouble() + 4;
        final subtitleHeight = subtitleOf == null
            ? 0.0
            : (scaler.scale(12) * 1.5).ceilToDouble() + 8;

        final height =
            (cardWidth * 1.5 + 6 + titleHeight + subtitleHeight)
                .ceilToDouble() +
            8;

        return GridView.builder(
          padding: const EdgeInsets.all(10),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: gap,
            mainAxisSpacing: 16,
            mainAxisExtent: height,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            final work = workOf(item);

            return Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => onOpen(item),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: cardWidth * 1.5,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          WorkCover(
                            url: work.thumbnail,
                            placeholderBuilder: placeholderBuilder,
                          ),
                          if (badgeBuilder != null)
                            Positioned(
                              top: 2,
                              right: 2,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.black87,
                                  borderRadius: BorderRadius.circular(24),
                                ),
                                child: badgeBuilder!(item),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: titleHeight,
                      child: Text(
                        work.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          height: 1.25,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    if (subtitleOf != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitleOf!(item),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          height: 1.3,
                          color: Colors.white54,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}
