import 'package:flutter/foundation.dart';
import 'package:log_trail/log_trail.dart';

/// Default tag of Flutter errors ([FlutterErrorLogging.recordFlutterError]). Carries the library
/// prefix ([libraryLogTagPrefix]), like all its tags.
const String flutterErrorLogTag = '${libraryLogTagPrefix}flutter';

/// Default tag of uncaught errors outside the framework ([FlutterErrorLogging.recordPlatformError]).
const String uncaughtErrorLogTag = '${libraryLogTagPrefix}uncaught';

/// Logging of Flutter errors ([FlutterErrorDetails]) and uncaught errors of the root isolate
/// through any [Logger]: the root, a module's child logger, or a test double.
///
/// A Flutter error becomes a regular entry with [LogEntry.error] whose [LogError.report] holds
/// the original [FlutterErrorDetails]: sinks that can show the full diagnostics (for example,
/// `flutterConsoleSink()`) take it from there, the rest need only the entry. Flutter errors
/// therefore pass through any sink wrappers ([RepeatCollapsingSink], [FilteringSink]) and the
/// early-phase buffer like any other entry.
///
/// ```dart
/// FlutterError.onError = logger.recordFlutterError;
/// PlatformDispatcher.instance.onError = logger.recordPlatformError;
/// ```
extension FlutterErrorLogging on Logger {
  /// Logs an uncaught error of the root isolate that neither Flutter nor app code caught (for
  /// example, in async code outside the framework). Fits [PlatformDispatcher.onError], which
  /// expects a `bool`, unlike [Logging.recordError].
  ///
  /// Always returns `true`: the error is logged, the engine need not apply its fallback output
  /// (printing to stderr). The log becomes the only place where the error is visible, so a
  /// console sink (`flutterConsoleSink()`) is needed in debug. If the engine's output is also
  /// wanted (the error then appears twice in the console), return `false` yourself:
  ///
  /// ```dart
  /// PlatformDispatcher.instance.onError = logger.recordPlatformError;
  /// // or, keeping the engine's output too:
  /// PlatformDispatcher.instance.onError = (e, s) {
  ///   logger.recordPlatformError(e, s);
  ///   return false;
  /// };
  /// ```
  ///
  /// [tags] defaults to [uncaughtErrorLogTag].
  bool recordPlatformError(
    Object error,
    StackTrace stackTrace, {
    LogLevel level = LogLevel.error,
    Set<String> tags = const {uncaughtErrorLogTag},
  }) {
    recordError(error, stackTrace, level: level, tags: tags);
    return true;
  }

  /// Logs a Flutter error; [message], [level] and [attributes] are as in [Logging.recordError].
  ///
  /// [tags] defaults to [flutterErrorLogTag]: the tag is set here, not in the sinks, so it is
  /// the same in all of them.
  void recordFlutterError(
    FlutterErrorDetails details, {
    String? message,
    LogLevel level = LogLevel.error,
    Set<String> tags = const {flutterErrorLogTag},
    DateTime? time,
    Iterable<LogAttribute<Object>> attributes = const [],
  }) => recordError(
    details.exception,
    details.stack,
    message: message,
    level: level,
    tags: tags,
    time: time,
    attributes: attributes,
    report: details,
  );
}
