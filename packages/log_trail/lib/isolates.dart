/// Logging from background isolates into the main isolate's root logger.
///
/// Two mechanisms for two situations:
///
/// - `LogSpool`, `LogSpoolSink`, `LogSpoolReceiver`: the background isolate
///   writes entries as files into a spool directory, the main isolate picks
///   them up. For engine-started isolates (FCM handler, WorkManager) or ones
///   that outlive the main isolate: the spool does not depend on whether a
///   main isolate exists or its port is alive, and only the main isolate
///   writes the store. The port here is only a "file appeared" notification.
/// - `IsolateLogSink`, `IsolateLogReceiver`: entries go through a `SendPort`
///   without persistence. For an isolate the sender owns and whose port it
///   received at spawn: a worker the main isolate started logs into the main
///   root, whose store stays in the main isolate with the viewer. A dead port
///   loses entries silently, so this does not suit foreign isolates.
///
/// Separate from `log_trail.dart` because `dart:isolate` and `dart:io` are
/// unavailable on web.
library;

export 'package:log_trail/src/isolates/isolate_logging.dart';
export 'package:log_trail/src/isolates/log_spool.dart';
