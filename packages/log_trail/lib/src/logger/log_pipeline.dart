import 'package:log_trail/src/diagnostics/log_diagnostic.dart';
import 'package:log_trail/src/entry/log_entry.dart';
import 'package:log_trail/src/logger/log_dispatch_policy.dart';
import 'package:log_trail/src/logger/log_processor.dart';
import 'package:log_trail/src/logger/startup_buffer.dart';
import 'package:log_trail/src/sinks/deferred_queue.dart';
import 'package:log_trail/src/sinks/fan_out_sink.dart';
import 'package:log_trail/src/sinks/log_sink.dart';
import 'package:meta/meta.dart';

/// Everything that happens to a built entry: the `RootLogger` dispatch
/// pipeline. [accept] queues the entry per [dispatch] ([DeferredQueue]); a
/// dispatched entry passes the [processors] in order, enters the startup
/// buffer ([StartupBuffer]) and goes to every sink ([FanOutSink]). The
/// pipeline owns the sinks and processors with their lifecycle ([addSink],
/// [addProcessor], [flush], [close]); the root owns the pipeline.
///
/// Building an entry (thresholds, context, stack capture) is the root's job
/// and stays in the logging call; the pipeline never sees a `LogCall`. The
/// root checks the closed state before building ([isClosed]) and reports the
/// drop; the pipeline assumes an accepted entry may be dispatched.
///
/// The pipeline is the one place that guards against logging from inside
/// itself ([accept] while a dispatch is running), whether a processor, a sink
/// or application code they call does it. An entry accepted while an entry
/// is being dispatched (processors or delivery) or while a replay runs is not
/// dispatched recursively but after the current one, in full (processors,
/// buffer, sinks): otherwise sinks later in the list would get the response
/// before its cause, and a processor logging on every entry would recurse to
/// a stack overflow. An entry accepted while such deferred entries are being
/// dispatched is dropped with a report to [diagnostics] (once): that is a loop
/// that would otherwise never end. The guard sees synchronous reentrancy only;
/// a loop through asynchronous work (a store failing on the entry logged
/// about its failure) is not a recursion and cannot be detected here, which
/// is why the diagnostics handler must not log.
///
/// An entry accepted between the entries of a queue dispatch (a diagnostics
/// handler logging on a dispatch failure) is dispatched immediately rather
/// than queued: through the queue it would go to the next turn, and a cycle
/// through it would run forever, one entry per turn.
///
/// Failures are reported to [diagnostics] under [owner]'s name and never
/// reach the caller: a processor failure drops the entry (passing it on
/// unprocessed could be a leak), a sink failure is isolated by the fan-out,
/// a failure dispatching one queued entry does not affect the rest (on the
/// timer it would otherwise escape to the zone).
@internal
final class LogPipeline {
  LogPipeline({
    required this.owner,
    required this.diagnostics,
    required this.dispatch,
    required List<LogSink> sinks,
    required List<LogProcessor> processors,
    required int startupBufferLimit,
    required Duration? startupBufferTimeout,
  }) : _processors = List.unmodifiable(processors),
       _sinks = FanOutSink(sinks, owner: owner, diagnostics: diagnostics),
       _startupBuffer = StartupBuffer(
         limit: startupBufferLimit,
         timeout: startupBufferTimeout,
         onTimeout: () => diagnostics.report(
           LogDiagnostic('$owner: startup buffering stopped after $startupBufferTimeout without finishStartup()'),
         ),
       );

  /// Name of the owner in diagnostics: `RootLogger: dispatch failed`.
  final String owner;

  final DiagnosticReporter diagnostics;

  /// When accepted entries are dispatched ([LogDispatchPolicy]).
  final LogDispatchPolicy dispatch;

  final FanOutSink _sinks;

  /// Events accepted before sinks were added: replayed into a sink at [addSink] until [finishStartup] or the
  /// buffer's timeout.
  final StartupBuffer _startupBuffer;

  /// Unmodifiable list: [addProcessor] and [removeProcessor] replace it wholesale, so processing of an in-flight
  /// entry iterates it without a copy.
  List<LogProcessor> _processors;

  /// Entries waiting for dispatch until the next event-loop turn, or until the queue holds
  /// [LogDispatchPolicy.queueLimit] of them and dispatches inside the call. Nothing is dropped.
  late final DeferredQueue _queue = DeferredQueue(
    limit: dispatch.queueLimit,
    immediateLevel: dispatch.immediateLevel,
    onDrain: _dispatchQueued,
  );

  /// Whether the queue is being dispatched ([_dispatchQueued]); see the class docs.
  bool _isDispatchingQueued = false;

  _Dispatching _dispatching = _Dispatching.none;

  /// Entries accepted during the current dispatch ([_Dispatching.entry]): dispatched after it.
  final List<LogEntry> _reentrant = [];

  bool _isLoopReported = false;

  List<LogSink> get sinks => _sinks.sinks;

  /// Processors in order: those given to the constructor, then those added via [addProcessor].
  List<LogProcessor> get processors => _processors;

  int get startupBufferLimit => _startupBuffer.limit;

  Duration? get startupBufferTimeout => _startupBuffer.timeout;

  /// Whether [close] has been called.
  bool get isClosed => _sinks.isClosed;

  /// Attaches [sink] under the pipeline's ownership, replaying the startup buffer into it when
  /// [replayStartupBuffer]. Adding the same sink again does nothing. Throws [StateError] after [close]: the sink
  /// would never receive entries or its [close].
  void addSink(LogSink sink, {required bool replayStartupBuffer}) {
    if (isClosed) throw StateError('$owner is closed: a sink added now would never be closed');
    final replay = replayStartupBuffer ? _startupBuffer.snapshot() : const <LogEntry>[];
    // A replay is a dispatch for the guard: a sink logging during it logs after it.
    _dispatchGuarded(() => _sinks.addSink(sink, replay: replay));
  }

