import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:log_trail/log_trail.dart';

/// Log viewer strings. English by default.
///
/// Viewer widgets (`LogViewerPage`, `LogFilterSheet`, `LogEntryDetailsPage`) find the strings
/// via [LogViewerStrings.of], like `MaterialLocalizations`, so they need not be passed to every
/// widget and are available in modal sheets and on pages opened via [Navigator] alike. Without
/// configuration the English strings are used. To translate, add [LogViewerStringsDelegate] to
/// the app's `localizationsDelegates`:
///
/// ```dart
/// MaterialApp(
///   localizationsDelegates: [
///     LogViewerStringsDelegate((locale) => switch (locale.languageCode) {
///       'de' => const LogViewerStrings(title: 'Protokoll', retry: 'Wiederholen'),
///       _ => const LogViewerStrings(),
///     }),
///     ...GlobalMaterialLocalizations.delegates,
///   ],
/// );
/// ```
@immutable
class LogViewerStrings {
  const LogViewerStrings({
    this.title = 'Logs',
    this.loadFailed = 'Failed to load logs',
    this.loadMoreFailed = 'Failed to load older logs',
    this.retry = 'Retry',
    this.empty = 'Nothing to display',
    this.removeFilter = 'Remove filter',
    this.search = 'Search',
    this.levelFilter = 'Log level:',
    this.tagFilter = 'Tags:',
    this.export = 'Export',
    this.exportFailed = 'Export failed',
    this.entryTitle = 'Logged event',
    this.level = 'Level',
    this.date = 'Date',
    this.message = 'Body',
    this.location = 'Code location',
    this.error = 'Error',
    this.stackTrace = 'Stack',
    this.levelName = _defaultLevelName,
  });

  /// Strings from [Localizations] for [context], or English if [LogViewerStringsDelegate] is not
  /// installed.
  factory LogViewerStrings.of(BuildContext context) =>
      Localizations.of<LogViewerStrings>(context, LogViewerStrings) ?? const LogViewerStrings();

  /// Title of the entry list.
  final String title;
  final String loadFailed;
  final String loadMoreFailed;
  final String retry;

  /// No entry matched the filter.
  final String empty;
  final String removeFilter;

  /// Hint in the entry text search field.
  final String search;
  final String levelFilter;
  final String tagFilter;

  /// Tooltip of the log export button and its failure message.
  final String export;
  final String exportFailed;

  /// Title of the entry page when it has no tags.
  final String entryTitle;
  final String level;
  final String date;
  final String message;
  final String location;
  final String error;
  final String stackTrace;

  /// Level name in the filter and on the entry page.
  final String Function(LogLevel level) levelName;
}

String _defaultLevelName(LogLevel level) => level.name;

/// [LogViewerStrings] delegate for `localizationsDelegates`: [stringsFor] picks the strings for
/// the app's locale. Supports any locale: [stringsFor] is responsible for the translation.
final class LogViewerStringsDelegate extends LocalizationsDelegate<LogViewerStrings> {
  const LogViewerStringsDelegate(this.stringsFor);

  final LogViewerStrings Function(Locale locale) stringsFor;

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<LogViewerStrings> load(Locale locale) => SynchronousFuture(stringsFor(locale));

  /// Reload when the picker function changes: a delegate with a different function yields
  /// different strings.
  @override
  bool shouldReload(LogViewerStringsDelegate old) => old.stringsFor != stringsFor;
}
