import 'dart:convert';

import 'package:log_trail/log_trail.dart';
import 'package:log_trail/storage.dart';
import 'package:test/test.dart';

const _userId = LogField('test.user_id', LogCodec.string);

LogEntry _entry(int second, String message, {LogLevel level = LogLevel.info, Set<String> tags = const {}}) =>
    LogEntry(time: DateTime(2026, 10, 24, 18, 0, second, 7), level: level, message: message, tags: tags);

void main() {
  late InMemoryLogStore store;

  setUp(() => store = InMemoryLogStore());
  tearDown(() => store.close());

  test('text: entry is readable without tools, details as indented lines', () async {
    await store.writeEntries([
      _entry(1, 'App started', tags: {'app'}),
      LogEntry(
        time: DateTime(2026, 10, 24, 18, 0, 2, 7),
        level: LogLevel.error,
        message: 'Failed to load profile',
        tags: const {'network'},
        location: 'Api.fetch (package:app/api.dart:10:5)',
        stackTrace: StackTrace.fromString(
          '#0      Api.fetch (package:app/api.dart:10:5)\n#1      main (package:app/main.dart:3:1)',
        ),
        error: LogError.capture(StateError('timeout')),
        attributes: LogAttributes([_userId('42')]),
      ),
    ]);
    final output = StringBuffer();

    final count = await exportLog(store, output);

    expect(count, 2);
    expect(
      '$output',
      '2026-10-24 18:00:01.007 INFO [app] App started\n'
          '2026-10-24 18:00:02.007 ERROR [network] Failed to load profile\n'
          '  error: StateError: Bad state: timeout\n'
          '  at: Api.fetch (package:app/api.dart:10:5)\n'
          '  test.user_id: 42\n'
          '  stack:\n'
          '    #0      Api.fetch (package:app/api.dart:10:5)\n'
          '    #1      main (package:app/main.dart:3:1)\n',
    );
  });

  test('jsonLines: each line reads back into an equal entry', () async {
    final entries = [
      _entry(1, 'a', tags: {'x'}),
      _entry(2, 'b'),
    ];
    await store.writeEntries(entries);
    final output = StringBuffer();

    await exportLog(store, output, format: LogExportFormat.jsonLines);

    final restored = [
      for (final line in const LineSplitter().convert('$output'))
        logEntryJson.decode(jsonDecode(line) as Map<String, Object?>),
    ];
    expect(restored, entries);
  });

  test('exports all pages by filter, oldest first', () async {
    await store.writeEntries([
      for (var i = 0; i < 7; i++) _entry(i, 'm$i', level: i.isEven ? LogLevel.error : LogLevel.info),
    ]);
    final output = StringBuffer();

    final count = await exportLog(
      store,
      output,
      filter: const LogFilter(levels: {LogLevel.error}),
      format: LogExportFormat.jsonLines,
      pageSize: 2,
    );

    expect(count, 4);
    final messages = [
      for (final line in const LineSplitter().convert('$output'))
        logEntryJson.decode(jsonDecode(line) as Map<String, Object?>).message,
    ];
    expect(messages, ['m0', 'm2', 'm4', 'm6']);
  });
}
