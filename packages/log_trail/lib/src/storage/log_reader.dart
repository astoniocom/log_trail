import 'package:log_trail/src/storage/log_query.dart';
import 'package:log_trail/src/storage/log_store_change.dart';

/// Reading the log from a store: everything the viewer needs.
///
/// Separated from `LogStore` so that code which only displays the log does
/// not depend on writing and cannot close a store owned by the application.
/// Every `LogStore` is also a [LogReader].
abstract interface class LogReader {
  /// Broadcast stream of changes: [LogEntriesAdded] for each saved batch of
  /// entries, [LogEntriesRemoved] describing removed entries,
  /// [LogStoreInvalidated] when a change cannot be described more precisely.
  /// There may be several subscribers (for example, two open viewers).
  Stream<LogStoreChange> get changes;

  /// A page of entries matching [query], with their ids (`StoredLogEntry`).
  /// The entries equal the written ones, with the same `LogEntry.attributes`.
  ///
  /// Called for every viewer page, so it must not read the whole log: an
  /// on-disk store needs an index on `(time, id)`, and a page continues from
  /// [LogQuery.startAfter] by that same key instead of `OFFSET`. An in-memory
  /// store can use `queryInMemory` over entries in store order.
  Future<LogPage> queryEntries([LogQuery query = const LogQuery()]);

  /// All tags (`LogEntry.tags`) found in stored entries: for the filter of a
  /// viewer that loads entries page by page. Must not scan the log either:
  /// for example, a separate tag table or counters updated on write and
  /// removal.
  Future<Set<String>> queryTags();
}
