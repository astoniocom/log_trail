import 'package:log_trail/src/entry/log_attributes.dart';
import 'package:log_trail/src/entry/log_level.dart';
import 'package:log_trail/src/logger/log_call.dart';

/// Writing to the log: everything that writing code needs.
///
/// Modules accept a [Logger], not a `RootLogger`: they need neither sinks nor the buffer, and the interface is
/// easy to replace in tests. A module usually gets a child logger with its own tags ([child]). A logger whose
/// context can be changed is a [ContextualLogger]; `RootLogger` and child loggers implement it, but a module that
/// only writes does not need it.
///
/// The single write point is [submit] with the call's parameters in a [LogCall]; implementations and test
/// replacements concern only it. Application code writes through the convenience forms: [Logging.log] and
/// [Logging.recordError], the short per-level calls of [LevelLogging] (`log.warning('Slow response')`), and
/// [LazyLogging.logLazy] for expensive messages.
abstract interface class Logger {
  /// Accepts a log call: drops it below the threshold ([isEnabled]), adds its own tags and context, and passes it
  /// on toward the root, which builds the entry and dispatches it to the sinks.
  void submit(LogCall call);

  /// A logger for a module: adds [tags] and [attributes] to each of its entries.
  ///
  /// ```dart
  /// final log = logger.child(tags: {'network'});
  /// log.log('Request sent'); // tags: {network}
  /// ```
  ///
  /// Tags are merged with the call's tags. [attributes] become the child logger's context
  /// ([ContextualLogger.contextAttributes]); a value for the same field passed to the call takes precedence.
  ///
  /// [minLevel] is the module's own threshold; without it the parent's threshold applies. It may be below the
  /// root's default threshold (`RootLogger.defaultMinLevel`): that is how debug is enabled for one module without
  /// collecting debug entries of the whole application. It does not go below the root's floor
  /// (`RootLogger.floor`): the floor is an application guarantee, not a default.
  ///
  /// ```dart
  /// final root = RootLogger(defaultMinLevel: LogLevel.info);
  /// final network = root.child(tags: {'network'}, minLevel: LogLevel.debug);
  /// ```
  ///
  /// A child logger follows its parent: the parent's context, including context set later
  /// ([ContextualLogger.setContextAttribute]), applies to the child too.
  Logger child({
    Set<String> tags = const {},
    Iterable<LogAttribute<Object>> attributes = const [],
    LogLevel? minLevel,
  });

  /// Whether an entry of [level] passes the logger's threshold. Entries below the threshold are dropped, so there
  /// is no point in preparing expensive data for them:
  ///
  /// ```dart
  /// if (log.isEnabled(LogLevel.debug)) {
  ///   log.log('Response', level: LogLevel.debug, attributes: [LogField.details(jsonEncode(body))]);
  /// }
  /// ```
  ///
  /// If only the message is expensive, [LazyLogging.logLazy] suffices.
  bool isEnabled(LogLevel level);
}

/// Logging a message or an error: convenience forms of [Logger.submit].
extension Logging on Logger {
  /// [location] is the call site (`Member (uri:line:column)`) for an application wrapper that determines it
  /// itself; without it the call site is determined from [stackTrace] or, for warnings and above, from the current
  /// stack. [attributes] is additional context for the entry, see [LogField]; [LogField.details] is for free-form
  /// text.
  void log(
    String message, {
    LogLevel level = LogLevel.info,
    Set<String> tags = const {},
    String? location,
    StackTrace? stackTrace,
    DateTime? time,
    Iterable<LogAttribute<Object>> attributes = const [],
  }) => submit(
    LogCall.message(
      message,
      level: level,
      tags: tags,
      location: location,
      stackTrace: stackTrace,
      time: time,
      attributes: attributes,
    ),
  );

  /// Logs an error. Positional [error] and [stackTrace] allow passing the method as a handler to
  /// `runZonedGuarded`. `PlatformDispatcher.onError` expects a handler returning `bool`: Flutter has
  /// `recordPlatformError` for it.
  ///
  /// [message] is what the application was doing ("Failed to load profile"); defaults to the error's text.
  /// [level] is, for example, [LogLevel.fatal] for an error after which the application cannot continue, or
  /// [LogLevel.warning] for a handled one.
  ///
  /// [location] is the call site, as in [log]: without it, determined from [stackTrace] (where the error was
  /// thrown) or from the current stack. [report] is the platform's full error report (for example
  /// `FlutterErrorDetails`): sinks that can display it receive it in `LogError.report`.
  void recordError(
    Object error,
    StackTrace? stackTrace, {
    String? message,
    LogLevel level = LogLevel.error,
    Set<String> tags = const {},
    String? location,
    DateTime? time,
    Iterable<LogAttribute<Object>> attributes = const [],
    Object? report,
  }) => submit(
    LogCall.error(
      error,
      message: message,
      report: report,
      level: level,
      tags: tags,
      location: location,
      stackTrace: stackTrace,
      time: time,
      attributes: attributes,
    ),
  );
}

