import 'dart:async';

import 'package:log_trail/log_trail.dart';
import 'package:log_trail/testing.dart';
import 'package:test/test.dart';

/// Sink that fails on a repeat summary.
final class _SummaryFailingSink extends LogSink {
  @override
  void onAdd(LogEntry entry) {
    if (entry.message.startsWith('Error repeated')) throw StateError('summary failed');
  }
}

const userId = LogField('test.user_id', LogCodec.string);

void main() {
  late RecordingLogSink inner;
  late RootLogger logger;

  setUp(() {
    inner = RecordingLogSink();
    logger = RootLogger(sinks: [RepeatCollapsingSink(inner)])..finishStartup();
  });

  tearDown(() => logger.close());

  StackTrace thrownHere() {
    try {
      throw const FormatException('x');
    } on FormatException catch (_, stack) {
      return stack;
    }
  }

  final start = DateTime(2026, 1, 1, 12);
  const summaryOfA = 'Error repeated 1 more time(s): StateError: Bad state: a';
  const summaryOfTimeout = 'Error repeated 1 more time(s): StateError: Bad state: timeout';
  const summaryOfAttempts =
      'Error repeated 2 more time(s): StateError: Bad state: attempt 0 '
      '(also 2 other text(s): "StateError: Bad state: attempt 1", "StateError: Bad state: attempt 2")';

  test('window must be positive', () {
    expect(() => RepeatCollapsingSink(inner, window: Duration.zero), throwsA(isA<AssertionError>()));
  });

  test('the first occurrence goes to inner with live original and report; the summary has no error or stack', () async {
    final stack = thrownHere();
    final report = Object();
    final error = StateError('a');
    for (var i = 0; i < 2; i++) {
      logger.recordError(
        error,
        stack,
        report: report,
        time: start.add(Duration(seconds: i)),
      );
    }
    await logger.flush();

    expect(inner.entries.first.error?.original, same(error));
    expect(inner.entries.first.error?.report, same(report));
    expect(inner.entries.last.message, summaryOfA);
    expect(inner.entries.last.error, isNull);
    expect(inner.entries.last.stackTrace, isNull);
  });

  test('repeats of an error from one call site are passed on as a single summary', () async {
    final stack = thrownHere();
    for (var i = 0; i < 3; i++) {
      logger.recordError(StateError('attempt $i'), stack, time: start.add(Duration(seconds: i)));
    }
    await logger.flush();

    expect(inner.messages, ['Bad state: attempt 0', summaryOfAttempts]);
    final summary = inner.entries.last;
    expect(summary.time, start.add(const Duration(seconds: 2)), reason: 'time of the last repeat');
    expect(summary.level, LogLevel.error);
    expect(summary.error, isNull, reason: 'the summary itself is not subject to collapsing');
  });

  group('repeat texts in the summary', () {
    test('identical texts are not listed; distinct texts are listed once, in order of appearance', () async {
      final stack = thrownHere();
      logger
        ..recordError(StateError('timeout'), stack)
        ..recordError(StateError('401'), stack)
        ..recordError(StateError('timeout'), stack)
        ..recordError(StateError('parse'), stack)
        ..recordError(StateError('401'), stack);
      await logger.flush();

      const summary =
          'Error repeated 4 more time(s): StateError: Bad state: timeout '
          '(also 2 other text(s): "StateError: Bad state: 401", "StateError: Bad state: parse")';
      expect(inner.messages, ['Bad state: timeout', summary]);
    });

    test('beyond maxOtherTextsInSummary an ellipsis is appended', () async {
      final stack = thrownHere();
      for (var i = 0; i <= RepeatCollapsingSink.maxOtherTextsInSummary + 1; i++) {
        logger.recordError(StateError('e$i'), stack);
      }
      await logger.flush();

      final summary = inner.messages.last;
      expect(summary, startsWith('Error repeated 6 more time(s): StateError: Bad state: e0 (also 5 other text(s): '));
      expect(summary, contains('"StateError: Bad state: e5", …)'));
      expect(summary, isNot(contains('e6')));
    });

    test('after a summary, text tracking starts over', () async {
      final stack = thrownHere();
      logger
        ..recordError(StateError('a'), stack, time: start)
        ..recordError(StateError('b'), stack, time: start.add(const Duration(seconds: 1)));
      await logger.flush();
      logger.recordError(StateError('a'), stack, time: start.add(const Duration(seconds: 2)));
      await logger.flush();

      expect(inner.messages, [
        'Bad state: a',
        'Error repeated 1 more time(s): StateError: Bad state: a (also 1 other text(s): "StateError: Bad state: b")',
        summaryOfA,
      ]);
    });

    test('for entries without an error the messages are listed', () async {
      final inner = RecordingLogSink();
      final logger = RootLogger(sinks: [RepeatCollapsingSink(inner, isCollapsible: (_) => true)])..finishStartup();
      addTearDown(logger.close);

      // One explicit call site: without a stack a warning takes the call's location, and these calls are on
      // different lines.
      const location = 'Api.fetch (package:app/api.dart:1:1)';
      logger
        ..log('Slow: 900 ms', level: LogLevel.warning, location: location)
        ..log('Slow: 1200 ms', level: LogLevel.warning, location: location);
      await logger.flush();

      expect(
        inner.messages.last,
        'Entry repeated 1 more time(s): Slow: 900 ms (also 1 other text(s): "Slow: 1200 ms")',
      );
    });
  });

  group('seriesKey', () {
    test('by default, errors of one type from one call site with different texts form one series', () async {
      final stack = thrownHere();
      logger
        ..recordError(StateError('timeout'), stack)
        ..recordError(StateError('401'), stack);
      await logger.flush();

      expect(inner.messages, hasLength(2));
      expect(inner.messages.first, 'Bad state: timeout');
      expect(inner.messages.last, startsWith('Error repeated 1 more time(s)'));
    });

    test('a custom key extends defaultSeriesKey: different texts go into different series', () async {
      final inner = RecordingLogSink();
      final logger = RootLogger(
        sinks: [
          RepeatCollapsingSink(
            inner,
            seriesKey: (entry) => '${RepeatCollapsingSink.defaultSeriesKey(entry)} ${entry.error?.message}',
          ),
        ],
      )..finishStartup();
      addTearDown(logger.close);
      final stack = thrownHere();

      logger
        ..recordError(StateError('timeout'), stack)
        ..recordError(StateError('401'), stack)
        ..recordError(StateError('timeout'), stack);
      await logger.flush();

      expect(inner.messages, ['Bad state: timeout', 'Bad state: 401', summaryOfTimeout]);
    });

    test('defaultSeriesKey distinguishes type and call site, but not text', () {
      final stack = thrownHere();
      LogEntry entry(Object error, {StackTrace? stackTrace}) => LogEntry(
        time: start,
        level: LogLevel.error,
        message: 'm',
        location: stackTrace == null ? null : 'Api.fetch (package:app/api.dart:1:1)',
        stackTrace: stackTrace,
        error: LogError.capture(error),
      );

      final byType = RepeatCollapsingSink.defaultSeriesKey(entry(StateError('a'), stackTrace: stack));
      expect(byType, RepeatCollapsingSink.defaultSeriesKey(entry(StateError('b'), stackTrace: stack)));
      expect(byType, isNot(RepeatCollapsingSink.defaultSeriesKey(entry(ArgumentError('a'), stackTrace: stack))));
      expect(
        RepeatCollapsingSink.defaultSeriesKey(entry(StateError('a'))),
        isNot(RepeatCollapsingSink.defaultSeriesKey(entry(StateError('b')))),
        reason: 'without a call site and stack, the text distinguishes',
      );
    });
  });

  test('errors alternating in a loop each collapse into their own series', () async {
    final stackA = thrownHere();
    final stackB = StackTrace.current;
    for (var i = 0; i < 3; i++) {
      logger
        ..recordError(StateError('a'), stackA)
        ..recordError(StateError('b'), stackB);
    }
    await logger.flush();

    expect(inner.messages, [
      'Bad state: a',
      'Bad state: b',
      'Error repeated 2 more time(s): StateError: Bad state: a',
      'Error repeated 2 more time(s): StateError: Bad state: b',
    ]);
  });

  test('the stack for the series key is parsed during root dispatch, not in the logger call', () async {
    var isParsed = false;
    final inner = RecordingLogSink();
    final logger = RootLogger(
      sinks: [RepeatCollapsingSink(inner)],
      // Called only when the stack is parsed for LogEntry.location.
      isWrapperFrame: (_, _) {
        isParsed = true;
        return false;
      },
    )..finishStartup();
    addTearDown(logger.close);
    final stack = thrownHere();

    logger
      ..recordError(StateError('a'), stack)
      ..recordError(StateError('a'), stack)
      ..recordError(ArgumentError('boom'), stack);
    expect(isParsed, isFalse, reason: 'the call returned, the stack was not parsed');
    expect(inner.entries, isEmpty);

    await Future<void>.delayed(Duration.zero);
    expect(isParsed, isTrue);
    expect(inner.messages, ['Bad state: a', 'Invalid argument(s): boom']);
  });

  test('the root dispatches a fatal entry in the call, with what accumulated: the sink collapses it too', () {
    final stack = thrownHere();
    logger
      ..recordError(StateError('a'), stack)
      ..recordError(StateError('a'), stack)
      // A different error type: otherwise, with the same stack, this would be a repeat of series "a".
      ..fatal('giving up', error: ArgumentError('fatal'), stackTrace: stack);

    expect(inner.messages, ['Bad state: a', 'giving up'], reason: 'no event-loop wait, the repeat is suppressed');
  });

  test('the sink is synchronous: under LogDispatchPolicy.synchronous all processing is in the logger call', () {
    final inner = RecordingLogSink();
    final logger = RootLogger(sinks: [RepeatCollapsingSink(inner)], dispatch: LogDispatchPolicy.synchronous)
      ..finishStartup();
    addTearDown(logger.close);

    logger.log('now');

    expect(inner.messages, ['now']);
  });

  test(
    'an inner failure goes to root diagnostics, other entries and sinks are unaffected, nothing reaches the zone',
    () async {
      final diagnostics = <LogDiagnostic>[];
      final other = RecordingLogSink();
      final logger = RootLogger(
        sinks: [RepeatCollapsingSink(_SummaryFailingSink()), other],
        diagnostics: DiagnosticReporter(diagnostics.add),
      )..finishStartup();
      addTearDown(logger.close);
      final stack = thrownHere();
      final unhandled = <Object>[];

      await runZonedGuarded(() async {
        logger
          ..recordError(StateError('a'), stack, time: start)
          ..recordError(StateError('a'), stack, time: start.add(const Duration(seconds: 1)))
          // A repeat outside the window ends the series with a summary, on which inner fails.
          ..recordError(StateError('a'), stack, time: start.add(const Duration(hours: 1)))
          ..recordError(StateError('b'), StackTrace.current, time: start.add(const Duration(hours: 1)));
        await pumpEventQueue();
      }, (error, _) => unhandled.add(error));

      expect(unhandled, isEmpty);
      expect(other.entries, hasLength(4));
      final diagnostic = diagnostics.single;
      expect(diagnostic.message, 'RootLogger: sink failed');
      expect(diagnostic.error, isA<StateError>());
      expect(diagnostic.stackTrace, isNotNull);
    },
  );

  test('beyond maxTrackedSeries the oldest series ends with a summary', () async {
    final inner = RecordingLogSink();
    final logger = RootLogger(sinks: [RepeatCollapsingSink(inner, maxTrackedSeries: 1)])..finishStartup();
    addTearDown(logger.close);
    final stack = thrownHere();

    logger
      ..recordError(StateError('a'), stack)
      ..recordError(StateError('a'), stack)
      ..recordError(StateError('b'), StackTrace.current);
    await pumpEventQueue();

    expect(inner.messages, ['Bad state: a', summaryOfA, 'Bad state: b']);
  });

  test('the summary is written by the window timer even if nothing else happens', () async {
    final inner = RecordingLogSink();
    final logger = RootLogger(
      sinks: [RepeatCollapsingSink(inner, window: const Duration(milliseconds: 20))],
    )..finishStartup();
    addTearDown(logger.close);
    final stack = thrownHere();

    logger
      ..recordError(StateError('a'), stack)
      ..recordError(StateError('a'), stack);
    await pumpEventQueue();
    expect(inner.messages, ['Bad state: a']);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(inner.messages, ['Bad state: a', summaryOfA]);
    expect(inner.flushCount, 0, reason: 'no flush');
  });

  test('an inner failure while writing a timer-driven summary goes to diagnostics, not to the zone', () async {
    final diagnostics = <LogDiagnostic>[];
    final sink = RepeatCollapsingSink(
      _SummaryFailingSink(),
      window: const Duration(milliseconds: 20),
    )..attach(DiagnosticReporter(diagnostics.add));
    final entry = LogEntry(
      time: DateTime.now(),
      level: LogLevel.error,
      message: 'a',
      error: LogError.capture(StateError('a')),
    );
    final unhandled = <Object>[];

    await runZonedGuarded(() async {
      sink
        ..add(entry)
        ..add(entry);
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }, (error, _) => unhandled.add(error));

    expect(unhandled, isEmpty);
    expect(diagnostics.single.message, 'RepeatCollapsingSink: summary delivery failed');
  });

  test('after close the series timer does not fire', () async {
    final inner = RecordingLogSink();
    final logger = RootLogger(
      sinks: [RepeatCollapsingSink(inner, window: const Duration(milliseconds: 20))],
    )..finishStartup();
    final stack = thrownHere();

    logger
      ..recordError(StateError('a'), stack)
      ..recordError(StateError('a'), stack);
    await logger.close();
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(inner.messages, ['Bad state: a', summaryOfA]);
  });

  test('isCollapsible: identical entries without an error collapse when opted in', () async {
    final inner = RecordingLogSink();
    final logger = RootLogger(sinks: [RepeatCollapsingSink(inner, isCollapsible: (_) => true)])..finishStartup();
    addTearDown(logger.close);

    logger
      ..log('Retrying connection')
      ..log('Retrying connection')
      ..log('Retrying connection');
    await logger.flush();

    expect(inner.messages, ['Retrying connection', 'Entry repeated 2 more time(s): Retrying connection']);
  });

  test('without repeats no summary is passed on', () async {
    logger.recordError(StateError('once'), thrownHere());
    await logger.flush();

    expect(inner.messages, ['Bad state: once']);
  });

  group('stack without symbols (--split-debug-info): the call site is unknown', () {
    StackTrace nonSymbolic(String frame) => StackTrace.fromString(
      '*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***\n'
      'pid: 1234, tid: 5678, name 1.ui\n'
      "build_id: '0123456789abcdef'\n"
      'isolate_dso_base: 7a6c000000, vm_dso_base: 7a6c000000\n'
      '#00 abs 0000007a6c3f2a0b virt 00000000001c2a0b _kDartIsolateSnapshotInstructions+$frame\n'
      '#01 abs 0000007a6c3f1000 virt 00000000001c1000 _kDartIsolateSnapshotInstructions+0x1a1000',
    );

    test('repeats with the same stack collapse although the error text changes', () async {
      final stack = nonSymbolic('0x1a2a0b');
      for (var i = 0; i < 3; i++) {
        logger.recordError(StateError('attempt $i'), stack);
      }
      await logger.flush();

      expect(inner.entries.first.location, isNull);
      expect(inner.messages, ['Bad state: attempt 0', summaryOfAttempts]);
    });

    test('errors with different stacks go into different series', () async {
      logger
        ..recordError(StateError('a'), nonSymbolic('0x1a2a0b'))
        ..recordError(StateError('a'), nonSymbolic('0x1b3b1c'));
      await logger.flush();

      expect(inner.messages, ['Bad state: a', 'Bad state: a']);
    });
  });

  test('an error from another call site is passed on', () async {
    logger
      ..recordError(StateError('a'), thrownHere())
      ..recordError(StateError('b'), StackTrace.current);
    await logger.flush();

    expect(inner.entries, hasLength(2));
  });

  test('entries without an error are passed on and do not interrupt the series', () async {
    final stack = thrownHere();
    logger
      ..recordError(StateError('a'), stack, time: start)
      ..log('between', time: start.add(const Duration(seconds: 1)))
      ..recordError(StateError('a'), stack, time: start.add(const Duration(seconds: 2)))
      ..log('between', time: start.add(const Duration(seconds: 3)));
    await logger.flush();

    expect(inner.messages, ['Bad state: a', 'between', 'between', summaryOfA]);
  });

  test('identical entries without an error do not collapse', () async {
    logger
      ..log('same')
      ..log('same');
    await logger.flush();

    expect(inner.entries, hasLength(2));
  });

  group('window', () {
    const window = Duration(seconds: 30);
    late RecordingLogSink inner;
    late RootLogger logger;

    setUp(() {
      inner = RecordingLogSink();
      logger = RootLogger(sinks: [RepeatCollapsingSink(inner, window: window)])..finishStartup();
    });

    tearDown(() => logger.close());

    test('a repeat outside the window starts a new series', () async {
      final stack = thrownHere();
      logger
        ..recordError(StateError('a'), stack, time: start)
        ..recordError(StateError('a'), stack, time: start.add(const Duration(seconds: 29)))
        // Exactly one window after the first occurrence: already a new series.
        ..recordError(StateError('a'), stack, time: start.add(window))
        ..recordError(StateError('a'), stack, time: start.add(window + const Duration(seconds: 15)));
      await logger.flush();

      expect(inner.messages, ['Bad state: a', summaryOfA, 'Bad state: a', summaryOfA]);
      expect(inner.entries[1].time, start.add(const Duration(seconds: 29)));
      expect(inner.entries[3].time, start.add(window + const Duration(seconds: 15)));
    });

    test('an entry earlier than the first occurrence of the series does not count as its repeat', () async {
      final stack = thrownHere();
      logger
        ..recordError(StateError('a'), stack, time: start)
        ..recordError(StateError('a'), stack, time: start.add(const Duration(seconds: 1)))
        // A startup entry replayed later: earlier in time than the first.
        ..recordError(StateError('a'), stack, time: start.subtract(const Duration(seconds: 5)));
      await logger.flush();

      expect(inner.messages, ['Bad state: a', summaryOfA, 'Bad state: a']);
      expect(inner.entries[1].time, start.add(const Duration(seconds: 1)), reason: 'summary not before the first');
      expect(inner.entries[2].time, start.subtract(const Duration(seconds: 5)), reason: 'passed on as is');
    });

    test('counts from the first occurrence, not from the last repeat', () async {
      final stack = thrownHere();
      // Repeats every 10 seconds: the series is not extended forever.
      for (var i = 0; i < 6; i++) {
        logger.recordError(StateError('a'), stack, time: start.add(Duration(seconds: 10 * i)));
      }
      await logger.flush();

      expect(inner.messages, [
        'Bad state: a',
        'Error repeated 2 more time(s): StateError: Bad state: a',
        'Bad state: a',
        'Error repeated 2 more time(s): StateError: Bad state: a',
      ]);
    });
  });

  test('flush passes on the summary and waits for inner; the series continues', () async {
    final stack = thrownHere();
    logger
      ..recordError(StateError('a'), stack, time: start)
      ..recordError(StateError('a'), stack, time: start.add(const Duration(seconds: 1)));
    await logger.flush();
    expect(inner.flushCount, 1);
    expect(inner.messages, ['Bad state: a', summaryOfA]);

    logger.recordError(StateError('a'), stack, time: start.add(const Duration(seconds: 2)));
    await logger.flush();
    expect(
      inner.messages,
      ['Bad state: a', summaryOfA, summaryOfA],
      reason: 'a repeat after flush within the window is suppressed again, with a new summary',
    );
    expect(inner.isClosed, isFalse);
  });

  test('flush without new repeats does not pass on the summary again', () async {
    logger.recordError(StateError('a'), thrownHere());
    await logger.flush();
    await logger.flush();

    expect(inner.entries, hasLength(1));
  });

  test('the summary carries the tags, call site and attributes of the last repeat', () async {
    final stack = thrownHere();
    logger
      ..recordError(StateError('a'), stack, tags: {'net'}, attributes: [userId('1')])
      ..recordError(StateError('a'), stack, tags: {'net', 'retry'}, attributes: [userId('2')]);
    await logger.flush();

    final summary = inner.entries.last;
    expect(summary.tags, {'net', 'retry'});
    expect(summary.location, inner.entries.first.location);
    expect(summary.location, isNotEmpty);
    expect(summary.attributes.get(userId), '2');
  });

  test('close passes on the summary and closes inner', () async {
    final stack = thrownHere();
    final inner = RecordingLogSink();
    final logger = RootLogger(sinks: [RepeatCollapsingSink(inner)])..finishStartup();

    logger
      ..recordError(StateError('a'), stack)
      ..recordError(StateError('a'), stack);
    await logger.close();

    expect(inner.messages, ['Bad state: a', summaryOfA]);
    expect(inner.isClosed, isTrue);
  });

  test('startup events collapse by their own time when replayed', () async {
    final stack = thrownHere();
    final inner = RecordingLogSink();
    final logger = RootLogger();
    addTearDown(logger.close);

    logger
      ..recordError(StateError('a'), stack, time: start)
      ..recordError(StateError('a'), stack, time: start.add(const Duration(seconds: 1)))
      ..recordError(StateError('a'), stack, time: start.add(const Duration(hours: 1)))
      ..addSink(RepeatCollapsingSink(inner))
      ..finishStartup();
    await logger.flush();

    expect(inner.messages, ['Bad state: a', summaryOfA, 'Bad state: a']);
  });
}
