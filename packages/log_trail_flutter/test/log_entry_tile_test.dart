import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:log_trail_flutter/log_trail_flutter.dart';
import 'package:log_trail_flutter/widgets.dart';

void main() {
  final entry = LogEntry(
    time: DateTime(2026, 1, 1, 12, 0, 5),
    level: LogLevel.info,
    message: 'message',
    tags: const {'internal'},
  );

  testWidgets('if all tags are hidden, the time remains without a separator', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LogEntryTile(entry, isTagVisible: (_) => false)),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('2026-01-01 12:00:05'), findsOneWidget);
    expect(find.text(' • '), findsNothing);
  });

  testWidgets('a tap calls onTap and opens nothing by itself', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LogEntryTile(entry, onTap: () => taps++)),
      ),
    );

    await tester.tap(find.text('message'));
    await tester.pumpAndSettle();

    expect(taps, 1);
    expect(find.byType(LogEntryDetailsPage), findsNothing);
  });

  testWidgets('without onTap the tile does not react to taps', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: LogEntryTile(entry))));

    expect(tester.widget<ListTile>(find.byType(ListTile)).onTap, isNull);
  });
}