  /// Detaches [sink] without closing it.
  void removeSink(LogSink sink) => _sinks.removeSink(sink);

  /// Appends [processor]; adding the same one again does nothing. Startup entries already in the buffer pass
  /// through it now, so that a sink added later replays only entries that passed every processor.
  void addProcessor(LogProcessor processor) {
    if (_processors.contains(processor)) return;
    _processors = List.unmodifiable([..._processors, processor]);
    _startupBuffer.rewrite((entry) => _applyProcessor(processor, entry));
  }

  /// Removes [processor]. Entries it already processed are not changed.
  void removeProcessor(LogProcessor processor) {
    if (!_processors.contains(processor)) return;
    _processors = List.unmodifiable([
      for (final other in _processors)
        if (other != processor) other,
    ]);
  }

  /// Ends the startup phase: the buffer is cleared and stops accumulating.
  void finishStartup() => _startupBuffer.finish();

  /// Takes a built entry for dispatch: queues it per [dispatch]; during a dispatch defers it until that one
  /// ends, during the dispatch of deferred entries drops it; between the entries of a queue dispatch dispatches
  /// it at once (see the class docs). The caller has checked thresholds and the closed state.
  void accept(LogEntry entry) {
    switch (_dispatching) {
      case _Dispatching.none:
        if (_isDispatchingQueued) {
          _dispatchGuarded(() => _dispatch(entry));
        } else {
          _queue.add(entry);
        }
      case _Dispatching.entry:
        _reentrant.add(entry);
      case _Dispatching.reentrant:
        _dropLooped();
    }
  }

  /// Dispatches the queued entries now and waits for delivery of accepted entries to all sinks without closing
  /// them. The first sink failure is returned to the caller after every sink was waited for.
  Future<void> flush() {
    _dispatchPending();
    return _sinks.flush();
  }

  /// Dispatches the queued entries now, ends the startup phase and closes every attached sink. The first sink
  /// failure is returned to the caller after every sink was closed. Calling again returns the first result.
  Future<void> close() {
    _dispatchPending();
    _startupBuffer.finish();
    return _sinks.close();
  }

  /// Dispatches what is queued right now, without waiting for the event loop. After [close] the queue is empty:
  /// there is nothing to dispatch and the sinks are closed.
  void _dispatchPending() {
    if (!isClosed) _queue.drain();
  }

  /// Dispatches the queued entries in order and tells the sinks the batch has ended ([LogSink.endBatch]). Runs
  /// outside a logger call (on a timer) or inside one (an entry at [LogDispatchPolicy.immediateLevel], a full
  /// queue, [flush], [close]).
  void _dispatchQueued() {
    final batch = _queue.takeAll();
    if (batch.isEmpty) return;
    _isDispatchingQueued = true;
    try {
      for (final entry in batch) {
        try {
          _dispatchGuarded(() => _dispatch(entry));
        } on Object catch (error, stackTrace) {
          diagnostics.report(LogDiagnostic('$owner: dispatch failed', error: error, stackTrace: stackTrace));
        }
      }
    } finally {
      _isDispatchingQueued = false;
    }
    _sinks.endBatch();
  }

  /// Runs [dispatch] (one entry or a replay) as the current dispatch, then dispatches the entries accepted
  /// during it, in order; entries accepted during those are dropped ([_dropLooped]). Inside a running dispatch
  /// runs [dispatch] as is: the outer one dispatches the deferred entries.
  void _dispatchGuarded(void Function() dispatch) {
    if (_dispatching != _Dispatching.none) {
      dispatch();
      return;
    }
    _dispatching = _Dispatching.entry;
    try {
      dispatch();
      _dispatching = _Dispatching.reentrant;
      // In this state new entries are dropped, so the list does not grow while it is iterated.
      _reentrant.forEach(_dispatch);
    } finally {
      _reentrant.clear();
      _dispatching = _Dispatching.none;
    }
  }

  void _dropLooped() {
    if (_isLoopReported) return;
    _isLoopReported = true;
    diagnostics.report(
      LogDiagnostic(
        '$owner: a processor or sink logs into its own logger in response to an entry that was itself logged '
        'during dispatch; such entries are dropped to break the loop',
      ),
    );
  }

  /// Passes the entry through [processors], stores it in the startup buffer and delivers it to every sink.
  void _dispatch(LogEntry entry) {
    final processed = _processed(entry);
    if (processed == null) return;
    _startupBuffer.add(processed);
    _sinks.add(processed);
  }

  /// [entry] after all [processors] in order; `null` if a processor dropped the entry or failed.
  LogEntry? _processed(LogEntry entry) {
    var current = entry;
    for (final processor in _processors) {
      final next = _applyProcessor(processor, current);
      if (next == null) return null;
      current = next;
    }
    return current;
  }

  /// [entry] after [processor]; `null` if it dropped the entry or failed (with the failure's stack in
  /// [diagnostics], without the entry's contents).
  LogEntry? _applyProcessor(LogProcessor processor, LogEntry entry) {
    try {
      return processor.process(entry);
    } on Object catch (error, stackTrace) {
      diagnostics.report(
        LogDiagnostic('$owner: processor failed, entry dropped', error: error, stackTrace: stackTrace),
      );
      return null;
    }
  }
}

/// Dispatch state of [LogPipeline] for the reentrancy guard.
enum _Dispatching {
  /// No dispatch in progress.
  none,

  /// Dispatching an accepted entry or a replay: entries accepted now are deferred until it ends.
  entry,

  /// Dispatching the deferred entries: entries accepted now are dropped.
  reentrant,
}
