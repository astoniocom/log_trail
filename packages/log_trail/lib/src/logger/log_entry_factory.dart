import 'package:log_trail/src/entry/call_site.dart';
import 'package:log_trail/src/entry/log_attributes.dart';
import 'package:log_trail/src/entry/log_entry.dart';
import 'package:log_trail/src/entry/log_level.dart';
import 'package:log_trail/src/logger/log_call.dart';
import 'package:log_trail/src/logger/log_context.dart';
import 'package:meta/meta.dart';

/// Builds `RootLogger` entries from call parameters ([LogCall]): time,
/// call site, stack trace, error and the shared context ([context]).
///
/// In debug, checks that no two different declarations go through this root
/// under one field name ([LogField.hasSameDeclaration]): their values would
/// overwrite each other in entries. The check is tied to the root, not the
/// isolate: it lives and is reset together with it.
@internal
final class LogEntryFactory {
  LogEntryFactory({required this.context, this.isWrapperFrame});

  /// Attributes added to every built entry.
  final LogContext context;

  /// Frames of the app's wrappers around the logger that do not count as the call site.
  final WrapperFramePredicate? isWrapperFrame;

  /// Fields whose values this root has already built, by name. Debug only.
  final Map<String, LogField<Object>> _knownFields = {};

  /// Builds an entry from [call].
  ///
  /// The call site is resolved for warnings, errors and entries with a stack
  /// trace: from [LogCall.stackTrace], or without it from the current stack.
  /// Here the stack is only captured; it is parsed on first access to
  /// [LogEntry.location], outside the logger call. For info and debug without
  /// a stack it is not resolved: even capturing a stack for every analytics
  /// event is pointless.
  ///
  /// The stack trace is kept if given; for entries with [LogCall.error] or a
  /// level of [LogLevel.error] and above without one, the current stack is
  /// taken. The error is stored as [LogError.capture]; without
  /// [LogCall.message] its text serves as the message.
  ///
  /// Call attributes go after the context: for a repeated field the call's value stays.
  LogEntry create(LogCall call) {
    final LogCall(:level, :location, :stackTrace, error: rawError) = call;
    final error = rawError == null ? null : LogError.capture(rawError, report: call.report);
    final isError = error != null || level >= LogLevel.error;
    final needsCurrentStack = stackTrace == null && (isError || (location == null && level >= LogLevel.warning));
    final locationStack = stackTrace ?? (needsCurrentStack ? StackTrace.current : null);
    return LogEntry.locatedBy(
      time: call.time ?? DateTime.now(),
      level: level,
      // Without a message there is an error (LogCall.error is the only constructor
      // without a required message); its text was already computed in LogError.capture.
      message: call.message ?? error!.message,
      tags: call.tags,
      callSite: switch ((location, locationStack)) {
        (final String location, _) => CallSite.known(location),
        (null, final StackTrace stack) => CallSite.fromStack(stack, isWrapperFrame: isWrapperFrame),
        (null, null) => CallSite.unknown,
      },
      stackTrace: stackTrace ?? (isError ? locationStack : null),
      error: error,
      attributes: _attributes(call.attributes),
    );
  }

  /// Context, then call attributes; the shared [LogAttributes.empty] when there
  /// is neither: most entries have no attributes.
  LogAttributes _attributes(Iterable<LogAttribute<Object>> attributes) {
    if (context.isEmpty) {
      if (attributes.isEmpty) return LogAttributes.empty;
      assert(_checkFieldDeclarations(attributes));
      return LogAttributes(attributes);
    }
    final all = [...context.attributes, ...attributes];
    assert(_checkFieldDeclarations(all));
    return LogAttributes(all);
  }

  /// Throws [AssertionError] if a field with another type or codec has already
  /// gone through this root under the name of one of [attributes].
  bool _checkFieldDeclarations(Iterable<LogAttribute<Object>> attributes) {
    for (final LogAttribute(:field) in attributes) {
      final known = _knownFields.putIfAbsent(field.name, () => field);
      if (identical(known, field) || known.hasSameDeclaration(field)) continue;
      throw AssertionError(
        'Log field "${field.name}" is declared twice: as ${known.runtimeType} with ${known.codec.runtimeType} '
        'and as ${field.runtimeType} with ${field.codec.runtimeType}. Their values would overwrite each other '
        'in entries; give one of them a unique name, for example with an app or package prefix.',
      );
    }
    return true;
  }
}
