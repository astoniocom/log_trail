import 'package:log_trail/src/storage/log_filter.dart';
import 'package:log_trail/src/storage/stored_log_entry.dart';
import 'package:meta/meta.dart';

/// A query for entries to `LogReader`: selection conditions ([filter]), order and page.
///
/// Only a description of the query; how to run it is up to the store: SQL, `queryInMemory` for entries
/// in memory, etc. Selection of a single entry is [LogFilter.matches], order is [LogCursor.compareTo].
///
/// Entries come in store order ([LogCursor]): by time, then by id, that is, in write order; reversed
/// with [newestFirst]. A page continues from [startAfter]: in SQL that is
/// `WHERE (time, id) > (?, ?) ORDER BY time, id` (`<` and `DESC` with [newestFirst]) instead of
/// `OFFSET`, which would be shifted by entries written between pages.
@immutable
final class LogQuery {
  const LogQuery({
    this.filter = const LogFilter(),
    this.newestFirst = false,
    this.limit,
    this.startAfter,
  }) : assert(limit == null || limit > 0, 'limit must be positive');

  /// Which entries to select; all by default.
  final LogFilter filter;

  /// Newest first.
  final bool newestFirst;

  /// At most this many entries per page; `null` means all.
  final int? limit;

  /// Only entries strictly after this position in query order (older than it with [newestFirst]): the
  /// continuation of the previous page, usually the position of its last entry ([StoredLogEntry.cursor]).
  /// `null` means from the start.
  final LogCursor? startAfter;

  /// The same query continuing the page after [cursor]: for [LogPage.next].
  LogQuery startingAfter(LogCursor cursor) =>
      LogQuery(filter: filter, newestFirst: newestFirst, limit: limit, startAfter: cursor);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LogQuery &&
          other.filter == filter &&
          other.newestFirst == newestFirst &&
          other.limit == limit &&
          other.startAfter == startAfter;

  @override
  int get hashCode => Object.hash(filter, newestFirst, limit, startAfter);

  @override
  String toString() =>
      'LogQuery('
      '${[
        if (!filter.isEmpty) 'filter: $filter',
        if (newestFirst) 'newestFirst',
        if (limit != null) 'limit: $limit',
        if (startAfter != null) 'startAfter: $startAfter',
      ].join(', ')}'
      ')';
}

/// A page of a [LogQuery] result.
@immutable
final class LogPage {
  LogPage(List<StoredLogEntry> entries, {this.next}) : entries = List.unmodifiable(entries);

  /// The page's entries in query order.
  final List<StoredLogEntry> entries;

  /// The query for the next page (usually `query.startingAfter(entries.last.cursor)`); `null` means
  /// there are no more pages.
  final LogQuery? next;
}
