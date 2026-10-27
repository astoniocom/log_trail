import 'package:log_trail/log_trail.dart';
import 'package:log_trail/testing.dart';
import 'package:test/test.dart';

LogEntry _entry(String message) => LogEntry(time: DateTime(2026), level: LogLevel.info, message: message);

/// Custom wrapper over [DelegatingSink]: passes every second entry.
final class _EveryOtherSink extends DelegatingSink {
  _EveryOtherSink(super.inner);

  int _count = 0;

  @override
  void onAdd(LogEntry entry) {
    if ((_count++).isEven) inner.add(entry);
  }
}

void main() {
  test('a subclass only needs onAdd: flush and close reach inner', () async {
    final inner = RecordingLogSink();
    final sink = _EveryOtherSink(inner)
      ..add(_entry('a'))
      ..add(_entry('b'))
      ..add(_entry('c'));

    await sink.flush();
    expect(inner.flushCount, 1);
    expect(inner.closeCount, 0);

    await sink.close();
    expect(inner.closeCount, 1);
    expect(inner.messages, ['a', 'c']);
  });

  test('attach passes the diagnostics reporter to inner through the whole wrapper chain', () {
    final inner = RecordingLogSink();
    final reporter = DiagnosticReporter((_) {});

    _EveryOtherSink(FilteringSink.minLevel(inner, LogLevel.info)).attach(reporter);

    expect(inner.diagnostics, same(reporter));
  });

  test('library wrappers are built on it', () {
    final inner = RecordingLogSink();
    expect(FilteringSink.minLevel(inner, LogLevel.info).inner, same(inner));
    expect(RepeatCollapsingSink(inner).inner, same(inner));
  });
}
