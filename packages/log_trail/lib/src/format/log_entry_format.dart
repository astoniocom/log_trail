import 'package:log_trail/src/entry/log_entry.dart';

/// The text of an entry for output: to the console (`ConsoleSink.format`), to a file or a report
/// (`exportLog`).
///
/// The format decides how to show an entry; the sink or export decides where to write it. So one format
/// prints both to the console and to a file (`ConsoleSink(format: LogExportFormat.jsonLines)` gives
/// structured output for a server), and changing how entries look in the console does not require
/// subclassing the sink: passing another format is enough.
///
/// Built-in formats: `ConsoleLogFormat` (a line with level icon, tags and stack trace), `LogExportFormat`
/// (report text, JSON lines), and in Flutter `FlutterConsoleFormat` with Flutter error diagnostics.
abstract interface class LogEntryFormat {
  /// The text of [entry] without a trailing newline, possibly multi-line (stack trace). `null` means the
  /// entry is not printed: for example, the console does not show a Flutter error with
  /// `FlutterErrorDetails.silent` outside debug.
  String? format(LogEntry entry);
}
