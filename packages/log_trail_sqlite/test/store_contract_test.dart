/// The `LogStore` contract check from `package:log_trail/testing.dart`: random
/// logs and queries must yield the same pages, tags and change events in
/// SQLite as in the in-memory reference (`queryInMemory` and
/// `LogCondition.matches` define the query semantics).
library;

import 'package:log_trail/testing.dart';
import 'package:log_trail_sqlite/log_trail_sqlite.dart';
import 'package:test/test.dart';

void main() {
  for (final seed in [1, 2, 3, 4, 5]) {
    test('seed $seed: SQLite yields the same pages, tags and changes as the in-memory store', () async {
      final reference = InMemoryLogStore(limit: 40);
      final sqlite = SqliteLogStore.inMemory(limit: 40);
      addTearDown(() async {
        await reference.close();
        await sqlite.close();
      });

      final mismatches = await compareLogStores(sqlite, reference: reference, seed: seed);

      expect(mismatches, isEmpty, reason: mismatches.join('\n'));
    });
  }
}
