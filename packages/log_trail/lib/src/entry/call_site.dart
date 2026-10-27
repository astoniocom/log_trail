import 'package:log_trail/src/util/stack_frames.dart';
import 'package:meta/meta.dart';
import 'package:stack_trace/stack_trace.dart';

/// Stack frame that does not count as the call site: the app's wrapper over
/// the logger. [uri] is the frame's file (`package:app/log.dart`), [member]
/// the function or method (`AppLog.warning`).
typedef WrapperFramePredicate = bool Function(Uri uri, String member);

/// Call site: the first frame of [stack] outside the `log_trail*` packages and
/// outside wrappers ([isWrapperFrame]), as `Member (uri:line:column)`.
///
/// SDK frames (`dart:`) are skipped if an app code frame follows them: for an
/// error thrown inside the SDK, the app line that called the SDK is more
/// useful. For a non-symbolic stack and unrecognized frames the result is
/// `null`, not a garbage string.
///
/// A `--split-debug-info` build produces a non-symbolic stack: the call site
/// is unknown for all entries, and the stack consists of addresses that only
/// `flutter symbolize` with the symbol files of the same build can restore.
/// `--obfuscate` alone keeps symbols: the call site is resolved, but with
/// obfuscated names.
///
/// Not exported: the entry's call site is `LogEntry.location`.
@internal
String? callSite(StackTrace stack, {WrapperFramePredicate? isWrapperFrame}) {
  final text = stack.toString();
  if (isNonSymbolicStack(text)) return null;

  final candidates = parseFrames(text).where(
    (frame) =>
        frame is! UnparsedFrame &&
        !_isOwnPackage(packageOf(frame)) &&
        !(isWrapperFrame?.call(frame.uri, frame.member ?? '') ?? false),
  );
  final frame = candidates.where((frame) => !frame.isCore).firstOrNull ?? candidates.firstOrNull;
  return frame == null ? null : formatFrame(frame);
}

bool _isOwnPackage(String? package) => package != null && (package == 'log_trail' || package.startsWith('log_trail_'));

/// Call site of an entry (`LogEntry.location`): known up front, or resolved
/// from the stack on first access to [value].
///
/// `StackTrace.toString()` and frame parsing are costly, and many sinks never
/// need the location; `LogEntry` holds this object instead of a string so that
/// parsing happens when the location is first needed, not in the logger call,
/// and is not repeated. Copies of an entry (`LogEntry.copyWith`) share one
/// object, so they share one parse.
@internal
sealed class CallSite {
  const CallSite();

  /// Location known up front: passed by the app's wrapper, read from a store;
  /// `null` means unknown.
  const factory CallSite.known(String? value) = _KnownCallSite;

  /// Location resolved from [stack] ([callSite]) on first access to [value].
  factory CallSite.fromStack(StackTrace stack, {WrapperFramePredicate? isWrapperFrame}) = _StackCallSite;

  /// Unknown location.
  static const CallSite unknown = CallSite.known(null);

  /// Location as `Member (uri:line:column)`; `null` if unknown.
  String? get value;

  /// Whether the object holds a stack for the location: then an entry kept
  /// for long (`LogEntry.withoutLiveObjects`) replaces it with a known value.
  bool get isFromStack;
}

final class _KnownCallSite extends CallSite {
  const _KnownCallSite(this.value);

  @override
  final String? value;

  @override
  bool get isFromStack => false;
}

final class _StackCallSite extends CallSite {
  _StackCallSite(this.stack, {this.isWrapperFrame});

  final StackTrace stack;
  final WrapperFramePredicate? isWrapperFrame;

  @override
  late final String? value = callSite(stack, isWrapperFrame: isWrapperFrame);

  @override
  bool get isFromStack => true;
}
