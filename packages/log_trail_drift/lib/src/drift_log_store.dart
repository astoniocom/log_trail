import 'package:drift/drift.dart';
// `remote.dart`, not `isolate.dart`: the exception type is platform-neutral,
// the isolate library is not supported on the web. drift marks `remote.dart`
// experimental for its wire protocol only; its public API, this type
// included, is documented as stable.
// ignore: experimental_member_use
import 'package:drift/remote.dart' show DriftRemoteException;
import 'package:log_trail/log_trail.dart';
import 'package:log_trail/storage.dart';
import 'package:log_trail_drift/src/log_entry_columns.dart';
import 'package:meta/meta.dart';
import 'package:sqlite3/common.dart' show SqliteException;

/// A [LogStore] over one drift table of your database: any table with
/// [LogEntryColumns]. One table and no helper tables or triggers is the point:
/// the log fits into your schema and migrations as one [Table].
///
/// ```dart
/// @DataClassName('LogEntryRow')
/// @TableIndex(name: 'log_entries_by_time', columns: {#time, #id})
/// class LogEntries extends Table with LogEntryColumns {}
///
/// @DriftDatabase(tables: [LogEntries])
/// class AppDatabase extends _$AppDatabase { /* … */ }
///
/// final store = DriftLogStore(db, db.logEntries, limit: 50000);
/// logger.addSink(RepeatCollapsingSink(LogStoreSink(store)));
/// ```
///
/// Everything goes through drift's query builder: pages ordered by
/// `(time, id)` and continued from a [LogCursor] by row-value comparison,
/// deletes by predicate. Filter conditions ([LogFilter.conditions]) are
/// translated with an exhaustive `switch`, so a new [LogCondition] does not
/// compile here until it has a translation; `compareLogStores` checks the
/// result against the in-memory reference.
///
/// Only `(time, id)` is indexed. Levels, tags and attributes are tested row by
/// row in SQL, text search is narrowed by [LogTextCondition.prefilterTokens]
/// over the entry JSON and decided by [LogTextCondition.matches]
/// ([collectLogPage]); a page is read in store order until full, so a filter
/// few rows satisfy reads the whole scope. [limit] bounds that cost; the
/// numbers (tens of milliseconds for a rare tag or attribute at 50 000
/// entries, half a second for a rare non-Latin needle) are measured in
/// `benchmark/filter_scan_benchmark.dart`. A tag no entry carries is answered
/// from the in-memory tag counts without a query. `log_trail_sqlite` indexes
/// tags, attributes and text instead.
///
/// Where SQLite runs is the database's choice (`NativeDatabase.createInBackground`,
/// `WasmDatabase`); the API is asynchronous end to end, so a fatal entry is
/// committed only when the executor gets to it, and an application that exits
/// right after one must `await logger.flush()` first.
///
/// Tag counts ([queryTags]) and the entry count ([count], eviction by [limit])
/// are kept in memory, built on first use by one `GROUP BY tags` query, and
/// are correct while this store is the only writer of the table within
/// [scope]; background isolates write to a `LogSpool` that the main isolate
/// imports here. The store does not own the database: [close] only marks the
/// store closed.
///
/// Subclass to fit the table into your schema: [additionalColumns] fills your
/// own columns on insert, [scope] restricts every query and removal to a
/// subset of rows (one tenant), so several stores or your code can share it.
///
/// ```dart
/// final class TenantLogStore extends DriftLogStore<$AuditLogTable, AuditLogData> {
///   TenantLogStore(super.database, super.table, this.tenant);
///
///   final String tenant;
///
///   @override
///   Map<GeneratedColumn<Object>, Expression<Object>> additionalColumns(LogEntry entry) =>
///       {table.tenant: Variable(tenant)};
///
///   @override
///   Expression<bool> get scope => table.tenant.equals(tenant);
/// }
/// ```
///
/// SQLite failures surface as [LogStoreException], unwrapped from drift's
/// [DriftRemoteException] when the executor runs in another isolate, without
/// query parameters. Requires SQLite 3.35 or newer (`RETURNING`): the build
/// drift bundles qualifies, the system SQLite of older Android versions does
/// not.
base class DriftLogStore<T extends LogEntryColumns, D> extends LogStoreBase {
  /// A store over [table] of [database]. [table] is the generated table
  /// object (`db.logEntries`), which is both the [TableInfo] drift queries
  /// need and the [LogEntryColumns] table; [T] and [D] (the row class) are
  /// inferred from it.
  ///
  /// [limit] caps the number of entries (within [scope]): when exceeded, the
  /// oldest are removed in the same transaction as the write, with
  /// [LogEntriesRemovedById] in [changes].
  DriftLogStore(this.database, TableInfo<T, D> table, {this.limit})
    : assert(limit == null || limit > 0, 'limit must be positive'),
      _info = table,
      // Generated tables return GeneratedColumns from the mixin's getters.
      _id = table.asDslTable.id as GeneratedColumn<int>,
      _time = table.asDslTable.time as GeneratedColumn<int>,
      _level = table.asDslTable.level as GeneratedColumn<String>,
      _entry = table.asDslTable.entry as GeneratedColumn<String>,
      _tags = table.asDslTable.tags as GeneratedColumn<String>,
      _attributes = table.asDslTable.attributes as GeneratedColumn<String>;

  /// Delimiter of [LogEntryColumns.tags] and [LogEntryColumns.attributes]:
  /// U+001F, unit separator.
  static const String separator = '\u001F';

  final GeneratedDatabase database;

  /// The log table as drift sees it; [table] is the same object typed as [T].
  final TableInfo<T, D> _info;

  /// The log table: the generated table object of your database, with its
  /// typed columns (`table.tenant` in a subclass).
  T get table => _info.asDslTable;

  /// Maximum number of stored entries within [scope]; `null` means no limit.
  final int? limit;

  final GeneratedColumn<int> _id;
  final GeneratedColumn<int> _time;
  final GeneratedColumn<String> _level;
  final GeneratedColumn<String> _entry;
  final GeneratedColumn<String> _tags;
  final GeneratedColumn<String> _attributes;

  /// Entry count and tag counts within [scope]; `null` until [initialize].
  Future<void>? _initialized;
  int _count = 0;
  final Map<String, int> _tagCounts = {};

  @override
  String get name => 'DriftLogStore';

  /// Columns of your table beyond [LogEntryColumns], with their values for
  /// [entry]: filled on every insert. Keyed by the generated column
  /// (`table.tenant`). Empty by default.
  @protected
  Map<GeneratedColumn<Object>, Expression<Object>> additionalColumns(LogEntry entry) => const {};

  /// Predicate every query, count and removal of this store is restricted to;
  /// `null` means the whole table. With a scope, [limit], [count] and
  /// [queryTags] apply to the scoped rows only.
  @protected
  Expression<bool>? get scope => null;

  /// Number of entries in the log (within [scope]); valid after [initialize]
  /// or the first operation.
  int get count => _count;

  /// Reads the entry and tag counts ([count], [queryTags], eviction by
  /// [limit]). Runs once, before the first operation, or now if called
  /// explicitly to surface failures early and to make [count] valid; after a
  /// failed operation the counts are read again by the next one.
  Future<void> initialize() => _initialized ??= _guard(() async {
    try {
      await _reload();
    } on Object {
      _initialized = null;
      rethrow;
    }
  });

  @override
  Future<List<StoredLogEntry>> onWriteEntries(List<LogEntry> entries) => _transaction(() async {
    final stored = <StoredLogEntry>[];
    for (final entry in entries) {
      final id = await database.into(_info).insert(RawValuesInsertable<D>(_values(entry)));
      _countTags(entry.tags, 1);
      stored.add(StoredLogEntry(id, entry));
    }
    _count += entries.length;
    final limit = this.limit;
    if (limit != null && _count > limit) {
      // The base sends this after the LogEntriesAdded of this write.
      reportChange(LogEntriesRemovedById(await _removeOldest(_count - limit)));
    }
    return List.unmodifiable(stored);
  });

  @override
  Future<LogPage> onQueryEntries(LogQuery query) async {
    await initialize();
    final newestFirst = query.newestFirst;
    final where = <Expression<bool>>[?scope];
    final texts = <LogTextCondition>[];

    // No default branch: a new condition must get its translation here.
    for (final condition in query.filter.conditions) {
      switch (condition) {
        case LogAfterCondition(:final time):
          where.add(_time.isBiggerThanValue(_microseconds(time)));
        case LogBeforeCondition(:final time):
          where.add(_time.isSmallerThanValue(_microseconds(time)));
        case LogLevelCondition(:final levels):
          where.add(_level.isIn([for (final level in levels) level.name]));
        case LogTagCondition(:final tag):
          // A tag no stored entry carries would otherwise cost a scan of the
          // scope for an empty page: the tag counts already answer it.
          if (!_tagCounts.containsKey(tag)) return LogPage(const []);
          where.add(_contains(_tags, '$separator$tag$separator'));
        case LogAttributeCondition(:final attribute):
          where.add(_contains(_attributes, '$separator${_pair(attribute)}$separator'));
        case LogTextCondition(:final prefilterTokens):
          // SQL only narrows the candidates (ASCII folding); the condition
          // itself is decided in Dart below.
          where.addAll([for (final token in prefilterTokens) _contains(_entry.lower(), token)]);
          texts.add(condition);
      }
    }

    final mode = newestFirst ? OrderingMode.desc : OrderingMode.asc;
    return collectLogPage(
      query,
      textConditions: texts,
      fetch: (after, limit) async {
        final select = database.selectOnly(_info)
          ..addColumns([_id, _time, _entry])
          ..orderBy([OrderingTerm(expression: _time, mode: mode), OrderingTerm(expression: _id, mode: mode)]);
        final predicates = [...where, if (after != null) _after(after, newestFirst)];
        if (predicates.isNotEmpty) select.where(predicates.reduce((a, b) => a & b));
        if (limit != null) select.limit(limit);
        final rows = await _guard(select.get);
        return [
          for (final row in rows)
            LogCandidate(
              id: row.read(_id)!,
              time: DateTime.fromMicrosecondsSinceEpoch(row.read(_time)!, isUtc: true),
              entryJson: row.read(_entry)!,
            ),
        ];
      },
    );
  }

  @override
  Future<Set<String>> onQueryTags() async {
    await initialize();
    return _tagCounts.keys.toSet();
  }

  @override
  Future<void> onClear() => _transaction(() async {
    await _delete(scope);
    _count = 0;
    _tagCounts.clear();
  });

  @override
  Future<void> onRemoveBefore(DateTime time) => _transaction(() async {
    final before = _time.isSmallerThanValue(_microseconds(time));
    await _uncountTags(before);
    _count -= await _delete(before);
  });

  @override
  Future<Set<int>?> onRetainNewest(int count) async {
    await initialize();
    return _count <= count ? const {} : await _transaction(() => _removeOldest(_count - count));
  }

  /// Column values of [entry] for an insert, plus [additionalColumns].
  Map<String, Expression<Object>> _values(LogEntry entry) => {
    _time.$name: Variable<int>(_microseconds(entry.time)),
    _level.$name: Variable<String>(entry.level.name),
    _entry.$name: Variable<String>(logEntryJsonText.encode(entry)),
    _tags.$name: Variable<String>(_delimited(entry.tags)),
    _attributes.$name: Variable<String>(
      _delimited([
        for (final MapEntry(:key, :value) in entry.attributes.encoded.entries) '$key=${value.toCanonicalJson()}',
      ]),
    ),
    for (final MapEntry(key: column, :value) in additionalColumns(entry).entries) column.$name: value,
  };

  /// Removes the [count] oldest entries in store order and returns their ids.
  /// One statement, `DELETE … WHERE id IN (the oldest) RETURNING id, tags`:
  /// the rows are selected, deleted and reported in one pass by one
  /// selection, with no id list to bind (a long one would exceed SQLite's
  /// parameter limit). Called inside a transaction. Needs SQLite 3.35 for
  /// `RETURNING`.
  Future<Set<int>> _removeOldest(int count) async {
    final oldest = database.selectOnly(_info)
      ..addColumns([_id])
      ..orderBy([OrderingTerm.asc(_time), OrderingTerm.asc(_id)])
      ..limit(count);
    if (scope case final scope?) oldest.where(scope);

    // Drift's delete statement returns rows as the generated row class, which
    // this store cannot read generically, so the statement is assembled from
    // drift's components into one context: the predicate and the subquery
    // (with its variables) are written by drift, only the frame is literal.
    final context = GenerationContext.fromDb(database)..buffer.write('DELETE FROM ${_info.tableWithAlias} WHERE ');
    _id.isInQuery(oldest).writeInto(context);
    context.buffer.write(' RETURNING ${context.identifier(_id.$name)}, ${context.identifier(_tags.$name)}');
    final rows = await database.customWriteReturning(
      context.sql,
      variables: context.introducedVariables,
      updates: {_info},
      updateKind: UpdateKind.delete,
    );

    final ids = <int>{};
    for (final row in rows) {
      ids.add(row.read<int>(_id.$name));
      _countTags(_splitDelimited(row.read<String>(_tags.$name)), -1);
    }
    _count -= rows.length;
    return ids;
  }

  /// Subtracts the tags of the rows matching [predicate] (within [scope])
  /// from the in-memory counts, before those rows are deleted. Aggregated
  /// as in [_reload], one row per distinct tag set: [removeBefore] may match
  /// thousands of rows, and only their tag sets need to cross the executor.
  Future<void> _uncountTags(Expression<bool> predicate) async {
    final entries = _id.count();
    final select = database.selectOnly(_info)
      ..addColumns([_tags, entries])
      ..where(_scoped(predicate)!)
      ..groupBy([_tags]);
    for (final row in await select.get()) {
      _countTags(_splitDelimited(row.read(_tags)!), -row.read(entries)!);
    }
  }

  /// Deletes the rows matching [predicate] within [scope]; returns how many.
  Future<int> _delete(Expression<bool>? predicate) {
    final statement = database.delete(_info);
    if (_scoped(predicate) case final where?) statement.where((_) => where);
    return statement.go();
  }

  Expression<bool>? _scoped(Expression<bool>? predicate) => switch ((scope, predicate)) {
    (null, final predicate) => predicate,
    (final scope?, null) => scope,
    (final scope?, final predicate?) => scope & predicate,
  };

  void _countTags(Iterable<String> tags, int delta) {
    for (final tag in tags) {
      final remaining = (_tagCounts[tag] ?? 0) + delta;
      if (remaining > 0) {
        _tagCounts[tag] = remaining;
      } else {
        _tagCounts.remove(tag);
      }
    }
  }

  /// Rereads [_count] and the tag counts from the table: one row per distinct
  /// tag set with how many entries carry it (`GROUP BY tags`), so the
  /// executor returns as many rows as there are tag combinations (usually
  /// tens), not as many as there are entries.
  Future<void> _reload() async {
    final entries = _id.count();
    final select = database.selectOnly(_info)
      ..addColumns([_tags, entries])
      ..groupBy([_tags]);
    if (scope case final scope?) select.where(scope);
    final rows = await select.get();
    _count = 0;
    _tagCounts.clear();
    for (final row in rows) {
      final count = row.read(entries)!;
      _count += count;
      _countTags(_splitDelimited(row.read(_tags)!), count);
    }
  }

  /// Runs [action] in a transaction (drift rolls it back on failure), with
  /// [initialize] inside it: the counts are read in the same transaction
  /// that then changes them, so no other operation can get between the read
  /// and the change. On failure the counts are discarded, not reread here:
  /// they may have changed before the failure, and a reread outside a
  /// transaction could interleave with the next operation; the next
  /// transaction rereads them in its own scope. An SQLite failure surfaces
  /// as [LogStoreException].
  Future<R> _transaction<R>(Future<R> Function() action) async {
    try {
      return await _guard(
        () => database.transaction(() async {
          await initialize();
          return action();
        }),
      );
    } on Object {
      _initialized = null;
      rethrow;
    }
  }

  /// Runs [action]; rethrows an SQLite failure from it as
  /// [LogStoreException] with the same stack trace. A failure from the
  /// executor's isolate arrives wrapped in a [DriftRemoteException] and is
  /// unwrapped, so callers see the same types whatever the executor.
  static Future<R> _guard<R>(Future<R> Function() action) async {
    try {
      return await action();
    } on SqliteException catch (error, stackTrace) {
      Error.throwWithStackTrace(_storeException(error), stackTrace);
    } on DriftRemoteException catch (error, stackTrace) {
      final cause = error.remoteCause;
      Error.throwWithStackTrace(
        cause is SqliteException ? _storeException(cause) : cause,
        error.remoteStackTrace ?? stackTrace,
      );
    }
  }

  /// [cause] as a [LogStoreException]: everything except the statement
  /// parameters (`parametersToStatement`), which for a write are the whole entry.
  /// The same six lines live in `SqliteLogStore`; see the note there.
  static LogStoreException _storeException(SqliteException cause) => LogStoreException(
    [cause.message, ?cause.explanation].join(', '),
    code: cause.extendedResultCode,
    operation: cause.operation,
    statement: cause.causingStatement,
  );

  /// Rows strictly after [cursor] in query order: `(time, id) < (?, ?)`
  /// spelled out, the `(time, id)` index serves both forms.
  Expression<bool> _after(LogCursor cursor, bool newestFirst) {
    final time = _microseconds(cursor.time);
    return newestFirst
        ? _time.isSmallerThanValue(time) | (_time.equals(time) & _id.isSmallerThanValue(cursor.id))
        : _time.isBiggerThanValue(time) | (_time.equals(time) & _id.isBiggerThanValue(cursor.id));
  }

  /// `instr(text, needle) > 0`: a parameterized substring test in which `%`
  /// and `_` mean nothing special.
  static Expression<bool> _contains(Expression<String> text, String needle) =>
      FunctionCallExpression<int>('instr', [text, Variable<String>(needle)]).isBiggerThanValue(0);

  static String _pair(LogAttribute<Object> attribute) =>
      '${attribute.field.name}=${attribute.encode().toCanonicalJson()}';

  static String _delimited(Iterable<String> items) =>
      items.isEmpty ? '' : '$separator${items.join(separator)}$separator';

  static Iterable<String> _splitDelimited(String text) =>
      text.isEmpty ? const [] : text.split(separator).where((item) => item.isNotEmpty);

  static int _microseconds(DateTime time) => time.microsecondsSinceEpoch;
}
