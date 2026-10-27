import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:log_trail_flutter/log_trail_flutter.dart';

void main() {
  late List<String> printed;
  late DebugPrintCallback originalDebugPrint;

  setUp(() {
    printed = [];
    originalDebugPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
  });

  tearDown(() => debugPrint = originalDebugPrint);

  final diagnostic = LogDiagnostic(
    'LogStoreSink: the store failed to write 1 entries',
    error: StateError('parameters: card 4111 1111'),
    stackTrace: StackTrace.fromString('#0 main (file.dart:1:1)'),
  );

  test('in debug prints the message, error and stack trace via debugPrint', () {
    // Explicit although it is the default in tests: the test is about debug mode, not the default.
    // ignore: avoid_redundant_argument_values
    debugPrintDiagnostic(diagnostic, buildMode: BuildMode.debug);

    expect(printed, ['$diagnostic']);
    expect(printed.single, contains('4111'));
  });

  test('in release prints only the message, like printDiagnostic', () {
    debugPrintDiagnostic(diagnostic, buildMode: BuildMode.release);

    expect(printed, [diagnostic.message]);
  });

  test('fits as a DiagnosticReporter handler', () {
    const DiagnosticReporter(debugPrintDiagnostic).report(const LogDiagnostic('Source: event'));

    expect(printed, ['Source: event']);
  });
}
