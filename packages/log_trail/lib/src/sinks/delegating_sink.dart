import 'package:log_trail/src/diagnostics/log_diagnostic.dart';
import 'package:log_trail/src/sinks/log_sink.dart';

/// A wrapper sink over [inner]: selects or transforms entries before passing
/// them on (`FilteringSink`, `RepeatCollapsingSink`). A subclass implements
/// only [onAdd]: what to pass to [inner] and when.
///
/// The wrapper owns [inner]: [flush] waits for it, [close] closes it too, and
/// the diagnostics channel ([attach]) and the end of batch ([endBatch]) are
/// passed to it. So one sink should not be wrapped twice, or attached to the
/// logger both in a wrapper and directly: the first wrapper to close would
/// close it for the rest. Like [LogSink], the class is `base`: subclass only;
/// a custom wrapper is declared `final class`.
///
/// ```dart
/// final class SamplingSink extends DelegatingSink {
///   SamplingSink(super.inner, {required this.every});
///
///   final int every;
///   int _count = 0;
///
///   @override
///   void onAdd(LogEntry entry) {
///     if (_count++ % every == 0) inner.add(entry);
///   }
/// }
/// ```
abstract base class DelegatingSink extends LogSink {
  DelegatingSink(this.inner);

  /// Where entries are passed; the sink owns it.
  final LogSink inner;

  @override
  Future<void> onFlush() => inner.flush();

  @override
  Future<void> onClose() => inner.close();

  @override
  void onAttach(DiagnosticReporter diagnostics) => inner.attach(diagnostics);

  @override
  void onBatchEnd() => inner.endBatch();
}
