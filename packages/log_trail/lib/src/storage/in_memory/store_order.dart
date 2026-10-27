/// Binary search over entries in store order ([LogCursor]: by time, then by id).
library;

import 'package:log_trail/src/storage/stored_log_entry.dart';
import 'package:meta/meta.dart';

/// Index of the first entry not before [time]; the list length if there is none.
@internal
int indexNotBefore(List<StoredLogEntry> entries, DateTime time) =>
    _partition(entries, (stored) => stored.entry.time.isBefore(time));

/// Index of the first entry after [time]; the list length if there is none.
@internal
int indexAfter(List<StoredLogEntry> entries, DateTime time) =>
    _partition(entries, (stored) => !stored.entry.time.isAfter(time));

/// Index of the first entry positioned not before [cursor]; the list length if there is none.
@internal
int indexNotBeforeCursor(List<StoredLogEntry> entries, LogCursor cursor) =>
    _partition(entries, (stored) => stored.cursor.compareTo(cursor) < 0);

/// Index of the first entry positioned after [cursor]; the list length if there is none.
@internal
int indexAfterCursor(List<StoredLogEntry> entries, LogCursor cursor) =>
    _partition(entries, (stored) => stored.cursor.compareTo(cursor) <= 0);

/// Whether [entries] are in store order: by [LogCursor], without duplicates.
@internal
bool isInStoreOrder(List<StoredLogEntry> entries) {
  for (var i = 1; i < entries.length; i++) {
    if (entries[i].cursor.compareTo(entries[i - 1].cursor) <= 0) return false;
  }
  return true;
}

/// Index of the first entry for which [isLeft] is false; [isLeft] is true for a prefix of the list and
/// false for the rest.
int _partition(List<StoredLogEntry> entries, bool Function(StoredLogEntry stored) isLeft) {
  var low = 0;
  var high = entries.length;
  while (low < high) {
    final middle = (low + high) >> 1;
    if (isLeft(entries[middle])) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low;
}
