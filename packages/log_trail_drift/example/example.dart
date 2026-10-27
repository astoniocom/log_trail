import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:log_trail/log_trail.dart';
import 'package:log_trail_drift/log_trail_drift.dart';

part 'example.g.dart';

const userId = LogField('example.user_id', LogCodec.string);

/// The log table: the package's columns under a name of your choice, next to
/// the application's own tables.
@DataClassName('LogEntryRow')
@TableIndex(name: 'log_entries_by_time', columns: {#time, #id})
class LogEntries extends Table with LogEntryColumns {}

@DriftDatabase(tables: [LogEntries])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  @override
  int get schemaVersion => 1;
}

Future<void> main() async {
  final directory = Directory.systemTemp.createTempSync('log_trail_drift_example_');
  final path = '${directory.path}/app.sqlite';

  // First run: write a few entries and close everything.
  await _run(path, 'first');
  // Second run: the entries of the first run are still there.
  await _run(path, 'second');

  directory.deleteSync(recursive: true);
}

Future<void> _run(String path, String run) async {
  // The logger exists before the database: early entries are buffered.
  final logger = RootLogger(sinks: [ConsoleSink()]);
  logger.info('Run $run starting');

  // SQLite runs in a background isolate; the store shares the app's database.
  // WAL: one disk sync per log batch instead of two, and reads do not wait for writes.
  final db = AppDatabase(
    NativeDatabase.createInBackground(File(path), setup: (db) => db.execute('PRAGMA journal_mode = WAL')),
  );
  final store = DriftLogStore(db, db.logEntries, limit: 1000);
  // Reads the entry and tag counts now, so that `store.count` below is valid.
  await store.initialize();
  logger
    ..addSink(RepeatCollapsingSink(LogStoreSink(store)))
    ..finishStartup()
    ..setContextAttribute(userId('42'));
  logger.child(tags: {'auth'}).warning('Slow sign-in', attributes: [LogField.details('run $run')]);

  await logger.flush();
  final page = await store.queryEntries(LogQuery(filter: LogFilter(attributes: [userId('42')]), newestFirst: true));
  stdout.writeln('Run $run: ${store.count} entries in the store, ${page.entries.length} for user 42:');
  for (final StoredLogEntry(:id, :entry) in page.entries) {
    stdout.writeln(
      '  #$id ${formatLogTimestamp(entry.time)} ${entry.message} (${entry.attributes.get(LogField.details)})',
    );
  }

  // The logger first, then the database, which the application owns.
  await logger.close();
  await store.close();
  await db.close();
}
