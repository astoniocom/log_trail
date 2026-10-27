import 'dart:async';

import 'package:log_trail/log_trail.dart';
import 'package:log_trail/storage.dart';
import 'package:test/test.dart';

class _DiskFullException implements Exception {
  const _DiskFullException();
}

class _MemoryStore implements LogStore {
  final List<LogEntry> written = [];

  /// Batches exactly as the sink passed them.
  final List<List<String>> batches = [];
  int closeCount = 0;

  bool get isClosed => closeCount > 0;

  /// Until completed, the current batch is not saved.
  Completer<void>? gate;

  /// If set, the write fails with this error.
  Exception? writeError;

  @override
  Stream<LogStoreChange> get changes => const Stream.empty();

  @override
  Future<List<StoredLogEntry>> writeEntries(List<LogEntry> entries) async {
    batches.add([for (final entry in entries) entry.message]);
    final gate = this.gate;
    if (gate != null) await gate.future;
    final writeError = this.writeError;
    if (writeError != null) throw writeError;
    written.addAll(entries);
    return [
      for (final (index, entry) in entries.indexed) StoredLogEntry(written.length - entries.length + index + 1, entry),
    ];
  }

  @override
  Future<void> clear() async => written.clear();

  @override
  Future<void> removeBefore(DateTime time) async => written.removeWhere((entry) => entry.time.isBefore(time));

  @override
  Future<void> retainNewest(int count) async {
    if (written.length > count) written.removeRange(0, written.length - count);
  }

  @override
  Future<LogPage> queryEntries([LogQuery query = const LogQuery()]) async =>
      queryInMemory([for (final (index, entry) in written.indexed) StoredLogEntry(index + 1, entry)], query);

  @override
  Future<Set<String>> queryTags() async => {for (final entry in written) ...entry.tags};

  @override
  Future<void> close() async => closeCount++;
}

/// One event-loop turn: zero-delay timers fire.
Future<void> nextEventLoopTurn() => Future<void>.delayed(Duration.zero);

