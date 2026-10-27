import 'package:log_trail/src/entry/call_site.dart';
import 'package:test/test.dart';

void main() {
  group('callSite', () {
    test('skips log_trail* frames and takes the first application frame in VM format', () {
      final stack = StackTrace.fromString(
        '#0      RootLogger.log (package:log_trail/src/logger/root_logger.dart:45:5)\n'
        '#1      FlutterErrorLogging.recordFlutterError (package:log_trail_flutter/src/flutter_error_logging.dart:10:7)\n'
        '#2      HomePageState.build (package:app/src/ui/pages/home_page.dart:100:12)\n'
        '#3      StatefulElement.build (package:flutter/src/widgets/framework.dart:1:1)',
      );

      expect(callSite(stack), 'HomePageState.build (package:app/src/ui/pages/home_page.dart:100:12)');
    });

    test('async VM stack: gaps and empty lines before the application frame are skipped', () {
      final stack = StackTrace.fromString(
        '#0      RootLogger.log (package:log_trail/src/logger/root_logger.dart:45:5)\n'
        '<asynchronous suspension>\n'
        '\n'
        '#1      Repository.load (package:app/data/repository.dart:12:3)\n'
        '<asynchronous suspension>\n'
        '#2      main (package:app/main.dart:5:1)',
      );

      expect(callSite(stack), 'Repository.load (package:app/data/repository.dart:12:3)');
    });

    test('application methods with similar names are not skipped', () {
      final stack = StackTrace.fromString(
        '#0      AuthService.logout (package:app/auth.dart:20:3)\n'
        '#1      Analytics.recordError (package:app/analytics.dart:5:1)',
      );

      expect(callSite(stack), 'AuthService.logout (package:app/auth.dart:20:3)');
    });

    test('understands the Chrome stack format', () {
      final stack = StackTrace.fromString(
        'Error\n'
        '    at RootLogger.log (http://localhost:8080/packages/log_trail/src/root_logger.dart.js:45:5)\n'
        '    at HomePageState.build (http://localhost:8080/packages/app/src/home_page.dart.js:100:12)',
      );

      expect(callSite(stack), startsWith('HomePageState.build'));
    });

    test('application file under packages/ is not mistaken for log_trail', () {
      final stack = StackTrace.fromString(
        '#0      main (file:///repo/packages/log_trail_app/lib/main.dart:3:5)',
      );

      expect(callSite(stack), 'main (file:///repo/packages/log_trail_app/lib/main.dart:3:5)');
    });

    test('SDK frames are skipped when application code follows', () {
      final stack = StackTrace.fromString(
        '#0      int.parse (dart:core-patch/integers_patch.dart:52:5)\n'
        '#1      Settings.load (package:app/settings.dart:12:9)',
      );

      expect(callSite(stack), 'Settings.load (package:app/settings.dart:12:9)');
    });

    test('without application frames an SDK frame is taken', () {
      final stack = StackTrace.fromString('#0      _rootRun (dart:async/zone.dart:1399:13)');

      expect(callSite(stack), '_rootRun (dart:async/zone.dart:1399:13)');
    });

    test('application wrappers are skipped via isWrapperFrame', () {
      final stack = StackTrace.fromString(
        '#0      AppLog.warning (package:app/log.dart:8:5)\n'
        '#1      Cart.checkout (package:app/cart.dart:40:7)',
      );

      expect(
        callSite(stack, isWrapperFrame: (uri, member) => member.startsWith('AppLog.')),
        'Cart.checkout (package:app/cart.dart:40:7)',
      );
    });

    test('obfuscated stack gives null, not garbage', () {
      final stack = StackTrace.fromString(
        '*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***\n'
        'pid: 1234, tid: 5678, name 1.ui\n'
        "build_id: '0123456789abcdef'\n"
        'isolate_dso_base: 7a6c000000, vm_dso_base: 7a6c000000\n'
        '#00 abs 0000007a6c3f2a0b virt 00000000001c2a0b _kDartIsolateSnapshotInstructions+0x1a2a0b',
      );

      expect(callSite(stack), isNull);
    });

    test('empty stack gives null (NIGHTLIGHT-1RZ)', () {
      // This is what the image decode error stack looked like on MiTV: an empty string.
      expect(callSite(StackTrace.fromString('')), isNull);
      expect(callSite(StackTrace.fromString('\n')), isNull);
    });

    test('returns null when all frames are from log_trail', () {
      final stack = StackTrace.fromString(
        '#0      RootLogger.log (package:log_trail/src/logger/root_logger.dart:45:5)',
      );

      expect(callSite(stack), isNull);
    });
  });
}
