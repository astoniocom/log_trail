import 'package:log_trail/log_trail.dart';
import 'package:log_trail/testing.dart';
import 'package:test/test.dart';

void main() {
  test('levels are ordered from trace to fatal', () {
    expect(LogLevel.values.first, LogLevel.trace);
    expect(LogLevel.trace < LogLevel.debug, isTrue);
    expect(LogLevel.debug < LogLevel.info, isTrue);
    expect(LogLevel.warning >= LogLevel.warning, isTrue);
    expect(LogLevel.error > LogLevel.warning, isTrue);
    expect(LogLevel.info <= LogLevel.debug, isFalse);
    expect([LogLevel.fatal, LogLevel.trace, LogLevel.warning]..sort(), [
      LogLevel.trace,
      LogLevel.warning,
      LogLevel.fatal,
    ]);
  });

  test('trace is below the default root threshold and is enabled per module via child(minLevel:)', () {
    final sink = RecordingLogSink();
    final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink])..finishStartup();
    addTearDown(logger.close);

    logger.trace('dropped by root');
    logger.child(tags: {'net'}).trace('dropped by child without own level');
    logger.child(tags: {'net'}, minLevel: LogLevel.trace).trace('kept');

    expect(sink.entries.map((e) => e.message), ['kept']);
    expect(sink.entries.single.level, LogLevel.trace);
  });

  test('trace survives JSON and the console format', () {
    final entry = LogEntry(time: DateTime.utc(2026), level: LogLevel.trace, message: 'frame 12');

    expect(logEntryJson.decode(logEntryJson.encode(entry)), entry);
    expect(logEntryJson.encode(entry)['level'], 'trace');
    expect(const ConsoleLogFormat(useColors: false, showTime: false).format(entry), '⋯ frame 12');
  });
}
