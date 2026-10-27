/// Logging from background isolates into the main isolate's root logger,
/// including engine-started isolates (FCM, WorkManager): an on-disk spool
/// (`LogSpool`, `LogSpoolSink`, `LogSpoolReceiver`) as the source of truth,
/// plus a notification port registered by name (`registerIsolateLogPort`,
/// `lookupIsolateLogPort`) so the main isolate picks entries up now rather
/// than at next startup. Separate from `log_trail_flutter.dart` because
/// `dart:isolate` and `dart:io` are unavailable on web.
library;

export 'package:log_trail/isolates.dart';
export 'package:log_trail_flutter/src/isolate_log_port.dart';
