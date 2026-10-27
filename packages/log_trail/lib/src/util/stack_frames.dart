/// Parsing stack text into frames and back: the shared part of call site
/// resolution (`callSite`) and stack printing (`formatStackTrace`).
library;

import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:stack_trace/stack_trace.dart';

/// Non-symbolic stack (`--split-debug-info` build): frames made of addresses
/// that only `flutter symbolize` can restore.
@internal
bool isNonSymbolicStack(String text) => text.trimLeft().startsWith(_nonSymbolicHeader);

/// Frames of [text]. A Dart VM stack is parsed line by line on demand: the
/// call site is usually in the first frames, and a stack can be a hundred
/// frames long. Other formats (web) are parsed whole.
@internal
Iterable<Frame> parseFrames(String text) {
  final trimmed = text.trimLeft();
  if (!trimmed.startsWith('#')) return Trace.parse(text).frames;
  return LineSplitter.split(
    trimmed,
  ).where((line) => line.isNotEmpty && line != _asyncSuspension).map(Frame.parseVM);
}

/// Frame in Dart VM format: `Member (uri:line:column)`.
@internal
String formatFrame(Frame frame) {
  final line = frame.line;
  final column = frame.column;
  final position = [if (line != null) ':$line', if (line != null && column != null) ':$column'].join();
  return '${frame.member ?? '<unknown>'} (${frame.uri}$position)';
}

/// Package of a frame: from a `package:` URI, or on web (DDC) from an `http(s)://…/packages/<name>/…` address.
/// A `file:` path is not parsed: a `packages/` directory also occurs in an app monorepo.
@internal
String? packageOf(Frame frame) {
  final package = frame.package;
  if (package != null) return package;
  final uri = frame.uri;
  if (!uri.isScheme('http') && !uri.isScheme('https')) return null;
  final segments = uri.pathSegments;
  final index = segments.indexOf('packages');
  return index >= 0 && index + 1 < segments.length ? segments[index + 1] : null;
}

const _asyncSuspension = '<asynchronous suspension>';

/// First line of a non-symbolic Dart VM stack (`--dwarf-stack-traces`).
const _nonSymbolicHeader = '*** *** ***';
