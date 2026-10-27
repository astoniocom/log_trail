import 'package:log_trail/log_trail.dart';
import 'package:log_trail/storage.dart';
import 'package:test/test.dart';

LogEntry _at(int minute) => LogEntry(time: DateTime(2026, 1, 1, 12, minute), level: LogLevel.info, message: 'm$minute');

StoredLogEntry _stored(int id, int minute) => StoredLogEntry(id, _at(minute));

void main() {
  test('limit must be positive', () {
    expect(() => LogQuery(limit: 0), throwsA(isA<AssertionError>()));
  });

  test('startingAfter keeps filter, order and page size', () {
    const filter = LogFilter(levels: {LogLevel.error}, tags: {'net'});
    const query = LogQuery(filter: filter, newestFirst: true, limit: 5);
    final cursor = _stored(7, 3).cursor;

    final next = query.startingAfter(cursor);

    expect(next.filter, filter);
    expect(next.newestFirst, isTrue);
    expect(next.limit, 5);
    expect(next.startAfter, cursor);
  });

  test('queries with the same conditions are equal', () {
    final cursor = _stored(7, 3).cursor;
    expect(LogQuery(limit: 5, startAfter: cursor), LogQuery(limit: 5, startAfter: cursor));
    expect(LogQuery(limit: 5, startAfter: cursor), isNot(const LogQuery(limit: 5)));
  });

  group('LogCursor', () {
    test('compares by time as an instant, then by id', () {
      final utc = LogCursor(DateTime.utc(2026, 1, 1, 12), 1);
      final local = LogCursor(DateTime.utc(2026, 1, 1, 12).toLocal(), 1);
      expect(utc, local);
      expect(utc.hashCode, local.hashCode);
      expect(utc.compareTo(local), 0);
      expect(LogCursor(DateTime(2026, 1, 1, 12), 1).compareTo(LogCursor(DateTime(2026, 1, 1, 12), 2)), isNegative);
      expect(LogCursor(DateTime(2026, 1, 1, 13), 1).compareTo(LogCursor(DateTime(2026, 1, 1, 12), 2)), isPositive);
    });
  });

  group('StoredLogEntry', () {
    test('equal when id and entry are the same', () {
      expect(_stored(1, 0), _stored(1, 0));
      expect(_stored(1, 0), isNot(_stored(2, 0)), reason: 'equal entries with different ids are distinct');
      expect(_stored(1, 0), isNot(_stored(1, 1)));
      expect(_stored(1, 0).hashCode, _stored(1, 0).hashCode);
    });
  });
}
