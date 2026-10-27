import 'package:log_trail/src/entry/log_attributes.dart';
import 'package:log_trail/src/entry/log_level.dart';
import 'package:log_trail/src/logger/log_call.dart';
import 'package:log_trail/src/logger/log_context.dart';
import 'package:log_trail/src/logger/logger.dart';
import 'package:meta/meta.dart';

/// Everything a child logger ([ChildLogger]) needs from the logger above it: the default threshold, the chain's
/// tags, and acceptance of calls upward to the root. Implemented by the root's entry point and by [ChildLogger]
/// itself for its own children; a child does not know what exactly is above it and does not inspect the parent's
/// type.
///
/// The threshold is checked by the child logger where the call started: it has its own threshold or the parent's,
/// and that may be below the root's default threshold. So calls go to the root not through [Logger.submit] (there
/// the root would check its own threshold and drop the entry) but through [submitFromChild]: each logger in the
/// chain only adds its context ([LogCall.withContext]) and passes the call on. The only thing a child cannot
/// bypass is the root's floor ([floor]).
@internal
abstract interface class ChildLoggerHost {
  /// Threshold for a child logger without its own `minLevel`.
  bool isEnabled(LogLevel level);

  /// The root's floor (`RootLogger.floor`): no child writes below it, whatever its `minLevel`.
  LogLevel get floor;

  /// Tags of all loggers in the chain from the top down to this one inclusive; the empty set at the root's entry
  /// point. A child adds its own to them at creation.
  Set<String> get allTags;

  /// Accepts a call that passed the child logger's threshold; the chain's tags are already in it.
  void submitFromChild(LogCall call);
}

/// A module's logger on top of a [ChildLoggerHost]: adds tags and its own context ([contextAttributes]) to every
/// entry and passes it on toward the root. It has no sinks or buffer of its own.
///
/// Child loggers form a chain up to the root rather than collapsing into one: context set on an intermediate
/// logger later ([setContextAttribute]) must apply to its children too. Attributes are collected along the chain
/// from the bottom up ([submitFromChild]), so a child's value takes precedence over the parent's, and the call's
/// value over all. Tags are immutable, so the tags of all parents are collected once at creation ([allTags]).
///
/// The threshold is its own [minLevel] or, if not set, the threshold of the logger above it
/// ([ChildLoggerHost.isEnabled]); in both cases not below the root's floor ([ChildLoggerHost.floor]). The root
/// does not check an entry that passed the child's threshold against its default threshold: a module with a debug
/// threshold writes debug entries even if the root's default is info; the root checks the floor itself.
///
/// Created via [Logger.child]; modules work with [Logger], not with this type.
@internal
final class ChildLogger implements ContextualLogger, ChildLoggerHost {
  ChildLogger(
    ChildLoggerHost host, {
    Set<String> tags = const {},
    Iterable<LogAttribute<Object>> attributes = const [],
    this.minLevel,
  }) : _host = host,
       tags = Set.unmodifiable(tags),
       allTags = Set.unmodifiable({...host.allTags, ...tags}),
       _context = LogContext(attributes);

  /// The logger above this one: a parent child logger or the root's entry point. Provides the default threshold
  /// and the chain's tags, accepts calls.
  final ChildLoggerHost _host;

  /// Own tags, passed to [Logger.child].
  final Set<String> tags;

  /// Tags of this logger and all its parents: added to every entry.
  @override
  final Set<String> allTags;

  final LogContext _context;

  /// Own threshold; `null` means the threshold of the logger above. The root's floor ([floor]) applies on top of
  /// it.
  final LogLevel? minLevel;

  @override
  LogLevel get floor => _host.floor;

  @override
  Iterable<LogAttribute<Object>> get contextAttributes => _context.attributes;

  @override
  void setContextAttribute(LogAttribute<Object> attribute) => _context.set(attribute);

  @override
  void removeContextAttribute(LogField<Object> field) => _context.remove(field);

  @override
  bool isEnabled(LogLevel level) =>
      level >= _host.floor &&
      switch (minLevel) {
        null => _host.isEnabled(level),
        final minLevel => level >= minLevel,
      };

  /// Checks the threshold, adds the chain's tags ([allTags]) and passes the call upward as its own
  /// ([submitFromChild]).
  @override
  void submit(LogCall call) {
    if (!isEnabled(call.level)) return;
    submitFromChild(call.withTags(allTags));
  }

  /// Adds its own context and passes the call on toward the root. The context goes before the attributes from
  /// lower in the chain and from the call: for a repeated field, the value from below stays.
  @override
  void submitFromChild(LogCall call) => _host.submitFromChild(call.withContext(_context.attributes));

  @override
  ContextualLogger child({
    Set<String> tags = const {},
    Iterable<LogAttribute<Object>> attributes = const [],
    LogLevel? minLevel,
  }) => ChildLogger(this, tags: tags, attributes: attributes, minLevel: minLevel);
}
