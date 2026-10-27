import 'package:flutter/foundation.dart';
import 'package:log_trail/log_trail.dart';

/// [DiagnosticHandler] for Flutter: prints via [debugPrint], which throttles output (otherwise
/// Android drops lines) and keeps ordering with Flutter's own output. Like [printDiagnostic], in
/// a release build ([buildMode]) prints only [LogDiagnostic.message]
/// ([LogDiagnostic.consoleText]).
///
/// Not installed by itself: by default the library prints via [print]. Set it on the root when
/// configuring logging:
///
/// ```dart
/// RootLogger(diagnostics: const DiagnosticReporter(debugPrintDiagnostic));
/// ```
void debugPrintDiagnostic(LogDiagnostic diagnostic, {BuildMode buildMode = BuildMode.current}) =>
    debugPrint(diagnostic.consoleText(buildMode));
