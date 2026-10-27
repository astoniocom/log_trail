import 'package:log_trail/log_trail.dart';
import 'package:log_trail/testing.dart';
import 'package:test/test.dart';

LogEntry _entry(String message) => LogEntry(time: DateTime(2026), level: LogLevel.info, message: message);

void main() {
  test('records entries and messages in order, counts flush and close', () async {
    final sink = RecordingLogSink()
      ..add(_entry('a'))
      ..add(_entry('b'));

    await sink.flush();
    await sink.flush();
    await sink.close();
    await sink.close();

    expect(sink.messages, ['a', 'b']);
    expect(sink.entries.map((e) => e.level), everyElement(LogLevel.info));
    expect(sink.flushCount, 2);
    expect(sink.closeCount, 1, reason: 'LogSink closes once');
    expect(() => sink.add(_entry('c')), throwsStateError, reason: 'LogSink refuses entries after close');
    expect(sink.name, 'RecordingLogSink');
  });

  test('failOn makes add throw for the selected entries and keeps them out of entries', () {
    final sink = RecordingLogSink(failOn: (entry) => entry.message == 'bad')..add(_entry('good'));

    expect(
      () => sink.add(_entry('bad')),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('bad'))),
    );
    sink.failOn = null;
    sink.add(_entry('bad'));

    expect(sink.messages, ['good', 'bad']);
  });

  test('batches group entries by endBatch; an empty batch end adds nothing', () {
    final sink = RecordingLogSink()
      ..add(_entry('a'))
      ..add(_entry('b'))
      ..endBatch()
      ..endBatch()
      ..add(_entry('c'));

    expect(sink.batches.map((batch) => batch.map((e) => e.message)), [
      ['a', 'b'],
    ]);
    expect(sink.messages, ['a', 'b', 'c'], reason: 'the open batch is in entries already');
  });

  test('works as a root sink and as a wrapper inner', () async {
    final sink = RecordingLogSink();
    final logger = RootLogger(
      sinks: [FilteringSink.minLevel(sink, LogLevel.info)],
      dispatch: LogDispatchPolicy.synchronous,
    )..finishStartup();

    logger
      ..debug('hidden')
      ..info('shown');
    await logger.close();

    expect(sink.messages, ['shown']);
    expect(sink.closeCount, 1, reason: 'closed through the wrapper');
  });
}
