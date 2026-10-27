import 'dart:collection';

import 'package:log_trail/src/entry/log_entry.dart';
import 'package:log_trail/src/storage/in_memory/in_memory_query.dart';
import 'package:log_trail/src/storage/in_memory/store_order.dart';
import 'package:log_trail/src/storage/log_query.dart';
import 'package:log_trail/src/storage/log_store_base.dart';
import 'package:log_trail/src/storage/log_store_change.dart';
import 'package:log_trail/src/storage/stored_log_entry.dart';

/// In-memory store: the current session's log without a database.
///
/// For tests, prototypes and apps that only need a viewer over the current session. Entries do not
/// survive a process restart.
///
/// Keeps entries as [LogStoreBase] passes them ([LogEntry.withoutLiveObjects]): without live
/// [LogError.original] and [LogError.report], with the call site already resolved. Otherwise a store of a
/// thousand entries would hold a thousand original errors and platform reports with everything they
/// reference. Entries are `==` to the written ones.
///
/// Entries are kept in store order (by time, then by id), so a query page does not need a scan of the
/// whole log ([queryInMemory]), and tags are counted on write and removal ([queryTags] does not iterate
/// entries).
///
/// The log is capped at [limit] (default [defaultLimit]): when exceeded, the oldest entries are removed
/// with [LogEntriesRemovedById] in [changes]. Without a limit a long session would grow both memory and
/// the cost of every query without bound.
final class InMemoryLogStore extends LogStoreBase {
  InMemoryLogStore({this.limit = defaultLimit}) : assert(limit == null || limit > 0, 'limit must be positive');

  /// Default limit: enough for a session viewed in the viewer, and small enough that a page with a rare
  /// filter ([queryInMemory] scans entries linearly) or memory does not become noticeable.
  static const int defaultLimit = 10000;

  /// Maximum number of kept entries; `null` means no limit (`InMemoryLogStore(limit: null)`), for tests
  /// where every entry matters.
  final int? limit;

  /// Entries in store order.
  final List<StoredLogEntry> _entries = [];

  /// Id of the next stored entry: ids are never reused, even after removal.
  int _nextId = 1;

  /// How many kept entries carry each tag.
  final Map<String, int> _tagCounts = {};

  @override
  String get name => 'InMemoryLogStore';

  /// Stored entries in store order: by time, entries with equal time in write order.
  List<StoredLogEntry> get entries => UnmodifiableListView(_entries);

  @override
  Future<List<StoredLogEntry>> onWriteEntries(List<LogEntry> entries) async {
    final stored = List<StoredLogEntry>.unmodifiable([for (final entry in entries) StoredLogEntry(_nextId++, entry)]);
    stored.forEach(_insert);
    final limit = this.limit;
    if (limit != null && _entries.length > limit) {
      // The base sends this after the LogEntriesAdded of this write.
      reportChange(LogEntriesRemovedById(_removeOldest(_entries.length - limit)));
    }
    return stored;
  }

  /// Entries usually arrive in time order and go to the end; replayed early-phase events go to their
  /// place, after entries with the same time. The new entry's id is greater than all existing ones, so
  /// store order (by time, then by id) is preserved.
  void _insert(StoredLogEntry stored) {
    final time = stored.entry.time;
    if (_entries.isEmpty || !time.isBefore(_entries.last.entry.time)) {
      _entries.add(stored);
    } else {
      _entries.insert(indexAfter(_entries, time), stored);
    }
    for (final tag in stored.entry.tags) {
      _tagCounts.update(tag, (count) => count + 1, ifAbsent: () => 1);
    }
  }

  /// Removes the [count] oldest entries and returns their ids.
  Set<int> _removeOldest(int count) {
    final removed = _entries.sublist(0, count);
    _entries.removeRange(0, count);
    for (final tag in removed.expand((stored) => stored.entry.tags)) {
      final remaining = _tagCounts[tag]! - 1;
      if (remaining == 0) {
        _tagCounts.remove(tag);
      } else {
        _tagCounts[tag] = remaining;
      }
    }
    return {for (final stored in removed) stored.id};
  }

  @override
  Future<LogPage> onQueryEntries(LogQuery query) async => queryInMemory(_entries, query);

  @override
  Future<Set<String>> onQueryTags() async => {..._tagCounts.keys};

  @override
  Future<void> onClear() async {
    _entries.clear();
    _tagCounts.clear();
  }

  @override
  Future<void> onRemoveBefore(DateTime time) async => _removeOldest(indexNotBefore(_entries, time));

  @override
  Future<Set<int>?> onRetainNewest(int count) async =>
      _entries.length <= count ? const {} : _removeOldest(_entries.length - count);
}
