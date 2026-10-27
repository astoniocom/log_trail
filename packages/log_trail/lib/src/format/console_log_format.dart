import 'package:log_trail/src/entry/log_entry.dart';
import 'package:log_trail/src/entry/log_level.dart';
import 'package:log_trail/src/format/log_entry_format.dart';
import 'package:log_trail/src/format/log_time_format.dart';
import 'package:log_trail/src/format/stack_trace_format.dart';
import 'package:log_trail/src/format/tag_predicate.dart';

/// An entry for the console as one line: time, level icon, tags, message, error and attributes; for
/// errors, the stack trace below the line in the uniform Dart VM format ([formatStackTrace]). The default
/// format of `ConsoleSink`.
///
/// ```dart
/// ConsoleSink(format: const ConsoleLogFormat(useColors: false, isTagVisible: (tag) => !tag.startsWith('internal.')));
/// ```
final class ConsoleLogFormat implements LogEntryFormat {
  const ConsoleLogFormat({
    this.showStackTrace = true,
    this.isTagVisible,
    this.useColors = true,
    this.showTime = true,
  });

  /// Print the stack trace for entries with an error and entries of level error and above.
  final bool showStackTrace;

  /// Which tags to show; `null` means all.
  final TagPredicate? isTagVisible;

  /// Color the line with ANSI codes by level: for a terminal (`dart run`, `dart test`). A console that is
  /// not a terminal shows the codes as text; the Flutter preset (`FlutterConsoleFormat`) turns them off.
  final bool useColors;

  /// Start the line with the entry time (`HH:mm:ss.mmm`): without it, early-phase events replayed later
  /// would look current.
  final bool showTime;

  /// The entry line ([formatLine]) and, if [showsStackTraceOf], the stack trace below it.
  @override
  String format(LogEntry entry) {
    final line = formatLine(entry);
    final stackTrace = entry.stackTrace;
    return stackTrace != null && showsStackTraceOf(entry) ? '$line\n${formatStackTrace(stackTrace)}' : line;
  }

  /// Whether to print the stack trace of [entry]: with [showStackTrace], for entries with an error and
  /// entries of level error and above.
  bool showsStackTraceOf(LogEntry entry) => showStackTrace && (entry.error != null || entry.level >= LogLevel.error);

  /// The entry line without the stack trace: time ([showTime]), level icon, visible tags
  /// ([isTagVisible]), message, error and attributes, in the level's ANSI color with [useColors]. For
  /// formats that print the stack trace or diagnostics differently but want the entry line in the same
  /// form (`FlutterConsoleFormat`).
  String formatLine(LogEntry entry) {
    final (icon, color) = switch (entry.level) {
      LogLevel.trace => ('⋯', '\x1B[2m'),
      LogLevel.debug => ('·', '\x1B[2m'),
      LogLevel.info => ('•', ''),
      LogLevel.warning => ('\u26A0', '\x1B[33m'),
      LogLevel.error => ('❗', '\x1B[31m'),
      LogLevel.fatal => ('‼️', '\x1B[1;31m'),
    };

    final colorStart = useColors ? color : '';
    final colorEnd = colorStart.isNotEmpty ? '\x1B[0m' : '';
    final time = showTime ? '${formatLogTimeOfDay(entry.time)} ' : '';
    final tags = entry.tags.whereVisible(isTagVisible).toList(growable: false);
    final prefix = tags.isNotEmpty ? '${tags.join(' ')} >> ' : '';
    final attributes = entry.attributes.isEmpty ? '' : ' ${entry.attributes}';
    final error = entry.error;
    final errorText = error == null || error.message == entry.message ? '' : ': $error';
    return '$colorStart$time$icon $prefix${entry.message}$errorText$attributes$colorEnd';
  }
}
