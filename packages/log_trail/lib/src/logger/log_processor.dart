import 'package:log_trail/src/entry/log_entry.dart';

/// One step of entry processing by the root (`RootLogger.processors`) before
/// the startup buffer and the sinks: redaction (`LogRedactor`), enrichment,
/// sampling. Applied in order to every entry the root dispatches, ready-made
/// ones from `RootLogger.asSink` included; each step sees the result of the
/// previous one.
///
/// `null` from [process] drops the entry. A failure drops it too, with a
/// diagnostic: the step could have been redaction, and passing the entry on
/// without it would be a leak.
///
/// Return the same entry if there is nothing to change, or a copy
/// ([LogEntry.copyWith]); do not read [LogEntry.location] without need, it
/// parses the stack trace and `copyWith` carries an unresolved one over. An
/// enriching step decides by attribute order whose value survives for a
/// field the entry already has (`LogAttributes` keeps the last): put a
/// process-wide value (build version) after the entry's attributes and a
/// value describing the event's source (user at the time) before them.
///
/// A processor may log into its own logger: the entry is dispatched after the
/// current one, through the processors too, and a response to that one is
/// dropped with a diagnostic, so logging on every entry yields one extra entry
/// per entry, not a recursion.
///
/// ```dart
/// RootLogger(
///   processors: [
///     LogRedactor(patterns: [RegExp(r'Bearer [\w.-]+')]),
///     LogProcessor((entry) => entry.copyWith(attributes: entry.attributes.withAll([buildVersion('1.2.0')]))),
///     LogProcessor((entry) => entry.level > LogLevel.debug || sampler.keep() ? entry : null),
///   ],
/// );
/// ```
abstract interface class LogProcessor {
  /// A processor from a function: for one-off processing without a class of its own.
  const factory LogProcessor(LogEntry? Function(LogEntry entry) process) = _FunctionProcessor;

  /// The entry after processing; `null` means drop it.
  LogEntry? process(LogEntry entry);
}

final class _FunctionProcessor implements LogProcessor {
  const _FunctionProcessor(this._process);

  final LogEntry? Function(LogEntry entry) _process;

  @override
  LogEntry? process(LogEntry entry) => _process(entry);
}
