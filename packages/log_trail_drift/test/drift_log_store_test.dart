import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:log_trail/log_trail.dart';
import 'package:log_trail_drift/log_trail_drift.dart';
import 'package:test/test.dart';

import 'support/test_database.dart';

const userId = LogField('test.user_id', LogCodec.string);
const payload = LogField('test.payload', LogCodec.raw);

LogEntry _entry(
  String message,
  int second, {
  Set<String> tags = const {},
  LogLevel level = LogLevel.info,
  Iterable<LogAttribute<Object>> attributes = const [],
}) => LogEntry(
  time: DateTime(2026, 1, 1, 12, 0, second),
  level: level,
  message: message,
  tags: tags,
  attributes: LogAttributes(attributes),
);

Future<Iterable<String>> _messages(LogReader reader, [LogQuery query = const LogQuery()]) async =>
    (await reader.queryEntries(query)).entries.map((e) => e.entry.message);

/// A store scoped to one tenant of the shared [TenantLogs] table.
final class _TenantLogStore extends DriftLogStore<$TenantLogsTable, TenantLog> {
  _TenantLogStore(super.database, super.table, this.tenant, {super.limit});

  final String tenant;

  @override
  Map<GeneratedColumn<Object>, Expression<Object>> additionalColumns(LogEntry entry) => {
    table.tenant: Variable<String>(tenant),
  };

  @override
  Expression<bool> get scope => table.tenant.equals(tenant);
}

/// Counts the `SELECT` statements that reach the executor.
final class _SelectCounter extends QueryInterceptor {
  int count = 0;

  @override
  Future<List<Map<String, Object?>>> runSelect(QueryExecutor executor, String statement, List<Object?> args) {
    count++;
    return super.runSelect(executor, statement, args);
  }
}

