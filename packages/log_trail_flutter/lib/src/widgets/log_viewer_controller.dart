import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:log_trail/log_trail.dart';
import 'package:log_trail/storage.dart';

/// Filter edit: builds a new filter from [current], the filter in effect when the edit is
/// applied ([LogViewerController.updateFilter]). A part of the screen that edits several
/// conditions (the filter sheet: levels, tags, text) thus does not overwrite conditions
/// someone else may have changed in the meantime.
typedef LogFilterUpdate = LogFilter Function(LogFilter current);

/// Widget-free state of the log viewer: first page from [reader], loading more older entries,
/// the filter, and updates from [LogReader.changes].
///
/// Construction starts nothing: [start] subscribes to changes and loads the first page
/// (`LogViewerPage` calls it itself, also for an external controller). Listeners are notified
/// of every state change. `LogViewerPage` is built on top of it; it also suits a custom list
/// (for example, Cupertino).
///
/// Loaded entries are a [LogWindow] under [filter]: a contiguous stretch of the log from the
/// newest entries to the last one loaded. Store changes modify it in place, and an entry that
/// arrives during a query is neither lost nor duplicated. The first page is re-read only on
/// [LogStoreInvalidated] and after an error in the changes stream.
///
/// Does not own the store and cannot close it: reading ([LogReader]) is enough; [dispose]
/// only unsubscribes from changes.
class LogViewerController extends ChangeNotifier {
  LogViewerController(
    this.reader, {
    required this.diagnostics,
    this.pageSize = defaultPageSize,
    this.maxEntries = defaultMaxEntries,
    LogFilter filter = const LogFilter(),
  }) : assert(maxEntries >= pageSize, 'maxEntries must not be less than pageSize'),
       _window = LogWindow(filter: filter, pageSize: pageSize);

  /// Defaults for [pageSize] and [maxEntries]; `LogViewerPage` uses the same.
  static const int defaultPageSize = 100;
  static const int defaultMaxEntries = 2000;

  final LogReader reader;

  /// Where store read failures go, with stack traces, like in the rest of the library: usually
  /// the root's channel ([RootLogger.diagnostics]), so the handler set on the root also sees
  /// viewer failures. There is no default: the viewer is not attached to the root and cannot
  /// obtain the channel itself, and a forgotten parameter would silently send failures to the
  /// console. For a prototype pass [DiagnosticReporter.console] explicitly. The user sees the
  /// failure through [loadError] and [loadMoreError].
  final DiagnosticReporter diagnostics;

  /// How many entries to load at a time ([loadMore]).
  final int pageSize;

  /// How many entries to keep while the screen is open and new ones arrive: otherwise the list
  /// would grow without bound over hours of use. The oldest entries over the limit are dropped
  /// and can be loaded again ([loadMore]).
  ///
  /// The limit is applied when new entries arrive and no store query is running. Not on loading
  /// more: scrolling to older entries would drop them immediately. Not during loading more: the
  /// loaded page would continue the dropped part. So the list may temporarily exceed the limit;
  /// the first new entry after that brings it back to the limit.
  final int maxEntries;

  /// Loaded window of the log under the current filter. A new one for every first-page load
  /// ([reload]): the result of a query started for the previous window is discarded.
  LogWindow _window;

  Object? _loadError;
  Object? _loadMoreError;
  Set<String> _availableTags = {};
  bool _isDisposed = false;

  /// Subscription to [LogReader.changes]; `null` before [start].
  StreamSubscription<LogStoreChange>? _changesSubscription;

  LogFilter get filter => _window.filter;

  /// Whether [start] has been called.
  bool get isStarted => _changesSubscription != null;

  /// Entries matching [filter], newest first. `null` until the first page is loaded, including
  /// after an error ([loadError]).
  List<StoredLogEntry>? get entries => _window.isLoaded ? _window.entries : null;

  /// Error of the last first-page load; `null` if there was none.
  Object? get loadError => _loadError;

  /// Whether there are entries older than the loaded ones.
  bool get hasMore => _window.next != null;
  bool get isLoadingMore => _window.isLoaded && _window.isQuerying;

  /// Error of the last loading more; until it is cleared ([retryLoadMore]), [loadMore] does
  /// nothing: scrolling must not repeat the failure in a loop.
  Object? get loadMoreError => _loadMoreError;

  /// Tags of the store's entries, including those that arrived via [LogReader.changes]: for the
  /// list in the filter, which does not depend on the loaded pages.
  ///
  /// Tags of removed entries remain until a reload ([reload], [setFilter]), except when all
  /// entries are removed: re-reading tags on every eviction by the store limit is pointless, and
  /// selecting such a tag only shows an empty list.
  Set<String> get availableTags => UnmodifiableSetView(_availableTags);

