import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:log_trail_flutter/log_trail_flutter.dart';
import 'package:log_trail_flutter/widgets.dart';

class _StoreUnavailableException implements Exception {
  const _StoreUnavailableException();

  @override
  String toString() => 'store unavailable';
}

class _MemoryStore implements LogStore {
  _MemoryStore(Iterable<LogEntry> entries) {
    addAll(entries);
  }

  /// Entries in store order; ids are assigned in insertion order.
  final List<StoredLogEntry> entries = [];
  int _nextId = 1;
  final _changes = StreamController<LogStoreChange>.broadcast();
  final List<LogQuery> queries = [];

  /// While not completed, [queryEntries] does not return a result.
  Completer<void>? queryGate;

  /// Snapshot entries after [queryGate]: the query then also captures entries
  /// stored during loading.
  bool snapshotAfterGate = false;

  /// If set, [queryEntries] fails with this error.
  Exception? queryError;

  @override
  Stream<LogStoreChange> get changes => _changes.stream;

  /// Stores [entry] without an event, like content of past sessions.
  void add(LogEntry entry) => entries.add(StoredLogEntry(_nextId++, entry));

  void addAll(Iterable<LogEntry> entries) => entries.forEach(add);

  /// Resets the content without an event, like preparing past sessions.
  void reset() => entries.clear();

  @override
  Future<List<StoredLogEntry>> writeEntries(List<LogEntry> entries) async {
    final stored = [for (final entry in entries) StoredLogEntry(_nextId++, entry)];
    this.entries.addAll(stored);
    _changes.add(LogEntriesAdded(stored));
    return stored;
  }

  void remove(bool Function(LogEntry entry) test) {
    final removed = {
      for (final stored in entries)
        if (test(stored.entry)) stored.id,
    };
    entries.removeWhere((stored) => removed.contains(stored.id));
    _changes.add(LogEntriesRemovedById(removed));
  }

  void failChanges(Exception error) => _changes.addError(error);

  @override
  Future<LogPage> queryEntries([LogQuery query = const LogQuery()]) async {
    queries.add(query);
    final snapshot = [...entries];
    final gate = queryGate;
    if (gate != null) await gate.future;
    final queryError = this.queryError;
    if (queryError != null) throw queryError;
    return queryInMemory(snapshotAfterGate ? entries : snapshot, query);
  }

  @override
  Future<Set<String>> queryTags() async => {for (final stored in entries) ...stored.entry.tags};

  @override
  Future<void> clear() async {
    entries.clear();
    _changes.add(const AllLogEntriesRemoved());
  }

  @override
  Future<void> removeBefore(DateTime time) async {
    entries.removeWhere((stored) => stored.entry.time.isBefore(time));
    _changes.add(LogEntriesRemovedBefore(time));
  }

  @override
  Future<void> retainNewest(int count) async {
    if (entries.length <= count) return;
    final removed = entries.sublist(0, entries.length - count);
    entries.removeRange(0, removed.length);
    _changes.add(LogEntriesRemovedById({for (final stored in removed) stored.id}));
  }

  @override
  Future<void> close() => _changes.close();
}

String _germanLevelName(LogLevel level) => switch (level) {
  LogLevel.trace => 'Ablauf',
  LogLevel.debug => 'Fehlersuche',
  LogLevel.info => 'Hinweis',
  LogLevel.warning => 'Warnung',
  LogLevel.error => 'Fehler',
  LogLevel.fatal => 'Schwerwiegend',
};

LogEntry _entry(String message, int second, {LogLevel level = LogLevel.info}) =>
    LogEntry(time: DateTime(2026, 1, 1, 12, 0, second), level: level, message: message);

