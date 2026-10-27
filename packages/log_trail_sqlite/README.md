SQLite log store for
[`log_trail`](https://pub.dev/packages/log_trail): the log
survives app restarts, pages are read through an index, and the in-app
viewer from `log_trail_flutter` works over it unchanged.

```dart
import 'package:log_trail/log_trail.dart';
import 'package:log_trail_sqlite/log_trail_sqlite.dart';

final logger = RootLogger(sinks: [ConsoleSink()]);

// Later, once the documents directory is known:
final store = SqliteLogStore.open('$documentsPath/log.sqlite', limit: 50000);
logger
  ..addSink(RepeatCollapsingSink(LogStoreSink(store)))
  ..finishStartup();

// On shutdown: the logger first (it waits for every accepted entry to be
// written), then the store, which the app owns.
await logger.close();
await store.close();
```

## Design

- Each entry is stored as one JSON document (`logEntryJson`), so a new entry
  field needs no schema migration. Only what the store filters and orders by
  has its own columns and tables: time, level, lowercased search text, tags
  and attributes.
- Store order is `(time, id)` with an index; pages continue from a
  `LogCursor` with a row-value comparison instead of `OFFSET`, so entries
  written between two pages do not shift the next one.
- Tags are counted in a separate table by triggers: `queryTags` does not scan
  the log.
- Text search is case-insensitive beyond ASCII, as `LogFilter.matches`
  defines it, and indexed: an FTS5 trigram index over the message and error
  text answers a needle of three characters or more in any script as a
  substring lookup. Measured with `benchmark/text_search_benchmark.dart` at
  50 000 entries on a laptop: a rare Cyrillic or Latin needle 2 ms, a
  needle with no hits 0.1 ms, a needle most entries contain 2.5 ms (the
  store notices the index would not narrow and reads the page in store
  order instead). The index costs about a quarter of the database size. A
  one- or two-character needle is below what trigrams index and is decided
  by scanning: hundreds of milliseconds in that log for a rare Cyrillic
  pair. Attribute filters compare canonical JSON of the encoded value.
- `limit` evicts the oldest entries in the same transaction as the write
  and reports them as `LogEntriesRemovedById`.
- `package:sqlite3` is synchronous: a batch write blocks the calling isolate
  for the duration of the transaction, and an entry the root dispatches in
  the logging call (`LogDispatchPolicy.immediateLevel`, `fatal` by default)
  is committed before `log` returns, unless a previous batch is still being
  written. The store must live in the isolate that reads it (the viewer
  needs its `LogReader` and `changes`, and there is no cross-isolate proxy
  for them), so it cannot be moved into a worker isolate. If SQLite work
  must stay off the main isolate, use `DriftLogStore` from
  [`log_trail_drift`](https://pub.dev/packages/log_trail_drift) over
  `NativeDatabase.createInBackground`: the store and its reader stay in the
  main isolate, the statements run on drift's executor isolate.
- Durability is a choice at `open` (`SqliteDurability`). The default,
  `processCrash` (`synchronous = NORMAL`), is what `LogStore.writeEntries`
  requires: a committed entry survives a crash or kill of the process, but
  the last transactions may roll back after an OS crash or power loss.
  `powerLoss` (`synchronous = FULL`) fsyncs every commit at the cost of a
  few milliseconds per transaction on the writing isolate.
- One writer per file: the store keeps the entry count and eviction state
  in memory. Background isolates started by the engine (FCM, WorkManager)
  must not open a second store on the same file; they write to a
  `LogSpool` and the main isolate imports the spool into its store
  (`package:log_trail/isolates.dart`).

Native platforms only. Requires SQLite 3.34 or newer built with FTS5 (the
trigram tokenizer); `package:sqlite3` bundles such a build.
