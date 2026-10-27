import 'package:log_trail/src/diagnostics/log_diagnostic.dart';
import 'package:log_trail/src/entry/call_site.dart';
import 'package:log_trail/src/entry/log_attributes.dart';
import 'package:log_trail/src/entry/log_entry.dart';
import 'package:log_trail/src/entry/log_level.dart';
import 'package:log_trail/src/logger/child_logger.dart';
import 'package:log_trail/src/logger/log_call.dart';
import 'package:log_trail/src/logger/log_context.dart';
import 'package:log_trail/src/logger/log_dispatch_policy.dart';
import 'package:log_trail/src/logger/log_entry_factory.dart';
import 'package:log_trail/src/logger/log_pipeline.dart';
import 'package:log_trail/src/logger/log_processor.dart';
import 'package:log_trail/src/logger/logger.dart';
import 'package:log_trail/src/sinks/log_sink.dart';

/// Root of application logging: owns the sinks ([LogSink]) and dispatches entries to them; modules get child
/// loggers from it ([child]). Created as the first line of `main()`: sinks are added later ([addSink]), as the
/// database, Sentry and other dependencies initialize.
///
/// [submit] (and the convenience forms over it: [log], [recordError], the per-level methods) builds a [LogEntry]
/// from a [LogCall] inside the call: time, call site, stack and context ([setContextAttribute]) belong to that
/// moment. Dispatch of the built entry (processors, startup buffer, sinks) is deferred per [dispatch]
/// ([LogDispatchPolicy]), so the work whose volume the application controls lengthens neither the call nor the
/// frame; [flush] and [close] dispatch the pending entries first. Ready-made entries (from another isolate, from
/// another root) arrive through [asSink] and pass the same [floor], [processors], buffer and sinks.
///
/// Entries logged before a sink is added accumulate in a bounded buffer ([startupBufferLimit]) and are replayed
/// into a sink at [addSink] if it asks for that; [finishStartup] ends the phase, [startupBufferTimeout] ends it
/// if the application forgets to. The buffer keeps live [LogError.original] and [LogError.report], so call
/// [finishStartup] as soon as the sinks are attached rather than relying on the timeout.
///
/// The logger owns an added sink: [close] closes every sink attached at that moment, [removeSink] returns a sink
/// to the caller unclosed. So one sink should not be attached to several loggers. Ownership does not extend to
/// resources the sink was handed from outside, such as the store behind a `LogStoreSink`.
///
/// After [close], entries are dropped however they arrive, with one message in [diagnostics]: logging must not
/// crash the application on shutdown. [addSink] after [close] throws [StateError]: an initialization-order bug.
///
/// Failures of logging itself go to [diagnostics], never to the sinks or the caller; every sink gets the same
/// channel on attach ([LogSink.attach]). An entry a processor or a sink logs into this logger while an entry is
/// being dispatched is dispatched after it; an entry logged in response to such an entry is dropped with a
/// diagnostic: that is a cycle.
final class RootLogger implements ContextualLogger {
  RootLogger({
    List<LogSink> sinks = const [],
    this.defaultMinLevel = LogLevel.debug,
    this.floor = LogLevel.trace,
    List<LogProcessor> processors = const [],
    int startupBufferLimit = 200,
    Duration? startupBufferTimeout = const Duration(minutes: 1),
    WrapperFramePredicate? isWrapperFrame,
    this.dispatch = const LogDispatchPolicy(),
    this.diagnostics = DiagnosticReporter.console,
  }) : _entryFactory = LogEntryFactory(context: LogContext(), isWrapperFrame: isWrapperFrame),
       _pipeline = LogPipeline(
         owner: 'RootLogger',
         diagnostics: diagnostics,
         dispatch: dispatch,
         sinks: sinks,
         processors: processors,
         startupBufferLimit: startupBufferLimit,
         startupBufferTimeout: startupBufferTimeout,
       );

  /// Builds entries from calls: time, call site, stack and the root's context.
  final LogEntryFactory _entryFactory;

  /// Everything after building: the dispatch queue, processors, startup buffer and sinks, with their lifecycle.
  final LogPipeline _pipeline;

  /// How built entries are dispatched: which levels immediately, how many may wait in the queue before a batch
  /// is dispatched inside the call ([LogDispatchPolicy]).
  final LogDispatchPolicy dispatch;

