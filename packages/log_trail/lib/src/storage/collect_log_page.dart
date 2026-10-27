import 'dart:math' as math;

import 'package:log_trail/src/format/log_entry_json_codec.dart';
import 'package:log_trail/src/storage/log_condition.dart';
import 'package:log_trail/src/storage/log_query.dart';
import 'package:log_trail/src/storage/stored_log_entry.dart';
import 'package:meta/meta.dart';

/// A row a store read for [collectLogPage]: the entry still as its JSON text ([logEntryJsonText]), with
/// the columns that give its position in store order. Decoded only once it has passed the raw text check
/// ([LogTextCondition.mayMatchJson]) of every text condition.
@immutable
final class LogCandidate {
  const LogCandidate({required this.id, required this.time, required this.entryJson});

  final int id;
  final DateTime time;
  final String entryJson;

  LogCursor get cursor => LogCursor(time, id);
}

/// Reads candidates for a page in query order, strictly after [after] (`null`: from the start), at most
/// [limit] of them (`null`: all). See [collectLogPage].
typedef LogCandidateFetch = Future<List<LogCandidate>> Function(LogCursor? after, int? limit);

/// Largest number of candidates read in one round by [collectLogPage].
const int _maxRound = 1000;

/// Builds the page of [query] for a store whose query language selects only candidates and leaves the
/// text conditions ([textConditions]) to Dart: SQL narrows (an FTS index or
/// [LogTextCondition.prefilterTokens]), [LogTextCondition.matches] decides.
///
/// [fetch] reads candidates in query order. Each is first checked on its JSON text
/// ([LogTextCondition.mayMatchJson]), which costs a fraction of decoding it; only a candidate that passes
/// is decoded and tested with [LogTextCondition.matches]. Candidates are read until [LogQuery.limit] + 1 are
/// accepted (the extra one decides [LogPage.next] without a count) or they end. The first round reads
/// exactly `limit + 1` rows, so a query whose candidates are all accepted costs the same as a plain page;
/// when candidates are rejected, the next rounds continue after the last candidate read and grow
/// (doubling up to [_maxRound]), so a rare match in a large log costs tens of round trips, not a scan into
/// memory. Without a limit, all candidates are read in one round. [LogPage.next] continues after the last
/// accepted entry, as with any store.
Future<LogPage> collectLogPage(
  LogQuery query, {
  required LogCandidateFetch fetch,
  required List<LogTextCondition> textConditions,
}) async {
  StoredLogEntry? accept(LogCandidate candidate) {
    if (!textConditions.every((condition) => condition.mayMatchJson(candidate.entryJson))) return null;
    final entry = logEntryJsonText.decode(candidate.entryJson);
    if (!textConditions.every((condition) => condition.matches(entry))) return null;
    return StoredLogEntry(candidate.id, entry);
  }

  final limit = query.limit;
  if (limit == null) {
    return LogPage([for (final candidate in await fetch(query.startAfter, null)) ?accept(candidate)]);
  }

  final wanted = limit + 1;
  final accepted = <StoredLogEntry>[];
  var after = query.startAfter;
  var round = wanted;
  while (accepted.length < wanted) {
    final candidates = await fetch(after, round);
    for (final candidate in candidates) {
      if (accept(candidate) case final entry?) {
        accepted.add(entry);
        if (accepted.length == wanted) break;
      }
    }
    if (candidates.length < round) break;
    after = candidates.last.cursor;
    round = math.min(math.max(round * 2, wanted - accepted.length), _maxRound);
  }

  final hasNext = accepted.length > limit;
  final entries = hasNext ? accepted.sublist(0, limit) : accepted;
  return LogPage(entries, next: hasNext ? query.startingAfter(entries.last.cursor) : null);
}
