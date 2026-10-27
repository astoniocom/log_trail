import 'package:log_trail/log_trail.dart';
import 'package:log_trail/storage.dart';
import 'package:log_trail_sqlite/src/sqlite_durability.dart';
import 'package:meta/meta.dart';
import 'package:sqlite3/sqlite3.dart';

/// SQLite log store: entries survive application restarts.
///
/// The entry is stored as JSON ([logEntryJson]) in one column, the source of
/// truth; the other columns and tables serve filtering and ordering: the
/// `(time, id)` index for pages, tag and attribute tables, trigger-maintained
/// tag counts for [queryTags], and an FTS5 trigram index over the searched
/// texts ([LogTextCondition.searchedTexts]) for text search. A new entry
/// field needs no schema change.
///
/// Filter conditions ([LogFilter.conditions]) are translated with an
/// exhaustive `switch`, so a new [LogCondition] does not compile here until it
/// has a translation; `compareLogStores` checks the result against the
/// in-memory reference. Text search is narrowed in SQL and decided by
/// [LogTextCondition.matches] ([collectLogPage]): a needle of at least
/// [minIndexedNeedleLength] characters that at most [maxIndexedMatches]
/// entries contain is an index lookup in any script; a more common needle is
/// read in store order; a shorter one falls back to
/// [LogTextCondition.prefilterTokens] and a scan. Where FTS5's case folding
/// and [String.toLowerCase] disagree (the Kelvin sign and a few others), the
/// index can miss an entry. Costs are measured in
/// `benchmark/text_search_benchmark.dart`.
///
/// Synchronous, in the caller's isolate: a [LogStoreSink] batch blocks it for
/// the transaction, a few milliseconds per 100 entries, and an entry the root
/// dispatches inside the call is committed before `log` returns. What a
/// commit survives is [SqliteDurability], process termination by default. The
/// store lives in the isolate that reads it (there is no cross-isolate
/// [LogReader]); an application that must keep SQLite off the main isolate
/// uses `DriftLogStore` over `NativeDatabase.createInBackground` instead.
///
/// One writer per file: the entry count is kept in memory, and a second
/// instance over the same file would diverge in eviction and not report its
/// removals. Background isolates write to a `LogSpool`, which the main isolate
/// imports into this store. WAL mode lets an external reader of the file (a
/// debugging tool) not block writes. [limit] evicts the oldest entries in the
/// same transaction as the write, reporting [LogEntriesRemovedById].
///
/// ```dart
/// final store = SqliteLogStore.open(p.join(dir.path, 'log.sqlite'), limit: 50000);
/// logger.addSink(RepeatCollapsingSink(LogStoreSink(store)));
/// ```
///
/// Owned by the code that opened it ([LogStore]): [close] after
/// [RootLogger.close]. A database opened by [SqliteLogStore.open] or
/// [SqliteLogStore.inMemory] is closed with the store; one passed to
/// [SqliteLogStore.new] only with `ownsDatabase: true`. SQLite failures
/// surface as [LogStoreException] without query parameters, which for a
/// write are the whole entry. Requires SQLite 3.34 or newer built with FTS5
/// (the `trigram` tokenizer); `package:sqlite3` ships such a build.
final class SqliteLogStore extends LogStoreBase {
  /// A store over [database], opened by the caller, for example to keep the
  /// log in one file with application data. The store's tables are created if
  /// missing. The database is closed with the store only when [ownsDatabase].
  ///
  /// Throws [StateError] if the schema in the database is newer than this
  /// build knows, and [LogStoreException] on an SQLite failure.
  SqliteLogStore(this.database, {this.limit, this.ownsDatabase = false})
    : assert(limit == null || limit > 0, 'limit must be positive') {
    _guard(() {
      _migrate();
      // Statements are prepared here, after migration, not lazily on first
      // access: otherwise closing a store that never wrote anything would
      // prepare them just to close them, and fail on a corrupted schema.
      _insertEntry = database.prepare(
        'INSERT INTO log_entries (time, level, entry) VALUES (?, ?, ?)',
        persistent: true,
      );
      _insertTag = database.prepare('INSERT INTO log_entry_tags (entry_id, tag) VALUES (?, ?)', persistent: true);
      _insertAttribute = database.prepare(
        'INSERT INTO log_entry_attributes (entry_id, name, value) VALUES (?, ?, ?)',
        persistent: true,
      );
      _insertText = database.prepare('INSERT INTO log_entry_texts (entry_id, text) VALUES (?, ?)', persistent: true);
      _count = _selectCount();
    });
  }

