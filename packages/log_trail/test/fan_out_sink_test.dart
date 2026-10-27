import 'package:log_trail/log_trail.dart';
import 'package:log_trail/src/sinks/fan_out_sink.dart';
import 'package:log_trail/testing.dart';
import 'package:test/test.dart';

LogEntry _entry(String message) => LogEntry(time: DateTime(2026), level: LogLevel.info, message: message);

final class _FailingSink extends LogSink {
  _FailingSink([this.label = '']);

  final String label;

  @override
  String get name => '_FailingSink$label';

  @override
  void onAdd(LogEntry entry) => throw StateError('add failed$label');

  @override
  Future<void> onFlush() async => throw StateError('flush failed$label');

  @override
  Future<void> onClose() async => throw StateError('close failed$label');
}

final class _CallbackSink extends LogSink {
  _CallbackSink(this.callback);

  final void Function(LogEntry entry) callback;

  @override
  void onAdd(LogEntry entry) => callback(entry);
}

void main() {
  late List<LogDiagnostic> diagnostics;
  late DiagnosticReporter reporter;

  setUp(() {
    diagnostics = [];
    reporter = DiagnosticReporter(diagnostics.add);
  });

  FanOutSink fanOut([List<LogSink> sinks = const []]) => FanOutSink(sinks, owner: 'Owner', diagnostics: reporter);

  test('passes the diagnostics reporter to constructor sinks and to later-attached ones', () {
    final initial = RecordingLogSink();
    final added = RecordingLogSink();
    expect(initial.diagnostics, DiagnosticReporter.console, reason: 'before attach');

    fanOut([initial]).addSink(added);

    expect(initial.diagnostics, same(reporter));
    expect(added.diagnostics, same(reporter));
  });

  test('dispatches the entry to all sinks, a duplicate in the list does not double it', () {
    final sink = RecordingLogSink();
    final other = RecordingLogSink();
    fanOut([sink, sink, other]).add(_entry('hello'));

    expect(sink.messages, ['hello']);
    expect(other.messages, ['hello']);
  });

  test('sink failure does not block the others and goes to diagnostics with the owner name', () {
    final good = RecordingLogSink();
    fanOut([_FailingSink(), good]).add(_entry('hello'));

    expect(good.messages, ['hello']);
    expect(diagnostics.single.message, 'Owner: sink failed');
    expect(diagnostics.single.error, isA<StateError>());
  });

  test('addSink passes only replay to the new sink, attaching again does nothing', () {
    final existing = RecordingLogSink();
    final added = RecordingLogSink();
    final sinks = fanOut([existing])..addSink(added, replay: [_entry('early')]);
    sinks.addSink(added, replay: [_entry('again')]);

    expect(added.messages, ['early']);
    expect(existing.messages, isEmpty);
    expect(sinks.sinks, [existing, added]);
  });

  test('sink failure during replay goes to diagnostics', () {
    fanOut().addSink(_FailingSink(), replay: [_entry('early')]);

    expect(diagnostics.single.message, 'Owner: sink failed');
  });

  test('sink removed during fan-out still receives it to the end of the old list', () {
    final last = RecordingLogSink();
    final sinks = fanOut();
    sinks
      ..addSink(_CallbackSink((_) => sinks.removeSink(last)))
      ..addSink(last)
      ..add(_entry('one'))
      ..add(_entry('two'));

    expect(last.messages, ['one']);
  });

  test('flush and close reach all sinks; the first error is returned', () async {
    final good = RecordingLogSink();
    final sinks = fanOut([_FailingSink(), good]);

    await expectLater(sinks.flush(), throwsStateError);
    await expectLater(sinks.close(), throwsStateError);

    expect(good.flushCount, 1);
    expect(good.closeCount, 1);
  });

  test('every sink failure on flush and close goes to diagnostics with its name, not only the first', () async {
    final sinks = fanOut([_FailingSink(' A'), RecordingLogSink(), _FailingSink(' B')]);

    await expectLater(
      sinks.flush(),
      throwsA(isA<StateError>().having((e) => e.message, 'message', 'flush failed A')),
      reason: 'caller gets the first error',
    );
    expect(diagnostics.map((d) => d.message), [
      'Owner: sink flush failed: _FailingSink A',
      'Owner: sink flush failed: _FailingSink B',
    ]);
    expect(diagnostics.map((d) => '${d.error}'), ['Bad state: flush failed A', 'Bad state: flush failed B']);
    expect(diagnostics.map((d) => d.stackTrace), everyElement(isNotNull));

    diagnostics.clear();
    await expectLater(sinks.close(), throwsStateError);
    expect(diagnostics.map((d) => d.message), [
      'Owner: sink close failed: _FailingSink A',
      'Owner: sink close failed: _FailingSink B',
    ]);
  });
}
