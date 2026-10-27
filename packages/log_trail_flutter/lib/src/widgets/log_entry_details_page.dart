import 'package:flutter/material.dart';
import 'package:log_trail/log_trail.dart';
import 'package:log_trail_flutter/src/widgets/log_viewer_strings.dart';
import 'package:log_trail_flutter/src/widgets/log_viewer_theme.dart';
import 'package:log_trail_flutter/src/widgets/separators.dart';

/// Page for a single entry: all fields, error, extra attributes and stack trace. Strings come
/// from [LogViewerStrings.of].
class LogEntryDetailsPage extends StatelessWidget {
  const LogEntryDetailsPage({
    required this.entry,
    this.isTagVisible,
    super.key,
  });

  final LogEntry entry;

  /// Which tags to show in the title; `null` means all.
  final TagPredicate? isTagVisible;

  @override
  Widget build(BuildContext context) {
    final error = entry.error;
    final stackTrace = entry.stackTrace;
    final visibleTags = entry.tags.whereVisible(isTagVisible).toList(growable: false);
    final theme = LogViewerTheme.of(context);
    final strings = LogViewerStrings.of(context);
    return Scaffold(
      appBar: AppBar(
        title: visibleTags.isEmpty
            ? Text(strings.entryTitle)
            : SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                child: Row(
                  children: withSeparators(
                    [for (final tag in visibleTags) Text(tag, style: TextStyle(color: theme.tagColor(tag)))],
                    const Text(' • '),
                  ),
                ),
              ),
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            ListTile(
              title: Text(strings.level),
              subtitle: Text(strings.levelName(entry.level)),
            ),
            ListTile(
              title: Text(strings.date),
              subtitle: SelectableText(formatLogTimestamp(entry.time)),
            ),
            ListTile(
              title: Text(strings.message),
              subtitle: SelectableText(entry.message),
            ),
            if (entry.location case final location?)
              ListTile(
                title: Text(strings.location),
                subtitle: SelectableText(location),
              ),
            if (error != null)
              ListTile(
                title: Text(strings.error),
                subtitle: SelectableText('$error'),
              ),
            for (final MapEntry(:key, :value) in entry.attributes.encoded.entries)
              ListTile(
                title: Text(key),
                subtitle: SelectableText('$value'),
              ),
            if (stackTrace != null)
              ListTile(
                title: Text(strings.stackTrace),
                subtitle: SelectableText('$stackTrace'),
              ),
          ],
        ),
      ),
    );
  }
}
