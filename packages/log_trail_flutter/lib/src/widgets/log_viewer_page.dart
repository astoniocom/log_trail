import 'dart:async';

import 'package:flutter/material.dart';
import 'package:log_trail/log_trail.dart';
import 'package:log_trail/storage.dart';
import 'package:log_trail_flutter/src/widgets/log_entry_details_page.dart';
import 'package:log_trail_flutter/src/widgets/log_entry_tile.dart';
import 'package:log_trail_flutter/src/widgets/log_filter_sheet.dart';
import 'package:log_trail_flutter/src/widgets/log_viewer_controller.dart';
import 'package:log_trail_flutter/src/widgets/log_viewer_strings.dart';
import 'package:log_trail_flutter/src/widgets/log_viewer_theme.dart';

/// Handler for tapping an entry in [LogViewerPage]: the entry with its store id, by which the
/// app can open it via its own route.
typedef LogEntrySelectedCallback = void Function(BuildContext context, StoredLogEntry entry);

/// Log export from [LogViewerPage] with the page's current filter.
typedef LogExportCallback = Future<void> Function(BuildContext context, LogFilter filter);

/// Log page: a list of entries, newest first, with loading more on scroll, search, a filter by
/// levels and tags, an entry page on tap, and export ([onExport]). State is managed by
/// [LogViewerController]; strings come from [LogViewerStrings.of], colors from
/// [LogViewerTheme.of].
///
/// The page is one widget over a controller; the constructor decides where the controller comes
/// from: [LogViewerPage.new] creates and owns its own over a store, [LogViewerPage.withController]
/// shows an external one. Switching from one to the other on rebuild disposes the own controller
/// and shows the external one, as if the page were closed and reopened.
class LogViewerPage extends StatelessWidget {
  /// Page with its own controller over [reader]: the controller is created when the page opens
  /// and disposed when it closes, along with the loaded entries and the selected filter.
  ///
  /// [pageSize] is how many entries to load at a time, [maxEntries] how many to keep while the
  /// page is open (see [LogViewerController]). [initialFilter] is the filter on opening: the user
  /// changes levels and tags in the filter sheet, the sheet preserves the other conditions (time
  /// range, attributes), so the page can be opened, for example, on one user's entries:
  /// `LogFilter(attributes: [userId('42')])`. [diagnostics] is where read and export failures
  /// go, usually [RootLogger.diagnostics]; there is no default, see
  /// [LogViewerController.diagnostics].
  LogViewerPage({
    required LogReader reader,
    required DiagnosticReporter diagnostics,
    this.isTagVisible,
    int pageSize = LogViewerController.defaultPageSize,
    int maxEntries = LogViewerController.defaultMaxEntries,
    LogFilter initialFilter = const LogFilter(),
    this.onEntrySelected,
    this.onExport,
    super.key,
  }) : _controllerSource = _OwnController(
         reader: reader,
         pageSize: pageSize,
         maxEntries: maxEntries,
         diagnostics: diagnostics,
         initialFilter: initialFilter,
       );

  /// Page over an external [controller]: loaded entries and the filter live as long as the
  /// controller, not the page (for example, between openings of the page), and in tests the
  /// controller can be prepared in advance. Page size, limit, filter and diagnostics channel are
  /// settings of the controller itself. The page does not dispose the controller: the caller
  /// owns it.
  LogViewerPage.withController({
    required LogViewerController controller,
    this.isTagVisible,
    this.onEntrySelected,
    this.onExport,
    super.key,
  }) : _controllerSource = _ExternalController(controller);

  /// Where the page's controller comes from: its own over a store, or external.
  final _ControllerSource _controllerSource;

  /// External controller ([LogViewerPage.withController]); `null` if the page creates its own.
  LogViewerController? get controller => switch (_controllerSource) {
    _ExternalController(:final controller) => controller,
    _OwnController() => null,
  };

  /// Where to read the log from ([LogViewerPage.new]); any [LogStore] works. The page does not
  /// close the store. `null` for a page over an external [controller].
  LogReader? get reader => switch (_controllerSource) {
    _OwnController(:final reader) => reader,
    _ExternalController() => null,
  };

  /// Route name of the entry page the page opens by default ([onEntrySelected] not set); the
  /// route's `arguments` is the [StoredLogEntry] itself, typed: a navigator observer or analytics
  /// can access its `id`.
  static const String detailsRouteName = 'log_details';

  /// Route name of the filter bottom sheet.
  static const String filterRouteName = 'log_filter';

  /// Which tags to show in the list, the filter and the entry page; `null` means all.
  final TagPredicate? isTagVisible;

