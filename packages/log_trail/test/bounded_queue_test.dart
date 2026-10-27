import 'package:log_trail/src/util/bounded_queue.dart';
import 'package:test/test.dart';

void main() {
  late int overflows;
  late BoundedQueue<String> queue;

  setUp(() {
    overflows = 0;
    queue = BoundedQueue(limit: 2, onOverflow: () => overflows++);
  });

  test('limit must be positive', () {
    expect(() => BoundedQueue<String>(limit: 0), throwsA(isA<AssertionError>()));
  });

  test('takeAll returns elements in order and empties the queue', () {
    queue
      ..add('a')
      ..add('b');
    expect(queue.length, 2);

    expect(queue.takeAll(), ['a', 'b']);
    expect(queue.isEmpty, isTrue);
    expect(queue.takeAll(), isEmpty);
    expect(overflows, 0);
    expect(queue.droppedCount, 0);
    expect(queue.lastDropped, isNull);
  });

  test('on overflow old elements are dropped, onOverflow once per episode, drops are counted', () {
    for (var i = 1; i <= 5; i++) {
      queue.add('e$i');
    }

    expect(overflows, 1);
    expect(queue.droppedCount, 3);
    expect(queue.lastDropped, 'e3', reason: 'last dropped: the warning is dated by it');
    expect(queue.takeAll(), ['e4', 'e5']);
  });

  test('after takeAll the drop count is reset: a new episode calls onOverflow again', () {
    for (var i = 1; i <= 3; i++) {
      queue.add('e$i');
    }
    queue.takeAll();
    expect(queue.droppedCount, 0);
    expect(queue.lastDropped, isNull);

    for (var i = 4; i <= 6; i++) {
      queue.add('e$i');
    }
    expect(overflows, 2);
    expect(queue.droppedCount, 1);
    expect(queue.lastDropped, 'e4');
  });

  test('returned batch is not changed by later add calls', () {
    queue.add('a');
    final batch = queue.takeAll();
    queue.add('b');

    expect(batch, ['a']);
  });

  test('toList returns elements without taking them or resetting the drop count', () {
    for (var i = 1; i <= 3; i++) {
      queue.add('e$i');
    }

    expect(queue.toList(), ['e2', 'e3']);
    expect(queue.toList(), ['e2', 'e3'], reason: 'for the next consumer');
    expect(queue.length, 2);
    expect(queue.droppedCount, 1);
  });

  test('clear drops elements and the drop count', () {
    for (var i = 1; i <= 3; i++) {
      queue.add('e$i');
    }

    queue.clear();
    queue.add('e4');

    expect(queue.toList(), ['e4']);
    expect(queue.droppedCount, 0);
  });

  test('without onOverflow drops are counted the same way', () {
    final quiet = BoundedQueue<String>(limit: 1)
      ..add('a')
      ..add('b');

    expect(quiet.droppedCount, 1);
    expect(quiet.takeAll(), ['b']);
  });

  test('take removes up to count oldest elements, the rest and the drop count stay; resetDropped resets the count', () {
    final queue = BoundedQueue<String>(limit: 3)
      ..add('dropped')
      ..add('a')
      ..add('b')
      ..add('c');

    expect(queue.take(2), ['a', 'b']);
    expect(queue.length, 1);
    expect(queue.droppedCount, 1, reason: 'take leaves the drop count alone');
    expect(queue.lastDropped, 'dropped');

    queue.resetDropped();
    expect(queue.droppedCount, 0);
    expect(queue.lastDropped, isNull);
    expect(queue.take(5), ['c'], reason: 'count above length: returns what there is');
    expect(queue.isEmpty, isTrue);
    expect(() => queue.take(0), throwsA(isA<AssertionError>()));
  });
}
