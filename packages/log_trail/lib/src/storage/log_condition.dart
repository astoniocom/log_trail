import 'package:log_trail/src/entry/log_attributes.dart';
import 'package:log_trail/src/entry/log_entry.dart';
import 'package:log_trail/src/entry/log_level.dart';
import 'package:meta/meta.dart';

/// One selection condition for entries: `LogFilter` decomposes into them (`LogFilter.conditions`), and
/// an entry matches the filter if it matches all of its conditions.
///
/// The set of conditions is closed (`sealed`), and the meaning of each is defined here, in [matches].
/// A store with its own query language (SQL) translates conditions with an exhaustive `switch` without a
/// default branch: a new condition becomes a compile error there, not a silently skipped selection.
///
/// ```dart
/// for (final condition in query.filter.conditions) {
///   switch (condition) {
///     case LogAfterCondition(:final time): where.add('time > ${micros(time)}');
///     // … a branch per condition
///   }
/// }
/// ```
@immutable
sealed class LogCondition {
  const LogCondition();

  /// Whether the entry matches the condition: the reference for stores with their own query language
  /// (their result must agree with it).
  bool matches(LogEntry entry);
}

/// Entries strictly after [time].
final class LogAfterCondition extends LogCondition {
  const LogAfterCondition(this.time);

  final DateTime time;

  @override
  bool matches(LogEntry entry) => entry.time.isAfter(time);
}

/// Entries strictly before [time].
final class LogBeforeCondition extends LogCondition {
  const LogBeforeCondition(this.time);

  final DateTime time;

  @override
  bool matches(LogEntry entry) => entry.time.isBefore(time);
}

/// Entries of one of [levels] (a non-empty set).
final class LogLevelCondition extends LogCondition {
  const LogLevelCondition(this.levels);

  final Set<LogLevel> levels;

  @override
  bool matches(LogEntry entry) => levels.contains(entry.level);
}

/// Entries with the tag [tag].
final class LogTagCondition extends LogCondition {
  const LogTagCondition(this.tag);

  final String tag;

  @override
  bool matches(LogEntry entry) => entry.tags.contains(tag);
}

/// Entries whose attribute with the same field name as [attribute] equals its value. Encoded values are
/// compared ([LogAttribute.encode]), like `LogValue.==`: a store that compares them in serialized form
/// (JSON text in a column) must serialize canonically, with sorted map keys.
final class LogAttributeCondition extends LogCondition {
  const LogAttributeCondition(this.attribute);

  final LogAttribute<Object> attribute;

  @override
  bool matches(LogEntry entry) => entry.attributes.hasValue(attribute);
}

/// Entries where one of the texts ([searchableTexts]) contains the substring [text] (a non-empty string),
/// case-insensitively.
///
/// Case is folded by the rules of [String.toLowerCase], beyond ASCII too: SQLite's `LIKE` and `lower()`
/// fold only Latin letters and would give a different result for Cyrillic. So a SQL store does not decide
/// this condition in SQL: it narrows the candidates (an FTS5 trigram index over [searchedTexts], or
/// [prefilterTokens] when it has none) and decides with [matches] over the decoded entries
/// (`collectLogPage`, which first drops candidates by [mayMatchJson] without decoding them).
final class LogTextCondition extends LogCondition {
  /// Not const: [needle] and [prefilterTokens] are computed here once per condition, not in [matches] for
  /// every scanned entry.
  LogTextCondition(String text) : this._(text, text.toLowerCase());

  LogTextCondition._(this.text, this.needle)
    : prefilterTokens = _prefilterTokens(needle),
      _isCheckableInJson = needle.codeUnits.every(
        (unit) => unit >= 0x20 && unit != 0x22 && unit != 0x5C && unit != 0x3A,
      );

  final String text;

  /// [text] in lowercase: the substring searched for in [searchableTexts].
  final String needle;

  /// Whether [mayMatchJson] can decide anything: the needle has no character that JSON escapes (`"`, `\`,
  /// control characters) and no `:`, which joins error type and message in Dart only.
  final bool _isCheckableInJson;

  /// Fragments of [needle] that every entry matching this condition contains in the ASCII-lowercased JSON
  /// text of the entry (`logEntryJson`): a prefilter for a SQL store that keeps entries as JSON and can
  /// fold only ASCII, `instr(lower(entry), ?) > 0` per fragment. The prefilter only drops rows that
  /// cannot match; the store still decides with [matches].
  ///
  /// A fragment is a maximal run of printable ASCII without space, `"`, `\` and `:`: JSON escapes the
  /// quote and the backslash, anything beyond ASCII would need the folding SQL lacks, and the error text
  /// joins type and message with `: ` while JSON keeps them apart. Longest first, so that the most
  /// selective fragment is checked first. Empty for a needle without such characters (all Cyrillic): no
  /// prefilter, the store scans.
  ///
  /// Two exceptions to the guarantee: the Kelvin sign (K) and the dotted İ, which [String.toLowerCase]
  /// turns into ASCII `k` and `i` and SQL's `lower()` leaves as they are. An entry containing them can be
  /// dropped by the prefilter.
  final List<String> prefilterTokens;

  /// The entry texts searched for the substring, as written: the message and, if present, the error
  /// ([LogError.toString]). The single definition of where text search looks; a store that indexes text
  /// (FTS5) indexes these.
  static List<String> searchedTexts(LogEntry entry) {
    final error = entry.error;
    return [entry.message, if (error != null) '$error'];
  }

  /// [searchedTexts] lowercased: what [matches] searches.
  static List<String> searchableTexts(LogEntry entry) => [for (final text in searchedTexts(entry)) text.toLowerCase()];

  @override
  bool matches(LogEntry entry) => searchableTexts(entry).any((text) => text.contains(needle));

  /// Whether an entry whose `logEntryJsonText` is [entryJson] can satisfy this condition: the needle is
  /// searched in the lowercased JSON text, without decoding the entry, which costs several times more.
  /// Only drops rows that cannot match: the message and the error text appear verbatim in the JSON,
  /// except for the characters JSON escapes and the `: ` Dart puts between error type and message; a
  /// needle containing any of those is not checked here (`true`), [matches] decides after decoding.
  bool mayMatchJson(String entryJson) => !_isCheckableInJson || entryJson.toLowerCase().contains(needle);

  static List<String> _prefilterTokens(String needle) {
    final tokens = <String>{};
    final token = StringBuffer();
    for (final unit in needle.codeUnits) {
      if (unit > 0x20 && unit < 0x7F && unit != 0x22 && unit != 0x5C && unit != 0x3A) {
        token.writeCharCode(unit);
      } else if (token.isNotEmpty) {
        tokens.add(token.toString());
        token.clear();
      }
    }
    if (token.isNotEmpty) tokens.add(token.toString());
    return List.unmodifiable(tokens.toList()..sort((a, b) => b.length.compareTo(a.length)));
  }
}
