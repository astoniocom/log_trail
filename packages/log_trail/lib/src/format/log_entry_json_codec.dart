import 'dart:convert';

import 'package:log_trail/src/entry/log_attributes.dart';
import 'package:log_trail/src/entry/log_entry.dart';
import 'package:log_trail/src/entry/log_level.dart';
import 'package:log_trail/src/entry/log_value.dart';
import 'package:meta/meta.dart';

/// [LogEntryJsonCodec]: `logEntryJson.encode(entry)`, `logEntryJson.decode(json)`.
const LogEntryJsonCodec logEntryJson = LogEntryJsonCodec();

/// [LogEntryJsonTextCodec]: `logEntryJsonText.encode(entry)`, `logEntryJsonText.decode(text)`.
const LogEntryJsonTextCodec logEntryJsonText = LogEntryJsonTextCodec();

/// [logEntryJson] as text: the entry as one JSON object serialized with [jsonEncode], and back.
///
/// The one place that turns an entry into the JSON text that stores keep in a column, the spool writes
/// as a line and `LogExportFormat.jsonLines` exports, so they all agree. [decode] throws
/// [FormatException] for text that is not a JSON object or not an entry.
final class LogEntryJsonTextCodec extends Codec<LogEntry, String> {
  const LogEntryJsonTextCodec();

  @override
  Converter<LogEntry, String> get encoder => const _LogEntryJsonTextEncoder();

  @override
  Converter<String, LogEntry> get decoder => const _LogEntryJsonTextDecoder();
}

final class _LogEntryJsonTextEncoder extends Converter<LogEntry, String> {
  const _LogEntryJsonTextEncoder();

  @override
  String convert(LogEntry input) => jsonEncode(logEntryJson.encode(input));
}

final class _LogEntryJsonTextDecoder extends Converter<String, LogEntry> {
  const _LogEntryJsonTextDecoder();

  @override
  LogEntry convert(String input) {
    final json = jsonDecode(input);
    if (json is! Map<String, Object?>) throw const FormatException('Not a log entry: a JSON object was expected');
    return logEntryJson.decode(json);
  }
}

/// A log entry in JSON-compatible form (for [jsonEncode]): the canonical format for stores that do not
/// need separate columns, for transfer between isolates and for log export.
///
/// Lossless except for live [LogError.original] and [LogError.report]: `decode(encode(entry)) == entry`.
/// Time is saved in UTC, so after a time zone change the read entry points to the same instant; time
/// without a zone is read as local. [decode] throws [FormatException] on corrupted data.
///
/// An entry carries the format version (`version`, currently [formatVersion]): the on-device log
/// survives app updates, and [decode] reads entries of all previous versions by their version instead of
/// guessing from the contents: a previous-version map first passes the [upgrades] steps up to the
/// current form, and only that form is parsed by the decoder. Entries of a newer version than this build
/// knows (a log written after an update and read after a rollback) are rejected with [FormatException].
final class LogEntryJsonCodec extends Codec<LogEntry, Map<String, Object?>> {
  const LogEntryJsonCodec();

  /// The format version written by [encode]: the number of steps in [upgrades]. It cannot be raised
  /// without adding a step.
  static int get formatVersion => upgrades.length;

  /// The format ladder: `upgrades[i]` converts a version `i` map into a version `i + 1` map, changing
  /// only what differs between them. A new format version is a new step at the end of the list, not an
  /// edit of the decoder: entries saved by previous app versions pass each step once when read. The
  /// codec test checks that an entry of every previous version is readable.
  ///
  /// - 0 → 1: an unknown call site was written as an empty string, now `null`; the `version` field was
  ///   added.
  @visibleForTesting
  static const List<Map<String, Object?> Function(Map<String, Object?> json)> upgrades = [_upgrade0To1];

  static Map<String, Object?> _upgrade0To1(Map<String, Object?> json) => {
    ...json,
    'location': switch (json['location']) {
      '' => null,
      final location => location,
    },
  };

  @override
  Converter<LogEntry, Map<String, Object?>> get encoder => const _LogEntryJsonEncoder();

  @override
  Converter<Map<String, Object?>, LogEntry> get decoder => const _LogEntryJsonDecoder();
}

final class _LogEntryJsonEncoder extends Converter<LogEntry, Map<String, Object?>> {
  const _LogEntryJsonEncoder();

  @override
  Map<String, Object?> convert(LogEntry input) {
    final error = input.error;
    return {
      'version': LogEntryJsonCodec.formatVersion,
      'time': input.time.toUtc().toIso8601String(),
      'level': input.level.name,
      'message': input.message,
      'tags': [...input.tags],
      'location': input.location,
      'stackTrace': input.stackTraceText,
      'error': error == null ? null : {'type': error.type, 'message': error.message},
      'attributes': {
        for (final MapEntry(:key, :value) in input.attributes.encoded.entries) key: value.toJson(),
      },
    };
  }
}

final class _LogEntryJsonDecoder extends Converter<Map<String, Object?>, LogEntry> {
  const _LogEntryJsonDecoder();

  @override
  LogEntry convert(Map<String, Object?> json) {
    final version = _read<int?>(json, 'version') ?? 0;
    if (version > LogEntryJsonCodec.formatVersion) {
      throw FormatException(
        'Unsupported log entry format version $version, this build reads up to ${LogEntryJsonCodec.formatVersion}',
      );
    }
    var input = json;
    for (var from = version; from < LogEntryJsonCodec.formatVersion; from++) {
      input = LogEntryJsonCodec.upgrades[from](input);
    }
    // Messages without field values: the exception goes to diagnostics, and from there to the release
    // build console or the app's handler, where entry fragments do not belong (LogDiagnostic).
    final time = DateTime.tryParse(_read(input, 'time'));
    if (time == null) throw const FormatException('Invalid log entry field "time": not an ISO 8601 date');
    final levelName = _read<String>(input, 'level');
    final level = LogLevel.values.asNameMap()[levelName];
    if (level == null) throw const FormatException('Invalid log entry field "level": unknown level name');
    final stackTrace = _read<String?>(input, 'stackTrace');
    final error = _read<Map<String, Object?>?>(input, 'error');

    return LogEntry(
      time: time,
      level: level,
      message: _read(input, 'message'),
      tags: {
        for (final tag in _read<List<Object?>>(input, 'tags'))
          if (tag is String)
            tag
          else
            throw FormatException('Invalid log entry field "tags": expected String, got ${tag.runtimeType}'),
      },
      location: _read<String?>(input, 'location'),
      stackTrace: stackTrace == null ? null : StackTrace.fromString(stackTrace),
      error: error == null ? null : LogError(type: _read(error, 'type'), message: _read(error, 'message')),
      attributes: LogAttributes.fromEncoded({
        for (final MapEntry(:key, :value) in _read<Map<String, Object?>>(input, 'attributes').entries)
          key: LogValue.fromJson(value),
      }),
    );
  }
}

/// The field [key] of type [T]. The exception text names the expected and actual type, not the value
/// (see [_LogEntryJsonDecoder.convert]).
T _read<T>(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is T) return value;
  throw FormatException('Invalid log entry field "$key": expected $T, got ${value.runtimeType}');
}
