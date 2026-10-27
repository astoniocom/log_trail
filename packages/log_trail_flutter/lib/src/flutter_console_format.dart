import 'package:flutter/foundation.dart';
import 'package:log_trail/log_trail.dart';

/// Console format for Flutter: an entry with a Flutter error ([FlutterErrorDetails] in
/// [LogError.report]) is printed as the entry line ([ConsoleLogFormat.formatLine]) plus the full
/// diagnostics (context, library, stack) in the same form as [FlutterError.dumpErrorToConsole],
/// instead of the entry's stack trace. Other entries are printed as by [line]. The default
/// format of `flutterConsoleSink()`.
///
/// In a release build ([buildMode]) the diagnostics are not printed and the entry looks as by
/// [line]: the platform report is a live object, it does not pass through the root's processors
/// ([LogRedactor]), and it may contain user data, for example in widget properties; the entry
/// and the stack trace are subject to redaction. An error with [FlutterErrorDetails.silent]
/// outside debug mode is not printed at all (`null`), as with [FlutterError.dumpErrorToConsole].
///
/// The default [line] prints without ANSI colors. `debugPrint` does not write to a terminal: on
/// iOS it goes through `os_log` and syslog, which show the escape byte as the text `\^[`, and the
/// Xcode console shows the codes as text as well; only logcat passes them through, so a colored
/// default would be readable on one platform and garbled on the others. Enable colors explicitly
/// where they are known to render:
///
/// ```dart
/// flutterConsoleSink(format: const FlutterConsoleFormat(line: ConsoleLogFormat(useColors: true)));
/// ```
final class FlutterConsoleFormat implements LogEntryFormat {
  const FlutterConsoleFormat({
    this.line = const ConsoleLogFormat(useColors: false),
    this.buildMode = BuildMode.current,
  });

  /// Entry line and stack trace of regular entries; its [ConsoleLogFormat.showStackTrace] also
  /// decides whether to print Flutter error diagnostics.
  final ConsoleLogFormat line;

  /// Build mode that decides whether to print diagnostics and errors with
  /// [FlutterErrorDetails.silent]; defaults to this build's mode ([BuildMode.current]). Tests
  /// need a different value.
  final BuildMode buildMode;

  @override
  String? format(LogEntry entry) {
    final details = entry.error?.report;
    if (buildMode.isRelease || details is! FlutterErrorDetails) return line.format(entry);
    if (details.silent && !buildMode.isDebug) return null;
    final text = line.formatLine(entry);
    return line.showStackTrace ? '$text\n${renderFlutterError(details)}' : text;
  }

  /// Full diagnostics of [details] in the same form as [FlutterError.dumpErrorToConsole] prints:
  /// the frame with the library, description, context and stack trace with the same wrapping and
  /// truncation parameters.
  static String renderFlutterError(FlutterErrorDetails details) => TextTreeRenderer(
    wrapWidthProperties: FlutterError.wrapWidth,
    maxDescendentsTruncatableNode: 5,
  ).render(details.toDiagnosticsNode(style: DiagnosticsTreeStyle.error)).trimRight();
}
