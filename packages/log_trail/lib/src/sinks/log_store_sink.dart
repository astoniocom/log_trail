import 'dart:async';

import 'package:log_trail/src/diagnostics/log_diagnostic.dart';
import 'package:log_trail/src/entry/log_entry.dart';
import 'package:log_trail/src/entry/log_tags.dart';
import 'package:log_trail/src/entry/overflow_warning.dart';
import 'package:log_trail/src/sinks/log_sink.dart';
import 'package:log_trail/src/storage/log_store.dart';
import 'package:log_trail/src/util/bounded_queue.dart';

/// Handler for a failed write of the batch [entries] to the store.
typedef LogWriteErrorHandler = void Function(Object error, StackTrace stackTrace, List<LogEntry> entries);

/// A sink that persists entries to [store].
///
/// Entries are written in batches in arrival order, one [LogStore.writeEntries]
/// at a time: a write starts at the end of the root's dispatch ([endBatch])
/// if the store is idle, otherwise right after the current write. A fatal
/// entry the root dispatches inside the logger call therefore reaches a
/// synchronous store before `log` returns, if the store is not busy. A batch
/// holds at most [maxBatchSize] entries, so a synchronous store never blocks
/// the isolate for a thousand-entry transaction; the rest follows in later
/// batches with the event loop yielded between them.
///
/// The queue is bounded by [queueLimit]: if the store cannot keep up, the
/// oldest waiting entries are dropped and the next batch carries a warning
/// with their count ([storageLogTag]). [flush] waits for the entries accepted
/// before the call; [close] waits for everything accepted. The sink does not
/// own the store, which the application reads concurrently and closes itself
/// after the logger:
///
/// ```dart
/// logger.addSink(RepeatCollapsingSink(LogStoreSink(store)));
/// // …
/// await logger.close(); // waits until everything accepted is written
/// await store.close();
/// ```
final class LogStoreSink extends LogSink {
  LogStoreSink(this.store, {this.queueLimit = 1000, this.maxBatchSize = 100, this.onWriteError})
    : assert(queueLimit > 0, 'queueLimit must be positive'),
      assert(maxBatchSize > 0, 'maxBatchSize must be positive');

  final LogStore store;

  @override
  String get name => 'LogStoreSink';

  /// Maximum number of entries waiting for the store. On overflow the oldest
  /// are dropped: with a looping error the latest events matter more. The
  /// limit is mandatory: a hung or slow store would otherwise eat memory while
  /// the app keeps logging.
  final int queueLimit;

  /// Maximum number of entries in one [LogStore.writeEntries] call (the
  /// overflow warning does not count). For a synchronous store this bounds how
  /// long one transaction blocks the isolate; smaller means shorter blocking
  /// but more transactions.
  final int maxBatchSize;

  /// Called when the store failed to persist a batch; without it the failure
  /// goes to [diagnostics], like queue overflow and a failure of the handler
  /// itself. Entries from the batch are not retried.
  ///
  /// Do not log from here into the logger this sink is attached to: with a
  /// broken store the failure would produce new entries and new failures.
  final LogWriteErrorHandler? onWriteError;

  /// Entries accepted and not yet handed to the store.
  late final BoundedQueue<LogEntry> _queue = BoundedQueue(
    limit: queueLimit,
    // The store is unresponsive, so the warning may never appear in it: report directly too.
    onOverflow: () => diagnostics.report(
      const LogDiagnostic('LogStoreSink: queue overflow, the store is not keeping up; oldest entries are dropped'),
    ),
  );

  /// The queue write in progress; `null` when the store is idle.
  Future<void>? _draining;

  /// How many entries were accepted in total.
  int _accepted = 0;

  /// How many accepted entries reached an outcome: handed to the store
  /// (persisted or passed to [onWriteError]) or dropped on overflow.
  /// [flush] waits until all entries accepted before it get here.
  int _settled = 0;

  /// Completes when the next batch has been handed to the store, then is replaced.
  Completer<void> _batchCompleted = Completer<void>();

  /// Whether a write is scheduled for the end of the current task (in case
  /// nobody reports the end of batch).
  bool _isDrainScheduled = false;

  @override
  void onAdd(LogEntry entry) {
    final lengthBefore = _queue.length;
    _queue.add(entry);
    _accepted++;
    // The queue did not grow: the oldest entry was dropped, its outcome is known.
    if (_queue.length == lengthBefore) _settled++;
    if (_isDrainScheduled) return;
    _isDrainScheduled = true;
    scheduleMicrotask(() {
      _isDrainScheduled = false;
      _startDraining();
    });
  }

