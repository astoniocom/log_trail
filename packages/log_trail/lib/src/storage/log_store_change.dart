import 'package:log_trail/src/storage/stored_log_entry.dart';

/// A change to the contents of a `LogStore`: the viewer updates from it instead of rereading the whole
/// log for every write.
sealed class LogStoreChange {
  const LogStoreChange();
}

/// Entries were written, in write order, with assigned ids. One event per batch
/// (`LogStore.writeEntries`): the subscriber updates once, not per entry.
final class LogEntriesAdded extends LogStoreChange {
  LogEntriesAdded(List<StoredLogEntry> entries) : entries = List.unmodifiable(entries);

  final List<StoredLogEntry> entries;
}

/// Entries were removed. The subtype says exactly which, so the subscriber drops them locally without
/// rereading the log: otherwise a store with a limit, evicting old entries on every write, would force
/// constant rereads.
sealed class LogEntriesRemoved extends LogStoreChange {
  const LogEntriesRemoved();
}

/// Entries with these ids ([StoredLogEntry.id]) were removed, and only they, for example evicted by the
/// store limit. Ids are passed, not entries: the store does not need to read what it removes (in SQL,
/// `DELETE … RETURNING id`), and the subscriber does not need to compare whole entries.
final class LogEntriesRemovedById extends LogEntriesRemoved {
  LogEntriesRemovedById(Set<int> ids) : ids = Set.unmodifiable(ids);

  final Set<int> ids;
}

/// All entries strictly before [time] were removed, and only they (`LogStore.removeBefore`).
final class LogEntriesRemovedBefore extends LogEntriesRemoved {
  const LogEntriesRemovedBefore(this.time);

  final DateTime time;
}

/// All entries were removed (`LogStore.clear`).
final class AllLogEntriesRemoved extends LogEntriesRemoved {
  const AllLogEntriesRemoved();
}

/// The contents changed in a way the store cannot cheaply describe: for example, it removed entries by
/// file size on its own and does not know which. The subscriber needs to reread the entries it needs.
final class LogStoreInvalidated extends LogStoreChange {
  const LogStoreInvalidated();
}