void main() {
  late TestDatabase db;
  late DriftLogStore<$LogEntriesTable, LogEntryRow> store;

  setUp(() {
    db = TestDatabase.memory();
    store = DriftLogStore(db, db.logEntries);
  });
  tearDown(() async {
    if (!store.isClosed) await store.close();
    await db.close();
  });

  test('limit must be positive', () {
    expect(() => DriftLogStore(db, db.logEntries, limit: 0), throwsA(isA<AssertionError>()));
  });

  test('writeEntries saves entries in order, returns them with ids and reports one event', () async {
    final changes = <LogStoreChange>[];
    store.changes.listen(changes.add);
    final entries = [
      _entry('a', 1, tags: {'x'}),
      _entry('b', 2),
    ];

    final stored = await store.writeEntries(entries);
    await pumpEventQueue();

    expect(stored.map((e) => (e.id, e.entry)), [(1, entries[0]), (2, entries[1])]);
    expect(store.count, 2);
    expect(changes, [isA<LogEntriesAdded>().having((c) => c.entries, 'entries', stored)]);
  });

  test('removeBefore keeps the tag counts right across repeated tag sets and leaves the rest', () async {
    await store.writeEntries([
      _entry('a', 1, tags: {'x', 'y'}),
      _entry('b', 2, tags: {'x', 'y'}),
      _entry('c', 3, tags: {'y'}),
      _entry('d', 4, tags: {'x'}),
      _entry('e', 5, tags: {'z'}),
    ]);

    await store.removeBefore(DateTime(2026, 1, 1, 12, 0, 4));

    expect(await store.queryTags(), {'x', 'z'}, reason: 'y lost all three carriers, x keeps one');
    expect(store.count, 2);
    expect(await _messages(store), ['d', 'e']);
  });

  test('a filter on a tag no entry carries is answered without a query', () async {
    final selects = _SelectCounter();
    final db = TestDatabase(NativeDatabase.memory().interceptWith(selects));
    final store = DriftLogStore(db, db.logEntries);
    addTearDown(() async {
      await store.close();
      await db.close();
    });
    await store.writeEntries([
      _entry('a', 1, tags: {'x'}),
      _entry('b', 2),
    ]);
    await store.initialize();
    selects.count = 0;

    final page = await store.queryEntries(const LogQuery(filter: LogFilter(tags: {'nope'}), limit: 10));

    expect(page.entries, isEmpty);
    expect(page.next, null);
    expect(selects.count, 0, reason: 'the in-memory tag counts answer it');
    expect(await _messages(store, const LogQuery(filter: LogFilter(tags: {'x'}))), ['a']);
    expect(selects.count, greaterThan(0), reason: 'a tag that exists is queried as before');
  });

  test('rows hold the index columns the store derives from the entry', () async {
    await store.writeEntries([
      _entry(
        'Störung',
        1,
        tags: {'net', 'auth'},
        attributes: [
          userId('42'),
          payload(LogMap(const {'b': LogInt(2), 'a': LogInt(1)})),
        ],
      ),
    ]);

    final row = await db.select(db.logEntries).getSingle();
    const sep = DriftLogStore.separator;
    expect(row.level, 'info');
    expect(row.tags, '${sep}net${sep}auth$sep');
    expect(row.attributes, '${sep}test.user_id="42"${sep}test.payload={"a":1,"b":2}$sep', reason: 'map keys sorted');
    expect(logEntryJson.decode(jsonDecode(row.entry) as Map<String, Object?>).message, 'Störung');
  });

  test('text search is decided in Dart over the JSON: non-ASCII case, escapes, error text, pages', () async {
    final entries = [
      for (var i = 0; i < 300; i++)
        LogEntry(
          time: DateTime(2026, 1, 1, 12, 0, i),
          level: LogLevel.info,
          message: i % 3 == 0 ? 'ÜBERTRAGUNG "$i" \\ gestört' : 'Übrig $i',
          error: i % 100 == 99 ? const LogError(type: 'StateError', message: 'Disk FULL') : null,
        ),
    ];
    await store.writeEntries(entries);

    // Only Cyrillic-free fragments reach SQL; the quote and the backslash split them.
    final page = await store.queryEntries(const LogQuery(filter: LogFilter(text: 'übertragung "2'), limit: 7));
    expect(page.entries.map((e) => e.entry.message), [
      for (final i in [21, 24, 27, 201, 204, 207, 210]) 'ÜBERTRAGUNG "$i" \\ gestört',
    ]);
    final rest = await store.queryEntries(page.next!);
    expect(rest.entries.length, 7);
    expect(rest.entries.first.entry.message, r'ÜBERTRAGUNG "213" \ gestört');

    expect(await _messages(store, const LogQuery(filter: LogFilter(text: r'" \ ges'))), hasLength(100));
    expect(
      await _messages(store, const LogQuery(filter: LogFilter(text: 'stateerror: disk'))),
      [
        for (final entry in entries)
          if (entry.error != null) entry.message,
      ],
      reason: 'the needle spans type and message, which JSON keeps apart',
    );
    expect(await _messages(store, const LogQuery(filter: LogFilter(text: 'rig 29'))), [
      'Übrig 29',
      for (var i = 290; i < 300; i++)
        if (i % 3 != 0) 'Übrig $i',
    ]);
    expect(await _messages(store, const LogQuery(filter: LogFilter(text: 'nichts'))), isEmpty);
  });

  test('a write failure rolls back the whole transaction, the counters are reread', () async {
    await store.writeEntries([
      _entry('a', 1, tags: {'kept'}),
    ]);
    // NaN has no JSON form: jsonEncode fails on the batch's second entry, after the first is inserted.
    final broken = LogEntry(
      time: DateTime(2026),
      level: LogLevel.info,
      message: 'b',
      attributes: LogAttributes([
        payload(LogMap(const {'k': LogDouble(double.nan)})),
      ]),
    );

    await expectLater(
      store.writeEntries([
        _entry('ok', 2, tags: {'lost'}),
        broken,
      ]),
      throwsA(anything),
    );

    expect(await _messages(store), ['a'], reason: 'no entry of the batch is saved');
    expect(store.count, 1);
    expect(await store.queryTags(), {'kept'}, reason: 'the tag of the rolled-back entry is not counted');
  });

  test('an SQLite failure surfaces as LogStoreException without query parameters', () async {
    const secret = 'card 4111-1111-1111-1111';
    await store.writeEntries([_entry('warm-up', 1)]);
    await db.customStatement('DROP TABLE log_entries');

    await expectLater(
      store.writeEntries([
        _entry(secret, 2, tags: {'payment'}),
      ]),
      throwsA(
        isA<LogStoreException>().having(
          (e) => '$e',
          'toString',
          allOf(contains('no such table'), isNot(contains(secret)), isNot(contains('payment'))),
        ),
      ),
    );
  });

  test('close marks the store closed and leaves the database open', () async {
    await store.writeEntries([_entry('a', 1)]);
    await store.close();

    await expectLater(store.queryEntries(), throwsStateError);
    expect(await db.select(db.logEntries).get(), hasLength(1), reason: 'the application still owns the database');
  });

  test('works under LogStoreSink: logger entries, including replayed startup ones, read back', () async {
    final logger = RootLogger()..info('early');
    logger
      ..addSink(LogStoreSink(store))
      ..finishStartup()
      ..warning('later', tags: {'t'});
    await logger.close();

    expect(await _messages(store), ['early', 'later']);
    expect(await store.queryTags(), {'t'});
  });

  group('subclass over a table of the application', () {
    late _TenantLogStore alpha;
    late _TenantLogStore beta;

    setUp(() {
      alpha = _TenantLogStore(db, db.tenantLogs, 'alpha', limit: 3);
      beta = _TenantLogStore(db, db.tenantLogs, 'beta');
    });
    tearDown(() async {
      await alpha.close();
      await beta.close();
    });

    test('additionalColumns fills the extra column on every insert', () async {
      await alpha.writeEntries([_entry('a', 1)]);
      await beta.writeEntries([_entry('b', 2)]);

      final rows = await (db.select(db.tenantLogs)..orderBy([(t) => OrderingTerm.asc(t.id)])).get();
      expect(rows.map((r) => r.tenant), ['alpha', 'beta']);
    });

    test('scope isolates queries, tags, count, limit and removals per tenant in one table', () async {
      await alpha.writeEntries([
        _entry('a1', 1, tags: {'a'}),
        _entry('a2', 2, tags: {'a'}),
      ]);
      await beta.writeEntries([
        _entry('b1', 1, tags: {'b'}),
        _entry('b2', 5, tags: {'b'}),
      ]);

      expect(await _messages(alpha), ['a1', 'a2']);
      expect(await _messages(beta), ['b1', 'b2']);
      expect(await alpha.queryTags(), {'a'});
      expect(await beta.queryTags(), {'b'});
      expect(alpha.count, 2);

      // alpha's limit of 3 evicts alpha's oldest only.
      await alpha.writeEntries([_entry('a3', 3), _entry('a4', 4)]);
      expect(await _messages(alpha), ['a2', 'a3', 'a4']);
      expect(await _messages(beta), ['b1', 'b2'], reason: "beta untouched by alpha's eviction");

      await beta.removeBefore(DateTime(2026, 1, 1, 12, 0, 3));
      expect(await _messages(beta), ['b2']);
      expect(await _messages(alpha), ['a2', 'a3', 'a4'], reason: "alpha untouched by beta's removal");

      await alpha.clear();
      expect(await _messages(alpha), isEmpty);
      expect(await alpha.queryTags(), isEmpty);
      expect(await _messages(beta), ['b2'], reason: 'clear is scoped too');
      expect(await db.select(db.tenantLogs).get(), hasLength(1));
    });
  });

  group('file database in a background isolate', () {
    late Directory directory;
    late TestDatabase fileDb;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('log_trail_drift_');
      fileDb = TestDatabase(NativeDatabase.createInBackground(File('${directory.path}/app.sqlite')));
    });
    tearDown(() async {
      await fileDb.close();
      directory.deleteSync(recursive: true);
    });

    test('entries, ids and tag counts survive closing the database and reopening it', () async {
      final first = DriftLogStore(fileDb, fileDb.logEntries, limit: 10);
      await first.writeEntries([
        _entry('a', 1, tags: {'x'}),
        _entry('b', 2, tags: {'y'}),
      ]);
      await first.removeBefore(DateTime(2026, 1, 1, 12, 0, 2));
      await first.close();
      await fileDb.close();

      fileDb = TestDatabase(NativeDatabase.createInBackground(File('${directory.path}/app.sqlite')));
      final second = DriftLogStore(fileDb, fileDb.logEntries, limit: 10);
      addTearDown(second.close);
      final stored = await second.writeEntries([_entry('c', 3)]);

      expect(second.count, 2);
      expect((await second.queryEntries()).entries.map((e) => (e.id, e.entry.message)), [(2, 'b'), (3, 'c')]);
      expect(stored.single.id, 3, reason: 'AUTOINCREMENT does not reuse ids');
      expect(await second.queryTags(), {'y'});
    });

    test('counts rebuilt on reopening keep the multiplicity of repeated tag sets', () async {
      final first = DriftLogStore(fileDb, fileDb.logEntries);
      await first.writeEntries([
        _entry('a', 1, tags: {'x', 'y'}),
        _entry('b', 2, tags: {'x', 'y'}),
        _entry('c', 3, tags: {'x'}),
        _entry('d', 4),
      ]);
      await first.close();

      final second = DriftLogStore(fileDb, fileDb.logEntries);
      addTearDown(second.close);
      await second.initialize();
      expect(second.count, 4);
      expect(await second.queryTags(), {'x', 'y'});

      // One of the two {x, y} entries goes: y must survive with count 1.
      await second.removeBefore(DateTime(2026, 1, 1, 12, 0, 2));
      expect(second.count, 3);
      expect(await second.queryTags(), {'x', 'y'});

      await second.removeBefore(DateTime(2026, 1, 1, 12, 0, 3));
      expect(await second.queryTags(), {'x'}, reason: 'y was counted twice at reopening, not once');

      await second.retainNewest(1);
      expect(await second.queryTags(), isEmpty);
      expect(second.count, 1);
    });

    test('an SQLite failure from the executor isolate is unwrapped into LogStoreException', () async {
      final remote = DriftLogStore(fileDb, fileDb.logEntries);
      addTearDown(remote.close);
      await remote.writeEntries([_entry('warm-up', 1)]);
      await fileDb.customStatement('DROP TABLE log_entries');

      await expectLater(
        remote.writeEntries([_entry('secret', 2)]),
        throwsA(isA<LogStoreException>().having((e) => e.message, 'message', contains('no such table'))),
      );
    });
  });
}
