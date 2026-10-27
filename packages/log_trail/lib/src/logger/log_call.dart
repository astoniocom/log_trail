import 'package:log_trail/src/entry/log_attributes.dart';
import 'package:log_trail/src/entry/log_level.dart';
import 'package:meta/meta.dart';

/// Parameters of one log call (`Logger.submit`): what the calling code passed, before the `LogEntry` is built.
/// The default time, the call site from the stack and the error's stack are determined by the root at build time,
/// not by the call.
///
/// A call logs either a message ([LogCall.message]) or an error ([LogCall.error]), possibly with an explanatory
/// message and a platform report. There are no other calls: the constructors cannot produce a call with neither
/// message nor error, or a report without an error, so entry building does not check this in debug or release.
///
/// Loggers in the chain to the root do not inspect the call: a child only adds its tags ([withTags]) and context
/// ([withContext]) and passes it on. So a new entry field is added here and in the root's entry building, not in
/// every logger of the chain.
///
/// Usually created by the convenience methods of `Logger` (`log`, `recordError`, `info` and the other per-level
/// ones); directly by an application wrapper that needs a single entry point, or by a test logger replacement
/// that collects the accepted calls:
///
/// ```dart
/// logger.submit(LogCall.message('Signed in', tags: {'auth'}));
/// logger.submit(LogCall.error(error, stackTrace: stackTrace, message: 'Failed to load profile'));
/// ```
@immutable
final class LogCall {
  /// Logs a message, without an error.
  const LogCall.message(
    String this.message, {
    this.level = LogLevel.info,
    this.tags = const {},
    this.location,
    this.stackTrace,
    this.time,
    this.attributes = const [],
  }) : error = null,
       report = null;

  /// Logs an error. [message] is what the application was doing; without it the error's text becomes the entry's
  /// message. [report] is the platform's report on [error] (for example `FlutterErrorDetails`). The default level
  /// is [LogLevel.error].
  const LogCall.error(
    Object this.error, {
    this.message,
    this.report,
    this.level = LogLevel.error,
    this.tags = const {},
    this.location,
    this.stackTrace,
    this.time,
    this.attributes = const [],
  });

  /// A copy with different [tags] or [attributes] ([withTags], [withContext]).
  const LogCall._({
    required this.message,
    required this.level,
    required this.tags,
    required this.location,
    required this.stackTrace,
    required this.time,
    required this.attributes,
    required this.error,
    required this.report,
  });

  /// What the application was doing ("Failed to load profile"). `null` only for a call with [error]: then the
  /// error's text becomes the entry's message. The text is computed when the entry is built, that is, only for a
  /// call that passed the threshold.
  final String? message;

  final LogLevel level;

  /// The call's tags; tags of the chain's loggers are added to them ([withTags]).
  final Set<String> tags;

  /// Call site (`Member (uri:line:column)`) from an application wrapper that determines it itself; without it the
  /// call site is determined from [stackTrace] or, for warnings and above, from the current stack when the entry
  /// is built.
  final String? location;

  /// Stack: for an error, where it was thrown. Without it, an entry with [error] or of level [LogLevel.error] and
  /// above gets the current stack captured at build time.
  final StackTrace? stackTrace;

  /// Time of the event; `null` means the time the entry is built.
  final DateTime? time;

  /// Additional context for the entry ([LogField]); the context of the chain's loggers is added before it
  /// ([withContext]), the call's value takes precedence.
  final Iterable<LogAttribute<Object>> attributes;

  /// The error, if the call logs an error ([LogCall.error]). The entry keeps its type and text (`LogError`); the
  /// object itself remains in `LogError.original`.
  final Object? error;

  /// The platform's full report on [error] (for example `FlutterErrorDetails`) for sinks that can display it
  /// (`LogError.report`).
  final Object? report;

  /// A copy with [tags] in addition to its own: the tags of the logger the call passed through. The same call if
  /// there is nothing to add.
  LogCall withTags(Set<String> tags) {
    if (tags.isEmpty) return this;
    return _copy(tags: this.tags.isEmpty ? tags : {...tags, ...this.tags});
  }

  /// A copy with the context [attributes] before its own attributes: for a repeated field, the call's value (the
  /// last) stays. The same call if the context is empty.
  LogCall withContext(Iterable<LogAttribute<Object>> attributes) {
    if (attributes.isEmpty) return this;
    return _copy(attributes: [...attributes, ...this.attributes]);
  }

  LogCall _copy({Set<String>? tags, Iterable<LogAttribute<Object>>? attributes}) => LogCall._(
    message: message,
    level: level,
    tags: tags ?? this.tags,
    location: location,
    stackTrace: stackTrace,
    time: time,
    attributes: attributes ?? this.attributes,
    error: error,
    report: report,
  );

  @override
  String toString() => '[${level.name}] ${message ?? error}';
}
