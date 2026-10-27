# log_trail_flutter example

A small app that creates the root logger first, hooks Flutter and platform
errors into it, logs route changes with `LoggingNavigatorObserver`, produces
a few entries (context, handled error, an error in a loop, a framework error)
and opens them in `LogViewerPage` with export to the clipboard.

```sh
cd packages/log_trail_flutter/example
flutter run
```

The store is `InMemoryLogStore`; replace it with `SqliteLogStore`
(`log_trail_sqlite`) or `DriftLogStore` (`log_trail_drift`) to keep the log
across restarts.