  /// What to do on tapping an entry. By default opens [LogEntryDetailsPage] via [Navigator.push]
  /// with a [MaterialPageRoute] named [detailsRouteName]. Set your own handler if the app
  /// navigates differently (go_router, custom transitions) or shows the entry its own way.
  final LogEntrySelectedCallback? onEntrySelected;

  /// Log export with the page's current filter, for example to send to support; without it
  /// there is no export button. How to deliver the result (clipboard, share, file) is up to the
  /// app:
  ///
  /// ```dart
  /// onExport: (context, filter) async {
  ///   final text = StringBuffer();
  ///   await exportLog(reader, text, filter: filter);
  ///   await Clipboard.setData(ClipboardData(text: '$text'));
  /// },
  /// ```
  ///
  /// A failure is shown on the page ([LogViewerStrings.exportFailed]) and goes to
  /// [LogViewerController.diagnostics].
  final LogExportCallback? onExport;

  /// Different controller sources are different widgets: when the source changes, Flutter itself
  /// disposes the previous state (and the own controller with it) and creates a new one, with no
  /// case analysis in `didUpdateWidget`.
  @override
  Widget build(BuildContext context) => switch (_controllerSource) {
    _ExternalController(:final controller) => _ControllerView(controller: controller, page: this),
    final _OwnController own => _OwnedControllerView(settings: own, page: this),
  };
}

/// Where [LogViewerPage] gets its controller.
sealed class _ControllerSource {
  const _ControllerSource();
}

/// The page's own controller over [reader] with these settings.
final class _OwnController extends _ControllerSource {
  const _OwnController({
    required this.reader,
    required this.pageSize,
    required this.maxEntries,
    required this.diagnostics,
    required this.initialFilter,
  });

  final LogReader reader;
  final int pageSize;
  final int maxEntries;
  final DiagnosticReporter diagnostics;
  final LogFilter initialFilter;

  LogViewerController create(LogFilter filter) => LogViewerController(
    reader,
    diagnostics: diagnostics,
    pageSize: pageSize,
    maxEntries: maxEntries,
    filter: filter,
  );

  /// Whether [other] yields the same controller: at most [initialFilter] differs, and it is
  /// applied to the existing one.
  bool hasSameController(_OwnController other) =>
      other.reader == reader &&
      other.pageSize == pageSize &&
      other.maxEntries == maxEntries &&
      other.diagnostics == diagnostics;
}

/// External controller owned by the caller.
final class _ExternalController extends _ControllerSource {
  const _ExternalController(this.controller);

  final LogViewerController controller;
}

/// Page with its own controller: creates it from [settings], disposes it with itself, and
/// recreates it if the store or settings changed on rebuild. Shows [_ControllerView] over it.
class _OwnedControllerView extends StatefulWidget {
  const _OwnedControllerView({required this.settings, required this.page});

  final _OwnController settings;
  final LogViewerPage page;

  @override
  State<_OwnedControllerView> createState() => _OwnedControllerViewState();
}

class _OwnedControllerViewState extends State<_OwnedControllerView> {
  late LogViewerController _controller = widget.settings.create(widget.settings.initialFilter);

  @override
  void didUpdateWidget(_OwnedControllerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final settings = widget.settings;
    final previous = oldWidget.settings;
    if (settings.hasSameController(previous)) {
      if (settings.initialFilter != previous.initialFilter) _controller.setFilter(settings.initialFilter);
      return;
    }
    // Different store or settings: new controller. The current filter takes precedence over the
    // new initialFilter: the user may have changed it.
    final filter = _controller.filter;
    _controller.dispose();
    _controller = settings.create(filter);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _ControllerView(controller: _controller, page: widget.page);
}

/// Page over a controller: starts it ([LogViewerController.start]), shows its state, does not
/// own it. Display settings come from [page].
class _ControllerView extends StatefulWidget {
  const _ControllerView({required this.controller, required this.page});

  final LogViewerController controller;
  final LogViewerPage page;

  @override
  State<_ControllerView> createState() => _ControllerViewState();
}

class _ControllerViewState extends State<_ControllerView> {
  /// Distance to the end of the list at which the next page is loaded.
  static const _loadMoreExtent = 500.0;

  /// App theme with the [LogViewerTheme] extension for the list tiles: computed when
  /// dependencies change, not on every build.
  late ThemeData _listTheme;

  /// Shared by the list and its scrollbar. Without an explicit controller the scrollbar falls
  /// back to the route's `PrimaryScrollController`, which the list attaches to only on mobile
  /// platforms: on desktop the scrollbar then has no scroll position and asserts when it fades
  /// out after a scroll.
  final ScrollController _scrollController = ScrollController();

