import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:log_trail/isolates.dart';
import 'package:log_trail/log_trail.dart';
import 'package:log_trail/testing.dart';
import 'package:test/test.dart';

const _jobId = LogField('test.job_id', LogCodec.integer);

/// [RecordingLogSink] with a hook at flush time: checks state while the spool file still exists.
final class _RecordingSink extends RecordingLogSink {
  void Function()? onFlushed;

  @override
  Future<void> onFlush() {
    onFlushed?.call();
    return super.onFlush();
  }
}

LogEntry _entry(String message, [int second = 0]) =>
    LogEntry(time: DateTime.utc(2026, 1, 1, 12, 0, second), level: LogLevel.info, message: message);

/// Background isolate body: own root writing to the spool with notification.
void _work(String spoolPath, SendPort? notify) {
  final logger = RootLogger(
    sinks: [LogSpoolSink(LogSpool(Directory(spoolPath)), notify: notify)],
    dispatch: LogDispatchPolicy.synchronous,
  )..finishStartup();
  final log = logger.child(tags: {'sync'})..log('Sync started', attributes: [_jobId(7)]);
  try {
    throw const FormatException('disk full');
  } on FormatException catch (error, stackTrace) {
    log.recordError(error, stackTrace, message: 'Sync failed');
  }
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 200 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late Directory directory;
  late LogSpool spool;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('log_spool_test');
    spool = LogSpool(directory);
  });

  tearDown(() => directory.delete(recursive: true));

  List<String> fileNames() => [
    for (final entity in directory.listSync()) entity.uri.pathSegments.last,
  ]..sort();

  group('LogSpoolSink', () {
    test('batch is written as one complete JSON-lines file; no temp file remains', () {
      final sink = LogSpoolSink(spool)
        ..add(_entry('a', 1))
        ..add(_entry('b', 2))
        ..endBatch();

      final names = fileNames();
      expect(names, hasLength(1));
      expect(names.single, endsWith(LogSpool.fileExtension));
      expect(names.single, isNot(endsWith(LogSpool.pendingExtension)));
      final lines = File('${directory.path}/${names.single}').readAsLinesSync();
      expect(lines, hasLength(2));
      final decoded = [for (final line in lines) logEntryJson.decode(jsonDecode(line) as Map<String, Object?>)];
      expect(decoded, [_entry('a', 1), _entry('b', 2)]);
      expect(sink.isClosed, isFalse);
    });

    test('each batch is its own file, names follow write order', () {
      final sink = LogSpoolSink(spool);
      for (var i = 0; i < 3; i++) {
        sink
          ..add(_entry('e$i'))
          ..endBatch();
      }

      final names = fileNames();
      expect(names, hasLength(3));
      expect(names, orderedEquals([...names]..sort()));
    });

    test('empty batch end creates no file; flush and close write pending entries', () async {
      final sink = LogSpoolSink(spool)..endBatch();
      expect(fileNames(), isEmpty);

      sink.add(_entry('flushed'));
      await sink.flush();
      expect(fileNames(), hasLength(1));

      sink.add(_entry('closed'));
      await sink.close();
      expect(fileNames(), hasLength(2));
    });

    test('creates the spool directory on first write', () {
      final nested = LogSpool(Directory('${directory.path}/nested/spool'));

      LogSpoolSink(nested)
        ..add(_entry('a'))
        ..endBatch();

      expect(nested.directory.existsSync(), isTrue);
      expect(nested.directory.listSync(), hasLength(1));
    });

    test('notifies the port with the file path after writing it', () async {
      final port = ReceivePort();
      addTearDown(port.close);
      final notifications = <Object?>[];
      port.listen(notifications.add);

      LogSpoolSink(spool, notify: port.sendPort)
        ..add(_entry('a'))
        ..endBatch();
      await _until(() => notifications.isNotEmpty);

      expect(notifications.single, '${directory.path}/${fileNames().single}');
    });

    test('write failure goes to diagnostics, the batch is lost, later ones are written', () {
      final diagnostics = <LogDiagnostic>[];
      // A file where the directory should be: it cannot be created.
      final blocked = File('${directory.path}/blocked')..writeAsStringSync('');
      final sink = LogSpoolSink(LogSpool(Directory(blocked.path)))..attach(DiagnosticReporter(diagnostics.add));

      sink
        ..add(_entry('lost'))
        ..endBatch();

      expect(diagnostics.single.message, 'LogSpoolSink: failed to write 1 entries');
      expect(diagnostics.single.error, isA<FileSystemException>());
    });
  });

  group('LogSpool.importInto', () {
    test('imports files in order, flushes the sink before deleting and deletes them', () async {
      LogSpoolSink(spool)
        ..add(_entry('first', 1))
        ..endBatch()
        ..add(_entry('second', 2))
        ..add(_entry('third', 3))
        ..endBatch();
      final sink = _RecordingSink();
      final filesAtFlush = <int>[];
      sink.onFlushed = () => filesAtFlush.add(fileNames().length);

      final imported = await spool.importInto(sink);

      expect(imported, 3);
      expect(sink.messages, ['first', 'second', 'third']);
      expect(sink.flushCount, 2, reason: 'one flush per file');
      expect(filesAtFlush, [2, 1], reason: 'file still exists at flush time: deleted after it');
      expect(fileNames(), isEmpty);
    });

    test("a file larger than the main root's queueLimit is imported through asSink without loss", () async {
      final spoolSink = LogSpoolSink(spool);
      for (var i = 0; i < 1500; i++) {
        spoolSink.add(_entry('m$i', i % 60));
      }
      spoolSink.endBatch();
      expect(fileNames(), hasLength(1), reason: 'one batch, one file of 1500 lines');
      final sink = _RecordingSink();
      final diagnostics = <LogDiagnostic>[];
      final logger = RootLogger(
        sinks: [sink],
        dispatch: const LogDispatchPolicy(queueLimit: 100),
        diagnostics: DiagnosticReporter(diagnostics.add),
      )..finishStartup();
      addTearDown(logger.close);

      final imported = await spool.importInto(logger.asSink());

      expect(imported, 1500);
      expect(sink.entries, hasLength(1500), reason: 'at least once: nothing dropped on the way into the root');
      expect(sink.messages.first, 'm0');
      expect(sink.messages.last, 'm1499');
      expect(sink.entries.every((e) => e.level == LogLevel.info), isTrue, reason: 'no overflow warnings');
      expect(diagnostics, isEmpty);
      expect(fileNames(), isEmpty);
    });

    test(
      'a background root with regular dispatch logging more than queueLimit in one pass spools everything',
      () async {
        final background = RootLogger(
          sinks: [LogSpoolSink(spool)],
          dispatch: const LogDispatchPolicy(queueLimit: 100),
          startupBufferTimeout: null,
        )..finishStartup();
        for (var i = 0; i < 250; i++) {
          background.log('m$i');
        }
        await background.close();

        expect(fileNames(), hasLength(3), reason: 'two full batches inside the calls, the remainder on close');
        final sink = _RecordingSink();
        expect(await spool.importInto(sink), 250);
        expect(sink.messages.first, 'm0');
        expect(sink.messages.last, 'm249');
      },
    );

    test('does nothing without a directory or files', () async {
      final sink = _RecordingSink();

      expect(await LogSpool(Directory('${directory.path}/missing')).importInto(sink), 0);
      expect(await spool.importInto(sink), 0);
      expect(sink.entries, isEmpty);
      expect(sink.flushCount, 0);
    });

    test('leaves writer temp files alone', () async {
      File('${directory.path}/0-1-1-000000${LogSpool.pendingExtension}').writeAsStringSync('{"half": ');
      final sink = _RecordingSink();

      expect(await spool.importInto(sink), 0);
      expect(fileNames(), hasLength(1));
    });

    test('corrupt line is skipped with diagnostics, the rest are imported, the file is deleted', () async {
      final good = jsonEncode(logEntryJson.encode(_entry('good')));
      File('${directory.path}/0-1-1-000000${LogSpool.fileExtension}').writeAsStringSync('$good\nnot json\n{"no":1}\n');
      final sink = _RecordingSink();
      final diagnostics = <LogDiagnostic>[];
      sink.attach(DiagnosticReporter(diagnostics.add));

      final imported = await spool.importInto(sink);

      expect(imported, 1);
      expect(sink.messages, ['good']);
      expect(diagnostics, hasLength(2));
      expect(diagnostics.map((d) => d.message), everyElement(startsWith('LogSpool: entry dropped from ')));
      expect(diagnostics.map((d) => d.error), everyElement(isA<FormatException>()));
      expect(fileNames(), isEmpty);
    });

    test('sink failure while importing a file goes to diagnostics and does not block other files', () async {
      LogSpoolSink(spool)
        ..add(_entry('a'))
        ..endBatch()
        ..add(_entry('b'))
        ..endBatch();
      final sink = _RecordingSink();
      final diagnostics = <LogDiagnostic>[];
      sink.attach(DiagnosticReporter(diagnostics.add));
      var flushes = 0;
      sink.onFlushed = () {
        if (++flushes == 1) throw StateError('store down');
      };

      final imported = await spool.importInto(sink);

      expect(imported, 1, reason: 'first file entries added, but its import did not finish');
      expect(sink.messages, ['a', 'b']);
      expect(diagnostics.single.message, startsWith('LogSpool: failed to import '));
      expect(fileNames(), hasLength(1), reason: 'failed file is kept for re-import');
    });
  });

  group('LogSpoolReceiver', () {
    test('imports on creation, on notification and on importNow', () async {
      LogSpoolSink(spool)
        ..add(_entry('at start'))
        ..endBatch();
      final sink = _RecordingSink();
      final receiver = LogSpoolReceiver(spool, sink);
      addTearDown(receiver.close);
      await _until(() => sink.entries.isNotEmpty);
      expect(sink.messages, ['at start']);

      LogSpoolSink(spool, notify: receiver.sendPort)
        ..add(_entry('notified'))
        ..endBatch();
      await _until(() => sink.entries.length == 2);
      expect(sink.messages, ['at start', 'notified']);

      LogSpoolSink(spool)
        ..add(_entry('silent'))
        ..endBatch();
      expect(await receiver.importNow(), 1);
      expect(sink.messages, ['at start', 'notified', 'silent']);
    });

    test('notification during import starts another import after the current one', () async {
      final sink = _RecordingSink();
      final receiver = LogSpoolReceiver(spool, sink);
      addTearDown(receiver.close);
      await receiver.importNow();

      final gate = Completer<void>();
      LogSpoolSink(spool)
        ..add(_entry('a'))
        ..endBatch();
      sink.onFlushed = () => gate.future;
      final first = receiver.importNow();
      // While the first import awaits flush, a new file and notification arrive.
      LogSpoolSink(spool, notify: receiver.sendPort)
        ..add(_entry('b'))
        ..endBatch();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      sink.onFlushed = null;
      gate.complete();

      expect(await first, 2, reason: 'second file picked up by the same import cycle');
      expect(sink.messages, ['a', 'b']);
      expect(fileNames(), isEmpty);
    });

    test('garbage in the port only triggers an import', () async {
      final sink = _RecordingSink();
      final diagnostics = <LogDiagnostic>[];
      sink.attach(DiagnosticReporter(diagnostics.add));
      final receiver = LogSpoolReceiver(spool, sink);
      addTearDown(receiver.close);

      LogSpoolSink(spool)
        ..add(_entry('a'))
        ..endBatch();
      receiver.sendPort.send(42);
      await _until(() => sink.entries.isNotEmpty);

      expect(sink.messages, ['a']);
      expect(diagnostics, isEmpty);
    });

    test('after close notifications are ignored, files stay until the next import', () async {
      final sink = _RecordingSink();
      final receiver = LogSpoolReceiver(spool, sink);
      await receiver.importNow();
      await receiver.close();

      LogSpoolSink(spool, notify: receiver.sendPort)
        ..add(_entry('late'))
        ..endBatch();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(sink.entries, isEmpty);
      expect(fileNames(), hasLength(1));
    });
  });

  group('background isolate', () {
    test('entries reach the main isolate via the spool with tags, attributes, error and stack', () async {
      final sink = _RecordingSink();
      final receiver = LogSpoolReceiver(spool, sink);
      addTearDown(receiver.close);
      final path = directory.path;
      final notify = receiver.sendPort;

      await Isolate.run(() => _work(path, notify));
      await _until(() => sink.entries.length == 2);

      expect(sink.messages, ['Sync started', 'Sync failed']);
      expect(sink.entries[0].tags, {'sync'});
      expect(sink.entries[0].attributes.get(_jobId), 7);
      final failed = sink.entries[1];
      expect(failed.error, const LogError(type: 'FormatException', message: 'FormatException: disk full'));
      expect(failed.error?.original, isNull, reason: 'live error object does not survive the disk');
      expect(failed.stackTrace.toString(), contains('_work'));
      expect(fileNames(), isEmpty);
    });

    test('without a port entries wait in the spool and import on the next main isolate start', () async {
      final path = directory.path;
      await Isolate.run(() => _work(path, null));
      expect(fileNames(), hasLength(2), reason: 'no main isolate: files still there');

      final sink = _RecordingSink();
      final receiver = LogSpoolReceiver(spool, sink);
      addTearDown(receiver.close);
      await _until(() => sink.entries.length == 2);

      expect(sink.messages, ['Sync started', 'Sync failed']);
      expect(fileNames(), isEmpty);
    });

    test('dead port loses nothing: files stay until import', () async {
      final dead = ReceivePort()..close();
      final deadPort = dead.sendPort;
      final path = directory.path;

      await Isolate.run(() => _work(path, deadPort));

      expect(fileNames(), hasLength(2));
      final sink = _RecordingSink();
      expect(await spool.importInto(sink), 2);
    });

    test('entries arrive from an isolate of another group with nested attributes', () async {
      const payload = LogField('test.payload', LogCodec.raw);
      final sink = _RecordingSink();
      final receiver = LogSpoolReceiver(spool, sink);
      addTearDown(receiver.close);

      await Isolate.spawnUri(
        Directory.current.uri.resolve('test/isolate_group_worker.dart'),
        [directory.path],
        receiver.sendPort,
        packageConfig: await Isolate.packageConfig,
      );
      await _until(() => sink.entries.isNotEmpty);

      final entry = sink.entries.single;
      expect(entry.message, 'from another group');
      expect(entry.tags, {'fcm'});
      expect(
        entry.attributes.get(payload),
        LogMap({
          'ids': LogList(const [LogInt(1), LogInt(2)]),
        }),
      );
    });

    test('in the main isolate entries pass through the root: threshold and redaction', () async {
      final sink = _RecordingSink();
      final logger = RootLogger(
        dispatch: LogDispatchPolicy.synchronous,
        sinks: [sink],
        floor: LogLevel.info,
        processors: const [
          LogRedactor(patterns: ['disk']),
        ],
      )..finishStartup();
      final receiver = LogSpoolReceiver(spool, logger.asSink());
      addTearDown(receiver.close);
      final path = directory.path;
      final notify = receiver.sendPort;

      await Isolate.run(() => _work(path, notify));
      await _until(() => sink.entries.length == 2);

      expect(sink.entries[1].error?.message, 'FormatException: [REDACTED] full');
    });
  });
}