  /// Opens or creates the database file [path] and a store over it. The
  /// database is in WAL mode: readers do not block writes. What a committed
  /// write survives is set by [durability]; the default is
  /// [SqliteDurability.processCrash].
  factory SqliteLogStore.open(String path, {int? limit, SqliteDurability durability = SqliteDurability.processCrash}) {
    final database = sqlite3.open(path);
    try {
      database
        ..execute('PRAGMA journal_mode = WAL')
        ..execute('PRAGMA synchronous = ${durability.pragmaValue}');
      return SqliteLogStore(database, limit: limit, ownsDatabase: true);
    } on Object {
      database.close();
      rethrow;
    }
  }

  /// A store in an in-memory database: for tests and prototypes. Entries do
  /// not survive closing.
  factory SqliteLogStore.inMemory({int? limit}) {
    final database = sqlite3.openInMemory();
    try {
      return SqliteLogStore(database, limit: limit, ownsDatabase: true);
    } on Object {
      database.close();
      rethrow;
    }
  }

  /// Schema version this build creates (`PRAGMA user_version`): the number of
  /// steps in [migrations]. It cannot be raised without adding a step.
  static int get schemaVersion => migrations.length;

  /// Migration ladder: `migrations[i]` takes the database from version `i` to
  /// `i + 1`. A new schema version is a new step at the end of the list that
  /// alters the previous schema (`ALTER TABLE`, a new index, a data move), not
  /// a rewritten earlier step: databases on users' devices pass each step
  /// exactly once. The store test runs the migration from every intermediate
  /// version.
  ///
  /// - 0 → 1: the schema ([_schemaV1]).
  @visibleForTesting
  static const List<String> migrations = [_schemaV1];

  /// Shortest needle the trigram index answers; a shorter one is decided by
  /// scanning ([LogTextCondition.prefilterTokens] and [LogTextCondition.matches]).
  static const int minIndexedNeedleLength = 3;

  /// Most entries a needle may match for the index to be used for it; a
  /// needle matching more is decided while reading the page in store order,
  /// which for a common needle fills from the first rows ([_isSelective]).
  static const int maxIndexedMatches = 1000;

  final Database database;

  /// Maximum number of stored entries; `null` means no limit.
  final int? limit;

  /// Whether to close [database] on [close].
  final bool ownsDatabase;

  /// Number of entries in the log: kept here instead of a `COUNT(*)` per
  /// write. Correct as long as the store is the only writer of its database
  /// (see the class docs); reread after a transaction rollback.
  late int _count;

  /// Prepared write statements; prepared in the constructor after migration.
  late final PreparedStatement _insertEntry;
  late final PreparedStatement _insertTag;
  late final PreparedStatement _insertAttribute;
  late final PreparedStatement _insertText;

  @override
  String get name => 'SqliteLogStore';

  /// Number of entries in the log.
  int get count => _count;

  @override
  Future<List<StoredLogEntry>> onWriteEntries(List<LogEntry> entries) async => _transaction(() {
    final stored = <StoredLogEntry>[];
    for (final entry in entries) {
      _insertEntry.execute([_microseconds(entry.time), entry.level.name, logEntryJsonText.encode(entry)]);
      final id = database.lastInsertRowId;
      for (final tag in entry.tags) {
        _insertTag.execute([id, tag]);
      }
      for (final MapEntry(key: name, :value) in entry.attributes.encoded.entries) {
        _insertAttribute.execute([id, name, value.toCanonicalJson()]);
      }
      _insertText.execute([id, _searchedText(entry)]);
      stored.add(StoredLogEntry(id, entry));
    }
    _count += entries.length;
    final limit = this.limit;
    if (limit != null && _count > limit) {
      // The base sends this after the LogEntriesAdded of this write.
      reportChange(LogEntriesRemovedById(_removeOldest(_count - limit)));
    }
    return List.unmodifiable(stored);
  });

