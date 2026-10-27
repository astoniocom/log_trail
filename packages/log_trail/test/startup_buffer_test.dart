import 'package:log_trail/log_trail.dart';
import 'package:log_trail/src/logger/startup_buffer.dart';
import 'package:test/test.dart';

LogEntry _entry(String message, int second) =>
    LogEntry(time: DateTime(2026, 1, 1, 12, 0, second), level: LogLevel.info, message: message);

Iterable<String> _messages(List<LogEntry> entries) => entries.map((e) => e.message);

void main() {
  late int timeouts;

  setUp(() => timeouts = 0);

  /// Buffer counting timer fires; no timer without [timeout].
  StartupBuffer buffer({int limit = 10, Duration? timeout}) =>
      StartupBuffer(limit: limit, timeout: timeout, onTimeout: () => timeouts++);

  test('limit must be positive', () {
    expect(() => buffer(limit: 0), throwsA(isA<AssertionError>()));
  });

  test('entries replay oldest first', () {
    final startup = buffer()
      ..add(_entry('first', 1))
      ..add(_entry('second', 2));

    expect(_messages(startup.snapshot()), ['first', 'second']);
    expect(startup.isActive, isTrue);
  });

  test('on overflow the oldest are dropped, replay starts with the warning', () {
    final startup = buffer(limit: 2);
    for (var i = 1; i <= 5; i++) {
      startup.add(_entry('e$i', i));
    }

    final replayed = startup.snapshot();
    expect(_messages(replayed), ['Startup log buffer overflow: 3 earlier event(s) dropped', 'e4', 'e5']);
    final overflow = replayed.first;
    expect(overflow.level, LogLevel.warning);
    expect(overflow.tags, {startupLogTag});
    expect(overflow.time, _entry('e3', 3).time, reason: 'time of the last dropped entry');
  });

  test('no warning without drops; empty buffer replays nothing', () {
    final startup = buffer(limit: 2);
    expect(startup.snapshot(), isEmpty);

    startup.add(_entry('only', 1));
    expect(_messages(startup.snapshot()), ['only']);
  });

  test('replay is a snapshot: adding during replay does not change the list', () {
    final startup = buffer()..add(_entry('first', 1));

    final replayed = startup.snapshot();
    startup.add(_entry('second', 2));

    expect(replayed, hasLength(1));
    expect(startup.snapshot(), hasLength(2));
  });

  test('finish clears the buffer and stops buffering; further add calls are ignored', () {
    final startup = buffer(limit: 2);
    for (var i = 1; i <= 3; i++) {
      startup.add(_entry('e$i', i));
    }
    startup.finish();

    expect(startup.isActive, isFalse);
    expect(startup.snapshot(), isEmpty, reason: 'neither entries nor a warning about earlier drops');

    startup.add(_entry('late', 4));
    expect(startup.snapshot(), isEmpty);
    expect(timeouts, 0);
  });

  test('on timeout the buffer releases itself without being touched and calls onTimeout once', () async {
    final startup = buffer(timeout: const Duration(milliseconds: 20))..add(_entry('early', 1));
    expect(startup.isActive, isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(startup.isActive, isFalse);
    expect(startup.snapshot(), isEmpty, reason: 'entries released by the timer');
    expect(timeouts, 1);

    startup.add(_entry('late', 2));
    expect(startup.snapshot(), isEmpty);
  });

  test('finish before timeout cancels the timer: onTimeout is not called', () async {
    buffer(timeout: const Duration(milliseconds: 20)).finish();

    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(timeouts, 0);
  });

  test('timeout: null buffers only until finish', () async {
    final startup = buffer();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(startup.isActive, isTrue);
    expect(timeouts, 0);
  });
}
