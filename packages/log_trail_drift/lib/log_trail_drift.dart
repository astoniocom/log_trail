/// Drift log store for `log_trail`: one table in your own drift database.
///
/// Declare a table with `LogEntryColumns` in your project, add it to
/// `@DriftDatabase(tables: [...])` and open a `DriftLogStore` over the
/// generated table object. This package generates no code and needs no
/// build configuration; your database's generator produces the table as
/// usual (drift only understands table classes declared in the package it
/// runs in, which is why the table is yours and the mixin is the schema).
/// Subclass `DriftLogStore` to fill columns of your own or to scope the store
/// to part of the table.
///
/// Re-exports `package:log_trail/storage.dart`: the store contract, the store
/// sink, queries and `LogStoreException`, the failure type every store
/// throws. Platform-neutral: works with any drift executor, including
/// `WasmDatabase` on the web.
library;

export 'package:log_trail/storage.dart';
export 'package:log_trail_drift/src/drift_log_store.dart';
export 'package:log_trail_drift/src/log_entry_columns.dart';