  /// Subscribes to store changes and loads the first page. A repeated call does nothing; to load
  /// again, use [reload].
  void start() {
    if (isStarted) return;
    // Subscribe before loading: otherwise an entry between the query and the subscription is lost.
    _changesSubscription = reader.changes.listen(_onStoreChange, onError: _onStoreChangesError);
    unawaited(_loadFirstPage());
  }

  @override
  void dispose() {
    _isDisposed = true;
    unawaited(_changesSubscription?.cancel());
    super.dispose();
  }

  void _onStoreChange(LogStoreChange change) {
    if (change is LogStoreInvalidated) {
      reload();
      return;
    }
    final window = _window;
    var isWindowChanged = window.apply(change);
    if (change is LogEntriesAdded) isWindowChanged = window.trim(maxEntries) || isWindowChanged;
    final tags = _tagsAfter(_availableTags, change);
    if (!isWindowChanged && identical(tags, _availableTags)) return;
    _availableTags = tags;
    // Until the first page is loaded, nothing has changed externally: its completion notifies.
    if (window.isLoaded) notifyListeners();
  }

  /// An error in the changes stream must not escape to the zone: from there it would reach
  /// [PlatformDispatcher.onError] and end up in the log again. A reload makes up for missed
  /// changes; if the store is broken, the reload shows the error.
  void _onStoreChangesError(Object error, StackTrace stack) {
    _report('LogViewerController: store changes failed', error, stack);
    reload();
  }

  /// Reloads the first page: [entries] and [loadError] are cleared for the duration of the load.
  /// Does nothing before [start], which loads itself.
  void reload() => _reload(filter);

  /// Applies [filter] and reloads the first page.
  void setFilter(LogFilter filter) => _reload(filter);

  /// Applies [update] to the current [filter] and reloads the first page: for edits of some
  /// conditions that must keep the others as they are now (the filter sheet).
  void updateFilter(LogFilterUpdate update) => _reload(update(filter));

  void _reload(LogFilter filter) {
    _window = LogWindow(filter: filter, pageSize: pageSize);
    _loadError = null;
    _loadMoreError = null;
    if (!isStarted) return;
    notifyListeners();
    unawaited(_loadFirstPage());
  }

  Future<void> _loadFirstPage() async {
    final window = _window..beginQuery();
    try {
      // Both queries at once: they are independent. Future.wait rethrows the first error as is
      // (not wrapped, unlike `(a, b).wait`) and does not let the second escape to the zone; the
      // values are then read from their typed futures, already completed.
      final pageFuture = reader.queryEntries(window.query);
      final tagsFuture = reader.queryTags();
      await Future.wait<void>([pageFuture, tagsFuture]);
      final page = await pageFuture;
      final tags = await tagsFuture;
      if (_isDisposed || !identical(window, _window)) return;
      final isCleared = window.completeQuery(page);
      // Tags are a snapshot of an unknown moment, like the page: entries that arrived after it may
      // be missing from it, and if the log was cleared during the query, the snapshot may predate
      // the clearing, so only the tags of entries added after it are valid.
      _availableTags = isCleared
          ? {...window.addedTags}
          : tags.containsAll(window.addedTags)
          ? tags
          : {...tags, ...window.addedTags};
      notifyListeners();
    } on Object catch (error, stack) {
      _report('LogViewerController: failed to load logs', error, stack);
      if (_isDisposed || !identical(window, _window)) return;
      window.failQuery();
      _loadError = error;
      notifyListeners();
    }
  }

  /// Loads the next page of older entries if there is one and no other load is running. Safe to
  /// call on every scroll event.
  Future<void> loadMore() async {
    final window = _window;
    final next = window.next;
    if (next == null || window.isQuerying || _loadMoreError != null) return;
    window.beginQuery();
    notifyListeners();
    try {
      final page = await reader.queryEntries(next);
      if (_isDisposed || !identical(window, _window)) return;
      window.completeQuery(page);
      notifyListeners();
    } on Object catch (error, stack) {
      _report('LogViewerController: failed to load more logs', error, stack);
      if (_isDisposed || !identical(window, _window)) return;
      window.failQuery();
      _loadMoreError = error;
      notifyListeners();
    }
  }

  /// Clears [loadMoreError] and retries loading more.
  Future<void> retryLoadMore() {
    _loadMoreError = null;
    notifyListeners();
    return loadMore();
  }

  void _report(String message, Object error, StackTrace stackTrace) =>
      diagnostics.report(LogDiagnostic(message, error: error, stackTrace: stackTrace));
}

/// [tags] after [change]; the same set if there are no new tags.
Set<String> _tagsAfter(Set<String> tags, LogStoreChange change) {
  switch (change) {
    case LogEntriesAdded(:final entries):
      final added = {for (final stored in entries) ...stored.entry.tags};
      return tags.containsAll(added) ? tags : {...tags, ...added};
    case AllLogEntriesRemoved():
      return {};
    case LogEntriesRemoved() || LogStoreInvalidated():
      return tags;
  }
}
