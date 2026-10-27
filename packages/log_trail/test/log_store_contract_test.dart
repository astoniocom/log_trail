import 'package:log_trail/log_trail.dart';
import 'package:log_trail/storage.dart';
import 'package:log_trail/testing.dart';
import 'package:test/test.dart';

/// The condition kind. An exhaustive `switch`: a new [LogCondition] does not compile here until it is given a
/// kind; at the same time it must be added to [_allConditionKinds] and to [LogStoreScenario.query], otherwise
/// the contract is not checked for it.
String _kind(LogCondition condition) => switch (condition) {
  LogAfterCondition() => 'after',
  LogBeforeCondition() => 'before',
  LogLevelCondition() => 'level',
  LogTagCondition() => 'tag',
  LogAttributeCondition() => 'attribute',
  LogTextCondition() => 'text',
};

const _allConditionKinds = {'after', 'before', 'level', 'tag', 'attribute', 'text'};

/// A store that ignores tag conditions: a contract violation the check must catch.
final class _IgnoresTags extends LogStoreBase {
  final InMemoryLogStore _inner = InMemoryLogStore(limit: 40);

  @override
  Future<List<StoredLogEntry>> onWriteEntries(List<LogEntry> entries) => _inner.writeEntries(entries);

  @override
  Future<LogPage> onQueryEntries(LogQuery query) => _inner.queryEntries(
    LogQuery(
      filter: query.filter.copyWith(tags: {}),
      newestFirst: query.newestFirst,
      limit: query.limit,
      startAfter: query.startAfter,
    ),
  );

  @override
  Future<Set<String>> onQueryTags() => _inner.queryTags();

  @override
  Future<void> onClear() => _inner.clear();

  @override
  Future<void> onRemoveBefore(DateTime time) => _inner.removeBefore(time);

  @override
  Future<Set<int>?> onRetainNewest(int count) async {
    await _inner.retainNewest(count);
    return null;
  }

  @override
  Future<void> onClose() => _inner.close();
}

void main() {
  test('the scenario produces conditions of every kind', () {
    final scenario = LogStoreScenario(0);
    final kinds = {
      for (var i = 0; i < 300; i++)
        for (final condition in scenario.query().filter.conditions) _kind(condition),
    };

    expect(kinds, _allConditionKinds);
  });

  test('the same seed gives the same scenario', () {
    final a = LogStoreScenario(3);
    final b = LogStoreScenario(3);

    expect([for (var i = 0; i < 20; i++) a.query()], [for (var i = 0; i < 20; i++) b.query()]);
    expect([for (var i = 0; i < 20; i++) a.entry()], [for (var i = 0; i < 20; i++) b.entry()]);
  });

  test('the in-memory store matches itself: no mismatches', () async {
    final store = InMemoryLogStore(limit: 40);
    final reference = InMemoryLogStore(limit: 40);
    addTearDown(() async {
      await store.close();
      await reference.close();
    });

    expect(await compareLogStores(store, reference: reference, seed: 1), isEmpty);
  });

  test('a store that ignores tag conditions and loses removal ids is reported, with the query and the round', () async {
    final store = _IgnoresTags();
    final reference = InMemoryLogStore(limit: 40);
    addTearDown(() async {
      await store.close();
      await reference.close();
    });

    final mismatches = await compareLogStores(store, reference: reference, seed: 1);

    expect(mismatches, isNotEmpty);
    expect(mismatches.map((m) => m.where), anyElement(allOf(startsWith('round '), contains('tags:'))));
    expect(
      mismatches.map((m) => m.where),
      anyElement('changes'),
      reason: 'LogStoreInvalidated instead of LogEntriesRemovedById differs in the change stream',
    );
    expect('${mismatches.first}', contains('expected:'));
  });

  test('without compareIds only entries are compared', () async {
    final reference = InMemoryLogStore(limit: 40);
    final store = InMemoryLogStore(limit: 40);
    addTearDown(() async {
      await store.close();
      await reference.close();
    });
    // Ids diverge from the start: the store has already issued some.
    await store.writeEntries([LogEntry(time: DateTime.utc(2025), level: LogLevel.info, message: 'old')]);
    await store.clear();

    expect(await compareLogStores(store, reference: reference, seed: 2), isNotEmpty);
    expect(await compareLogStores(store, reference: reference, seed: 2, compareIds: false), isEmpty);
  });
}
