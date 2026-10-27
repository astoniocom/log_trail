import 'dart:convert';

import 'package:log_trail/src/entry/log_entry.dart';
import 'package:log_trail/src/format/log_entry_format.dart';
import 'package:log_trail/src/format/log_entry_json_codec.dart';
import 'package:log_trail/src/format/log_time_format.dart';

/// Log export formats (`exportLog`); as [LogEntryFormat] they also work for the console
/// (`ConsoleSink(format: LogExportFormat.jsonLines)`).
enum LogExportFormat implements LogEntryFormat {
  /// Readable text for an error report: the entry's first line is time, level, tags and message; below,
  /// indented, the error, call site, attributes and stack trace.
  text,

  /// One entry per line in the [logEntryJson] format: readable back via `logEntryJson.decode` and
  /// parseable by tools (`jq`).
  jsonLines;

  /// [entry] in this format, without a trailing newline. Never skips entries.
  @override
  String format(LogEntry entry) => switch (this) {
    LogExportFormat.text => _formatText(entry),
    LogExportFormat.jsonLines => logEntryJsonText.encode(entry),
  };
}

String _formatText(LogEntry entry) {
  final error = entry.error;
  final stackTrace = entry.stackTrace?.toString().trimRight();
  return [
    [
      formatLogTimestamp(entry.time),
      entry.level.name.toUpperCase(),
      if (entry.tags.isNotEmpty) '[${entry.tags.join(', ')}]',
      entry.message,
    ].join(' '),
    if (error != null && '$error' != entry.message) '  error: $error',
    if (entry.location case final location?) '  at: $location',
    for (final MapEntry(:key, :value) in entry.attributes.encoded.entries) '  $key: $value',
    if (stackTrace != null && stackTrace.isNotEmpty) ...[
      '  stack:',
      for (final line in const LineSplitter().convert(stackTrace)) '    $line',
    ],
  ].join('\n');
}
