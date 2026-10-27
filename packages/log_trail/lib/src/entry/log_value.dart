import 'dart:collection';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

/// Value of an entry's extra attribute in a form any store can persist:
/// string, number, boolean, list or map.
///
/// Stores work only with [LogValue] and do not know the app's attribute types:
/// the field's `LogCodec` converts to the attribute type and back.
@immutable
sealed class LogValue {
  const LogValue();

  /// Parses a JSON-compatible value (e.g. the result of [jsonDecode]).
  ///
  /// Throws [FormatException] for `null` and non-JSON-compatible values.
  /// On web, integers and doubles in JSON are indistinguishable: `1.0` comes back as [LogInt].
  factory LogValue.fromJson(Object? json) => switch (json) {
    final String value => LogString(value),
    final int value => LogInt(value),
    final double value => LogDouble(value),
    final bool value => LogBool(value),
    final List<Object?> values => LogList([for (final value in values) LogValue.fromJson(value)]),
    final Map<String, Object?> values => LogMap({
      for (final MapEntry(:key, :value) in values.entries) key: LogValue.fromJson(value),
    }),
    // Type, not value: the exception may end up in diagnostics (LogDiagnostic).
    _ => throw FormatException('Not a log value: ${json.runtimeType}'),
  };

  /// JSON-compatible representation (for [jsonEncode]).
  Object toJson();

  /// JSON text of this value with map keys sorted at every level, so that
  /// equal values give equal text: two [LogMap]s with the same entries in a
  /// different order encode the same. Stores compare attribute values as this
  /// text (`LogAttributeCondition` on an indexed column), so every store must
  /// use this one definition both when writing and when querying.
  String toCanonicalJson() => jsonEncode(_canonical(toJson()));

  static Object _canonical(Object json) => switch (json) {
    final Map<String, Object> values => SplayTreeMap<String, Object>.of({
      for (final MapEntry(:key, :value) in values.entries) key: _canonical(value),
    }),
    final List<Object> values => [for (final value in values) _canonical(value)],
    _ => json,
  };
}

final class LogString extends LogValue {
  const LogString(this.value);

  final String value;

  @override
  String toJson() => value;

  @override
  bool operator ==(Object other) => other is LogString && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class LogInt extends LogValue {
  const LogInt(this.value);

  final int value;

  @override
  int toJson() => value;

  @override
  bool operator ==(Object other) => other is LogInt && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => '$value';
}

final class LogDouble extends LogValue {
  const LogDouble(this.value);

  final double value;

  @override
  double toJson() => value;

  @override
  bool operator ==(Object other) => other is LogDouble && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => '$value';
}

final class LogBool extends LogValue {
  // Single-value wrapper like LogString and LogInt: a parameter name would add nothing.
  // ignore: avoid_positional_boolean_parameters
  const LogBool(this.value);

  final bool value;

  @override
  bool toJson() => value;

  @override
  bool operator ==(Object other) => other is LogBool && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => '$value';
}

final class LogList extends LogValue {
  LogList(List<LogValue> values) : values = List.unmodifiable(values);

  final List<LogValue> values;

  @override
  List<Object> toJson() => [for (final value in values) value.toJson()];

  @override
  bool operator ==(Object other) => other is LogList && const ListEquality<LogValue>().equals(other.values, values);

  @override
  int get hashCode => const ListEquality<LogValue>().hash(values);

  @override
  String toString() => '$values';
}

final class LogMap extends LogValue {
  LogMap(Map<String, LogValue> values) : values = Map.unmodifiable(values);

  final Map<String, LogValue> values;

  @override
  Map<String, Object> toJson() => {for (final MapEntry(:key, :value) in values.entries) key: value.toJson()};

  @override
  bool operator ==(Object other) =>
      other is LogMap && const MapEquality<String, LogValue>().equals(other.values, values);

  @override
  int get hashCode => const MapEquality<String, LogValue>().hash(values);

  @override
  String toString() => '$values';
}
