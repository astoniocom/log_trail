/// Cost of text search in `SqliteLogStore` at a 50 000-entry log: a needle the
/// FTS5 trigram index answers (three characters or more, Cyrillic and Latin,
/// rare and common) against one below the index length, which falls back to
/// a scan with the raw JSON check and a decode per candidate.
///
/// Run from the package directory: `dart run benchmark/text_search_benchmark.dart`.
/// The database is a file in the system temp directory. Numbers in the
/// `SqliteLogStore` docs come from here.
library;

import 'dart:io';

import 'package:log_trail/log_trail.dart';
import 'package:log_trail_sqlite/log_trail_sqlite.dart';

const _entries = 50000;

Future<void> main() async {
  final path = '${Directory.systemTemp.path}/log_trail_sqlite_benchmark.sqlite';
  if (File(path).existsSync()) File(path).deleteSync();
  final store = SqliteLogStore.open(path, limit: _entries);
  final stack = StackTrace.fromString(
    List.generate(8, (i) => '#$i      Frame$i (package:app/file$i.dart:${10 + i}:3)').join('\n'),
  );

  final writing = Stopwatch()..start();
  for (var written = 0; written < _entries; written += 500) {
    await store.writeEntries([
      for (var i = written; i < written + 500; i++)
        LogEntry(
          time: DateTime.utc(2026).add(Duration(milliseconds: i)),
          level: i % 1000 == 7 ? LogLevel.error : LogLevel.info,
          message: i % 1000 == 7 ? 'Ошибка сети при запросе $i' : 'Запрос $i выполнен, request completed',
          tags: const {'net'},
          stackTrace: stack,
          error: i % 1000 == 7 ? const LogError(type: 'HttpException', message: 'Timeout exceeded') : null,
        ),
    ]);
  }
  stdout.writeln(
    'wrote $_entries entries in ${writing.elapsedMilliseconds} ms, file ${(File(path).lengthSync() / 1e6).toStringAsFixed(1)} MB',
  );
  // Size per table group, if this SQLite build has the dbstat virtual table.
  try {
    final sizes = store.database.select(
      "SELECT CASE WHEN name LIKE 'log_entry_fts%' THEN 'FTS index' "
      "WHEN name LIKE 'log_entry_texts%' THEN 'FTS content' ELSE 'entries, tags, attributes' END AS part, "
      'SUM(pgsize) AS bytes FROM dbstat GROUP BY part ORDER BY part',
    );
    for (final row in sizes) {
      stdout.writeln(
        '  ${(row['part'] as String).padRight(28)} ${((row['bytes'] as int) / 1e6).toStringAsFixed(1).padLeft(6)} MB',
      );
    }
  } on Object {
    stdout.writeln('  (dbstat unavailable: no per-table sizes)');
  }

  Future<void> measure(String label, String text) async {
    final query = LogQuery(filter: LogFilter(text: text), newestFirst: true, limit: 100);
    await store.queryEntries(query); // warm-up
    final stopwatch = Stopwatch()..start();
    const runs = 5;
    var hits = 0;
    for (var i = 0; i < runs; i++) {
      hits = (await store.queryEntries(query)).entries.length;
    }
    stdout.writeln(
      '${label.padRight(52)} ${(stopwatch.elapsedMicroseconds / runs / 1000).toStringAsFixed(1).padLeft(7)} ms  hits=$hits',
    );
  }

  await measure('indexed, Cyrillic, ~50 hits ("ошибка")', 'ошибка');
  await measure('indexed, Cyrillic, no hits ("нет такого")', 'нет такого');
  await measure('indexed, Cyrillic, most entries ("запрос")', 'запрос');
  await measure('indexed, Latin, ~50 hits in error text ("timeout")', 'timeout');
  await measure('indexed, Latin, no hits ("zzz")', 'zzz');
  await measure('indexed, digits, one hit ("49999")', '49999');
  await measure('below index length, Cyrillic, ~50 hits ("ош")', 'ош');
  await measure('below index length, Latin, no hits ("zz")', 'zz');

  await store.close();
  File(path).deleteSync();
}
