import 'package:log_trail/src/util/stack_frames.dart';
import 'package:stack_trace/stack_trace.dart';

/// [stack] in the uniform Dart VM format (`#0      Member (uri:line:column)`) regardless of platform:
/// web stack traces and async chains are converted to it.
///
/// A non-symbolic stack trace and one with unrecognized frames are returned as is: reformatting would
/// lose the addresses by which `flutter symbolize` restores an obfuscated stack trace.
String formatStackTrace(StackTrace stack) {
  final text = stack.toString();
  if (isNonSymbolicStack(text)) return text.trimRight();
  final frames = Trace.parse(text).frames;
  if (frames.any((frame) => frame is UnparsedFrame)) return text.trimRight();
  return [for (final (index, frame) in frames.indexed) '#${'$index'.padRight(7)}${formatFrame(frame)}'].join('\n');
}