  @override
  Future<LogPage> onQueryEntries(LogQuery query) {
    final newestFirst = query.newestFirst;
    final where = <String>[];
    final arguments = <Object?>[];
    final texts = <LogTextCondition>[];

    // No default branch: a new condition must get its translation here.
    for (final condition in query.filter.conditions) {
      switch (condition) {
        case LogAfterCondition(:final time):
          where.add('time > ?');
          arguments.add(_microseconds(time));
        case LogBeforeCondition(:final time):
          where.add('time < ?');
          arguments.add(_microseconds(time));
        case LogLevelCondition(:final levels):
          where.add('level IN (${_placeholders(levels.length)})');
          arguments.addAll(levels.map((level) => level.name));
        case LogTagCondition(:final tag):
          where.add('id IN (SELECT entry_id FROM log_entry_tags WHERE tag = ?)');
          arguments.add(tag);
        case LogAttributeCondition(:final attribute):
          where.add('id IN (SELECT entry_id FROM log_entry_attributes WHERE name = ? AND value = ?)');
          arguments
            ..add(attribute.field.name)
            ..add(attribute.encode().toCanonicalJson());
        case LogTextCondition(:final needle, :final prefilterTokens):
          // SQL only narrows the candidates; the condition itself is decided
          // in Dart (collectLogPage). The trigram index answers a needle of
          // minIndexedNeedleLength characters or more in any script, and is
          // used when it is selective (_isSelective); a common needle is
          // cheaper to decide while reading the page in store order. A
          // needle below the index length falls back to the ASCII fragments
          // over the JSON.
          if (needle.runes.length < minIndexedNeedleLength) {
            for (final token in prefilterTokens) {
              where.add('instr(lower(entry), ?) > 0');
              arguments.add(token);
            }
          } else if (_isSelective(_ftsPhrase(needle))) {
            where.add('id IN (SELECT rowid FROM log_entry_fts WHERE log_entry_fts MATCH ?)');
            arguments.add(_ftsPhrase(needle));
          }
          texts.add(condition);
      }
    }

    final order = newestFirst ? 'time DESC, id DESC' : 'time ASC, id ASC';
    return collectLogPage(
      query,
      textConditions: texts,
      fetch: (after, limit) async {
        final predicates = [
          ...where,
          if (after != null && newestFirst) '(time, id) < (?, ?)',
          if (after != null && !newestFirst) '(time, id) > (?, ?)',
        ];
        final sql = [
          'SELECT id, time, entry FROM log_entries',
          if (predicates.isNotEmpty) 'WHERE ${predicates.join(' AND ')}',
          'ORDER BY $order',
          if (limit != null) 'LIMIT ?',
        ].join(' ');
        final rows = _guard(
          () => database.select(sql, [
            ...arguments,
            if (after != null) ...[_microseconds(after.time), after.id],
            ?limit,
          ]),
        );
        return [
          for (final row in rows)
            LogCandidate(
              id: row['id'] as int,
              time: DateTime.fromMicrosecondsSinceEpoch(row['time'] as int, isUtc: true),
              entryJson: row['entry'] as String,
            ),
        ];
      },
    );
  }

  @override
  Future<Set<String>> onQueryTags() async => {
    for (final row in _guard(() => database.select('SELECT tag FROM log_tags'))) row['tag'] as String,
  };

  @override
  Future<void> onClear() async => _transaction(() {
    database
      ..execute('DELETE FROM log_entry_tags')
      ..execute('DELETE FROM log_entry_attributes')
      ..execute('DELETE FROM log_entry_texts')
      ..execute('DELETE FROM log_entries');
    _count = 0;
  });

  @override
  Future<void> onRemoveBefore(DateTime time) async => _transaction(() {
    final before = _microseconds(time);
    const removed = 'SELECT id FROM log_entries WHERE time < ?';
    database
      ..execute('DELETE FROM log_entry_tags WHERE entry_id IN ($removed)', [before])
      ..execute('DELETE FROM log_entry_attributes WHERE entry_id IN ($removed)', [before])
      ..execute('DELETE FROM log_entry_texts WHERE entry_id IN ($removed)', [before])
      ..execute('DELETE FROM log_entries WHERE time < ?', [before]);
    _count -= database.updatedRows;
  });

