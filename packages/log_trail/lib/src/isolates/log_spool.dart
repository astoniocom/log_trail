import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:log_trail/src/diagnostics/log_diagnostic.dart';
import 'package:log_trail/src/entry/log_entry.dart';
import 'package:log_trail/src/format/log_entry_json_codec.dart';
import 'package:log_trail/src/sinks/log_sink.dart';

/// Spool of background-isolate entries: a directory where isolates started by
/// the engine (FCM handler, WorkManager) or by the app write entry files
/// ([LogSpoolSink]), and the main isolate picks them up ([importInto],
/// [LogSpoolReceiver]) and runs them through its root logger alongside its
/// own entries.
///
/// The spool is the source of truth: an entry counts as delivered once its
/// file is in the directory, not once the main isolate received it. So the
/// background isolate does not care whether a main isolate exists, whether
/// its port is alive, or whether it is in the same process: it writes the file
/// and exits. The main isolate picks files up at startup, on a port
/// notification ([LogSpoolReceiver]), and whenever it chooses
/// ([LogSpoolReceiver.importNow], e.g. on resume from background). Thus only
/// one isolate writes the main store, and neither its counters nor its
/// eviction diverge from a second writer.
///
/// Each batch is a separate `*.jsonl` file (one entry per line in
/// [logEntryJson] format), written to a temporary file with `fsync` and
/// renamed atomically: a file in the directory is either absent or complete.
/// So writers and import need no locks, never read half-written lines, and
/// never lose entries added during an import. The file name starts with the
/// write time, process id and isolate id, so files from different writers do
/// not collide and import follows write order.
///
/// Both ends configure the same directory, e.g.
/// `Directory(p.join(supportDir.path, 'log_spool'))`; the main isolate creates
/// it on import, the writer on its first write.
final class LogSpool {
  LogSpool(this.directory);

  /// Spool directory.
  final Directory directory;

  /// Extension of a complete entry file.
  static const String fileExtension = '.jsonl';

  /// Extension of a file the writer is still filling; import ignores it.
  static const String pendingExtension = '.jsonl.tmp';

  /// Complete entry files in write order (by name).
  Future<List<File>> files() async {
    if (!directory.existsSync()) return const [];
    final files = [
      await for (final entity in directory.list())
        if (entity is File && entity.path.endsWith(fileExtension)) entity,
    ];
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  /// Imports all complete files into [sink]: each entry goes to [LogSink.add],
  /// and the file is deleted after [LogSink.flush]. Returns the number of
  /// entries passed.
  ///
  /// A file is deleted only after the sink has delivered its entries
  /// ([LogSink.flush]; for `RootLogger.asSink` that is the store write), so a
  /// failure between add and delete re-imports the same file instead of losing
  /// it: background-isolate entries are delivered at least once. A corrupt
  /// line is skipped with a message in the sink's [LogSink.diagnostics]; the
  /// remaining lines are imported and the file is deleted, otherwise it would
  /// be imported forever. A read or delete failure also goes to diagnostics
  /// and does not block the other files.
  Future<int> importInto(LogSink sink) async {
    var imported = 0;
    for (final file in await files()) {
      try {
        imported += await _importFile(file, sink);
      } on Object catch (error, stackTrace) {
        sink.diagnostics.report(
          LogDiagnostic('LogSpool: failed to import ${file.path}', error: error, stackTrace: stackTrace),
        );
      }
    }
    return imported;
  }

  Future<int> _importFile(File file, LogSink sink) async {
    var imported = 0;
    for (final line in const LineSplitter().convert(await file.readAsString())) {
      if (line.isEmpty) continue;
      try {
        sink.add(logEntryJsonText.decode(line));
        imported++;
      } on Object catch (error, stackTrace) {
        sink.diagnostics.report(
          LogDiagnostic('LogSpool: entry dropped from ${file.path}', error: error, stackTrace: stackTrace),
        );
      }
    }
    await sink.flush();
    await file.delete();
    return imported;
  }
}

/// Background-isolate sink that writes entries to [spool].
///
/// Entries accepted since the last batch end go out as one file at batch end
/// ([LogSink.endBatch], reported by the root after each dispatch), on
/// [LogSink.flush] and on [LogSink.close]. The file is written synchronously
/// with `fsync`: a background isolate often exits right after its work
/// ([Isolate.run], FCM handler), and the entry must be on disk before the call
/// that logged it returns.
///
/// How many entries share a file is decided by the background root's
/// dispatch: with `LogDispatchPolicy.synchronous` each entry is dispatched in
/// the logger call and goes out in its own file at once, which is the most
/// reliable for an isolate that may be killed at any moment; with regular
/// dispatch the entries of one event-loop turn share a file (at most
/// `LogDispatchPolicy.queueLimit` per file: a fuller queue is dispatched in
/// the call), and `await logger.close()` at the end of the work flushes the
/// rest.
///
/// After writing a file, a notification is sent to [notify] (the main
/// isolate's [LogSpoolReceiver] port; in Flutter it is looked up by name via
/// `lookupIsolateLogPort`) so the main isolate picks the file up now rather
/// than at next startup. The notification is only a signal: if the port is
/// missing, closed, or its isolate has exited, the file is still imported
/// later.
///
/// A write failure (no space, directory unavailable) goes to [diagnostics] and
/// the batch is lost: there is nowhere to retry.
///
/// ```dart
/// Future<void> onBackgroundMessage(RemoteMessage message) async {
///   final logger = RootLogger(
///     sinks: [LogSpoolSink(LogSpool(spoolDirectory), notify: lookupIsolateLogPort())],
///     dispatch: LogDispatchPolicy.synchronous,
///   )..finishStartup();
///   logger.child(tags: {'fcm'}).log('Message received');
/// }
/// ```
final class LogSpoolSink extends LogSink {
  LogSpoolSink(this.spool, {this.notify});

