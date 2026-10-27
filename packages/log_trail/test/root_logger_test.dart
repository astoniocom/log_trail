import 'dart:async';

import 'package:collection/collection.dart';
import 'package:log_trail/log_trail.dart';
import 'package:log_trail/testing.dart';
import 'package:test/test.dart';

const _userId = LogField('test.user_id', LogCodec.string);

/// Sink that records received entries and a short description of each.
/// [RecordingLogSink] that also renders each entry as one `events` line.
final class _RecordingSink extends RecordingLogSink {
  final List<String> events = [];

  @override
  void onAdd(LogEntry entry) {
    super.onAdd(entry);
    final kind = entry.error == null ? 'log' : 'err';
    events.add('$kind:${entry.message}@${entry.time.millisecondsSinceEpoch}:${entry.location}');
  }
}

/// Sink that fails on every entry, on flush and on close.
final class _FailingSink extends LogSink {
  @override
  void onAdd(LogEntry entry) => throw StateError('add failed');

  @override
  Future<void> onFlush() async => throw StateError('flush failed');

  @override
  Future<void> onClose() async => throw StateError('close failed');
}

/// Sink whose [flush] completes when [gate] completes.
final class _FlushingSink extends LogSink {
  final gate = Completer<void>();
  bool isFlushed = false;

  @override
  void onAdd(LogEntry entry) {}

  @override
  Future<void> onFlush() async {
    await gate.future;
    isFlushed = true;
  }
}

/// Sink that counts [flush] and [close] calls; [close] completes when [closeGate] completes.
final class _CountingSink extends LogSink {
  final closeGate = Completer<void>();
  int flushCount = 0;
  int closeCount = 0;

  @override
  void onAdd(LogEntry entry) {}

  @override
  Future<void> onFlush() async => flushCount++;

  @override
  Future<void> onClose() async {
    closeCount++;
    await closeGate.future;
  }
}

/// Sink that runs [onLog] for every entry.
final class _CallbackSink extends LogSink {
  _CallbackSink(this.onLog);

  final void Function() onLog;

  @override
  void onAdd(LogEntry entry) => onLog();
}

