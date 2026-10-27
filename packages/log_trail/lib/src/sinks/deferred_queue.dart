import 'dart:async';

import 'package:log_trail/src/entry/log_entry.dart';
import 'package:log_trail/src/entry/log_level.dart';
import 'package:meta/meta.dart';

/// The `RootLogger` dispatch queue: [add] puts an entry into the queue and
/// schedules [onDrain] for the next event-loop turn, while an entry at
/// [immediateLevel] or above calls [onDrain] immediately, together with what
/// accumulated before it.
///
/// This moves dispatch (processors, sinks) out of the `log` call and the
/// current frame, while [immediateLevel] keeps an exception for entries that
/// must not be lost if the app exits the process right after them.
///
/// The queue never drops an entry. It holds at most [limit] entries: the
/// entry that fills it is dispatched at once, inside the call, together with
/// everything before it. So a burst larger than the limit within one
/// event-loop turn (a spool file imported through `RootLogger.asSink`, a
/// loop logging thousands of entries, a stream of port messages queued ahead
/// of the drain timer) goes out in batches of [limit] with nothing lost, and
/// memory stays bounded whether or not the event loop gets a turn. Dropping
/// would buy nothing here: the consumer is the root itself, synchronous, and
/// always able to run.
///
/// The owner takes the accumulated entries in [onDrain] via [takeAll].
@internal
final class DeferredQueue {
  DeferredQueue({required this.limit, required this.immediateLevel, required this.onDrain})
    : assert(limit > 0, 'limit must be positive');

  /// Number of queued entries at which [onDrain] runs inside the call.
  final int limit;

  /// Entries at this level and above call [onDrain] immediately; `null` means
  /// all entries wait for the next event-loop turn or for the queue to fill.
  final LogLevel? immediateLevel;

  /// Handles the accumulated entries: in the next event-loop turn,
  /// immediately for an [immediateLevel] entry or a full queue, or via [drain].
  final void Function() onDrain;

  List<LogEntry> _entries = [];

  /// The scheduled [onDrain]; `null` if none is scheduled.
  Timer? _scheduled;

  bool get isEmpty => _entries.isEmpty;
  bool get isNotEmpty => _entries.isNotEmpty;
  int get length => _entries.length;

  /// Enqueues an entry and schedules [onDrain]; for an [immediateLevel] entry
  /// or when the queue reaches [limit], calls it immediately.
  void add(LogEntry entry) {
    _entries.add(entry);
    final immediateLevel = this.immediateLevel;
    if (_entries.length >= limit || (immediateLevel != null && entry.level >= immediateLevel)) {
      drain();
      return;
    }
    // A timer, not a microtask: a microtask would run before the current frame finishes.
    _scheduled ??= Timer(Duration.zero, drain);
  }

  /// Cancels the scheduled handling and calls [onDrain] now: for `flush` and
  /// `close`, which do not wait for the event loop.
  void drain() {
    _scheduled?.cancel();
    _scheduled = null;
    onDrain();
  }

  /// Takes the accumulated entries, oldest first. The returned list is not
  /// changed by later [add] calls.
  List<LogEntry> takeAll() {
    final batch = _entries;
    _entries = [];
    return batch;
  }
}
