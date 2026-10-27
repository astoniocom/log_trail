import 'dart:collection';
import 'dart:math' as math;

import 'package:meta/meta.dart';

/// An oldest-to-newest queue with a length limit: on overflow the oldest
/// items are dropped and the losses are counted.
///
/// Shared by the deferred-dispatch queue (`DeferredQueue`) and the startup
/// buffer (`StartupBuffer`): with a looping error the latest events matter
/// more, and the limit is mandatory, otherwise such an error eats memory.
/// Losses are not silent: [droppedCount] and [lastDropped] describe the loss
/// episode since the last [takeAll] or [clear], and [onOverflow] is called on
/// the first loss of an episode. The queue owner decides what to report about
/// losses and where.
@internal
final class BoundedQueue<T> {
  BoundedQueue({required this.limit, this.onOverflow}) : assert(limit > 0, 'limit must be positive');

  /// Maximum number of items in the queue.
  final int limit;

  /// Called on the first loss of an overflow episode (until the next
  /// [takeAll] or [clear]).
  final void Function()? onOverflow;

  final Queue<T> _items = ListQueue();
  int _droppedCount = 0;
  T? _lastDropped;

  bool get isEmpty => _items.isEmpty;
  bool get isNotEmpty => _items.isNotEmpty;
  int get length => _items.length;

  /// How many items were dropped since the last [takeAll] or [clear].
  int get droppedCount => _droppedCount;

  /// The last item dropped in the episode; `null` if nothing was lost.
  /// Dropped items are older than the remaining ones, so the owner can date
  /// the warning by it without breaking order.
  T? get lastDropped => _lastDropped;

  /// Adds [item]; on overflow drops the oldest item.
  void add(T item) {
    _items.add(item);
    if (_items.length > limit) {
      _lastDropped = _items.removeFirst();
      _droppedCount++;
      if (_droppedCount == 1) onOverflow?.call();
    }
  }

  /// Items in arrival order, without taking them.
  List<T> toList() => [..._items];

  /// Replaces each item with the result of [transform], in order; `null`
  /// removes the item. Loss accounting is unchanged.
  void rewrite(T? Function(T item) transform) {
    final items = toList();
    _items.clear();
    for (final item in items) {
      final next = transform(item);
      if (next != null) _items.add(next);
    }
  }

  /// Takes all items and resets loss accounting. The returned list does not
  /// change while the receiver processes it.
  List<T> takeAll() {
    final batch = toList();
    clear();
    return batch;
  }

  /// Takes up to [count] oldest items; the rest remain. Loss accounting is
  /// unchanged: the owner resets it itself ([resetDropped]) once it has
  /// reported the losses.
  List<T> take(int count) {
    assert(count > 0, 'count must be positive');
    final taken = math.min(count, _items.length);
    return [for (var i = 0; i < taken; i++) _items.removeFirst()];
  }

  /// Resets loss accounting without touching the items: the loss episode is
  /// over and has been reported.
  void resetDropped() {
    _droppedCount = 0;
    _lastDropped = null;
  }

  /// Drops the items and the loss accounting.
  void clear() {
    _items.clear();
    resetDropped();
  }
}