void main() {
  group('RootLogger', () {
    test('dispatches events to every attached sink', () {
      final first = _RecordingSink();
      final second = _RecordingSink();
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [first, second])..finishStartup();

      logger.log('hello');

      expect(first.events.single, startsWith('log:hello@'));
      expect(second.events.single, startsWith('log:hello@'));
    });

    test('replays startup events with their original time', () {
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous);
      logger.log('early');
      logger.recordError('early error', StackTrace.current);

      final sink = _RecordingSink();
      logger.addSink(sink);

      expect(sink.events, hasLength(2));
      expect(sink.events[0], startsWith('log:early@'));
      expect(sink.events[1], startsWith('err:early error@'));
    });

    test('keeps the original time rather than the sink attach time', () {
      final eventTime = DateTime(2020, 5, 17, 12, 30);
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous);
      logger.log('with explicit time', time: eventTime);

      final sink = _RecordingSink();
      logger.addSink(sink);

      expect(sink.events.single, startsWith('log:with explicit time@${eventTime.millisecondsSinceEpoch}:'));
    });

    test('info without a stack trace and location: the call site is not resolved', () {
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous)..finishStartup();
      final sink = _RecordingSink();
      logger.addSink(sink);

      logger.log('plain');

      expect(sink.events.single, endsWith(':null'), reason: 'no point capturing a stack for every info entry');
      expect(sink.events.single, isNot(contains('root_logger_test.dart')));
    });

    test('resolves location at the call site for warnings and entries with a stack trace', () {
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous)..finishStartup();
      final sink = _RecordingSink();
      logger.addSink(sink);

      logger.log('located', level: LogLevel.warning);

      expect(sink.entries.single.location, contains('root_logger_test.dart'));
    });

    test('does not overwrite a given location', () {
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous)..finishStartup();
      final sink = _RecordingSink();
      logger.addSink(sink);

      logger.log('located', location: 'custom');

      expect(sink.entries.single.location, 'custom');
    });

    test('can attach a sink without replaying the buffer', () {
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous);
      logger.log('early');

      final sink = _RecordingSink();
      logger.addSink(sink, replayStartupBuffer: false);
      expect(sink.events, isEmpty);

      logger.log('live');
      expect(sink.events.single, startsWith('log:live@'));
    });

    test('finishStartup stops buffering and clears the buffer', () {
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous);
      logger.log('early');
      logger.finishStartup();
      logger.log('after startup');

      final sink = _RecordingSink();
      logger.addSink(sink);

      expect(sink.events, isEmpty);
    });

    test('on buffer overflow the oldest events are dropped and the loss is reported', () {
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, startupBufferLimit: 2);
      logger.log('a', time: DateTime(2026, 1, 1, 12));
      logger.log('b', time: DateTime(2026, 1, 1, 12, 1));
      logger.log('c', time: DateTime(2026, 1, 1, 12, 2));

      final sink = _RecordingSink();
      logger.addSink(sink);

      expect(sink.entries.map((e) => e.message), [
        'Startup log buffer overflow: 1 earlier event(s) dropped',
        'b',
        'c',
      ]);
    });

    test('the overflow message keeps events ordered by time', () {
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, startupBufferLimit: 1);
      logger.log('a', time: DateTime(2026, 1, 1, 12));
      logger.log('b', time: DateTime(2026, 1, 1, 12, 1));

      final sink = _RecordingSink();
      logger.addSink(sink);

      expect(sink.entries.first.time, DateTime(2026, 1, 1, 12), reason: 'time of the last dropped event');
      expect(sink.entries.map((e) => e.time).isSorted((a, b) => a.compareTo(b)), isTrue);
    });

    test('without finishStartup, buffering stops after startupBufferTimeout with a diagnostic', () async {
      final diagnostics = <LogDiagnostic>[];
      final logger = RootLogger(
        dispatch: LogDispatchPolicy.synchronous,
        startupBufferTimeout: const Duration(milliseconds: 20),
        diagnostics: DiagnosticReporter(diagnostics.add),
      );
      logger.log('early');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(
        diagnostics.single.message,
        contains('startup buffering stopped after 0:00:00.020000'),
        reason: 'by timer, without any logger calls',
      );
      logger.log('after timeout');

      final sink = _RecordingSink();
      logger.addSink(sink);

      expect(sink.entries, isEmpty, reason: 'startup events are not replayed after a long time');
      expect(diagnostics, hasLength(1));
    });

    test('finishStartup and close cancel the timer: no timeout message', () async {
      final diagnostics = <LogDiagnostic>[];
      RootLogger(
          dispatch: LogDispatchPolicy.synchronous,
          startupBufferTimeout: const Duration(milliseconds: 20),
          diagnostics: DiagnosticReporter(diagnostics.add),
        )
        ..log('early')
        ..finishStartup();
      final closed = RootLogger(
        dispatch: LogDispatchPolicy.synchronous,
        startupBufferTimeout: const Duration(milliseconds: 20),
        diagnostics: DiagnosticReporter(diagnostics.add),
      )..log('early');
      await closed.close();

      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(diagnostics, isEmpty);
    });

    test('the startupBufferTimeout timer starts with the first entry, not with logger creation', () async {
      final diagnostics = <LogDiagnostic>[];
      final logger = RootLogger(
        dispatch: LogDispatchPolicy.synchronous,
        startupBufferTimeout: const Duration(milliseconds: 20),
        diagnostics: DiagnosticReporter(diagnostics.add),
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(diagnostics, isEmpty, reason: 'no entries, no timer');

      logger.log('first early');
      final sink = _RecordingSink();
      logger.addSink(sink);
      expect(sink.entries.single.message, 'first early', reason: 'buffering is still on');

      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(diagnostics, hasLength(1), reason: 'the timeout counts from the first entry');
    });

    test('startupBufferTimeout: null buffers only until finishStartup', () async {
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, startupBufferTimeout: null);
      logger.log('early');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final sink = _RecordingSink();
      logger.addSink(sink);

      expect(sink.entries.single.message, 'early');
    });

    test('one sink failing does not affect the others and goes to diagnostics', () {
      final good = _RecordingSink();
      final diagnostics = <LogDiagnostic>[];
      final logger = RootLogger(
        dispatch: LogDispatchPolicy.synchronous,
        sinks: [_FailingSink(), good],
        diagnostics: DiagnosticReporter(diagnostics.add),
      )..finishStartup();

      logger.log('message');
      logger.recordError('error', StackTrace.current);

      expect(good.events, hasLength(2));
      expect(diagnostics, hasLength(2));
      expect(diagnostics.first.message, 'RootLogger: sink failed');
      expect(diagnostics.first.error, isA<StateError>().having((e) => e.message, 'message', 'add failed'));
      expect(diagnostics.first.stackTrace, isNotNull);
    });

    test('a failure of the diagnostic handler itself does not reach the caller', () {
      final good = _RecordingSink();
      final logger = RootLogger(
        dispatch: LogDispatchPolicy.synchronous,
        sinks: [_FailingSink(), good],
        diagnostics: DiagnosticReporter((_) => throw StateError('diagnostics broke')),
      )..finishStartup();

      final printed = <String>[];
      runZoned(
        () => logger.log('message'),
        zoneSpecification: ZoneSpecification(print: (_, _, _, line) => printed.add(line)),
      );

      expect(good.events, hasLength(1));
      expect(printed, hasLength(2), reason: 'handler failure and original message are printed as a last resort');
      expect(printed.first, startsWith('DiagnosticHandler failed: Bad state: diagnostics broke'));
      expect(printed.last, startsWith('RootLogger: sink failed: Bad state: add failed'));
    });

    test('a sink failing during replay does not affect the others', () {
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous);
      logger.log('early');

      logger.addSink(_FailingSink());
      final good = _RecordingSink();
      logger.addSink(good);

      expect(good.events, hasLength(1));
    });

    test('removeSink detaches the sink', () {
      final sink = _RecordingSink();
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink])..finishStartup();

      logger.removeSink(sink);
      logger.log('after removal');

      expect(sink.events, isEmpty);
    });

    test('attaching the same sink again does not duplicate events', () {
      final sink = _RecordingSink();
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink, sink])..finishStartup();

      logger
        ..addSink(sink)
        ..log('message');

      expect(sink.events, hasLength(1));
    });

    test('a sink attaches and detaches others during dispatch: dispatch runs to completion', () {
      final first = _RecordingSink();
      final late = _RecordingSink();
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [first])..finishStartup();
      logger.addSink(
        _CallbackSink(
          () => logger
            ..addSink(late)
            ..removeSink(first),
        ),
      );

      logger.log('one');
      expect(first.events, hasLength(1), reason: 'the dispatch list is snapshotted before dispatch');
      expect(late.events, isEmpty);

      logger.log('two');
      expect(late.events, hasLength(1));
      expect(first.events, hasLength(1));
    });

    test('a sink only attaches another during dispatch: logging does not fail', () {
      final late = _RecordingSink();
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous)..finishStartup();
      var isAdded = false;
      logger.addSink(
        _CallbackSink(() {
          if (!isAdded) {
            isAdded = true;
            logger.addSink(late);
          }
        }),
      );

      expect(() => logger.log('one'), returnsNormally);
      expect(late.events, isEmpty, reason: 'the dispatch list is snapshotted before dispatch');

      logger.log('two');
      expect(late.events, hasLength(1));
    });

    test('a sink only detaches itself during dispatch: the others receive the entry', () {
      final after = _RecordingSink();
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous)..finishStartup();
      late final LogSink selfRemoving;
      selfRemoving = _CallbackSink(() => logger.removeSink(selfRemoving));
      logger
        ..addSink(selfRemoving)
        ..addSink(after);

      expect(() => logger.log('one'), returnsNormally);
      expect(after.events, hasLength(1));
    });

    test('a sink logs through the facade during buffer replay', () {
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous);
      logger.log('early');
      var calls = 0;
      logger.addSink(
        _CallbackSink(() {
          if (calls++ == 0) logger.log('from replay');
        }),
      );

      expect(calls, greaterThanOrEqualTo(2), reason: 'both the replay and the new entry arrived');
    });

    test('extra attributes reach the sink with their original type', () {
      final sink = _RecordingSink();
      RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink])
        ..finishStartup()
        ..log('signed in', attributes: [_userId('42')]);

      final String? userId = sink.entries.single.attributes.get(_userId);
      expect(userId, '42');
    });

    test('recordError: the error keeps its type and original object; without a stack the call stack is taken', () {
      final sink = _RecordingSink();
      final error = StateError('boom');
      RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink])
        ..finishStartup()
        ..recordError(error, null);

      final entry = sink.entries.single;
      expect(entry.level, LogLevel.error);
      expect(entry.error, const LogError(type: 'StateError', message: 'Bad state: boom'));
      expect(entry.error?.original, same(error));
      expect(entry.stackTrace.toString(), contains('root_logger_test.dart'));
      expect(entry.location, contains('root_logger_test.dart'));
    });

    test('recordError: explanatory message and level, the error is stored separately', () {
      final sink = _RecordingSink();
      RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink])
        ..finishStartup()
        ..recordError(
          StateError('token expired'),
          StackTrace.current,
          message: 'Failed to load profile',
          level: LogLevel.fatal,
        );

      final entry = sink.entries.single;
      expect(entry.message, 'Failed to load profile');
      expect(entry.level, LogLevel.fatal);
      expect(entry.error, const LogError(type: 'StateError', message: 'Bad state: token expired'));
    });

    test('recordError: report ends up in LogError.report', () {
      final sink = _RecordingSink();
      final report = Object();
      RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink])
        ..finishStartup()
        ..recordError(StateError('boom'), null, report: report);

      expect(sink.entries.single.error?.report, same(report));
    });

    test('recordError at warning level without a stack keeps the call stack', () {
      final sink = _RecordingSink();
      RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink])
        ..finishStartup()
        ..recordError(StateError('handled'), null, level: LogLevel.warning);

      expect(sink.entries.single.stackTrace.toString(), contains('root_logger_test.dart'));
    });

    test('recordError works as a runZonedGuarded handler', () async {
      final sink = _RecordingSink();
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink])..finishStartup();

      runZonedGuarded(() => unawaited(Future<void>.error(StateError('unhandled'))), logger.recordError);
      await pumpEventQueue();

      expect(sink.entries.single.error?.type, 'StateError');
    });

    test('the stack is kept for errors and when given explicitly, but not captured for warnings', () {
      final sink = _RecordingSink();
      RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink])
        ..finishStartup()
        ..log('warning', level: LogLevel.warning)
        ..log('error', level: LogLevel.error)
        ..log('info with stack', stackTrace: StackTrace.current);

      expect(sink.entries.map((e) => e.stackTrace != null), [false, true, true]);
    });

    test('a root attaches to another root as a sink via asSink', () {
      final sink = _RecordingSink();
      final inner = RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink])..finishStartup();
      RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [inner.asSink()])
        ..finishStartup()
        ..log('nested', attributes: [_userId('7')]);

      expect(sink.entries.single.attributes.get(_userId), '7');
    });

    test('asSink accepts ready-made entries like any sink', () {
      final sink = _RecordingSink();
      final LogSink asSink = (RootLogger(
        dispatch: LogDispatchPolicy.synchronous,
        sinks: [sink],
      )..finishStartup()).asSink();

      asSink.add(LogEntry(time: DateTime(2026), level: LogLevel.info, message: 'via Sink'));

      expect(sink.entries.single.message, 'via Sink');
    });

    test('closing an asSink sink does not close the root; every call gives an independent sink', () async {
      final sink = _RecordingSink();
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink])..finishStartup();
      final outer = RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [logger.asSink()])..finishStartup();
      final receiverSink = logger.asSink();

      await outer.close();

      expect(logger.isClosed, isFalse);
      expect(sink.isClosed, isFalse);
      receiverSink.add(LogEntry(time: DateTime(2026), level: LogLevel.info, message: 'still accepted'));
      expect(sink.entries.single.message, 'still accepted');
    });

    test('flush of an asSink sink waits for the root sinks', () async {
      final slow = _FlushingSink();
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [slow])..finishStartup();
      final asSink = logger.asSink();

      var isFlushed = false;
      final flushing = asSink.flush().then((_) => isFlushed = true);
      await pumpEventQueue();
      expect(isFlushed, isFalse);

      slow.gate.complete();
      await flushing;
      expect(slow.isFlushed, isTrue);
    });
  });

  group('RootLogger: level threshold', () {
    test('entries below defaultMinLevel do not reach sinks and are not buffered', () {
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, defaultMinLevel: LogLevel.info)
        ..log('debug', level: LogLevel.debug)
        ..recordError(StateError('handled'), null, level: LogLevel.debug)
        ..log('info');

      final sink = _RecordingSink();
      logger.addSink(sink);

      expect(sink.entries.map((e) => e.message), ['info']);
    });

    test('defaultMinLevel changes at runtime and child loggers follow the root', () {
      final sink = _RecordingSink();
      final logger = RootLogger(
        dispatch: LogDispatchPolicy.synchronous,
        sinks: [sink],
        defaultMinLevel: LogLevel.warning,
      )..finishStartup();
      final child = logger.child(tags: {'network'});

      child.log('hidden', level: LogLevel.debug);
      expect(child.isEnabled(LogLevel.debug), isFalse);

      logger.defaultMinLevel = LogLevel.debug;
      child.log('shown', level: LogLevel.debug);

      expect(child.isEnabled(LogLevel.debug), isTrue);
      expect(sink.entries.map((e) => e.message), ['shown']);
    });

    test('ready-made entries from asSink pass the floor but not the default threshold: their source applied it', () {
      final sink = _RecordingSink();
      final logger = RootLogger(
        dispatch: LogDispatchPolicy.synchronous,
        sinks: [sink],
        defaultMinLevel: LogLevel.error,
        floor: LogLevel.info,
      )..finishStartup();
      final asSink = logger.asSink();

      asSink
        ..add(LogEntry(time: DateTime(2026), level: LogLevel.debug, message: 'below floor'))
        ..add(LogEntry(time: DateTime(2026), level: LogLevel.info, message: 'from another logger'));

      expect(sink.entries.map((e) => e.message), ['from another logger']);
    });

    test('logLazy does not compute the message for an entry below the threshold', () {
      final sink = _RecordingSink();
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink], defaultMinLevel: LogLevel.info)
        ..finishStartup();
      var calls = 0;
      String message() => 'computed ${++calls}';

      logger
        ..logLazy(message, level: LogLevel.debug)
        ..child(tags: {'module'}).logLazy(message, level: LogLevel.warning);

      expect(calls, 1);
      expect(sink.entries.single.message, 'computed 1');
      expect(sink.entries.single.level, LogLevel.warning);
      expect(sink.entries.single.location, contains('root_logger_test.dart'), reason: 'the call site is the app');
    });
  });

  group('RootLogger: context', () {
    const sessionId = LogField('test.session_id', LogCodec.string);

    test('context attributes are added to every entry and error', () {
      final sink = _RecordingSink();
      RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink])
        ..finishStartup()
        ..setContextAttribute(_userId('42'))
        ..setContextAttribute(sessionId('s1'))
        ..log('one')
        ..recordError(StateError('two'), null);

      for (final entry in sink.entries) {
        expect(entry.attributes.get(_userId), '42');
        expect(entry.attributes.get(sessionId), 's1');
      }
    });

    test('the call value takes precedence over the context', () {
      final sink = _RecordingSink();
      RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink])
        ..finishStartup()
        ..setContextAttribute(_userId('42'))
        ..log('impersonated', attributes: [_userId('7')]);

      expect(sink.entries.single.attributes.get(_userId), '7');
    });

    test('a repeated call replaces the value, removeContextAttribute removes the field', () {
      final sink = _RecordingSink();
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink])
        ..finishStartup()
        ..setContextAttribute(_userId('42'))
        ..setContextAttribute(_userId('43'))
        ..log('switched');
      logger
        ..removeContextAttribute(_userId)
        ..log('signed out');

      expect(sink.entries[0].attributes.get(_userId), '43');
      expect(sink.entries[1].attributes.contains(_userId), isFalse);
      expect(logger.contextAttributes, isEmpty);
    });

    test('startup events keep the context from the moment they were logged', () {
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous)..log('before sign in');
      logger
        ..setContextAttribute(_userId('42'))
        ..log('after sign in');

      final sink = _RecordingSink();
      logger.addSink(sink);

      expect(sink.entries[0].attributes.contains(_userId), isFalse);
      expect(sink.entries[1].attributes.get(_userId), '42');
    });

    test('ready-made entries from add do not get the context', () {
      final sink = _RecordingSink();
      RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink])
        ..finishStartup()
        ..setContextAttribute(_userId('42'))
        ..asSink().add(LogEntry(time: DateTime(2026), level: LogLevel.info, message: 'from another logger'));

      expect(sink.entries.single.attributes.isEmpty, isTrue);
    });
  });

  group('RootLogger.flush', () {
    test('waits for all sinks; one failing does not affect the others and is returned to the caller', () async {
      final slow = _FlushingSink();
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [slow, _FailingSink()]);

      final flushing = expectLater(logger.flush(), throwsStateError);
      await pumpEventQueue();
      expect(slow.isFlushed, isFalse);

      slow.gate.complete();
      await flushing;
      expect(slow.isFlushed, isTrue);
    });
  });

  group('RootLogger.close', () {
    test('closes all sinks; one failing does not prevent closing the others and is returned to the caller', () async {
      final first = _RecordingSink();
      final second = _RecordingSink();
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [first, _FailingSink(), second]);

      await expectLater(logger.close(), throwsStateError);

      expect(first.isClosed, isTrue);
      expect(second.isClosed, isTrue);
    });

    test('entries after close are dropped without an exception; diagnostics are reported once', () async {
      final sink = _RecordingSink();
      final diagnostics = <LogDiagnostic>[];
      final logger = RootLogger(
        dispatch: LogDispatchPolicy.synchronous,
        sinks: [sink],
        diagnostics: DiagnosticReporter(diagnostics.add),
      )..finishStartup();
      await logger.close();

      logger
        ..log('after close')
        ..recordError(StateError('after close'), null);

      expect(sink.entries, isEmpty);
      expect(diagnostics.map((d) => d.message), ['RootLogger: closed, further entries are dropped']);
    });

    test('a ready-made entry via asSink after root close is dropped the same way as log', () async {
      final diagnostics = <LogDiagnostic>[];
      final logger = RootLogger(
        dispatch: LogDispatchPolicy.synchronous,
        diagnostics: DiagnosticReporter(diagnostics.add),
      )..finishStartup();
      final asSink = logger.asSink();
      await logger.close();

      asSink.add(LogEntry(time: DateTime(2026), level: LogLevel.info, message: 'late'));
      logger.log('late too');

      expect(diagnostics.map((d) => d.message), ['RootLogger: closed, further entries are dropped']);
    });

    test('adding to a closed asSink sink throws StateError, like any sink', () async {
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous)..finishStartup();
      addTearDown(logger.close);
      final asSink = logger.asSink();
      await asSink.close();

      expect(
        () => asSink.add(LogEntry(time: DateTime(2026), level: LogLevel.info, message: 'late')),
        throwsStateError,
      );
    });

    test('a repeated close does not close sinks again and returns the first result', () async {
      final sink = _CountingSink();
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink]);
      expect(logger.isClosed, isFalse);

      final first = logger.close();
      expect(logger.isClosed, isTrue, reason: 'closed from the moment of the call, not of completion');
      final second = logger.close();
      sink.closeGate.complete();
      await Future.wait([first, second]);

      expect(sink.closeCount, 1);
      expect(identical(first, second), isTrue);
    });

    test('a repeated close after a failure returns the same failure without closing the others again', () async {
      final good = _CountingSink()..closeGate.complete();
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [_FailingSink(), good]);

      await expectLater(logger.close(), throwsStateError);
      await expectLater(logger.close(), throwsStateError);

      expect(good.closeCount, 1);
    });

    test('flush after close does not touch closed sinks and waits for the close', () async {
      final sink = _CountingSink();
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink]);

      final closing = logger.close();
      var isFlushed = false;
      final flushing = logger.flush().then((_) => isFlushed = true);
      await pumpEventQueue();
      expect(isFlushed, isFalse, reason: 'the close is still in progress');

      sink.closeGate.complete();
      await Future.wait([closing, flushing]);
      expect(sink.flushCount, 0);
      expect(isFlushed, isTrue);
    });

    test('addSink after close throws StateError: the sink would never be closed', () async {
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous);
      await logger.close();
      final late = _CountingSink();

      expect(() => logger.addSink(late), throwsStateError);
      expect(logger.sinks, isEmpty);
      expect(late.closeCount, 0, reason: 'the sink stays with the caller');
    });
  });
}
