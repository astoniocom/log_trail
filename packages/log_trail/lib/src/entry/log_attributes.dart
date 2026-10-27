import 'package:collection/collection.dart';
import 'package:log_trail/src/entry/log_value.dart';
import 'package:meta/meta.dart';

/// Converts an attribute value to [LogValue] and back.
///
/// [decode] must restore a value equal to the original: whether an entry read
/// from a store matches the one written depends on it.
abstract interface class LogCodec<T extends Object> {
  static const LogCodec<String> string = _StringCodec();
  static const LogCodec<int> integer = _IntCodec();

  /// Also accepts [LogInt]: on web, JSON does not distinguish `1` from `1.0`.
  static const LogCodec<double> float = _DoubleCodec();
  static const LogCodec<bool> boolean = _BoolCodec();

  /// ISO 8601 with microsecond precision; the UTC flag is preserved.
  static const LogCodec<DateTime> dateTime = _DateTimeCodec();

  /// Number of microseconds.
  static const LogCodec<Duration> duration = _DurationCodec();

  /// Value as is: for structured data ([LogList], [LogMap]).
  static const LogCodec<LogValue> raw = _RawCodec();

  LogValue encode(T value);

  /// Throws [FormatException] if [encoded] does not match the codec's format.
  T decode(LogValue encoded);
}

/// Enum value by name (`name`): survives reordering and adding values.
///
/// ```dart
/// const screen = LogField('app.screen', EnumByNameCodec(Screen.values));
/// ```
final class EnumByNameCodec<T extends Enum> implements LogCodec<T> {
  const EnumByNameCodec(this.values);

  final List<T> values;

  @override
  LogValue encode(T value) => LogString(value.name);

  @override
  T decode(LogValue encoded) => switch (encoded) {
    LogString(:final value) => values.asNameMap()[value] ?? (throw FormatException('Unknown enum value: $value')),
    _ => throw _mismatch('enum name', encoded),
  };
}

/// Extra attribute of a log entry.
///
/// ```dart
/// const userId = LogField('app.user_id', LogCodec.string);
///
/// logger.log('Signed in', attributes: [userId('42')]);
/// final String? id = entry.attributes.get(userId);
/// ```
///
/// [name] is the attribute's key in the store, so it must be unique (prefixed
/// with the app or package: the library's own fields, like its tags, start
/// with `log_trail.`) and stable across versions: entries saved under the old
/// name are not found under the new one.
///
/// Fields with the same [name] count as one field: a value saved by one app
/// version is read by the next version's field even if its type changed
/// ([LogAttributes.get]). Hence two different fields with one name in one app
/// would overwrite each other's values in an entry, and a filter would find
/// the wrong entries. In debug, `RootLogger` detects this while building the
/// entry: identical declarations in different places are allowed; fields with
/// a different type or codec under one name are an error.
@immutable
final class LogField<T extends Object> {
  const LogField(this.name, this.codec);

  /// Free-form text context for an entry when a dedicated field is not worth it.
  static const LogField<String> details = LogField('log_trail.details', LogCodec.string);

  final String name;
  final LogCodec<T> codec;

  /// This attribute's value for an entry.
  LogAttribute<T> call(T value) => LogAttribute(this, value);

  /// Whether this is the same declaration as [other]: same name, same field
  /// and codec types. Declarations in different places are equal by
  /// description, not by [identical].
  bool hasSameDeclaration(LogField<Object> other) =>
      other.name == name && other.runtimeType == runtimeType && other.codec.runtimeType == codec.runtimeType;

  @override
  bool operator ==(Object other) => other is LogField<Object> && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => 'LogField($name)';
}

/// Value of attribute [field] for one entry. Usually created by calling the field: `userId('42')`.
@immutable
final class LogAttribute<T extends Object> {
  const LogAttribute(this.field, this.value);

  final LogField<T> field;
  final T value;

  LogValue encode() => field.codec.encode(value);

  /// Attributes of the same field with the same encoded value are equal.
  @override
  bool operator ==(Object other) => other is LogAttribute<Object> && other.field == field && other.encode() == encode();

  @override
  int get hashCode => Object.hash(field, encode());

  @override
  String toString() => '${field.name}: $value';
}

/// Extra attributes of an entry.
///
/// Attributes of an entry created in this process hold the original values.
/// Attributes read from a store ([LogAttributes.fromEncoded]) hold [LogValue]
/// and are converted to the field's type on read via [get]. So a store does
/// not need to know the app's fields, and an entry equals the original after
/// a save and read.
@immutable
final class LogAttributes {
  /// For a repeated field the last value wins.
  LogAttributes(Iterable<LogAttribute<Object>> attributes)
    : _slots = Map.unmodifiable({
        for (final attribute in attributes) attribute.field.name: _LiveSlot(attribute),
      });

  /// Attributes from the stored form ([encoded]): field name and its
  /// [LogValue], as returned by a store or produced by [LogAttributes.encoded].
  LogAttributes.fromEncoded(Map<String, LogValue> encoded)
    : _slots = Map.unmodifiable({
        for (final MapEntry(:key, :value) in encoded.entries) key: _EncodedSlot(value),
      });

