import 'package:flutter_test/flutter_test.dart';
import 'package:log_trail_example/main.dart';
import 'package:log_trail_flutter/widgets.dart';

void main() {
  testWidgets('entries produced on the home page show up in the log viewer', (tester) async {
    logger
      ..addSink(LogStoreSink(store))
      ..finishStartup();
    await tester.pumpWidget(const ExampleApp());

    await tester.tap(find.text('Sign in (sets user id context)'));
    await tester.tap(find.text('Handled error with stack'));
    await tester.tap(find.byTooltip('Open the log'));
    await tester.pumpAndSettle();

    expect(find.byType(LogViewerPage), findsOneWidget);
    expect(find.text('Signed in'), findsOneWidget);
    expect(find.text('Failed to parse profile'), findsOneWidget);

    await logger.close();
  });
}
