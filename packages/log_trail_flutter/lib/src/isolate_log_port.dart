import 'dart:isolate';
import 'dart:ui';

/// Default name under which the main isolate's spool notification port is
/// registered.
const String defaultIsolateLogPortName = 'log_trail';

/// Registers [port] (`LogSpoolReceiver.sendPort`) under [name] so that
/// engine-started isolates (FCM handler, WorkManager) can find it: they cannot
/// be handed a port at spawn. The port is only a "file appeared in the spool"
/// notification; the entries themselves are in the spool (`LogSpool`), so a
/// missing or dead port loses nothing.
///
/// A previous registration under the same name is replaced: after a hot
/// restart, or after the system killed the main isolate but kept the process,
/// it points at the port of an isolate that has already exited. Throws
/// [StateError] if the name was taken between removal and registration.
///
/// ```dart
/// final receiver = LogSpoolReceiver(LogSpool(spoolDirectory), logger.asSink());
/// registerIsolateLogPort(receiver.sendPort);
/// ```
void registerIsolateLogPort(SendPort port, {String name = defaultIsolateLogPortName}) {
  IsolateNameServer.removePortNameMapping(name);
  if (!IsolateNameServer.registerPortWithName(port, name)) {
    throw StateError('Isolate log port name "$name" was registered concurrently');
  }
}

/// The main isolate's notification port registered by [registerIsolateLogPort],
/// or `null` if there is no main isolate (e.g. the system started only the
/// background FCM handler) or it has not registered a port. The background
/// isolate writes to the spool either way and passes the port as a
/// notification when present:
///
/// ```dart
/// final logger = RootLogger(
///   sinks: [LogSpoolSink(LogSpool(spoolDirectory), notify: lookupIsolateLogPort())],
///   // The background isolate exits without waiting for an event-loop turn.
///   dispatch: LogDispatchPolicy.synchronous,
/// )..finishStartup();
/// ```
///
/// [IsolateNameServer] is shared by all isolates of the process, including
/// isolates of other groups started by other `FlutterEngine`s, but not by
/// other processes (iOS extensions, a service in its own `android:process`):
/// the port is not visible from there, and entries arrive through the spool at
/// the next import.
SendPort? lookupIsolateLogPort({String name = defaultIsolateLogPortName}) => IsolateNameServer.lookupPortByName(name);

/// Removes the [name] registration, e.g. before `LogSpoolReceiver.close`:
/// background isolates stop notifying a closed port. Entry delivery is not
/// affected: entries stay in the spool until the next import.
void unregisterIsolateLogPort({String name = defaultIsolateLogPortName}) =>
    IsolateNameServer.removePortNameMapping(name);
