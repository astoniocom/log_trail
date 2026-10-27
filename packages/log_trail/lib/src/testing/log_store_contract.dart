import 'dart:math';

import 'package:collection/collection.dart';
import 'package:log_trail/src/entry/log_attributes.dart';
import 'package:log_trail/src/entry/log_entry.dart';
import 'package:log_trail/src/entry/log_level.dart';
import 'package:log_trail/src/entry/log_value.dart';
import 'package:log_trail/src/storage/log_condition.dart';
import 'package:log_trail/src/storage/log_filter.dart';
import 'package:log_trail/src/storage/log_query.dart';
import 'package:log_trail/src/storage/log_reader.dart';
import 'package:log_trail/src/storage/log_store.dart';
import 'package:log_trail/src/storage/log_store_change.dart';
import 'package:log_trail/src/storage/stored_log_entry.dart';
import 'package:meta/meta.dart';

/// Random entries and queries for [compareLogStores]: the scenario every
/// [LogStore] implementation is checked against.
///
/// Entries vary in time (few distinct moments, so that order for equal times
/// is exercised), level, tags, call site, stack, error and typed attributes
/// including nested values; texts mix Latin, umlauts and Cyrillic. Queries
/// combine every kind of [LogCondition] (checked by the core's own test), both
/// orders and small or no page limits. The same seed gives the same scenario,
/// so a mismatch is reproducible by its seed.
final class LogStoreScenario {
  LogStoreScenario(int seed) : _random = Random(seed);

  static const LogField<String> userId = LogField('log_trail.contract.user_id', LogCodec.string);
  static const LogField<int> attempt = LogField('log_trail.contract.attempt', LogCodec.integer);
  static const LogField<double> ratio = LogField('log_trail.contract.ratio', LogCodec.float);
  static const LogField<LogValue> payload = LogField('log_trail.contract.payload', LogCodec.raw);

  static const List<String> _words = ['sync', 'Störung', 'timeout', 'Ошибка', 'profile', 'Übertragung', '100%', 'a_b'];
  static const List<String> _tags = ['net', 'auth', 'ui', 'db', 'log_trail.startup'];
  static const List<String> _needles = [..._words, 'stö', 'OK', '%', 'zzz', 'ош', 'ошибка'];

  final Random _random;

  T _pick<T>(List<T> values) => values[_random.nextInt(values.length)];

  bool _chance(double probability) => _random.nextDouble() < probability;

  Set<T> _subset<T>(List<T> values, {int max = 3}) => {
    for (var i = 0; i < _random.nextInt(max + 1); i++) _pick(values),
  };

  /// A batch of 1, 2, 5 or 10 entries.
  List<LogEntry> batch() => [
    for (var i = 0; i < 1 + _pick(const [0, 1, 4, 9]); i++) entry(),
  ];

  LogEntry entry() {
    final time = DateTime.utc(2026, 1, 1, 12, 0, _random.nextInt(8), 0, _random.nextInt(3));
    final error = _chance(0.3) ? LogError(type: _pick(_words), message: '${_pick(_words)} ${_pick(_words)}') : null;
    return LogEntry(
      time: time,
      level: _pick(LogLevel.values),
      message: '${_pick(_words)} ${_pick(_words)}',
      tags: _subset(_tags),
      location: _chance(0.5) ? 'main (file:///app/main.dart:${_random.nextInt(9)}:1)' : null,
      stackTrace: _chance(0.3) ? StackTrace.fromString('#0      main (file:///app/main.dart:1:1)\n') : null,
      error: error,
      attributes: LogAttributes([
        if (_chance(0.6)) userId('${_random.nextInt(3)}'),
        if (_chance(0.4)) attempt(_random.nextInt(3)),
        if (_chance(0.2)) ratio(_random.nextInt(3) / 2),
        if (_chance(0.2))
          payload(
            LogMap({
              'k': LogInt(_random.nextInt(2)),
              'l': LogList([LogString(_pick(_words))]),
            }),
          ),
      ]),
    );
  }

