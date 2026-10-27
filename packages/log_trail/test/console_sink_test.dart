import 'dart:convert';

import 'package:log_trail/log_trail.dart';
import 'package:test/test.dart';

LogEntry _entry(String message, {LogLevel level = LogLevel.info, StackTrace? stackTrace, LogAttributes? attributes}) =>
    LogEntry(time: DateTime(2026), level: level, message: message, stackTrace: stackTrace, attributes: attributes);

void main() {
  late List<String> printed;

  setUp(() => printed = []);

  /// Console with [ConsoleLogFormat] writing to [printed].
  ConsoleSink sink({bool showStackTrace = true, bool useColors = true, bool showTime = true}) => ConsoleSink(
    format: ConsoleLogFormat(showStackTrace: showStackTrace, useColors: useColors, showTime: showTime),
    output: printed.add,
  );

  test('prints every received entry', () {
    sink(showStackTrace: false).add(_entry('debug message', level: LogLevel.debug));
    expect(printed.single, contains('debug message'));
  });

  test('useColors: false removes ANSI codes', () {
    sink(showStackTrace: false, useColors: false).add(_entry('warn', level: LogLevel.warning));
    expect(printed.single, isNot(contains('\x1B[')));
  });

  test('error stack is printed under the entry line only when the entry has one', () {
    sink()
      ..add(_entry('without stack', level: LogLevel.error))
      ..add(_entry('with stack', level: LogLevel.error, stackTrace: StackTrace.current));

    expect(printed, hasLength(2), reason: 'one output line per entry, stack inside it');
    expect(printed.first, isNot(contains('\n')));
    expect(printed.last, startsWith('\x1B[31m'));
    expect(printed.last.split('\n'), hasLength(greaterThan(1)));
    expect(printed.last, contains('console_sink_test.dart'));
  });

  test('with an explanatory message both error text and stack are printed, even at warning', () {
    sink().add(
      LogEntry(
        time: DateTime(2026),
        level: LogLevel.warning,
        message: 'Failed to load profile',
        error: const LogError(type: 'StateError', message: 'Bad state: token expired'),
        stackTrace: StackTrace.current,
      ),
    );

    final [line, ...stack] = printed.single.split('\n');
    expect(line, contains('Failed to load profile: StateError: Bad state: token expired'));
    expect(stack.join('\n'), contains('console_sink_test.dart'));
  });

  test('error text is not duplicated when it is the message', () {
    sink(showStackTrace: false).add(
      LogEntry(
        time: DateTime(2026),
        level: LogLevel.error,
        message: 'Bad state: boom',
        error: const LogError(type: 'StateError', message: 'Bad state: boom'),
      ),
    );

    expect(printed.single, endsWith('Bad state: boom\x1B[0m'));
    expect(printed.single, isNot(contains('StateError')));
  });

  test('extra attributes are printed after the message', () {
    const userId = LogField('test.user_id', LogCodec.string);
    sink().add(_entry('signed in', attributes: LogAttributes([userId('42')])));
    expect(printed.single, contains('signed in {test.user_id: 42}'));
  });

  test('line starts with the entry time, not the current one: matters for replayed events', () {
    sink(useColors: false).add(
      LogEntry(time: DateTime(2020, 5, 17, 9, 3, 7, 45), level: LogLevel.info, message: 'early'),
    );

    expect(printed.single, '09:03:07.045 • early');
  });

  test('showTime: false removes the time', () {
    sink(useColors: false, showTime: false).add(_entry('no time'));

    expect(printed.single, '• no time');
  });

  test('debug differs from info by icon and color', () {
    sink(showTime: false)
      ..add(_entry('d', level: LogLevel.debug))
      ..add(_entry('i'));

    expect(printed[0], startsWith('\x1B[2m·'));
    expect(printed[1], startsWith('•'));
  });

  test('ConsoleLogFormat.isTagVisible selects tags to show', () {
    ConsoleSink(
      format: ConsoleLogFormat(useColors: false, showTime: false, isTagVisible: (tag) => tag != 'internal'),
      output: printed.add,
    ).add(LogEntry(time: DateTime(2026), level: LogLevel.info, message: 'm', tags: const {'internal', 'auth'}));

    expect(printed.single, '• auth >> m');
  });

  group('build mode', () {
    test('defaults to the current build mode: debug in tests, sink prints', () {
      final sink = ConsoleSink(output: printed.add);
      expect(sink.buildMode, BuildMode.current);
      expect(sink.isSilent, isFalse);

      sink.add(_entry('m'));
      expect(printed, hasLength(1));
    });

    test('silent in release: format is not called, output gets nothing', () {
      final sink = ConsoleSink(format: _CountingFormat(), output: printed.add, buildMode: BuildMode.release);
      expect(sink.isSilent, isTrue);

      sink.add(_entry('m'));
      expect(printed, isEmpty);
      expect((sink.format as _CountingFormat).calls, 0);
    });

    test('prints in release with printInRelease', () {
      final sink = ConsoleSink(output: printed.add, printInRelease: true, buildMode: BuildMode.release);
      expect(sink.isSilent, isFalse);

      sink.add(_entry('m'));
      expect(printed, hasLength(1));
    });

    test('prints in profile: silence is release-only', () {
      ConsoleSink(output: printed.add, buildMode: BuildMode.profile).add(_entry('m'));
      expect(printed, hasLength(1));
    });
  });

  group('format', () {
    test('any LogEntryFormat: JSON lines to the console', () {
      ConsoleSink(format: LogExportFormat.jsonLines, output: printed.add).add(_entry('structured'));

      final json = jsonDecode(printed.single) as Map<String, Object?>;
      expect(json['message'], 'structured');
      expect(json['level'], 'info');
    });

    test('null from format: entry is not printed', () {
      ConsoleSink(format: _OnlyErrors(), output: printed.add)
        ..add(_entry('info'))
        ..add(_entry('error', level: LogLevel.error));

      expect(printed, ['error']);
    });
  });
}

/// Format that shows only the message of error-and-above entries; hides the rest.
final class _OnlyErrors implements LogEntryFormat {
  @override
  String? format(LogEntry entry) => entry.level >= LogLevel.error ? entry.message : null;
}

/// Format that counts calls.
final class _CountingFormat implements LogEntryFormat {
  int calls = 0;

  @override
  String format(LogEntry entry) {
    calls++;
    return entry.message;
  }
}
