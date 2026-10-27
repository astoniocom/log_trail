Flutter integration for
[`log_trail`](https://pub.dev/packages/log_trail).

- `recordFlutterError`: an extension on any `Logger` (the root or a
  module's child logger) that records Flutter errors (`FlutterErrorDetails`):
  `FlutterError.onError = logger.recordFlutterError`. They become ordinary
  entries whose `LogError.report` carries the original details, so every sink
  and sink wrapper receives them; Flutter-aware sinks read the details from there.
  `recordPlatformError` fits `PlatformDispatcher.instance.onError`, which
  expects a handler returning `bool`.
- `flutterConsoleSink()`: the console sink from `log_trail` preset to
  print through `debugPrint` in `FlutterConsoleFormat`, which renders
  Flutter errors with the full `FlutterErrorDetails` diagnostics, in the
  same shape as `FlutterError.dumpErrorToConsole`, without ANSI colors by
  default: `debugPrint` output reaches the IDE through `os_log`/syslog on
  iOS, which turn the escape codes into text. The format is a
  `LogEntryFormat` and can be used with any `ConsoleSink` or replaced.
- `LoggingNavigatorObserver`: a `NavigatorObserver` that logs route changes.
  It depends only on `package:flutter/widgets.dart`, not on Material.
- `LogViewerPage`: the in-app log viewer on top of a `LogReader` (any `LogStore`)
  (`package:log_trail_flutter/widgets.dart`, which also re-exports
  `package:log_trail/storage.dart`). Its texts are English
  by default and can be translated with `LogViewerStrings`.

The [example app](example/) wires all of this together: the root logger
created first, error hooks, the navigator observer, a few produced entries
and the viewer with export to the clipboard (`flutter run` in `example/`).

See the [`log_trail` README](https://pub.dev/packages/log_trail)
for the motivation and the overall design.
