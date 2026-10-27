import 'package:log_trail/log_trail.dart';
import 'package:log_trail/testing.dart';
import 'package:test/test.dart';

const _email = LogField('test.email', LogCodec.string);
const _body = LogField('test.body', LogCodec.raw);
const _attempt = LogField('test.attempt', LogCodec.integer);

final _redactor = LogRedactor(
  patterns: [RegExp(r'Bearer [\w.-]+'), RegExp(r'[\w.+-]+@[\w-]+\.[\w.]+')],
  removedFields: const [_body],
);

LogEntry _entry(
  String message, {
  LogError? error,
  List<LogAttribute<Object>> attributes = const [],
}) => LogEntry(
  time: DateTime(2026),
  level: LogLevel.error,
  message: message,
  tags: const {'auth'},
  location: 'Auth.login (package:app/auth.dart:1:1)',
  stackTrace: StackTrace.fromString('#0      main (file:///app.dart:1:1)'),
  error: error,
  attributes: LogAttributes(attributes),
);

void main() {
  group('LogRedactor', () {
    test('redacts message, error text and string attributes, including nested ones', () {
      final redacted = _redactor.process(
        _entry(
          'Login failed for bob@example.com',
          error: LogError.capture(StateError('Header Bearer abc.def is invalid')),
          attributes: [
            _email('bob@example.com'),
            _attempt(3),
            LogField.details('forwarded to ann@example.com'),
          ],
        ),
      );

      expect(redacted.message, 'Login failed for [REDACTED]');
      expect(redacted.error?.message, 'Bad state: Header [REDACTED] is invalid');
      expect(redacted.attributes.get(_email), '[REDACTED]');
      expect(redacted.attributes.get(_attempt), 3);
      expect(redacted.attributes.get(LogField.details), 'forwarded to [REDACTED]');
    });

    test('redacts strings inside LogList and LogMap', () {
      const payload = LogField('test.payload', LogCodec.raw);
      final redacted = _redactor.process(
        _entry(
          'm',
          attributes: [
            payload(
              LogMap({
                'users': LogList(const [LogString('bob@example.com'), LogInt(1)]),
              }),
            ),
          ],
        ),
      );

      expect(
        redacted.attributes.get(payload),
        LogMap({
          'users': LogList(const [LogString('[REDACTED]'), LogInt(1)]),
        }),
      );
    });

    test('removes removedFields fields entirely', () {
      final redacted = _redactor.process(
        _entry('m', attributes: [_body(const LogString('{"password": "x"}')), _attempt(1)]),
      );

      expect(redacted.attributes.contains(_body), isFalse);
      expect(redacted.attributes.get(_attempt), 1);
    });

    test('tags, call site, stack, time and level are unchanged', () {
      final entry = _entry('bob@example.com');
      final redacted = _redactor.process(entry);

      expect(redacted.tags, entry.tags);
      expect(redacted.location, entry.location);
      expect(redacted.stackTrace, same(entry.stackTrace));
      expect(redacted.time, entry.time);
      expect(redacted.level, entry.level);
    });

    test('live original and report are dropped if anything in the entry was redacted; otherwise kept', () {
      final report = Object();
      final error = LogError.capture(StateError('timeout'), report: report);
      final byError = _redactor.process(
        _entry('m', error: LogError.capture(StateError('bob@example.com'), report: report)),
      );
      final byMessage = _redactor.process(_entry('bob@example.com', error: error));
      final byAttribute = _redactor.process(_entry('m', error: error, attributes: [_body(const LogString('secret'))]));
      final intact = _redactor.process(_entry('nothing secret', error: error));

      for (final redacted in [byError, byMessage, byAttribute]) {
        expect(redacted.error?.original, isNull);
        expect(redacted.error?.report, isNull, reason: 'report is not redacted but carries data of the same event');
        expect(redacted.error?.type, 'StateError', reason: 'error type and text are kept');
      }
      expect(intact.error?.report, same(report));
      expect(intact.error?.original, same(error.original));
    });

    test('entry without matches is returned as is', () {
      final entry = _entry('nothing secret', attributes: [_attempt(1)]);

      expect(_redactor.process(entry), same(entry));
    });
  });

  test('redaction in the logger call does not parse the stack: call site resolves later, as for the original', () {
    var frameChecks = 0;
    final sink = RecordingLogSink();
    final logger = RootLogger(
      dispatch: LogDispatchPolicy.synchronous,
      sinks: [sink],
      processors: [_redactor],
      // Called only when parsing the stack for LogEntry.location.
      isWrapperFrame: (_, _) {
        frameChecks++;
        return false;
      },
    )..finishStartup();

    logger.warning('Login failed for bob@example.com');

    expect(sink.entries.single.message, 'Login failed for [REDACTED]');
    expect(frameChecks, 0, reason: 'call site was not resolved from the stack in the logger call');
    expect(sink.entries.single.location, contains('log_redactor_test.dart'));
    expect(frameChecks, greaterThan(0));
  });

  test('as root processor redacts before the startup buffer and all sinks, including ready-made asSink entries', () {
    final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, processors: [_redactor])
      ..log('early bob@example.com')
      ..asSink().add(_entry('from another logger bob@example.com'));
    final sink = RecordingLogSink();
    logger
      ..addSink(sink)
      ..finishStartup()
      ..recordError(StateError('token Bearer abc'), null);

    expect(sink.entries.map((e) => e.message), [
      'early [REDACTED]',
      'from another logger [REDACTED]',
      'Bad state: token [REDACTED]',
    ]);
  });
}
