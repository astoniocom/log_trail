import 'package:collection/collection.dart';
import 'package:log_trail/src/entry/log_attributes.dart';
import 'package:log_trail/src/entry/log_entry.dart';
import 'package:log_trail/src/entry/log_level.dart';
import 'package:log_trail/src/storage/log_condition.dart';
import 'package:meta/meta.dart';

/// Selection conditions for entries: period, levels, tags, attributes, text. All conditions are
/// combined with AND; an empty condition accepts any entry.
///
/// Part of `LogQuery`; the viewer uses it as its filter too.
@immutable
final class LogFilter {
  const LogFilter({
    this.after,
    this.before,
    this.levels = const {},
    this.tags = const {},
    this.attributes = const [],
    this.text = '',
  });

  /// Only entries strictly after this moment.
  final DateTime? after;

  /// Only entries strictly before this moment.
  final DateTime? before;

  /// Only entries of these levels; an empty set means any.
  final Set<LogLevel> levels;

  /// Only entries that have all of these tags; an empty set means any.
  final Set<String> tags;

  /// Only entries where each of these attributes equals the given value
  /// (`LogFilter(attributes: [userId('42')])`); an empty list means any.
  ///
  /// The store compares encoded values: [LogAttribute.encode] of the condition against the stored value
  /// of the attribute with the same name, like `LogValue.==`. This keeps lookup by an indexed column
  /// independent of the app's field types. A store that compares serialized values (JSON text in a
  /// column) must serialize canonically, with sorted map keys: `LogMap` values are equal regardless of
  /// key order.
  final List<LogAttribute<Object>> attributes;

  /// Only entries whose message or error text ([LogError.toString]) contains this substring,
  /// case-insensitively; an empty string means any.
  ///
  /// Case is folded by the rules of [String.toLowerCase], so beyond ASCII too ([matches]). SQLite's
  /// `LIKE` and `lower()` fold only Latin letters and would give a different result for Cyrillic; a SQL
  /// store should keep the text lowercased at write time and search for the substring in it.
  final String text;

  /// No conditions at all.
  bool get isEmpty => conditions.isEmpty;

  /// The filter as a set of conditions: one per set field, one per tag and per attribute. A store with
  /// its own query language translates exactly these ([LogCondition]), and [matches] checks the same
  /// ones, so the meaning of the selection is defined in one place.
  List<LogCondition> get conditions => _conditions[this] ??= List.unmodifiable([
    if (after case final after?) LogAfterCondition(after),
    if (before case final before?) LogBeforeCondition(before),
    if (levels.isNotEmpty) LogLevelCondition(levels),
    for (final tag in tags) LogTagCondition(tag),
    for (final attribute in attributes) LogAttributeCondition(attribute),
    if (text.isNotEmpty) LogTextCondition(text),
  ]);

  /// [conditions] of each filter, built once: [matches] is called for every scanned entry. The cache
  /// lives outside the fields so the filter stays const.
  static final Expando<List<LogCondition>> _conditions = Expando();

  /// Whether the entry matches all conditions ([conditions]).
  bool matches(LogEntry entry) => conditions.every((condition) => condition.matches(entry));

  /// A copy with the given conditions replaced; omitted ones are kept.
  ///
  /// A condition is cleared with its empty value: `copyWith(levels: {}, text: '')`. [after] and [before]
  /// have no empty value (`null` means "keep"), so they are passed as a function returning the new value:
  /// `copyWith(after: () => weekAgo)`; to clear, `copyWith(after: () => null)`.
  LogFilter copyWith({
    DateTime? Function()? after,
    DateTime? Function()? before,
    Set<LogLevel>? levels,
    Set<String>? tags,
    List<LogAttribute<Object>>? attributes,
    String? text,
  }) => LogFilter(
    after: after == null ? this.after : after(),
    before: before == null ? this.before : before(),
    levels: levels ?? this.levels,
    tags: tags ?? this.tags,
    attributes: attributes ?? this.attributes,
    text: text ?? this.text,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LogFilter &&
          other.after == after &&
          other.before == before &&
          const SetEquality<LogLevel>().equals(other.levels, levels) &&
          const SetEquality<String>().equals(other.tags, tags) &&
          const ListEquality<LogAttribute<Object>>().equals(other.attributes, attributes) &&
          other.text == text;

  @override
  int get hashCode => Object.hash(
    after,
    before,
    const SetEquality<LogLevel>().hash(levels),
    const SetEquality<String>().hash(tags),
    const ListEquality<LogAttribute<Object>>().hash(attributes),
    text,
  );

  @override
  String toString() =>
      'LogFilter('
      '${[
        if (after != null) 'after: $after',
        if (before != null) 'before: $before',
        if (levels.isNotEmpty) 'levels: ${levels.map((level) => level.name).join(',')}',
        if (tags.isNotEmpty) 'tags: $tags',
        if (attributes.isNotEmpty) 'attributes: $attributes',
        if (text.isNotEmpty) 'text: "$text"',
      ].join(', ')}'
      ')';
}
