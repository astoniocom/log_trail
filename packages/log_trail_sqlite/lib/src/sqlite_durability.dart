/// What a committed write of an SQLite-backed log store (`SqliteLogStore`,
/// `DriftLogStore`) survives: the value of `PRAGMA synchronous` in WAL mode.
///
/// The `LogStore.writeEntries` contract requires only [processCrash]: the
/// fatal entry the sink hands to the store before process termination must
/// survive that termination. Any mode provides this: the pages are already in
/// the OS cache. The modes differ in what happens on an OS failure or power
/// loss, and in cost: an `fsync` per transaction.
enum SqliteDurability {
  /// `synchronous = NORMAL`: the WAL is flushed to disk at a checkpoint, not
  /// on every commit. A write survives a process crash or kill; on a kernel
  /// failure or power loss the last transactions may roll back, the database
  /// stays consistent. Commit without `fsync`, so a transaction blocks the
  /// isolate for a fraction of a millisecond. The default: for an application
  /// log, losing the last entries when the device loses power is a rare case
  /// not worth an `fsync` per batch.
  processCrash('NORMAL'),

  /// `synchronous = FULL`: `fsync` on every commit. A write survives both an
  /// OS failure and power loss, as far as the device's `fsync` is honest. A
  /// transaction blocks the isolate for the duration of `fsync`: a few
  /// milliseconds on flash storage per batch, noticeable in the main isolate
  /// during a burst. An application that cannot afford that and still wants
  /// `fsync` per commit keeps SQLite off the main isolate with
  /// `DriftLogStore` instead.
  powerLoss('FULL');

  const SqliteDurability(this.pragmaValue);

  /// The value for `PRAGMA synchronous`.
  final String pragmaValue;
}
