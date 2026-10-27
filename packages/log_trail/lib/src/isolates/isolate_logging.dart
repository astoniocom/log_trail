import 'dart:async';
import 'dart:isolate';

import 'package:log_trail/src/diagnostics/log_diagnostic.dart';
import 'package:log_trail/src/entry/log_entry.dart';
import 'package:log_trail/src/format/log_entry_json_codec.dart';
import 'package:log_trail/src/sinks/log_sink.dart';

/// Sink that passes entries to another isolate through [port]
/// ([IsolateLogReceiver.sendPort]) without persisting them. There they go
/// through the root logger alongside its own entries: same threshold,
/// processors, sinks and store.
///
/// For an isolate the sender owns and whose port it received at spawn: a
/// worker the main isolate started logs into the main root, whose sinks and
/// store stay where the viewer reads them; it is not a way to move a store out
/// of the main isolate. [SendPort.send] does not confirm delivery: if the
/// receiver is closed ([IsolateLogReceiver.close]) or its isolate has exited,
/// entries are lost silently, so engine-started isolates (FCM, WorkManager)
/// use `LogSpoolSink`, which writes to disk and uses the port only as a
/// notification.
///
/// An entry is sent in [logEntryJson] form: a map of strings, numbers, lists
/// and maps, which [SendPort.send] delivers even to an isolate of another
/// group without shared code. It is not encoded as JSON text: the receiver
/// should not have to parse it. As with persistence, only the live
/// [LogError.original] and [LogError.report] are lost.
///
/// Sends in [add], during root dispatch. An isolate that exits right after its
/// work ([Isolate.run]) would lose entries waiting for dispatch until the next
/// event-loop turn, so its root is given dispatch in the logger call
/// (`LogDispatchPolicy.synchronous`):
///
/// ```dart
/// Future<void> work(SendPort logPort) async {
///   final logger = RootLogger(sinks: [IsolateLogSink(logPort)], dispatch: LogDispatchPolicy.synchronous)
///     ..finishStartup();
///   logger.child(tags: {'sync'}).log('Sync started');
/// }
///
/// await Isolate.run(() => work(receiver.sendPort));
/// ```
final class IsolateLogSink extends LogSink {
  IsolateLogSink(this.port);

  final SendPort port;

  @override
  String get name => 'IsolateLogSink';

  @override
  void onAdd(LogEntry entry) => port.send(logEntryJson.encode(entry));
}

/// Receives entries through a port ([IsolateLogSink]): each entry is passed to
/// [sink], usually the root logger's sink (`RootLogger.asSink`).
///
/// ```dart
/// final logger = RootLogger(sinks: [...]);
/// final receiver = IsolateLogReceiver(logger.asSink());
/// // receiver.sendPort is passed to the isolate at spawn.
/// ```
///
/// Entries arrive ready-made, so the root context (`setContextAttribute`) is
/// not added to them: the background isolate has its own root with its own
/// context. A message that fails to parse and a [sink] failure go to the
/// sink's [LogSink.diagnostics] (for `RootLogger.asSink`, the root's channel)
/// and do not block the following entries.
///
/// Until the receiver is closed ([close]), the port keeps the isolate alive.
final class IsolateLogReceiver {
  IsolateLogReceiver(this.sink) {
    _subscription = _port.listen(_onMessage);
  }

  /// Entry recipient; its [LogSink.diagnostics] also carries receive
  /// diagnostics.
  final LogSink sink;

  // Port name for the debugger; unrelated to the IsolateNameServer registration name.
  final ReceivePort _port = ReceivePort('IsolateLogReceiver');
  late final StreamSubscription<Object?> _subscription;

  /// Port for the background isolate's [IsolateLogSink].
  SendPort get sendPort => _port.sendPort;

  /// Stops receiving: entries sent after this are lost. [sink] is not closed:
  /// the caller owns it.
  Future<void> close() async {
    _port.close();
    await _subscription.cancel();
  }

  void _onMessage(Object? message) {
    try {
      if (message is! Map<String, Object?>) {
        throw FormatException('Not a log entry message: ${message.runtimeType}');
      }
      sink.add(logEntryJson.decode(message));
    } on Object catch (error, stackTrace) {
      sink.diagnostics.report(
        LogDiagnostic('IsolateLogReceiver: entry dropped', error: error, stackTrace: stackTrace),
      );
    }
  }
}
