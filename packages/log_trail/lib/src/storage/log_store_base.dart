import 'dart:async';

import 'package:log_trail/src/entry/log_entry.dart';
import 'package:log_trail/src/storage/log_query.dart';
import 'package:log_trail/src/storage/log_store.dart';
import 'package:log_trail/src/storage/log_store_change.dart';
import 'package:log_trail/src/storage/stored_log_entry.dart';
import 'package:meta/meta.dart';

/// Base class for a store ([LogStore]): carries what every store would
/// otherwise repeat, leaving the implementation the primitives
/// [onWriteEntries], [onQueryEntries], [onQueryTags], [onClear],
/// [onRemoveBefore], [onRetainNewest] and [onClose].
///
/// The base emits every [LogStoreChange] to [changes] itself (the store
/// reports only removals of its own through [reportChange], delivered after
/// the current write's [LogEntriesAdded]); hands [onWriteEntries] the entries
/// already in stored form ([LogEntry.withoutLiveObjects]); makes every
/// operation throw [StateError] after [close] and closes [changes] after
/// [onClose]. A `base` class: a store is `final class MyStore extends
/// LogStoreBase`, and one the base does not fit implements [LogStore] directly.
///
/// ```dart
/// final class MyStore extends LogStoreBase {
///   @override
///   Future<List<StoredLogEntry>> onWriteEntries(List<LogEntry> entries) => db.transaction((tx) async {
///     final stored = [for (final entry in entries) StoredLogEntry(insert(tx, entry), entry)];
///     reportChange(LogEntriesRemovedById(evictOldest(tx)));
///     return stored;
///   });
///   // …
/// }
/// ```
abstract base class LogStoreBase implements LogStore {
  final StreamController<LogStoreChange> _changes = StreamController.broadcast();

  /// Closing in progress or completed; `null` until [close] is called.
  Future<void>? _closing;

  /// Changes the store reported during [onWriteEntries]: sent after the
  /// [LogEntriesAdded] of that write. `null` when no write is in progress.
  List<LogStoreChange>? _changesDuringWrite;
  int _writesInProgress = 0;

  /// Store name in messages ([StateError] after [close]). Defaults to the
  /// class name, unreadable in an `--obfuscate` build; a store should return
  /// a constant string, as sinks do (`LogSink.name`).
  String get name => '$runtimeType';

  /// Whether [close] has been called: from then on operations throw [StateError].
  bool get isClosed => _closing != null;

  @override
  @nonVirtual
  Stream<LogStoreChange> get changes => _changes.stream;

  /// Converts entries to stored form, saves them ([onWriteEntries]) and sends
  /// [LogEntriesAdded] to [changes]; changes the store reported while saving
  /// ([reportChange]) follow it. Throws [StateError] after [close].
  @override
  @nonVirtual
  Future<List<StoredLogEntry>> writeEntries(List<LogEntry> entries) async {
    _checkOpen();
    final detached = [for (final entry in entries) entry.withoutLiveObjects()];
    _writesInProgress++;
    _changesDuringWrite ??= [];
    try {
      final stored = await onWriteEntries(detached);
      assert(
        stored.length == detached.length,
        '$name.onWriteEntries returned ${stored.length} entries for ${detached.length} written',
      );
      _emit(LogEntriesAdded(stored));
      return stored;
    } finally {
      // Also after a failed write: otherwise deferred changes would wait for the next write.
      _writesInProgress--;
      if (_writesInProgress == 0) {
        final deferred = _changesDuringWrite!;
        _changesDuringWrite = null;
        deferred.forEach(_emit);
      }
    }
  }

  /// A page of entries for [query] ([onQueryEntries]). Throws [StateError] after [close].
  @override
  @nonVirtual
  Future<LogPage> queryEntries([LogQuery query = const LogQuery()]) => Future.sync(() {
    _checkOpen();
    return onQueryEntries(query);
  });

  /// Tags of stored entries ([onQueryTags]). Throws [StateError] after [close].
  @override
  @nonVirtual
  Future<Set<String>> queryTags() => Future.sync(() {
    _checkOpen();
    return onQueryTags();
  });

  /// Removes all entries ([onClear]) and sends [AllLogEntriesRemoved].
  /// Throws [StateError] after [close].
  @override
  @nonVirtual
  Future<void> clear() async {
    _checkOpen();
    await onClear();
    _emit(const AllLogEntriesRemoved());
  }

  /// Removes entries strictly before [time] ([onRemoveBefore]) and sends
  /// [LogEntriesRemovedBefore]. Throws [StateError] after [close].
  @override
  @nonVirtual
  Future<void> removeBefore(DateTime time) async {
    _checkOpen();
    await onRemoveBefore(time);
    _emit(LogEntriesRemovedBefore(time));
  }

  /// Keeps the [count] newest entries ([onRetainNewest]) and sends
  /// [LogEntriesRemovedById] with the removed ids, nothing if there was
  /// nothing to remove, or [LogStoreInvalidated] if the store does not know
  /// what it removed. Throws [StateError] after [close].
  @override
  @nonVirtual
  Future<void> retainNewest(int count) async {
    assert(count >= 0, 'count must not be negative');
    _checkOpen();
    final removed = await onRetainNewest(count);
    if (removed == null) {
      _emit(const LogStoreInvalidated());
    } else if (removed.isNotEmpty) {
      _emit(LogEntriesRemovedById(removed));
    }
  }

  /// Releases resources ([onClose]) and closes [changes]. A repeated call
  /// closes nothing again and returns the result of the first.
  @override
  @nonVirtual
  Future<void> close() {
    if (_closing case final closing?) return closing;
    return _closing = Future.sync(onClose).whenComplete(_changes.close);
  }

  /// Reports a change the store made on its own: removed entries because of
  /// file size ([LogEntriesRemovedById] or, if it does not know which,
  /// [LogStoreInvalidated]). During [onWriteEntries] the change is sent after
  /// the [LogEntriesAdded] of that write: otherwise a subscriber would get a
  /// removal of entries it does not yet know about.
  @protected
  void reportChange(LogStoreChange change) {
    final deferred = _changesDuringWrite;
    if (deferred != null) {
      deferred.add(change);
    } else {
      _emit(change);
    }
  }

  /// Saves [entries] in this order and returns them with ids
  /// ([StoredLogEntry.id]): increasing in save order and never reused (in
  /// SQLite, `INTEGER PRIMARY KEY AUTOINCREMENT`). Entries are already in
  /// stored form ([LogEntry.withoutLiveObjects]). A batch is best saved in
  /// one transaction; the sink passes the next one only after this one
  /// completes. The base sends [LogEntriesAdded].
  @protected
  Future<List<StoredLogEntry>> onWriteEntries(List<LogEntry> entries);

  /// A page of entries for [query]; see [LogStore.queryEntries].
  @protected
  Future<LogPage> onQueryEntries(LogQuery query);

  /// All tags of stored entries; see [LogStore.queryTags].
  @protected
  Future<Set<String>> onQueryTags();

  /// Removes all entries. The base sends [AllLogEntriesRemoved].
  @protected
  Future<void> onClear();

  /// Removes entries strictly before [time]. The base sends [LogEntriesRemovedBefore].
  @protected
  Future<void> onRemoveBefore(DateTime time);

  /// Keeps the [count] newest entries in store order and returns the removed
  /// ids (an empty set if there was nothing to remove) or `null` if they
  /// cannot be determined cheaply: the base then sends [LogStoreInvalidated].
  /// In SQL, `DELETE … RETURNING id` provides the ids.
  @protected
  Future<Set<int>?> onRetainNewest(int count);

  /// Releases the store's resources. Called once, from [close]; the base
  /// closes [changes] afterwards. Does nothing by default.
  @protected
  Future<void> onClose() async {}

  void _emit(LogStoreChange change) {
    if (!_changes.isClosed) _changes.add(change);
  }

  void _checkOpen() {
    if (isClosed) throw StateError('$name is closed');
  }
}
