import 'dart:io';

import 'package:log_trail/log_trail.dart';
import 'package:log_trail_sqlite/log_trail_sqlite.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

const userId = LogField('test.user_id', LogCodec.string);
const attempt = LogField('test.attempt', LogCodec.integer);
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

Future<List<StoredLogEntry>> _all(LogReader reader) async => (await reader.queryEntries()).entries;

Future<Iterable<String>> _messages(LogReader reader, [LogQuery query = const LogQuery()]) async =>
    (await reader.queryEntries(query)).entries.map((e) => e.entry.message);

void main() {
  late SqliteLogStore store;

  setUp(() => store = SqliteLogStore.inMemory());
  tearDown(() => store.isClosed ? null : store.close());

  test('limit must be positive', () {
    expect(() => SqliteLogStore.inMemory(limit: 0), throwsA(isA<AssertionError>()));
  });

  test('writeEntries saves entries in order, returns them with ids and reports one event', () async {
    final changes = <LogStoreChange>[];
    store.changes.listen(changes.add);

    final stored = await store.writeEntries([_entry('a', 1), _entry('b', 2)]);
    final more = await store.writeEntries([_entry('c', 3)]);
    await pumpEventQueue();

    expect(stored.map((e) => e.entry.message), ['a', 'b']);
    expect(stored.map((e) => e.id), [1, 2]);
    expect(more.single.id, 3, reason: 'ids grow across batches');
    expect(await _all(store), [...stored, ...more]);
    expect(store.count, 3);
    expect(changes, [
      isA<LogEntriesAdded>().having((c) => c.entries, 'entries', stored),
      isA<LogEntriesAdded>().having((c) => c.entries, 'entries', more),
    ]);
    expect(() => stored.add(more.single), throwsUnsupportedError, reason: 'the returned list is unmodifiable');
  });

  group('SQLite failure', () {
    const secret = 'card 4111-1111-1111-1111';

    test('surfaces as LogStoreException without query parameters: entry contents do not leak', () async {
      // The first write prepares the statements; then the tag table disappears.
      await store.writeEntries([
        _entry('warm-up', 1, tags: {'t'}),
      ]);
      store.database.execute('DROP TABLE log_entry_tags');

      await expectLater(
        store.writeEntries([
          _entry(secret, 2, tags: {'payment'}),
        ]),
        throwsA(
          isA<LogStoreException>()
              .having(
                (e) => '$e',
                'toString',
                allOf(contains('no such table'), isNot(contains(secret)), isNot(contains('payment'))),
              )
              .having((e) => e.statement, 'statement', contains('log_entry_tags')),
        ),
      );
      expect(store.count, 1, reason: 'the transaction rolled back, the counter was reread');
      expect(await _messages(store), ['warm-up']);
    });

    test('and on read', () async {
      store.database.execute('DROP TABLE log_tags');

      await expectLater(store.queryTags(), throwsA(isA<LogStoreException>()));
    });
  });

  test('an entry with error, stack trace, location and attributes reads back equal to the written one', () async {
    final written = LogEntry(
      time: DateTime(2026, 3, 4, 5, 6, 7, 8, 9),
      level: LogLevel.error,
      message: 'Failed to load profile',
      tags: const {'auth', 'network'},
      location: 'ProfileRepository.load (package:app/profile.dart:42:7)',
      stackTrace: StackTrace.fromString('#0      main (file:///app/main.dart:1:1)\n'),
      error: LogError.capture(const FormatException('Unexpected token'), report: Object()),
      attributes: LogAttributes([
        userId('42'),
        attempt(3),
        payload(
          LogMap({
            'b': const LogInt(1),
            'a': LogList(const [LogString('x'), LogBool(true), LogDouble(1.5)]),
          }),
        ),
      ]),
    );

    await store.writeEntries([written]);
    final read = (await _all(store)).single.entry;

    expect(read, written);
    expect(read.error?.original, isNull);
    expect(read.error?.report, isNull);
    expect(read.time.isUtc, isTrue, reason: 'time is stored in UTC');
    expect(read.attributes.get(userId), '42');
    expect(read.attributes.get(attempt), 3);
  });

  test('an out-of-order entry (a startup event) lands in its place, after entries with the same time', () async {
    await store.writeEntries([_entry('a', 1), _entry('c', 3)]);
    await store.writeEntries([_entry('early', 1), _entry('b', 2)]);

    expect(await _messages(store), ['a', 'early', 'b', 'c']);
    expect(await _messages(store, const LogQuery(newestFirst: true)), ['c', 'b', 'early', 'a']);
    expect((await _all(store)).map((e) => (e.id, e.entry.message)).take(2), [(1, 'a'), (3, 'early')]);
  });

  group('queryEntries', () {
    setUp(
      () => store.writeEntries([
        _entry('a', 1, tags: {'x'}, level: LogLevel.debug, attributes: [userId('1')]),
        _entry('b', 2, tags: {'y'}, attributes: [userId('2'), attempt(1)]),
        _entry('c', 3, tags: {'x', 'y'}, level: LogLevel.warning, attributes: [userId('1'), attempt(1)]),
        _entry('d', 4, tags: {'x'}, level: LogLevel.error),
        _entry('e', 4, level: LogLevel.fatal),
      ]),
    );

    test('pages continue by cursor in both directions, entries with equal time are not lost', () async {
      var page = await store.queryEntries(const LogQuery(newestFirst: true, limit: 2));
      expect(page.entries.map((e) => e.entry.message), ['e', 'd']);
      page = await store.queryEntries(page.next!);
      expect(page.entries.map((e) => e.entry.message), ['c', 'b']);
      page = await store.queryEntries(page.next!);
      expect(page.entries.map((e) => e.entry.message), ['a']);
      expect(page.next, isNull);

      page = await store.queryEntries(const LogQuery(limit: 3));
      expect(page.entries.map((e) => e.entry.message), ['a', 'b', 'c']);
      page = await store.queryEntries(page.next!);
      expect(page.entries.map((e) => e.entry.message), ['d', 'e']);
      expect(page.next, isNull, reason: 'a page of exactly the limit does not promise a next one');
    });

    test('an entry saved between pages does not shift the next page', () async {
      final page = await store.queryEntries(const LogQuery(newestFirst: true, limit: 2));
      await store.writeEntries([_entry('late', 5)]);

      final next = await store.queryEntries(page.next!);
      expect(next.entries.map((e) => e.entry.message), ['c', 'b'], reason: 'OFFSET would shift the page by late');
      expect(await _messages(store, next.next!), ['a']);
    });

    test('period filter: strictly after and strictly before', () async {
      final filter = LogFilter(after: DateTime(2026, 1, 1, 12, 0, 1), before: DateTime(2026, 1, 1, 12, 0, 4));
      expect(await _messages(store, LogQuery(filter: filter)), ['b', 'c']);
    });

    test('level filter', () async {
      expect(await _messages(store, const LogQuery(filter: LogFilter(levels: {LogLevel.debug, LogLevel.fatal}))), [
        'a',
        'e',
      ]);
    });

    test('tag filter requires all tags', () async {
      expect(await _messages(store, const LogQuery(filter: LogFilter(tags: {'x'}))), ['a', 'c', 'd']);
      expect(await _messages(store, const LogQuery(filter: LogFilter(tags: {'x', 'y'}))), ['c']);
      expect(await _messages(store, const LogQuery(filter: LogFilter(tags: {'z'}))), isEmpty);
    });

    test('attribute filter compares encoded values', () async {
      expect(await _messages(store, LogQuery(filter: LogFilter(attributes: [userId('1')]))), ['a', 'c']);
      expect(await _messages(store, LogQuery(filter: LogFilter(attributes: [userId('1'), attempt(1)]))), ['c']);
      expect(await _messages(store, LogQuery(filter: LogFilter(attributes: [attempt(2)]))), isEmpty);
    });

    test('all conditions together and with a cursor', () async {
      final query = LogQuery(
        filter: LogFilter(levels: const {LogLevel.info, LogLevel.warning}, tags: const {'y'}, attributes: [attempt(1)]),
        newestFirst: true,
        limit: 1,
      );
      final page = await store.queryEntries(query);
      expect(page.entries.single.entry.message, 'c');
      expect(await _messages(store, page.next!), ['b']);
    });
  });

  group('text search', () {
    test('case-insensitive, including non-ASCII, over message and error text', () async {
      await store.writeEntries([
        _entry('Störung Übertragung', 1),
        LogEntry(
          time: DateTime(2026, 1, 1, 12, 0, 2),
          level: LogLevel.error,
          message: 'request failed',
          error: const LogError(type: 'HttpException', message: 'Timeout ÜBERSCHRITTEN'),
        ),
        _entry('nothing here', 3),
      ]);

      expect(await _messages(store, const LogQuery(filter: LogFilter(text: 'störung übertragung'))), [
        'Störung Übertragung',
      ]);
      expect(await _messages(store, const LogQuery(filter: LogFilter(text: 'überschritten'))), ['request failed']);
      expect(await _messages(store, const LogQuery(filter: LogFilter(text: 'httpexception'))), ['request failed']);
      expect(await _messages(store, const LogQuery(filter: LogFilter(text: 'missing'))), isEmpty);
    });

    test('a Cyrillic needle is answered by the trigram index with case folding, as a substring', () async {
      await store.writeEntries([
        _entry('Ошибка Сети при запросе', 1),
        _entry('ЗАПРОС выполнен', 2),
        _entry('nothing here', 3),
      ]);

      expect(await _messages(store, const LogQuery(filter: LogFilter(text: 'ошибка'))), ['Ошибка Сети при запросе']);
      expect(await _messages(store, const LogQuery(filter: LogFilter(text: 'шибка с'))), ['Ошибка Сети при запросе']);
      expect(await _messages(store, const LogQuery(filter: LogFilter(text: 'запрос'))), [
        'Ошибка Сети при запросе',
        'ЗАПРОС выполнен',
      ]);
      expect(await _messages(store, const LogQuery(filter: LogFilter(text: 'ошибки'))), isEmpty);
      final plan = store.database.select(
        'EXPLAIN QUERY PLAN SELECT id FROM log_entries WHERE id IN (SELECT rowid FROM log_entry_fts WHERE log_entry_fts MATCH ?)',
        ['"ошибка"'],
      );
      expect(
        plan.map((row) => row['detail']).join('\n'),
        contains('VIRTUAL TABLE INDEX'),
        reason: 'the FTS index is used',
      );
    });

    test('a needle shorter than three characters is decided without the index, in any script', () async {
      await store.writeEntries([_entry('Ошибка', 1), _entry('ok', 2), _entry('ab', 3), _entry('AB', 4)]);

      expect(await _messages(store, const LogQuery(filter: LogFilter(text: 'ош'))), ['Ошибка']);
      expect(await _messages(store, const LogQuery(filter: LogFilter(text: 'ab'))), ['ab', 'AB']);
      expect(await _messages(store, const LogQuery(filter: LogFilter(text: 'ok'))), ['ok']);
      expect(await _messages(store, const LogQuery(filter: LogFilter(text: 'zz'))), isEmpty);
    });

    test('FTS operators and quotes in the needle are literal', () async {
      await store.writeEntries([
        _entry('a AND b', 1),
        _entry('a b', 2),
        _entry('say "hi" NOT now', 3),
        _entry('col:x', 4),
      ]);

      expect(await _messages(store, const LogQuery(filter: LogFilter(text: 'a and b'))), ['a AND b']);
      expect(await _messages(store, const LogQuery(filter: LogFilter(text: '"hi" not'))), ['say "hi" NOT now']);
      expect(await _messages(store, const LogQuery(filter: LogFilter(text: 'col:x'))), ['col:x']);
      expect(await _messages(store, const LogQuery(filter: LogFilter(text: 'a OR'))), isEmpty);
    });

    test('the indexed text is the message and the error text as LogError.toString, on its own line', () async {
      await store.writeEntries([
        _entry('Ошибка Сети', 1),
        LogEntry(
          time: DateTime(2026, 1, 1, 12, 0, 2),
          level: LogLevel.error,
          message: 'Sync failed',
          error: const LogError(type: 'StateError', message: 'Bad state: Disk FULL'),
        ),
        LogEntry(
          time: DateTime(2026, 1, 1, 12, 0, 3),
          level: LogLevel.error,
          message: 'Parse failed',
          error: const LogError(type: 'FormatException', message: 'FormatException: Unexpected token'),
        ),
      ]);

      expect(store.database.select('SELECT text FROM log_entry_texts ORDER BY entry_id').map((row) => row['text']), [
        'Ошибка Сети',
        'Sync failed\nStateError: Bad state: Disk FULL',
        'Parse failed\nFormatException: Unexpected token',
      ], reason: 'the type is not repeated when the message starts with it');
      expect(await _messages(store, const LogQuery(filter: LogFilter(text: 'stateerror: bad'))), ['Sync failed']);
      expect(await _messages(store, const LogQuery(filter: LogFilter(text: 'unexpected'))), ['Parse failed']);
      expect(
        await _messages(store, const LogQuery(filter: LogFilter(text: 'сети\nstateerror'))),
        isEmpty,
        reason: 'the line break between message and error is not searchable text',
      );
    });

    test('the index follows removals: removed entries are not found, their text rows are gone', () async {
      await store.writeEntries([_entry('Ошибка одна', 1), _entry('Ошибка две', 2), _entry('Ошибка три', 3)]);

      await store.removeBefore(DateTime(2026, 1, 1, 12, 0, 2));
      await store.retainNewest(1);

      expect(await _messages(store, const LogQuery(filter: LogFilter(text: 'ошибка'))), ['Ошибка три']);
      expect(store.database.select('SELECT COUNT(*) AS c FROM log_entry_texts').single['c'], 1);
      expect(
        store.database.select("SELECT rowid FROM log_entry_fts WHERE log_entry_fts MATCH '\"ошибка\"'"),
        hasLength(1),
      );

      await store.clear();
      expect(store.database.select("SELECT rowid FROM log_entry_fts WHERE log_entry_fts MATCH '\"ошибка\"'"), isEmpty);
    });

    test('LIKE pattern characters are matched literally', () async {
      await store.writeEntries([_entry('100% done', 1), _entry('100 done', 2), _entry('a_b', 3), _entry('aXb', 4)]);

      expect(await _messages(store, const LogQuery(filter: LogFilter(text: '100%'))), ['100% done']);
      expect(await _messages(store, const LogQuery(filter: LogFilter(text: 'a_b'))), ['a_b']);
    });

    test('decided over the JSON: escaped characters, a needle across type and message, pages', () async {
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

      final page = await store.queryEntries(const LogQuery(filter: LogFilter(text: 'übertragung "2'), limit: 7));
      expect(page.entries.map((e) => e.entry.message), [
        for (final i in [21, 24, 27, 201, 204, 207, 210]) 'ÜBERTRAGUNG "$i" \\ gestört',
      ]);
      expect((await store.queryEntries(page.next!)).entries.first.entry.message, r'ÜBERTRAGUNG "213" \ gestört');
      expect(await _messages(store, const LogQuery(filter: LogFilter(text: r'" \ ges'))), hasLength(100));
      expect(await _messages(store, const LogQuery(filter: LogFilter(text: 'stateerror: disk'))), [
        for (final entry in entries)
          if (entry.error != null) entry.message,
      ]);
      expect(await _messages(store, const LogQuery(filter: LogFilter(text: 'nichts'))), isEmpty);
    });
  });

  test('a map attribute is found regardless of key order', () async {
    await store.writeEntries([
      _entry(
        'a',
        1,
        attributes: [
          payload(LogMap(const {'z': LogInt(1), 'a': LogInt(2)})),
        ],
      ),
    ]);

    final reordered = payload(LogMap(const {'a': LogInt(2), 'z': LogInt(1)}));
    expect(await _messages(store, LogQuery(filter: LogFilter(attributes: [reordered]))), ['a']);
  });

  test('queryTags collects tags of all entries and does not return tags of removed ones', () async {
    await store.writeEntries([
      _entry('a', 1, tags: {'x', 'y'}),
      _entry('b', 2, tags: {'y', 'z'}),
    ]);
    expect(await store.queryTags(), {'x', 'y', 'z'});

    await store.removeBefore(DateTime(2026, 1, 1, 12, 0, 2));
    expect(await store.queryTags(), {'y', 'z'});

    await store.clear();
    expect(await store.queryTags(), isEmpty);
  });

  test('removeBefore removes only entries strictly before and reports the removal', () async {
    await store.writeEntries([
      _entry('a', 1, tags: {'x'}, attributes: [userId('1')]),
      _entry('b', 2),
      _entry('c', 3),
    ]);
    final changes = <LogStoreChange>[];
    store.changes.listen(changes.add);

    await store.removeBefore(DateTime(2026, 1, 1, 12, 0, 2));
    await pumpEventQueue();

    expect(await _messages(store), ['b', 'c']);
    expect(store.count, 2);
    expect(changes, [
      isA<LogEntriesRemovedBefore>().having((c) => c.time, 'time', DateTime(2026, 1, 1, 12, 0, 2)),
    ]);
    expect(store.database.select('SELECT COUNT(*) AS c FROM log_entry_tags').single['c'], 0);
    expect(store.database.select('SELECT COUNT(*) AS c FROM log_entry_attributes').single['c'], 0);
  });

  test('clear removes everything and reports it', () async {
    await store.writeEntries([
      _entry('a', 1, tags: {'x'}),
      _entry('b', 2),
    ]);
    final changes = <LogStoreChange>[];
    store.changes.listen(changes.add);

    await store.clear();
    await pumpEventQueue();

    expect(await _all(store), isEmpty);
    expect(store.count, 0);
    expect(changes, [isA<AllLogEntriesRemoved>()]);
  });

  test('when limit is exceeded, the oldest entries are removed in the same transaction and reported', () async {
    final store = SqliteLogStore.inMemory(limit: 2);
    addTearDown(store.close);
    final changes = <LogStoreChange>[];
    store.changes.listen(changes.add);

    await store.writeEntries([
      _entry('a', 1, tags: {'old'}),
      _entry('b', 2),
      _entry('c', 3),
    ]);
    await pumpEventQueue();

    expect(await _messages(store), ['b', 'c']);
    expect(store.count, 2);
    expect(await store.queryTags(), isEmpty, reason: 'the tag of the removed entry does not remain');
    expect(changes.first, isA<LogEntriesAdded>().having((c) => c.entries, 'entries', hasLength(3)));
    expect(changes.last, isA<LogEntriesRemovedById>().having((c) => c.ids, 'ids', {1}));
  });

  test('retainNewest keeps the newest and reports the removed; within the limit it is silent', () async {
    await store.writeEntries([for (var i = 0; i < 5; i++) _entry('m$i', i)]);
    final changes = <LogStoreChange>[];
    store.changes.listen(changes.add);

    await store.retainNewest(5);
    await store.retainNewest(2);
    await pumpEventQueue();

    expect(await _messages(store), ['m3', 'm4']);
    expect(changes.single, isA<LogEntriesRemovedById>().having((c) => c.ids, 'ids', {1, 2, 3}));
  });

  test('ids are not reused after all entries are removed', () async {
    await store.writeEntries([_entry('a', 1), _entry('b', 2)]);
    await store.clear();
    final stored = await store.writeEntries([_entry('c', 3)]);

    expect(stored.single.id, 3);
  });

  test('a write failure rolls back the whole transaction, the counter stays correct', () async {
    await store.writeEntries([_entry('a', 1)]);
    // NaN has no JSON form: jsonEncode fails on the batch's second entry, after the first is inserted.
    final broken = LogEntry(
      time: DateTime(2026),
      level: LogLevel.info,
      message: 'b',
      attributes: LogAttributes([
        payload(LogMap(const {'k': LogDouble(double.nan)})),
      ]),
    );

    await expectLater(store.writeEntries([_entry('ok', 2), broken]), throwsA(anything));

    expect(await _messages(store), ['a'], reason: 'no entry of the batch is saved');
    expect(store.count, 1);
    expect(await store.queryTags(), isEmpty);
  });

  group('file', () {
    late Directory directory;
    late String path;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('log_trail_sqlite_');
      path = '${directory.path}/log.sqlite';
    });
    tearDown(() => directory.deleteSync(recursive: true));

    test('entries and ids survive close and reopen', () async {
      final first = SqliteLogStore.open(path, limit: 10);
      await first.writeEntries([
        _entry('a', 1, tags: {'x'}, attributes: [userId('1')]),
        _entry('b', 2),
      ]);
      await first.removeBefore(DateTime(2026, 1, 1, 12, 0, 2));
      await first.close();

      final second = SqliteLogStore.open(path, limit: 10);
      addTearDown(second.close);
      final stored = await second.writeEntries([_entry('c', 3)]);

      expect(second.count, 2);
      expect((await _all(second)).map((e) => (e.id, e.entry.message)), [(2, 'b'), (3, 'c')]);
      expect(stored.single.id, 3, reason: 'AUTOINCREMENT does not reuse ids');
      expect(await second.queryTags(), isEmpty);
      expect(second.database.select('PRAGMA journal_mode').single.columnAt(0), 'wal');
      expect(second.database.userVersion, SqliteLogStore.schemaVersion);
    });

    test('durability sets PRAGMA synchronous: NORMAL (1) by default, FULL (2) for powerLoss', () async {
      final normal = SqliteLogStore.open(path);
      expect(normal.database.select('PRAGMA synchronous').single.columnAt(0), 1, reason: 'NORMAL');
      await normal.close();

      final full = SqliteLogStore.open(path, durability: SqliteDurability.powerLoss);
      addTearDown(full.close);
      expect(full.database.select('PRAGMA synchronous').single.columnAt(0), 2, reason: 'FULL');
      await full.writeEntries([_entry('a', 1)]);
      expect((await _all(full)).single.entry.message, 'a');
    });

    test('a database with a schema newer than supported does not open', () {
      final database = sqlite3.open(path)..userVersion = SqliteLogStore.schemaVersion + 1;
      database.close();

      expect(() => SqliteLogStore.open(path), throwsStateError);
    });

    group('migration', () {
      test('schema version equals the number of steps', () {
        expect(SqliteLogStore.schemaVersion, SqliteLogStore.migrations.length);
        expect(SqliteLogStore.schemaVersion, greaterThan(0));
      });

      for (var from = 0; from < SqliteLogStore.schemaVersion; from++) {
        test('a version $from database is brought to the current version and works', () async {
          final database = sqlite3.open(path);
          for (var step = 0; step < from; step++) {
            database
              ..execute(SqliteLogStore.migrations[step])
              ..userVersion = step + 1;
          }
          database.close();

          final store = SqliteLogStore.open(path, limit: 10);
          addTearDown(store.close);
          await store.writeEntries([
            _entry('after migration', 1, tags: {'x'}, attributes: [userId('1')]),
          ]);

          expect(store.database.userVersion, SqliteLogStore.schemaVersion);
          expect((await _all(store)).single.entry.message, 'after migration');
          expect(await store.queryTags(), {'x'});
          expect(await _messages(store, LogQuery(filter: LogFilter(attributes: [userId('1')]))), ['after migration']);
        });
      }

      test('a failed step rolls back only itself: the version is unchanged, reopening retries', () {
        // A table with a name from the schema makes step 0 → 1 impossible.
        final database = sqlite3.open(path)..execute('CREATE TABLE log_entries (x)');
        database.close();

        expect(() => SqliteLogStore.open(path), throwsA(isA<LogStoreException>()));
        final reopened = sqlite3.open(path);
        addTearDown(reopened.close);
        expect(reopened.userVersion, 0, reason: 'user_version rolled back with the step');
        expect(
          reopened.select("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'log_tags'"),
          isEmpty,
          reason: 'the other tables of the step are not created',
        );
      });
    });

    test('a store over a foreign database does not close it unless it owns it', () async {
      final database = sqlite3.open(path);
      addTearDown(database.close);
      final store = SqliteLogStore(database);
      await store.writeEntries([_entry('a', 1)]);
      await store.close();

      expect(database.select('SELECT COUNT(*) AS c FROM log_entries').single['c'], 1, reason: 'database still open');
      final again = SqliteLogStore(database);
      expect(again.count, 1, reason: 'the schema is not created again');
      await again.close();
    });
  });

  test('close closes changes; reading, writing and removing after it throw StateError', () async {
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

  test('works under LogStoreSink: logger entries, including replayed startup ones, read back', () async {
    final logger = RootLogger(startupBufferTimeout: null);
    logger.info('before store', tags: {'startup'});
    logger.addSink(LogStoreSink(store));
    logger.child(tags: {'auth'}).warning('after store', attributes: [userId('42')]);
    logger.finishStartup();

    await logger.close();

    final entries = await _all(store);
    expect(entries.map((e) => e.entry.message), ['before store', 'after store']);
    expect(entries.last.entry.tags, {'auth'});
    expect(entries.last.entry.attributes.get(userId), '42');
    expect(entries.last.entry.location, isNotNull, reason: 'the warning call site is resolved before saving');
    expect(await store.queryTags(), {'startup', 'auth'});
  });

  test('LogWindow over the store receives changes and inserts new entries by time', () async {
    await store.writeEntries([_entry('a', 1), _entry('b', 3)]);
    final window = LogWindow(filter: const LogFilter(), pageSize: 10);
    store.changes.listen(window.apply);
    window.beginQuery();
    window.completeQuery(await store.queryEntries(window.query));

    await store.writeEntries([_entry('between', 2), _entry('c', 4)]);
    await store.retainNewest(3);
    await pumpEventQueue();

    expect(window.entries.map((e) => e.entry.message), ['c', 'b', 'between']);
  });
}
