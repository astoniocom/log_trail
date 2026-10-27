import 'dart:async';

import 'package:log_trail/log_trail.dart';
import 'package:log_trail/storage.dart';
import 'package:test/test.dart';

LogEntry _entry(String message) => LogEntry(time: DateTime(2026), level: LogLevel.info, message: message);

final class _Sink extends LogSink {
  final List<String> written = [];
  final releaseGate = Completer<void>();
  int flushCount = 0;
  int releaseCount = 0;

  @override
  void onAdd(LogEntry entry) => written.add(entry.message);

  @override
  Future<void> onFlush() async => flushCount++;

  @override
  Future<void> onClose() async {
    releaseCount++;
    await releaseGate.future;
  }
}

void main() {
  test('name defaults to the class name; library sinks name themselves consistently', () {
    expect(_Sink().name, '_Sink');
    expect(_Sink().toString(), '_Sink');
    expect(ConsoleSink(output: (_) {}).name, 'ConsoleSink');
    expect(FilteringSink.minLevel(_Sink(), LogLevel.info).name, 'FilteringSink');
    expect(RepeatCollapsingSink(_Sink()).name, 'RepeatCollapsingSink');
    expect(LogStoreSink(InMemoryLogStore()).name, 'LogStoreSink');
    expect(RootLogger().asSink().name, 'RootLogger.asSink');
  });

  test('diagnostics before attach is the console; attach sets the reporter and calls onAttach', () {
    final sink = _AttachAwareSink();
    expect(sink.diagnostics, DiagnosticReporter.console);

    final reporter = DiagnosticReporter((_) {});
    sink.attach(reporter);

    expect(sink.diagnostics, same(reporter));
    expect(sink.attached, [same(reporter)]);
  });

  test('write error after close names the sink by name', () async {
    final sink = _Sink()..releaseGate.complete();
    await sink.close();

    expect(
      () => sink.add(_entry('late')),
      throwsA(isA<StateError>().having((e) => e.message, 'message', '_Sink is closed')),
    );
  });

  test('add after close throws StateError, write is not called', () async {
    final sink = _Sink()..releaseGate.complete();
    sink.add(_entry('before'));

    await sink.close();

    expect(sink.isClosed, isTrue);
    expect(() => sink.add(_entry('after')), throwsStateError);
    expect(sink.written, ['before']);
  });

  test('closed from the moment close is called: entries during closing are rejected', () {
    final sink = _Sink();
    unawaited(sink.close());

    expect(sink.isClosed, isTrue);
    expect(() => sink.add(_entry('during close')), throwsStateError);
  });

  test('repeated close does not release resources again and returns the first result', () async {
    final sink = _Sink();
    final first = sink.close();
    final second = sink.close();
    sink.releaseGate.complete();
    await Future.wait([first, second]);

    expect(identical(first, second), isTrue);
    expect(sink.releaseCount, 1);
  });

  test('flush after close does not call onFlush and awaits the closing', () async {
    final sink = _Sink();
    final closing = sink.close();
    var isFlushed = false;
    final flushing = sink.flush().then((_) => isFlushed = true);
    await pumpEventQueue();
    expect(isFlushed, isFalse, reason: 'closing still in progress');

    sink.releaseGate.complete();
    await Future.wait([closing, flushing]);

    expect(isFlushed, isTrue);
    expect(sink.flushCount, 0);
  });

  test('release failure is returned from close and from repeated close', () async {
    final sink = _FailingSink();

    await expectLater(sink.close(), throwsStateError);
    await expectLater(sink.close(), throwsStateError);
  });

  group('endBatch', () {
    test('calls onBatchEnd; does nothing after close', () async {
      final sink = _BatchSink();

      sink.endBatch();
      await sink.close();
      sink.endBatch();

      expect(sink.events, ['end']);
    });

    test('wrappers pass batch end to inner', () {
      final inner = _BatchSink();

      RepeatCollapsingSink(FilteringSink.minLevel(inner, LogLevel.info)).endBatch();

      expect(inner.events, ['end']);
    });

    test('root reports batch end after the entries of each dispatch, empty dispatch has none', () async {
      final sink = _BatchSink();
      final logger = RootLogger(sinks: [sink])..finishStartup();
      addTearDown(logger.close);

      logger
        ..log('a')
        ..log('b');
      await Future<void>.delayed(Duration.zero);
      logger.log('fatal', level: LogLevel.fatal);
      await logger.flush();

      expect(sink.events, ['a', 'b', 'end', 'fatal', 'end'], reason: 'flush with nothing pending gives no batch end');
    });

    test('startup replay into a new sink is its own batch', () {
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous);
      addTearDown(logger.close);
      logger.log('early');

      final sink = _BatchSink();
      logger.addSink(sink);

      expect(sink.events, ['early', 'end']);
    });

    test('one sink failing on batch end goes to diagnostics, the others receive it', () {
      final diagnostics = <LogDiagnostic>[];
      final other = _BatchSink();
      final logger = RootLogger(
        sinks: [_BatchSink(failOnBatchEnd: true), other],
        dispatch: LogDispatchPolicy.synchronous,
        diagnostics: DiagnosticReporter(diagnostics.add),
      )..finishStartup();
      addTearDown(logger.close);

      logger.log('a');

      expect(other.events, ['a', 'end']);
      expect(diagnostics.single.message, 'RootLogger: sink failed');
    });
  });
}

/// Sink recording received entries and batch ends in order.
final class _BatchSink extends LogSink {
  _BatchSink({this.failOnBatchEnd = false});

  final bool failOnBatchEnd;
  final List<String> events = [];

  @override
  void onAdd(LogEntry entry) => events.add(entry.message);

  @override
  void onBatchEnd() {
    if (failOnBatchEnd) throw StateError('batch end failed');
    events.add('end');
  }
}

final class _FailingSink extends LogSink {
  @override
  void onAdd(LogEntry entry) {}

  @override
  Future<void> onClose() => throw StateError('release failed');
}

final class _AttachAwareSink extends LogSink {
  final List<DiagnosticReporter> attached = [];

  @override
  void onAdd(LogEntry entry) {}

  @override
  void onAttach(DiagnosticReporter diagnostics) => attached.add(diagnostics);
}