  @override
  void onBatchEnd() => _startDraining();

  /// Starts writing the queue if it is not empty and no write is in progress.
  /// If a write is in progress and yielding the event loop between batches
  /// ([_yielding]), interrupts the yield: the root dispatched a new batch,
  /// possibly a fatal inside the logger call, and it must not wait for a frame.
  void _startDraining() {
    if (_draining != null) {
      final yielding = _yielding;
      if (yielding != null && !yielding.isCompleted) yielding.complete();
      return;
    }
    if (_queue.isEmpty) return;
    _draining = _drain().whenComplete(_onDrainEnded);
  }

  /// The event-loop yield in progress between batches; `null` if there is none.
  Completer<void>? _yielding;

  /// How much synchronous work in a [LogStore.writeEntries] call counts as
  /// blocking the isolate, after which the event loop should be given to a
  /// frame before the next batch. An asynchronous store (in a background
  /// isolate) returns faster: it only hands the batch over.
  static const Duration _blockingWrite = Duration(milliseconds: 1);

  Future<void> _drain() async {
    while (_queue.isNotEmpty) {
      final lengthBefore = _queue.length;
      final batch = _queue.takeWithOverflowWarning(
        tag: storageLogTag,
        message: (dropped) => 'Log store queue overflow: $dropped entry(ies) dropped',
        limit: maxBatchSize,
      );
      final taken = lengthBefore - _queue.length;
      final blocked = Stopwatch()..start();
      try {
        // A synchronous store does the whole write inside the call, before the await.
        final writing = store.writeEntries(batch);
        blocked.stop();
        await writing;
      } on Object catch (error, stack) {
        blocked.stop();
        _reportWriteError(error, stack, batch);
      }
      _settled += taken;
      _signalBatchCompleted();
      if (_queue.isNotEmpty && blocked.elapsed >= _blockingWrite) await _yieldToEventLoop();
    }
  }

  /// Gives up the event loop until the next turn so a frame can render between
  /// synchronous transactions; [_startDraining] may cut the wait short.
  Future<void> _yieldToEventLoop() {
    final yielding = _yielding = Completer<void>();
    Timer.run(() {
      if (!yielding.isCompleted) yielding.complete();
    });
    return yielding.future.whenComplete(() => _yielding = null);
  }

  void _onDrainEnded() {
    _draining = null;
    // Pending flushes must wake up and see there is nothing left to write.
    _signalBatchCompleted();
  }

  void _signalBatchCompleted() {
    final completed = _batchCompleted;
    _batchCompleted = Completer<void>();
    completed.complete();
  }

  /// A write failure must not escape to the zone as an unhandled error: from
  /// there it would reach `PlatformDispatcher.onError` → `recordError` → the store again.
  void _reportWriteError(Object error, StackTrace stack, List<LogEntry> entries) {
    final onWriteError = this.onWriteError;
    try {
      if (onWriteError != null) {
        onWriteError(error, stack, entries);
        return;
      }
    } on Object catch (handlerError, handlerStack) {
      // A failure of the handler itself must not escape to the zone either.
      diagnostics.report(
        LogDiagnostic('LogStoreSink: onWriteError failed', error: handlerError, stackTrace: handlerStack),
      );
    }
    diagnostics.report(
      LogDiagnostic(
        'LogStoreSink: the store failed to write ${entries.length} entries',
        error: error,
        stackTrace: stack,
      ),
    );
  }

  /// Starts writing what accumulated, if not already in progress, and waits
  /// until entries accepted before this call are handed to the store
  /// (persisted or passed to [onWriteError]) or dropped on overflow, however
  /// many batches that takes. Does not wait for entries accepted later:
  /// otherwise, with continuous logging faster than the store writes, it would
  /// never complete.
  @override
  Future<void> onFlush() async {
    _startDraining();
    final target = _accepted;
    while (_settled < target && _draining != null) {
      await _batchCompleted.future;
    }
  }

  /// After [close] there are no new entries, so waits for the whole queue to
  /// be written. Does not close [store]: the app owns it.
  @override
  Future<void> onClose() async {
    _startDraining();
    if (_draining case final draining?) await draining;
  }
}