  @override
  Future<Set<int>?> onRetainNewest(int count) async =>
      _count <= count ? const {} : _transaction(() => _removeOldest(_count - count));

  /// Releases the prepared statements and, when [ownsDatabase], closes the database.
  @override
  Future<void> onClose() async {
    _insertEntry.close();
    _insertTag.close();
    _insertAttribute.close();
    _insertText.close();
    if (ownsDatabase) database.close();
  }

  /// Removes the [count] oldest entries in store order and returns their ids.
  /// Called inside a transaction.
  Set<int> _removeOldest(int count) {
    const oldest = 'SELECT id FROM log_entries ORDER BY time ASC, id ASC LIMIT ?';
    final removed = {
      for (final row in database.select(oldest, [count])) row['id'] as int,
    };
    database
      ..execute('DELETE FROM log_entry_tags WHERE entry_id IN ($oldest)', [count])
      ..execute('DELETE FROM log_entry_attributes WHERE entry_id IN ($oldest)', [count])
      ..execute('DELETE FROM log_entry_texts WHERE entry_id IN ($oldest)', [count])
      ..execute('DELETE FROM log_entries WHERE id IN ($oldest)', [count]);
    _count -= removed.length;
    return removed;
  }

  /// The texts text search looks at ([LogTextCondition.searchedTexts]), as
  /// one FTS document: message, then the error text on its own line. The
  /// line break keeps a phrase from matching across the two in most cases;
  /// where it does, the final check ([LogTextCondition.matches]) rejects.
  static String _searchedText(LogEntry entry) => LogTextCondition.searchedTexts(entry).join('\n');

  /// Whether the index narrows [phrase] to at most [maxIndexedMatches]
  /// entries. `id IN (SELECT rowid FROM log_entry_fts WHERE … MATCH ?)`
  /// materializes every matching rowid before the outer query takes its
  /// page, so for a needle most entries contain the index costs tens of
  /// milliseconds and buys nothing: such a page is filled from the first
  /// rows in store order. FTS5 iterates lazily under `LIMIT`, so the probe
  /// reads at most [maxIndexedMatches] + 1 rowids.
  bool _isSelective(String phrase) {
    final matches = _guard(
      () => database.select('SELECT rowid FROM log_entry_fts WHERE log_entry_fts MATCH ? LIMIT ?', [
        phrase,
        maxIndexedMatches + 1,
      ]),
    );
    return matches.length <= maxIndexedMatches;
  }

  /// [needle] as an FTS5 phrase query: a quoted string with inner quotes
  /// doubled, so that FTS5 operators and column names in the needle are
  /// literal. With the trigram tokenizer a phrase matches as a substring.
  static String _ftsPhrase(String needle) => '"${needle.replaceAll('"', '""')}"';

  /// Runs [action] over entries in a transaction. On failure rolls it back
  /// and rereads [_count] from the database: the counter may have changed
  /// before the failure.
  T _transaction<T>(T Function() action) {
    try {
      return _inTransaction(action);
    } on Object {
      _count = _selectCount();
      rethrow;
    }
  }

  /// Runs [action] in a transaction, rolling it back on failure. Without
  /// [_count]: for migration, when the tables may not exist yet. An SQLite
  /// failure surfaces as [LogStoreException] ([_guard]).
  T _inTransaction<T>(T Function() action) => _guard(() {
    database.execute('BEGIN');
    try {
      final result = action();
      database.execute('COMMIT');
      return result;
    } on Object {
      database.execute('ROLLBACK');
      rethrow;
    }
  });

  /// Runs [action]; rethrows a [SqliteException] from it as
  /// [LogStoreException] with the same stack trace: without query
  /// parameters, which for a write contain the whole entry.
  static T _guard<T>(T Function() action) {
    try {
      return action();
    } on SqliteException catch (error, stackTrace) {
      Error.throwWithStackTrace(_storeException(error), stackTrace);
    }
  }

  int _selectCount() =>
      _guard(() => database.select('SELECT COUNT(*) AS count FROM log_entries').single['count'] as int);

