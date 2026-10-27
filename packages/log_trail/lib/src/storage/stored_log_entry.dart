import 'package:log_trail/src/entry/log_entry.dart';
import 'package:meta/meta.dart';

/// An entry saved by a store: the [entry] and the store-assigned [id].
///
/// [LogEntry] is a value without identity: two entries with equal fields are indistinguishable. The
/// store tells them apart by [id], so the viewer removes deleted entries and continues pages by id
/// without comparing whole entries.
///
/// Store entries are ordered by [cursor]: by time, then by [id], that is, in write order. `LogQuery`
/// defines this order.
@immutable
final class StoredLogEntry {
  const StoredLogEntry(this.id, this.entry);

  /// The entry's id in the store: increases in write order and is never reused while the store lives
  /// (like SQLite `rowid` with `AUTOINCREMENT`). Unique within a single store.
  final int id;

  final LogEntry entry;

  /// The entry's position in store order.
  LogCursor get cursor => LogCursor(entry.time, id);

  /// Entries with the same [id] and the same [entry] are equal. [entry] equality is checked after [id]:
  /// for entries of one store, [id] tells them apart without touching the stack trace and attributes.
  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is StoredLogEntry && other.id == id && other.entry == entry;

  @override
  int get hashCode => id;

  @override
  String toString() => '#$id $entry';
}

/// An entry's position in store order: time, then id ([StoredLogEntry.id]). A page continues from it
/// (`LogQuery.startAfter`): entries written between pages do not shift the next page, and entries with
/// equal time are neither lost nor repeated at its boundary.
@immutable
final class LogCursor implements Comparable<LogCursor> {
  const LogCursor(this.time, this.id);

  final DateTime time;
  final int id;

  /// By [time] first (as an instant, regardless of time zone), then by [id].
  @override
  int compareTo(LogCursor other) {
    final byTime = time.compareTo(other.time);
    return byTime != 0 ? byTime : id.compareTo(other.id);
  }

  @override
  bool operator ==(Object other) => other is LogCursor && other.id == id && other.time.isAtSameMomentAs(time);

  @override
  int get hashCode => Object.hash(time.microsecondsSinceEpoch, id);

  @override
  String toString() => 'LogCursor(${time.toIso8601String()}, #$id)';
}
