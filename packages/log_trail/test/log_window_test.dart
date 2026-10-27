import 'package:log_trail/log_trail.dart';
import 'package:log_trail/storage.dart';
import 'package:test/test.dart';

final _start = DateTime(2026, 1, 1, 12);

StoredLogEntry _stored(int id, {int second = 0, LogLevel level = LogLevel.info, Set<String> tags = const {}}) =>
    StoredLogEntry(
      id,
      LogEntry(
        time: _start.add(Duration(seconds: second)),
        level: level,
        message: 'e$id',
        tags: tags,
      ),
    );

LogPage _page(List<StoredLogEntry> entries, {LogQuery? next}) => LogPage(entries, next: next);

void main() {
  late LogWindow window;

  setUp(() => window = LogWindow(filter: const LogFilter(), pageSize: 2));

  Iterable<int> ids() => window.entries.map((stored) => stored.id);

  test('pageSize must be positive', () {
    expect(() => LogWindow(filter: const LogFilter(), pageSize: 0), throwsA(isA<AssertionError>()));
  });

  test('query: filtered entries newest first by pageSize', () {
    const filter = LogFilter(levels: {LogLevel.error});
    final window = LogWindow(filter: filter, pageSize: 7);

    expect(window.query, const LogQuery(filter: filter, newestFirst: true, limit: 7));
    expect(window.isLoaded, isFalse);
    expect(window.entries, isEmpty);
  });

  test('completeQuery loads the page and remembers the cursor', () {
    final next = window.query.startingAfter(_stored(1).cursor);
    window
      ..beginQuery()
      ..completeQuery(_page([_stored(2, second: 2), _stored(1, second: 1)], next: next));

    expect(window.isLoaded, isTrue);
    expect(window.isQuerying, isFalse);
    expect(ids(), [2, 1]);
    expect(window.next, next);
  });

  test('next page is appended without id duplicates', () {
    window
      ..beginQuery()
      ..completeQuery(_page([_stored(3, second: 3), _stored(2, second: 2)], next: window.query))
      ..beginQuery()
      ..completeQuery(_page([_stored(2, second: 2), _stored(1, second: 1)]));

    expect(ids(), [3, 2, 1]);
    expect(window.next, isNull);
  });

  group('apply', () {
    test('before the first page loads changes are only remembered and applied over the result', () {
      window.beginQuery();
      expect(window.apply(LogEntriesAdded([_stored(3, second: 3)])), isFalse);
      expect(window.entries, isEmpty);

      // Store snapshot was taken before entry 3: it must end up in the window.
      window.completeQuery(_page([_stored(2, second: 2), _stored(1, second: 1)]));
      expect(ids(), [3, 2, 1]);
    });

    test('entry already seen by the query is not duplicated', () {
      window.beginQuery();
      window.apply(LogEntriesAdded([_stored(3, second: 3)]));
      window.completeQuery(_page([_stored(3, second: 3), _stored(2, second: 2)]));

      expect(ids(), [3, 2]);
    });

    test('new entries are placed by time, non-matching ones are skipped, tags are counted', () {
      final window = LogWindow(filter: const LogFilter(levels: {LogLevel.info}), pageSize: 10)
        ..beginQuery()
        ..completeQuery(_page([_stored(3, second: 3), _stored(1, second: 1)]));

      expect(
        window.apply(
          LogEntriesAdded([
            _stored(4, second: 2, tags: {'late'}),
          ]),
        ),
        isTrue,
      );
      expect(
        window.apply(
          LogEntriesAdded([
            _stored(5, second: 5, level: LogLevel.debug, tags: {'debug'}),
          ]),
        ),
        isFalse,
      );

      expect(window.entries.map((s) => s.id), [3, 4, 1], reason: 'entry 4 is between 3 and 1 by time');
      expect(window.addedTags, {'late', 'debug'}, reason: 'tags of non-matching entries too');
    });

    test('entry older than the loaded window is not inserted when a cursor exists', () {
      window
        ..beginQuery()
        ..completeQuery(_page([_stored(3, second: 3), _stored(2, second: 2)], next: window.query));

      expect(window.apply(LogEntriesAdded([_stored(1, second: 1)])), isFalse);
      expect(ids(), [3, 2], reason: 'the next page will load it');
    });

    test('removal by ids and by time drops entries', () {
      window
        ..beginQuery()
        ..completeQuery(_page([_stored(3, second: 3), _stored(2, second: 2), _stored(1, second: 1)]));

      expect(window.apply(LogEntriesRemovedById(const {2})), isTrue);
      expect(window.apply(LogEntriesRemovedById(const {99})), isFalse);
      expect(window.apply(LogEntriesRemovedBefore(_start.add(const Duration(seconds: 2)))), isTrue);
      expect(ids(), [3]);
    });

    test('removing all entries clears the window, cursor and tags', () {
      window
        ..beginQuery()
        ..completeQuery(_page([_stored(2, second: 2)], next: window.query))
        ..apply(
          LogEntriesAdded([
            _stored(3, second: 3, tags: {'x'}),
          ]),
        );

      expect(window.apply(const AllLogEntriesRemoved()), isTrue);
      expect(window.entries, isEmpty);
      expect(window.next, isNull);
      expect(window.addedTags, isEmpty);
    });

    test('completeQuery reports whether everything was removed during the query', () {
      window.beginQuery();
      window.apply(const AllLogEntriesRemoved());
      expect(window.completeQuery(_page([_stored(1)])), isTrue);

      window.beginQuery();
      expect(window.completeQuery(_page([])), isFalse);
    });

    test('LogStoreInvalidated leaves the window unchanged: the owner reloads', () {
      window
        ..beginQuery()
        ..completeQuery(_page([_stored(1)]));

      expect(window.apply(const LogStoreInvalidated()), isFalse);
      expect(ids(), [1]);
    });
  });

  test('failQuery drops remembered changes, the window stays', () {
    window
      ..beginQuery()
      ..completeQuery(_page([_stored(1)]))
      ..beginQuery();
    expect(window.isQuerying, isTrue);

    window.failQuery();

    expect(window.isQuerying, isFalse);
    expect(ids(), [1]);
  });

  group('trim', () {
    test('drops old entries over the limit and continues the page after the last kept one', () {
      window
        ..beginQuery()
        ..completeQuery(_page([_stored(3, second: 3), _stored(2, second: 2), _stored(1, second: 1)]));

      expect(window.trim(2), isTrue);
      expect(ids(), [3, 2]);
      expect(window.next, window.query.startingAfter(_stored(2, second: 2).cursor));
      expect(window.trim(2), isFalse, reason: 'within the limit');
    });

    test('not during a query: its result would continue the dropped part', () {
      window
        ..beginQuery()
        ..completeQuery(_page([_stored(3), _stored(2), _stored(1)]))
        ..beginQuery();

      expect(window.trim(1), isFalse);
      expect(ids(), [3, 2, 1]);
    });
  });
}
