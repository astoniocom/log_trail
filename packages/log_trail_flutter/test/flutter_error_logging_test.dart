import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:log_trail/testing.dart';
import 'package:log_trail_flutter/log_trail_flutter.dart';

const _route = LogField('test.route', LogCodec.string);

void main() {
  test('a Flutter error becomes an entry with FlutterErrorDetails in error.report', () {
    final sink = RecordingLogSink();
    final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink])..finishStartup();
    final details = FlutterErrorDetails(exception: StateError('boom'), stack: StackTrace.current);

    logger.recordFlutterError(details, attributes: [_route('/home')]);

    final entry = sink.entries.single;
    expect(entry.level, LogLevel.error);
    expect(entry.error, const LogError(type: 'StateError', message: 'Bad state: boom'));
    expect(entry.error?.original, same(details.exception));
    expect(entry.error?.report, same(details));
    expect(entry.stackTrace, same(details.stack));
    expect(entry.attributes.get(_route), '/home');
  });

  test('fits as FlutterError.onError', () {
    final sink = RecordingLogSink();
    final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink])..finishStartup();
    final FlutterExceptionHandler handler = logger.recordFlutterError;

    handler(const FlutterErrorDetails(exception: 'boom'));

    expect(sink.entries.single.error?.report, isA<FlutterErrorDetails>());
  });

  test('recordPlatformError fits as PlatformDispatcher.onError and reports the error as handled', () {
    final sink = RecordingLogSink();
    final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink])..finishStartup();
    final ErrorCallback handler = logger.child(tags: {'app'}).recordPlatformError;
    final stack = StackTrace.current;

    expect(handler(StateError('unhandled'), stack), isTrue);

    final entry = sink.entries.single;
    expect(entry.error?.type, 'StateError');
    expect(entry.level, LogLevel.error);
    expect(entry.tags, {'app', uncaughtErrorLogTag});
    expect(entry.stackTrace, same(stack));
  });

  test('to keep the engine output, the app returns false itself', () {
    final sink = RecordingLogSink();
    final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink])..finishStartup();
    bool handler(Object error, StackTrace stack) {
      logger.recordPlatformError(error, stack);
      return false;
    }

    final ErrorCallback onError = handler;
    expect(onError(StateError('unhandled'), StackTrace.current), isFalse);
    expect(sink.entries.single.error?.type, 'StateError');
  });

  test('a child logger records a Flutter error with its tags and the report', () {
    final sink = RecordingLogSink();
    const details = FlutterErrorDetails(exception: 'boom');
    RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink])
      ..finishStartup()
      ..child(tags: {'checkout'}).recordFlutterError(details);

    expect(sink.entries.single.tags, {'checkout', flutterErrorLogTag});
    expect(sink.entries.single.error?.report, same(details));
  });

  test('report is not persisted and does not take part in entry equality', () {
    final sink = RecordingLogSink();
    RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink])
      ..finishStartup()
      ..recordFlutterError(const FlutterErrorDetails(exception: 'boom'), time: DateTime(2026));
    final entry = sink.entries.single;

    final restored = logEntryJson.decode(logEntryJson.encode(entry));
    expect(restored.error?.report, isNull);
    expect(restored, entry);
  });

  test('early-phase Flutter errors are replayed with the original time and report', () {
    final eventTime = DateTime(2020, 5, 17, 12, 30);
    const details = FlutterErrorDetails(exception: 'early');
    final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous)..recordFlutterError(details, time: eventTime);

    final sink = RecordingLogSink();
    logger.addSink(sink);

    expect(sink.entries.single.time, eventTime);
    expect(sink.entries.single.error?.report, same(details));
  });

  test('Flutter errors pass through sink wrappers together with the report', () async {
    final inner = RecordingLogSink();
    const details = FlutterErrorDetails(exception: 'boom');
    final logger =
        RootLogger(
            dispatch: LogDispatchPolicy.synchronous,
            sinks: [RepeatCollapsingSink(FilteringSink.minLevel(inner, LogLevel.info))],
          )
          ..finishStartup()
          ..recordFlutterError(details);
    await logger.flush();

    expect(inner.entries.single.error?.report, same(details));
  });

  test('recordFlutterError accepts an explanatory message and a level', () {
    final sink = RecordingLogSink();
    RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink])
      ..finishStartup()
      ..recordFlutterError(
        FlutterErrorDetails(exception: StateError('layout'), stack: StackTrace.current),
        message: 'Checkout screen failed to build',
        level: LogLevel.fatal,
      );

    final entry = sink.entries.single;
    expect(entry.message, 'Checkout screen failed to build');
    expect(entry.level, LogLevel.fatal);
    expect(entry.error?.message, 'Bad state: layout');
  });

  test('Flutter errors are tagged flutter by default', () {
    final sink = RecordingLogSink();
    RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink])
      ..finishStartup()
      ..recordFlutterError(const FlutterErrorDetails(exception: 'boom'));

    expect(sink.entries.single.tags, {flutterErrorLogTag});
  });

  test('passed tags replace the default tag', () {
    final sink = RecordingLogSink();
    RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink])
      ..finishStartup()
      ..recordFlutterError(const FlutterErrorDetails(exception: 'boom'), tags: {'checkout'});

    expect(sink.entries.single.tags, {'checkout'});
  });

  test('without a stack in FlutterErrorDetails the call stack is used', () {
    final sink = RecordingLogSink();
    RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink])
      ..finishStartup()
      ..recordFlutterError(const FlutterErrorDetails(exception: 'no stack'));

    expect(sink.entries.single.location, contains('flutter_error_logging_test.dart'));
  });
}
