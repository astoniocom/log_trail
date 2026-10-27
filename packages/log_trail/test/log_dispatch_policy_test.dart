import 'dart:async';

import 'package:log_trail/log_trail.dart';
import 'package:log_trail/testing.dart';
import 'package:test/test.dart';

const _userId = LogField('test.user_id', LogCodec.string);

/// Sink that runs [onEntry] for every entry.
final class _CallbackSink extends LogSink {
  _CallbackSink(this.onEntry);

  final void Function(LogEntry entry) onEntry;

  @override
  void onAdd(LogEntry entry) => onEntry(entry);
}

/// One event-loop turn: zero-delay timers fire.
Future<void> nextEventLoopTurn() => Future<void>.delayed(Duration.zero);

void main() {
  group('LogDispatchPolicy', () {
    test('values are equal by description, queueLimit is positive', () {
      const policy = LogDispatchPolicy();
      expect(policy.immediateLevel, LogLevel.fatal);
      expect(policy.queueLimit, 1000);
      expect(const LogDispatchPolicy(), isNot(const LogDispatchPolicy(queueLimit: 10)));
      expect(LogDispatchPolicy.synchronous.immediateLevel, LogLevel.values.first);
      expect(const LogDispatchPolicy().hashCode, const LogDispatchPolicy().hashCode);
      expect('${const LogDispatchPolicy(immediateLevel: null, queueLimit: 5)}', contains('queueLimit: 5'));
      expect(() => LogDispatchPolicy(queueLimit: 0), throwsA(isA<AssertionError>()));
    });

    test('synchronous: sink and processor see the entry before log returns', () {
      final sink = RecordingLogSink();
      var processed = 0;
      final logger = RootLogger(
        sinks: [sink],
        dispatch: LogDispatchPolicy.synchronous,
        processors: [
          LogProcessor((entry) {
            processed++;
            return entry;
          }),
        ],
      )..finishStartup();
      addTearDown(logger.close);

      logger
        ..info('info')
        ..child(minLevel: LogLevel.trace).trace('trace');

      expect(processed, 2, reason: 'immediateLevel: trace dispatches every level in the call');
      expect(sink.messages, ['info', 'trace']);
    });
  });

  group('RootLogger: default dispatch', () {
    late RecordingLogSink sink;
    late List<LogDiagnostic> diagnostics;
    late List<String> processed;
    late RootLogger logger;

    setUp(() {
      sink = RecordingLogSink();
      diagnostics = [];
      processed = [];
      logger = RootLogger(
        sinks: [sink],
        processors: [
          LogProcessor((entry) {
            processed.add(entry.message);
            return entry;
          }),
        ],
        diagnostics: DiagnosticReporter(diagnostics.add),
      )..finishStartup();
    });

    tearDown(() => logger.close());

    test('processors and sinks run in the next event-loop turn, not in the log call, in order', () async {
      logger
        ..log('a')
        ..log('b');
      expect(processed, isEmpty, reason: 'log returned, processor not called yet');
      expect(sink.entries, isEmpty);

      await Future<void>.microtask(() {});
      expect(sink.entries, isEmpty, reason: 'microtasks are still in the current frame');

      await nextEventLoopTurn();
      expect(processed, ['a', 'b']);
      expect(sink.messages, ['a', 'b']);
    });

    test('entry is built in the call: time, context and call site belong to it, not to dispatch', () async {
      final before = DateTime.now();
      logger
        ..setContextAttribute(_userId('42'))
        ..log('located', level: LogLevel.warning)
        ..setContextAttribute(_userId('other'));
      final after = DateTime.now();

      await nextEventLoopTurn();

      final entry = sink.entries.single;
      expect(entry.attributes.get(_userId), '42', reason: 'context at call time');
      expect(entry.location, contains('log_dispatch_policy_test.dart'), reason: 'stack captured in the call');
      expect(entry.time.isBefore(before) || entry.time.isAfter(after), isFalse);
    });

    test('child logger entries and ready-made entries from asSink are deferred the same way and keep order', () async {
      final child = logger.child(tags: {'child'});
      final input = logger.asSink();
      addTearDown(input.close);

      logger.log('root');
      child.log('child');
      input.add(LogEntry(time: DateTime(2026), level: LogLevel.info, message: 'ready'));
      logger.log('root again');
      expect(sink.entries, isEmpty);

      await nextEventLoopTurn();
      expect(sink.messages, ['root', 'child', 'ready', 'root again']);
      expect(sink.entries[1].tags, {'child'});
    });

    test('entries at immediateLevel and above dispatch immediately, pending ones before them', () async {
      logger
        ..log('before')
        ..log('fatal', level: LogLevel.fatal);

      expect(sink.messages, ['before', 'fatal'], reason: 'no event-loop wait, order kept');
      expect(processed, ['before', 'fatal']);

      logger.log('after');
      expect(sink.messages, ['before', 'fatal']);
      await nextEventLoopTurn();
      expect(sink.messages, ['before', 'fatal', 'after']);
    });

    test('immediateLevel: null defers all entries', () async {
      final sink = RecordingLogSink();
      final logger = RootLogger(sinks: [sink], dispatch: const LogDispatchPolicy(immediateLevel: null))
        ..finishStartup();
      addTearDown(logger.close);

      logger.log('fatal', level: LogLevel.fatal);
      expect(sink.entries, isEmpty);

      await nextEventLoopTurn();
      expect(sink.messages, ['fatal']);
    });

    test('flush dispatches pending entries immediately and awaits sinks', () async {
      logger.log('pending');

      await logger.flush();

      expect(sink.messages, ['pending']);
      expect(sink.flushCount, 1);
      expect(sink.isClosed, isFalse);
    });

    test('close dispatches pending entries and closes sinks; entries after close are dropped', () async {
      logger.log('pending');

      await logger.close();
      logger.log('late');
      await nextEventLoopTurn();

      expect(sink.messages, ['pending']);
      expect(sink.isClosed, isTrue);
      expect(diagnostics.single.message, contains('closed'));
    });

    test('processor added while entries await dispatch processes them too', () async {
      logger.log('pending');
      logger.addProcessor(LogProcessor((entry) => entry.copyWith(message: '${entry.message}!')));

      await nextEventLoopTurn();

      expect(sink.messages, ['pending!']);
    });

    test('sink attached while entries await dispatch gets them after the buffer, without repeats', () async {
      final logger = RootLogger();
      addTearDown(logger.close);
      logger.log('early');
      await nextEventLoopTurn();
      logger.log('pending');

      final late = RecordingLogSink();
      logger.addSink(late);
      expect(late.messages, ['early'], reason: 'buffer replayed; pending entry not dispatched yet');

      await nextEventLoopTurn();
      expect(late.messages, ['early', 'pending']);
    });

    test('startup buffer holds only dispatched entries: finishStartup before dispatch does not keep them', () async {
      final logger = RootLogger();
      addTearDown(logger.close);

      logger.log('buffered');
      await nextEventLoopTurn();
      logger
        ..log('not buffered')
        ..finishStartup();
      await nextEventLoopTurn();

      final late = RecordingLogSink();
      logger.addSink(late);
      expect(
        late.entries,
        isEmpty,
        reason: 'finishStartup cleared the buffer; pending entry went only to current sinks',
      );
    });

    test('a full queue is dispatched inside the call in batches of queueLimit; nothing is dropped', () async {
      final sink = RecordingLogSink();
      final diagnostics = <LogDiagnostic>[];
      final logger = RootLogger(
        sinks: [sink],
        dispatch: const LogDispatchPolicy(queueLimit: 2),
        diagnostics: DiagnosticReporter(diagnostics.add),
      )..finishStartup();
      addTearDown(logger.close);

      for (var i = 1; i <= 5; i++) {
        logger.log('e$i');
      }
      Iterable<Iterable<String>> batches() => sink.batches.map((batch) => batch.map((e) => e.message));
      expect(batches(), [
        ['e1', 'e2'],
        ['e3', 'e4'],
      ], reason: 'two full batches went out inside the logging calls, in order');

      await nextEventLoopTurn();

      expect(batches(), [
        ['e1', 'e2'],
        ['e3', 'e4'],
        ['e5'],
      ], reason: 'the remainder waits for the event loop as usual');
      expect(diagnostics, isEmpty);
    });

    test('a burst through asSink larger than queueLimit is delivered completely after flush', () async {
      final sink = RecordingLogSink();
      final diagnostics = <LogDiagnostic>[];
      final logger = RootLogger(
        sinks: [sink],
        dispatch: const LogDispatchPolicy(queueLimit: 100),
        diagnostics: DiagnosticReporter(diagnostics.add),
      )..finishStartup();
      addTearDown(logger.close);
      final target = logger.asSink();

      for (var i = 0; i < 1500; i++) {
        target.add(LogEntry(time: DateTime.utc(2026), level: LogLevel.info, message: 'm$i'));
      }
      await target.flush();

      expect(sink.entries, hasLength(1500));
      expect(sink.messages.first, 'm0');
      expect(sink.messages.last, 'm1499');
      expect(diagnostics, isEmpty);
    });

    test("ready-made entries share the queue with the root's own: order within a turn is kept", () async {
      final sink = RecordingLogSink();
      final logger = RootLogger(sinks: [sink], dispatch: const LogDispatchPolicy(queueLimit: 3))..finishStartup();
      addTearDown(logger.close);
      final target = logger.asSink();

      logger.log('own 1');
      target.add(LogEntry(time: DateTime.utc(2026), level: LogLevel.info, message: 'ready 1'));
      logger.log('own 2');
      target.add(LogEntry(time: DateTime.utc(2026), level: LogLevel.info, message: 'ready 2'));
      await nextEventLoopTurn();

      expect(sink.messages, ['own 1', 'ready 1', 'own 2', 'ready 2']);
    });

    test('sink failure on deferred dispatch goes to diagnostics, others arrive, nothing reaches the zone', () async {
      sink.failOn = (entry) => entry.message == 'bad';
      final unhandled = <Object>[];

      await runZonedGuarded(() async {
        logger
          ..log('good 1')
          ..log('bad')
          ..log('good 2');
        await nextEventLoopTurn();
      }, (error, _) => unhandled.add(error));

      expect(unhandled, isEmpty);
      expect(sink.messages, ['good 1', 'good 2']);
      expect(diagnostics.single.message, 'RootLogger: sink failed');
      expect(diagnostics.single.error, isA<StateError>());
    });

    test(
      'sink response entry dispatches in the same turn after the current one; a response to a response is cut off',
      () async {
        final seen = <String>[];
        final logger = RootLogger(
          diagnostics: DiagnosticReporter(diagnostics.add),
        )..finishStartup();
        addTearDown(logger.close);
        logger
          ..addSink(_CallbackSink((entry) => seen.add(entry.message)))
          // Responds to every entry, including its own: without protection this is infinite recursion
          // or, via the queue, an endless series of one entry per turn.
          ..addSink(_CallbackSink((entry) => logger.log('echo of ${entry.message}')))
          ..log('one')
          ..log('two');

        await nextEventLoopTurn();
        expect(seen, ['one', 'echo of one', 'two', 'echo of two']);
        expect(diagnostics.single.message, contains('dropped to break the loop'));

        await nextEventLoopTurn();
        expect(seen, hasLength(4), reason: 'nothing continued in the next turn');
      },
    );
  });
}
