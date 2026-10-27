import 'package:log_trail/log_trail.dart';
import 'package:log_trail/testing.dart';
import 'package:test/test.dart';

LogEntry _entry(String message, {LogLevel level = LogLevel.info, Set<String> tags = const {}}) =>
    LogEntry(time: DateTime(2026), level: level, message: message, tags: tags);

void main() {
  test('passes only entries the condition accepts', () {
    final inner = RecordingLogSink();
    FilteringSink(inner, (entry) => !entry.tags.contains('analytics'))
      ..add(_entry('screen opened', tags: {'analytics'}))
      ..add(_entry('request failed'));

    expect(inner.messages, ['request failed']);
  });

  test('minLevel: info with analytics attributes does not reach the release console', () {
    final printed = <String>[];
    FilteringSink.minLevel(
        ConsoleSink(format: const ConsoleLogFormat(showStackTrace: false), output: printed.add),
        LogLevel.warning,
      )
      ..add(_entry('analytics event {"utm_source": "x"}'))
      ..add(_entry('disk almost full', level: LogLevel.warning))
      ..add(_entry('Bad state: boom', level: LogLevel.error));

    expect(printed, hasLength(2));
    expect(printed.join('\n'), isNot(contains('utm_source')));
  });

  test('flush and close reach inner', () async {
    final inner = RecordingLogSink();
    final sink = FilteringSink.minLevel(inner, LogLevel.error);

    await sink.flush();
    await sink.close();

    expect(inner.flushCount, 1);
    expect(inner.closeCount, 1);
  });
}
