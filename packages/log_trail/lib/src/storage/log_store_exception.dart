import 'package:meta/meta.dart';

/// A failure of a store's backend (SQLite, a file, a remote service) in a
/// store operation: what the application needs to handle or report it,
/// without the query parameters, which for a write are the whole entry.
///
/// Backend exceptions tend to print their parameters in `toString()`
/// (`SqliteException` from `package:sqlite3` does), and a store failure goes
/// to diagnostics (`LogStoreSink: the store failed to write …`) and from there
/// to the console or the application's handler (Sentry), where log contents
/// do not belong. So a store rethrows backend failures in this form, with the
/// original stack trace ([Error.throwWithStackTrace]), and application code
/// handles every store the same way. Exceptions from opening a database are
/// not wrapped: they have no parameters, and there is no store yet.
@immutable
final class LogStoreException implements Exception {
  const LogStoreException(this.message, {this.code, this.operation, this.statement});

  /// Backend result code, if the backend has one: for SQLite the extended
  /// result code (`SQLITE_FULL`, `SQLITE_BUSY`, …).
  final int? code;

  /// Backend message, with its explanation if it gives one separately.
  final String message;

  /// The backend operation during which the failure occurred, if known.
  final String? operation;

  /// The statement that failed, if known, without parameters.
  final String? statement;

  @override
  String toString() => [
    'LogStoreException',
    if (code != null) '($code)',
    ': ',
    if (operation != null) 'while $operation, ',
    message,
    if (statement != null) '\n  Statement: $statement',
  ].join();
}
