import 'package:log_trail/src/entry/log_attributes.dart';
import 'package:log_trail/src/entry/log_entry.dart';
import 'package:log_trail/src/entry/log_value.dart';
import 'package:log_trail/src/logger/log_processor.dart';

/// Redaction of sensitive data (tokens, e-mail addresses, phone numbers) in an
/// entry before the sinks receive it: a root processor ([LogProcessor]).
///
/// ```dart
/// RootLogger(
///   processors: [
///     LogRedactor(
///       patterns: [RegExp(r'Bearer [\w.-]+'), RegExp(r'[\w.+-]+@[\w-]+\.[\w.]+')],
///       removedFields: [requestBody],
///     ),
///   ],
/// );
/// ```
///
/// Matches of [patterns] are replaced with [replacement] in the message, the
/// error text and string attribute values, including those nested in [LogList]
/// and [LogMap]. Fields in [removedFields] are removed from the entry entirely.
/// Tags, call site and stack trace are left unchanged: they come from code,
/// not from user data.
///
/// If anything in the entry was redacted, the live [LogError.original] and
/// [LogError.report] are dropped from its error: they cannot be redacted, yet
/// carry data of the same event (the original error text, platform
/// diagnostics). [LogError.type] and [LogError.message] remain. An entry with
/// nothing to redact is returned as is, with its report.
/// Never drops entries.
final class LogRedactor implements LogProcessor {
  const LogRedactor({this.patterns = const [], this.replacement = '[REDACTED]', this.removedFields = const []});

  final List<Pattern> patterns;
  final String replacement;
  final List<LogField<Object>> removedFields;

  @override
  LogEntry process(LogEntry entry) {
    final message = _redactText(entry.message);
    final error = entry.error;
    final errorMessage = error == null ? null : _redactText(error.message);
    final attributes = _redactAttributes(entry.attributes);
    final isUnchanged =
        message == entry.message && errorMessage == error?.message && identical(attributes, entry.attributes);
    if (isUnchanged) return entry;
    // copyWith rather than a new entry: a call site not yet resolved from the stack
    // is carried into the copy without parsing the stack in the logger call.
    return entry.copyWith(
      message: message,
      // A new LogError without the live original and report: they cannot be redacted.
      error: error == null ? null : () => LogError(type: error.type, message: errorMessage!),
      attributes: attributes,
    );
  }

  String _redactText(String text) {
    var result = text;
    for (final pattern in patterns) {
      result = result.replaceAll(pattern, replacement);
    }
    return result;
  }

  LogAttributes _redactAttributes(LogAttributes attributes) {
    if (attributes.isEmpty) return attributes;
    final removedNames = {for (final field in removedFields) field.name};
    final redacted = <String, LogValue>{};
    var isChanged = false;
    for (final MapEntry(:key, :value) in attributes.encoded.entries) {
      if (removedNames.contains(key)) {
        isChanged = true;
        continue;
      }
      final redactedValue = _redactValue(value);
      isChanged = isChanged || redactedValue != value;
      redacted[key] = redactedValue;
    }
    return isChanged ? LogAttributes.fromEncoded(redacted) : attributes;
  }

  LogValue _redactValue(LogValue value) => switch (value) {
    LogString(value: final text) => LogString(_redactText(text)),
    LogList(:final values) => LogList([for (final item in values) _redactValue(item)]),
    LogMap(:final values) => LogMap({
      for (final MapEntry(:key, :value) in values.entries) key: _redactValue(value),
    }),
    LogInt() || LogDouble() || LogBool() => value,
  };
}
