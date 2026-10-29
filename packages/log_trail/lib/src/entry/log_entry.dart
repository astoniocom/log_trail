import 'package:collection/collection.dart';
import 'package:log_trail/src/entry/call_site.dart';
import 'package:log_trail/src/entry/log_attributes.dart';
import 'package:log_trail/src/entry/log_level.dart';
import 'package:meta/meta.dart';

/// Error attached to an entry, in a form that survives persistence
/// ([type] and [message]); the live [original] and [report] stay in-process.
@immutable
final class LogError {
  const LogError({
    required this.type,
    required this.message,
  }) : original = null,
       report = null;

  /// [report] is the platform's live report of this error, if any
  /// (e.g. `FlutterErrorDetails`); see [LogError.report].
  LogError.capture(Object error, {this.report})
    // The type name is for display and grouping; in an obfuscated build it is obfuscated too.
    : type = error.runtimeType.toString(),
      message = error.toString(),
      original = error;

  /// Type name of the original error.
  final String type;

  /// `toString()` of the original error.
  final String message;

  /// The original error object: present only on entries created in this
  /// process, `null` on entries read from a store ([LogEntry.withoutLiveObjects]).
  /// Not part of equality.
  final Object? original;

  /// The platform's full error report, if any: e.g. `FlutterErrorDetails` with
  /// context, library and diagnostics. Like [original], it lives only in this
  /// process, is not persisted and is not part of equality. A sink that can
  /// display such a report checks its type
  /// (`if (error.report case final FlutterErrorDetails d)`); the rest make do
  /// with [type], [message] and the entry's stack.
  final Object? report;

  @override
  bool operator ==(Object other) => other is LogError && other.type == type && other.message == message;

  @override
  int get hashCode => Object.hash(type, message);

  /// Type and text; the type is not repeated if the text already starts with
  /// it (as with [FormatException]).
  @override
  String toString() => message.startsWith(type) ? message : '$type: $message';
}

/// Log entry: what the facade passes to sinks and what stores persist and
/// return.
///
/// Everything except the live [LogError.original] and [LogError.report] is
/// persisted losslessly: an entry read from a store is `==` to the one
/// written. The storage format is not part of the entry: e.g. JSON is
/// `logEntryJson`.
///
/// For an entry built by the logger, [location] and [stackTraceText] are
/// computed on first access, so the first comparison or hashing of such an
/// entry parses the stack; entries read from a store do not. A modified entry
/// (processor, summary) is produced via [copyWith]: a not yet resolved call
/// site moves to the copy without parsing the stack.
@immutable
final class LogEntry {
  LogEntry({
    required DateTime time,
    required LogLevel level,
    required String message,
    Set<String> tags = const {},
    String? location,
    StackTrace? stackTrace,
    LogError? error,
    LogAttributes? attributes,
  }) : this.locatedBy(
         time: time,
         level: level,
         message: message,
         tags: tags,
         callSite: CallSite.known(location),
         stackTrace: stackTrace,
         error: error,
         attributes: attributes,
       );

  /// Entry with call site [callSite], which may be resolved from the stack on
  /// first access to [LogEntry.location] ([CallSite.fromStack]): stack parsing
  /// is costly, many sinks (console, dropping filters) never need the
  /// location, and a sink that does (`LogStoreSink` when serializing,
  /// `RepeatCollapsingSink` for the series key) reads it later, outside the
  /// logger call.
  @internal
  LogEntry.locatedBy({
    required this.time,
    required this.level,
    required this.message,
    Set<String> tags = const {},
    CallSite callSite = CallSite.unknown,
    this.stackTrace,
    this.error,
    LogAttributes? attributes,
  }) : tags = Set.unmodifiable(tags),
       _callSite = callSite,
       attributes = attributes ?? LogAttributes.empty;

  /// Moment of the event as passed in: UTC or local time. Entries compare by
  /// moment ([DateTime.isAtSameMomentAs]), not by representation: an entry
  /// read from a store in UTC equals the one written in local time. Convert to
  /// local time for display: `formatLogTimestamp`, `formatLogTimeOfDay` and
  /// `formatLogTime` do so themselves. A store and storage format
  /// (`logEntryJson`) should persist the moment in UTC: then after a time
  /// zone change or DST switch the entry read back points at the same moment.
  final DateTime time;
  final LogLevel level;
  final String message;
  final Set<String> tags;