  /// Where the library's messages about its own operation go: sink failures, store queue overflow, writes after
  /// [close]. Passed to every sink when attached ([LogSink.attach]) and to [asSink] sinks. Defaults to printing
  /// to the console; Flutter has `debugPrintDiagnostic`.
  ///
  /// ```dart
  /// RootLogger(diagnostics: DiagnosticReporter((d) => Sentry.captureMessage('$d')));
  /// ```
  final DiagnosticReporter diagnostics;

  /// Default threshold: for the root's own calls and for child loggers without their own `minLevel` ([child]).
  /// Not a floor: a child with its own `minLevel` follows it, even below this threshold; that is how debug is
  /// enabled for one module. The limit for everything is [floor].
  ///
  /// Entries below the threshold are dropped before the entry is built, without a stack capture. Defaults to
  /// [LogLevel.debug]: [LogLevel.trace] entries are dropped until enabled here for the whole application or for
  /// one module via `child(minLevel: LogLevel.trace)`.
  ///
  /// May be changed at runtime, for example to enable debug from a remote setting.
  LogLevel defaultMinLevel;

  /// Floor: below it the root dispatches nothing, wherever the entry came from (the root itself, a child logger
  /// with any `minLevel`, a ready-made entry from [asSink]). Unlike [defaultMinLevel], a child logger cannot
  /// bypass it: it is an application guarantee, not a default. Checked before the entry is built, without a stack
  /// capture.
  ///
  /// Defaults to [LogLevel.trace], that is, no limit. In a release build one usually sets [floor] rather than
  /// [defaultMinLevel]: otherwise a module with its own `child(minLevel: LogLevel.trace)` would write trace there
  /// too. Filtering for a single sink is `FilteringSink`.
  ///
  /// May be changed at runtime, for example lowered from a remote setting to diagnose one user.
  ///
  /// ```dart
  /// RootLogger(floor: BuildMode.current.isRelease ? LogLevel.info : LogLevel.trace);
  /// ```
  LogLevel floor;

  bool _isDropAfterCloseReported = false;

  List<LogSink> get sinks => _pipeline.sinks;

  /// Entry processing, in order ([LogProcessor]): redaction (`LogRedactor`), enrichment, filtering. Applied to
  /// every entry, including ready-made ones from [asSink], before the startup buffer and before all sinks, so
  /// that, for example, an unredacted entry reaches neither the console, nor the store, nor reports. `null` from
  /// a processor drops the entry; a processor failure drops it too, with a message in [diagnostics]: passing the
  /// entry on unprocessed could be a leak.
  ///
  /// Those passed to the constructor, then those added via [addProcessor], in that order. The list is
  /// unmodifiable.
  List<LogProcessor> get processors => _pipeline.processors;

  /// Appends [processor] to [processors]: like sinks ([addSink]), processors are added as their dependencies
  /// become ready, for example redaction by patterns from remote configuration, or enrichment with the build
  /// version that `PackageInfo` returns asynchronously. Adding the same one again does nothing: sampling twice
  /// would filter twice as hard.
  ///
  /// Startup entries already in the buffer pass through [processor] now: only entries that passed all of the
  /// root's processors are replayed into a sink added later, otherwise redaction added after the first entries
  /// would not protect the store from them. Entries already dispatched to sinks are not changed.
  void addProcessor(LogProcessor processor) => _pipeline.addProcessor(processor);

  /// Removes [processor] from [processors]. Entries it already processed (including those in the startup buffer)
  /// are not changed.
  void removeProcessor(LogProcessor processor) => _pipeline.removeProcessor(processor);

  /// Frames of the application's wrappers over the logger that do not count as the call site. Frames of
  /// `log_trail*` itself are always skipped.
  ///
  /// Called not at log time but on a sink's first access to [LogEntry.location], possibly on another event-loop
  /// turn, so it must depend only on its arguments.
  ///
  /// ```dart
  /// RootLogger(isWrapperFrame: (uri, member) => member.startsWith('AppLog.'));
  /// ```
  WrapperFramePredicate? get isWrapperFrame => _entryFactory.isWrapperFrame;