  LogViewerController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    // The app may have created an external controller without starting it.
    _controller.start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _listTheme = LogViewerTheme.resolveIn(Theme.of(context));
  }

  @override
  void didUpdateWidget(_ControllerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.controller, oldWidget.controller)) _controller.start();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _selectEntry(StoredLogEntry entry) {
    final onEntrySelected = widget.page.onEntrySelected;
    if (onEntrySelected != null) {
      onEntrySelected(context, entry);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: RouteSettings(name: LogViewerPage.detailsRouteName, arguments: entry),
        builder: (context) => LogEntryDetailsPage(entry: entry.entry, isTagVisible: widget.page.isTagVisible),
      ),
    );
  }

  /// The filter is applied immediately on every change ([LogViewerController.updateFilter]), so
  /// the sheet's result is not needed.
  Future<void> _displayFilter() async {
    await showModalBottomSheet<void>(
      context: context,
      // Otherwise the sheet with the search field does not rise above the keyboard.
      isScrollControlled: true,
      routeSettings: const RouteSettings(name: LogViewerPage.filterRouteName),
      builder: (context) {
        return LogFilterSheet(
          initialFilter: _controller.filter,
          availableTags: _controller.availableTags.whereVisible(widget.page.isTagVisible).toSet(),
          onFilterChanged: _controller.updateFilter,
        );
      },
    );
  }

  Future<void> _export(LogExportCallback onExport) async {
    try {
      await onExport(context, _controller.filter);
    } on Object catch (error, stack) {
      _controller.diagnostics.report(LogDiagnostic('LogViewerPage: export failed', error: error, stackTrace: stack));
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${LogViewerStrings.of(context).exportFailed}: $error')));
    }
  }

  Widget _buildFooter(LogViewerStrings strings) {
    final loadMoreError = _controller.loadMoreError;
    if (loadMoreError == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return ListTile(
      title: Text(strings.loadMoreFailed),
      subtitle: Text('$loadMoreError'),
      trailing: TextButton(onPressed: _controller.retryLoadMore, child: Text(strings.retry)),
    );
  }

  Widget _buildBody(LogViewerStrings strings) {
    final loadError = _controller.loadError;
    if (loadError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(strings.loadFailed),
            SelectableText('$loadError'),
            TextButton(onPressed: _controller.reload, child: Text(strings.retry)),
          ],
        ),
      );
    }

    final entries = _controller.entries;
    if (entries == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (entries.isEmpty) {
      final filter = _controller.filter;
      // Only what the user could select in the sheet is cleared; the app's conditions (time range,
      // attributes) remain.
      final hasUserFilter = filter.levels.isNotEmpty || filter.tags.isNotEmpty || filter.text.isNotEmpty;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(strings.empty),
            if (hasUserFilter)
              TextButton(
                onPressed: () => _controller.setFilter(filter.copyWith(levels: {}, tags: {}, text: '')),
                child: Text(strings.removeFilter),
              ),
          ],
        ),
      );
    }

    final hasMore = _controller.hasMore;
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.extentAfter < _loadMoreExtent) unawaited(_controller.loadMore());
        return false;
      },
      // Scrollbar picks its look by platform itself (Cupertino on iOS and macOS).
      child: Scrollbar(
        controller: _scrollController,
        child: ListView.builder(
          controller: _scrollController,
          reverse: true,
          itemBuilder: (context, index) {
            if (index == entries.length) return _buildFooter(strings);
            final entry = entries[index];
            return LogEntryTile(
              entry.entry,
              onTap: () => _selectEntry(entry),
              isTagVisible: widget.page.isTagVisible,
            );
          },
          itemCount: entries.length + (hasMore ? 1 : 0),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final strings = LogViewerStrings.of(context);
    return FocusTraversalGroup(
      policy: ReadingOrderTraversalPolicy(),
      child: Scaffold(
        appBar: AppBar(
          title: Text(strings.title),
          actions: [
            if (widget.page.onExport case final onExport?)
              IconButton(
                onPressed: () => unawaited(_export(onExport)),
                tooltip: strings.export,
                icon: Icon(Icons.adaptive.share),
              ),
          ],
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: _displayFilter,
          child: const Icon(
            Icons.filter_list_alt,
          ),
        ),
        // List theme with the LogViewerTheme extension: tiles find it ready-made.
        body: Theme(
          data: _listTheme,
          child: ListenableBuilder(
            listenable: _controller,
            builder: (context, _) => _buildBody(strings),
          ),
        ),
      ),
    );
  }
}
