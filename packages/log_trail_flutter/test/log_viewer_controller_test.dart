import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:log_trail_flutter/log_trail_flutter.dart';
import 'package:log_trail_flutter/widgets.dart';

class _StoreUnavailableException implements Exception {
  const _StoreUnavailableException();
}

/// The controller only reads, so the fake implements only [LogReader].
class _MemoryReader implements LogReader {
  _MemoryReader(Iterable<LogEntry> entries) {
    addAll(entries);
  }

  /// Entries in store order; ids are assigned in insertion order.
  final List<StoredLogEntry> entries = [];
  int _nextId = 1;
  final _changes = StreamController<LogStoreChange>.broadcast();
  final List<LogQuery> queries = [];

  /// While not completed, [queryEntries] does not return a result.
  Completer<void>? queryGate;

  /// Snapshot entries after [queryGate]: the query then also captures entries
  /// stored during loading.
  bool snapshotAfterGate = false;

  /// If set, [queryEntries] fails with this error.
  Exception? queryError;

  /// If set, [queryTags] fails with this error.
  Exception? tagsError;

  @override
  Stream<LogStoreChange> get changes => _changes.stream;

  /// Stores [entry] without an event, like content of past sessions:
  /// in store order, after entries with the same time.
  StoredLogEntry add(LogEntry entry) {
    final stored = StoredLogEntry(_nextId++, entry);
    final index = entries.indexWhere((other) => other.entry.time.isAfter(entry.time));
    entries.insert(index < 0 ? entries.length : index, stored);
    return stored;
  }

  void addAll(Iterable<LogEntry> entries) => entries.forEach(add);

  void clear() => entries.clear();

  /// Like the store's `writeEntries`: stores and reports the change.
  void write(List<LogEntry> entries) {
    _changes.add(LogEntriesAdded([for (final entry in entries) add(entry)]));
  }

  /// Removes matching entries and reports their ids, like a store with a limit.
  void remove(bool Function(LogEntry entry) test) {
    final removed = {
      for (final stored in entries)
        if (test(stored.entry)) stored.id,
    };
    entries.removeWhere((stored) => removed.contains(stored.id));
    _changes.add(LogEntriesRemovedById(removed));
  }

  /// Like `removeBefore` and `clear`: removes entries before [before] (all if null) and reports the bound.
  void removeBefore(DateTime? before) {
    entries.removeWhere((stored) => before == null || stored.entry.time.isBefore(before));
    _changes.add(before == null ? const AllLogEntriesRemoved() : LogEntriesRemovedBefore(before));
  }

  /// A change the store cannot describe more precisely.
  void invalidate() => _changes.add(const LogStoreInvalidated());

  void failChanges(Exception error) => _changes.addError(error);

  @override
  Future<LogPage> queryEntries([LogQuery query = const LogQuery()]) async {
    queries.add(query);
    final snapshot = [...entries];
    final gate = queryGate;
    if (gate != null) await gate.future;
    final queryError = this.queryError;
    if (queryError != null) throw queryError;
    return queryInMemory(snapshotAfterGate ? entries : snapshot, query);
  }

  @override
  Future<Set<String>> queryTags() async {
    final tagsError = this.tagsError;
    if (tagsError != null) throw tagsError;
    return {for (final stored in entries) ...stored.entry.tags};
  }

  Future<void> close() => _changes.close();
}

LogEntry _entry(String message, int second, {LogLevel level = LogLevel.info, Set<String> tags = const {}}) =>
    LogEntry(time: DateTime(2026, 1, 1, 12, 0, second), level: level, message: message, tags: tags);

extension on LogViewerController {
  Iterable<String>? get messages => entries?.map((e) => e.entry.message);
}

