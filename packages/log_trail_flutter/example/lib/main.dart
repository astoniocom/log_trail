import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:log_trail_flutter/log_trail_flutter.dart';
import 'package:log_trail_flutter/widgets.dart';

/// Declared once, typed: `userId('42')` attaches it to an entry and
/// `entry.attributes.get(userId)` reads it back as a `String?`, also from the store.
const userId = LogField('example.user_id', LogCodec.string);

/// The root is the first thing created: it buffers what is logged before the
/// sinks exist and replays it into them.
final logger = RootLogger(
  sinks: [flutterConsoleSink()],
  diagnostics: const DiagnosticReporter(debugPrintDiagnostic),
);

/// The store the viewer reads. `InMemoryLogStore` keeps the current session;
/// `SqliteLogStore` from `log_trail_sqlite` or `DriftLogStore` from
/// `log_trail_drift` keep the log across restarts and plug in the same way.
final store = InMemoryLogStore(limit: 5000);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  logger.info('App starting');

  // Flutter and platform errors become log entries with the full report attached.
  FlutterError.onError = logger.recordFlutterError;
  PlatformDispatcher.instance.onError = logger.recordPlatformError;

  // In a real app the store opens asynchronously; entries logged meanwhile are buffered.
  await Future<void>.delayed(const Duration(milliseconds: 50));
  logger
    ..addSink(RepeatCollapsingSink(LogStoreSink(store)))
    ..finishStartup();

  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'log_trail example',
    theme: ThemeData(colorSchemeSeed: Colors.teal),
    darkTheme: ThemeData(colorSchemeSeed: Colors.teal, brightness: Brightness.dark),
    // Route changes are logged with the route names as typed attributes.
    navigatorObservers: [LoggingNavigatorObserver(logger)],
    routes: {
      '/': (_) => const HomePage(),
      '/logs': (_) => LogViewerPage(
        reader: store,
        diagnostics: logger.diagnostics,
        // Library tags (navigation, Flutter errors) are hidden in the list; they still filter.
        isTagVisible: (tag) => !tag.startsWith(libraryLogTagPrefix),
        onExport: (context, filter) async {
          final text = StringBuffer();
          await exportLog(store, text, filter: filter);
          await Clipboard.setData(ClipboardData(text: '$text'));
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Log copied to the clipboard')));
          }
        },
      ),
    },
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// A module logs through a child logger: its tag is on every entry.
  final Logger log = logger.child(tags: {'home'});
  int _attempt = 0;

  void _signIn() {
    // Context set on the root reaches every entry logged afterwards.
    logger.setContextAttribute(userId('42'));
    log.info('Signed in');
  }

  void _request() {
    _attempt++;
    log.debug('Request sent', attributes: [LogField.details('attempt $_attempt')]);
    if (_attempt.isEven) {
      log.warning('Slow response', attributes: [LogField.details('${800 * _attempt} ms')]);
    }
  }

  void _fail() {
    try {
      throw const FormatException('Unexpected token at offset 12');
    } on FormatException catch (error, stackTrace) {
      log.error('Failed to parse profile', error: error, stackTrace: stackTrace);
    }
  }

  void _loop() {
    // The same error twenty times: RepeatCollapsingSink stores it once plus a summary.
    for (var i = 0; i < 20; i++) {
      log.recordError(StateError('Sync worker crashed'), StackTrace.current, message: 'Sync iteration $i');
    }
  }

  void _flutterError() {
    // A build error goes through FlutterError.onError into the log, with FlutterErrorDetails attached.
    FlutterError.reportError(FlutterErrorDetails(exception: Exception('Simulated widget error'), library: 'example'));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('log_trail example'),
      actions: [
        IconButton(
          tooltip: 'Open the log',
          icon: const Icon(Icons.list_alt),
          onPressed: () => Navigator.of(context).pushNamed('/logs'),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Produce some entries, then open the log from the app bar.'),
        const SizedBox(height: 16),
        FilledButton(onPressed: _signIn, child: const Text('Sign in (sets user id context)')),
        FilledButton.tonal(onPressed: _request, child: const Text('Send a request (debug + warning)')),
        FilledButton.tonal(onPressed: _fail, child: const Text('Handled error with stack')),
        FilledButton.tonal(onPressed: _loop, child: const Text('Error in a loop (collapsed)')),
        FilledButton.tonal(onPressed: _flutterError, child: const Text('Flutter framework error')),
        const SizedBox(height: 16),
        OutlinedButton(
          onPressed: () => unawaited(logger.flush()),
          child: const Text('Flush (e.g. when going to the background)'),
        ),
      ],
    ),
  );
}
