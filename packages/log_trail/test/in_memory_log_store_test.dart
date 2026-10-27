import 'package:log_trail/log_trail.dart';
import 'package:log_trail/storage.dart';
import 'package:test/test.dart';

LogEntry _entry(String message, int second, {Set<String> tags = const {}}) =>
    LogEntry(time: DateTime(2026, 1, 1, 12, 0, second), level: LogLevel.info, message: message, tags: tags);

void main() {
  late InMemoryLogStore store;

  setUp(() => store = InMemoryLogStore());
  tearDown(() => store.isClosed ? null : store.close());

  test('default limit is set; null removes it', () {
    expect(InMemoryLogStore().limit, InMemoryLogStore.defaultLimit);
    expect(InMemoryLogStore(limit: null).limit, isNull);
  });

  test('limit must be positive', () {
    expect(() => InMemoryLogStore(limit: 0), throwsA(isA<AssertionError>()));
  });

  test('writeEntries stores entries in order, returns them with ids and reports one event', () async {
    final changes = <LogStoreChange>[];
    store.changes.listen(changes.add);

    final stored = await store.writeEntries([_entry('a', 1), _entry('b', 2)]);
    final more = await store.writeEntries([_entry('c', 3)]);
    await pumpEventQueue();

    expect(stored.map((e) => e.entry.message), ['a', 'b']);
    expect(stored.map((e) => e.id), [1, 2]);
    expect(more.single.id, 3, reason: 'ids grow across batches');
    expect(store.entries, [...stored, ...more]);
    expect(changes, [
      isA<LogEntriesAdded>().having((c) => c.entries, 'entries', stored),
      isA<LogEntriesAdded>().having((c) => c.entries, 'entries', more),
    ]);
    expect(() => stored.add(more.single), throwsUnsupportedError, reason: 'returned list is unmodifiable');
  });

  test('writeEntries stores and returns entries without live original and report, equal to the written ones', () async {
    final changes = <LogStoreChange>[];
    store.changes.listen(changes.add);
    final report = Object();
    final written = LogEntry(
      time: DateTime(2026),
      level: LogLevel.error,
      message: 'boom',
      error: LogError.capture(StateError('boom'), report: report),
    );

    final stored = await store.writeEntries([written]);
    await pumpEventQueue();
    final queried = await store.queryEntries();
    final added = (changes.single as LogEntriesAdded).entries;

    for (final entry in [stored.single.entry, queried.entries.single.entry, added.single.entry]) {
      expect(entry.error?.original, isNull);
      expect(entry.error?.report, isNull);
      expect(entry, written);
    }
    expect(written.error?.original, isA<StateError>(), reason: 'the written entry itself is unchanged');
  });

  test('query applies filter, order and pages in memory', () async {
    await store.writeEntries([
      _entry('a', 1, tags: {'x'}),
      _entry('b', 2),
      _entry('c', 3, tags: {'x'}),
    ]);

    final page = await store.queryEntries(const LogQuery(filter: LogFilter(tags: {'x'}), newestFirst: true, limit: 1));
    expect(page.entries.map((e) => e.entry.message), ['c']);
    final next = page.next;
    expect(next, isNotNull);
    expect((await store.queryEntries(next!)).entries.map((e) => e.entry.message), ['a']);
  });

  test('queryTags collects tags of all entries', () async {
    await store.writeEntries([
      _entry('a', 1, tags: {'x', 'y'}),
      _entry('b', 2, tags: {'y', 'z'}),
    ]);

    expect(await store.queryTags(), {'x', 'y', 'z'});
  });

  test('removeBefore removes only entries strictly before and reports the removal', () async {
    await store.writeEntries([_entry('a', 1), _entry('b', 2), _entry('c', 3)]);
    final changes = <LogStoreChange>[];
    store.changes.listen(changes.add);

    await store.removeBefore(DateTime(2026, 1, 1, 12, 0, 2));
    await pumpEventQueue();

    expect(store.entries.map((e) => e.entry.message), ['b', 'c']);
    expect(changes, [
      isA<LogEntriesRemovedBefore>().having((c) => c.time, 'time', DateTime(2026, 1, 1, 12, 0, 2)),
    ]);
  });

  test('clear removes everything and reports it', () async {
    await store.writeEntries([_entry('a', 1), _entry('b', 2)]);
    final changes = <LogStoreChange>[];
    store.changes.listen(changes.add);

    await store.clear();
    await pumpEventQueue();

    expect(store.entries, isEmpty);
    expect(changes, [isA<AllLogEntriesRemoved>()]);
  });

  test('exceeding limit removes the oldest entries and reports them', () async {
    final store = InMemoryLogStore(limit: 2);
    addTearDown(store.close);
    final changes = <LogStoreChange>[];
    store.changes.listen(changes.add);

    await store.writeEntries([_entry('a', 1), _entry('b', 2), _entry('c', 3)]);
    await pumpEventQueue();

    expect(store.entries.map((e) => e.entry.message), ['b', 'c']);
    expect(changes.last, isA<LogEntriesRemovedById>().having((c) => c.ids, 'ids', {1}));
    expect(
      changes.first,
      isA<LogEntriesAdded>().having((c) => c.entries, 'entries', hasLength(3)),
      reason: 'batch is reported before removal',
    );
  });

  test('out-of-order entry (startup event) is placed by time, after entries of the same time', () async {
    await store.writeEntries([_entry('a', 1), _entry('c', 3)]);
    await store.writeEntries([_entry('early', 1), _entry('b', 2)]);

    expect(store.entries.map((e) => e.entry.message), ['a', 'early', 'b', 'c']);
    final newest = await store.queryEntries(const LogQuery(newestFirst: true));
    expect(newest.entries.map((e) => e.entry.message), ['c', 'b', 'early', 'a']);
  });

  test('queryTags does not return tags of removed entries', () async {
    await store.writeEntries([
      _entry('a', 1, tags: {'x', 'y'}),
      _entry('b', 2, tags: {'y'}),
    ]);

    await store.removeBefore(DateTime(2026, 1, 1, 12, 0, 2));

    expect(await store.queryTags(), {'y'});
  });

  test('retainNewest keeps the newest and reports the removed', () async {
    await store.writeEntries([for (var i = 0; i < 5; i++) _entry('m$i', i)]);
    final changes = <LogStoreChange>[];
    store.changes.listen(changes.add);

    await store.retainNewest(2);
    await pumpEventQueue();

    expect(store.entries.map((e) => e.entry.message), ['m3', 'm4']);
    expect(changes.single, isA<LogEntriesRemovedById>().having((c) => c.ids, 'ids', {1, 2, 3}));
  });

  test('ids grow in storage order and are not reused after removal', () async {
    await store.writeEntries([_entry('a', 1), _entry('b', 2)]);
    await store.clear();
    await store.writeEntries([_entry('c', 3)]);

    expect(store.entries.map((e) => e.id), [3]);
    final page = await store.queryEntries();
    expect(page.entries.single.id, 3);
    expect(page.entries.single.entry, _entry('c', 3));
  });

  test('startup entry gets a larger id and sorts after entries of the same time', () async {
    await store.writeEntries([_entry('live', 1)]);
    await store.writeEntries([_entry('replayed', 1)]);

    expect(store.entries.map((e) => (e.id, e.entry.message)), [(1, 'live'), (2, 'replayed')]);
  });

  test('retainNewest within the limit removes nothing and reports nothing', () async {
    await store.writeEntries([for (var i = 0; i < 3; i++) _entry('m$i', i)]);
    final changes = <LogStoreChange>[];
    store.changes.listen(changes.add);

    await store.retainNewest(3);
    await pumpEventQueue();

    expect(store.entries, hasLength(3));
    expect(changes, isEmpty);
  });

  test('retention by age and count: two consecutive calls', () async {
    await store.writeEntries([for (var i = 0; i < 5; i++) _entry('m$i', i)]);

    await store.removeBefore(DateTime(2026, 1, 1, 12, 0, 1));
    await store.retainNewest(3);
    expect(store.entries.map((e) => e.entry.message), ['m2', 'm3', 'm4']);
  });

  test('entries cannot be modified from outside', () async {
    await store.writeEntries([_entry('a', 1)]);

    expect(() => store.entries.clear(), throwsUnsupportedError);
  });

  test('close closes changes; read, write and remove after it throw StateError', () async {
    await store.writeEntries([_entry('a', 1)]);
    final done = store.changes.toList();

    await store.close();

    expect(store.isClosed, isTrue);
    await expectLater(done, completion(isEmpty));
    await expectLater(store.queryEntries(), throwsStateError);
    await expectLater(store.queryTags(), throwsStateError);
    await expectLater(store.writeEntries([_entry('b', 2)]), throwsStateError);
    await expectLater(store.clear(), throwsStateError);
    await expectLater(store.removeBefore(DateTime(2026)), throwsStateError);
    await expectLater(store.retainNewest(0), throwsStateError);
  });
}
