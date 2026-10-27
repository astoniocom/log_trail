/// SQLite log store (`SqliteLogStore`) for `log_trail`: entries survive
/// application restarts, pages are read by index, tags are counted on write.
/// Re-exports `package:log_trail/storage.dart`: the store is connected
/// through `LogStoreSink` and read through `LogQuery`; failures surface as
/// `LogStoreException` from there, the same type every store throws.
///
/// Native platforms only: `package:sqlite3` on web requires a separate
/// WebAssembly build of SQLite and a virtual file system; for a drift
/// database, including `WasmDatabase` on the web, see `log_trail_drift`.
library;

export 'package:log_trail/storage.dart';
export 'package:log_trail_sqlite/src/sqlite_durability.dart';
export 'package:log_trail_sqlite/src/sqlite_log_store.dart';
