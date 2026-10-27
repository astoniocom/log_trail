import 'dart:async';

import 'package:log_trail/src/diagnostics/log_diagnostic.dart';
import 'package:log_trail/src/entry/log_entry.dart';
import 'package:meta/meta.dart';

/// A sink for log entries.
///
/// [add] accepts an entry. Its time, call site and stack are already resolved
/// by the facade (`RootLogger`). Entries accumulated before the sink was
/// attached arrive with their original [LogEntry.time].
///
/// The lifecycle is shared by all sinks and managed here: a subclass
/// implements [onAdd] and, when needed, [onFlush], [onClose] and [onAttach];
/// [add], [flush], [close] and [attach] cannot be overridden. This way no sink
/// accepts an entry after closing or releases its resources twice. The class
/// is `base`: a sink can only be subclassed (`extends`), not `implements`-ed,
/// otherwise these guarantees would be mere convention. So a custom sink is
/// declared `final class MySink extends LogSink` (or `base class` if it will
/// be subclassed itself). For the same reason a sink cannot be mocked with
/// `implements`; the test double is `RecordingLogSink` from
/// `package:log_trail/testing.dart`, which records entries and lifecycle calls
/// and can be subclassed for more.
///
/// A sink reports its own failures outside the logger's fan-out (queue
/// overflow, failed timer delivery) to [diagnostics]: the logger sets the
/// channel on attach ([attach]).
///
/// Does not implement [Sink] from `dart:core`: its [close] is synchronous, and
/// code that accepts `Sink<LogEntry>` ([Stream.pipe] and the like) does not
/// expect a log sink. `RootLogger` dispatches entries to the sink.
abstract base class LogSink {
  bool _isClosed = false;

  /// The closing in progress or completed; `null` until [close] is called.
  Future<void>? _closing;

  DiagnosticReporter _diagnostics = DiagnosticReporter.console;

  /// Sink name in library messages: in diagnostics ([LogDiagnostic]) and in
  /// the dropped-entries warnings that go into the log. Defaults to the class
  /// name, but in an `--obfuscate` build that is unreadable (`minified:aB`);
  /// the library's sinks return a constant string, and a custom sink should
  /// do the same.
  String get name => '$runtimeType';

  /// Whether [close] has been called: from then on [add] throws.
  bool get isClosed => _isClosed;

  /// Where the sink reports its own failures. Set by the logger on attach
  /// ([attach]); before that, [DiagnosticReporter.console].
  ///
  /// Failures that happen during the logger's fan-out (a throw from [onAdd])
  /// are caught and reported by the logger itself; here the sink reports what
  /// happens outside it: on a timer, in an asynchronous write, on queue
  /// overflow.
  DiagnosticReporter get diagnostics => _diagnostics;

  /// Tells the sink where to send reports of its own failures
  /// ([diagnostics]). Called by the logger on attach (`RootLogger.addSink`
  /// and the sinks from the root constructor); wrappers pass the channel to
  /// their inner sinks ([onAttach]). A repeated call replaces the channel: a
  /// sink reattached to another logger reports to it.
  ///
  /// A sink used without a logger (for example in a test) gets its channel
  /// through this same method.
  @nonVirtual
  void attach(DiagnosticReporter diagnostics) {
    _diagnostics = diagnostics;
    onAttach(diagnostics);
  }

  /// Accepts an entry ([onAdd]). Throws [StateError] after [close]: logging
  /// into a closed sink is a shutdown-order bug, better seen than silently
  /// sent to a closed store. The `RootLogger` fan-out catches such errors and
  /// reports them to diagnostics.
  @nonVirtual
  void add(LogEntry entry) {
    if (_isClosed) throw StateError('$name is closed');
    onAdd(entry);
  }

  /// Signals that a batch of entries has ended ([onBatchEnd]): `RootLogger`
  /// calls it after every queue dispatch, including dispatch inside the logger
  /// call (a fatal entry, [flush], [close]). A sink that writes in batches
  /// (`LogStoreSink`) hands over what it accumulated here: everything the root
  /// dispatched at once goes as one batch, and a fatal entry goes together
  /// with what accumulated before it, before `log` returns. Does nothing
  /// after [close].
  @nonVirtual
  void endBatch() {
    if (!_isClosed) onBatchEnd();
  }

  @override
  String toString() => name;

  /// Waits until accepted entries reach their destination (for example are
  /// persisted to the store) without closing the sink ([onFlush]). After
  /// [close], waits for the closing to complete, which delivers everything
  /// accepted.
  @nonVirtual
  Future<void> flush() => _closing ?? Future.sync(onFlush);

  /// Shuts the sink down: no new entries are accepted, then [onClose]
  /// delivers the accepted ones and releases resources. A repeated call closes
  /// nothing again and returns the result of the first.
  @nonVirtual
  Future<void> close() {
    if (_closing case final closing?) return closing;
    _isClosed = true;
    return _closing = Future.sync(onClose);
  }

  /// Handles an accepted entry. Called only before [close].
  @protected
  void onAdd(LogEntry entry);

  /// Called from [endBatch]. Does nothing by default: for sinks that handle
  /// each entry in [onAdd]; wrappers (`DelegatingSink`) pass the end of batch
  /// to `inner`.
  @protected
  void onBatchEnd() {}

  /// Waits for accepted entries to be delivered. Does nothing by default: for
  /// sinks that deliver entries immediately in [onAdd].
  @protected
  Future<void> onFlush() async {}

  /// Delivers accepted entries and releases resources (for example closes the
  /// store). Called once. Does nothing by default.
  @protected
  Future<void> onClose() async {}

  /// Called from [attach]: pass [diagnostics] to inner sinks. Does nothing by
  /// default; `DelegatingSink` passes it to `inner`.
  @protected
  void onAttach(DiagnosticReporter diagnostics) {}
}
