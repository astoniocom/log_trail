import 'dart:io';

import 'package:log_trail/log_trail.dart';
import 'package:log_trail/storage.dart';

/// Custom fields are declared once and stay typed: `userId(42)` does not compile,
/// and reading a field returns `String?` even for entries loaded from storage.
const userId = LogField('example.user_id', LogCodec.string);
const attempt = LogField('example.attempt', LogCodec.integer);

Future<void> main() async {
  // Create the logger first, before anything else is initialized.
  // The console sink is available immediately.
  final logger = RootLogger(sinks: [ConsoleSink()]);
  logger.info('App starting');

  // The storage becomes available later (opening a database takes time).
  // Entries logged before that moment are buffered and replayed into it
  // with their original time. InMemoryLogStore keeps the current session only;
  // a database store from another package would persist across launches.
  // RepeatCollapsingSink keeps an error thrown in a loop from flooding the
  // store. The root dispatches entries after the logging call returns, so
  // neither sink adds work to the call itself.
  await Future<void>.delayed(const Duration(milliseconds: 10));
  final store = InMemoryLogStore(limit: 1000);
  logger
    ..addSink(RepeatCollapsingSink(LogStoreSink(store)))
    ..finishStartup();

  // A module gets a child logger that tags all its entries. Context set on
  // the child later (for example a session id) reaches every entry of the
  // child and of the loggers derived from it.
  final authLog = logger.child(tags: {'auth'});

  // After sign-in, every entry, including the child's, carries the user id.
  logger.setContextAttribute(userId('42'));
  authLog.info('Signed in');

  try {
    throw const FormatException('Unexpected token');
  } on FormatException catch (error, stackTrace) {
    // A handled error: the message says what the app was doing.
    logger.warning('Failed to parse profile', error: error, stackTrace: stackTrace, attributes: [attempt(3)]);
  }

  // Wait until the entries reach the store, then read back this user's entries.
  // A database store can serve this filter from an indexed column.
  await logger.flush();
  final page = await store.queryEntries(
    LogQuery(filter: LogFilter(attributes: [userId('42')]), newestFirst: true, limit: 10),
  );
  stdout.writeln("\nUser 42's entries read back from the store:");
  for (final StoredLogEntry(:entry) in page.entries) {
    final String? user = entry.attributes.get(userId);
    final int? attemptNumber = entry.attributes.get(attempt);
    stdout.writeln(
      '  ${entry.level.name.padRight(7)} ${entry.message}'
      '${user == null ? '' : ', user $user'}'
      '${attemptNumber == null ? '' : ', attempt $attemptNumber'}'
      '${entry.error == null ? '' : ', error ${entry.error!.type}'}',
    );
  }

  // The logger closes its sinks and waits for every accepted entry to be
  // written. The store is owned by the app: close it afterwards, when nothing
  // (such as the in-app log viewer) reads it anymore.
  await logger.close();
  await store.close();
}
