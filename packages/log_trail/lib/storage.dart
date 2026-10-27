/// Storing, reading and viewing the log: the store contract (`LogStore`, `LogReader`) and the base for
/// custom stores (`LogStoreBase`, `collectLogPage`), the sink that writes entries to a store
/// (`LogStoreSink`), the in-memory store (`InMemoryLogStore`, `queryInMemory`), queries (`LogQuery`,
/// `LogFilter`, `LogCursor`), store
/// changes (`LogStoreChange`), the viewer list model (`LogWindow`) and export (`exportLog`).
///
/// Separate from `log_trail.dart`: code that only writes to the log does not need the store contract,
/// while store implementations (`SqliteLogStore` from `log_trail_sqlite`, a file) and the viewer depend
/// on this library. The entry format for stores (`logEntryJson`) and the export formats
/// (`LogExportFormat`) stay in `log_trail.dart`: they describe an entry, not a store, and are needed
/// without one (JSON console output, transfer between isolates).
library;

export 'package:log_trail/src/sinks/log_store_sink.dart' show LogStoreSink, LogWriteErrorHandler;
export 'package:log_trail/src/storage/collect_log_page.dart';
export 'package:log_trail/src/storage/in_memory/in_memory_log_store.dart';
export 'package:log_trail/src/storage/in_memory/in_memory_query.dart';
export 'package:log_trail/src/storage/log_condition.dart';
export 'package:log_trail/src/storage/log_export.dart';
export 'package:log_trail/src/storage/log_filter.dart';
export 'package:log_trail/src/storage/log_query.dart';
export 'package:log_trail/src/storage/log_reader.dart';
export 'package:log_trail/src/storage/log_store.dart';
export 'package:log_trail/src/storage/log_store_base.dart';
export 'package:log_trail/src/storage/log_store_change.dart';
export 'package:log_trail/src/storage/log_store_exception.dart';
export 'package:log_trail/src/storage/log_window.dart';
export 'package:log_trail/src/storage/stored_log_entry.dart';
