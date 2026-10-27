import 'package:log_trail/src/entry/log_attributes.dart';
import 'package:meta/meta.dart';

/// Attributes a logger adds to each of its entries, by field name: the context
/// of `RootLogger` and child loggers (`ContextualLogger.setContextAttribute`).
@internal
final class LogContext {
  LogContext([Iterable<LogAttribute<Object>> attributes = const []]) {
    attributes.forEach(set);
  }

  final Map<String, LogAttribute<Object>> _byName = {};

  Iterable<LogAttribute<Object>> get attributes => _byName.values;

  bool get isEmpty => _byName.isEmpty;

  /// Adds [attribute]; a repeated call for the same field replaces the value.
  void set(LogAttribute<Object> attribute) => _byName[attribute.field.name] = attribute;

  void remove(LogField<Object> field) => _byName.remove(field.name);
}