  /// Maximum number of events in the startup buffer. On overflow the oldest are dropped: with an error looping at
  /// startup, the latest events matter more. The limit is mandatory: otherwise such an error would eat memory.
  int get startupBufferLimit => _pipeline.startupBufferLimit;

  /// How long after the first startup entry buffering stops on its own if [finishStartup] is not called; `null`
  /// means only via [finishStartup]. Otherwise a sink added half an hour later would receive the events of the
  /// first second.
  ///
  /// Fires on a timer even if the application writes nothing more: the accumulated entries are released. Until
  /// the timer fires it keeps the isolate alive: a script that logged something before [finishStartup] or [close]
  /// exits no sooner than this duration. Creating the logger does not start the timer.
  Duration? get startupBufferTimeout => _pipeline.startupBufferTimeout;

  /// Attributes added to every entry built by this logger ([submit], including through child loggers).
  @override
  Iterable<LogAttribute<Object>> get contextAttributes => _entryFactory.context.attributes;

  /// Adds [attribute] to every subsequent entry built by this logger ([submit], including Flutter errors), for
  /// example the user id after sign-in. Calling again for the same field replaces the value.
  ///
  /// A value for the same field from a child logger or passed to the log call takes precedence over the root's
  /// context. Entries already built by now (including those in the startup buffer) are not changed; ready-made
  /// entries from [asSink] do not receive the context: another logger built them with its own context.
  @override
  void setContextAttribute(LogAttribute<Object> attribute) => _entryFactory.context.set(attribute);

  /// Removes the field from the context, for example the user id after sign-out.
  @override
  void removeContextAttribute(LogField<Object> field) => _entryFactory.context.remove(field);

  /// Attaches the sink and hands it over to the logger's ownership: the logger's [close] closes it too, and it
  /// reports its failures to [diagnostics] ([LogSink.attach]). Adding the same sink again does nothing: otherwise
  /// its events would be duplicated.
  ///
  /// [replayStartupBuffer]: replay the startup-phase events into it. Makes sense for persistent stores (database,
  /// Sentry) and not for analytics, where time-shifted events distort reports. Entries still waiting for dispatch
  /// are not in the buffer yet: the sink receives them after the replay, when they are dispatched to everyone.
  ///
  /// Throws [StateError] after [close]: a sink added to a closed logger would never receive entries or
  /// [LogSink.close], and its resources would stay open. That is an initialization-order bug, better seen right
  /// away.
  void addSink(LogSink sink, {bool replayStartupBuffer = true}) =>
      _pipeline.addSink(sink, replayStartupBuffer: replayStartupBuffer);

  /// Detaches the sink and returns it to the caller without closing it or waiting for delivery: entries the sink
  /// has already accepted, it delivers itself. When the sink is no longer needed, call its [LogSink.close],
  /// otherwise its resources (for example the store) stay open.
  void removeSink(LogSink sink) => _pipeline.removeSink(sink);

  /// Ends the startup phase: the buffer is cleared, new events are no longer accumulated, the
  /// [startupBufferTimeout] timer is cancelled. Entries still waiting for dispatch no longer enter the buffer:
  /// they go to the sinks attached at dispatch time, like everything after the startup phase.
  void finishStartup() => _pipeline.finishStartup();

  /// A sink that passes ready-made entries to this root: for entries from another isolate
  /// (`IsolateLogReceiver(logger.asSink())`) or to attach this root as a sink of another one
  /// (`other.addSink(logger.asSink())`). The entry passes the root's threshold, processors, startup buffer and
  /// sinks like its own; the context ([setContextAttribute]) is not added: another logger built it with its own
  /// context. The processors, however, are this root's policy for everything it dispatches: redaction and
  /// filtering apply to a ready-made entry too, and enrichment sees its attributes and decides by order whether
  /// to overwrite the source's values ([LogProcessor]).
  ///
  /// Each call returns a new sink with its own lifecycle: closing one (for example by another root at its
  /// [close]) does not affect the others and does not close this root, which its creator owns. The sink's [flush]
  /// waits for the root's sinks ([flush]). The sink's diagnostics channel is this root's [diagnostics] until
  /// another root replaces it with its own on attach.
  LogSink asSink() => _RootLoggerSink(this)..attach(diagnostics);

  /// Whether [close] has been called.
  bool get isClosed => _pipeline.isClosed;