  LogAttributes._(Map<String, _Slot> slots) : _slots = Map.unmodifiable(slots);

  static final LogAttributes empty = LogAttributes(const []);

  final Map<String, _Slot> _slots;

  /// Copy with [attributes] added to the existing ones; for a repeated field
  /// the new value wins. Existing attributes are kept as is, including those
  /// read from a store. For enriching an entry in a processor:
  /// `entry.copyWith(attributes: entry.attributes.withAll([buildVersion('1.2.0')]))`.
  /// To let an existing value take precedence, do not add it again:
  /// `withAll([if (!entry.attributes.contains(userId)) userId(id)])`.
  LogAttributes withAll(Iterable<LogAttribute<Object>> attributes) => LogAttributes._({
    ..._slots,
    for (final attribute in attributes) attribute.field.name: _LiveSlot(attribute),
  });

  bool get isEmpty => _slots.isEmpty;

  Iterable<String> get names => _slots.keys;

  bool contains(LogField<Object> field) => _slots.containsKey(field.name);

  /// Whether attribute [attribute] is present with the same value. Compares
  /// the encoded value ([LogValue]), so the result is the same for entries
  /// created in-process and read from a store.
  bool hasValue(LogAttribute<Object> attribute) => _slots[attribute.field.name]?.encoded == attribute.encode();

  /// The attribute's value, or `null` if absent.
  ///
  /// Throws [FormatException] if the stored value does not fit the field's
  /// codec (e.g. the attribute's type changed between app versions).
  T? get<T extends Object>(LogField<T> field) => switch (_slots[field.name]) {
    null => null,
    _LiveSlot(attribute: LogAttribute(value: final T value)) => value,
    final _Slot slot => field.codec.decode(slot.encoded),
  };

  /// Attributes in store form: field name and [LogValue].
  ///
  /// Computed once on first access: entries are compared and hashed by it,
  /// and the viewer does that often.
  late final Map<String, LogValue> encoded = Map.unmodifiable({
    for (final MapEntry(:key, :value) in _slots.entries) key: value.encoded,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LogAttributes && const MapEquality<String, LogValue>().equals(other.encoded, encoded);

  @override
  int get hashCode => const MapEquality<String, LogValue>().hash(encoded);

  @override
  String toString() => '$encoded';
}

sealed class _Slot {
  const _Slot();

  LogValue get encoded;
}

final class _LiveSlot extends _Slot {
  const _LiveSlot(this.attribute);

  final LogAttribute<Object> attribute;

  @override
  LogValue get encoded => attribute.encode();
}

final class _EncodedSlot extends _Slot {
  const _EncodedSlot(this.encoded);

  @override
  final LogValue encoded;
}

FormatException _mismatch(String expected, LogValue encoded) => FormatException('Expected $expected, got $encoded');

final class _StringCodec implements LogCodec<String> {
  const _StringCodec();

  @override
  LogValue encode(String value) => LogString(value);

  @override
  String decode(LogValue encoded) => switch (encoded) {
    LogString(:final value) => value,
    _ => throw _mismatch('string', encoded),
  };
}

final class _IntCodec implements LogCodec<int> {
  const _IntCodec();

  @override
  LogValue encode(int value) => LogInt(value);

  @override
  int decode(LogValue encoded) => switch (encoded) {
    LogInt(:final value) => value,
    _ => throw _mismatch('int', encoded),
  };
}

final class _DoubleCodec implements LogCodec<double> {
  const _DoubleCodec();

  @override
  LogValue encode(double value) => LogDouble(value);

  @override
  double decode(LogValue encoded) => switch (encoded) {
    LogDouble(:final value) => value,
    LogInt(:final value) => value.toDouble(),
    _ => throw _mismatch('double', encoded),
  };
}

final class _BoolCodec implements LogCodec<bool> {
  const _BoolCodec();

  @override
  LogValue encode(bool value) => LogBool(value);

  @override
  bool decode(LogValue encoded) => switch (encoded) {
    LogBool(:final value) => value,
    _ => throw _mismatch('bool', encoded),
  };
}

final class _DateTimeCodec implements LogCodec<DateTime> {
  const _DateTimeCodec();

  @override
  LogValue encode(DateTime value) => LogString(value.toIso8601String());

  @override
  DateTime decode(LogValue encoded) => switch (encoded) {
    LogString(:final value) => DateTime.tryParse(value) ?? (throw _mismatch('ISO 8601 date', encoded)),
    _ => throw _mismatch('ISO 8601 date', encoded),
  };
}

final class _DurationCodec implements LogCodec<Duration> {
  const _DurationCodec();

  @override
  LogValue encode(Duration value) => LogInt(value.inMicroseconds);

  @override
  Duration decode(LogValue encoded) => switch (encoded) {
    LogInt(:final value) => Duration(microseconds: value),
    _ => throw _mismatch('microseconds', encoded),
  };
}

final class _RawCodec implements LogCodec<LogValue> {
  const _RawCodec();

  @override
  LogValue encode(LogValue value) => value;

  @override
  LogValue decode(LogValue encoded) => encoded;
}
