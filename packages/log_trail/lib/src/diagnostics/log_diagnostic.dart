import 'package:log_trail/src/util/build_mode.dart';
import 'package:meta/meta.dart';

/// A message from the library about its own operation: a sink failure, a store
/// queue overflow, an entry logged after the logger was closed.
///
/// Such messages do not go into the log: with a broken sink or store they would
/// produce new entries and new failures. Instead they go to the
/// [DiagnosticReporter] given to the root (`RootLogger`), which passes it
/// to sinks when they are attached.
///
/// [message] is written by the library and carries no entry data. [error]
/// and [stackTrace] come from outside and may carry it: `SqliteException`
/// prints query parameters, which for a store write is the whole entry;
/// an exception from parsing another isolate's message carries its fragments.
/// Console output in release builds is therefore limited to [message] ([consoleText]).
@immutable
final class LogDiagnostic {
  const LogDiagnostic(this.message, {this.error, this.stackTrace});

  /// What happened, prefixed with the source name: `RootLogger: sink failed`.
  final String message;

  /// The error, if the message reports a failure.
  final Object? error;
  final StackTrace? stackTrace;

  /// Console text for build mode [buildMode]. In release, only [message]:
  /// the release console is the device's system log, readable via adb and
  /// included in crash reports, where `ConsoleSink` deliberately writes no
  /// entry data, while [error] and [stackTrace] may carry it.
  /// In debug and profile, the full [toString].
  String consoleText(BuildMode buildMode) => buildMode.isRelease ? message : toString();

  /// Message, error and stack trace in full.
  @override
  String toString() => [
    message,
    if (error != null) ': $error',
    if (stackTrace != null) '\n$stackTrace',
  ].join();
}

/// Receiver of [LogDiagnostic] ([DiagnosticReporter.handler]).
typedef DiagnosticHandler = void Function(LogDiagnostic diagnostic);

/// Default handler: prints to the console, the only output that does not lead
/// back into the log. In release builds ([buildMode]) prints only
/// [LogDiagnostic.message] ([LogDiagnostic.consoleText]).
///
/// [buildMode] defaults to this build's mode ([BuildMode.current]); a different
/// value is for tests. An app that needs the full text in release can use its
/// own handler: `DiagnosticReporter((d) => debugPrint('$d'))`.
void printDiagnostic(LogDiagnostic diagnostic, {BuildMode buildMode = BuildMode.current}) {
  // The only print call in the package: all other messages go through DiagnosticReporter.
  // ignore: avoid_print
  print(diagnostic.consoleText(buildMode));
}

/// Channel for the library's messages about its own operation ([LogDiagnostic]).
///
/// Set once on the root (`RootLogger(diagnostics: …)`), which passes it to
/// every sink on attach (`LogSink.attach`); wrappers pass it on to their
/// nested sinks. This way the handler given to the root also sees store
/// failures and timer-driven delivery failures, although they happen outside
/// the logger call. Library parts without a root (a standalone sink before
/// attach) use [console] by default.
///
/// ```dart
/// RootLogger(diagnostics: DiagnosticReporter((d) => Sentry.captureMessage('$d')));
/// ```
///
/// Do not log from [handler]: with a broken sink this would loop forever.
///
/// Channels with the same [handler] are equal. Widgets (`LogViewerPage`) use
/// equality to decide whether the channel changed, so pass them the same
/// instance (`logger.diagnostics`) instead of creating a new one in every `build`.
@immutable
final class DiagnosticReporter {
  const DiagnosticReporter(this.handler);

  /// Prints to the console ([printDiagnostic]): in release builds only the
  /// message, without the error and stack trace.
  static const DiagnosticReporter console = DiagnosticReporter(printDiagnostic);

  final DiagnosticHandler handler;

  @override
  bool operator ==(Object other) => other is DiagnosticReporter && other.handler == handler;

  @override
  int get hashCode => handler.hashCode;

  /// Passes [diagnostic] to [handler] without letting a handler failure reach
  /// the caller: logging must not crash the app. The failure and the original
  /// message are printed to the console as a last resort ([printDiagnostic]:
  /// in release builds only the messages, without errors and stack traces).
  ///
  /// Failures happen in timers and asynchronous code, where calling the handler
  /// directly would send its error to the zone, so sinks and log screens
  /// report only through this method.
  void report(LogDiagnostic diagnostic) {
    try {
      handler(diagnostic);
    } on Object catch (error, stackTrace) {
      printDiagnostic(LogDiagnostic('DiagnosticHandler failed', error: error, stackTrace: stackTrace));
      printDiagnostic(diagnostic);
    }
  }
}
