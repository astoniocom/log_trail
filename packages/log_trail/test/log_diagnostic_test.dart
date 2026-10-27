import 'dart:async';

import 'package:log_trail/log_trail.dart';
import 'package:log_trail/storage.dart';
import 'package:log_trail/testing.dart';
import 'package:test/test.dart';

final class _FailingSink extends LogSink {
  @override
  void onAdd(LogEntry entry) => throw StateError('broken');
}

/// Store that cannot write a single batch.
final class _FailingStore extends LogStoreBase {
  @override
  Future<List<StoredLogEntry>> onWriteEntries(List<LogEntry> entries) async => throw StateError('disk full');

  @override
  Future<LogPage> onQueryEntries(LogQuery query) async => LogPage(const []);

  @override
  Future<Set<String>> onQueryTags() async => const {};

  @override
  Future<void> onClear() async {}

  @override
  Future<void> onRemoveBefore(DateTime time) async {}

  @override
  Future<Set<int>?> onRetainNewest(int count) async => const {};
}

void main() {
  test('prints to the console by default', () {
    expect(RootLogger().diagnostics, DiagnosticReporter.console);
    expect(RecordingLogSink().diagnostics, DiagnosticReporter.console);
    final printed = <String>[];
    runZoned(
      () => DiagnosticReporter.console.report(const LogDiagnostic('Source: something happened')),
      zoneSpecification: ZoneSpecification(print: (_, _, _, line) => printed.add(line)),
    );
    expect(printed, ['Source: something happened']);
  });

  group('console and build mode', () {
    final diagnostic = LogDiagnostic(
      'LogStoreSink: the store failed to write 1 entries',
      error: StateError('parameters: card 4111 1111'),
      stackTrace: StackTrace.fromString('#0 main (file.dart:1:1)'),
    );

    List<String> printedBy(void Function() action) {
      final printed = <String>[];
      runZoned(action, zoneSpecification: ZoneSpecification(print: (_, _, _, line) => printed.add(line)));
      return printed;
    }

    test('in debug and profile prints message, error and stack', () {
      for (final mode in [BuildMode.debug, BuildMode.profile]) {
        expect(printedBy(() => printDiagnostic(diagnostic, buildMode: mode)), ['$diagnostic']);
      }
      expect('$diagnostic', contains('card 4111 1111'));
      expect('$diagnostic', contains('file.dart:1:1'));
    });

    test('in release prints only the message: error and stack may carry entry data', () {
      final printed = printedBy(() => printDiagnostic(diagnostic, buildMode: BuildMode.release));

      expect(printed, ['LogStoreSink: the store failed to write 1 entries']);
      expect(printed.single, isNot(contains('4111')));
    });

    test('consoleText: one policy for all console handlers', () {
      expect(diagnostic.consoleText(BuildMode.release), diagnostic.message);
      expect(diagnostic.consoleText(BuildMode.profile), '$diagnostic');
      expect(diagnostic.consoleText(BuildMode.debug), '$diagnostic');
    });
  });

  test('reporter given to the root receives failures of wrapped sinks and of async store writes', () async {
    final diagnostics = <LogDiagnostic>[];
    final logger = RootLogger(
      sinks: [
        RepeatCollapsingSink(_FailingSink()),
        RepeatCollapsingSink(LogStoreSink(_FailingStore())),
      ],
      startupBufferTimeout: null,
      diagnostics: DiagnosticReporter(diagnostics.add),
    )..finishStartup();
    addTearDown(logger.close);

    logger.log('message');
    await pumpEventQueue();

    // The root fan-out catches the dispatch failure; the async write failure happens
    // outside it, and the sink reports it itself to the reporter received from the root.
    expect(diagnostics.map((d) => d.message), [
      'RootLogger: sink failed',
      'LogStoreSink: the store failed to write 1 entries',
    ]);
  });

  test('root reporter reaches a later-attached sink through wrappers', () {
    final reporter = DiagnosticReporter((_) {});
    final inner = RecordingLogSink();
    final logger = RootLogger(diagnostics: reporter)
      ..addSink(RepeatCollapsingSink(FilteringSink.minLevel(inner, LogLevel.info)));
    addTearDown(logger.close);

    expect(inner.diagnostics, same(reporter));
    expect(logger.asSink().diagnostics, same(reporter));
  });

  test('re-attaching to another root replaces the reporter', () {
    final first = DiagnosticReporter((_) {});
    final second = DiagnosticReporter((_) {});
    final sink = RecordingLogSink();
    final firstLogger = RootLogger(sinks: [sink], diagnostics: first);
    expect(sink.diagnostics, same(first));

    firstLogger.removeSink(sink);
    final secondLogger = RootLogger(sinks: [sink], diagnostics: second);
    addTearDown(() => Future.wait([firstLogger.close(), secondLogger.close()]));

    expect(sink.diagnostics, same(second));
  });

  test('handler failure does not reach the caller: it and the message are printed as a last resort', () {
    final reporter = DiagnosticReporter((_) => throw StateError('handler broke'));

    final printed = <String>[];
    runZoned(
      () => reporter.report(const LogDiagnostic('Source: failed')),
      zoneSpecification: ZoneSpecification(print: (_, _, _, line) => printed.add(line)),
    );

    expect(printed.first, startsWith('DiagnosticHandler failed: Bad state: handler broke'));
    expect(printed.last, 'Source: failed');
  });

  test('reporters with the same handler are equal', () {
    final diagnostics = <LogDiagnostic>[];
    expect(DiagnosticReporter(diagnostics.add), DiagnosticReporter(diagnostics.add));
    expect(DiagnosticReporter(diagnostics.add).hashCode, DiagnosticReporter(diagnostics.add).hashCode);
    expect(DiagnosticReporter(diagnostics.add), isNot(DiagnosticReporter.console));
    expect(DiagnosticReporter.console.handler, printDiagnostic);
  });

  test('toString: message only when there is no error', () {
    expect(const LogDiagnostic('Source: something happened').toString(), 'Source: something happened');
  });

  test('toString: message, error and stack', () {
    final stackTrace = StackTrace.fromString('#0 main (file.dart:1:1)');
    final diagnostic = LogDiagnostic('Source: failed', error: StateError('bad'), stackTrace: stackTrace);

    expect(diagnostic.toString(), 'Source: failed: Bad state: bad\n#0 main (file.dart:1:1)');
  });
}