  LogQuery query() => LogQuery(
    filter: LogFilter(
      after: _chance(0.3) ? DateTime.utc(2026, 1, 1, 12, 0, _random.nextInt(8)) : null,
      before: _chance(0.3) ? DateTime.utc(2026, 1, 1, 12, 0, _random.nextInt(8)) : null,
      levels: _subset(LogLevel.values, max: 2),
      tags: _subset(_tags, max: 2),
      attributes: [
        if (_chance(0.3)) userId('${_random.nextInt(3)}'),
        if (_chance(0.2)) attempt(_random.nextInt(3)),
        if (_chance(0.1)) ratio(_random.nextInt(3) / 2),
        if (_chance(0.1))
          // Map keys in the other order than the entry's: equal values must still match.
          payload(
            LogMap({
              'l': LogList([LogString(_pick(_words))]),
              'k': LogInt(_random.nextInt(2)),
            }),
          ),
      ],
      text: _chance(0.4) ? _pick(_needles) : '',
    ),
    newestFirst: _chance(0.5),
    limit: _chance(0.8) ? 1 + _random.nextInt(4) : null,
  );

  /// Whether to call [removeBefore] this round, and with which time.
  DateTime? removeBefore() => _chance(0.15) ? DateTime.utc(2026, 1, 1, 12, 0, _pick(const [2, 5])) : null;

  /// Whether to call [retainNewest] this round, and with which count.
  int? retainNewest() => _chance(0.15) ? _pick(const [5, 20]) : null;
}

/// One place where a store under [compareLogStores] disagreed with the reference.
@immutable
final class LogStoreMismatch {
  const LogStoreMismatch(this.where, {required this.expected, required this.actual});

  /// What was compared and when: `round 3, query LogQuery(…)`.
  final String where;

  final Object? expected;
  final Object? actual;

  @override
  String toString() => '$where:\n  expected: $expected\n  actual:   $actual';
}

/// Drives a store under test and a reference store (normally `InMemoryLogStore`
/// with the same `limit`) in lockstep through a [LogStoreScenario] and
/// collects where they disagree. [compareLogStores] runs it whole; a test that
/// drives several stores through one scenario (two scoped stores over one
/// table) calls [round] and [finish] itself.
///
/// Each round writes one batch to both, applies the same `removeBefore` and
/// `retainNewest` when the scenario asks for them, compares the tags and reads
/// six random queries page by page, comparing the full result. [finish]
/// compares the change streams: the same sequence of change types with the
/// same entries, ids (or, without [compareIds], as many ids) and times.
/// Without [compareIds] only entries are compared, for a store whose ids are
/// shared with other writers of its table.
final class LogStoreContractCheck {
  LogStoreContractCheck({
    required this.store,
    required this.reference,
    required this.scenario,
    this.compareIds = true,
  }) {
    _referenceChanges = [];
    _storeChanges = [];
    reference.changes.listen(_referenceChanges.add);
    store.changes.listen(_storeChanges.add);
  }

  final LogStore store;
  final LogStore reference;
  final LogStoreScenario scenario;
  final bool compareIds;

  late final List<LogStoreChange> _referenceChanges;
  late final List<LogStoreChange> _storeChanges;
  final List<LogStoreMismatch> _mismatches = [];
  int _round = 0;

  /// Mismatches found so far; empty means the stores agreed.
  List<LogStoreMismatch> get mismatches => List.unmodifiable(_mismatches);

  /// One round: a batch, optional removals, tags, six queries.
  Future<void> round() async {
    final round = _round++;
    final batch = scenario.batch();
    final referenceStored = await reference.writeEntries(batch);
    final storeStored = await store.writeEntries(batch);
    _compare('round $round, writeEntries', expected: _stored(referenceStored), actual: _stored(storeStored));

    if (scenario.removeBefore() case final time?) {
      await reference.removeBefore(time);
      await store.removeBefore(time);
    }
    if (scenario.retainNewest() case final count?) {
      await reference.retainNewest(count);
      await store.retainNewest(count);
    }

    _compare('round $round, queryTags', expected: await reference.queryTags(), actual: await store.queryTags());
    for (var i = 0; i < 6; i++) {
      final query = scenario.query();
      _compare(
        'round $round, $query',
        expected: _stored(await _allPages(reference, query, 'reference')),
        actual: _stored(await _allPages(store, query, 'store')),
      );
    }
  }

