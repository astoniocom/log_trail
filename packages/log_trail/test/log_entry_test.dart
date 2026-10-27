import 'dart:convert';

import 'package:log_trail/log_trail.dart';
import 'package:log_trail/src/entry/call_site.dart';
import 'package:test/test.dart';

enum _Screen { home, settings }

const _userId = LogField('test.user_id', LogCodec.string);
const _attempt = LogField('test.attempt', LogCodec.integer);
const _ratio = LogField('test.ratio', LogCodec.float);
const _isRetry = LogField('test.is_retry', LogCodec.boolean);
const _startedAt = LogField('test.started_at', LogCodec.dateTime);
const _elapsed = LogField('test.elapsed', LogCodec.duration);
const _screen = LogField('test.screen', EnumByNameCodec(_Screen.values));
const _payload = LogField('test.payload', LogCodec.raw);

LogEntry _fullEntry() => LogEntry(
  time: DateTime.utc(2026, 10, 20, 11, 43, 12, 345, 678),
  level: LogLevel.error,
  message: 'Request failed',
  tags: const {'network', 'api'},
  location: 'Api.fetch (package:app/api.dart:10:5)',
  stackTrace: StackTrace.current,
  error: LogError.capture(StateError('timeout')),
  attributes: LogAttributes([
    LogField.details('GET /users'),
    _userId('42'),
    _attempt(3),
    _ratio(0.25),
    _isRetry(true),
    _startedAt(DateTime(2026, 10, 20, 11, 43)),
    _elapsed(const Duration(milliseconds: 1500)),
    _screen(_Screen.settings),
    _payload(
      LogMap({
        'ids': LogList(const [LogInt(1), LogInt(2)]),
      }),
    ),
  ]),
);

LogEntry _roundTrip(LogEntry entry) =>
    logEntryJson.decode(jsonDecode(jsonEncode(logEntryJson.encode(entry))) as Map<String, Object?>);

