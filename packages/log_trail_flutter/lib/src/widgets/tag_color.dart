import 'package:flutter/material.dart';

/// Tag color: the same tag is always colored the same, on every platform.
Color colorForTag(String tag) {
  var hash = 0;
  for (var i = 0; i < tag.length; i++) {
    // The hash is kept within 31 bits: otherwise one tag would get different colors on web, where
    // shifts work on 32-bit integers, and on the VM, where they work on 64-bit ones.
    hash = (tag.codeUnitAt(i) + ((hash << 5) - hash)) & 0x7FFFFFFF;
  }
  final hue = (hash % 360).toDouble();
  return HSLColor.fromAHSL(1, hue, 0.6, 0.5).toColor();
}
