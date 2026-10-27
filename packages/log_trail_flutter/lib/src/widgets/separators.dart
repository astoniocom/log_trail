import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// [widgets] with [separator] between neighbors; an empty list for an empty list.
@internal
List<Widget> withSeparators(List<Widget> widgets, Widget separator) => [
  for (final (index, widget) in widgets.indexed) ...[if (index > 0) separator, widget],
];
