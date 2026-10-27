import 'package:log_trail/log_trail.dart';
import 'package:log_trail/testing.dart';
import 'package:test/test.dart';

const _build = LogField('test.build', LogCodec.string);

/// Enrichment: adds [_build] to every entry. [overrides] puts the own attribute
/// after the entry attributes (overwriting the source value) or before them
/// (keeping it).
final class _BuildEnricher implements LogProcessor {
  const _BuildEnricher(this.build, {this.overrides = true});

  final String build;
  final bool overrides;

  @override
  LogEntry process(LogEntry entry) {
    final own = _build(build);
    final existing = [
      for (final MapEntry(:key, :value) in entry.attributes.encoded.entries) LogField(key, LogCodec.raw)(value),
    ];
    return LogEntry(
      time: entry.time,
      level: entry.level,
      message: entry.message,
      tags: entry.tags,
      location: entry.location,
      stackTrace: entry.stackTrace,
      error: entry.error,
      attributes: LogAttributes(overrides ? [...existing, own] : [own, ...existing]),
    );
  }
}

LogEntry _entry(String message, {LogLevel level = LogLevel.info}) =>
    LogEntry(time: DateTime(2026), level: level, message: message);

void main() {
  group('RootLogger.processors', () {
    test('apply in order, each gets the previous result', () {
      final seen = <String>[];
      final sink = RecordingLogSink();
      RootLogger(
          dispatch: LogDispatchPolicy.synchronous,
          sinks: [sink],
          processors: [
            LogProcessor((entry) {
              seen.add('first: ${entry.message}');
              return _entry('${entry.message}+1');
            }),
            LogProcessor((entry) {
              seen.add('second: ${entry.message}');
              return _entry('${entry.message}+2');
            }),
          ],
        )
        ..finishStartup()
        ..log('m');

      expect(seen, ['first: m', 'second: m+1']);
      expect(sink.entries.single.message, 'm+1+2');
    });

    test('null drops the entry: later processors and sinks do not see it', () {
      var reachedSecond = 0;
      final sink = RecordingLogSink();
      final logger = RootLogger(
        dispatch: LogDispatchPolicy.synchronous,
        sinks: [sink],
        processors: [
          LogProcessor((entry) => entry.level == LogLevel.debug ? null : entry),
          LogProcessor((entry) {
            reachedSecond++;
            return entry;
          }),
        ],
      )..finishStartup();

      logger
        ..debug('dropped')
        ..info('kept');

      expect(sink.entries.map((e) => e.message), ['kept']);
      expect(reachedSecond, 1);
    });

    test('dropped entry does not reach the startup buffer either', () {
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, processors: [LogProcessor((_) => null)])
        ..log('early');
      final sink = RecordingLogSink();
      logger.addSink(sink);

      expect(sink.entries, isEmpty);
    });

    test('processor failure drops the entry and reports to diagnostics without its content', () {
      final sink = RecordingLogSink();
      final diagnostics = <LogDiagnostic>[];
      RootLogger(
          dispatch: LogDispatchPolicy.synchronous,
          sinks: [sink],
          processors: [LogProcessor((_) => throw StateError('processor broke'))],
          diagnostics: DiagnosticReporter(diagnostics.add),
        )
        ..finishStartup()
        ..log('secret bob@example.com');

      expect(sink.entries, isEmpty, reason: 'unprocessed entry does not reach sinks');
      expect(diagnostics.single.message, 'RootLogger: processor failed, entry dropped');
      expect(diagnostics.single.error, isA<StateError>());
      expect('${diagnostics.single}', isNot(contains('bob@example.com')));
    });

    test('custom processor class: enrichment also applies to ready-made entries from asSink', () {
      final sink = RecordingLogSink();
      final logger = RootLogger(
        dispatch: LogDispatchPolicy.synchronous,
        sinks: [sink],
        processors: const [_BuildEnricher('1.2.3')],
      )..finishStartup();

      logger
        ..log('own')
        ..asSink().add(_entry('from another isolate'));

      expect(sink.entries.map((e) => e.attributes.get(_build)), ['1.2.3', '1.2.3']);
      expect(sink.entries.map((e) => e.message), ['own', 'from another isolate']);
    });

    test('ready-made entry from asSink: attribute order in the processor decides whose value wins', () {
      final overriding = RecordingLogSink();
      final preserving = RecordingLogSink();
      final ready = LogEntry(
        time: DateTime(2026),
        level: LogLevel.info,
        message: 'from another isolate',
        attributes: LogAttributes([_build('background')]),
      );

      (RootLogger(
        dispatch: LogDispatchPolicy.synchronous,
        sinks: [overriding],
        processors: const [_BuildEnricher('main')],
      )..finishStartup()).asSink().add(ready);
      (RootLogger(
        dispatch: LogDispatchPolicy.synchronous,
        sinks: [preserving],
        processors: const [_BuildEnricher('main', overrides: false)],
      )..finishStartup()).asSink().add(ready);

      expect(overriding.entries.single.attributes.get(_build), 'main', reason: 'own attribute after: overwrote');
      expect(preserving.entries.single.attributes.get(_build), 'background', reason: 'own attribute before: kept');
    });

    test('without processors the entry reaches sinks as is', () {
      final sink = RecordingLogSink();
      RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink])
        ..finishStartup()
        ..log('plain');

      expect(sink.entries.single.message, 'plain');
    });

    test('processor list is unmodifiable', () {
      final processors = <LogProcessor>[LogProcessor((entry) => entry)];
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, processors: processors);

      processors.clear();
      expect(logger.processors, hasLength(1));
      expect(logger.processors.clear, throwsUnsupportedError);
    });

    group('addProcessor', () {
      test('adds the processor last; adding the same again does nothing', () {
        final sink = RecordingLogSink();
        final upper = LogProcessor((entry) => entry.copyWith(message: entry.message.toUpperCase()));
        final logger =
            RootLogger(
                dispatch: LogDispatchPolicy.synchronous,
                sinks: [sink],
                processors: [LogProcessor((entry) => entry.copyWith(message: '${entry.message}+1'))],
              )
              ..finishStartup()
              ..addProcessor(upper)
              ..addProcessor(upper)
              ..log('m');

        expect(logger.processors, hasLength(2));
        expect(sink.entries.single.message, 'M+1');
      });

      test('buffered startup entries pass the added processor before replay', () {
        final redactor = LogRedactor(patterns: [RegExp(r'[\w.+-]+@[\w-]+\.[\w.]+')]);
        final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous)
          ..log('early bob@example.com')
          ..log('drop me')
          ..addProcessor(redactor)
          ..addProcessor(LogProcessor((entry) => entry.message == 'drop me' ? null : entry));
        final sink = RecordingLogSink();

        logger
          ..addSink(sink)
          ..log('late ann@example.com');

        expect(sink.entries.map((e) => e.message), ['early [REDACTED]', 'late [REDACTED]']);
      });

      test('added processor failing on a buffered entry drops it with diagnostics', () {
        final diagnostics = <LogDiagnostic>[];
        final logger =
            RootLogger(dispatch: LogDispatchPolicy.synchronous, diagnostics: DiagnosticReporter(diagnostics.add))
              ..log('secret')
              ..addProcessor(LogProcessor((_) => throw StateError('processor broke')));
        final sink = RecordingLogSink();

        logger.addSink(sink);

        expect(sink.entries, isEmpty);
        expect(diagnostics.single.message, 'RootLogger: processor failed, entry dropped');
        expect('${diagnostics.single}', isNot(contains('secret')));
      });

      test('no buffer after finishStartup: adding replays nothing', () {
        final sink = RecordingLogSink();
        RootLogger(dispatch: LogDispatchPolicy.synchronous)
          ..log('early')
          ..finishStartup()
          ..addProcessor(LogProcessor((entry) => entry))
          ..addSink(sink);

        expect(sink.entries, isEmpty);
      });
    });

    test('removeProcessor removes the processor; removing a missing one does nothing', () {
      final sink = RecordingLogSink();
      final dropAll = LogProcessor((_) => null);
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink], processors: [dropAll])
        ..finishStartup();

      logger
        ..log('dropped')
        ..removeProcessor(dropAll)
        ..removeProcessor(dropAll)
        ..log('kept');

      expect(logger.processors, isEmpty);
      expect(sink.entries.map((e) => e.message), ['kept']);
    });
  });
}
