import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:log_trail/storage.dart';
import 'package:log_trail_flutter/log_trail_flutter.dart';

void main() {
  test('the same Flutter error on every frame is stored once plus a repeat summary', () async {
    final store = InMemoryLogStore();
    final logger = RootLogger(sinks: [RepeatCollapsingSink(LogStoreSink(store))])..finishStartup();
    addTearDown(logger.close);
    final overflow = FlutterErrorDetails(
      exception: FlutterError('A RenderFlex overflowed by 42 pixels on the right.'),
      stack: StackTrace.current,
    );

    for (var frame = 0; frame < 60; frame++) {
      logger.recordFlutterError(overflow);
    }
    await logger.flush();

    expect(store.entries, hasLength(2));
    expect(store.entries.first.entry.error?.type, 'FlutterError');
    expect(store.entries.last.entry.message, startsWith('Error repeated 59 more time(s)'));
  });
}
