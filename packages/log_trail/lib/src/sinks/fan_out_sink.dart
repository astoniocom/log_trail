import 'package:log_trail/src/diagnostics/log_diagnostic.dart';
import 'package:log_trail/src/entry/log_entry.dart';
import 'package:log_trail/src/sinks/log_sink.dart';
import 'package:meta/meta.dart';

/// A sink that delivers every entry to the attached sinks: the `RootLogger`
/// fan-out.
///
/// A failure of one sink does not block the others and goes to [diagnostics],
/// not to the caller: logging must not crash the app. Such reports do not go
/// to the sinks: a sink's failure would come back to the same sink. [flush]
/// and [close] reach every sink; each failure goes to [diagnostics], and the
/// first is also returned to the caller.
///
/// The diagnostics channel ([attach]) is passed to every sink: to those from
/// the constructor immediately, to those added via [addSink] on attach.
///
/// Delivers synchronously and recursively if asked to: the guard against a
/// sink logging into its own logger during delivery is the pipeline's
/// (`LogPipeline`), which defers such an entry until the current dispatch
/// ends, for processors and sinks alike.
@internal
final class FanOutSink extends LogSink {
  FanOutSink(Iterable<LogSink> sinks, {required this.owner, required DiagnosticReporter diagnostics})
    : _sinks = List.unmodifiable({...sinks}) {
    attach(diagnostics);
  }

  /// Owner name for diagnostics: `RootLogger: sink failed`.
  final String owner;

  @override
  String get name => 'FanOutSink';

  /// Immutable list: [addSink] and [removeSink] replace it as a whole.
  /// Delivery iterates the list without copying, while a sink may attach and
  /// detach others during it: the loop finishes over the previous list.
  List<LogSink> _sinks;

  List<LogSink> get sinks => _sinks;

  /// Attaches [sink] and passes it [replay]: entries accepted before attach.
  /// Attaching the same sink again does nothing: otherwise its entries would double.
  void addSink(LogSink sink, {Iterable<LogEntry> replay = const []}) {
    if (_sinks.contains(sink)) return;
    sink.attach(diagnostics);
    _sinks = List.unmodifiable([..._sinks, sink]);
    for (final entry in replay) {
      _deliver(sink, entry);
    }
    if (replay.isNotEmpty) _endBatch(sink);
  }

  /// Detaches [sink] without closing it.
  void removeSink(LogSink sink) {
    if (!_sinks.contains(sink)) return;
    _sinks = List.unmodifiable([
      for (final other in _sinks)
        if (other != sink) other,
    ]);
  }

  @override
  void onAttach(DiagnosticReporter diagnostics) {
    for (final sink in _sinks) {
      sink.attach(diagnostics);
    }
  }

  @override
  void onAdd(LogEntry entry) {
    for (final sink in _sinks) {
      _deliver(sink, entry);
    }
  }

  void _deliver(LogSink sink, LogEntry entry) {
    try {
      sink.add(entry);
    } on Object catch (error, stackTrace) {
      diagnostics.report(LogDiagnostic('$owner: sink failed', error: error, stackTrace: stackTrace));
    }
  }

  /// The end of batch is passed to every sink; a failure of one does not block the others.
  @override
  void onBatchEnd() => _sinks.forEach(_endBatch);

  void _endBatch(LogSink sink) {
    try {
      sink.endBatch();
    } on Object catch (error, stackTrace) {
      diagnostics.report(LogDiagnostic('$owner: sink failed', error: error, stackTrace: stackTrace));
    }
  }

  @override
  Future<void> onFlush() => _forEachSink((sink) => sink.flush(), 'sink flush failed');

  @override
  Future<void> onClose() => _forEachSink((sink) => sink.close(), 'sink close failed');

  /// Runs [action] for every sink and waits for all. Each failure goes to
  /// [diagnostics] with [failure] and the sink name; the first is also
  /// returned to the caller. Without this, [Future.wait] would report only the
  /// first and the rest would be lost.
  Future<void> _forEachSink(Future<void> Function(LogSink sink) action, String failure) async {
    Object? firstError;
    StackTrace? firstStackTrace;
    await Future.wait([
      for (final sink in _sinks)
        Future.sync(() => action(sink)).catchError((Object error, StackTrace stackTrace) {
          diagnostics.report(LogDiagnostic('$owner: $failure: $sink', error: error, stackTrace: stackTrace));
          firstError ??= error;
          firstStackTrace ??= stackTrace;
        }),
    ]);
    if (firstError case final error?) Error.throwWithStackTrace(error, firstStackTrace!);
  }
}