void main() {
  late _MemoryReader store;

  setUp(
    () => store = _MemoryReader([
      _entry('first', 1, tags: {'a'}),
    ]),
  );
  tearDown(() => store.close());

  LogViewerController createController({int pageSize = 100, int maxEntries = 2000}) {
    final controller = LogViewerController(
      store,
      diagnostics: DiagnosticReporter.console,
      pageSize: pageSize,
      maxEntries: maxEntries,
    )..start();
    addTearDown(controller.dispose);
    return controller;
  }

  test('updateFilter applies the edit to the current filter and reloads the first page', () async {
    final weekAgo = DateTime(2026, 3, 8);
    final controller = createController()..setFilter(LogFilter(after: weekAgo));
    await pumpEventQueue();
    final queriesBefore = store.queries.length;

    controller.updateFilter((current) => current.copyWith(levels: {LogLevel.error}));
    await pumpEventQueue();

    expect(controller.filter.after, weekAgo, reason: 'condition untouched by the edit is kept');
    expect(controller.filter.levels, {LogLevel.error});
    expect(store.queries, hasLength(queriesBefore + 1));
    expect(store.queries.last.filter, controller.filter);
  });

  test('before start the controller neither reads nor subscribes to the store; setFilter applies at start', () async {
    final controller = LogViewerController(store, diagnostics: DiagnosticReporter.console);
    addTearDown(controller.dispose);
    controller
      ..setFilter(const LogFilter(text: 'first'))
      ..reload();
    await pumpEventQueue();

    expect(controller.isStarted, isFalse);
    expect(store.queries, isEmpty);
    expect(store._changes.hasListener, isFalse);

    controller
      ..start()
      ..start();
    await pumpEventQueue();

    expect(store.queries.single.filter.text, 'first', reason: 'one load, with the filter');
    expect(controller.messages, ['first']);
  });

  test('no entries before the first page loads, then store entries and tags', () async {
    final controller = createController();
    expect(controller.entries, isNull);
    expect(controller.loadError, isNull);

    var notifications = 0;
    controller.addListener(() => notifications++);
    await pumpEventQueue();

    expect(controller.messages, ['first']);
    expect(controller.availableTags, {'a'});
    expect(controller.hasMore, isFalse);
    expect(notifications, 1);
  });

  test('queries the first page newest first with the page size', () async {
    createController(pageSize: 20);
    await pumpEventQueue();

    final query = store.queries.single;
    expect(query.newestFirst, isTrue);
    expect(query.limit, 20);
    expect(query.startAfter, isNull);
  });

  test('a new entry goes first without reloading, its tags become available', () async {
    final controller = createController();
    await pumpEventQueue();

    store.write([
      _entry('second', 2, tags: {'b'}),
    ]);
    await pumpEventQueue();

    expect(controller.messages, ['second', 'first']);
    expect(controller.availableTags, {'a', 'b'});
    expect(store.queries, hasLength(1), reason: 'the store is not re-read');
  });

  test('a new entry not matching the filter is hidden, but its tag is available in the filter', () async {
    final controller = createController()..setFilter(const LogFilter(levels: {LogLevel.error}));
    await pumpEventQueue();
    expect(controller.messages, isEmpty);

    store.write([
      _entry('info', 2, tags: {'b'}),
    ]);
    await pumpEventQueue();

    expect(controller.messages, isEmpty);
    expect(controller.availableTags, contains('b'));
  });

  test('a batch of entries goes first, newest first, with a single notification', () async {
    final controller = createController();
    await pumpEventQueue();
    var notifications = 0;
    controller.addListener(() => notifications++);

    store.write([
      _entry('second', 2, tags: {'b'}),
      _entry('third', 3, tags: {'c'}),
    ]);
    await pumpEventQueue();

    expect(controller.messages, ['third', 'second', 'first']);
    expect(controller.availableTags, {'a', 'b', 'c'});
    expect(notifications, 1);
  });

  test('a batch with no matching entries and no new tags does not notify', () async {
    final controller = createController()..setFilter(const LogFilter(levels: {LogLevel.error}));
    await pumpEventQueue();
    var notifications = 0;
    controller.addListener(() => notifications++);

    store.write([
      _entry('info', 2, tags: {'a'}),
    ]);
    await pumpEventQueue();

    expect(notifications, 0);
  });

  group('maxEntries', () {
    setUp(() {
      store
        ..clear()
        ..addAll([for (var i = 0; i < 5; i++) _entry('m$i', i)]);
    });

    test('pageSize greater than maxEntries is an error', () {
      expect(
        () => LogViewerController(store, diagnostics: DiagnosticReporter.console, pageSize: 10, maxEntries: 5),
        throwsA(isA<AssertionError>()),
      );
    });

    test('new entries over the limit evict old ones, loading more continues without gaps or repeats', () async {
      final controller = createController(pageSize: 2, maxEntries: 4);
      await pumpEventQueue();
      await controller.loadMore();
      expect(controller.messages, ['m4', 'm3', 'm2', 'm1']);

      store.write([_entry('m5', 5), _entry('m6', 6)]);
      await pumpEventQueue();
      expect(controller.messages, ['m6', 'm5', 'm4', 'm3']);
      expect(controller.hasMore, isTrue);

      while (controller.hasMore) {
        await controller.loadMore();
      }
      expect(controller.messages, ['m6', 'm5', 'm4', 'm3', 'm2', 'm1', 'm0']);
    });

    test('entries with the same time as the last kept one load without loss or repeats', () async {
      store
        ..clear()
        ..addAll([
          for (final message in ['a', 'b', 'c', 'd']) _entry(message, 1),
        ]);
      final controller = createController(pageSize: 2, maxEntries: 2);
      await pumpEventQueue();
      expect(controller.messages, ['d', 'c']);

      store.write([_entry('e', 2)]);
      await pumpEventQueue();
      expect(controller.messages, ['e', 'd']);

      await controller.loadMore();
      expect(controller.messages, ['e', 'd', 'c', 'b'], reason: 'full page after dropping the repeat at the bound');
      while (controller.hasMore) {
        await controller.loadMore();
      }
      expect(controller.messages, ['e', 'd', 'c', 'b', 'a']);
    });

    test('the limit is not applied while loading more, else the list would have a gap; the next entry does', () async {
      final controller = createController(pageSize: 2, maxEntries: 2);
      await pumpEventQueue();
      expect(controller.messages, ['m4', 'm3']);

      final gate = store.queryGate = Completer<void>();
      final loading = controller.loadMore();
      await pumpEventQueue();
      store.write([_entry('m5', 5)]);
      await pumpEventQueue();
      expect(controller.messages, ['m5', 'm4', 'm3'], reason: 'new entry shown, no eviction');
      gate.complete();
      store.queryGate = null;
      await loading;

      expect(controller.messages, ['m5', 'm4', 'm3', 'm2', 'm1'], reason: 'loaded page without a gap');
      expect(controller.isLoadingMore, isFalse);

      store.write([_entry('m6', 6)]);
      await pumpEventQueue();
      expect(controller.messages, ['m6', 'm5'], reason: 'limit applied on the next entry');

      await controller.loadMore();
      expect(controller.messages, ['m6', 'm5', 'm4', 'm3'], reason: 'continues right after the last kept one');
    });

    test('an early-phase entry with a past time goes to its place, not first', () async {
      final controller = createController();
      await pumpEventQueue();
      expect(controller.messages, ['m4', 'm3', 'm2', 'm1', 'm0']);

      store.write([_entry('replayed', 2)]);
      await pumpEventQueue();

      expect(controller.messages, ['m4', 'm3', 'replayed', 'm2', 'm1', 'm0']);
    });

    test('an entry older than the loaded window is not inserted when more exists: loadMore will load it', () async {
      final controller = createController(pageSize: 2, maxEntries: 4);
      await pumpEventQueue();
      expect(controller.messages, ['m4', 'm3']);

      store.write([_entry('old', 1)]);
      await pumpEventQueue();
      expect(controller.messages, ['m4', 'm3'], reason: 'the window stays contiguous');

      while (controller.hasMore) {
        await controller.loadMore();
      }
      expect(controller.messages, ['m4', 'm3', 'm2', 'old', 'm1', 'm0'], reason: 'loaded in its place, no repeat');
    });
  });

  test('removed entries leave the list without re-reading', () async {
    store.add(_entry('second', 2));
    final controller = createController();
    await pumpEventQueue();

    store.remove((entry) => entry.message == 'first');
    await pumpEventQueue();

    expect(controller.messages, ['second']);
    expect(store.queries, hasLength(1), reason: 'the store is not re-read');
  });

  test('of value-equal entries, the one whose id was removed is dropped', () async {
    final duplicate = store.add(_entry('first', 1, tags: {'a'}));
    final controller = createController();
    await pumpEventQueue();
    expect(controller.messages, ['first', 'first']);

    store._changes.add(LogEntriesRemovedById({duplicate.id}));
    await pumpEventQueue();

    expect(controller.entries?.map((e) => e.id), [store.entries.first.id]);
  });

  test('removal of unknown ids does not change the list or notify', () async {
    final controller = createController();
    await pumpEventQueue();
    var notifications = 0;
    controller.addListener(() => notifications++);

    store._changes.add(LogEntriesRemovedById(const {999}));
    store._changes.add(LogEntriesRemovedBefore(DateTime(2026)));
    await pumpEventQueue();

    expect(controller.messages, ['first']);
    expect(notifications, 0);
  });

  test('removal by bound drops old entries in place, loaded pages are kept', () async {
    store
      ..clear()
      ..addAll([for (var i = 0; i < 25; i++) _entry('m$i', i)]);
    final controller = createController(pageSize: 10);
    await pumpEventQueue();
    await controller.loadMore();
    final queriesBefore = store.queries.length;

    store.removeBefore(DateTime(2026, 1, 1, 12, 0, 8));
    await pumpEventQueue();

    expect(controller.messages, [for (var i = 24; i >= 8; i--) 'm$i']);
    expect(controller.hasMore, isTrue);
    expect(store.queries, hasLength(queriesBefore), reason: 'the store is not re-read');
  });

  test('removal of all entries clears the list, tags and loading more', () async {
    store
      ..clear()
      ..addAll([
        for (var i = 0; i < 25; i++) _entry('m$i', i, tags: {'t'}),
      ]);
    final controller = createController(pageSize: 10);
    await pumpEventQueue();

    store.removeBefore(null);
    await pumpEventQueue();

    expect(controller.messages, isEmpty);
    expect(controller.hasMore, isFalse);
    expect(controller.availableTags, isEmpty);
  });

  test('LogStoreInvalidated re-reads the first page', () async {
    final controller = createController();
    await pumpEventQueue();

    store.add(_entry('silently added', 2));
    store.invalidate();
    await pumpEventQueue();

    expect(controller.messages, ['silently added', 'first']);
    expect(store.queries, hasLength(2));
  });

  test('removal during the first page load applies to its result', () async {
    store.add(_entry('second', 2));
    final gate = store.queryGate = Completer<void>();
    final controller = createController();

    store.remove((entry) => entry.message == 'first');
    await pumpEventQueue();
    gate.complete();
    await pumpEventQueue();

    expect(controller.messages, ['second'], reason: 'query snapshot taken before the removal');
  });

  test('an entry stored after removing all during loading is shown', () async {
    final gate = store.queryGate = Completer<void>();
    store.snapshotAfterGate = true;
    final controller = createController();

    store
      ..removeBefore(null)
      ..write([
        _entry('after clear', 2, tags: {'b'}),
      ]);
    await pumpEventQueue();
    gate.complete();
    await pumpEventQueue();

    expect(controller.messages, ['after clear'], reason: 'the query saw both the removal and the new entry');
    expect(controller.availableTags, {'b'});
  });

  test('removal while loading more applies to the loaded page', () async {
    store
      ..clear()
      ..addAll([for (var i = 0; i < 25; i++) _entry('m$i', i)]);
    final controller = createController(pageSize: 10);
    await pumpEventQueue();

    final gate = store.queryGate = Completer<void>();
    final loading = controller.loadMore();
    await pumpEventQueue();
    store.remove((entry) => entry.message == 'm10');
    await pumpEventQueue();
    gate.complete();
    await loading;

    expect(controller.entries, hasLength(19));
    expect(controller.messages, isNot(contains('m10')));
  });

  test('over a full InMemoryLogStore a write with eviction does not reset the list', () async {
    final memoryStore = InMemoryLogStore(limit: 3);
    addTearDown(memoryStore.close);
    await memoryStore.writeEntries([for (var i = 0; i < 3; i++) _entry('m$i', i)]);
    final controller = LogViewerController(memoryStore, diagnostics: DiagnosticReporter.console, pageSize: 2)..start();
    addTearDown(controller.dispose);
    await pumpEventQueue();
    await controller.loadMore();
    expect(controller.entries, hasLength(3));

    var resets = 0;
    controller.addListener(() {
      if (controller.entries == null) resets++;
    });
    for (var i = 3; i < 13; i++) {
      await memoryStore.writeEntries([_entry('m$i', i)]);
    }
    await pumpEventQueue();

    expect(resets, 0);
    expect(controller.messages, ['m12', 'm11', 'm10']);
  });

  test('an entry stored during loading is neither lost nor duplicated', () async {
    final gate = store.queryGate = Completer<void>();
    store.snapshotAfterGate = true;
    final controller = createController();

    store.write([
      _entry('during load', 2, tags: {'b'}),
    ]);
    await pumpEventQueue();
    expect(controller.entries, isNull, reason: 'no entries are shown until loading completes');
    gate.complete();
    await pumpEventQueue();

    expect(controller.messages, ['during load', 'first']);
    expect(controller.availableTags, {'a', 'b'});
  });

  test('an entry stored during loading and missing from its result is added', () async {
    final gate = store.queryGate = Completer<void>();
    final controller = createController();

    store.write([_entry('during load', 2)]);
    await pumpEventQueue();
    gate.complete();
    await pumpEventQueue();

    expect(controller.messages, ['during load', 'first']);
  });

  test('loadMore loads older entries by startAfter while they exist', () async {
    store
      ..clear()
      ..addAll([for (var i = 0; i < 25; i++) _entry('m$i', i)]);
    final controller = createController(pageSize: 10);
    await pumpEventQueue();
    expect(controller.entries, hasLength(10));
    expect(controller.hasMore, isTrue);

    final loading = controller.loadMore();
    expect(controller.isLoadingMore, isTrue);
    await loading;
    expect(controller.isLoadingMore, isFalse);
    expect(controller.entries, hasLength(20));
    expect(store.queries.last.startAfter, isNotNull);

    await controller.loadMore();
    expect(controller.messages?.last, 'm0');
    expect(controller.hasMore, isFalse);

    final queriesBefore = store.queries.length;
    await controller.loadMore();
    expect(store.queries, hasLength(queriesBefore), reason: 'no queries without a next page');
  });

  test('a repeated loadMore while loading more does not make a second query', () async {
    store
      ..clear()
      ..addAll([for (var i = 0; i < 25; i++) _entry('m$i', i)]);
    final controller = createController(pageSize: 10);
    await pumpEventQueue();

    final gate = store.queryGate = Completer<void>();
    final first = controller.loadMore();
    final second = controller.loadMore();
    gate.complete();
    await Future.wait([first, second]);

    expect(store.queries, hasLength(2));
    expect(controller.entries, hasLength(20));
  });

  test('a load-more error is remembered, loadMore does not retry it, retryLoadMore does', () async {
    store
      ..clear()
      ..addAll([for (var i = 0; i < 25; i++) _entry('m$i', i)]);
    final controller = createController(pageSize: 10);
    await pumpEventQueue();

    store.queryError = const _StoreUnavailableException();
    await controller.loadMore();
    expect(controller.loadMoreError, isA<_StoreUnavailableException>());
    expect(controller.isLoadingMore, isFalse);
    expect(controller.hasMore, isTrue);

    final queriesBefore = store.queries.length;
    await controller.loadMore();
    expect(store.queries, hasLength(queriesBefore));

    store.queryError = null;
    await controller.retryLoadMore();
    expect(controller.loadMoreError, isNull);
    expect(controller.entries, hasLength(20));
  });

  test('setFilter re-reads the first page with the filter in the query', () async {
    store.add(_entry('boom', 2, level: LogLevel.error, tags: {'net'}));
    final controller = createController();
    await pumpEventQueue();

    controller.setFilter(const LogFilter(levels: {LogLevel.error}, tags: {'net'}));
    expect(controller.entries, isNull, reason: 'entries are reset while reloading');
    await pumpEventQueue();

    expect(controller.filter.levels, {LogLevel.error});
    expect(store.queries.last.filter.levels, {LogLevel.error});
    expect(store.queries.last.filter.tags, {'net'});
    expect(controller.messages, ['boom']);
  });

  test('the result of a stale load is discarded', () async {
    final gate = store.queryGate = Completer<void>();
    final controller = createController();
    await pumpEventQueue();

    store.queryGate = null;
    controller.setFilter(const LogFilter(levels: {LogLevel.error}));
    await pumpEventQueue();
    expect(controller.messages, isEmpty, reason: 'the second load completed');

    gate.complete();
    await pumpEventQueue();
    expect(controller.messages, isEmpty, reason: 'the first load did not overwrite the second result');
  });

  test('a load failure goes to diagnostics with a stack trace', () async {
    store.queryError = const _StoreUnavailableException();
    final diagnostics = <LogDiagnostic>[];
    final controller = LogViewerController(store, diagnostics: DiagnosticReporter(diagnostics.add))..start();
    addTearDown(controller.dispose);
    await pumpEventQueue();

    expect(diagnostics.single.message, 'LogViewerController: failed to load logs');
    expect(diagnostics.single.error, isA<_StoreUnavailableException>());
    expect(diagnostics.single.stackTrace, isNotNull);
  });

  test('a first page load error is kept, reload retries the load', () async {
    store.queryError = const _StoreUnavailableException();
    final controller = createController();
    await pumpEventQueue();

    expect(controller.loadError, isA<_StoreUnavailableException>());
    expect(controller.entries, isNull);

    store.queryError = null;
    controller.reload();
    expect(controller.loadError, isNull);
    await pumpEventQueue();

    expect(controller.messages, ['first']);
  });

  test('a tags query failure is also a load error, as is, unwrapped; nothing reaches the zone', () async {
    store.tagsError = const _StoreUnavailableException();
    final unhandled = <Object>[];
    late final LogViewerController controller;

    await runZonedGuarded(() async {
      controller = createController();
      await pumpEventQueue();
    }, (error, _) => unhandled.add(error));

    expect(unhandled, isEmpty);
    expect(controller.loadError, isA<_StoreUnavailableException>());
    expect(controller.entries, isNull);
  });

  test('if both first page queries fail, no error reaches the zone', () async {
    store
      ..queryError = const _StoreUnavailableException()
      ..tagsError = const _StoreUnavailableException();
    final unhandled = <Object>[];

    await runZonedGuarded(() async {
      createController();
      await pumpEventQueue();
    }, (error, _) => unhandled.add(error));

    expect(unhandled, isEmpty);
  });

  test('an error in the changes stream does not reach the zone, the first page is re-read', () async {
    final controller = createController();
    await pumpEventQueue();
    final queriesBefore = store.queries.length;

    final unhandled = <Object>[];
    await runZonedGuarded(() async {
      store.failChanges(const _StoreUnavailableException());
      await pumpEventQueue();
    }, (error, _) => unhandled.add(error));

    expect(unhandled, isEmpty);
    expect(store.queries.length, greaterThan(queriesBefore));
    expect(controller.messages, ['first']);
  });

  test('dispose during loading: the result is not applied and listeners are not notified', () async {
    final gate = store.queryGate = Completer<void>();
    final controller = LogViewerController(store, diagnostics: DiagnosticReporter.console)..start();
    var notifications = 0;
    controller
      ..addListener(() => notifications++)
      ..dispose();

    gate.complete();
    await pumpEventQueue();

    expect(notifications, 0);
  });

  test('dispose during a failed load does not notify listeners', () async {
    final gate = store.queryGate = Completer<void>();
    store.queryError = const _StoreUnavailableException();
    final controller = LogViewerController(store, diagnostics: DiagnosticReporter.console)..start();
    var notifications = 0;
    controller
      ..addListener(() => notifications++)
      ..dispose();

    gate.complete();
    await pumpEventQueue();

    expect(notifications, 0);
  });

  test('dispose unsubscribes from changes but does not close the store', () async {
    final controller = LogViewerController(store, diagnostics: DiagnosticReporter.console)..start();
    await pumpEventQueue();
    controller.dispose();

    expect(store._changes.hasListener, isFalse);
    expect(store._changes.isClosed, isFalse);
  });
}
