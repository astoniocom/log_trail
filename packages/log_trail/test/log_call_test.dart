import 'package:log_trail/log_trail.dart';
import 'package:test/test.dart';

const _userId = LogField('test.user_id', LogCodec.string);
const _requestId = LogField('test.request_id', LogCodec.string);

void main() {
  group('LogCall', () {
    test('call with a message: no error or report, level info by default', () {
      const call = LogCall.message('ok');

      expect(call.message, 'ok');
      expect(call.error, isNull);
      expect(call.report, isNull);
      expect(call.level, LogLevel.info);
    });

    test('call with an error: message and report are optional, level error by default', () {
      final error = StateError('boom');
      final bare = LogCall.error(error);
      final explained = LogCall.error(error, message: 'Failed', report: 'details', level: LogLevel.warning);

      expect(bare.error, same(error));
      expect(bare.message, isNull);
      expect(bare.report, isNull);
      expect(bare.level, LogLevel.error);
      expect(explained.message, 'Failed');
      expect(explained.report, 'details');
      expect(explained.level, LogLevel.warning);
    });

    test('withTags adds tags to its own; returns the same call when nothing is added', () {
      const call = LogCall.message('m', tags: {'call'});

      expect(call.withTags({'module', 'call'}).tags, {'module', 'call'});
      expect(call.withTags(const {}), same(call));
      expect(const LogCall.message('m').withTags({'module'}).tags, {'module'});
    });

    test('withContext puts context before the call attributes: the call value is last', () {
      final call = LogCall.message('m', attributes: [_userId('call')]);

      final enriched = call.withContext([_userId('context'), _requestId('r1')]);

      expect(enriched.attributes.map((a) => a.field.name).toList(), [
        'test.user_id',
        'test.request_id',
        'test.user_id',
      ]);
      expect(LogAttributes(enriched.attributes).get(_userId), 'call');
      expect(LogAttributes(enriched.attributes).get(_requestId), 'r1');
      expect(call.withContext(const []), same(call));
    });

    test('copies keep the other fields', () {
      final error = StateError('boom');
      final stack = StackTrace.current;
      final time = DateTime(2026);
      final call = LogCall.error(
        error,
        message: 'm',
        report: 'details',
        level: LogLevel.warning,
        location: 'here',
        stackTrace: stack,
        time: time,
      );

      final copy = call.withTags({'t'}).withContext([_userId('u')]);

      expect(copy.message, 'm');
      expect(copy.level, LogLevel.warning);
      expect(copy.location, 'here');
      expect(copy.stackTrace, same(stack));
      expect(copy.time, time);
      expect(copy.error, same(error));
      expect(copy.report, 'details');
    });
  });
}