void main() {
  late _MemoryStore store;
  late RootLogger logger;

  setUp(() {
    store = _MemoryStore();
    logger = RootLogger(sinks: [LogStoreSink(store)])..finishStartup();
  });

  tearDown(() => logger.close());

  test('every accepted entry is saved; error repeats are not collapsed', () async {
    final stack = StackTrace.current;
    logger
      ..recordError(StateError('a'), stack)
      ..recordError(StateError('a'), stack);
    await logger.flush();

    expect(store.written.map((e) => e.message), ['Bad state: a', 'Bad state: a']);
  });

  test('the store write starts in the next event-loop turn, not in the log call', () async {
    logger.log('a');
    expect(store.batches, isEmpty, reason: 'the log call returned, the store has not been called yet');

    await Future<void>.microtask(() {});
    expect(store.batches, isEmpty, reason: 'microtasks are still in the current frame');

    await nextEventLoopTurn();
    expect(store.batches, [
      ['a'],
    ]);
  });

  test('entries of one root dispatch go as one batch', () async {
    logger
      ..log('a')
      ..log('b')
      ..log('c');
    await nextEventLoopTurn();

    expect(store.batches, [
      ['a', 'b', 'c'],
    ]);
  });

  test('the root dispatches a fatal entry in the call: the store gets it at once, batched with what accumulated', () {
    logger
      ..log('before')
      ..log('fatal', level: LogLevel.fatal);

    expect(store.batches, [
      ['before', 'fatal'],
    ], reason: 'no event-loop wait, order preserved');
  });

  test(
    'a fatal entry during an in-progress write is not passed in parallel, '
    'but goes as the next batch right after it completes, without an event-loop turn',
    () async {
      final gate = store.gate = Completer<void>();
      logger.log('a');
      await nextEventLoopTurn();
      expect(store.batches, [
        ['a'],
      ], reason: 'the store is writing the first batch');

      logger.log('fatal', level: LogLevel.fatal);
      await pumpEventQueue();
      expect(store.batches, [
        ['a'],
      ], reason: 'nothing is passed to the store in parallel with an in-progress write');

      store.gate = null;
      gate.complete();
      // A zero-delay timer fires after all microtasks: if the second batch has
      // been passed by then, it did not wait for an event-loop turn.
      final batchesAtNextTurn = Completer<List<List<String>>>();
      Timer(Duration.zero, () => batchesAtNextTurn.complete([...store.batches]));
      expect(await batchesAtNextTurn.future, [
        ['a'],
        ['fatal'],
      ]);

      await logger.flush();
      expect(store.written.map((e) => e.message), ['a', 'fatal']);
    },
  );

  test('the sink follows the root policy: with immediateLevel: null even fatal waits for dispatch', () async {
    final store = _MemoryStore();
    final logger = RootLogger(sinks: [LogStoreSink(store)], dispatch: const LogDispatchPolicy(immediateLevel: null))
      ..finishStartup();
    addTearDown(logger.close);

    logger.log('fatal', level: LogLevel.fatal);
    expect(store.batches, isEmpty);

    await nextEventLoopTurn();
    expect(store.batches, [
      ['fatal'],
    ]);
  });

  test('without a root nobody signals the batch end: the write starts at the end of the task, as one batch', () async {
    final store = _MemoryStore();
    final sink = LogStoreSink(store);
    addTearDown(sink.close);

    sink
      ..add(LogEntry(time: DateTime(2026), level: LogLevel.info, message: 'a'))
      ..add(LogEntry(time: DateTime(2026), level: LogLevel.info, message: 'b'));
    expect(store.batches, isEmpty);

    await Future<void>.microtask(() {});
    expect(store.batches, [
      ['a', 'b'],
    ]);
  });

  test('an end of batch signaled by a wrapper starts the write at once', () {
    final store = _MemoryStore();
    final sink = RepeatCollapsingSink(LogStoreSink(store));
    addTearDown(sink.close);

    sink
      ..add(LogEntry(time: DateTime(2026), level: LogLevel.info, message: 'a'))
      ..endBatch();

    expect(store.batches, [
      ['a'],
    ]);
  });

  test('while the store writes a batch, further entries accumulate and go as one batch in order', () async {
    final gate = store.gate = Completer<void>();
    logger.log('a');
    await nextEventLoopTurn();
    logger
      ..log('b')
      ..log('c');
    await pumpEventQueue();
    expect(store.batches, [
      ['a'],
    ], reason: 'the next batch is not passed until the current one completes');

    store.gate = null;
    gate.complete();
    await logger.flush();

    expect(store.batches, [
      ['a'],
      ['b', 'c'],
    ]);
    expect(store.written.map((e) => e.message), ['a', 'b', 'c']);
  });

  group('queue overflow', () {
    test('queueLimit must be positive', () {
      expect(() => LogStoreSink(store, queueLimit: 0), throwsA(isA<AssertionError>()));
    });

    test('the oldest pending entries are dropped; a warning goes first in the next batch', () async {
      final store = _MemoryStore();
      final diagnostics = <LogDiagnostic>[];
      final logger = RootLogger(
        sinks: [LogStoreSink(store, queueLimit: 2)],
        diagnostics: DiagnosticReporter(diagnostics.add),
      )..finishStartup();
      addTearDown(logger.close);
      final start = DateTime(2026, 1, 1, 12);

      final gate = store.gate = Completer<void>();
      logger.log('writing', time: start);
      await nextEventLoopTurn();
      for (var i = 1; i <= 5; i++) {
        logger.log('queued $i', time: start.add(Duration(seconds: i)));
      }
      store.gate = null;
      gate.complete();
      await logger.flush();

      expect(store.batches, [
        ['writing'],
        ['Log store queue overflow: 3 entry(ies) dropped', 'queued 4', 'queued 5'],
      ]);
      final warning = store.written[1];
      expect(warning.level, LogLevel.warning);
      expect(warning.tags, {storageLogTag});
      expect(warning.time, start.add(const Duration(seconds: 3)), reason: 'time of the last dropped entry');
      expect(diagnostics, hasLength(1), reason: 'diagnostics are reported once per overflow episode');
      expect(diagnostics.single.message, contains('queue overflow'));
      expect(diagnostics.single.error, isNull);
    });

    test('after the queue drains the counter resets; no new losses, no warnings', () async {
      final store = _MemoryStore();
      final logger = RootLogger(sinks: [LogStoreSink(store, queueLimit: 1)])..finishStartup();
      addTearDown(logger.close);

      final gate = store.gate = Completer<void>();
      logger.log('writing');
      await nextEventLoopTurn();
      logger
        ..log('dropped')
        ..log('kept');
      store.gate = null;
      gate.complete();
      await logger.flush();
      logger.log('later');
      await logger.flush();

      expect(store.written.map((e) => e.message), [
        'writing',
        'Log store queue overflow: 1 entry(ies) dropped',
        'kept',
        'later',
      ]);
    });

    test('within the limit nothing is dropped', () async {
      final store = _MemoryStore();
      final logger = RootLogger(sinks: [LogStoreSink(store, queueLimit: 3)])..finishStartup();
      addTearDown(logger.close);

      final gate = store.gate = Completer<void>();
      logger.log('writing');
      await nextEventLoopTurn();
      logger
        ..log('a')
        ..log('b')
        ..log('c');
      store.gate = null;
      gate.complete();
      await logger.flush();

      expect(store.written.map((e) => e.message), ['writing', 'a', 'b', 'c']);
    });
  });

  test('flush waits for the save; the sink stays open', () async {
    final gate = store.gate = Completer<void>();
    logger.log('pending');

    var isFlushed = false;
    final flushing = logger.flush().then((_) => isFlushed = true);
    await pumpEventQueue();
    expect(isFlushed, isFalse, reason: 'the write has not completed yet');

    store.gate = null;
    gate.complete();
    await flushing;
    expect(store.written.single.message, 'pending');
    expect(store.isClosed, isFalse);

    logger.log('after flush');
    await logger.flush();
    expect(store.written.last.message, 'after flush');
  });

  test('flush waits for entries accepted before the call and not for those accepted later', () async {
    final gate1 = store.gate = Completer<void>();
    logger.log('a');
    await nextEventLoopTurn();
    logger.log('b');
    expect(store.batches, [
      ['a'],
    ], reason: 'a is being written, b is queued');

    var isFlushed = false;
    final flushing = logger.flush().then((_) => isFlushed = true);
    final gate2 = store.gate = Completer<void>();
    gate1.complete();
    await pumpEventQueue();
    expect(store.batches, [
      ['a'],
      ['b'],
    ]);
    expect(isFlushed, isFalse, reason: 'b was accepted before flush and is still being written');

    logger.log('c');
    final gate3 = store.gate = Completer<void>();
    gate2.complete();
    await pumpEventQueue();
    expect(isFlushed, isTrue, reason: 'c was accepted after flush: flush does not wait for it');
    expect(store.written.map((e) => e.message), ['a', 'b']);
    expect(store.batches, [
      ['a'],
      ['b'],
      ['c'],
    ], reason: 'c is written as its own batch');

    store.gate = null;
    gate3.complete();
    await flushing;
    await logger.flush();
    expect(store.written.map((e) => e.message), ['a', 'b', 'c']);
  });

  test('flush with no entries and no in-progress write completes at once', () async {
    await logger.flush();
    expect(store.batches, isEmpty);
  });

  test('close waits for writes but does not close the store: the app owns it', () async {
    final gate = store.gate = Completer<void>();
    logger.log('pending');

    final closing = logger.close();
    await pumpEventQueue();
    expect(store.written, isEmpty, reason: 'the write is still in progress');

    gate.complete();
    await closing;
    expect(store.written.single.message, 'pending');
    expect(store.isClosed, isFalse);
    // A viewer open on the same store keeps reading.
    final page = await store.queryEntries();
    expect(page.entries.single.entry.message, 'pending');
  });

  test('does not write to the store after close', () async {
    final sink = LogStoreSink(store);
    await sink.close();
    await sink.close();

    expect(() => sink.add(LogEntry(time: DateTime(2026), level: LogLevel.info, message: 'late')), throwsStateError);
    await pumpEventQueue();
    expect(store.batches, isEmpty);
    expect(store.closeCount, 0);
  });

  test('a write failure does not reach the zone as an unhandled error', () async {
    store.writeError = const _DiskFullException();
    final unhandled = <Object>[];

    await runZonedGuarded(() async {
      logger.log('lost');
      await logger.flush();
    }, (error, _) => unhandled.add(error));

    expect(unhandled, isEmpty);
    expect(store.written, isEmpty);
  });

  test('a write failure without onWriteError goes to diagnostics with the error and stack', () async {
    final diagnostics = <LogDiagnostic>[];
    final logger = RootLogger(sinks: [LogStoreSink(store)], diagnostics: DiagnosticReporter(diagnostics.add))
      ..finishStartup();
    addTearDown(logger.close);
    store.writeError = const _DiskFullException();

    logger.log('lost');
    await logger.flush();

    final diagnostic = diagnostics.single;
    expect(diagnostic.message, 'LogStoreSink: the store failed to write 1 entries');
    expect(diagnostic.error, isA<_DiskFullException>());
    expect(diagnostic.stackTrace, isNotNull);
  });

  test('a failure of onWriteError itself goes to diagnostics, then the write failure is reported too', () async {
    final diagnostics = <LogDiagnostic>[];
    final logger = RootLogger(
      sinks: [
        LogStoreSink(
          store,
          onWriteError: (_, _, _) => throw StateError('handler broke'),
        ),
      ],
      diagnostics: DiagnosticReporter(diagnostics.add),
    )..finishStartup();
    addTearDown(logger.close);
    store.writeError = const _DiskFullException();

    logger.log('lost');
    await logger.flush();

    expect(diagnostics.map((d) => d.message), [
      'LogStoreSink: onWriteError failed',
      'LogStoreSink: the store failed to write 1 entries',
    ]);
    expect(diagnostics.first.error, isA<StateError>());
    expect(diagnostics.last.error, isA<_DiskFullException>());
  });

  test('onWriteError receives the error and the unsaved entries; the next batches are written', () async {
    final failures = <(Object, List<String>)>[];
    final logger = RootLogger(
      sinks: [
        LogStoreSink(
          store,
          onWriteError: (error, _, entries) => failures.add((error, [for (final e in entries) e.message])),
        ),
      ],
    )..finishStartup();
    addTearDown(logger.close);

    store.writeError = const _DiskFullException();
    logger.log('lost');
    await logger.flush();
    store.writeError = null;
    logger.log('saved');
    await logger.flush();

    expect(failures.single.$1, isA<_DiskFullException>());
    expect(failures.single.$2, ['lost']);
    expect(store.written.single.message, 'saved');
  });
}
