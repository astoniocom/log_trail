import 'package:log_trail/log_trail.dart';
import 'package:log_trail/testing.dart';
import 'package:test/test.dart';

const _userId = LogField('test.user_id', LogCodec.string);
const _module = LogField('test.module', LogCodec.string);

void main() {
  late RecordingLogSink sink;
  late RootLogger logger;

  setUp(() {
    sink = RecordingLogSink();
    logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink])..finishStartup();
  });

  test('child logger tags are merged with call tags', () {
    logger.child(tags: {'network'})
      ..log('request sent')
      ..log('retry', tags: {'retry'})
      ..recordError(StateError('timeout'), null);

    expect(sink.entries.map((e) => e.tags), [
      {'network'},
      {'network', 'retry'},
      {'network'},
    ]);
  });

  test('attribute precedence: context, then child logger, then call', () {
    logger.setContextAttribute(_module('app'));
    logger.setContextAttribute(_userId('42'));
    final child = logger.child(attributes: [_module('network')])
      ..log('from child')
      ..log('impersonated', attributes: [_userId('7')]);

    expect(child, isA<Logger>());
    expect(sink.entries[0].attributes.get(_module), 'network', reason: 'the child wins over the context');
    expect(sink.entries[0].attributes.get(_userId), '42', reason: 'the context stays');
    expect(sink.entries[1].attributes.get(_userId), '7', reason: 'the call wins over everything');
  });

  test('a nested child logger accumulates tags and attributes', () {
    logger.child(tags: {'network'}, attributes: [_module('http')]).child(tags: {'auth'}).log('token refreshed');

    final entry = sink.entries.single;
    expect(entry.tags, {'network', 'auth'});
    expect(entry.attributes.get(_module), 'http');
  });

  group('child logger context', () {
    const sessionId = LogField('test.session_id', LogCodec.string);

    test('setContextAttribute applies to subsequent entries of the logger and its earlier-created children', () {
      final sync = logger.child(tags: {'sync'});
      final uploader = sync.child(tags: {'upload'});
      sync.log('before session');

      sync.setContextAttribute(sessionId('s1'));
      sync.log('session started');
      uploader.log('uploading');

      expect(sink.entries.map((e) => e.attributes.get(sessionId)), [null, 's1', 's1']);
      expect(sync.contextAttributes, [sessionId('s1')]);
      expect(uploader.contextAttributes, isEmpty, reason: 'the parent context is not part of its own');
    });

    test('removeContextAttribute removes the field from this logger; the parent field stays', () {
      logger.setContextAttribute(_userId('42'));
      final sync = logger.child(attributes: [sessionId('s1')])
        ..setContextAttribute(sessionId('s2'))
        ..removeContextAttribute(sessionId)
        ..removeContextAttribute(_userId)
        ..log('after removal');

      final entry = sink.entries.single;
      expect(entry.attributes.contains(sessionId), isFalse);
      expect(entry.attributes.get(_userId), '42');
      expect(sync.contextAttributes, isEmpty);
    });

    test('precedence: call over child, child over parent, later context over earlier', () {
      logger.setContextAttribute(_module('app'));
      final child = logger.child(attributes: [_module('child')]);
      final grandchild = child.child()..log('inherits child');
      child.setContextAttribute(_module('child-updated'));
      grandchild
        ..log('sees update')
        ..setContextAttribute(_module('grandchild'))
        ..log('own wins')
        ..log('call wins', attributes: [_module('call')]);

      expect(sink.entries.map((e) => e.attributes.get(_module)), ['child', 'child-updated', 'grandchild', 'call']);
    });
  });

  test('child logger entries pass through the root startup buffer', () {
    final early = RootLogger(dispatch: LogDispatchPolicy.synchronous);
    early.child(tags: {'startup'}).log('before sinks');

    final lateSink = RecordingLogSink();
    early.addSink(lateSink);

    expect(lateSink.entries.single.tags, {'startup'});
  });

  test('the platform error report gets through via a child logger', () {
    final report = Object();
    logger.child(tags: {'ui'}).recordError(StateError('layout'), null, report: report);

    expect(sink.entries.single.error?.report, same(report));
  });

  test('the call site is the app code, not the child logger', () {
    logger.child(tags: {'network'}).log('slow response', level: LogLevel.warning);

    expect(sink.entries.single.location, contains('child_logger_test.dart'));
  });

  test('recordError accepts a given call site, like log', () {
    logger
        .child(tags: {'network'})
        .recordError(StateError('x'), StackTrace.current, location: 'Api.fetch (api.dart:1:1)');

    expect(sink.entries.single.location, 'Api.fetch (api.dart:1:1)');
  });

  group('LevelLogging', () {
    test('each method logs its own level with tags and attributes', () {
      // trace is below the root default threshold: enabled by the module's own threshold.
      final log = logger.child(tags: {'module'}, minLevel: LogLevel.trace);
      log
        ..trace('t')
        ..debug('d')
        ..info('i', tags: {'extra'})
        ..warning('w', attributes: [_userId('1')])
        ..error('e')
        ..fatal('f');

      expect(sink.entries.map((e) => e.level), LogLevel.values);
      expect(sink.entries.map((e) => e.message), ['t', 'd', 'i', 'w', 'e', 'f']);
      expect(sink.entries[2].tags, {'module', 'extra'});
      expect(sink.entries[3].attributes.get(_userId), '1');
      expect(sink.entries.every((e) => e.error == null), isTrue);
    });

    test('with error, the error is logged with a message about what the app was doing', () {
      final stack = StackTrace.current;
      logger.warning('Failed to refresh token', error: const FormatException('bad json'), stackTrace: stack);

      final entry = sink.entries.single;
      expect(entry.level, LogLevel.warning);
      expect(entry.message, 'Failed to refresh token');
      expect(entry.error, LogError.capture(const FormatException('bad json')));
      expect(entry.stackTrace, same(stack));
    });

    test('below the threshold the entry is not built', () {
      logger.defaultMinLevel = LogLevel.warning;
      logger
        ..debug('d')
        ..info('i', error: StateError('ignored'))
        ..warning('w');

      expect(sink.entries.map((e) => e.message), ['w']);
    });
  });

  test('root and child loggers are interchangeable as Logger', () {
    void module(Logger log) => log.log('from module');

    module(logger);
    module(logger.child(tags: {'module'}));

    expect(sink.entries.map((e) => e.tags), [
      <String>{},
      {'module'},
    ]);
  });

  test('the owner gets a ContextualLogger; a module needs only Logger', () {
    final ContextualLogger owned = logger.child(tags: {'sync'});
    owned.setContextAttribute(_userId('1'));
    final ContextualLogger grandchild = owned.child();

    expect(logger, isA<ContextualLogger>());
    expect(grandchild, isA<Logger>());
  });

  group('child logger minLevel', () {
    test('below the root default threshold: module entries are built although the root would drop them', () {
      logger.defaultMinLevel = LogLevel.info;
      final network = logger.child(tags: {'network'}, minLevel: LogLevel.debug);

      logger.debug('root debug');
      network.debug('module debug');
      network.child(tags: {'http'}).debug('nested debug');

      expect(sink.entries.map((e) => e.message), ['module debug', 'nested debug']);
      expect(network.isEnabled(LogLevel.debug), isTrue);
      expect(logger.isEnabled(LogLevel.debug), isFalse);
    });

    test('above the root threshold: module entries below its own threshold are dropped', () {
      final quiet = logger.child(tags: {'analytics'}, minLevel: LogLevel.warning);

      quiet
        ..info('dropped')
        ..warning('kept');
      logger.info('root kept');

      expect(sink.entries.map((e) => e.message), ['kept', 'root kept']);
      expect(quiet.isEnabled(LogLevel.info), isFalse);
    });

    test('without its own threshold a child follows the parent threshold, including one set later', () {
      final module = logger.child(tags: {'module'}, minLevel: LogLevel.warning);
      final part = module.child(tags: {'part'});
      expect(part.isEnabled(LogLevel.info), isFalse, reason: 'the module threshold');
      expect(part.isEnabled(LogLevel.warning), isTrue);

      final plain = logger.child(tags: {'plain'});
      expect(plain.isEnabled(LogLevel.debug), isTrue);
      logger.defaultMinLevel = LogLevel.error;
      expect(plain.isEnabled(LogLevel.warning), isFalse, reason: 'the root threshold set later');
      expect(part.isEnabled(LogLevel.warning), isTrue, reason: 'module threshold is independent of the root default');
    });

    group('root floor', () {
      test('a child with minLevel below the floor does not log below the floor; isEnabled reflects that', () {
        logger.floor = LogLevel.info;
        final network = logger.child(tags: {'network'}, minLevel: LogLevel.trace);

        network
          ..trace('t')
          ..debug('d')
          ..info('i');
        network.child(tags: {'http'}).debug('nested');

        expect(sink.entries.map((e) => e.message), ['i']);
        expect(network.isEnabled(LogLevel.debug), isFalse, reason: 'else logLazy would compute the message in vain');
        expect(network.isEnabled(LogLevel.info), isTrue);
      });

      test('the floor is raised and lowered at runtime and applies to already created children', () {
        final module = logger.child(minLevel: LogLevel.debug);
        logger.floor = LogLevel.warning;
        module.info('hidden');

        logger.floor = LogLevel.trace;
        module.info('shown');

        expect(sink.entries.map((e) => e.message), ['shown']);
      });

      test('a floor above the default threshold applies to the root too', () {
        logger
          ..defaultMinLevel = LogLevel.debug
          ..floor = LogLevel.error;

        logger
          ..warning('hidden')
          ..error('shown');

        expect(sink.entries.map((e) => e.message), ['shown']);
        expect(logger.isEnabled(LogLevel.warning), isFalse);
      });
    });

    test('logLazy does not compute the message below the child threshold', () {
      var isComputed = false;
      final quiet = logger.child(minLevel: LogLevel.error);

      quiet.logLazy(() {
        isComputed = true;
        return 'expensive';
      });

      expect(isComputed, isFalse);
      expect(sink.entries, isEmpty);
    });

    test('after root close, entries of a child with a low threshold are dropped like the rest', () async {
      final network = logger.child(minLevel: LogLevel.debug);
      await logger.close();

      network.debug('late');

      expect(sink.entries, isEmpty);
    });
  });
}