/// A [Logger] with mutable context: attributes added to every subsequent entry of this logger and its children.
///
/// These are `RootLogger` and child loggers. Code that only writes accepts a [Logger]; the logger's owner (the
/// application for the root, the module for its child) holds a [ContextualLogger] to set context: the user id
/// after sign-in, the id of a sync session.
abstract interface class ContextualLogger implements Logger {
  /// Attributes this logger adds to each of its entries: for a child, those passed to [child] and set via
  /// [setContextAttribute]; without the parent's attributes, which are added higher up the chain.
  Iterable<LogAttribute<Object>> get contextAttributes;

  /// Adds [attribute] to every subsequent entry of this logger and its children, for example the user id after
  /// sign-in on the root, or the sync session id on a module logger already handed out to its parts. Calling again
  /// for the same field replaces the value.
  ///
  /// A child logger's value for the same field takes precedence over the parent's, and a value passed to the log
  /// call takes precedence over context. Entries already built by now are not changed.
  ///
  /// For the context of one operation in one place in code, a child logger ([child]) is more convenient: it does
  /// not change state shared with other calls.
  void setContextAttribute(LogAttribute<Object> attribute);

  /// Removes the field from this logger's context, for example the user id after sign-out. The parent's field
  /// stays.
  void removeContextAttribute(LogField<Object> field);

  /// The child logger has context too: the module sets its own without touching the parent's.
  @override
  ContextualLogger child({
    Set<String> tags = const {},
    Iterable<LogAttribute<Object>> attributes = const [],
    LogLevel? minLevel,
  });
}

/// Logging by level: [trace], [debug], [info], [warning], [error], [fatal].
///
/// Each method is [Logging.log] at the given level; with the [error] parameter it is [Logging.recordError], where
/// the message describes what the application was doing:
///
/// ```dart
/// log.info('Signed in');
/// log.warning('Slow response', attributes: [elapsed(duration)]);
/// log.error('Failed to load profile', error: e, stackTrace: s);
/// ```
///
/// The call site cannot be given: it is determined from the stack. An application wrapper that passes its own
/// call site needs [Logging.log].
extension LevelLogging on Logger {
  /// Detailed tracing ([LogLevel.trace]): below the root's threshold by default, enabled for a module via
  /// `child(minLevel: LogLevel.trace)`. For an expensive message, [LazyLogging.logLazy] at this level.
  void trace(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Set<String> tags = const {},
    DateTime? time,
    Iterable<LogAttribute<Object>> attributes = const [],
  }) => _at(LogLevel.trace, message, error, stackTrace, tags, time, attributes);

  void debug(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Set<String> tags = const {},
    DateTime? time,
    Iterable<LogAttribute<Object>> attributes = const [],
  }) => _at(LogLevel.debug, message, error, stackTrace, tags, time, attributes);

  void info(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Set<String> tags = const {},
    DateTime? time,
    Iterable<LogAttribute<Object>> attributes = const [],
  }) => _at(LogLevel.info, message, error, stackTrace, tags, time, attributes);

  void warning(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Set<String> tags = const {},
    DateTime? time,
    Iterable<LogAttribute<Object>> attributes = const [],
  }) => _at(LogLevel.warning, message, error, stackTrace, tags, time, attributes);

  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Set<String> tags = const {},
    DateTime? time,
    Iterable<LogAttribute<Object>> attributes = const [],
  }) => _at(LogLevel.error, message, error, stackTrace, tags, time, attributes);

  /// An error after which the application cannot continue.
  void fatal(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Set<String> tags = const {},
    DateTime? time,
    Iterable<LogAttribute<Object>> attributes = const [],
  }) => _at(LogLevel.fatal, message, error, stackTrace, tags, time, attributes);

  void _at(
    LogLevel level,
    String message,
    Object? error,
    StackTrace? stackTrace,
    Set<String> tags,
    DateTime? time,
    Iterable<LogAttribute<Object>> attributes,
  ) => submit(
    error == null
        ? LogCall.message(message, level: level, tags: tags, stackTrace: stackTrace, time: time, attributes: attributes)
        : LogCall.error(
            error,
            message: message,
            level: level,
            tags: tags,
            stackTrace: stackTrace,
            time: time,
            attributes: attributes,
          ),
  );
}

/// Logging with a message computed only if the entry passes the threshold.
extension LazyLogging on Logger {
  /// Like [Logging.log], but [message] is called only if [level] passes the logger's threshold
  /// ([Logger.isEnabled]): expensive interpolation (`'Response: ${jsonEncode(body)}'`) is skipped for dropped
  /// entries. [attributes] are computed at the call; if they are expensive, check [Logger.isEnabled] yourself.
  void logLazy(
    String Function() message, {
    LogLevel level = LogLevel.info,
    Set<String> tags = const {},
    String? location,
    StackTrace? stackTrace,
    DateTime? time,
    Iterable<LogAttribute<Object>> attributes = const [],
  }) {
    if (!isEnabled(level)) return;
    submit(
      LogCall.message(
        message(),
        level: level,
        tags: tags,
        location: location,
        stackTrace: stackTrace,
        time: time,
        attributes: attributes,
      ),
    );
  }
}
