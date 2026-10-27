import 'package:log_trail/log_trail.dart';
import 'package:log_trail/src/logger/log_pipeline.dart';
import 'package:log_trail/testing.dart';
import 'package:test/test.dart';

LogEntry _entry(String message, {LogLevel level = LogLevel.info}) =>
    LogEntry(time: DateTime.utc(2026), level: level, message: message);

LogPipeline _pipeline({
  List<LogSink> sinks = const [],
  List<LogProcessor> processors = const [],
  LogDispatchPolicy dispatch = LogDispatchPolicy.synchronous,
  List<LogDiagnostic>? diagnostics,
}) => LogPipeline(
  owner: 'Test',
  diagnostics: diagnostics == null ? DiagnosticReporter.console : DiagnosticReporter(diagnostics.add),
  dispatch: dispatch,
  sinks: sinks,
  processors: processors,
  startupBufferLimit: 10,
  startupBufferTimeout: null,
);

/// Sink that runs [onEntry] for every entry.
final class _CallbackSink extends LogSink {
  _CallbackSink(this.onEntry);

  final void Function(LogEntry entry) onEntry;

  @override
  void onAdd(LogEntry entry) => onEntry(entry);
}

void main() {
  test('processors run in order; null drops the entry; a failing processor drops it with a diagnostic', () {
    final sink = RecordingLogSink();
    final diagnostics = <LogDiagnostic>[];
    final pipeline = _pipeline(
      sinks: [sink],
      diagnostics: diagnostics,
      processors: [
        LogProcessor((entry) => entry.copyWith(message: '${entry.message} a')),
        LogProcessor((entry) => entry.message.contains('drop') ? null : entry.copyWith(message: '${entry.message} b')),
        LogProcessor((entry) => entry.message.contains('fail') ? throw StateError('bad') : entry),
      ],
    );

    pipeline
      ..accept(_entry('keep'))
      ..accept(_entry('drop'))
      ..accept(_entry('fail'));

    expect(sink.messages, ['keep a b']);
    expect(diagnostics.single.message, 'Test: processor failed, entry dropped');
  });

  test('startup buffer replays into a later sink after passing a processor added later', () {
    final pipeline = _pipeline()..accept(_entry('early'));
    pipeline.addProcessor(LogProcessor((entry) => entry.copyWith(message: '${entry.message}!')));
    final replayed = RecordingLogSink();
    final fresh = RecordingLogSink();

    pipeline
      ..addSink(replayed, replayStartupBuffer: true)
      ..addSink(fresh, replayStartupBuffer: false)
      ..finishStartup()
      ..accept(_entry('late'));

    expect(replayed.messages, ['early!', 'late!']);
    expect(fresh.messages, ['late!']);
  });

  test(
    'an entry accepted during queue dispatch is dispatched right after the current one, in the same batch',
    () async {
      late final LogPipeline pipeline;
      final sink = RecordingLogSink();
      var responded = false;
      pipeline = _pipeline(
        dispatch: const LogDispatchPolicy(),
        sinks: [
          FilteringSink(sink, (entry) {
            if (!responded && entry.message == 'first') {
              responded = true;
              pipeline.accept(_entry('response'));
            }
            return true;
          }),
        ],
      );

      pipeline
        ..accept(_entry('first'))
        ..accept(_entry('second'));
      await Future<void>.delayed(Duration.zero);

      expect(sink.messages, ['first', 'response', 'second'], reason: 'not queued to the next turn, not before first');
      expect(sink.batches, hasLength(1), reason: 'one endBatch for the queued batch and the response');
    },
  );

  test('flush dispatches the queue first; close ends startup, closes sinks and refuses new sinks', () async {
    final sink = RecordingLogSink();
    final pipeline = _pipeline(dispatch: const LogDispatchPolicy(), sinks: [sink])..accept(_entry('queued'));

    await pipeline.flush();
    expect(sink.messages, ['queued']);
    expect(sink.flushCount, 1);

    pipeline.accept(_entry('before close'));
    await pipeline.close();
    expect(sink.messages, ['queued', 'before close']);
    expect(sink.closeCount, 1);
    expect(pipeline.isClosed, isTrue);
    expect(() => pipeline.addSink(RecordingLogSink(), replayStartupBuffer: true), throwsStateError);
  });

  test('the same sink or processor added twice is attached once', () {
    final sink = RecordingLogSink();
    final processor = LogProcessor((entry) => entry.copyWith(message: '${entry.message}+'));
    final pipeline = _pipeline(sinks: [sink], processors: [processor])
      ..addSink(sink, replayStartupBuffer: false)
      ..addProcessor(processor)
      ..accept(_entry('once'));

    expect(sink.messages, ['once+']);
    expect(pipeline.sinks, [sink]);
    expect(pipeline.processors, [processor]);
  });

  group('logging into the pipeline from inside a dispatch', () {
    test("a sink's entry is dispatched to all after the current one, not from inside the fan-out", () {
      final before = RecordingLogSink();
      final after = RecordingLogSink();
      late final LogPipeline pipeline;
      pipeline = _pipeline(
        sinks: [
          before,
          _CallbackSink((entry) {
            if (entry.message == 'hello') pipeline.accept(_entry('from sink'));
          }),
          after,
        ],
      );
      pipeline.accept(_entry('hello'));

      expect(before.messages, ['hello', 'from sink']);
      expect(after.messages, ['hello', 'from sink'], reason: 'a later sink does not get the response before its cause');
    });

    test('a response to a deferred entry is dropped with one diagnostic; no recursion', () {
      final recording = RecordingLogSink();
      final diagnostics = <LogDiagnostic>[];
      late final LogPipeline pipeline;
      pipeline = _pipeline(
        diagnostics: diagnostics,
        sinks: [
          recording,
          // Responds to every entry, including its own: without the guard this is infinite recursion.
          _CallbackSink((entry) => pipeline.accept(_entry('echo of ${entry.message}'))),
        ],
      );
      pipeline
        ..accept(_entry('one'))
        ..accept(_entry('two'));

      expect(recording.messages, ['one', 'echo of one', 'two', 'echo of two']);
      expect(diagnostics.single.message, contains('dropped to break the loop'));
    });

    test('a processor logging on every entry yields one extra entry per entry, through the processors', () async {
      final recording = RecordingLogSink();
      final diagnostics = <LogDiagnostic>[];
      late final LogPipeline pipeline;
      pipeline = _pipeline(
        diagnostics: diagnostics,
        dispatch: const LogDispatchPolicy(),
        sinks: [recording],
        processors: [
          LogProcessor((entry) {
            pipeline.accept(_entry('seen ${entry.message}'));
            return entry.copyWith(message: '${entry.message}!');
          }),
        ],
      );
      pipeline.accept(_entry('user'));
      await pipeline.flush();

      expect(recording.messages, ['user!', 'seen user!'], reason: "the processor's entry passed the processors too");
      expect(diagnostics.single.message, contains('dropped to break the loop'));
      expect(diagnostics.single.error, isNull, reason: 'no StackOverflowError');
    });

    test('an entry logged during a replay is dispatched to all after the replay', () {
      final existing = RecordingLogSink();
      final seen = <String>[];
      late final LogPipeline pipeline;
      pipeline = _pipeline(sinks: [existing])
        ..accept(_entry('early'))
        ..accept(_entry('later'));
      existing.entries.clear();

      pipeline.addSink(
        _CallbackSink((entry) {
          seen.add(entry.message);
          if (entry.message == 'early') pipeline.accept(_entry('on replay'));
        }),
        replayStartupBuffer: true,
      );

      expect(seen, ['early', 'later', 'on replay']);
      expect(existing.messages, ['on replay'], reason: 'only the new sink gets the replay, everyone gets the response');
    });
  });
}
