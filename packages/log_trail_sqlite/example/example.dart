import 'dart:io';

import 'package:log_trail/log_trail.dart';
import 'package:log_trail_sqlite/log_trail_sqlite.dart';

const userId = LogField('example.user_id', LogCodec.string);

Future<void> main() async {
  final directory = Directory.systemTemp.createTempSync('log_trail_sqlite_example_');
  final path = '${directory.path}/log.sqlite';

  // First run: write a few entries and close everything.
  await _run(path, 'first');
  // Second run: the entries of the first run are still there.
  await _run(path, 'second');

  directory.deleteSync(recursive: true);
}

Future<void> _run(String path, String run) async {
  final logger = RootLogger(sinks: [ConsoleSink()]);
  logger.info('Run $run starting');

  // The store opens synchronously; keep at most 1000 entries.
  final store = SqliteLogStore.open(path, limit: 1000);
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

  await logger.close();
  await store.close();
}
