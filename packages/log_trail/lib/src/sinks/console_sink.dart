import 'package:log_trail/src/entry/log_entry.dart';
import 'package:log_trail/src/format/console_log_format.dart';
import 'package:log_trail/src/format/log_entry_format.dart';
import 'package:log_trail/src/sinks/log_sink.dart';
import 'package:log_trail/src/util/build_mode.dart';

/// A sink that prints entries to the console: [format] produces the text
/// (by default [ConsoleLogFormat]: a line with the level icon, tags and
/// stack), [output] prints it (by default [print]). The look of an entry is
/// changed by the format, not by subclassing: for example,
/// `format: LogExportFormat.jsonLines` prints JSON for a server.
///
/// Prints synchronously, in [add]: `RootLogger` dispatches entries outside
/// the logger call, in the next event-loop turn, so the line appears in the
/// console slightly after the call, in entry order. To print right inside the
/// call (for example when stepping through in a debugger), give the root
/// `dispatch: LogDispatchPolicy.synchronous`. For Flutter there is
/// `flutterConsoleSink()`: the same sink with `debugPrint` and Flutter error
/// diagnostics by default.
///
/// In a release build ([buildMode]) it prints nothing by default
/// ([printInRelease]): there the output goes to the device's system log,
/// which is reachable via adb and ends up in crash reports, and entries may
/// contain user data. Silence is decided at construction ([isSilent]) and
/// does not depend on where [output] points.
///
/// Behavior is set by [format] and [output], not by subclassing: a different
/// entry look is a different format, a different destination is a different
/// [output].
final class ConsoleSink extends LogSink {
  ConsoleSink({
    this.format = const ConsoleLogFormat(),
    this.output = print,
    this.printInRelease = false,
    this.buildMode = BuildMode.current,
  });

  @override
  String get name => 'ConsoleSink';

  /// How to render an entry; `null` from the format means do not print it.
  final LogEntryFormat format;

  /// Where to print. The text may span multiple lines (stack).
  final void Function(String text) output;

  /// Whether to print in a release build. Off by default.
  /// When enabling, keep only what matters via `FilteringSink.minLevel` and
  /// mask user data via `LogRedactor` in `RootLogger.processors`.
  ///
  /// A command-line program built with `dart compile exe` is also a release
  /// build: it needs `printInRelease: true` to print.
  final bool printInRelease;

  /// Build mode that decides [isSilent]; by default the mode of this build
  /// ([BuildMode.current]). A different value is for a test that checks
  /// release behavior.
  final BuildMode buildMode;

  /// Whether the sink is silent: a release build without [printInRelease].
  bool get isSilent => buildMode.isRelease && !printInRelease;

  @override
  void onAdd(LogEntry entry) {
    if (isSilent) return;
    final text = format.format(entry);
    if (text != null) output(text);
  }
}
