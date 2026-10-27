import 'dart:async';

import 'package:log_trail/src/entry/log_entry.dart';
import 'package:log_trail/src/entry/log_tags.dart';
import 'package:log_trail/src/entry/overflow_warning.dart';
import 'package:log_trail/src/util/bounded_queue.dart';
import 'package:meta/meta.dart';

/// Startup-phase entries of `RootLogger`: accepted before a sink was
/// attached, to be replayed into it on attach ([snapshot]).
///
/// The buffer is bounded by [limit]: on overflow the oldest entries are
/// dropped, and the replay starts with a warning stating how many were lost
/// ([startupLogTag]). Buffering ends on [finish] or, if it is not called,
/// when [timeout] elapses since the first entry: the timer releases the
/// entries even if the app writes nothing else, and reports this via
/// [onTimeout]. There is no timer while there are no entries: creating the
/// buffer starts nothing.
@internal
final class StartupBuffer {
  StartupBuffer({required int limit, required this.timeout, required this.onTimeout})
    : _entries = BoundedQueue(limit: limit);

  /// Maximum number of entries. On overflow the oldest are dropped: with a
  /// looping error at startup the latest events matter more. The limit is
  /// mandatory: otherwise such an error eats memory.
  int get limit => _entries.limit;

  /// How long after the first entry buffering turns itself off; `null` means
  /// only via [finish]. Otherwise a sink attached half an hour later would
  /// get the events of the first second.
  final Duration? timeout;

  /// Called when buffering was turned off by [timeout] rather than [finish].
  final void Function() onTimeout;

  final BoundedQueue<LogEntry> _entries;
  Timer? _timer;
  bool _isActive = true;

  /// Whether buffering is in progress.
  bool get isActive => _isActive;

  /// Remembers the entry if buffering is in progress; the first entry starts
  /// the [timeout] timer. Does nothing after [finish].
  void add(LogEntry entry) {
    if (!_isActive) return;
    _entries.add(entry);
    final timeout = this.timeout;
    if (timeout != null) _timer ??= Timer(timeout, _expire);
  }

  /// Replaces each entry with the result of [transform]; `null` removes the
  /// entry. For a processor added to the root after entries reached the
  /// buffer: replayed entries must have passed all root processors. Does
  /// nothing after [finish].
  void rewrite(LogEntry? Function(LogEntry entry) transform) {
    if (!_isActive) return;
    _entries.rewrite(transform);
  }

  /// Ends buffering: entries are dropped, new ones are not collected, the
  /// timer is cancelled.
  void finish() {
    _isActive = false;
    _timer?.cancel();
    _timer = null;
    _entries.clear();
  }

  void _expire() {
    if (!_isActive) return;
    finish();
    onTimeout();
  }

  /// Entries to replay into a sink: the overflow warning, if entries were
  /// lost, then entries from oldest to newest. Entries stay in the buffer for
  /// subsequent sinks.
  ///
  /// A snapshot at call time: during replay the sink may itself log into the
  /// logger and add to the buffer.
  List<LogEntry> snapshot() => [
    if (_entries.lastDropped case final lastDropped?)
      overflowWarning(
        tag: startupLogTag,
        message: 'Startup log buffer overflow: ${_entries.droppedCount} earlier event(s) dropped',
        time: lastDropped.time,
      ),
    ..._entries.toList(),
  ];
}