  /// Compares the change streams once the stores have delivered them.
  Future<void> finish() async {
    // Two turns: LogStoreBase emits after the write completes, the broadcast stream delivers on the next.
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    _compare(
      'changes',
      expected: _referenceChanges.map((c) => c.runtimeType).toList(),
      actual: _storeChanges.map((c) => c.runtimeType).toList(),
    );
    for (final (index, expected) in _referenceChanges.indexed) {
      if (index >= _storeChanges.length) break;
      final actual = _storeChanges[index];
      switch (expected) {
        case LogEntriesAdded(:final entries):
          if (actual is LogEntriesAdded) {
            _compare('changes[$index] LogEntriesAdded', expected: _stored(entries), actual: _stored(actual.entries));
          }
        case LogEntriesRemovedById(:final ids):
          if (actual is LogEntriesRemovedById) {
            _compare(
              'changes[$index] LogEntriesRemovedById',
              expected: compareIds ? ids : ids.length,
              actual: compareIds ? actual.ids : actual.ids.length,
            );
          }
        case LogEntriesRemovedBefore(:final time):
          if (actual is LogEntriesRemovedBefore) {
            _compare('changes[$index] LogEntriesRemovedBefore', expected: time, actual: actual.time);
          }
        case AllLogEntriesRemoved() || LogStoreInvalidated():
          break;
      }
    }
  }

  /// All pages of [query]: a page longer than its limit or a pagination that does not end is a mismatch.
  Future<List<StoredLogEntry>> _allPages(LogReader reader, LogQuery query, String which) async {
    final result = <StoredLogEntry>[];
    LogQuery? next = query;
    var pages = 0;
    while (next != null) {
      final page = await reader.queryEntries(next);
      if (next.limit case final limit? when page.entries.length > limit) {
        _mismatches.add(
          LogStoreMismatch(
            '$which: page longer than its limit for $next',
            expected: limit,
            actual: page.entries.length,
          ),
        );
      }
      result.addAll(page.entries);
      next = page.next;
      if (++pages > 200) {
        _mismatches.add(
          LogStoreMismatch('$which: pagination did not end for $query', expected: '< 200 pages', actual: pages),
        );
        break;
      }
    }
    return result;
  }

  /// Stored entries as compared: with ids, or entries only without [compareIds].
  List<Object> _stored(List<StoredLogEntry> entries) =>
      compareIds ? entries : [for (final stored in entries) stored.entry];

  void _compare(String where, {required Object? expected, required Object? actual}) {
    if (!const DeepCollectionEquality().equals(expected, actual)) {
      _mismatches.add(LogStoreMismatch(where, expected: expected, actual: actual));
    }
  }
}

/// Checks [store] against the [LogStore] contract by comparing it with
/// [reference] (an `InMemoryLogStore` with the same `limit`, whose
/// `queryInMemory` and [LogCondition.matches] define the semantics) over
/// [rounds] rounds of the [LogStoreScenario] for [seed]. Returns the
/// mismatches; an empty list means the store behaved like the reference for
/// this seed. A package's contract test runs a few seeds and asserts the list
/// is empty:
///
/// ```dart
/// for (final seed in [1, 2, 3]) {
///   test('seed $seed matches the reference', () async {
///     final mismatches = await compareLogStores(MyStore(), reference: InMemoryLogStore(limit: 40), seed: seed);
///     expect(mismatches, isEmpty);
///   });
/// }
/// ```
///
/// Neither store is closed: the caller owns both.
Future<List<LogStoreMismatch>> compareLogStores(
  LogStore store, {
  required LogStore reference,
  required int seed,
  int rounds = 12,
  bool compareIds = true,
}) async {
  final check = LogStoreContractCheck(
    store: store,
    reference: reference,
    scenario: LogStoreScenario(seed),
    compareIds: compareIds,
  );
  for (var i = 0; i < rounds; i++) {
    await check.round();
  }
  await check.finish();
  return check.mismatches;
}