void main() {
  group('LogEntry', () {
    test('equals the original after a JSON round trip', () {
      final entry = _fullEntry();
      final restored = _roundTrip(entry);

      expect(restored, entry);
      expect(restored.hashCode, entry.hashCode);
      expect(restored.stackTrace.toString(), entry.stackTrace.toString());
    });

    test('time is stored in UTC and read back as the same moment; the entry equals the original', () {
      final entry = LogEntry(time: DateTime(2026, 10, 25, 2, 30, 15, 123, 456), level: LogLevel.info, message: 'm');
      final json = logEntryJson.encode(entry);
      final restored = _roundTrip(entry);

      expect(json['time'], endsWith('Z'));
      expect(entry.time.isUtc, isFalse, reason: 'local time is passed as is');
      expect(restored.time.isUtc, isTrue, reason: 'the time read back stays in UTC');
      expect(restored.time.isAtSameMomentAs(entry.time), isTrue);
      expect(restored, entry);
      expect(restored.hashCode, entry.hashCode);
    });

    test('logEntryJson writes the current format version and reads it back unchanged', () {
      final stored = <String, Object?>{
        'version': LogEntryJsonCodec.formatVersion,
        'time': '2026-10-20T11:43:12.345678Z',
        'level': 'error',
        'message': 'Request failed',
        'tags': ['network'],
        'location': 'Api.fetch (package:app/api.dart:10:5)',
        'stackTrace': '#0      main (package:app/main.dart:1:1)',
        'error': {'type': 'StateError', 'message': 'Bad state: timeout'},
        'attributes': {'test.user_id': '42'},
      };

      expect(LogEntryJsonCodec.formatVersion, 1);
      expect(logEntryJson.encode(logEntryJson.decode(stored)), stored);
    });

    test('logEntryJsonText is logEntryJson as text: round trip, and non-object text is rejected', () {
      final entry = _fullEntry();
      final text = logEntryJsonText.encode(entry);

      expect(jsonDecode(text), logEntryJson.encode(entry));
      expect(logEntryJsonText.decode(text), entry);
      expect(LogExportFormat.jsonLines.format(entry), text);
      expect(() => logEntryJsonText.decode('[1, 2]'), throwsFormatException);
      expect(() => logEntryJsonText.decode('not json'), throwsFormatException);
    });

    test('an entry without the version field is read as version 0 and written in the current one', () {
      final legacy = <String, Object?>{
        'time': '2026-10-20T11:43:12.345678Z',
        'level': 'error',
        'message': 'Request failed',
        'tags': ['network'],
        'location': 'Api.fetch (package:app/api.dart:10:5)',
        'stackTrace': '#0      main (package:app/main.dart:1:1)',
        'error': {'type': 'StateError', 'message': 'Bad state: timeout'},
        'attributes': {'test.user_id': '42'},
      };

      expect(logEntryJson.encode(logEntryJson.decode(legacy)), {...legacy, 'version': 1});
    });

    test('the format version equals the number of upgrade steps; an entry of every earlier version is readable', () {
      expect(LogEntryJsonCodec.formatVersion, LogEntryJsonCodec.upgrades.length);
      expect(LogEntryJsonCodec.formatVersion, greaterThan(0));

      final current = logEntryJson.encode(_fullEntry());
      final expected = logEntryJson.decode(current);
      for (var version = 0; version < LogEntryJsonCodec.formatVersion; version++) {
        // A map of the given version: the current one with the steps after it not yet applied.
        // Step 0 -> 1 added the version field and replaced '' with null in location; reversed here for the test.
        final legacy = switch (version) {
          0 => ({...current, 'location': current['location'] ?? ''}..remove('version')),
          _ => {...current, 'version': version},
        };

        expect(logEntryJson.decode(legacy), expected, reason: 'version $version');
      }
    });

    test('an entry of a newer format version is rejected with FormatException', () {
      final json = logEntryJson.encode(_fullEntry())..['version'] = LogEntryJsonCodec.formatVersion + 1;

      expect(
        () => logEntryJson.decode(json),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('format version 2'))),
      );
      expect(() => logEntryJson.decode(logEntryJson.encode(_fullEntry())..['version'] = 'x'), throwsFormatException);
    });

    test('parse error messages name the field and type but not the value: it may end up in diagnostics', () {
      final json = logEntryJson.encode(_fullEntry());
      Matcher failsWithout(String secret, {required String naming}) => throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          allOf(contains(naming), isNot(contains(secret))),
        ),
      );

      expect(() => logEntryJson.decode({...json, 'message': 424242}), failsWithout('424242', naming: '"message"'));
      expect(
        () => logEntryJson.decode({
          ...json,
          'tags': ['ok', 424242],
        }),
        failsWithout('424242', naming: '"tags"'),
      );
      expect(
        () => logEntryJson.decode({...json, 'time': 'secret-time'}),
        failsWithout('secret-time', naming: '"time"'),
      );
      expect(
        () => logEntryJson.decode({...json, 'level': 'secret-level'}),
        failsWithout('secret-level', naming: '"level"'),
      );
      expect(
        () => LogValue.fromJson(DateTime(2026)),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', 'Not a log value: DateTime')),
      );
    });

    test('time is stored as given but compared by moment: entries in UTC and local time are equal', () {
      final utc = DateTime.utc(2026, 10, 20, 11, 43);
      final fromUtc = LogEntry(time: utc, level: LogLevel.info, message: 'm');
      final fromLocal = LogEntry(time: utc.toLocal(), level: LogLevel.info, message: 'm');

      expect(fromUtc.time, same(utc));
      expect(fromLocal.time.isUtc, isFalse);
      expect(fromUtc, fromLocal);
      expect(fromUtc.hashCode, fromLocal.hashCode);
    });

    test('an unknown call site is stored as null, and an empty string from version 0 is read as unknown', () {
      final entry = LogEntry(time: DateTime(2026), level: LogLevel.info, message: 'm');
      expect(entry.location, isNull);
      expect(logEntryJson.encode(entry)['location'], isNull);
      expect(_roundTrip(entry).location, isNull);

      final legacy = logEntryJson.decode({...logEntryJson.encode(entry), 'location': ''}..remove('version'));
      expect(legacy.location, isNull);
      expect(legacy, entry);

      final current = logEntryJson.decode({...logEntryJson.encode(entry), 'location': ''});
      expect(current.location, '', reason: 'in the current version an empty string is an ordinary value');
    });

    test('time without a zone designator is read as local', () {
      final restored = logEntryJson.decode({
        ...logEntryJson.encode(_fullEntry()),
        'time': '2026-10-20T11:43:12.000',
      });

      expect(restored.time, DateTime(2026, 10, 20, 11, 43, 12));
    });

    test('entries with different stacks are not equal; entries without a stack compare by the other fields', () {
      LogEntry withStack(StackTrace? stack) =>
          LogEntry(time: DateTime(2026), level: LogLevel.error, message: 'm', stackTrace: stack);
      final stack = StackTrace.current;

      expect(withStack(stack), withStack(StackTrace.fromString(stack.toString())));
      expect(withStack(stack), isNot(withStack(StackTrace.fromString('#0 other (x.dart:1:1)'))));
      expect(withStack(null), withStack(null));
      expect(withStack(null), isNot(withStack(stack)));
    });

    test('an entry read back has no original error object; type and text are present', () {
      final restored = _roundTrip(_fullEntry());

      expect(restored.error?.original, isNull);
      expect(restored.error?.type, 'StateError');
      expect(restored.error?.message, 'Bad state: timeout');
    });

    test('attributes of an entry read back are returned in the field type', () {
      final restored = _roundTrip(_fullEntry()).attributes;

      expect(restored.get(_userId), '42');
      expect(restored.get(_attempt), 3);
      expect(restored.get(_ratio), 0.25);
      expect(restored.get(_isRetry), isTrue);
      expect(restored.get(_startedAt), DateTime(2026, 10, 20, 11, 43));
      expect(restored.get(_elapsed), const Duration(milliseconds: 1500));
      expect(restored.get(_screen), _Screen.settings);
      expect(
        restored.get(_payload),
        LogMap({
          'ids': LogList(const [LogInt(1), LogInt(2)]),
        }),
      );
    });

    test('corrupted data gives FormatException', () {
      final json = logEntryJson.encode(_fullEntry())..['level'] = 'verbose';
      expect(() => logEntryJson.decode(json), throwsFormatException);
      expect(() => logEntryJson.decode(logEntryJson.encode(_fullEntry())..remove('message')), throwsFormatException);
    });

    group('copyWith', () {
      test('without arguments gives an equal entry; given fields are replaced, the rest stay', () {
        final entry = _fullEntry();
        final newError = LogError.capture(const FormatException('bad'));

        expect(entry.copyWith(), entry);

        final copy = entry.copyWith(
          level: LogLevel.warning,
          message: 'changed',
          tags: const {'other'},
          error: () => newError,
          attributes: LogAttributes([_attempt(4)]),
        );
        expect(copy.level, LogLevel.warning);
        expect(copy.message, 'changed');
        expect(copy.tags, {'other'});
        expect(copy.error, same(newError));
        expect(copy.attributes.get(_attempt), 4);
        expect(copy.attributes.get(_userId), isNull);
        expect(copy.time, entry.time);
        expect(copy.location, entry.location);
        expect(copy.stackTrace, same(entry.stackTrace));
      });

      test('location, stackTrace and error are cleared by a function returning null', () {
        final entry = _fullEntry();

        final copy = entry.copyWith(location: () => null, stackTrace: () => null, error: () => null);

        expect(copy.location, isNull);
        expect(copy.stackTrace, isNull);
        expect(copy.error, isNull);
        expect(copy.message, entry.message);
      });

      test('a not yet resolved call site is carried over without parsing the stack and resolved once for both', () {
        var frameChecks = 0;
        final entry = LogEntry.locatedBy(
          time: DateTime(2026),
          level: LogLevel.warning,
          message: 'm',
          callSite: CallSite.fromStack(
            StackTrace.current,
            isWrapperFrame: (_, _) {
              frameChecks++;
              return false;
            },
          ),
        );

        final copy = entry.copyWith(message: 'changed');
        expect(frameChecks, 0, reason: 'copying does not parse the stack');

        expect(copy.location, contains('log_entry_test.dart'));
        final checksAfterCopy = frameChecks;
        expect(checksAfterCopy, greaterThan(0));

        expect(entry.location, copy.location);
        expect(frameChecks, checksAfterCopy, reason: 'the call site is resolved once for both entries');
      });

      test('withoutLiveObjects: no original and report, the call site is resolved, the entry equals the original', () {
        final report = Object();
        var frameChecks = 0;
        final entry = LogEntry.locatedBy(
          time: DateTime(2026),
          level: LogLevel.error,
          message: 'm',
          stackTrace: StackTrace.current,
          error: LogError.capture(StateError('boom'), report: report),
          callSite: CallSite.fromStack(
            StackTrace.current,
            isWrapperFrame: (_, _) {
              frameChecks++;
              return false;
            },
          ),
        );

        final detached = entry.withoutLiveObjects();

        expect(detached.error?.original, isNull);
        expect(detached.error?.report, isNull);
        expect(detached.error?.type, 'StateError');
        expect(detached.error?.message, 'Bad state: boom');
        expect(frameChecks, greaterThan(0), reason: 'the call site is resolved, the stack is no longer needed for it');
        expect(detached.location, entry.location);
        expect(detached.stackTrace, same(entry.stackTrace));
        expect(detached, entry);
        expect(detached.hashCode, entry.hashCode);
      });

      test('withoutLiveObjects returns the same entry if there are no live objects', () {
        final restored = _roundTrip(_fullEntry());
        final plain = LogEntry(time: DateTime(2026), level: LogLevel.info, message: 'm', location: 'given');

        expect(restored.withoutLiveObjects(), same(restored));
        expect(plain.withoutLiveObjects(), same(plain));
      });

      test('comparing a copy with the original does not parse the stack; the hash is computed once', () {
        var frameChecks = 0;
        final entry = LogEntry.locatedBy(
          time: DateTime(2026),
          level: LogLevel.error,
          message: 'm',
          stackTrace: StackTrace.current,
          callSite: CallSite.fromStack(
            StackTrace.current,
            isWrapperFrame: (_, _) {
              frameChecks++;
              return false;
            },
          ),
        );
        final copy = entry.copyWith(tags: {'x'});
        final same = entry.copyWith();

        expect(same, entry);
        expect(copy, isNot(entry));
        expect(frameChecks, 0, reason: 'the shared CallSite and shared stack are compared by identity');

        final hash = entry.hashCode;
        expect(frameChecks, greaterThan(0), reason: 'the hash includes the call site and the stack text');
        final checksAfterHash = frameChecks;
        expect(entry.hashCode, hash);
        expect(frameChecks, checksAfterHash, reason: 'a repeated hash is not recomputed');
      });

      test('a given call site cancels resolution from the stack', () {
        var frameChecks = 0;
        final entry = LogEntry.locatedBy(
          time: DateTime(2026),
          level: LogLevel.warning,
          message: 'm',
          callSite: CallSite.fromStack(StackTrace.current, isWrapperFrame: (_, _) => frameChecks++ < 0),
        );

        expect(entry.copyWith(location: () => 'given').location, 'given');
        expect(entry.copyWith(location: () => null).location, isNull);
        expect(frameChecks, 0);
      });
    });
  });

  group('LogError', () {
    test('toString adds the type if the text lacks it', () {
      expect('${LogError.capture(StateError('boom'))}', 'StateError: Bad state: boom');
    });

    test('toString does not repeat the type if the text starts with it', () {
      expect('${LogError.capture(const FormatException('Unexpected token'))}', 'FormatException: Unexpected token');
    });
  });

  group('LogAttributes', () {
    test('a missing attribute gives null', () {
      expect(LogAttributes([_userId('42')]).get(_attempt), isNull);
    });

    test('for a repeated field the last value stays', () {
      expect(LogAttributes([_userId('1'), _userId('2')]).get(_userId), '2');
    });

    test('a stored value of another type gives FormatException', () {
      final attributes = LogAttributes.fromEncoded(const {'test.attempt': LogString('three')});
      expect(() => attributes.get(_attempt), throwsFormatException);
    });

    test('a field with the same name and another type reads the value through its own codec', () {
      const attemptAsDouble = LogField('test.attempt', LogCodec.float);
      expect(LogAttributes([_attempt(3)]).get(attemptAsDouble), 3.0);
    });

    test('hasSameDeclaration: same name, field type and codec type, regardless of identical', () {
      const first = LogField('test.same', LogCodec.string);
      // A separate instance, not a constant: declarations in different modules are not identical.
      // ignore: prefer_const_constructors
      final second = LogField('test.same', LogCodec.string);
      const enumFirst = LogField('test.same_enum', EnumByNameCodec(_Screen.values));
      final enumSecond = LogField('test.same_enum', EnumByNameCodec(List.of(_Screen.values)));

      expect(first.hasSameDeclaration(second), isTrue);
      expect(enumFirst.hasSameDeclaration(enumSecond), isTrue);
      expect(first.hasSameDeclaration(const LogField('test.same', LogCodec.integer)), isFalse);
      expect(
        enumFirst.hasSameDeclaration(const LogField('test.same_enum', EnumByNameCodec(LogLevel.values))),
        isFalse,
        reason: 'same codec, different value type',
      );
      expect(first.hasSameDeclaration(const LogField('test.other', LogCodec.string)), isFalse);
    });

    test('encoded is computed once and cannot be modified from outside', () {
      final attributes = LogAttributes([_userId('42')]);

      expect(identical(attributes.encoded, attributes.encoded), isTrue);
      expect(() => attributes.encoded['x'] = const LogString('y'), throwsUnsupportedError);
    });

    test('attributes logged in-process equal those read from the store', () {
      final live = LogAttributes([_userId('42'), _attempt(3)]);
      expect(LogAttributes.fromEncoded(live.encoded), live);
    });

    test('withAll adds attributes, the new field value wins, the originals are unchanged', () {
      final live = LogAttributes([_userId('42'), _attempt(3)]);
      final decoded = LogAttributes.fromEncoded(live.encoded);

      final merged = decoded.withAll([_attempt(4), _ratio(0.5)]);

      expect(merged.get(_userId), '42', reason: 'the decoded attribute is kept');
      expect(merged.get(_attempt), 4);
      expect(merged.get(_ratio), 0.5);
      expect(decoded.get(_attempt), 3, reason: 'the original attributes are immutable');
      expect(live.withAll(const []), live);
      expect(LogAttributes.empty.withAll([_userId('1')]), LogAttributes([_userId('1')]));
    });
  });

  group('LogValue', () {
    test('fromJson rejects null and non-JSON values', () {
      expect(() => LogValue.fromJson(null), throwsFormatException);
      expect(() => LogValue.fromJson(Object()), throwsFormatException);
    });

    test('toCanonicalJson sorts map keys at every level; equal values give equal text', () {
      final a = LogMap({
        'b': const LogInt(2),
        'a': LogList([
          LogMap(const {'z': LogBool(true), 'y': LogString('s')}),
        ]),
      });
      final b = LogMap({
        'a': LogList([
          LogMap(const {'y': LogString('s'), 'z': LogBool(true)}),
        ]),
        'b': const LogInt(2),
      });

      expect(a.toCanonicalJson(), '{"a":[{"y":"s","z":true}],"b":2}');
      expect(a.toCanonicalJson(), b.toCanonicalJson());
      expect(const LogString('x').toCanonicalJson(), '"x"');
      expect(const LogDouble(1.5).toCanonicalJson(), '1.5');
    });
  });
}
