A logging facade for Flutter apps that can be created on the first line of
`main()`, fans events out to several sinks (console, database, crash
reporting), and lets you browse the persisted log inside the app.

## Packages

- `log_trail`: the logging facade, the sink interface and a console
  sink (`package:log_trail/log_trail.dart`); the storage
  contract with an in-memory store, the store sink, queries and export
  (`package:log_trail/storage.dart`); logging from background
  isolates (`package:log_trail/isolates.dart`). Pure Dart, with no
  Flutter dependency.
- [`log_trail_flutter`](https://pub.dev/packages/log_trail_flutter):
  Flutter error reporting, a Flutter-aware console sink, a navigator
  observer and the in-app log viewer.
- [`log_trail_sqlite`](https://pub.dev/packages/log_trail_sqlite):
  `SqliteLogStore`, a `LogStore` on `package:sqlite3` that keeps the log
  across app restarts. Pure Dart, native platforms.
- [`log_trail_drift`](https://pub.dev/packages/log_trail_drift):
  `DriftLogStore`, the same store as one table inside your own
  [drift](https://pub.dev/packages/drift) database; runs wherever your
  executor runs, including a background isolate and the web.

## Motivation

Logging in a real app starts before the app is ready to log. The first
events, and often the most important errors, happen while the database,
crash reporting and other dependencies are still initializing. Later, when a
user reports a problem, you want to open the log on the device and see
exactly what was recorded, including entries from previous sessions.

This package was written because no existing package covered all of these
needs together:

- **Logging before the environment is ready.** The facade buffers events
  (with a bounded buffer) until sinks are attached, then replays them into
  each sink that asks for it, keeping the original event time. Analytics-like
  sinks can opt out of the replay so that shifted events do not distort
  reports.
- **Several independent sinks.** Every event goes to all attached sinks. A
  failing sink is isolated: it cannot crash the app or prevent other sinks
  from receiving the event.
- **Persisted records that stay the same after a round trip.** A record
  contains only data that survives storage: time, level, message, tags,
  code location, stack trace, the error's type and text and custom fields
  (request bodies, extra context). A list read back from the database is equal to the list
  that was written, so the in-app viewer shows the same thing for the
  current session and for past ones.
- **Typed custom fields.** Declare a field once
  (`const userId = LogField('app.user_id', LogCodec.string)`), attach it to
  a record (`log('Signed in', attributes: [userId('42')])`) and read it back
  as a `String?`, including from records loaded from storage. Storages only
  see a small closed set of values (string, number, bool, list, map), so a
  storage package written later supports fields it has never heard of.
- **An in-app viewer on top of the storage.** The log screen reads records
  through the storage interface and filters them by level and tag, so it
  works with whatever database you plug in.
- **Useful context out of the box.** The code location of warnings and
  errors is derived from the call stack, a `RepeatCollapsingSink` wrapper
  collapses repeats of the same error within a time window into one summary
  entry so an error in a loop does not flood the log, and a navigator
  observer records route changes.

### Why not an existing package

At the time of writing (`mason_logger` 0.3.6, `logger` 2.8.0, `logging`
1.3.0, `talker` 5.1.20):

- [`mason_logger`](https://pub.dev/packages/mason_logger) is a toolkit for
  command line apps (styled output, progress, prompts), not an application
  logger.
- [`logger`](https://pub.dev/packages/logger) has pluggable outputs, including
  files, but an output receives an event only after it was formatted by a
  printer, there are no tags or structured fields, and events logged before
  an asynchronous output finished `init()` are not buffered for it.
- [`logging`](https://pub.dev/packages/logging) is the standard,
  hierarchical logging API used by many Dart packages. It only produces
  records: storage, buffering and viewing are left to listeners, a record's
  time cannot be set explicitly, and the only category is the single logger
  name.
- [`talker`](https://pub.dev/packages/talker) is the closest in spirit, but
  its history is a synchronous in-memory `List<TalkerData>` that the UI
  re-reads on every event, so it cannot page through a database. Its records
  keep the original error object, and the viewer shows the error's runtime
  type, which cannot be reproduced for errors restored from storage.

## Features

- A root logger that exists from the first line of `main()`; sinks are
  attached as their dependencies become ready, and early entries are
  replayed into them with their original time.
- A small `Logger` interface for modules: `log`, `recordError`, level
  shortcuts (`trace` … `fatal`, each with an optional `error:`), child
  loggers with their own tags, context attributes and per-module level.
- Entries built in the logging call, dispatched after it: by default the
  root hands a batch to processors and sinks on the next event-loop turn,
  so `log()` never waits for serialization, stack parsing or I/O.
  `fatal` entries (configurable) are dispatched before `log()` returns.
- A processor pipeline applied once for all sinks: redaction
  (`LogRedactor`), enrichment, sampling.
- Sinks with one lifecycle (`add`/`flush`/`close`), failure isolation and a
  shared diagnostics channel; wrappers for per-sink filtering and for
  collapsing repeated errors.
- A storage contract with ids, cursor pagination and a change stream; an
  in-memory store, a SQLite store (`log_trail_sqlite`), and a base class
  that makes a new store a handful of primitives.
- Typed attributes that survive a storage round trip, JSON-lines export,
  a Flutter error hook, a navigator observer and an in-app viewer
  (`log_trail_flutter`).
- Logging from background isolates, including isolates started by the
  engine, through a spool on disk or a `SendPort`.

## Getting started

`log_trail` alone is a complete logger: the root, sinks, processors, an
in-memory store and the export. Add the other packages only for what you
need from them.

```yaml
dependencies:
  log_trail: ^0.1.0
```

| Add | When |
| --- | --- |
| `log_trail_flutter: ^0.1.0` | A Flutter app: Flutter error hooks, a `debugPrint` console sink, a navigator observer, the in-app log viewer. |
| `log_trail_sqlite: ^0.1.0` | The log should survive restarts and you do not use drift (native platforms). |
| `log_trail_drift: ^0.1.0` | The log should survive restarts as a table in the drift database you already have. Pick one store, not both. |

A typical Flutter app ends up with `log_trail`, `log_trail_flutter` and one
of the two stores; a Dart command-line tool or server with `log_trail`
alone.

The core is split into libraries, so that code which only writes to the
log does not depend on storage or on `dart:io`:

| Import | What it gives you |
| --- | --- |
| `package:log_trail/log_trail.dart` | `RootLogger`, `Logger`, `LogEntry`, `LogField`, sinks, processors, formats, diagnostics |
| `package:log_trail/storage.dart` | `LogStore`, `LogStoreBase`, `LogStoreSink`, `InMemoryLogStore`, `LogQuery`, `LogFilter`, `exportLog` |
| `package:log_trail/isolates.dart` | `LogSpool`, `LogSpoolSink`, `LogSpoolReceiver`, `IsolateLogSink`, `IsolateLogReceiver` (not available on web) |
| `package:log_trail/testing.dart` | `RecordingLogSink`, the test double for a sink (`LogSink` is a `base` class and cannot be mocked with `implements`); `compareLogStores`, the `LogStore` contract check against the in-memory reference for a store implementation |

## Usage

### Create the root first, attach sinks later

```dart
import 'package:log_trail/log_trail.dart';
import 'package:log_trail/storage.dart';

const userId = LogField('app.user_id', LogCodec.string);
const attempt = LogField('app.attempt', LogCodec.integer);

Future<void> main() async {
  // Before anything else: the console is the only sink available so far.
  final logger = RootLogger(sinks: [ConsoleSink()]);
  logger.info('App starting');

  // The database comes up later. Everything logged until now is buffered
  // (bounded, 200 entries by default) and replayed into the new sink.
  final store = await openStore(); // e.g. SqliteLogStore.open(path, limit: 50000)
  logger
    ..addSink(RepeatCollapsingSink(LogStoreSink(store)))
    ..finishStartup(); // the early phase is over; stop buffering

  // Modules get a child logger with their tags.
  final authLog = logger.child(tags: {'auth'});
  authLog.info('Signed in');

  // Context set on a logger reaches every entry of it and of its children.
  logger.setContextAttribute(userId('42'));

  try {
    throw const FormatException('Unexpected token');
  } on FormatException catch (error, stackTrace) {
    // A handled error: the message says what the app was doing.
    authLog.warning('Failed to parse profile', error: error, stackTrace: stackTrace, attributes: [attempt(3)]);
  }

  // Shutdown: the logger waits for every accepted entry to reach its sinks
  // and closes them. The store is owned by the app; close it last, when the
  // viewer no longer reads it either.
  await logger.close();
  await store.close();
}
```

What a sink receives is a `LogEntry`: time, level, message, tags, the call
site (resolved lazily from the stack for warnings and errors), the stack
trace, the error's type and text, and attributes. Entries are immutable
and comparable; what comes back from a store is equal to what was written.

### Module code depends on `Logger`, not on the root

```dart
final class SyncService {
  SyncService(this._log);

  final Logger _log; // injected: logger.child(tags: {'sync'})

  Future<void> run() async {
    _log.debug('Sync started');
    // Expensive data only when the level is enabled:
    if (_log.isEnabled(LogLevel.trace)) _log.trace('Payload: ${expensiveDump()}');
    _log.logLazy(expensiveDump, level: LogLevel.trace);
  }
}
```

A child logger can have its own threshold (`logger.child(tags: {'net'},
minLevel: LogLevel.trace)`) to turn one module up without flooding the log
with everything else; the root's `floor` is the hard lower bound for all of
them (`RootLogger(floor: BuildMode.current.isRelease ? LogLevel.info :
LogLevel.trace)`).

### Read the log back

```dart
final page = await store.queryEntries(
  LogQuery(
    filter: LogFilter(attributes: [userId('42')], levels: {LogLevel.warning}),
    newestFirst: true,
    limit: 50,
  ),
);
for (final StoredLogEntry(:id, :entry) in page.entries) {
  final int? attemptNumber = entry.attributes.get(attempt); // typed, also for stored entries
  print('#$id ${entry.message} attempt=$attemptNumber');
}
if (page.next case final next?) await store.queryEntries(next); // the following page

// A text or JSON-lines dump for a bug report:
final text = StringBuffer();
await exportLog(store, text, filter: const LogFilter(levels: {LogLevel.error, LogLevel.fatal}));
```

`LogFilter` combines a time range, levels, tags, attribute values and a
case-insensitive text search; all conditions are ANDed. Pages continue from
a `LogCursor` (`time`, `id`), so entries written between two pages do not
shift the next one. The store's `changes` stream reports every write and
removal, which is what the in-app viewer listens to.

### Tune the root

```dart
const buildVersion = LogField('app.build_version', LogCodec.string);

final logger = RootLogger(
  // Nothing below info in release, even if a module asks for more.
  floor: BuildMode.current.isRelease ? LogLevel.info : LogLevel.trace,
  // Applied once, before the early-phase buffer and every sink.
  processors: [
    LogRedactor(patterns: [RegExp(r'Bearer [\w.-]+'), RegExp(r'[\w.+-]+@[\w-]+\.[\w.]+')]),
    LogProcessor((entry) => entry.copyWith(attributes: entry.attributes.withAll([buildVersion('1.2.0')]))),
  ],
  // Dispatch errors and above inside the logging call; the rest on the next turn.
  dispatch: const LogDispatchPolicy(immediateLevel: LogLevel.error),
  // Where the library reports its own failures (a sink threw, a queue overflowed).
  diagnostics: DiagnosticReporter((d) => unawaited(Sentry.captureMessage('$d'))),
  // Per-sink selection: the console shows only warnings and above.
  sinks: [FilteringSink.minLevel(ConsoleSink(), LogLevel.warning)],
);

// When the app goes to the background the OS may kill it without notice:
AppLifecycleListener(onPause: () => unawaited(logger.flush()));
```

Diagnostics never go into the log itself (a broken sink would log about
its own failure forever); they go to `diagnostics`, console by default.

### Flutter

`log_trail_flutter` adds `FlutterError.onError = logger.recordFlutterError`,
`PlatformDispatcher.instance.onError = logger.recordPlatformError`, a
console sink that prints through `debugPrint` with full Flutter error
diagnostics (`flutterConsoleSink()`), `LoggingNavigatorObserver`, and
`LogViewerPage(reader: store, diagnostics: ...)`, a paged viewer with
search, level and tag filters and export over any `LogReader`. See its
[README](https://pub.dev/packages/log_trail_flutter).

### Background isolates

An isolate you start yourself can log straight into the main root over a
`SendPort` (`IsolateLogSink` / `IsolateLogReceiver`). Isolates started by
the engine (FCM, WorkManager) may outlive the main isolate or run without
it, so they write to a spool directory instead and the main isolate imports
it:

```dart
// Main isolate: import what background isolates wrote, now and on resume.
final receiver = LogSpoolReceiver(LogSpool(spoolDirectory), logger.asSink());
AppLifecycleListener(onResume: () => unawaited(receiver.importNow()));

// Background isolate: its own small root writing to the spool.
final background = RootLogger(
  sinks: [LogSpoolSink(LogSpool(spoolDirectory))],
  dispatch: LogDispatchPolicy.synchronous, // the isolate may exit right after
)..finishStartup();
background.info('Background work done');
```

Entries imported this way pass through the main root's processors and
sinks like its own, so redaction and storage happen in one place.

## Writing your own store

A store is anything that can keep entries and give them back in order:
SQLite, a file, a remote service, a wrapper around another store. The
contract is `LogStore` (writes, retention, close) over `LogReader` (queries
and the change stream, which is all the viewer needs). Three things define
it:

1. **Identity.** `writeEntries` assigns every entry an `int` id that grows in
   write order and is never reused (`INTEGER PRIMARY KEY AUTOINCREMENT` in
   SQLite). Store order is `(time, id)`: by time, and by id for equal times.
2. **Keyset pagination.** `queryEntries` returns a `LogPage`; when there is
   more, `page.next` is the same query starting after the last entry's
   `LogCursor`. No `OFFSET`: a store on disk needs an index on `(time, id)`.
3. **Change events.** Every write emits `LogEntriesAdded` with the stored
   entries; removals emit `AllLogEntriesRemoved`, `LogEntriesRemovedBefore`,
   `LogEntriesRemovedById`, or `LogStoreInvalidated` when the store cannot
   say cheaply what it removed.

You do not implement these yourself. Extend `LogStoreBase`: it emits the
events, enforces the closed state, strips live objects (`LogError.original`,
`LogError.report`) before entries reach you, and leaves you seven
primitives.

### A minimal store

```dart
import 'package:log_trail/log_trail.dart';
import 'package:log_trail/storage.dart';

/// Keeps entries in a list: the shape of a file- or database-backed store, minus the I/O.
final class ListLogStore extends LogStoreBase {
  ListLogStore({this.limit});

  final int? limit;
  final List<StoredLogEntry> _entries = []; // in store order
  int _nextId = 1;

  @override
  String get name => 'ListLogStore'; // readable in obfuscated builds

  @override
  Future<List<StoredLogEntry>> onWriteEntries(List<LogEntry> entries) async {
    final stored = [for (final entry in entries) StoredLogEntry(_nextId++, entry)];
    _entries.addAll(stored);
    // Self-eviction: report it; the base emits it after LogEntriesAdded.
    final limit = this.limit;
    if (limit != null && _entries.length > limit) {
      final evicted = _entries.sublist(0, _entries.length - limit);
      _entries.removeRange(0, evicted.length);
      reportChange(LogEntriesRemovedById({for (final e in evicted) e.id}));
    }
    return stored;
  }

  @override
  Future<LogPage> onQueryEntries(LogQuery query) async => queryInMemory(_entries, query);

  @override
  Future<Set<String>> onQueryTags() async => {for (final e in _entries) ...e.entry.tags};

  @override
  Future<void> onClear() async => _entries.clear();

  @override
  Future<void> onRemoveBefore(DateTime time) async => _entries.removeWhere((e) => e.entry.time.isBefore(time));

  @override
  Future<Set<int>?> onRetainNewest(int count) async {
    if (_entries.length <= count) return const {};
    final removed = _entries.sublist(0, _entries.length - count);
    _entries.removeRange(0, removed.length);
    return {for (final e in removed) e.id}; // null if you cannot tell cheaply
  }
}
```

`queryInMemory` implements the whole query semantics (filter, order,
cursor) over an in-memory list in store order, so a store that can afford
to hold its entries in memory is done at this point. `InMemoryLogStore` is
this plus tag counting and insertion by time for replayed early entries.

### A store with its own query language

A database store translates the query instead. Two helpers make this
mechanical and safe against future changes:

- `LogFilter.conditions` splits a filter into a closed set of
  `LogCondition`s. Translate them with an exhaustive `switch` without a
  default branch: a condition added in a future version becomes a compile
  error in your store, not a silently ignored filter.
- `logEntryJson` stores an entry as one JSON document. Keep only what you
  filter and order by in columns (time, level, tags, attributes); a new
  entry field then needs no schema migration.
- `collectLogPage` builds a page when SQL can only narrow the candidates
  and Dart makes the final decision. Text search is the case: it folds
  case beyond ASCII, which SQLite's `lower()` cannot. Instead of storing a
  lowercased copy of every message, prefilter the JSON with
  `LogTextCondition.prefilterTokens` (ASCII fragments every matching entry
  is guaranteed to contain) and let `collectLogPage` test the decoded
  candidates with `LogTextCondition.matches`, reading more rounds while
  candidates are rejected.

```dart
Future<LogPage> queryPage(LogQuery query) {
  final where = <String>[];
  final args = <Object?>[];
  final texts = <LogTextCondition>[];
  for (final condition in query.filter.conditions) {
    switch (condition) {
      case LogAfterCondition(:final time):
        where.add('time > ?');
        args.add(time.microsecondsSinceEpoch);
      case LogBeforeCondition(:final time):
        where.add('time < ?');
        args.add(time.microsecondsSinceEpoch);
      case LogLevelCondition(:final levels):
        where.add('level IN (${List.filled(levels.length, '?').join(',')})');
        args.addAll(levels.map((l) => l.index));
      case LogTagCondition(:final tag):
        where.add('id IN (SELECT entry_id FROM tags WHERE tag = ?)');
        args.add(tag);
      case LogAttributeCondition(:final attribute):
        where.add('id IN (SELECT entry_id FROM attributes WHERE name = ? AND value = ?)');
        args.addAll([attribute.field.name, attribute.encode().toJson().toString()]);
      case LogTextCondition(:final prefilterTokens):
        // SQL only narrows; the condition is decided in Dart by collectLogPage.
        for (final token in prefilterTokens) {
          where.add('instr(lower(entry), ?) > 0');
          args.add(token);
        }
        texts.add(condition);
    }
  }
  final order = query.newestFirst ? 'time DESC, id DESC' : 'time ASC, id ASC';
  return collectLogPage(
    query,
    accept: (entry) => texts.every((c) => c.matches(entry)),
    fetch: (after, limit) async {
      // Continue after the cursor with a row-value comparison on the (time, id) index.
      final predicates = [...where, if (after != null) '(time, id) ${query.newestFirst ? '<' : '>'} (?, ?)'];
      return selectRows(
        'SELECT id, entry FROM entries '
        '${predicates.isEmpty ? '' : 'WHERE ${predicates.join(' AND ')} '}'
        'ORDER BY $order ${limit == null ? '' : 'LIMIT ?'}',
        [...args, if (after != null) ...[after.time.microsecondsSinceEpoch, after.id], ?limit],
      );
    },
  );
}
```

`collectLogPage` reads `limit + 1` rows in its first round, so a query
without a text condition costs the same as a plain page and the extra row
decides `LogPage.next` without a count.

Things the contract expects from a durable store, documented on
`LogStore` and shown in full in `log_trail_sqlite`:

- **Batches are transactions.** `onWriteEntries` receives the batch
  `LogStoreSink` accumulated; the next batch arrives only after this one
  completed. When the returned future completes, the entries must survive a
  process kill (`fatal` is written in the logging call precisely because of
  this). Whether they survive power loss is your choice; document it.
- **Eviction by your own policy** (file size, row count) is allowed at any
  time; report it with `reportChange(LogEntriesRemovedById(ids))` from
  `DELETE … RETURNING id`, or `LogStoreInvalidated` if the ids are not
  cheap to get. `retainNewest` returns the ids the same way.
- **`queryTags` must not scan the log**: keep a tag table with counts
  maintained on write and delete.
- **One writer per file.** Background isolates do not open a second store on
  the same file; they spool (see above) and the main isolate imports.

### Testing a store

`InMemoryLogStore` is the reference: its `queryInMemory` and
`LogCondition.matches` define what every query means. The SQLite package
checks its store against it with randomly generated logs and queries
(`test/store_contract_test.dart`): write the same entries into both,
run the same `LogQuery`s, compare pages, tags and the emitted change events.
Copy that test and point it at your store.

## Writing your own sink or processor

A sink extends `LogSink` and implements `onAdd`; `onBatchEnd` is called
after each batch the root dispatched, `onFlush`/`onClose` wait for delivery.
Report failures that happen outside the root's dispatch (timers, async I/O)
through `diagnostics`:

```dart
final class HttpSink extends LogSink {
  HttpSink(this.send);

  final Future<void> Function(List<Map<String, Object?>> batch) send;
  final List<LogEntry> _pending = [];
  Future<void> _inFlight = Future.value();

  @override
  String get name => 'HttpSink';

  @override
  void onAdd(LogEntry entry) => _pending.add(entry);

  @override
  void onBatchEnd() {
    if (_pending.isEmpty) return;
    final batch = [for (final entry in _pending) logEntryJson.encode(entry)];
    _pending.clear();
    _inFlight = _inFlight.then((_) => send(batch)).catchError((Object error, StackTrace stack) {
      diagnostics.report(LogDiagnostic('HttpSink: upload failed', error: error, stackTrace: stack));
    });
  }

  @override
  Future<void> onFlush() => _inFlight;

  @override
  Future<void> onClose() => _inFlight;
}
```

Wrap, don't subclass, to add behaviour to an existing sink:
`DelegatingSink` forwards everything to `inner`; `FilteringSink` and
`RepeatCollapsingSink` are built on it.

A processor is a `LogProcessor` (or a function wrapped in
`LogProcessor(...)`): it receives every entry before the buffer and the
sinks and returns the same entry, a `copyWith` of it, or `null` to drop
it. Processors run synchronously on every entry; keep them cheap and do
not touch `LogEntry.location` unless you need it (it parses the stack).
