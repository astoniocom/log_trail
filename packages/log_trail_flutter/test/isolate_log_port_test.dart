import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:log_trail/testing.dart';
import 'package:log_trail_flutter/isolates.dart';
import 'package:log_trail_flutter/log_trail_flutter.dart';

void main() {
  const name = 'log_trail_test';

  tearDown(() => unregisterIsolateLogPort(name: name));

  test('no port without registration', () {
    expect(lookupIsolateLogPort(name: name), isNull);
  });

  test('a registered port is found by name, re-registration replaces the previous one', () {
    final stale = ReceivePort();
    final current = ReceivePort();
    addTearDown(stale.close);
    addTearDown(current.close);

    registerIsolateLogPort(stale.sendPort, name: name);
    registerIsolateLogPort(current.sendPort, name: name);

    expect(lookupIsolateLogPort(name: name), current.sendPort);
  });

  test('after unregister the port is not found', () {
    final port = ReceivePort();
    addTearDown(port.close);

    registerIsolateLogPort(port.sendPort, name: name);
    unregisterIsolateLogPort(name: name);

    expect(lookupIsolateLogPort(name: name), isNull);
  });

  test('a notification via the port found by name starts the spool import in the main isolate', () async {
    final directory = Directory.systemTemp.createTempSync('isolate_log_port_test');
    addTearDown(() => directory.delete(recursive: true));
    final spool = LogSpool(directory);
    final sink = RecordingLogSink();
    final receiver = LogSpoolReceiver(spool, sink);
    addTearDown(receiver.close);
    await receiver.importNow();
    registerIsolateLogPort(receiver.sendPort, name: name);

    LogSpoolSink(spool, notify: lookupIsolateLogPort(name: name))
      ..add(LogEntry(time: DateTime(2026), level: LogLevel.info, message: 'from background'))
      ..endBatch();
    for (var i = 0; i < 50 && sink.entries.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(sink.entries.single.message, 'from background');
    expect(directory.listSync(), isEmpty, reason: 'the file was consumed');
  });
}
