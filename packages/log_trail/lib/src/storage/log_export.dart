import 'package:log_trail/src/format/log_entry_format.dart';
import 'package:log_trail/src/format/log_export_format.dart';
import 'package:log_trail/src/storage/log_filter.dart';
import 'package:log_trail/src/storage/log_query.dart';
import 'package:log_trail/src/storage/log_reader.dart';

/// Exports the entries of [reader] matching [filter] to [output], oldest to newest, one entry per
/// [LogEntryFormat.format] plus a newline: for an error report or sending to support. Entries for which
/// [format] returned `null` are skipped. Returns the number of exported entries.
///
/// Entries are read in pages of [pageSize], so the whole log is not loaded into memory unless [output]
/// accumulates it itself (like [StringBuffer]).
///
/// ```dart
/// final file = File(path).openWrite();
/// await exportLog(store, file, format: LogExportFormat.jsonLines);
/// await file.close();
/// ```
Future<int> exportLog(
  LogReader reader,
  StringSink output, {
  LogFilter filter = const LogFilter(),
  LogEntryFormat format = LogExportFormat.text,
  int pageSize = 500,
}) async {
  var count = 0;
  LogQuery? query = LogQuery(filter: filter, limit: pageSize);
  while (query != null) {
    final page = await reader.queryEntries(query);
    for (final stored in page.entries) {
      final text = format.format(stored.entry);
      if (text == null) continue;
      output.writeln(text);
      count++;
    }
    query = page.next;
  }
  return count;
}