  /// Dispatches entries still waiting for dispatch and waits for delivery of accepted entries to all sinks
  /// without closing them. One sink's failure does not prevent waiting for the others; the first error is
  /// returned to the caller.
  Future<void> flush() => _pipeline.flush();

  /// Dispatches entries still waiting for dispatch and closes every sink attached at that moment; sinks detached
  /// via [removeSink] are left alone. One sink's failure does not prevent closing the others; the first error is
  /// returned to the caller. Calling again closes nothing anew and returns the result of the first call.
  Future<void> close() => _pipeline.close();

  /// The root's threshold for its own calls: [defaultMinLevel] and [floor].
  @override
  bool isEnabled(LogLevel level) => level >= defaultMinLevel && level >= floor;

  /// Accepts a ready-made entry ([asSink]): an entry below [floor] or after [close] is dropped, the rest go to
  /// the pipeline. The entry has already passed the source's threshold; [defaultMinLevel] does not apply to it: it
  /// is for this root's loggers.
  void _accept(LogEntry entry) {
    if (_dropIfClosed() || entry.level < floor) return;
    _pipeline.accept(entry);
  }

  /// Accepts a call whose threshold the caller has checked ([submit] against [isEnabled], a child logger against
  /// its own `minLevel`): drops it after [close] or below [floor], otherwise builds the entry and hands it to the
  /// pipeline. The floor is checked here for every call, not only in the callers' thresholds: it is the root's
  /// guarantee for everything it dispatches and must not depend on how a child checked its threshold. Building
  /// always happens here, in the call: time, context and stack belong to it, not to the moment of dispatch.
  void _submitCall(LogCall call) {
    if (_dropIfClosed() || call.level < floor) return;
    _pipeline.accept(_entryFactory.create(call));
  }

  /// After [close] the entry is dropped with a message in [diagnostics] (once) instead of throwing: logging must
  /// not crash the application on shutdown.
  bool _dropIfClosed() {
    if (!isClosed) return false;
    if (!_isDropAfterCloseReported) {
      _isDropAfterCloseReported = true;
      diagnostics.report(const LogDiagnostic('RootLogger: closed, further entries are dropped'));
    }
    return true;
  }

  /// Checks the root's threshold ([isEnabled]) before anything is built, to avoid a wasted stack capture, then
  /// builds and dispatches the entry ([_submitCall]).
  @override
  void submit(LogCall call) {
    if (!isEnabled(call.level)) return;
    _submitCall(call);
  }

  /// Child logger calls pass through this logger: same sinks, startup buffer and context ([setContextAttribute]).
  /// The child checks the threshold: its own [minLevel] or [defaultMinLevel]; [floor] always applies to it.
  @override
  ContextualLogger child({
    Set<String> tags = const {},
    Iterable<LogAttribute<Object>> attributes = const [],
    LogLevel? minLevel,
  }) => ChildLogger(_childHost, tags: tags, attributes: attributes, minLevel: minLevel);

  late final ChildLoggerHost _childHost = _RootChildHost(this);
}

/// The root's entry point for child loggers: the root's default threshold, the floor, empty tags (the chain
/// starts here) and acceptance of calls whose threshold the child has already checked
/// ([RootLogger._submitCall]).
final class _RootChildHost implements ChildLoggerHost {
  _RootChildHost(this.logger);

  final RootLogger logger;

  @override
  bool isEnabled(LogLevel level) => logger.isEnabled(level);

  @override
  LogLevel get floor => logger.floor;

  @override
  Set<String> get allTags => const {};

  @override
  void submitFromChild(LogCall call) => logger._submitCall(call);
}

/// The root as a sink of ready-made entries ([RootLogger.asSink]).
///
/// Does not own the root: closing the sink only stops acceptance; the root is closed by its creator. Acceptance
/// after the sink is closed throws, as with any [LogSink]; acceptance after the root is closed is dropped by the
/// root.
final class _RootLoggerSink extends LogSink {
  _RootLoggerSink(this.logger);

  final RootLogger logger;

  @override
  String get name => 'RootLogger.asSink';

  @override
  void onAdd(LogEntry entry) => logger._accept(entry);

  @override
  Future<void> onFlush() => logger.flush();
}
