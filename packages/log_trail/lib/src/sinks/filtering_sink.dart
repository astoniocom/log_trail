import 'package:log_trail/src/entry/log_entry.dart';
import 'package:log_trail/src/entry/log_level.dart';
import 'package:log_trail/src/sinks/delegating_sink.dart';
import 'package:log_trail/src/sinks/log_sink.dart';

/// A wrapper sink that passes to [inner] only entries for which [isAccepted] holds.
///
/// Selection for a single sink: for example, the console shows everything
/// while the store gets entries from info up. The shared limit for all sinks
/// is `RootLogger.floor`: entries below it are not even collected.
///
/// The sink owns [inner]: [close] closes it too.
///
/// ```dart
/// logger.addSink(FilteringSink.minLevel(LogStoreSink(store), LogLevel.info));
/// ```
final class FilteringSink extends DelegatingSink {
  FilteringSink(super.inner, this.isAccepted);

  /// Entries at [minLevel] and above.
  FilteringSink.minLevel(LogSink inner, LogLevel minLevel) : this(inner, (entry) => entry.level >= minLevel);

  @override
  String get name => 'FilteringSink';

  /// Whether to pass the entry to [inner].
  final bool Function(LogEntry entry) isAccepted;

  @override
  void onAdd(LogEntry entry) {
    if (isAccepted(entry)) inner.add(entry);
  }
}
