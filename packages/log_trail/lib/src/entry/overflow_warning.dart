import 'package:log_trail/src/entry/log_entry.dart';
import 'package:log_trail/src/entry/log_level.dart';
import 'package:log_trail/src/util/bounded_queue.dart';
import 'package:meta/meta.dart';

/// Warning about entries lost to overflow of a bounded library queue (startup
/// buffer, store queue), which the queue owner places before the remaining
/// entries. The root's dispatch queue never drops: it dispatches when full.
///
/// [tag] names the queue (`startupLogTag`, `storageLogTag`), [time] is the
/// time of the last dropped entry: the
/// dropped entries are older than the remaining ones, so a warning with this
/// time precedes them and keeps event order.
@internal
LogEntry overflowWarning({required String tag, required String message, required DateTime time}) =>
    LogEntry(time: time, level: LogLevel.warning, message: message, tags: {tag});

/// Draining a bounded entry queue together with an overflow warning.
@internal
extension TakeWithOverflowWarning on BoundedQueue<LogEntry> {
  /// Takes entries oldest first, all or at most [limit]; if entries were
  /// dropped since the last call, an [overflowWarning] with [tag] and the
  /// [message] for their count comes first. Drop accounting is reset: it has
  /// been reported. The warning does not count toward [limit].
  List<LogEntry> takeWithOverflowWarning({
    required String tag,
    required String Function(int dropped) message,
    int? limit,
  }) {
    final lastDropped = this.lastDropped;
    final warning = lastDropped == null
        ? null
        : overflowWarning(tag: tag, message: message(droppedCount), time: lastDropped.time);
    final batch = limit == null ? takeAll() : take(limit);
    resetDropped();
    return warning == null ? batch : [warning, ...batch];
  }
}
