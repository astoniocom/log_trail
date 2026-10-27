import 'dart:async';

import 'package:log_trail/log_trail.dart';
import 'package:log_trail/storage.dart';
import 'package:test/test.dart';

/// Minimal store on [LogStoreBase]: entry list plus a log of primitive calls.
/// Checks that the base handles everything except storage.
final class _ListStore extends LogStoreBase {
  final List<StoredLogEntry> stored = [];
  final List<String> calls = [];
  int _nextId = 1;

  /// If set, [onWriteEntries] fails with this error.
  Error? writeError;

  /// What [onRetainNewest] returns: ids or `null`.
  Set<int>? Function(int count)? retainResult;

  /// Until completed, [onWriteEntries] does not return.
  Completer<void>? writeGate;

  @override
  String get name => 'ListStore';

  @override
  Future<List<StoredLogEntry>> onWriteEntries(List<LogEntry> entries) async {
    calls.add('write ${entries.length}');
    if (writeGate case final gate?) await gate.future;
    if (writeError case final error?) throw error;
    final batch = [for (final entry in entries) StoredLogEntry(_nextId++, entry)];
    stored.addAll(batch);
    return batch;
  }

  @override
  Future<LogPage> onQueryEntries(LogQuery query) async {
    calls.add('query');
    return queryInMemory(stored, query);
  }

  @override
  Future<Set<String>> onQueryTags() async {
    calls.add('tags');
    return {for (final entry in stored) ...entry.entry.tags};
  }

  @override
  Future<void> onClear() async => calls.add('clear');

  @override
  Future<void> onRemoveBefore(DateTime time) async => calls.add('removeBefore');

  @override
  Future<Set<int>?> onRetainNewest(int count) async {
    calls.add('retain $count');
    final retainResult = this.retainResult;
    return retainResult == null ? const {} : retainResult(count);
  }

  @override
  Future<void> onClose() async => calls.add('close');

  /// Store reports a removal it performed itself.
  void evict(Set<int> ids) => reportChange(LogEntriesRemovedById(ids));
}

LogEntry _entry(String message, int second) =>
    LogEntry(time: DateTime(2026, 1, 1, 12, 0, second), level: LogLevel.info, message: message);

