import 'dart:math' as math;

import 'package:log_trail/src/storage/in_memory/store_order.dart';
import 'package:log_trail/src/storage/log_query.dart';
import 'package:log_trail/src/storage/stored_log_entry.dart';

/// Runs [query] over entries in memory: for in-memory stores (`InMemoryLogStore`, fakes in tests).
///
/// [entries] must be in store order: by time, entries with equal time by id (checked in debug). Then a
/// page needs neither sorting nor a scan of the whole log: the period bounds (`LogFilter.after`,
/// `LogFilter.before`) and the continuation ([LogQuery.startAfter]) are found by binary search, and the
/// scan stops as soon as the page is full and the next matching entry is found.
///
/// Not suitable for an on-disk store (SQLite, a file): reading the whole log for every page is too
/// expensive; it needs its own index by time.
LogPage queryInMemory(List<StoredLogEntry> entries, LogQuery query) {
  assert(isInStoreOrder(entries), 'entries must be in store order: by time, then by id');
  final filter = query.filter;
  final after = filter.after;
  final before = filter.before;
  // Entries of the period: [low, high).
  final low = after == null ? 0 : indexAfter(entries, after);
  final high = before == null ? entries.length : indexNotBefore(entries, before);

  final newestFirst = query.newestFirst;
  final step = newestFirst ? -1 : 1;
  var index = switch ((query.startAfter, newestFirst)) {
    (null, false) => low,
    (null, true) => high - 1,
    (final cursor?, false) => math.max(low, indexAfterCursor(entries, cursor)),
    (final cursor?, true) => math.min(high, indexNotBeforeCursor(entries, cursor)) - 1,
  };

  final limit = query.limit;
  final page = <StoredLogEntry>[];
  var hasNext = false;
  for (; index >= low && index < high; index += step) {
    final stored = entries[index];
    if (!filter.matches(stored.entry)) continue;
    if (limit != null && page.length == limit) {
      hasNext = true;
      break;
    }
    page.add(stored);
  }
  return LogPage(page, next: hasNext ? query.startingAfter(page.last.cursor) : null);
}
