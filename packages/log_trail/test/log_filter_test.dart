import 'dart:convert';

import 'package:log_trail/log_trail.dart';
import 'package:log_trail/storage.dart';
import 'package:test/test.dart';

const _userId = LogField('test.user_id', LogCodec.string);
const _attempt = LogField('test.attempt', LogCodec.integer);

LogEntry _at(int minute, {LogLevel level = LogLevel.info, Set<String> tags = const {}}) =>
    LogEntry(time: DateTime(2026, 1, 1, 12, minute), level: level, message: 'm$minute', tags: tags);

void main() {
  final t10 = DateTime(2026, 1, 1, 12, 10);
  final t20 = DateTime(2026, 1, 1, 12, 20);

  group('matches', () {
    test('without conditions any entry matches', () {
      expect(const LogFilter().matches(_at(0)), isTrue);
      expect(const LogFilter().isEmpty, isTrue);
    });

    test('after: strictly after the bound', () {
      final filter = LogFilter(after: t10);
      expect(filter.matches(_at(9)), isFalse);
      expect(filter.matches(_at(10)), isFalse);
      expect(filter.matches(_at(11)), isTrue);
    });

    test('before: strictly before the bound', () {
      final filter = LogFilter(before: t10);
      expect(filter.matches(_at(9)), isTrue);
      expect(filter.matches(_at(10)), isFalse);
      expect(filter.matches(_at(11)), isFalse);
    });

    test('both bounds form an open interval', () {
      final filter = LogFilter(after: t10, before: t20);
      expect(filter.matches(_at(10)), isFalse);
      expect(filter.matches(_at(15)), isTrue);
      expect(filter.matches(_at(20)), isFalse);
    });

    test('levels: any of the listed levels', () {
      const filter = LogFilter(levels: {LogLevel.warning, LogLevel.error});
      expect(filter.matches(_at(0)), isFalse);
      expect(filter.matches(_at(0, level: LogLevel.warning)), isTrue);
      expect(filter.matches(_at(0, level: LogLevel.error)), isTrue);
    });

    test('attributes: all listed attributes with these values', () {
      LogEntry withAttributes(List<LogAttribute<Object>> attributes) =>
          LogEntry(time: t10, level: LogLevel.info, message: 'm', attributes: LogAttributes(attributes));

      final filter = LogFilter(attributes: [_userId('42'), _attempt(3)]);
      expect(filter.matches(withAttributes([_userId('42'), _attempt(3)])), isTrue);
      expect(filter.matches(withAttributes([_userId('42'), _attempt(4)])), isFalse);
      expect(filter.matches(withAttributes([_userId('42')])), isFalse);
      expect(filter.matches(withAttributes([_userId('7'), _attempt(3)])), isFalse);
    });

    test('attributes also match entries read from the store', () {
      final restored = LogEntry(
        time: t10,
        level: LogLevel.info,
        message: 'm',
        attributes: LogAttributes.fromEncoded(const {'test.user_id': LogString('42')}),
      );

      expect(LogFilter(attributes: [_userId('42')]).matches(restored), isTrue);
    });

    test('text: case-insensitive substring of message or error text', () {
      LogEntry entry(String message, {Object? error}) => LogEntry(
        time: t10,
        level: LogLevel.error,
        message: message,
        error: error == null ? null : LogError.capture(error),
      );

      const filter = LogFilter(text: 'TimeOut');
      expect(filter.matches(entry('Request timeout')), isTrue);
      expect(filter.matches(entry('Request failed', error: const FormatException('read timeout'))), isTrue);
      expect(const LogFilter(text: 'formatexception').matches(entry('m', error: const FormatException('x'))), isTrue);
      expect(filter.matches(entry('Request failed')), isFalse);
      expect(const LogFilter().matches(entry('anything')), isTrue);
    });

    test('tags: all listed tags', () {
      const filter = LogFilter(tags: {'network', 'api'});
      expect(filter.matches(_at(0, tags: {'network'})), isFalse);
      expect(filter.matches(_at(0, tags: {'network', 'api', 'auth'})), isTrue);
    });
  });

  test('equality by value, including attributes', () {
    LogFilter make() =>
        LogFilter(after: t10, levels: const {LogLevel.error}, tags: const {'net'}, attributes: [_userId('42')]);

    expect(make(), make());
    expect(make().hashCode, make().hashCode);
    expect(make(), isNot(make().copyWith(tags: {'ui'})));
    expect(make(), isNot(make().copyWith(attributes: [_userId('7')])));
    expect(make(), isNot(make().copyWith(text: 'timeout')));
    expect(const LogFilter(), const LogFilter());
    expect(const LogFilter(text: 'x').isEmpty, isFalse);
    expect(const LogFilter(text: 'x').copyWith(text: '').isEmpty, isTrue);
  });

  test('copyWith replaces conditions; bounds are set and cleared via a function', () {
    final filter = LogFilter(after: t10, before: t20, levels: const {LogLevel.error}, tags: const {'net'});

    final narrowed = filter.copyWith(levels: {}, tags: {'ui'});
    expect(narrowed.after, t10, reason: 'untouched conditions are kept');
    expect(narrowed.before, t20);
    expect(narrowed.levels, isEmpty);
    expect(narrowed.tags, {'ui'});

    final shifted = filter.copyWith(after: () => t20);
    expect(shifted.after, t20);
    expect(shifted.before, t20, reason: 'bound not passed is kept');

    final unbounded = filter.copyWith(after: () => null, before: () => null);
    expect(unbounded.after, isNull);
    expect(unbounded.before, isNull);
    expect(unbounded.levels, {LogLevel.error});
  });

  test('toString lists only the set conditions', () {
    expect(const LogFilter().toString(), 'LogFilter()');
    expect(
      LogFilter(levels: const {LogLevel.error}, attributes: [_userId('42')]).toString(),
      'LogFilter(levels: error, attributes: [test.user_id: 42])',
    );
    expect(const LogFilter(text: 'timeout').toString(), 'LogFilter(text: "timeout")');
  });

  group('conditions', () {
    test('one condition per set field, one per tag and attribute', () {
      final filter = LogFilter(
        after: t10,
        before: t20,
        levels: const {LogLevel.error},
        tags: const {'net', 'api'},
        attributes: [_userId('42')],
        text: 'Timeout',
      );

      expect(filter.conditions.map((c) => c.runtimeType), [
        LogAfterCondition,
        LogBeforeCondition,
        LogLevelCondition,
        LogTagCondition,
        LogTagCondition,
        LogAttributeCondition,
        LogTextCondition,
      ]);
      expect(const LogFilter().conditions, isEmpty);
      expect(identical(filter.conditions, filter.conditions), isTrue, reason: 'built once');
    });

    test('filter matches means all its conditions match', () {
      final filter = LogFilter(after: t10, tags: const {'net'});
      for (final entry in [
        _at(5, tags: {'net'}),
        _at(15),
        _at(15, tags: {'net'}),
      ]) {
        expect(filter.matches(entry), filter.conditions.every((c) => c.matches(entry)));
      }
    });

    test('searchableTexts: lower-cased message and error text', () {
      final entry = LogEntry(
        time: t10,
        level: LogLevel.error,
        message: 'Netz nicht verfügbar',
        error: LogError.capture(StateError('Disk FULL')),
      );

      expect(LogTextCondition.searchableTexts(entry), ['netz nicht verfügbar', 'stateerror: bad state: disk full']);
      expect(LogTextCondition.searchableTexts(_at(0)), ['m0']);
      expect(LogTextCondition('VERFÜGBAR').matches(entry), isTrue);
    });

    test('prefilterTokens: lowercased ASCII runs without space, quote, backslash and colon, longest first', () {
      expect(LogTextCondition('Disk FULLY').prefilterTokens, ['fully', 'disk']);
      expect(LogTextCondition(r'StateError: Bad "state"\x').prefilterTokens, ['stateerror', 'state', 'bad', 'x']);
      expect(
        LogTextCondition('Netz nicht verfügbar').prefilterTokens,
        unorderedEquals(['nicht', 'netz', 'verf', 'gbar']),
      );
      expect(LogTextCondition('Сбой сети').prefilterTokens, isEmpty);
      expect(LogTextCondition('a a 100%').prefilterTokens, ['100%', 'a']);
      expect(LogTextCondition('tab\there\nlines').prefilterTokens, ['lines', 'here', 'tab']);
    });

    test('prefilterTokens are found in the ASCII-lowercased JSON of every matching entry', () {
      String asciiLower(String text) => text.replaceAllMapped(RegExp('[A-Z]'), (m) => m[0]!.toLowerCase());
      final entries = [
        LogEntry(time: t10, level: LogLevel.info, message: 'Quote " and \\ backslash\nnew line, 100% ÜBER Straße'),
        LogEntry(
          time: t10,
          level: LogLevel.error,
          message: 'request failed',
          error: const LogError(type: 'HttpException', message: 'Timeout: 30s / "x"'),
        ),
        LogEntry(
          time: t10,
          level: LogLevel.error,
          message: 'f',
          error: const LogError(type: 'E', message: 'E: twice'),
        ),
      ];
      const needles = [
        'quote "',
        r'and \ back',
        'backslash\nnew',
        '100% über',
        'straße',
        'HttpException: Timeout: 30s',
        'timeout: 30s / "x"',
        '/ "x',
        'e: e: twice',
        'e: twice',
      ];

      for (final entry in entries) {
        final json = asciiLower(jsonEncode(logEntryJson.encode(entry)));
        for (final condition in needles.map(LogTextCondition.new)) {
          if (!condition.matches(entry)) continue;
          for (final token in condition.prefilterTokens) {
            expect(
              json,
              contains(token),
              reason: '"${condition.text}" matches $entry, so "$token" must be in its JSON',
            );
          }
        }
      }
    });
  });
}
