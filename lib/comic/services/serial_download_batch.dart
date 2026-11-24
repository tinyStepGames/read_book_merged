import 'package:flutter/foundation.dart';

class SerialBatchState {
  const SerialBatchState({
    this.scope = '',
    this.running = false,
    this.stopping = false,
    this.stopped = false,
    this.total = 0,
    this.saved = 0,
    this.skipped = 0,
    this.currentTitle = '',
    this.failures = const [],
  });

  final String scope;
  final bool running;
  final bool stopping;
  final bool stopped;
  final int total;
  final int saved;
  final int skipped;
  final String currentTitle;
  final List<String> failures;

  int get processed => saved + skipped + failures.length;

  SerialBatchState copyWith({
    bool? running,
    bool? stopping,
    bool? stopped,
    int? saved,
    int? skipped,
    String? currentTitle,
    List<String>? failures,
  }) {
    return SerialBatchState(
      scope: scope,
      total: total,
      running: running ?? this.running,
      stopping: stopping ?? this.stopping,
      stopped: stopped ?? this.stopped,
      saved: saved ?? this.saved,
      skipped: skipped ?? this.skipped,
      currentTitle: currentTitle ?? this.currentTitle,
      failures: List<String>.unmodifiable(failures ?? this.failures),
    );
  }
}

class SerialDownloadBatch<T> {
  final state = ValueNotifier<SerialBatchState>(const SerialBatchState());

  bool _stopRequested = false;

  void stop() {
    if (!state.value.running) return;
    _stopRequested = true;
    state.value = state.value.copyWith(stopping: true);
  }

  Future<void> run(
    Iterable<T> source, {
    required String scope,
    required String Function(T) keyOf,
    required String Function(T) titleOf,
    required Future<bool> Function(T) isSaved,
    required Future<void> Function(T) save,
  }) async {
    if (state.value.running) {
      throw StateError('一括保存はすでに実行中です');
    }

    final seen = <String>{};
    final tasks = source.where((item) => seen.add(keyOf(item))).toList();

    _stopRequested = false;
    state.value = SerialBatchState(
      scope: scope,
      running: true,
      total: tasks.length,
    );

    try {
      for (final item in tasks) {
        if (_stopRequested) break;

        final title = titleOf(item);
        state.value = state.value.copyWith(currentTitle: title);

        try {
          final existing = await isSaved(item);
          if (_stopRequested) break;

          if (existing) {
            state.value = state.value.copyWith(
              skipped: state.value.skipped + 1,
            );
            continue;
          }

          await save(item);

          // 停止と完了が重なっても、保存が成功した話は数える。
          state.value = state.value.copyWith(saved: state.value.saved + 1);
        } catch (error) {
          // ユーザーの中断は保存失敗として数えない。
          if (_stopRequested) break;

          state.value = state.value.copyWith(
            failures: [...state.value.failures, '$title：$error'],
          );
        }
      }
    } finally {
      state.value = state.value.copyWith(
        running: false,
        stopping: false,
        stopped: _stopRequested && state.value.processed < state.value.total,
        currentTitle: '',
      );
    }
  }
}
