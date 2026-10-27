import 'dart:async';

import 'package:flutter/material.dart';
import 'package:log_trail/log_trail.dart';
import 'package:log_trail/storage.dart';
import 'package:log_trail_flutter/src/widgets/log_viewer_controller.dart';
import 'package:log_trail_flutter/src/widgets/log_viewer_strings.dart';
import 'package:log_trail_flutter/src/widgets/log_viewer_theme.dart';

/// Bottom sheet for choosing a filter: text search, levels and tags. Every change is passed to
/// [onFilterChanged]: levels and tags immediately, text after [searchDelay] since the last
/// keystroke or when the sheet closes, if the pause has not yet elapsed.
///
/// The sheet edits only levels, tags and text and passes the owner not a ready filter but an
/// edit ([LogFilterUpdate]), which the owner applies to the filter in effect at that moment. The
/// other conditions (time range, attributes) stay as the owner has set them by then, even if it
/// changed them while the sheet was open; [initialFilter] only sets the initial selection.
/// Strings come from [LogViewerStrings.of].
///
/// `LogViewerPage` shows it via [showModalBottomSheet]; a custom page over [LogViewerController]
/// can do the same:
///
/// ```dart
/// showModalBottomSheet<void>(
///   context: context,
///   builder: (_) => LogFilterSheet(
///     initialFilter: controller.filter,
///     availableTags: controller.availableTags,
///     onFilterChanged: controller.updateFilter,
///   ),
/// );
/// ```
class LogFilterSheet extends StatefulWidget {
  const LogFilterSheet({
    required this.initialFilter,
    required this.availableTags,
    required this.onFilterChanged,
    this.searchDelay = const Duration(milliseconds: 300),
    super.key,
  });

  /// Filter at the moment of opening; its text, levels and tags are shown selected.
  final LogFilter initialFilter;

  /// Tags offered for selection (usually [LogViewerController.availableTags]).
  final Set<String> availableTags;

  /// Called on every change with an edit that carries the sheet's levels, tags and text onto
  /// the owner's current filter (usually [LogViewerController.updateFilter]).
  final void Function(LogFilterUpdate update) onFilterChanged;

  /// Pause in typing after which the search is applied: every letter is a new store query.
  final Duration searchDelay;

  @override
  State<LogFilterSheet> createState() => _LogFilterSheetState();
}

class _LogFilterSheetState extends State<LogFilterSheet> {
  late final Set<LogLevel> _levels = {...widget.initialFilter.levels};
  late final Set<String> _tags = {...widget.initialFilter.tags};
  late final TextEditingController _search = TextEditingController(text: widget.initialFilter.text);
  Timer? _searchTimer;

  @override
  void dispose() {
    _searchTimer?.cancel();
    _search.dispose();
    super.dispose();
  }

  /// Text typed right before closing the sheet is applied when the route pops, while the sheet is
  /// still in the tree: the owner's state must not be changed from [dispose], the tree is being
  /// torn down at that point.
  void _applyPendingSearch() {
    final timer = _searchTimer;
    if (timer == null || !timer.isActive) return;
    timer.cancel();
    _updateFilter();
  }

  void _updateFilter() {
    // Snapshots: the edit may be applied later than it is made.
    final levels = {..._levels};
    final tags = {..._tags};
    final text = _search.text.trim();
    widget.onFilterChanged((current) => current.copyWith(levels: levels, tags: tags, text: text));
  }

  void _onSearchChanged(String _) {
    _searchTimer?.cancel();
    _searchTimer = Timer(widget.searchDelay, _updateFilter);
  }

  /// Toggles [value] in [selected] and applies the filter.
  void _toggle<T>(Set<T> selected, T value, {required bool isSelected}) {
    setState(() => isSelected ? selected.add(value) : selected.remove(value));
    _updateFilter();
  }

  @override
  Widget build(BuildContext context) {
    final theme = LogViewerTheme.of(context);
    final strings = LogViewerStrings.of(context);
    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _applyPendingSearch();
      },
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _search,
                onChanged: _onSearchChanged,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: strings.search,
                  prefixIcon: const Icon(Icons.search),
                ),
              ),
              const SizedBox(height: 16),
              Text(strings.levelFilter),
              Wrap(
                spacing: 8,
                children: [
                  // FilterChip rather than ActionChip with opacity: the selection state is also
                  // visible to screen readers.
                  for (final level in LogLevel.values)
                    FilterChip(
                      selected: _levels.contains(level),
                      onSelected: (isSelected) => _toggle(_levels, level, isSelected: isSelected),
                      label: Text(strings.levelName(level)),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text(strings.tagFilter),
              Wrap(
                spacing: 8,
                children: [
                  for (final tag in widget.availableTags)
                    FilterChip(
                      selected: _tags.contains(tag),
                      onSelected: (isSelected) => _toggle(_tags, tag, isSelected: isSelected),
                      label: Text(tag, style: TextStyle(color: theme.tagColor(tag))),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
