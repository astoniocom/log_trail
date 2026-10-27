import 'dart:async';

import 'package:log_trail/src/diagnostics/log_diagnostic.dart';
import 'package:log_trail/src/entry/log_entry.dart';
import 'package:log_trail/src/sinks/delegating_sink.dart';

/// A wrapper sink that collapses repeats of the same error before passing
/// them to [inner]: an error in a loop must not crowd out the log.
///
/// The first occurrence starts a series and is passed on as is; repeats within
/// [window] of it are counted, and [inner] gets one summary "Error repeated N
/// more time(s)" with the time of the last repeat when the series ends: by
/// timer [window] after the first occurrence, on a repeat outside [window]
/// (which starts a new series), on eviction ([maxTrackedSeries]), on [flush]
/// and [close]. Series of different errors are independent. Entries that do
/// not collapse ([isCollapsible]) pass through and do not interrupt a series.
/// Repeats are measured by [LogEntry.time], so deferred dispatch does not
/// affect collapsing.
///
/// [seriesKey] decides what counts as the same error; by default
/// ([defaultSeriesKey]) the same type from the same [LogEntry.location],
/// regardless of the text, so a changing number in the message does not break
/// a series. The downside: errors of one type thrown from one place with
/// different codes (`PlatformException`, `DioException`) also count as one;
/// the summary therefore lists the differing texts of suppressed repeats (up
/// to [maxOtherTextsInSummary]), and a custom [seriesKey] can add the code:
///
/// ```dart
/// RepeatCollapsingSink(
///   inner,
///   seriesKey: (entry) => switch (entry.error?.original) {
///     final PlatformException e => '${RepeatCollapsingSink.defaultSeriesKey(entry)} ${e.code}',
///     _ => RepeatCollapsingSink.defaultSeriesKey(entry),
///   },
/// );
/// ```
///
/// Without a location (a `--split-debug-info` build) the default key uses the
/// stack text, identical for repeats from one place within a process; without
/// a stack, type and text. Entries without an error are keyed by level the
/// same way. The key reads [LogEntry.location], that is parses the stack, in
/// [add]; the root dispatches outside the logger call, so `log` does not pay
/// for it. The series keeps its entries without live objects
/// ([LogEntry.withoutLiveObjects]); the first occurrence goes to [inner]
/// with them. A running series' timer keeps the isolate alive until [window]
/// or [close].
///
/// ```dart
/// logger.addSink(RepeatCollapsingSink(LogStoreSink(store)));
/// ```
final class RepeatCollapsingSink extends DelegatingSink {
  RepeatCollapsingSink(
    super.inner, {
    this.window = const Duration(minutes: 1),
    this.maxTrackedSeries = 32,
    this.isCollapsible = _hasError,
    this.seriesKey = defaultSeriesKey,
  }) : assert(window > Duration.zero, 'window must be positive'),
       assert(maxTrackedSeries > 0, 'maxTrackedSeries must be positive');

  /// How many texts of suppressed repeats that differ from the first
  /// occurrence the summary lists; with more distinct texts it ends with an
  /// ellipsis. The limit keeps the summary and the series memory small.
  static const int maxOtherTextsInSummary = 5;

  @override
  String get name => 'RepeatCollapsingSink';

  /// How long after the first occurrence of an error its repeats count as one
  /// series. A repeat later than this starts a new series: otherwise an error
  /// that genuinely occurs once an hour would appear in the log once.
  ///
  /// Repeats are measured by [LogEntry.time], not by the sink's clock:
  /// startup-phase events replayed later collapse by their own time. The timer
  /// that ends the series runs on the clock.
  final Duration window;

  /// How many series are tracked at once. A new series beyond this ends, with
  /// a summary, the one that repeated longest ago: memory is bounded, and
  /// there are usually few distinct errors in one loop.
  final int maxTrackedSeries;

  /// Whether to collapse entries of this kind. By default only entries with
  /// an error: identical informational entries (for example analytics events)
  /// often repeat legitimately, and a summary would lose their time and
  /// parameters.
  final bool Function(LogEntry entry) isCollapsible;

  /// Series key: entries with one key within [window] count as repeats of one
  /// error. Defaults to [defaultSeriesKey]; a custom key usually extends it
  /// rather than replaces it (see the example in the class docs). Called for
  /// every collapsible entry, during root dispatch.
  final String Function(LogEntry entry) seriesKey;

  /// Running series by key, from least recently repeated to most recent.
  final Map<String, _Series> _series = {};

  static bool _hasError(LogEntry entry) => entry.error != null;

  /// Default series key: error type and location ([LogEntry.location]);
  /// without a location, the stack text ([LogEntry.stackTraceText]); without
  /// a stack, the error text. For an entry without an error, the level
  /// replaces the type and the message replaces the error text. The error text
  /// is not used when the location or stack is known: an error in a loop with
  /// a changing number in its message is one error.
  static String defaultSeriesKey(LogEntry entry) {
    final error = entry.error;
    final where = switch (entry) {
      LogEntry(:final location?) => location,
      // Stack without symbols: no location can be extracted, but within one
      // process it is identical for repeats from one place.
      LogEntry(:final stackTraceText?) => stackTraceText,
      _ => error?.message ?? entry.message,
    };
    return error != null ? 'error ${error.type} @ $where' : '${entry.level.name} @ $where';
  }

