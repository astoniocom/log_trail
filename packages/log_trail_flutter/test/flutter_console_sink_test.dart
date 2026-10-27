import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:log_trail_flutter/log_trail_flutter.dart';

void main() {
  late List<String> printed;
  late List<FlutterErrorDetails> presented;
  late DebugPrintCallback originalDebugPrint;
  late FlutterExceptionHandler originalPresentError;

  setUp(() {
    printed = [];
    presented = [];
    originalDebugPrint = debugPrint;
    originalPresentError = FlutterError.presentError;
    debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
    FlutterError.presentError = presented.add;
  });

  tearDown(() {
    debugPrint = originalDebugPrint;
    FlutterError.presentError = originalPresentError;
  });

  /// An entry with a Flutter error, as built by `recordFlutterError`.
  LogEntry entry({
    LogLevel level = LogLevel.error,
    FlutterErrorDetails details = const FlutterErrorDetails(exception: 'boom'),
    Set<String> tags = const {},
    DateTime? time,
  }) => LogEntry(
    time: time ?? DateTime(2026),
    level: level,
    message: 'boom',
    tags: tags,
    error: LogError.capture(details.exception, report: details),
  );

  /// Format without colors and time: lines are compared exactly.
  const plain = FlutterConsoleFormat(line: ConsoleLogFormat(useColors: false, showTime: false));
  const plainWithoutStack = FlutterConsoleFormat(
    line: ConsoleLogFormat(useColors: false, showTime: false, showStackTrace: false),
  );

  test('by default prints via debugPrint in FlutterConsoleFormat', () {
    final sink = flutterConsoleSink();
    expect(sink.format, isA<FlutterConsoleFormat>());

    sink.add(LogEntry(time: DateTime(2026), level: LogLevel.info, message: 'message'));
    expect(printed.single, contains('message'));
  });

  test('a Flutter error prints as the entry line plus diagnostics via output, not presentError', () async {
    final details = FlutterErrorDetails(
      exception: 'boom',
      library: 'widgets library',
      context: ErrorDescription('building Foo'),
    );
    final output = <String>[];

    final logger =
        RootLogger(
            sinks: [flutterConsoleSink(format: plain, output: output.add)],
          )
          ..finishStartup()
          ..recordFlutterError(details, tags: const {'flutter', 'ui'});
    await logger.close();

    expect(presented, isEmpty);
    expect(printed, isEmpty, reason: 'output goes to output, not debugPrint');
    final [line, ...diagnostics] = output.single.split('\n');
    expect(line, '❗ flutter ui >> boom');
    expect(diagnostics.join('\n'), contains('EXCEPTION CAUGHT BY WIDGETS LIBRARY'));
    expect(diagnostics.join('\n'), contains('building Foo'));
    expect(diagnostics.join('\n'), contains('boom'));
  });

  test('the default format prints without ANSI colors: debugPrint output is not a terminal', () {
    final output = <String>[];
    flutterConsoleSink(output: output.add)
      ..add(entry(time: DateTime(2026, 1, 1, 12, 30, 15, 250)))
      ..add(LogEntry(time: DateTime(2026), level: LogLevel.warning, message: 'plain'));

    expect(output, everyElement(isNot(contains('\x1B['))));
    expect(const FlutterConsoleFormat().line.useColors, isFalse);
  });

  test('the Flutter error entry line honors showTime, useColors and isTagVisible of the line format', () {
    final output = <String>[];
    flutterConsoleSink(
      format: FlutterConsoleFormat(
        line: ConsoleLogFormat(showStackTrace: false, isTagVisible: (tag) => tag != 'flutter'),
      ),
      output: output.add,
    ).add(entry(time: DateTime(2026, 1, 1, 12, 30, 15, 250), tags: const {'flutter', 'ui'}));

    expect(output.single, '\x1B[31m12:30:15.250 ❗ ui >> boom\x1B[0m');
  });

  test('diagnostics match what FlutterError.dumpErrorToConsole prints', () {
    const details = FlutterErrorDetails(exception: 'boom', library: 'test library');
    FlutterError.dumpErrorToConsole(details, forceReport: true);

    expect(FlutterConsoleFormat.renderFlutterError(details), printed.join('\n'));
  });

  test('behind a FilteringSink, Flutter errors below the threshold are not printed', () {
    FilteringSink.minLevel(flutterConsoleSink(), LogLevel.fatal).add(entry());

    expect(presented, isEmpty);
    expect(printed, isEmpty);
  });

  test('with showStackTrace: false a Flutter error prints as a plain line without the stack dump', () {
    flutterConsoleSink(format: plainWithoutStack).add(entry());

    expect(presented, isEmpty);
    expect(printed.single, '❗ boom');
  });

  test('an entry with a plain error prints like ConsoleSink: line and stack trace', () {
    final output = <String>[];
    flutterConsoleSink(format: plain, output: output.add).add(
      LogEntry(
        time: DateTime(2026),
        level: LogLevel.error,
        message: 'plain',
        stackTrace: StackTrace.fromString('#0      main (file:///app.dart:1:1)'),
        error: LogError.capture(StateError('plain')),
      ),
    );

    final [line, ...stack] = output.single.split('\n');
    expect(line, '❗ plain: StateError: Bad state: plain');
    expect(stack.join('\n'), contains('main (file:///app.dart:1:1)'));
    expect(stack.join('\n'), isNot(contains('EXCEPTION CAUGHT BY')));
  });

  test('FlutterConsoleFormat also works for a plain ConsoleSink with another output', () {
    final output = <String>[];
    ConsoleSink(format: plainWithoutStack, output: output.add).add(entry(tags: const {'flutter'}));

    expect(output.single, '❗ flutter >> boom');
  });

  group('build mode', () {
    // Same text as the entry message: the line has no ": String: ..." suffix.
    const silentDetails = FlutterErrorDetails(exception: 'boom', silent: true);

    test('the core BuildMode.current matches kDebugMode, kProfileMode and kReleaseMode', () {
      expect(BuildMode.current.isDebug, kDebugMode);
      expect(BuildMode.current == BuildMode.profile, kProfileMode);
      expect(BuildMode.current.isRelease, kReleaseMode);
    });

    test('in debug, diagnostics are printed, including for a silent error', () {
      const format = FlutterConsoleFormat(
        line: ConsoleLogFormat(useColors: false, showTime: false),
        // Explicit although it is the default in tests: the test is about debug mode, not the default.
        // ignore: avoid_redundant_argument_values
        buildMode: BuildMode.debug,
      );

      final [line, ...diagnostics] = format.format(entry(details: silentDetails))!.split('\n');
      expect(line, '❗ boom');
      expect(diagnostics.join('\n'), contains('EXCEPTION CAUGHT BY'));
    });

    test('in profile, a silent error is not printed at all, others print with diagnostics', () {
      const format = FlutterConsoleFormat(
        line: ConsoleLogFormat(useColors: false, showTime: false),
        buildMode: BuildMode.profile,
      );

      expect(format.format(entry(details: silentDetails)), isNull);
      expect(format.format(entry()), contains('EXCEPTION CAUGHT BY'));
    });

    test('in release, a Flutter error prints as a plain entry without diagnostics: the report is not masked', () {
      const format = FlutterConsoleFormat(
        line: ConsoleLogFormat(useColors: false, showTime: false),
        buildMode: BuildMode.release,
      );

      final text = format.format(entry())!;
      expect(text, '❗ boom');
      expect(text, isNot(contains('EXCEPTION CAUGHT BY')));
      expect(format.format(entry(details: silentDetails)), '❗ boom', reason: 'silent only matters with diagnostics');
    });

    test('flutterConsoleSink in release is silent without printInRelease, like ConsoleSink', () {
      flutterConsoleSink(buildMode: BuildMode.release).add(entry());
      expect(printed, isEmpty);
    });

    test('flutterConsoleSink passes its buildMode to the default format', () {
      final sink = flutterConsoleSink(buildMode: BuildMode.release, printInRelease: true);
      expect((sink.format as FlutterConsoleFormat).buildMode, BuildMode.release);

      sink.add(entry());
      expect(printed.single, isNot(contains('EXCEPTION CAUGHT BY')), reason: 'the format is in release too');
    });
  });
}
