import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:log_trail_flutter/log_trail_flutter.dart';
import 'package:log_trail_flutter/widgets.dart';

void main() {
  late List<LogFilter> applied;

  /// The owner's filter that sheet edits apply to.
  late LogFilter current;

  setUp(() {
    applied = [];
    current = const LogFilter();
  });

  void apply(LogFilterUpdate update) => applied.add(current = update(current));

  Widget sheet() => MaterialApp(
    home: Scaffold(
      body: LogFilterSheet(
        initialFilter: const LogFilter(),
        availableTags: const {'net'},
        onFilterChanged: apply,
      ),
    ),
  );

  testWidgets('text applies after a pause following the last input', (tester) async {
    await tester.pumpWidget(sheet());
    await tester.enterText(find.byType(TextField), 'boom');
    await tester.pump(const Duration(milliseconds: 100));
    expect(applied, isEmpty);

    await tester.pump(const Duration(milliseconds: 300));
    expect(applied.map((f) => f.text), ['boom']);
  });

  testWidgets('text that did not reach the pause applies when the sheet route closes', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                builder: (_) => LogFilterSheet(
                  initialFilter: const LogFilter(),
                  availableTags: const {},
                  onFilterChanged: apply,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'boom');

    // Close by tapping the barrier, as a user does.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(applied.map((f) => f.text), ['boom']);
  });

  testWidgets('removing the sheet from the tree without closing the route does not call onFilterChanged', (
    tester,
  ) async {
    await tester.pumpWidget(sheet());
    await tester.enterText(find.byType(TextField), 'boom');

    // The owner is tearing down the tree: its state must not change from dispose.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));

    expect(applied, isEmpty);
  });

  testWidgets('an edit carries only levels, tags and text to the current filter; other owner conditions are kept', (
    tester,
  ) async {
    final weekAgo = DateTime(2026, 3, 8);
    await tester.pumpWidget(sheet());

    // While the sheet is open, the owner changed a condition the sheet does not edit.
    current = current.copyWith(after: () => weekAgo);
    await tester.tap(find.widgetWithText(FilterChip, 'error'));
    await tester.pump();

    expect(applied.single.levels, {LogLevel.error});
    expect(applied.single.after, weekAgo, reason: 'the initialFilter snapshot did not overwrite the owner condition');
  });
}
