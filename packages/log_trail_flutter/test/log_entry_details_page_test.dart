import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:log_trail_flutter/log_trail_flutter.dart';
import 'package:log_trail_flutter/widgets.dart';

LogEntry _entry(Set<String> tags) =>
    LogEntry(time: DateTime(2026, 1, 1, 12, 0, 5), level: LogLevel.info, message: 'message', tags: tags);

void main() {
  testWidgets('if all tags are hidden, the default title is shown', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LogEntryDetailsPage(entry: _entry({'internal'}), isTagVisible: (_) => false),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Logged event'), findsOneWidget);
    expect(find.text('internal'), findsNothing);
  });

  testWidgets('visible tags are separated, hidden ones are not shown', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LogEntryDetailsPage(entry: _entry({'network', 'internal', 'api'}), isTagVisible: (t) => t != 'internal'),
      ),
    );

    expect(find.text('network'), findsOneWidget);
    expect(find.text('api'), findsOneWidget);
    expect(find.text('internal'), findsNothing);
    expect(find.text(' • '), findsOneWidget);
  });

  testWidgets('the call site is shown only when known', (tester) async {
    await tester.pumpWidget(MaterialApp(home: LogEntryDetailsPage(entry: _entry(const {}))));
    expect(find.text('Code location'), findsNothing, reason: 'call site unknown, no empty row');

    await tester.pumpWidget(
      MaterialApp(
        home: LogEntryDetailsPage(
          entry: LogEntry(
            time: DateTime(2026),
            level: LogLevel.info,
            message: 'message',
            location: 'Api.fetch (package:app/api.dart:10:5)',
          ),
        ),
      ),
    );
    expect(find.text('Code location'), findsOneWidget);
    expect(find.text('Api.fetch (package:app/api.dart:10:5)'), findsOneWidget);
  });

  testWidgets('shows the full timestamp with date and milliseconds', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LogEntryDetailsPage(
          entry: LogEntry(time: DateTime(2026, 3, 4, 5, 6, 7, 89), level: LogLevel.info, message: 'message'),
        ),
      ),
    );

    expect(find.text('2026-03-04 05:06:07.089'), findsOneWidget);
  });
}
