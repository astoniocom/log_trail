import 'package:log_trail/src/entry/log_entry.dart';
import 'package:log_trail/src/storage/log_reader.dart';
import 'package:log_trail/src/storage/log_store_change.dart';
import 'package:log_trail/src/storage/stored_log_entry.dart';

/// A store of log entries: SQLite, a file, etc. Stores, serves ([LogReader])
/// and removes entries; queueing, batching and failure handling on the way
/// from the logger are `LogStoreSink`'s. The viewer takes it as a [LogReader].
///
/// Owned by whoever opened it, usually the application, which closes it after
/// `RootLogger.close`. Implementations build on `LogStoreBase`, which carries
/// the shared duties ([changes], closing, the stored form of entries); only a
/// store the base does not fit implements this interface directly and carries
/// the duties described on the methods itself. `compareLogStores` from
/// `package:log_trail/testing.dart` checks an implementation against the
/// in-memory reference.
abstract interface class LogStore implements LogReader {
  /// Saves [entries] in this order, each in full including [LogEntry.attributes],
  /// and assigns each an id ([StoredLogEntry.id]) increasing in save order and
  /// never reused. The next batch is passed only after this one completes.
  ///
  /// Once the returned [Future] completes, the entries survive process
  /// termination; a fatal entry relies on this. Surviving an OS failure or
  /// power loss is the implementation's documented choice, not the contract's.
  ///
  /// Returns the saved entries with ids in the same order and sends them as
  /// [LogEntriesAdded] to [changes]. Entries are saved and returned in stored
  /// form ([LogEntry.withoutLiveObjects]), the same form [queryEntries]
  /// returns.
  Future<List<StoredLogEntry>> writeEntries(List<LogEntry> entries);

  /// Removes all entries and sends [AllLogEntriesRemoved] to [changes].
  Future<void> clear();

  /// Removes entries strictly before [time] and sends [LogEntriesRemovedBefore]
  /// to [changes]: the application's age limit, `store.removeBefore(weekAgo)`.
  Future<void> removeBefore(DateTime time);

  /// Keeps the [count] newest entries in store order ([LogCursor]), removes the
  /// rest and sends their ids as [LogEntriesRemovedById] to [changes], or
  /// [LogStoreInvalidated] if the ids are not cheaply known: the application's
  /// count limit, `store.retainNewest(50000)`. A store may also remove entries
  /// on its own (a size limit), reporting them the same way.
  Future<void> retainNewest(int count);

  /// Releases the store's resources and closes [changes]. Called by the owner
  /// (the application) after the logger is closed, that is, after all
  /// [writeEntries] have completed, and when nobody reads the store anymore.
  Future<void> close();
}
