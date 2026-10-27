import 'package:flutter/foundation.dart';
import 'package:log_trail/log_trail.dart';
import 'package:log_trail_flutter/src/flutter_console_format.dart';

/// [ConsoleSink] for Flutter: prints via [debugPrint], which throttles output (otherwise Android
/// drops lines) and keeps ordering with Flutter's own output, in the [FlutterConsoleFormat]
/// format with full Flutter error diagnostics.
///
/// Only the defaults for [format] and [output] differ; the sink is the same [ConsoleSink],
/// including silence in a release build ([buildMode]) without [printInRelease]. The default
/// format gets the same [buildMode] as the sink.
///
/// ```dart
/// RootLogger(sinks: [flutterConsoleSink()]);
/// ```
ConsoleSink flutterConsoleSink({
  LogEntryFormat? format,
  void Function(String text) output = _debugPrint,
  bool printInRelease = false,
  BuildMode buildMode = BuildMode.current,
}) => ConsoleSink(
  format: format ?? FlutterConsoleFormat(buildMode: buildMode),
  output: output,
  printInRelease: printInRelease,
  buildMode: buildMode,
);

/// [debugPrint] is read on every call: it gets replaced (for example, by flutter_test).
void _debugPrint(String text) => debugPrint(text);