void main() {
  late _MemoryStore store;

  setUp(() => store = _MemoryStore([_entry('first', 1)]));
  tearDown(() => store.close());

  Future<void> pumpPage(WidgetTester tester, {int pageSize = 100}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LogViewerPage(reader: store, diagnostics: DiagnosticReporter.console, pageSize: pageSize),
      ),
    );
    await tester.pump();
  }

  testWidgets('a new entry appears without reloading the page', (tester) async {
    await pumpPage(tester);
    expect(find.text('first'), findsOneWidget);

    await store.writeEntries([_entry('second', 2)]);
    await tester.pump();

    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsOneWidget);
  });

  testWidgets('removed entries disappear from the list', (tester) async {
    store.add(_entry('second', 2));
    await pumpPage(tester);
    expect(find.text('first'), findsOneWidget);

    store.remove((entry) => entry.message == 'first');
    await tester.pump();
    await tester.pump();

    expect(find.text('first'), findsNothing);
    expect(find.text('second'), findsOneWidget);
  });

  testWidgets('an entry stored during loading is not lost', (tester) async {
    final gate = store.queryGate = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: LogViewerPage(reader: store, diagnostics: DiagnosticReporter.console),
      ),
    );

    await store.writeEntries([_entry('during load', 2)]);
    gate.complete();
    await tester.pump();
    await tester.pump();

    expect(find.text('first'), findsOneWidget);
    expect(find.text('during load'), findsOneWidget);
  });

  testWidgets('an entry also present in the load result is shown once', (tester) async {
    final gate = store.queryGate = Completer<void>();
    store.snapshotAfterGate = true;
    await tester.pumpWidget(
      MaterialApp(
        home: LogViewerPage(reader: store, diagnostics: DiagnosticReporter.console),
      ),
    );

    await store.writeEntries([_entry('during load', 2)]);
    gate.complete();
    await tester.pump();
    await tester.pump();

    expect(find.text('during load'), findsOneWidget);
  });

  testWidgets('queries the store for the first page, newest first', (tester) async {
    await pumpPage(tester, pageSize: 20);

    final query = store.queries.single;
    expect(query.newestFirst, isTrue);
    expect(query.limit, 20);
  });

  testWidgets('older entries load on scroll', (tester) async {
    store
      ..reset()
      ..addAll([for (var i = 0; i < 30; i++) _entry('m$i', i)]);
    await pumpPage(tester, pageSize: 10);
    expect(find.text('m29'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('m0'), 300, scrollable: find.byType(Scrollable).first);

    expect(find.text('m0'), findsOneWidget);
    expect(store.queries.where((q) => q.startAfter != null), isNotEmpty);
  });

  testWidgets(
    "desktop: the scrollbar shares the list's scroll position and fades out after a scroll without asserting",
    (tester) async {
      // On desktop the list does not attach to the route's PrimaryScrollController; a scrollbar left
      // on that controller has no position and asserts when its fade-out starts.
      store
        ..reset()
        ..addAll([for (var i = 0; i < 30; i++) _entry('m$i', i)]);
      await pumpPage(tester, pageSize: 10);

      await tester.drag(find.byType(Scrollable).first, const Offset(0, 200));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // The desktop scroll behavior adds scrollbars to the tiles' horizontal tag rows too.
      final scrollbar = tester.widget<Scrollbar>(
        find.ancestor(of: find.byType(ListView), matching: find.byType(Scrollbar)),
      );
      final list = tester.widget<ListView>(find.byType(ListView));
      expect(scrollbar.controller, isNotNull);
      expect(list.controller, same(scrollbar.controller));
    },
    variant: TargetPlatformVariant.desktop(),
  );

  testWidgets('the filter sheet opens even while the first page is loading', (tester) async {
    final gate = store.queryGate = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: LogViewerPage(reader: store, diagnostics: DiagnosticReporter.console),
      ),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.tap(find.byType(FloatingActionButton));
    // No pumpAndSettle: the loading indicator animates until the query completes.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.byType(LogFilterSheet), findsOneWidget);
    gate.complete();
    store.queryGate = null;
    await tester.pumpAndSettle();
  });

  testWidgets('the level filter is passed to the store query', (tester) async {
    store.add(_entry('boom', 2, level: LogLevel.error));
    await pumpPage(tester);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'error'));
    await tester.pump();
    await tester.pump();

    expect(store.queries.last.filter.levels, {LogLevel.error});
    // The bottom sheet covers the list: check entries in the tree, not visibility.
    expect(find.text('boom', skipOffstage: false), findsOneWidget);
    expect(find.text('first', skipOffstage: false), findsNothing);
  });

  testWidgets('search in the filter sheet applies after a typing pause', (tester) async {
    store.add(_entry('Request timeout', 2));
    await pumpPage(tester);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'TIMEOUT');
    await tester.pump(const Duration(milliseconds: 100));
    expect(store.queries.last.filter.text, isEmpty, reason: 'the pause has not elapsed yet');

    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(store.queries.last.filter.text, 'TIMEOUT');
    expect(find.text('Request timeout', skipOffstage: false), findsOneWidget);
    expect(find.text('first', skipOffstage: false), findsNothing);
  });

  testWidgets('text entered before closing the sheet is not lost', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'boom');
    Navigator.of(tester.element(find.byType(TextField))).pop();
    await tester.pumpAndSettle();

    expect(store.queries.last.filter.text, 'boom');
  });

  testWidgets('the remove filter button also clears the search', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LogViewerPage(
          reader: store,
          diagnostics: DiagnosticReporter.console,
          initialFilter: const LogFilter(text: 'nothing like this'),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Remove filter'));
    await tester.pump();

    expect(store.queries.last.filter.text, isEmpty);
    expect(find.text('first'), findsOneWidget);
  });

  testWidgets('no export button without onExport; with it, it receives the current filter', (tester) async {
    await pumpPage(tester);
    expect(find.byTooltip('Export'), findsNothing);

    final exported = <LogFilter>[];
    const filter = LogFilter(levels: {LogLevel.info});
    await tester.pumpWidget(
      MaterialApp(
        home: LogViewerPage(
          reader: store,
          diagnostics: DiagnosticReporter.console,
          initialFilter: filter,
          onExport: (_, filter) async => exported.add(filter),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byTooltip('Export'));
    await tester.pump();

    expect(exported, [filter]);
  });

  testWidgets('an export failure is shown on the page and goes to diagnostics', (tester) async {
    final diagnostics = <LogDiagnostic>[];
    await tester.pumpWidget(
      MaterialApp(
        home: LogViewerPage(
          reader: store,
          diagnostics: DiagnosticReporter(diagnostics.add),
          onExport: (_, _) async => throw StateError('disk full'),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Export'));
    await tester.pump();

    expect(find.text('Export failed: Bad state: disk full'), findsOneWidget);
    expect(diagnostics.single.message, 'LogViewerPage: export failed');
  });

  group('withController', () {
    testWidgets('the page shows the external controller state and does not dispose it', (tester) async {
      final controller = LogViewerController(store, diagnostics: DiagnosticReporter.console)
        ..setFilter(const LogFilter(text: 'first'));
      addTearDown(controller.dispose);

      await tester.pumpWidget(MaterialApp(home: LogViewerPage.withController(controller: controller)));
      await tester.pump();
      expect(find.text('first'), findsOneWidget);

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      expect(() => controller.addListener(() {}), returnsNormally, reason: 'the controller is not disposed');
      expect(store._changes.hasListener, isTrue, reason: 'the controller still watches the store');
    });

    testWidgets('state survives reopening the page without reloading', (tester) async {
      final controller = LogViewerController(store, diagnostics: DiagnosticReporter.console);
      addTearDown(controller.dispose);
      await tester.pumpWidget(MaterialApp(home: LogViewerPage.withController(controller: controller)));
      await tester.pump();
      final queriesBefore = store.queries.length;

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpWidget(MaterialApp(home: LogViewerPage.withController(controller: controller)));
      await tester.pump();

      expect(find.text('first'), findsOneWidget);
      expect(store.queries, hasLength(queriesBefore));
    });

    testWidgets('switching from an own controller to an external one disposes the own', (tester) async {
      final other = _MemoryStore([_entry('other', 1)]);
      addTearDown(other.close);
      final external = LogViewerController(other, diagnostics: DiagnosticReporter.console);
      addTearDown(external.dispose);

      await pumpPage(tester);
      expect(store._changes.hasListener, isTrue);

      await tester.pumpWidget(MaterialApp(home: LogViewerPage.withController(controller: external)));
      await tester.pump();

      expect(store._changes.hasListener, isFalse, reason: 'the own controller unsubscribed from the store');
      expect(find.text('other'), findsOneWidget);
    });
  });

  group('rebuilding the page with an own controller', () {
    testWidgets('with another store creates a new controller, keeping the current filter', (tester) async {
      final other = _MemoryStore([_entry('other', 1)]);
      addTearDown(other.close);
      const chosen = LogFilter(text: 'first');

      await tester.pumpWidget(
        MaterialApp(
          home: LogViewerPage(reader: store, diagnostics: DiagnosticReporter.console, initialFilter: chosen),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(
        MaterialApp(
          home: LogViewerPage(
            reader: other,
            diagnostics: DiagnosticReporter.console,
            initialFilter: const LogFilter(text: 'ignored'),
          ),
        ),
      );
      await tester.pump();

      expect(store._changes.hasListener, isFalse, reason: 'the previous controller is disposed');
      expect(other._changes.hasListener, isTrue);
      expect(other.queries.single.filter, chosen, reason: 'the current filter wins over the new initialFilter');
    });

    testWidgets('with another initialFilter and the same store applies it to the existing controller', (tester) async {
      await pumpPage(tester);
      final queriesBefore = store.queries.length;

      await tester.pumpWidget(
        MaterialApp(
          home: LogViewerPage(
            reader: store,
            diagnostics: DiagnosticReporter.console,
            initialFilter: const LogFilter(text: 'first'),
          ),
        ),
      );
      await tester.pump();

      expect(store._changes.hasListener, isTrue);
      expect(store.queries, hasLength(queriesBefore + 1));
      expect(store.queries.last.filter.text, 'first');
    });
  });

  testWidgets('initialFilter applies to the first query, the filter sheet keeps its conditions', (tester) async {
    const userId = LogField('test.user_id', LogCodec.string);
    final filter = LogFilter(attributes: [userId('42')]);
    store.add(
      LogEntry(
        time: DateTime(2026, 1, 1, 12, 0, 2),
        level: LogLevel.error,
        message: 'boom',
        attributes: LogAttributes([userId('42')]),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: LogViewerPage(reader: store, diagnostics: DiagnosticReporter.console, initialFilter: filter),
      ),
    );
    await tester.pump();

    expect(store.queries.single.filter, filter);
    expect(find.text('boom'), findsOneWidget);
    expect(find.text('first'), findsNothing, reason: 'without the attribute it does not match the preset');

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, 'error'));
    await tester.pump();

    expect(store.queries.last.filter, filter.copyWith(levels: {LogLevel.error}));
  });

  testWidgets('the remove filter button clears levels and tags, but not app conditions', (tester) async {
    const userId = LogField('test.user_id', LogCodec.string);
    final preset = LogFilter(attributes: [userId('42')]);
    await tester.pumpWidget(
      MaterialApp(
        home: LogViewerPage(
          reader: store,
          diagnostics: DiagnosticReporter.console,
          initialFilter: preset.copyWith(levels: {LogLevel.fatal}),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Nothing to display'), findsOneWidget);

    await tester.tap(find.text('Remove filter'));
    await tester.pump();

    expect(store.queries.last.filter, preset);
    expect(find.text('Remove filter'), findsNothing, reason: 'no user conditions remain');
  });

  testWidgets('a load error is shown with a retry option', (tester) async {
    store.queryError = const _StoreUnavailableException();
    await pumpPage(tester);

    expect(find.text('Failed to load logs'), findsOneWidget);
    expect(find.text('store unavailable'), findsOneWidget);

    store.queryError = null;
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();

    expect(find.text('first'), findsOneWidget);
  });

  testWidgets('an error in the changes stream does not reach the zone, the list is re-read', (tester) async {
    await pumpPage(tester);
    final queriesBefore = store.queries.length;

    store.failChanges(const _StoreUnavailableException());
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(store.queries.length, greaterThan(queriesBefore));
    expect(find.text('first'), findsOneWidget);
  });

  testWidgets('strings from the Localizations delegate are used in the list, filter and entry page', (tester) async {
    const strings = LogViewerStrings(
      title: 'Protokoll',
      levelFilter: 'Stufe:',
      level: 'Stufe',
      levelName: _germanLevelName,
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: [LogViewerStringsDelegate((_) => strings)],
        home: LogViewerPage(reader: store, diagnostics: DiagnosticReporter.console),
      ),
    );
    await tester.pump();
    expect(find.text('Protokoll'), findsOneWidget);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.text('Stufe:'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, 'Fehler'), findsOneWidget);
    Navigator.of(tester.element(find.text('Stufe:'))).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('first'));
    await tester.pumpAndSettle();
    expect(find.text('Stufe'), findsOneWidget);
    expect(find.text('Hinweis'), findsOneWidget);
  });

  testWidgets('the entry page opens as a page, not a dialog', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.text('first'));
    await tester.pumpAndSettle();

    final route = ModalRoute.of(tester.element(find.text('Body')));
    expect(route, isA<MaterialPageRoute<void>>());
    expect(route?.settings.name, LogViewerPage.detailsRouteName);
    expect(route?.settings.arguments, isA<StoredLogEntry>().having((e) => e.id, 'id', store.entries.single.id));
    expect(find.byType(BackButton), findsOneWidget);
  });

  testWidgets('hidden tags are not shown on the entry page either', (tester) async {
    store
      ..reset()
      ..add(LogEntry(time: DateTime(2026), level: LogLevel.info, message: 'first', tags: const {'shown', 'hidden'}));
    await tester.pumpWidget(
      MaterialApp(
        home: LogViewerPage(
          reader: store,
          diagnostics: DiagnosticReporter.console,
          isTagVisible: (tag) => tag != 'hidden',
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('first'));
    await tester.pumpAndSettle();

    expect(find.byType(LogEntryDetailsPage), findsOneWidget);
    expect(find.text('shown'), findsOneWidget);
    expect(find.text('hidden'), findsNothing);
  });

  testWidgets('onEntrySelected replaces the default navigation', (tester) async {
    final selected = <StoredLogEntry>[];
    await tester.pumpWidget(
      MaterialApp(
        home: LogViewerPage(
          reader: store,
          diagnostics: DiagnosticReporter.console,
          onEntrySelected: (_, entry) => selected.add(entry),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('first'));
    await tester.pumpAndSettle();

    expect(selected.map((e) => e.entry.message), ['first']);
    expect(selected.single.id, store.entries.single.id);
    expect(find.byType(LogEntryDetailsPage), findsNothing);
    expect(find.text('first'), findsOneWidget, reason: 'the list stays on screen');
  });

  testWidgets('closing the page during loading does not call setState after dispose', (tester) async {
    final gate = store.queryGate = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: LogViewerPage(reader: store, diagnostics: DiagnosticReporter.console),
      ),
    );

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    gate.complete();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('closing the page during a failed load does not call setState after dispose', (tester) async {
    final gate = store.queryGate = Completer<void>();
    store.queryError = const _StoreUnavailableException();
    await tester.pumpWidget(
      MaterialApp(
        home: LogViewerPage(reader: store, diagnostics: DiagnosticReporter.console),
      ),
    );

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    gate.complete();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
