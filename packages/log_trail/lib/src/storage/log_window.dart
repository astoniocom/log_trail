import 'package:collection/collection.dart';
import 'package:log_trail/src/storage/log_filter.dart';
import 'package:log_trail/src/storage/log_query.dart';
import 'package:log_trail/src/storage/log_store_change.dart';
import 'package:log_trail/src/storage/stored_log_entry.dart';

/// Loaded window of the log under [filter]: [entries] newest first, with no duplicates by
/// [StoredLogEntry.id], contiguous from the newest entries to the last one loaded; [next]
/// follows it. The list model for a viewer that reads the log in pages and receives store
/// changes ([LogStoreChange]); independent of the UI.
///
/// The window grows by query pages ([query], [LogPage.next]) and changes in place on store
/// events ([apply]): new entries take their place by time, removed ones are dropped by id, the
/// oldest ones over the limit are discarded ([trim]). While a store query is running
/// ([beginQuery]), changes are additionally remembered: the query result is a snapshot of an
/// unknown moment, which may or may not include them. On completion ([completeQuery]) the page
/// is merged into the window by id, and the remembered changes are applied on top of it in the
/// original order; all operations are idempotent, so the result is correct either way. Until the
/// first page is loaded ([isLoaded]), there is nothing to apply changes to: they are only
/// remembered.
///
/// An entry older than the loaded window is not inserted while there is a continuation: the next
/// page will load it, and the window stays contiguous. [LogStoreInvalidated] is not handled by
/// the window: it means a reload, which is the owner's job.
///
/// ```dart
/// final window = LogWindow(filter: filter, pageSize: 100);
/// window.beginQuery();
/// final page = await reader.queryEntries(window.query);
/// window.completeQuery(page);
/// reader.changes.listen(window.apply);
/// ```
final class LogWindow {
  LogWindow({required this.filter, required this.pageSize}) : assert(pageSize > 0, 'pageSize must be positive');

  /// Conditions selecting the window's entries.
  final LogFilter filter;

  /// How many entries to request at a time ([query]).
  final int pageSize;

  final List<StoredLogEntry> _entries = [];
  final Set<int> _ids = {};
  final Set<String> _addedTags = {};

  bool _isLoaded = false;
  LogQuery? _next;

  /// Changes that arrived during a running store query; `null` when no query is running.
  List<LogStoreChange>? _changesDuringQuery;

  /// First-page query: entries under [filter], newest first, [pageSize] at a time.
  LogQuery get query => LogQuery(filter: filter, newestFirst: true, limit: pageSize);

  /// The window's entries, newest first.
  List<StoredLogEntry> get entries => UnmodifiableListView(_entries);

  /// Tags of entries added to the store while the window exists ([LogEntriesAdded]), including
  /// those not matching [filter]: a tag list requested from the store before these entries does
  /// not contain them.
  Set<String> get addedTags => UnmodifiableSetView(_addedTags);

  /// Whether the first page is loaded ([completeQuery]).
  bool get isLoaded => _isLoaded;

  /// Query for the next page of older entries; `null` means there are no more pages.
  LogQuery? get next => _next;

  /// Whether a store query is running ([beginQuery] without [completeQuery] or [failQuery]).
  bool get isQuerying => _changesDuringQuery != null;

  /// Marks the start of a store query: changes until its completion are remembered to be applied
  /// on top of the result.
  void beginQuery() => _changesDuringQuery = [];

  /// Marks the query as failed: remembered changes are discarded (they are already applied to the
  /// window if it is loaded).
  void failQuery() => _changesDuringQuery = null;

  /// Merges [page] and applies on top of it the changes that arrived during the query; the window
  /// is loaded afterwards ([isLoaded]). The continuation comes from the page, unless everything
  /// was removed during the query.
  ///
  /// Returns whether all entries were removed during the query: any store snapshot taken in that
  /// time (for example, tags) may predate the removal and is then stale.
  bool completeQuery(LogPage page) {
    final changes = _changesDuringQuery ?? const <LogStoreChange>[];
    _changesDuringQuery = null;
    page.entries.forEach(_insert);
    _next = page.next;
    _isLoaded = true;
    changes.forEach(_apply);
    return changes.any((change) => change is AllLogEntriesRemoved);
  }

  /// Applies a store change to the window (except [LogStoreInvalidated]). During a query also
  /// remembers it. Returns whether the window changed.
  bool apply(LogStoreChange change) {
    _changesDuringQuery?.add(change);
    return _isLoaded && _apply(change);
  }

  bool _apply(LogStoreChange change) => switch (change) {
    LogEntriesAdded(:final entries) => _insertAll(entries),
    LogEntriesRemoved() => _remove(change),
    LogStoreInvalidated() => false,
  };

  bool _insertAll(List<StoredLogEntry> added) {
    var isChanged = false;
    for (final stored in added) {
      _addedTags.addAll(stored.entry.tags);
      if (!filter.matches(stored.entry)) continue;
      if (_next != null && _entries.isNotEmpty && stored.cursor.compareTo(_entries.last.cursor) < 0) continue;
      isChanged = _insert(stored) || isChanged;
    }
    return isChanged;
  }

  /// Inserts [stored] at its position in store order; `false` if an entry with this id already
  /// exists.
  bool _insert(StoredLogEntry stored) {
    if (!_ids.add(stored.id)) return false;
    // New entries are usually newer than all loaded ones and go first.
    final index = _entries.isEmpty || stored.cursor.compareTo(_entries.first.cursor) > 0
        ? 0
        : lowerBound(_entries, stored, compare: _newestFirst);
    _entries.insert(index, stored);
    return true;
  }

  bool _remove(LogEntriesRemoved removal) {
    final bool Function(StoredLogEntry stored) isRemoved;
    switch (removal) {
      case LogEntriesRemovedById(:final ids):
        isRemoved = (stored) => ids.contains(stored.id);
      case LogEntriesRemovedBefore(:final time):
        isRemoved = (stored) => stored.entry.time.isBefore(time);
      case AllLogEntriesRemoved():
        _next = null;
        _addedTags.clear();
        isRemoved = (_) => true;
    }
    final countBefore = _entries.length;
    _entries.removeWhere((stored) {
      if (!isRemoved(stored)) return false;
      _ids.remove(stored.id);
      return true;
    });
    return _entries.length != countBefore || removal is AllLogEntriesRemoved;
  }

  /// Discards the oldest entries over [max]; the next page starts right after the last remaining
  /// one. Not during a store query: its result would continue the discarded part. Returns whether
  /// the window changed.
  bool trim(int max) {
    if (isQuerying || _entries.length <= max) return false;
    for (final stored in _entries.sublist(max)) {
      _ids.remove(stored.id);
    }
    _entries.removeRange(max, _entries.length);
    _next = query.startingAfter(_entries.last.cursor);
    return true;
  }

  static int _newestFirst(StoredLogEntry a, StoredLogEntry b) => b.cursor.compareTo(a.cursor);
}
