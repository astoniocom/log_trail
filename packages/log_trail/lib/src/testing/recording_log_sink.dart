import 'package:log_trail/src/entry/log_entry.dart';
import 'package:log_trail/src/sinks/log_sink.dart';

/// A sink for tests: records what it receives and counts the lifecycle calls.
///
/// [LogSink] is a `base` class so that its lifecycle ([add] throws after
/// [close], [onClose] runs once, [attach] reaches wrappers' inner sinks) is
/// inherited and cannot be bypassed by a reimplementation; that also rules out
/// `implements LogSink` in a mock. This sink is the test double instead:
/// attach it to a root and assert on [entries], or hand it to a wrapper under
/// test as `inner` and assert on what the wrapper let through, flushed and
/// closed.
///
/// ```dart
/// final sink = RecordingLogSink();
/// final logger = RootLogger(sinks: [sink], dispatch: LogDispatchPolicy.synchronous)..finishStartup();
/// service(logger.child(tags: {'sync'})).run();
/// expect(sink.messages, ['Sync started', 'Sync finished']);
/// ```
///
/// [failOn] makes [add] throw for the entries it selects, to test how a
/// logger or wrapper handles a failing sink. [batches] groups the entries by
/// dispatch batch ([LogSink.endBatch]). Subclass it (`extends`) for a test
/// that needs more, for example a hook at flush time.
base class RecordingLogSink extends LogSink {
  RecordingLogSink({this.failOn});

  /// Entries for which [add] throws a [StateError]; `null` means none.
  bool Function(LogEntry entry)? failOn;

  /// Entries received, in order; an entry [failOn] rejected is not among them.
  final List<LogEntry> entries = [];

  /// Entries grouped by dispatch batch: a new list per [endBatch] that ended
  /// a non-empty batch. Entries since the last batch end are in [entries]
  /// but not yet here.
  final List<List<LogEntry>> batches = [];
  List<LogEntry> _currentBatch = [];

  int flushCount = 0;
  int closeCount = 0;

  @override
  String get name => 'RecordingLogSink';

  Iterable<String> get messages => entries.map((entry) => entry.message);

  @override
  void onAdd(LogEntry entry) {
    if (failOn?.call(entry) ?? false) throw StateError('$name refuses: ${entry.message}');
    entries.add(entry);
    _currentBatch.add(entry);
  }

  @override
  void onBatchEnd() {
    if (_currentBatch.isEmpty) return;
    batches.add(_currentBatch);
    _currentBatch = [];
  }

  @override
  Future<void> onFlush() async => flushCount++;

  @override
  Future<void> onClose() async => closeCount++;
}
