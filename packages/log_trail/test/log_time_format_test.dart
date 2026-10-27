import 'package:log_trail/log_trail.dart';
import 'package:test/test.dart';

void main() {
  group('formatLogTime', () {
    final now = DateTime(2026, 10, 22, 15);

    test('today entry: time only, zero-padded', () {
      expect(formatLogTime(DateTime(2026, 10, 22, 9, 3, 7), now: now), '09:03:07');
    });

    test('entry from another day includes the date', () {
      expect(formatLogTime(DateTime(2026, 10, 21, 9, 3, 7), now: now), '2026-10-21 09:03:07');
      expect(formatLogTime(DateTime(2025, 10, 22, 9, 3, 7), now: now), '2025-10-22 09:03:07');
    });
  });

  test('formatLogTimestamp: date, time and milliseconds, zero-padded', () {
    expect(formatLogTimestamp(DateTime(2026, 3, 4, 5, 6, 7, 89)), '2026-03-04 05:06:07.089');
  });

  test('UTC time (e.g. read from the store) is shown in local time', () {
    final local = DateTime(2026, 3, 4, 5, 6, 7, 89);
    final utc = local.toUtc();

    expect(formatLogTimestamp(utc), formatLogTimestamp(local));
    expect(formatLogTimeOfDay(utc), formatLogTimeOfDay(local));
    expect(formatLogTime(utc, now: local), formatLogTime(local, now: local));
    expect(formatLogTime(utc, now: utc), '05:06:07', reason: 'now is converted to local too');
  });
}
