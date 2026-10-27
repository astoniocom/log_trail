import 'package:log_trail/log_trail.dart';
import 'package:log_trail/storage.dart';
import 'package:test/test.dart';

/// A store of `count` entries in store order, as the JSON candidates a SQL store reads; [fetch] records
/// every round. Entry `i` has the message `even i` or `odd i`, entry `rare` the message `rare`.
final class _Candidates {
  _Candidates(int count, {int? rare, this.corruptRejected = false})
    : entries = [
        for (var i = 1; i <= count; i++)
          StoredLogEntry(
            i,
            LogEntry(
              time: DateTime(2026, 1, 1, 12, 0, i),
              level: LogLevel.info,
              message: i == rare ? 'rare' : '${i.isEven ? 'even' : 'odd'} $i',
            ),
          ),
      ];

  final List<StoredLogEntry> entries;
  final List<(LogCursor?, int?)> rounds = [];

  /// Whether candidates other than `even` ones and the rare one carry JSON that does not decode: a test
  /// that passes with this set proves they were rejected on the raw text, before decoding.
  final bool corruptRejected;

  Future<List<LogCandidate>> fetch(LogCursor? after, int? limit) async {
    rounds.add((after, limit));
    var candidates = entries.where((e) => after == null || e.cursor.compareTo(after) > 0);
    if (limit != null) candidates = candidates.take(limit);
    return [
      for (final StoredLogEntry(:id, :entry) in candidates)
        LogCandidate(
          id: id,
          time: entry.time,
          entryJson: corruptRejected && entry.message.startsWith('odd') ? '{not json' : logEntryJsonText.encode(entry),
        ),
    ];
  }
}

final _even = LogTextCondition('EVEN');

void main() {
  test('all candidates accepted: one round of limit + 1, next continues after the last entry', () async {
    final candidates = _Candidates(10);

    final page = await collectLogPage(const LogQuery(limit: 4), fetch: candidates.fetch, textConditions: []);

    expect(page.entries.map((e) => e.id), [1, 2, 3, 4]);
    expect(page.entries.map((e) => e.entry), candidates.entries.take(4).map((e) => e.entry), reason: 'decoded');
    expect(page.next, const LogQuery(limit: 4).startingAfter(candidates.entries[3].cursor));
    expect(candidates.rounds, [(null, 5)]);
  });

  test('the last page has no next, even when exactly full', () async {
    final candidates = _Candidates(4);

    final page = await collectLogPage(const LogQuery(limit: 4), fetch: candidates.fetch, textConditions: []);

    expect(page.entries.map((e) => e.id), [1, 2, 3, 4]);
    expect(page.next, isNull);
  });

  test('rejected candidates: rounds continue after the last candidate read and grow', () async {
    final candidates = _Candidates(1000);

    final page = await collectLogPage(const LogQuery(limit: 10), fetch: candidates.fetch, textConditions: [_even]);

    expect(page.entries.map((e) => e.id), [2, 4, 6, 8, 10, 12, 14, 16, 18, 20]);
    expect(page.next, const LogQuery(limit: 10).startingAfter(candidates.entries[19].cursor));
    expect(candidates.rounds.map((r) => r.$2), [11, 22]);
    expect(
      candidates.rounds[1].$1,
      candidates.entries[10].cursor,
      reason: 'after the 11th candidate, not the 10th entry',
    );
  });

  test('a rare match reads the log in rounds capped at 1000 until the candidates end', () async {
    final candidates = _Candidates(5000, rare: 4999);

    final page = await collectLogPage(
      const LogQuery(limit: 10),
      fetch: candidates.fetch,
      textConditions: [LogTextCondition('rare')],
    );

    expect(page.entries.single.id, 4999);
    expect(page.next, isNull);
    expect(candidates.rounds.map((r) => r.$2), [11, 22, 44, 88, 176, 352, 704, 1000, 1000, 1000, 1000]);
  });

  test('a candidate whose JSON cannot contain the needle is rejected without being decoded', () async {
    final candidates = _Candidates(40, corruptRejected: true);

    final page = await collectLogPage(const LogQuery(limit: 5), fetch: candidates.fetch, textConditions: [_even]);

    expect(page.entries.map((e) => e.id), [2, 4, 6, 8, 10], reason: 'odd candidates have undecodable JSON');
  });

  test('a needle with JSON-escaped characters or the error join is decided after decoding only', () {
    final entry = LogEntry(
      time: DateTime(2026),
      level: LogLevel.error,
      message: 'say "hi"\n',
      error: const LogError(type: 'StateError', message: 'bad'),
    );
    final json = logEntryJsonText.encode(entry);

    for (final needle in ['"hi"', 'hi"\n', 'stateerror: bad', r'\n']) {
      final condition = LogTextCondition(needle);
      expect(condition.mayMatchJson(json), isTrue, reason: '"$needle" is not checked on the JSON text');
      expect(condition.mayMatchJson('{}'), isTrue);
    }
    expect(LogTextCondition('SAY').mayMatchJson(json), isTrue);
    expect(LogTextCondition('Ошибка').mayMatchJson(json), isFalse);
    expect(LogTextCondition('ошибка').mayMatchJson(logEntryJsonText.encode(entry.copyWith(message: 'ОШИБКА'))), isTrue);
  });

  test('a page starting after a cursor passes it to the first round', () async {
    final candidates = _Candidates(30);
    final query = LogQuery(limit: 5, startAfter: candidates.entries[9].cursor);

    final page = await collectLogPage(query, fetch: candidates.fetch, textConditions: [_even]);

    expect(page.entries.map((e) => e.id), [12, 14, 16, 18, 20]);
    expect(candidates.rounds.first, (candidates.entries[9].cursor, 6));
  });

  test('without a limit, all candidates are read in one round and filtered', () async {
    final candidates = _Candidates(7);

    final page = await collectLogPage(const LogQuery(), fetch: candidates.fetch, textConditions: [_even]);

    expect(page.entries.map((e) => e.id), [2, 4, 6]);
    expect(page.next, isNull);
    expect(candidates.rounds, [(null, null)]);
  });
}
