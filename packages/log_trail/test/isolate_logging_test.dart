import 'dart:isolate';

import 'package:log_trail/isolates.dart';
import 'package:log_trail/log_trail.dart';
import 'package:log_trail/testing.dart';
import 'package:test/test.dart';

const _jobId = LogField('test.job_id', LogCodec.integer);

/// Background isolate body: own root writing to the main isolate.
void _work(SendPort logPort) {
  final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [IsolateLogSink(logPort)])..finishStartup();
  final log = logger.child(tags: {'sync'})..log('Sync started', attributes: [_jobId(7)]);
  try {
    throw const FormatException('disk full');
  } on FormatException catch (error, stackTrace) {
    log.recordError(error, stackTrace, message: 'Sync failed');
  }
  logger.log('noise', level: LogLevel.debug);
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test('background isolate entries reach the main one with tags, attributes, error and stack', () async {
    final sink = RecordingLogSink();
    final receiver = IsolateLogReceiver(sink);
    addTearDown(receiver.close);
    final port = receiver.sendPort;

    await Isolate.run(() => _work(port));
    await _until(() => sink.entries.length == 3);

    expect(sink.entries.map((e) => e.message), ['Sync started', 'Sync failed', 'noise']);
    final started = sink.entries[0];
    expect(started.tags, {'sync'});
    expect(started.attributes.get(_jobId), 7);
    final failed = sink.entries[1];
    expect(failed.error, const LogError(type: 'FormatException', message: 'FormatException: disk full'));
    expect(failed.error?.original, isNull, reason: 'live error object does not cross isolates');
    expect(failed.location, contains('isolate_logging_test.dart'));
    expect(failed.stackTrace.toString(), contains('_work'));
  });

  test('in the main isolate entries pass through the root: threshold and redaction', () async {
    final sink = RecordingLogSink();
    final logger = RootLogger(
      dispatch: LogDispatchPolicy.synchronous,
      sinks: [sink],
      floor: LogLevel.info,
      processors: const [
        LogRedactor(patterns: ['disk']),
      ],
    )..finishStartup();
    final receiver = IsolateLogReceiver(logger.asSink());
    addTearDown(receiver.close);
    final port = receiver.sendPort;

    await Isolate.run(() => _work(port));
    await _until(() => sink.entries.length == 2);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(sink.entries.map((e) => e.message), ['Sync started', 'Sync failed'], reason: 'debug below root threshold');
    expect(sink.entries[1].error?.message, 'FormatException: [REDACTED] full');
  });

  test('corrupt message goes to diagnostics and does not block the next ones', () async {
    final sink = RecordingLogSink();
    final diagnostics = <LogDiagnostic>[];
    sink.attach(DiagnosticReporter(diagnostics.add));
    final receiver = IsolateLogReceiver(sink);
    addTearDown(receiver.close);

    receiver.sendPort
      ..send(42)
      ..send('{"not": "an entry"}')
      ..send(<String, Object?>{'not': 'an entry'});
    IsolateLogSink(receiver.sendPort).add(LogEntry(time: DateTime(2026), level: LogLevel.info, message: 'ok'));
    await _until(() => sink.entries.isNotEmpty);

    expect(diagnostics.map((d) => d.message), everyElement('IsolateLogReceiver: entry dropped'));
    expect(diagnostics, hasLength(3));
    expect(diagnostics.map((d) => d.error), everyElement(isA<FormatException>()));
    expect(sink.entries.single.message, 'ok');
  });

  test('entries are rejected after close', () async {
    final sink = RecordingLogSink();
    final receiver = IsolateLogReceiver(sink);
    final port = receiver.sendPort;
    await receiver.close();

    IsolateLogSink(port).add(LogEntry(time: DateTime(2026), level: LogLevel.info, message: 'late'));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(sink.entries, isEmpty);
  });
}
