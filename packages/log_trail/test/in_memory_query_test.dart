import 'package:log_trail/log_trail.dart';
import 'package:log_trail/storage.dart';
import 'package:test/test.dart';

LogEntry _at(int minute, {LogLevel level = LogLevel.info, String? message}) => LogEntry(
  time: DateTime(2026, 1, 1, 12, minute),
  level: level,
  message: message ?? 'm$minute',
);

/// Like a store: ids in storage order, starting at 1.
List<StoredLogEntry> _stored(List<LogEntry> entries) => [
  for (final (index, entry) in entries.indexed) StoredLogEntry(index + 1, entry),
];

List<String> _messages(LogPage page) => [for (final stored in page.entries) stored.entry.message];

/// All query pages in sequence.
List<String> _allPages(LogQuery query, List<StoredLogEntry> entries) {
  final messages = <String>[];
  LogQuery? next = query;
  while (next != null) {
    final page = queryInMemory(entries, next);
    messages.addAll(_messages(page));
    next = page.next;
  }
  return messages;
}

void main() {
  final entries = _stored([_at(0), _at(10), _at(20)]);

  test('entries out of time order: error in debug', () {
    expect(() => queryInMemory(_stored([_at(20), _at(0)]), const LogQuery()), throwsA(isA<AssertionError>()));
  });

  test('same-time entries out of id order: error in debug', () {
    final swapped = [StoredLogEntry(2, _at(1)), StoredLogEntry(1, _at(1))];
    expect(() => queryInMemory(swapped, const LogQuery()), throwsA(isA<AssertionError>()));
  });

  test('returns in ascending time order by default', () {
    expect(_messages(queryInMemory(entries, const LogQuery())), ['m0', 'm10', 'm20']);
  });

  test('newestFirst returns in descending order', () {
    expect(_messages(queryInMemory(entries, const LogQuery(newestFirst: true))), ['m20', 'm10', 'm0']);
  });

  test('period bounds with a cursor in both directions', () {
    final many = _stored([for (var i = 0; i < 10; i++) _at(i)]);
    final filter = LogFilter(after: DateTime(2026, 1, 1, 12, 2), before: DateTime(2026, 1, 1, 12, 8));

    expect(_allPages(LogQuery(filter: filter, limit: 2), many), ['m3', 'm4', 'm5', 'm6', 'm7']);
    expect(_allPages(LogQuery(filter: filter, limit: 2, newestFirst: true), many), ['m7', 'm6', 'm5', 'm4', 'm3']);
  });

  test('full last page with no further matching entries has no cursor', () {
    final mixed = _stored([for (var i = 0; i < 6; i++) _at(i, level: i < 2 ? LogLevel.error : LogLevel.info)]);
    final page = queryInMemory(mixed, const LogQuery(filter: LogFilter(levels: {LogLevel.error}), limit: 2));

    expect(_messages(page), ['m0', 'm1']);
    expect(page.next, isNull);
  });

  test('filters before paging', () {
    final mixed = _stored([
      for (var i = 0; i < 10; i++) _at(i, level: i.isEven ? LogLevel.error : LogLevel.info),
    ]);
    final page = queryInMemory(mixed, const LogQuery(filter: LogFilter(levels: {LogLevel.error}), limit: 3));
    expect(_messages(page), ['m0', 'm2', 'm4']);
  });

  test('without limit returns everything in one page', () {
    expect(queryInMemory(entries, const LogQuery()).next, isNull);
  });

  test('pages by limit cover all entries without repeats', () {
    final many = _stored([for (var i = 0; i < 7; i++) _at(i)]);
    expect(_allPages(const LogQuery(limit: 3), many), [for (var i = 0; i < 7; i++) 'm$i']);
    expect(_allPages(const LogQuery(limit: 3, newestFirst: true), many), [for (var i = 6; i >= 0; i--) 'm$i']);
  });

  test('cursor is the position of the last entry on the page', () {
    final many = _stored([for (var i = 0; i < 7; i++) _at(i)]);

    final page = queryInMemory(many, const LogQuery(limit: 3));

    expect(page.next?.startAfter, page.entries.last.cursor);
    expect(page.next?.limit, 3);
  });

  test('same-time entries are neither lost nor repeated at page boundaries', () {
    final sameTime = [for (var i = 0; i < 5; i++) _at(1, message: 'same$i')];
    final entries = _stored([_at(0), ...sameTime, _at(2)]);

    expect(_allPages(const LogQuery(limit: 2), entries), ['m0', 'same0', 'same1', 'same2', 'same3', 'same4', 'm2']);
    expect(
      _allPages(const LogQuery(limit: 2, newestFirst: true), entries),
      ['m2', 'same4', 'same3', 'same2', 'same1', 'same0', 'm0'],
    );
  });

  test('cursor at a removed entry continues from the next one', () {
    final many = _stored([for (var i = 0; i < 6; i++) _at(i)]);
    final oldest = queryInMemory(many, const LogQuery(limit: 2)); // m0, m1
    final newest = queryInMemory(many, const LogQuery(limit: 2, newestFirst: true)); // m5, m4

    final withoutM1 = [...many]..removeWhere((stored) => stored.entry.message == 'm1');
    expect(_messages(queryInMemory(withoutM1, oldest.next!)), ['m2', 'm3']);

    final withoutM4 = [...many]..removeWhere((stored) => stored.entry.message == 'm4');
    expect(_messages(queryInMemory(withoutM4, newest.next!)), ['m3', 'm2']);
  });

  test('new entries between pages do not shift the next page', () {
    final entries = _stored([for (var i = 0; i < 6; i++) _at(i)]);
    final first = queryInMemory(entries, const LogQuery(newestFirst: true, limit: 3));
    expect(_messages(first), ['m5', 'm4', 'm3']);

    final grown = [...entries, StoredLogEntry(7, _at(30)), StoredLogEntry(8, _at(31))];
    expect(_messages(queryInMemory(grown, first.next!)), ['m2', 'm1', 'm0']);
  });

  test('startup entry with a past time and a new id sorts after entries of the same time', () {
    // As in InMemoryLogStore: a replayed entry goes after earlier stored entries with the same time.
    final entries = [StoredLogEntry(1, _at(1, message: 'live')), StoredLogEntry(2, _at(1, message: 'replayed'))];

    expect(_allPages(const LogQuery(limit: 1), entries), ['live', 'replayed']);
    expect(_allPages(const LogQuery(limit: 1, newestFirst: true), entries), ['replayed', 'live']);
  });

  test('next page keeps the attribute filter', () {
    const userId = LogField('test.user_id', LogCodec.string);
    final entries = _stored([
      for (var i = 0; i < 6; i++)
        LogEntry(
          time: DateTime(2026, 1, 1, 12, i),
          level: LogLevel.info,
          message: 'm$i',
          attributes: LogAttributes([userId(i.isEven ? '42' : '7')]),
        ),
    ]);

    expect(_allPages(LogQuery(filter: LogFilter(attributes: [userId('42')]), limit: 2), entries), ['m0', 'm2', 'm4']);
  });
}
