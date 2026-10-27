# log_trail

Logging for Dart and Flutter that works before the app is ready: a root
logger created on the first line of `main()` buffers what is logged until the
sinks exist, fans entries out to console, database and crash reporting, keeps
typed entries that survive a storage round trip, and lets you browse the
persisted log inside the app.

```dart
final logger = RootLogger(sinks: [flutterConsoleSink()]);   // first line of main()
logger.info('App starting');                                 // buffered until a store exists

final store = SqliteLogStore.open('$dir/log.sqlite', limit: 50000);
logger
  ..addSink(RepeatCollapsingSink(LogStoreSink(store)))     // replays the buffered entries
  ..finishStartup();

final log = logger.child(tags: {'auth'});                   // modules depend on Logger
log.warning('Slow sign-in', attributes: [userId('42')]);

Navigator.push(context, MaterialPageRoute(builder: (_) => LogViewerPage(reader: store, diagnostics: logger.diagnostics)));
```

## Packages

| Package | What it is | pub.dev |
| --- | --- | --- |
| [`log_trail`](packages/log_trail) | The facade: `RootLogger`, `Logger`, typed `LogEntry`, sinks, processors, the storage contract with an in-memory store, queries and export, background-isolate spooling. Pure Dart, all platforms. | [![pub](https://img.shields.io/pub/v/log_trail.svg)](https://pub.dev/packages/log_trail) |
| [`log_trail_flutter`](packages/log_trail_flutter) | Flutter error hooks, a Flutter-aware console sink, a navigator observer and the in-app log viewer (`LogViewerPage`). | [![pub](https://img.shields.io/pub/v/log_trail_flutter.svg)](https://pub.dev/packages/log_trail_flutter) |
| [`log_trail_sqlite`](packages/log_trail_sqlite) | `SqliteLogStore` on `package:sqlite3`: the log survives restarts, with indexed pages, tag counts and FTS5 text search. Native platforms. | [![pub](https://img.shields.io/pub/v/log_trail_sqlite.svg)](https://pub.dev/packages/log_trail_sqlite) |
| [`log_trail_drift`](packages/log_trail_drift) | `DriftLogStore`: the same store as one table inside your own [drift](https://pub.dev/packages/drift) database, wherever its executor runs, including the web. | [![pub](https://img.shields.io/pub/v/log_trail_drift.svg)](https://pub.dev/packages/log_trail_drift) |

The [`log_trail` README](packages/log_trail/README.md) has the motivation,
the design and the usage guide; each package README covers its own part. The
[example app](packages/log_trail_flutter/example) wires everything together.

## Repository

A [pub workspace](https://dart.dev/tools/pub/workspaces): one `dart pub get`
at the root resolves all packages and the example together.

```sh
dart pub get
dart analyze
# Generated *.g.dart files keep the generator's formatting, so they are left out.
dart format --set-exit-if-changed $(git ls-files '*.dart' ':!*.g.dart')

(cd packages/log_trail && dart test)
(cd packages/log_trail_sqlite && dart test)
(cd packages/log_trail_drift && dart test)
(cd packages/log_trail_flutter && flutter test)
(cd packages/log_trail_flutter/example && flutter test)
```

`log_trail_drift` and its tests use generated drift code; after changing a
table or the `LogEntryColumns` docs, regenerate with
`dart run build_runner build --delete-conflicting-outputs` in that package
and commit the `*.g.dart` files as generated (a second run must write
nothing).

The analysis and formatting rules live in
`packages/log_trail/lib/analysis_options.yaml` and are included by every
package through `include: package:log_trail/analysis_options.yaml`, so that a
published package archive carries the same rules pub.dev analyzes it with.

Packages are published in dependency order: `log_trail` first, then
`log_trail_sqlite`, `log_trail_drift` and `log_trail_flutter`.

## License

MIT, see `LICENSE` in each package.