  /// Takes the database from its version to [schemaVersion] through the
  /// [migrations] steps, each step in its own transaction together with the
  /// new `user_version` (`PRAGMA user_version` is transactional): a failure on
  /// a step rolls back only that step, completed ones remain, and the next
  /// open continues from it. An empty database (version 0) passes all steps
  /// and gets the current schema.
  void _migrate() {
    final version = database.userVersion;
    if (version > schemaVersion) {
      throw StateError('$name: database schema version $version is newer than supported $schemaVersion');
    }
    for (var from = version; from < schemaVersion; from++) {
      _inTransaction(() {
        database
          ..execute(migrations[from])
          ..userVersion = from + 1;
      });
    }
  }

  static int _microseconds(DateTime time) => time.microsecondsSinceEpoch;

  static String _placeholders(int count) => List.filled(count, '?').join(', ');
}

/// [cause] as a [LogStoreException]: everything except the statement
/// parameters (`parametersToStatement`), which for a write are the whole entry.
/// The same six lines live in `DriftLogStore`: the core does not know
/// [SqliteException], and a package shared by the two stores for this alone
/// is not worth its version and dependency.
LogStoreException _storeException(SqliteException cause) => LogStoreException(
  [cause.message, ?cause.explanation].join(', '),
  code: cause.extendedResultCode,
  operation: cause.operation,
  statement: cause.causingStatement,
);

/// Step 0 → 1: the schema. The whole entry lives in `entry` ([logEntryJson]);
/// the other columns and tables serve filtering and ordering. Time is
/// microseconds since the epoch in UTC; store order is the `(time, id)` index.
/// Tags are counted in `log_tags` by triggers so that `queryTags` does not
/// scan entries. The searched texts ([LogTextCondition.searchedTexts]:
/// message, then the error text on its own line) are the external content of
/// the FTS5 trigram index `log_entry_fts` (FTS5 needs the old text to delete a
/// document), kept in sync by triggers; the text is stored as written, case
/// folding is the tokenizer's.
const String _schemaV1 = '''
CREATE TABLE log_entries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  time INTEGER NOT NULL,
  level TEXT NOT NULL,
  entry TEXT NOT NULL
);
CREATE INDEX log_entries_by_time ON log_entries (time, id);

CREATE TABLE log_entry_tags (
  entry_id INTEGER NOT NULL,
  tag TEXT NOT NULL,
  PRIMARY KEY (entry_id, tag)
) WITHOUT ROWID;
CREATE INDEX log_entry_tags_by_tag ON log_entry_tags (tag, entry_id);

CREATE TABLE log_entry_attributes (
  entry_id INTEGER NOT NULL,
  name TEXT NOT NULL,
  value TEXT NOT NULL,
  PRIMARY KEY (entry_id, name)
) WITHOUT ROWID;
CREATE INDEX log_entry_attributes_by_value ON log_entry_attributes (name, value, entry_id);

CREATE TABLE log_tags (
  tag TEXT PRIMARY KEY,
  entry_count INTEGER NOT NULL
) WITHOUT ROWID;

CREATE TRIGGER log_entry_tags_count_insert AFTER INSERT ON log_entry_tags BEGIN
  INSERT INTO log_tags (tag, entry_count) VALUES (NEW.tag, 1)
    ON CONFLICT (tag) DO UPDATE SET entry_count = entry_count + 1;
END;

CREATE TRIGGER log_entry_tags_count_delete AFTER DELETE ON log_entry_tags BEGIN
  UPDATE log_tags SET entry_count = entry_count - 1 WHERE tag = OLD.tag;
  DELETE FROM log_tags WHERE tag = OLD.tag AND entry_count = 0;
END;

CREATE TABLE log_entry_texts (
  entry_id INTEGER PRIMARY KEY,
  text TEXT NOT NULL
);

CREATE VIRTUAL TABLE log_entry_fts USING fts5(
  text,
  content = 'log_entry_texts',
  content_rowid = 'entry_id',
  tokenize = 'trigram'
);

CREATE TRIGGER log_entry_texts_fts_insert AFTER INSERT ON log_entry_texts BEGIN
  INSERT INTO log_entry_fts (rowid, text) VALUES (NEW.entry_id, NEW.text);
END;

CREATE TRIGGER log_entry_texts_fts_delete AFTER DELETE ON log_entry_texts BEGIN
  INSERT INTO log_entry_fts (log_entry_fts, rowid, text) VALUES ('delete', OLD.entry_id, OLD.text);
END;
''';
