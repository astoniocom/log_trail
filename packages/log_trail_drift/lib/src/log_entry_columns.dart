import 'package:drift/drift.dart';

/// The columns a drift table needs to hold `log_trail` entries: mix it into
/// a table declared in your project. drift's generator only understands table
/// classes in the package it runs in, so the table itself is yours; the mixin
/// is the whole schema.
///
/// ```dart
/// // The plain case. The row class is named explicitly: drift would otherwise
/// // call it `LogEntry`, which clashes with log_trail's `LogEntry`.
/// @DataClassName('LogEntryRow')
/// @TableIndex(name: 'log_entries_by_time', columns: {#time, #id})
/// class LogEntries extends Table with LogEntryColumns {}
///
/// // Or your own name and extra columns:
/// @TableIndex(name: 'audit_log_by_time', columns: {#time, #id})
/// class AuditLog extends Table with LogEntryColumns {
///   TextColumn get tenant => text()();
/// }
///
/// @DriftDatabase(tables: [LogEntries])
/// class AppDatabase extends _$AppDatabase { /* … */ }
/// ```
///
/// One table, no helper tables or triggers. [entry] is the whole entry as
/// JSON (`logEntryJson`), the source of truth: a new entry field needs no
/// schema change. The other columns are an index for filtering and ordering
/// and are derived from the entry on write; `DriftLogStore` fills them, your
/// code never writes them by hand:
///
/// - [time] and [id] give store order; put an index on `(time, id)`
///   (`@TableIndex(columns: {#time, #id})`) so that a page is read without
///   scanning the log.
/// - [tags] and [attributes] are delimited texts searched with `instr()`,
///   which binds the needle as a parameter and treats `%` and `_` literally.
///   No index serves them: a filter on a tag or an attribute reads rows in
///   store order until the page is full, every row of the scope when few
///   match (see `DriftLogStore`). The delimiter is U+001F (unit separator);
///   a tag or attribute name containing it is not supported.
/// - Text search has no column: it is prefiltered on [entry] in SQL and
///   decided in Dart (`LogTextCondition.prefilterTokens`), so the message is
///   not stored twice.
///
/// Extra columns of your table must have a default or be nullable, unless your
/// `DriftLogStore` subclass fills them (`DriftLogStore.additionalColumns`).
/// [id] is the table's primary key (drift makes an `autoIncrement()` column
/// the primary key): the table must not declare [primaryKey] or another
/// `autoIncrement()` column, drift's generator rejects both.
mixin LogEntryColumns on Table {
  /// Store id and the table's primary key: grows in write order and is never
  /// reused (`INTEGER PRIMARY KEY AUTOINCREMENT`).
  IntColumn get id => integer().autoIncrement()();

  /// Entry time, microseconds since the epoch in UTC.
  IntColumn get time => integer()();

  /// `LogLevel.name`.
  TextColumn get level => text()();

  /// The whole entry as JSON (`logEntryJson`).
  TextColumn get entry => text()();

  /// Tags, each wrapped in U+001F: `\u001Fnet\u001Fauth\u001F`.
  TextColumn get tags => text()();

  /// Attributes as `\u001Fname=canonical JSON\u001F…`, map keys sorted so that
  /// equal values give equal text.
  TextColumn get attributes => text()();
}
