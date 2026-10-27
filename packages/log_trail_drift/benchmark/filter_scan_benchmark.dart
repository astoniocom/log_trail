/// Cost of the unindexed filters of `DriftLogStore` at the documented `limit`:
/// a page by a common tag (stops early), by an attribute value with a few
/// hits and by a rare tag (both read the whole scope), plus `removeBefore`
/// over a large share of the log (the tag counts are rebuilt by `GROUP BY`).
///
/// Run from the package directory: `dart run benchmark/filter_scan_benchmark.dart`.
/// The database is a file in the system temp directory with SQLite in the
/// calling isolate, so the numbers are SQLite's own, without the hop to an
/// executor isolate. Numbers in the `DriftLogStore` docs come from here.
library;

import 'dart:io';
import 'dart:math';

import 'package:drift/native.dart';
import 'package:log_trail/log_trail.dart';
import 'package:log_trail_drift/log_trail_drift.dart';

import '../test/support/test_database.dart';

const _entries = 50000;
const _userId = LogField('bench.user_id', LogCodec.string);

Future<void> main() async {
  final file = File('${Directory.systemTemp.path}/log_trail_drift_benchmark.sqlite');
  if (file.existsSync()) file.deleteSync();
  final db = TestDatabase(NativeDatabase(file));
  final store = DriftLogStore(db, db.logEntries, limit: _entries);
  final random = Random(1);
  const tagSets = [
    {'net'},
    {'auth'},
    {'ui', 'net'},
    {'db'},
    {'sync', 'net'},
  ];
  // A message plus a short stack: the typical size of an entry's JSON.
  final stack = StackTrace.fromString(
    List.generate(8, (i) => '#$i      Frame$i (package:app/file$i.dart:${10 + i}:3)').join('\n'),
  );

  final writing = Stopwatch()..start();
  for (var written = 0; written < _entries; written += 500) {
    await store.writeEntries([
      for (var i = written; i < written + 500; i++)
        LogEntry(
          time: DateTime.utc(2026).add(Duration(milliseconds: i)),
          level: LogLevel.info,
          message: i % 1000 == 7 ? 'Ошибка сети при запросе $i' : 'Запрос $i выполнен, request $i completed',
          tags: tagSets[random.nextInt(tagSets.length)],
          stackTrace: stack,
          attributes: LogAttributes([_userId('${random.nextInt(1000)}')]),
        ),
    ]);
  }
  stdout.writeln(
    'wrote $_entries entries in ${writing.elapsedMilliseconds} ms, file ${(file.lengthSync() / 1e6).toStringAsFixed(1)} MB',
  );

  Future<void> measure(String label, Future<Object?> Function() action) async {
    await action(); // warm-up
    final stopwatch = Stopwatch()..start();
    const runs = 5;
    for (var i = 0; i < runs; i++) {
      await action();
    }
    stdout.writeln(
      '${label.padRight(52)} ${(stopwatch.elapsedMicroseconds / runs / 1000).toStringAsFixed(1).padLeft(7)} ms',
    );
  }

  LogQuery page(LogFilter filter) => LogQuery(filter: filter, newestFirst: true, limit: 100);
  await measure('page, no filter', () => store.queryEntries(page(const LogFilter())));
  await measure(
    'page, common tag (net, ~60% of entries)',
    () => store.queryEntries(page(const LogFilter(tags: {'net'}))),
  );
  await measure('page, rare tag (db, ~20%)', () => store.queryEntries(page(const LogFilter(tags: {'db'}))));
  await measure(
    'page, attribute with ~50 hits (full scan)',
    () => store.queryEntries(page(LogFilter(attributes: [_userId('7')]))),
  );
  await measure(
    'page, attribute with no hits (full scan)',
    () => store.queryEntries(page(LogFilter(attributes: [_userId('none')]))),
  );
  await measure(
    'page, tag no entry carries (no query)',
    () => store.queryEntries(page(const LogFilter(tags: {'nope'}))),
  );
  await measure(
    'page, text search, ASCII needle (prefilter)',
    () => store.queryEntries(page(const LogFilter(text: 'request 4999'))),
  );
  await measure(
    'page, text search, no-hit ASCII needle (scan)',
    () => store.queryEntries(page(const LogFilter(text: 'zzz'))),
  );
  await measure(
    'page, text search, Cyrillic, ~50 hits (scan)',
    () => store.queryEntries(page(const LogFilter(text: 'ошибка'))),
  );
  await measure(
    'page, text search, Cyrillic, no hits (scan)',
    () => store.queryEntries(page(const LogFilter(text: 'нет такого'))),
  );
  await measure(
    'page, text search, Cyrillic, most entries',
    () => store.queryEntries(page(const LogFilter(text: 'запрос'))),
  );
  await measure('queryTags (in memory)', store.queryTags);

  final cutoff = DateTime.utc(2026).add(const Duration(milliseconds: _entries ~/ 2));
  final removing = Stopwatch()..start();
  await store.removeBefore(cutoff);
  stdout.writeln(
    '${'removeBefore over half the log'.padRight(52)} ${removing.elapsedMilliseconds.toString().padLeft(7)} ms, ${store.count} left',
  );

  await store.close();
  await db.close();
  file.deleteSync();
}
