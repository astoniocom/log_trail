import 'package:log_trail/src/entry/log_level.dart';
import 'package:meta/meta.dart';

/// How `RootLogger` dispatches collected entries: runs them through
/// processors (`LogProcessor`), puts them into the startup buffer and passes
/// them to the sinks.
///
/// Building an entry (`LogCall` → `LogEntry`: time, context, stack snapshot)
/// always happens inside the logger call, otherwise the entry would get
/// someone else's time and context. Dispatch, however, is work whose amount
/// the app defines (pattern masking, enrichment, sinks), and the root does it
/// not in the `log` call but in the next event-loop turn, as a batch: `log`
/// only puts the entry into a queue of at most [queueLimit] entries; a full
/// queue is dispatched inside the call rather than dropped. This is the only
/// place in the library where work is deferred: sinks keep no queues of
/// their own and run synchronously, already outside the logger call.
///
/// Entries at [immediateLevel] and above are dispatched inside the call,
/// together with what accumulated before them: an app that logs a fatal and
/// exits the process must not lose that entry. [synchronous] dispatches
/// everything inside the call; the root of a background isolate
/// (`IsolateLogSink`) needs this, since it may exit right after its work, as
/// do tests that check a sink right after logging.
///
/// ```dart
/// RootLogger(dispatch: const LogDispatchPolicy(immediateLevel: LogLevel.error));
/// RootLogger(sinks: [IsolateLogSink(port)], dispatch: LogDispatchPolicy.synchronous);
/// ```
@immutable
final class LogDispatchPolicy {
  const LogDispatchPolicy({this.immediateLevel = LogLevel.fatal, this.queueLimit = 1000})
    : assert(queueLimit > 0, 'queueLimit must be positive');

  /// Dispatch of every entry inside the logger call: `log` returns once every
  /// sink has handled the entry.
  static const LogDispatchPolicy synchronous = LogDispatchPolicy(immediateLevel: LogLevel.trace);

  /// Entries at this level and above are dispatched inside the logger call,
  /// together with what accumulated before them. `null` means all are deferred.
  final LogLevel? immediateLevel;

  /// Maximum number of entries waiting for dispatch. The entry that fills the
  /// queue is dispatched inside the logger call together with everything
  /// before it, so a burst larger than the limit within one event-loop turn
  /// (a spool file imported through `RootLogger.asSink`, a loop logging
  /// thousands of entries, port messages queued ahead of the drain timer)
  /// goes out in batches of this size and nothing is dropped. The limit is
  /// mandatory: it bounds memory whether or not the event loop gets a turn,
  /// and it bounds the size of one batch, that is of one
  /// `LogStore.writeEntries` transaction and one spool file.
  final int queueLimit;

  @override
  bool operator ==(Object other) =>
      other is LogDispatchPolicy && other.immediateLevel == immediateLevel && other.queueLimit == queueLimit;

  @override
  int get hashCode => Object.hash(immediateLevel, queueLimit);

  @override
  String toString() => 'LogDispatchPolicy(immediateLevel: ${immediateLevel?.name}, queueLimit: $queueLimit)';
}
