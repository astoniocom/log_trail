import 'package:log_trail/src/format/stack_trace_format.dart';
import 'package:test/test.dart';

void main() {
  group('formatStackTrace', () {
    test('normalizes the stack to Dart VM format with a same-width prefix', () {
      final stack = StackTrace.fromString(
        '#0      Api.fetch (package:app/api.dart:10:5)\n'
        '#1      main (package:app/main.dart:3:1)',
      );

      expect(
        formatStackTrace(stack),
        '#0      Api.fetch (package:app/api.dart:10:5)\n'
        '#1      main (package:app/main.dart:3:1)',
      );
    });

    test('Chrome stack is normalized to Dart VM format', () {
      final stack = StackTrace.fromString(
        'Error\n'
        '    at Api.fetch (http://localhost:8080/packages/app/api.dart.js:10:5)',
      );

      expect(formatStackTrace(stack), '#0      Api.fetch (http://localhost:8080/packages/app/api.dart.js:10:5)');
    });

    test('stack without symbols is returned as is: it needs flutter symbolize', () {
      const text =
          '*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***\n'
          'pid: 1234, tid: 5678, name 1.ui\n'
          '#00 abs 0000007a6c3f2a0b virt 00000000001c2a0b _kDartIsolateSnapshotInstructions+0x1a2a0b';

      expect(formatStackTrace(StackTrace.fromString(text)), text);
    });
  });
}