  /// Passes [entry] to [inner] or counts it as a repeat of a running series.
  @override
  void onAdd(LogEntry entry) {
    if (!isCollapsible(entry)) {
      inner.add(entry);
      return;
    }
    final key = seriesKey(entry);
    final series = _series.remove(key);
    if (series != null) {
      // An entry earlier than the first occurrence (a startup-phase entry
      // replayed later) does not belong to the series: otherwise the summary
      // would get a time earlier than the first.
      final sinceFirst = entry.time.difference(series.first.time);
      if (!sinceFirst.isNegative && sinceFirst < window) {
        series.countRepeat(entry);
        _series[key] = series;
        return;
      }
      _end(series);
    }
    _start(key, entry);
    inner.add(entry);
  }

  void _start(String key, LogEntry first) {
    if (_series.length >= maxTrackedSeries) {
      final oldestKey = _series.keys.first;
      _end(_series.remove(oldestKey)!);
    }
    // The location is already resolved for the series key; the copy does not parse the stack.
    final series = _Series(first.withoutLiveObjects());
    // The timer summary runs outside the `RootLogger` fan-out, which catches
    // sink failures: without protection an inner failure would escape to the zone.
    series.timer = Timer(window, () {
      if (!identical(_series[key], series)) return;
      _series.remove(key);
      try {
        _end(series);
      } on Object catch (error, stackTrace) {
        diagnostics.report(
          LogDiagnostic('$name: summary delivery failed', error: error, stackTrace: stackTrace),
        );
      }
    });
    _series[key] = series;
  }

  void _end(_Series series) {
    series.timer?.cancel();
    _writeSummary(series);
  }

  /// Passes a summary of the series' suppressed repeats to [inner], if there
  /// were any: otherwise the log would not show the error was in a loop. If
  /// the repeat texts differed from the first occurrence, the summary lists
  /// them: different errors may have passed under one key. The series does
  /// not end here: the next repeat within [window] is suppressed again.
  void _writeSummary(_Series series) {
    final lastRepeat = series.lastRepeat;
    if (lastRepeat == null) return;
    final kind = series.first.error != null ? 'Error' : 'Entry';
    final otherTexts = series.otherTexts;
    final also = otherTexts.isEmpty
        ? ''
        : ' (also ${otherTexts.length} other text(s): '
              '${[for (final text in otherTexts) '"$text"', if (series.hasMoreOtherTexts) '…'].join(', ')})';
    // The summary has no [LogEntry.error] (it does not itself take part in error
    // collapsing) and no stack: time, level, tags, location and parameters of the last repeat.
    inner.add(
      lastRepeat.copyWith(
        message: '$kind repeated ${series.repeats} more time(s): ${series.firstText}$also',
        error: () => null,
        stackTrace: () => null,
      ),
    );
    series.resetRepeats();
  }

  /// Passes summaries of suppressed repeats for all series and waits for [inner].
  @override
  Future<void> onFlush() {
    _series.values.forEach(_writeSummary);
    return super.onFlush();
  }

  /// Ends all series and closes [inner].
  @override
  Future<void> onClose() {
    final series = [..._series.values];
    _series.clear();
    series.forEach(_end);
    return super.onClose();
  }
}

/// A repeat series: the first occurrence, passed to the sink, and the repeats
/// suppressed since the last summary.
final class _Series {
  _Series(this.first) : firstText = _textOf(first);

  final LogEntry first;

  /// Text of the first occurrence: the error (type and text) or the message.
  final String firstText;

  Timer? timer;
  int repeats = 0;

  /// Last suppressed repeat; `null` if there were no repeats since the last summary.
  LogEntry? lastRepeat;

  /// Texts of suppressed repeats that differ from [firstText] and from each
  /// other, in order of appearance, at most [RepeatCollapsingSink.maxOtherTextsInSummary].
  final Set<String> otherTexts = {};

  /// Whether there were distinct texts beyond [otherTexts].
  bool hasMoreOtherTexts = false;

  /// Counts [entry] as a repeat: without live objects
  /// ([LogEntry.withoutLiveObjects]), since the series lives until the window ends.
  void countRepeat(LogEntry entry) {
    repeats += 1;
    lastRepeat = entry.withoutLiveObjects();
    final text = _textOf(entry);
    if (text == firstText || otherTexts.contains(text)) return;
    if (otherTexts.length < RepeatCollapsingSink.maxOtherTextsInSummary) {
      otherTexts.add(text);
    } else {
      hasMoreOtherTexts = true;
    }
  }

  /// Restarts repeat counting: after a summary.
  void resetRepeats() {
    repeats = 0;
    lastRepeat = null;
    otherTexts.clear();
    hasMoreOtherTexts = false;
  }

  static String _textOf(LogEntry entry) => entry.error?.toString() ?? entry.message;
}