  final LogSpool spool;

  /// Where to announce a new file; `null` means do not announce.
  final SendPort? notify;

  final List<LogEntry> _pending = [];
  int _sequence = 0;

  @override
  String get name => 'LogSpoolSink';

  @override
  void onAdd(LogEntry entry) => _pending.add(entry);

  @override
  void onBatchEnd() => _writePending();

  @override
  Future<void> onFlush() async => _writePending();

  @override
  Future<void> onClose() async => _writePending();

  void _writePending() {
    if (_pending.isEmpty) return;
    final batch = List.of(_pending);
    _pending.clear();
    final File file;
    try {
      file = _write(batch);
    } on Object catch (error, stackTrace) {
      diagnostics.report(
        LogDiagnostic('LogSpoolSink: failed to write ${batch.length} entries', error: error, stackTrace: stackTrace),
      );
      return;
    }
    notify?.send(file.path);
  }

  /// Writes [batch] to a temporary file with `fsync` and renames it to the
  /// complete name: a reader sees either the whole file or none.
  File _write(List<LogEntry> batch) {
    final directory = spool.directory..createSync(recursive: true);
    final base = '${directory.path}${Platform.pathSeparator}${_fileStem()}';
    final pending = File('$base${LogSpool.pendingExtension}')
      ..writeAsStringSync([for (final entry in batch) '${logEntryJsonText.encode(entry)}\n'].join(), flush: true);
    return pending.renameSync('$base${LogSpool.fileExtension}');
  }

  /// Name without extension: time (import order), process and isolate
  /// (different writers do not collide), sequence number within this sink
  /// (two files in the same microsecond).
  String _fileStem() {
    final micros = DateTime.now().microsecondsSinceEpoch.toString().padLeft(16, '0');
    final isolate = Isolate.current.hashCode.toRadixString(16);
    final sequence = (_sequence++).toString().padLeft(6, '0');
    return '$micros-$pid-$isolate-$sequence';
  }
}

/// Receives entries from [spool] in the main isolate: imports into [sink]
/// (usually `RootLogger.asSink`) on creation, on every notification to
/// [sendPort] from [LogSpoolSink], and on [importNow].
///
/// ```dart
/// final receiver = LogSpoolReceiver(LogSpool(spoolDirectory), logger.asSink());
/// registerIsolateLogPort(receiver.sendPort); // Flutter: port for engine-started isolates
/// AppLifecycleListener(onResume: () => unawaited(receiver.importNow()));
/// ```
///
/// Imports do not run concurrently: a notification during an import starts
/// another one after the current. Port messages carry no entries and their
/// content is irrelevant: garbage in the port merely triggers an import. Until
/// the receiver is closed ([close]), the port keeps the isolate alive.
final class LogSpoolReceiver {
  LogSpoolReceiver(this.spool, this.sink) {
    _subscription = _port.listen((_) => unawaited(importNow()));
    unawaited(importNow());
  }

  final LogSpool spool;

  /// Entry recipient; its [LogSink.diagnostics] also carries import
  /// diagnostics.
  final LogSink sink;

  final ReceivePort _port = ReceivePort('LogSpoolReceiver');
  late final StreamSubscription<Object?> _subscription;
  Future<int>? _importing;
  bool _isImportRequested = false;

  /// Port for [LogSpoolSink.notify] of background isolates.
  SendPort get sendPort => _port.sendPort;

  /// Imports the complete spool files. If an import is already running, waits
  /// for it and starts the next one: files that appeared during an import do
  /// not wait for the next notification. Returns the number of entries
  /// imported by this call (or by the import it joined).
  Future<int> importNow() {
    if (_importing case final importing?) {
      _isImportRequested = true;
      return importing;
    }
    return _importing = _importLoop();
  }

  Future<int> _importLoop() async {
    var total = 0;
    try {
      do {
        _isImportRequested = false;
        total += await spool.importInto(sink);
      } while (_isImportRequested);
    } finally {
      _importing = null;
    }
    return total;
  }

  /// Stops receiving notifications; a running import completes. [sink] is not
  /// closed: the caller owns it.
  Future<void> close() async {
    _port.close();
    await _subscription.cancel();
  }
}
