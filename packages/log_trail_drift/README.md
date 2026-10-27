Drift log store for [`log_trail`](https://pub.dev/packages/log_trail): one
table in the drift database you already have. Entries survive restarts, SQLite
runs wherever your executor runs (a background isolate with
`NativeDatabase.createInBackground`, the browser with `WasmDatabase`), and the
in-app viewer from `log_trail_flutter` works over it unchanged.

## Setup

Declare the table in your project with the package's column mixin and add it
to your database. drift's generator only understands table classes declared
in the package it runs in, so the table is yours and `LogEntryColumns` is the
whole schema; this package generates nothing and needs no build configuration.

```dart
import 'package:drift/drift.dart';
import 'package:log_trail_drift/log_trail_drift.dart';

part 'app_database.g.dart';

// Name the row class: drift would otherwise call it `LogEntry`, which clashes
// with log_trail's `LogEntry`.
@DataClassName('LogEntryRow')
@TableIndex(name: 'log_entries_by_time', columns: {#time, #id})
class LogEntries extends Table with LogEntryColumns {}

@DriftDatabase(tables: [Users, LogEntries])
class AppDatabase extends _$AppDatabase {
  // ...
}
```

Adding the table to a database that is already shipped is a normal drift
migration:

```dart
@override
MigrationStrategy get migration => MigrationStrategy(
  onCreate: (m) => m.createAll(),
  onUpgrade: (m, from, to) async {
    if (from < 5) {
      await m.createTable(logEntries);
      await m.createIndex(logEntriesByTime);
    }
  },
);
```

Then open a store over the generated table object and plug it into the logger
like any other `LogStore`:

```dart
final store = DriftLogStore(db, db.logEntries, limit: 50000);
logger
  ..addSink(RepeatCollapsingSink(LogStoreSink(store)))
  ..finishStartup();

// Shutdown: the logger first (it waits for every accepted entry), then your
// database, which the store never closes.
await logger.close();
await db.close();
```

The journal mode is your database's choice. A log is many small write
transactions, and in SQLite's default `DELETE` journal mode each one syncs
the disk twice; `WAL` syncs once and lets the viewer read while the store
writes. If your database does not set it already, do so when opening it:

```dart
NativeDatabase.createInBackground(
  file,
  setup: (db) => db.execute('PRAGMA journal_mode = WAL'),
);
```

## Your own table: extra columns and scoping

Mix `LogEntryColumns` into a table with its own name and columns, and
subclass `DriftLogStore` to fill those columns and to restrict the store to
its part of the table. Several stores, or your own queries, can then share
one table:

```dart
@TableIndex(name: 'audit_log_by_time', columns: {#time, #id})
class AuditLog extends Table with LogEntryColumns {
  TextColumn get tenant => text()();
}

final class TenantLogStore extends DriftLogStore<$AuditLogTable, AuditLogData> {
  TenantLogStore(super.database, super.table, this.tenant, {super.limit});

  final String tenant;

  @override
  Map<GeneratedColumn<Object>, Expression<Object>> additionalColumns(LogEntry entry) =>
      {table.tenant: Variable(tenant)};

  @override
  Expression<bool> get scope => table.tenant.equals(tenant);
}
```

With a `scope`, `limit`, `count`, `queryTags`, every query and every removal
(including `clear`) apply to the scoped rows only. Extra columns without a
value from `additionalColumns` must have a default or be nullable.

## Design

- One table, no helper tables or triggers. `entry` holds the whole entry as
  JSON (`logEntryJson`), the source of truth; `time`, `level`, `tags` and
  `attributes` are an index derived from it on write. A new entry field
  needs no schema change.
- Everything goes through drift's typed query builder against the table's
  generated columns. Store order is `(time, id)`; pages continue from a
  `LogCursor` with a `(time, id)` comparison that the index serves, not with
  `OFFSET`. Put the `@TableIndex` on `(time, id)` as shown.
- Tags and attributes are delimited texts (U+001F) matched with `instr()`:
  parameterized, and `%` / `_` mean nothing special. Attribute values are
  compared as canonical JSON (map keys sorted). No index serves these
  columns, nor `level`: only `(time, id)` is indexed. A page is read in
  store order until it is full, so a filter that most rows satisfy stops
  early, while a filter few rows satisfy (a rare tag, an attribute value
  with a few hits) reads every row of the scope. A tag no stored entry
  carries is answered from the in-memory tag counts without a query.
  Measured with `benchmark/filter_scan_benchmark.dart` at 50 000 entries of
  ~750 bytes on a laptop: a page by a common tag 1.5 ms, a full scan by an
  attribute value 15–20 ms; expect several times that on a phone, once per
  filter change, on the executor's isolate. This is the price of one table;
  `log_trail_sqlite` indexes tags and attributes in helper tables instead.
  Set `limit` to bound it.
- Text search stores nothing extra. It folds case beyond ASCII, which
  SQLite's `lower()` cannot, so SQL only narrows the candidates with
  `instr(lower(entry), ?)` for the ASCII fragments of the needle
  (`LogTextCondition.prefilterTokens`) and the decoded rows are checked in
  Dart, page by page (`collectLogPage`, which checks the needle on the raw
  JSON before decoding a row). The prefilter lowercases every row's JSON,
  so it is the most expensive filter: 40–60 ms per page at 50 000 entries
  in the benchmark above. A needle without ASCII fragments (all Cyrillic)
  has no prefilter: a rare one reads the log through the executor in
  growing rounds, about 0.5 s in that benchmark and seconds on a phone,
  dominated by moving the rows out of SQLite, not by decoding them; a
  common one fills the page from the first rows. One table cannot carry an
  FTS index; an app whose users search a non-Latin log should use
  `log_trail_sqlite`, whose trigram index answers such a needle in
  milliseconds.
- Tag counts and the entry count are kept in memory, built on first use by
  one `GROUP BY tags` query (one row per distinct tag set, not per entry)
  and maintained by the store's own writes and removals: correct as long as
  this store is the table's only writer within its scope. Background isolates spool their entries (`LogSpoolSink`,
  `package:log_trail/isolates.dart`); the main isolate imports them here.
- The API is asynchronous end to end, so a `fatal` entry the root dispatches
  inside the logging call is queued to the executor before `log` returns and
  committed when the executor gets to it. An application that exits right
  after a fatal entry must `await logger.flush()` first. `log_trail_sqlite`
  commits such an entry synchronously instead.
- SQLite failures surface as `LogStoreException` (from
  `log_trail_sqlite`), unwrapped from drift's `DriftRemoteException` when the
  executor runs in another isolate, and without query parameters, which for a
  write are the whole entry.
- The contract test checks pages, tags and change events against
  `InMemoryLogStore` with random logs and queries, over a plain table and
  over two scoped stores sharing one table.

Works with any drift executor; on the web use `WasmDatabase` from
`package:drift/wasm.dart`. Requires SQLite 3.35 or newer (eviction deletes
with `RETURNING`): the SQLite bundled by `sqlite3_flutter_libs`, which drift
recommends on mobile, and drift's `sqlite3.wasm` are far newer; the system
SQLite of older Android versions is not.
