import 'package:log_trail/log_trail.dart';
import 'package:log_trail/src/logger/log_context.dart';
import 'package:log_trail/src/logger/log_entry_factory.dart';
import 'package:test/test.dart';

const _userId = LogField('test.user_id', LogCodec.string);

LogEntry _create(
  LogEntryFactory factory, {
  LogLevel level = LogLevel.info,
  String? location,
  StackTrace? stackTrace,
  Object? error,
  Iterable<LogAttribute<Object>> attributes = const [],
}) => factory.create(
  error == null
      ? LogCall.message(
          'message',
          level: level,
          location: location,
          stackTrace: stackTrace,
          time: DateTime(2026),
          attributes: attributes,
        )
      : LogCall.error(
          error,
          message: 'message',
          level: level,
          location: location,
          stackTrace: stackTrace,
          time: DateTime(2026),
          attributes: attributes,
        ),
);

void main() {
  test('context is added to the entry, the call value wins', () {
    final factory = LogEntryFactory(context: LogContext([_userId('42')]));

    expect(_create(factory).attributes.get(_userId), '42');
    expect(_create(factory, attributes: [_userId('7')]).attributes.get(_userId), '7');

    factory.context.remove(_userId);
    expect(_create(factory).attributes.contains(_userId), isFalse);
    expect(factory.context.attributes, isEmpty);
  });

  group('field declaration check (debug)', () {
    test('second field with the same name and another codec: error when building the entry', () {
      const asString = LogField('test.conflict', LogCodec.string);
      const asInt = LogField('test.conflict', LogCodec.integer);
      final factory = LogEntryFactory(context: LogContext());
      _create(factory, attributes: [asString('x')]);

      expect(
        () => _create(factory, attributes: [asInt(1)]),
        throwsA(isA<AssertionError>().having((e) => '${e.message}', 'message', contains('test.conflict'))),
      );
    });

    test('identical declarations in different places are allowed; a conflict in context is detected too', () {
      const first = LogField('test.same', LogCodec.string);
      // Separate instance, not a constant: declarations in different modules are not identical.
      // ignore: prefer_const_constructors
      final second = LogField('test.same', LogCodec.string);
      const conflicting = LogField('test.same', LogCodec.integer);
      final factory = LogEntryFactory(context: LogContext([first('a')]));

      expect(() => _create(factory, attributes: [second('b')]), returnsNormally);
      expect(() => _create(factory, attributes: [conflicting(1)]), throwsA(isA<AssertionError>()));
    });

    test('check is per root: another root knows nothing about earlier fields', () {
      const asString = LogField('test.per_root', LogCodec.string);
      const asInt = LogField('test.per_root', LogCodec.integer);
      _create(LogEntryFactory(context: LogContext()), attributes: [asString('x')]);

      expect(() => _create(LogEntryFactory(context: LogContext()), attributes: [asInt(1)]), returnsNormally);
    });
  });

  test('call site is resolved for warnings, but not for info without a stack', () {
    final factory = LogEntryFactory(context: LogContext());

    expect(_create(factory).location, isNull);
    expect(_create(factory, level: LogLevel.warning).location, contains('log_entry_factory_test.dart'));
    expect(_create(factory, level: LogLevel.warning).stackTrace, isNull);
  });

  test('error without a stack gets the current stack', () {
    final entry = _create(
      LogEntryFactory(context: LogContext()),
      level: LogLevel.warning,
      error: StateError('boom'),
    );

    expect(entry.stackTrace.toString(), contains('log_entry_factory_test.dart'));
    expect(entry.error, const LogError(type: 'StateError', message: 'Bad state: boom'));
  });

  test('without a message the error text becomes the entry message; the report is kept in error.report', () {
    final factory = LogEntryFactory(context: LogContext());
    final error = StateError('boom');
    const report = 'platform report';

    final entry = factory.create(LogCall.error(error, report: report, level: LogLevel.info, time: DateTime(2026)));

    expect(entry.message, 'Bad state: boom');
    expect(entry.level, LogLevel.info, reason: 'level comes from the call, not from having an error');
    expect(entry.error?.original, same(error));
    expect(entry.error?.report, report);
  });

  test('call site is parsed on first access, not when building the entry', () {
    var frameChecks = 0;
    final factory = LogEntryFactory(
      context: LogContext(),
      isWrapperFrame: (_, _) {
        frameChecks++;
        return false;
      },
    );

    final entry = _create(factory, level: LogLevel.warning);
    expect(frameChecks, 0, reason: 'stack captured but not parsed');

    expect(entry.location, contains('log_entry_factory_test.dart'));
    expect(frameChecks, greaterThan(0));
    final checksAfterFirstRead = frameChecks;
    expect(entry.location, contains('log_entry_factory_test.dart'));
    expect(frameChecks, checksAfterFirstRead, reason: 'parsed once');
  });

  test('passed call site needs no stack parsing', () {
    var frameChecks = 0;
    final factory = LogEntryFactory(context: LogContext(), isWrapperFrame: (_, _) => frameChecks++ < 0);

    final entry = _create(factory, level: LogLevel.error, location: 'custom', stackTrace: StackTrace.current);

    expect(entry.location, 'custom');
    expect(frameChecks, 0);
  });

  test('isWrapperFrame skips application wrapper frames', () {
    final factory = LogEntryFactory(
      context: LogContext(),
      isWrapperFrame: (uri, member) => uri.path.endsWith('log_entry_factory_test.dart'),
    );

    expect(_create(factory, level: LogLevel.warning).location, isNot(contains('log_entry_factory_test.dart')));
  });
}