void main() {
  late _ListStore store;
  late List<LogStoreChange> changes;

  setUp(() {
    store = _ListStore();
    changes = [];
    store.changes.listen(changes.add);
  });

  tearDown(() => store.close());

  test('writeEntries passes stored-form entries to the primitive and emits LogEntriesAdded itself', () async {
    final report = Object();
    final written = LogEntry(
      time: DateTime(2026),
      level: LogLevel.error,
      message: 'boom',
      error: LogError.capture(StateError('boom'), report: report),
    );

    final stored = await store.writeEntries([written]);
    await pumpEventQueue();

    expect(store.calls, ['write 1']);
    expect(stored.single.entry.error?.original, isNull);
    expect(stored.single.entry.error?.report, isNull);
    expect(stored.single.entry, written);
    expect(changes.single, isA<LogEntriesAdded>().having((c) => c.entries, 'entries', stored));
  });

  test('change reported by the store during a write is emitted after LogEntriesAdded', () async {
    final store = _ListStore();
    addTearDown(store.close);
    final changes = <LogStoreChange>[];
    store.changes.listen(changes.add);
    store.writeGate = Completer<void>();

    final writing = store.writeEntries([_entry('a', 1)]);
    store.evict({7});
    expect(changes, isEmpty, reason: 'removal deferred until the write ends');
    store.writeGate!.complete();
    await writing;
    await pumpEventQueue();

    expect(changes, [
      isA<LogEntriesAdded>(),
      isA<LogEntriesRemovedById>().having((c) => c.ids, 'ids', {7}),
    ]);
  });

  test('change outside a write is emitted at once; deferred changes survive a write failure', () async {
    store.evict({1});
    await pumpEventQueue();
    expect(changes.single, isA<LogEntriesRemovedById>());

    store.writeError = StateError('disk full');
    store.writeGate = Completer<void>();
    final writing = store.writeEntries([_entry('a', 1)]);
    store.evict({2});
    store.writeGate!.complete();
    await expectLater(writing, throwsStateError);
    await pumpEventQueue();

    expect(changes, hasLength(2), reason: 'no LogEntriesAdded, deferred removal emitted');
    expect(changes.last, isA<LogEntriesRemovedById>().having((c) => c.ids, 'ids', {2}));

    store.evict({3});
    await pumpEventQueue();
    expect(changes.last, isA<LogEntriesRemovedById>().having((c) => c.ids, 'ids', {3}), reason: 'immediate again');
  });

  test('clear and removeBefore call the primitive and emit an event', () async {
    await store.clear();
    await store.removeBefore(DateTime(2026, 1, 1, 12, 0, 5));
    await pumpEventQueue();

    expect(store.calls, ['clear', 'removeBefore']);
    expect(changes, [
      isA<AllLogEntriesRemoved>(),
      isA<LogEntriesRemovedBefore>().having((c) => c.time, 'time', DateTime(2026, 1, 1, 12, 0, 5)),
    ]);
  });

  test(
    'retainNewest: ids give LogEntriesRemovedById, empty set gives nothing, null gives LogStoreInvalidated',
    () async {
      store.retainResult = (_) => {1, 2};
      await store.retainNewest(3);
      store.retainResult = (_) => {};
      await store.retainNewest(3);
      store.retainResult = (_) => null;
      await store.retainNewest(3);
      await pumpEventQueue();

      expect(store.calls, ['retain 3', 'retain 3', 'retain 3']);
      expect(changes, [
        isA<LogEntriesRemovedById>().having((c) => c.ids, 'ids', {1, 2}),
        isA<LogStoreInvalidated>(),
      ]);
    },
  );

  test('reads go through the primitives', () async {
    await store.writeEntries([_entry('a', 1)]);

    final page = await store.queryEntries();
    final tags = await store.queryTags();

    expect(page.entries.single.entry.message, 'a');
    expect(tags, isEmpty);
    expect(store.calls, ['write 1', 'query', 'tags']);
  });

  test('close calls the primitive once and closes changes; operations after it throw StateError', () async {
    final store = _ListStore();
    final done = store.changes.toList();

    final first = store.close();
    final second = store.close();
    await Future.wait([first, second]);

    expect(identical(first, second), isTrue, reason: 'repeated close returns the first result');
    expect(store.isClosed, isTrue);
    expect(store.calls, ['close']);
    await expectLater(done, completion(isEmpty));
    await expectLater(store.queryEntries(), throwsStateError);
    await expectLater(store.queryTags(), throwsStateError);
    await expectLater(store.writeEntries([_entry('b', 2)]), throwsStateError);
    await expectLater(store.clear(), throwsStateError);
    await expectLater(store.removeBefore(DateTime(2026)), throwsStateError);
    await expectLater(store.retainNewest(0), throwsStateError);
    expect(store.calls, ['close'], reason: 'primitives are not called after close');
  });

  test('StateError message names the store by name', () async {
    final store = _ListStore();
    await store.close();

    await expectLater(
      store.queryTags(),
      throwsA(isA<StateError>().having((e) => e.message, 'message', 'ListStore is closed')),
    );
  });

  test('in debug onWriteEntries must return one entry per passed entry', () async {
    final store = _BrokenStore();
    addTearDown(store.close);

    await expectLater(store.writeEntries([_entry('a', 1)]), throwsA(isA<AssertionError>()));
  });
}

/// Store that loses entries: returns an empty list.
final class _BrokenStore extends LogStoreBase {
  @override
  Future<List<StoredLogEntry>> onWriteEntries(List<LogEntry> entries) async => const [];

  @override
  Future<LogPage> onQueryEntries(LogQuery query) async => LogPage(const []);

  @override
  Future<Set<String>> onQueryTags() async => const {};

  @override
  Future<void> onClear() async {}

  @override
  Future<void> onRemoveBefore(DateTime time) async {}

  @override
  Future<Set<int>?> onRetainNewest(int count) async => const {};
}
