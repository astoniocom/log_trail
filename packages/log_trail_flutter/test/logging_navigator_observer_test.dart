import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:log_trail/storage.dart';
import 'package:log_trail/testing.dart';
import 'package:log_trail_flutter/log_trail_flutter.dart';

Route<void> _route(String name, Object? arguments) => PageRouteBuilder<void>(
  settings: RouteSettings(name: name, arguments: arguments),
  pageBuilder: (_, _, _) => const SizedBox(),
);

void main() {
  late RecordingLogSink sink;
  late RootLogger logger;

  setUp(() {
    sink = RecordingLogSink();
    logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [sink])..finishStartup();
  });

  test('by default route arguments are not stored', () {
    LoggingNavigatorObserver(logger).didPush(_route('/profile', {'token': 'secret'}), null);

    final entry = sink.entries.single;
    expect(entry.message, 'Nav push to /profile from none');
    expect(entry.attributes.contains(LoggingNavigatorObserver.argumentsField), isFalse);
    expect(entry.attributes.contains(LoggingNavigatorObserver.argumentsField), isFalse);
  });

  group('typed route change attributes', () {
    const action = LoggingNavigatorObserver.actionField;
    const route = LoggingNavigatorObserver.routeField;
    const previous = LoggingNavigatorObserver.previousRouteField;

    test('push: the opened route and the route beneath it', () {
      LoggingNavigatorObserver(logger).didPush(_route('/profile', null), _route('/home', null));

      final attributes = sink.entries.single.attributes;
      expect(attributes.get(action), NavigationLogAction.push);
      expect(attributes.get(route), '/profile');
      expect(attributes.get(previous), '/home');
    });

    test('first page: previous_route is absent, not "none"', () {
      LoggingNavigatorObserver(logger).didPush(_route('/home', null), null);

      final attributes = sink.entries.single.attributes;
      expect(attributes.get(route), '/home');
      expect(attributes.contains(previous), isFalse);
    });

    test('pop: the closed route and the one returned to', () {
      LoggingNavigatorObserver(logger).didPop(_route('/profile', null), _route('/home', null));

      final entry = sink.entries.single;
      expect(entry.message, 'Nav pop to /home from /profile');
      expect(entry.attributes.get(action), NavigationLogAction.pop);
      expect(entry.attributes.get(route), '/profile');
      expect(entry.attributes.get(previous), '/home');
    });

    test('remove: the removed route and the route beneath it', () {
      LoggingNavigatorObserver(logger).didRemove(_route('/dialog', null), _route('/home', null));

      final attributes = sink.entries.single.attributes;
      expect(attributes.get(action), NavigationLogAction.remove);
      expect(attributes.get(route), '/dialog');
      expect(attributes.get(previous), '/home');
    });

    test('replace: the new route and the replaced one, arguments come from the new', () {
      LoggingNavigatorObserver(
        logger,
        argumentsFormatter: (arguments) => '$arguments',
      ).didReplace(newRoute: _route('/b', 'args-b'), oldRoute: _route('/a', 'args-a'));

      final entry = sink.entries.single;
      expect(entry.message, 'Nav replace /a → /b');
      expect(entry.attributes.get(action), NavigationLogAction.replace);
      expect(entry.attributes.get(route), '/b');
      expect(entry.attributes.get(previous), '/a');
      expect(entry.attributes.get(LoggingNavigatorObserver.argumentsField), 'args-b');
    });

    test('an unnamed route is recorded by type', () {
      final unnamed = PageRouteBuilder<void>(pageBuilder: (_, _, _) => const SizedBox());
      LoggingNavigatorObserver(logger).didPush(unnamed, null);

      expect(sink.entries.single.attributes.get(route), 'unnamed PageRouteBuilder<void>');
    });

    test('entries can be filtered by route', () async {
      final store = InMemoryLogStore();
      final logger = RootLogger(dispatch: LogDispatchPolicy.synchronous, sinks: [LogStoreSink(store)])..finishStartup();
      addTearDown(logger.close);
      LoggingNavigatorObserver(logger)
        ..didPush(_route('/home', null), null)
        ..didPush(_route('/profile', null), _route('/home', null))
        ..didPop(_route('/profile', null), _route('/home', null));
      await logger.flush();

      final page = await store.queryEntries(LogQuery(filter: LogFilter(attributes: [route('/profile')])));
      expect(page.entries.map((e) => e.entry.attributes.get(action)), [
        NavigationLogAction.push,
        NavigationLogAction.pop,
      ]);
    });
  });

  test('argumentsFormatter stores arguments in a separate attribute', () {
    LoggingNavigatorObserver(
      logger,
      argumentsFormatter: (arguments) => arguments is Map ? 'keys: ${arguments.keys.join(',')}' : null,
    ).didPush(_route('/profile', {'userId': 42, 'token': 'secret'}), null);

    expect(sink.entries.single.attributes.get(LoggingNavigatorObserver.argumentsField), 'keys: userId,token');
  });

  test('accepts a child logger: its tags are added to the navigation tag', () {
    LoggingNavigatorObserver(logger.child(tags: {'app'})).didPush(_route('/profile', null), null);

    expect(sink.entries.single.tags, {'app', navigationLogTag});
  });

  test('argumentsFormatter can decline to store arguments', () {
    LoggingNavigatorObserver(logger, argumentsFormatter: (_) => null).didPush(_route('/profile', 'secret'), null);

    expect(sink.entries.single.attributes.contains(LoggingNavigatorObserver.argumentsField), isFalse);
  });
}
