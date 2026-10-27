/// The log page and its parts. Separate from `log_trail_flutter.dart` so that code without
/// screens does not depend on Material.
///
/// The ready-made page is `LogViewerPage`. A custom page can use the same parts:
/// `LogViewerController` (state, pages, filter), `LogEntryTile`, `LogEntryDetailsPage`,
/// `LogFilterSheet`, plus `LogViewerStrings` (strings via `Localizations`), `LogViewerTheme`
/// and `colorForTag` for colors.
///
/// The viewer reads the log via `LogReader` and works with `LogFilter` and `StoredLogEntry`, so
/// the library re-exports `package:log_trail/storage.dart`.
library;

export 'package:log_trail/storage.dart';
export 'package:log_trail_flutter/src/widgets/log_entry_details_page.dart';
export 'package:log_trail_flutter/src/widgets/log_entry_tile.dart';
export 'package:log_trail_flutter/src/widgets/log_filter_sheet.dart';
export 'package:log_trail_flutter/src/widgets/log_viewer_controller.dart';
export 'package:log_trail_flutter/src/widgets/log_viewer_page.dart';
export 'package:log_trail_flutter/src/widgets/log_viewer_strings.dart';
export 'package:log_trail_flutter/src/widgets/log_viewer_theme.dart';
export 'package:log_trail_flutter/src/widgets/tag_color.dart';
