/// The `LogStore` contract check from `package:log_trail/testing.dart`: random
/// logs and queries must yield the same pages, tags and change events in the
/// drift store as in the in-memory reference (`queryInMemory` and
/// `LogCondition.matches` define the query semantics).
///
/// Three setups: the ready-made `LogEntries` table; and two scoped stores
/// over one shared `TenantLogs` table, driven in lockstep through one
/// scenario, so each store must keep matching its own reference while the
/// other writes, evicts and removes in the same table.
library;

import 'package:drift/drift.dart';
import 'package:log_trail/log_trail.dart';
import 'package:log_trail/testing.dart';
import 'package:log_trail_drift/log_trail_drift.dart';
import 'package:test/test.dart';

import 'support/test_database.dart';

/// A store scoped to one tenant of the shared [TenantLogs] table.
final class _TenantLogStore extends DriftLogStore<$TenantLogsTable, TenantLog> {
  _TenantLogStore(super.database, super.table, this.tenant, {super.limit});

  final String tenant;

  @override
  Map<GeneratedColumn<Object>, Expression<Object>> additionalColumns(LogEntry entry) => {
    table.tenant: Variable<String>(tenant),
  };

  @override
  Expression<bool> get scope => table.tenant.equals(tenant);
}

void main() {
  for (final seed in [1, 2, 3, 4, 5]) {
    test('LogEntries table, seed $seed: same pages, tags and changes as the in-memory store', () async {
      final db = TestDatabase.memory();
      final reference = InMemoryLogStore(limit: 40);
      final drift = DriftLogStore(db, db.logEntries, limit: 40);
      addTearDown(() async {
        await reference.close();
        await drift.close();
        await db.close();
      });

      final mismatches = await compareLogStores(drift, reference: reference, seed: seed);

      expect(mismatches, isEmpty, reason: mismatches.join('\n'));
    });

    test('two scoped stores over one TenantLogs table, seed $seed: each matches its own reference', () async {
      final db = TestDatabase.memory();
      final scenario = LogStoreScenario(seed);
      final checks = [
        for (final tenant in ['a', 'b'])
          LogStoreContractCheck(
            store: _TenantLogStore(db, db.tenantLogs, tenant, limit: 40),
            reference: InMemoryLogStore(limit: 40),
            scenario: scenario,
            // Ids are shared across tenants in one table; the private reference issues its own.
            compareIds: false,
          ),
      ];
      addTearDown(() async {
        for (final check in checks) {
          await check.store.close();
          await check.reference.close();
        }
        await db.close();
      });

      for (var round = 0; round < 12; round++) {
        for (final check in checks) {
          await check.round();
        }
      }
      for (final check in checks) {
        await check.finish();
        expect(check.mismatches, isEmpty, reason: check.mismatches.join('\n'));
      }
    });
  }

  test('a single store over an exclusive table also matches the reference ids', () async {
    final db = TestDatabase.memory();
    final reference = InMemoryLogStore(limit: 10);
    final drift = DriftLogStore(db, db.logEntries, limit: 10);
    addTearDown(() async {
      await reference.close();
      await drift.close();
      await db.close();
    });

    final mismatches = await compareLogStores(drift, reference: reference, seed: 7, rounds: 6);

    expect(mismatches, isEmpty, reason: mismatches.join('\n'));
  });
}
