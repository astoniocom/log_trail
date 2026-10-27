import 'package:flutter/material.dart';
import 'package:log_trail/log_trail.dart';
import 'package:log_trail_flutter/src/widgets/log_viewer_theme.dart';
import 'package:log_trail_flutter/src/widgets/separators.dart';

/// Entry list tile: level, message, tags and time.
///
/// Only displays the entry; what happens on tap is up to the list owner via [onTap] (for
/// example, `LogViewerPage` opens `LogEntryDetailsPage`). Without [onTap] the tile does not
/// react to taps.
class LogEntryTile extends StatelessWidget {
  const LogEntryTile(
    this.entry, {
    this.onTap,
    this.isTagVisible,
    super.key,
  });

  final LogEntry entry;
  final VoidCallback? onTap;

  /// Which tags to show under the message; `null` means all.
  final TagPredicate? isTagVisible;

  static IconData _levelIcon(LogLevel level) => switch (level) {
    LogLevel.trace => Icons.circle_outlined,
    LogLevel.debug => Icons.circle,
    LogLevel.info => Icons.info,
    LogLevel.warning => Icons.warning,
    LogLevel.error || LogLevel.fatal => Icons.error,
  };

  @override
  Widget build(BuildContext context) {
    final theme = LogViewerTheme.of(context);
    return Material(
      color: theme.levelBackground(entry.level),
      child: ListTile(
        onTap: onTap,
        leading: Icon(_levelIcon(entry.level), color: theme.levelColor(entry.level)),
        title: Text(entry.message, maxLines: 1),
        subtitle: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: withSeparators(
              [
                for (final tag in entry.tags.whereVisible(isTagVisible))
                  Text(tag, style: TextStyle(color: theme.tagColor(tag))),
                Text(
                  formatLogTime(entry.time),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              const Text(' • '),
            ),
          ),
        ),
      ),
    );
  }
}