  /// Call site in code; `null` if unknown. For entries built by the logger it
  /// is resolved from the stack on first access ([CallSite]) and is unknown
  /// when no location was given and none can be extracted from the stack,
  /// e.g. in a `--split-debug-info` build, where the stack is non-symbolic.
  String? get location => _callSite.value;
  final CallSite _callSite;

  final StackTrace? stackTrace;
  final LogError? error;

  /// Extra context of the entry: request body, parameters, etc. (see [LogField]).
  final LogAttributes attributes;

  /// Text of [stackTrace], computed once: `StackTrace.toString()` of a live
  /// stack is costly, and entries are compared, hashed and persisted by it.
  late final String? stackTraceText = stackTrace?.toString();

  /// Copy with the given fields replaced; omitted ones are kept. A call site
  /// not yet resolved from the stack moves to the copy as is and is resolved
  /// on first access to [location] on either entry, once for both: copying
  /// does not parse the stack. This lets a processor (`LogProcessor`) return a
  /// modified entry from the logger call without noticeable work in it.
  ///
  /// For [location], [stackTrace] and [error] a bare `null` would mean "keep",
  /// so they are passed as functions, as in `LogFilter.copyWith`:
  /// `copyWith(stackTrace: () => null)` removes the stack,
  /// `copyWith(error: () => LogError(...))` replaces the error. A passed
  /// [location], including `null`, cancels resolving the call site from the
  /// stack.
  LogEntry copyWith({
    DateTime? time,
    LogLevel? level,
    String? message,
    Set<String>? tags,
    String? Function()? location,
    StackTrace? Function()? stackTrace,
    LogError? Function()? error,
    LogAttributes? attributes,
  }) => LogEntry.locatedBy(
    time: time ?? this.time,
    level: level ?? this.level,
    message: message ?? this.message,
    tags: tags ?? this.tags,
    callSite: location == null ? _callSite : CallSite.known(location()),
    stackTrace: stackTrace == null ? this.stackTrace : stackTrace(),
    error: error == null ? this.error : error(),
    attributes: attributes ?? this.attributes,
  );

  /// Entry without references to live process objects: the original error
  /// ([LogError.original]), the platform report ([LogError.report]) and a
  /// stack whose call site is not yet resolved (it is resolved here). What
  /// survives persistence remains; the entry is `==` to the original. Returns
  /// the same entry if it holds no live objects.
  ///
  /// This is the form in which a store keeps and returns entries
  /// (`InMemoryLogStore`; an on-disk store gets the same from `logEntryJson`),
  /// and the form to keep entries in for long anywhere: the original error and
  /// report may reference anything, e.g. the widget tree via
  /// `FlutterErrorDetails`. Parses the stack, so not for the logger call.
  LogEntry withoutLiveObjects() {
    final error = this.error;
    final liveError = error != null && (error.original != null || error.report != null) ? error : null;
    if (liveError == null && !_callSite.isFromStack) return this;
    return copyWith(
      location: () => location,
      error: liveError == null ? null : () => LogError(type: liveError.type, message: liveError.message),
    );
  }

  /// Entries are equal by the content that survives persistence: the live
  /// [LogError.original] and [LogError.report] are excluded. For copies
  /// ([copyWith]) and entries sharing a stack, call site and stack compare by
  /// object, without parsing; parsing is needed only when comparing entries
  /// from different sources, e.g. a live one with one read from a store.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LogEntry &&
          other.time.isAtSameMomentAs(time) &&
          other.level == level &&
          other.message == message &&
          (identical(other._callSite, _callSite) || other.location == location) &&
          const SetEquality<String>().equals(other.tags, tags) &&
          other.error == error &&
          other.attributes == attributes &&
          (identical(other.stackTrace, stackTrace) || other.stackTraceText == stackTraceText);

  /// Computed once: the entry is immutable, and hashing the tag set and
  /// attributes is costly on repeated access (key in a [Set]).
  @override
  late final int hashCode = Object.hash(
    time.microsecondsSinceEpoch,
    level,
    message,
    const SetEquality<String>().hash(tags),
    location,
    stackTraceText,
    error,
    attributes,
  );

  @override
  String toString() => '[${level.name}] $message';
}
