## 0.2.0

- Requires Dart 3.13 and Flutter 3.47, the floor of `material_ui` ^1.11.1.
  The viewer widgets import `package:material_ui/material_ui.dart` instead of
  `package:flutter/material.dart`.

## 0.1.1

- Requires Dart 3.8 and Flutter 3.32 instead of Dart 3.13. `meta` is a
  direct dependency: `@internal` was reached through
  `flutter/foundation.dart`, which re-exports it only on newer Flutter.

## 0.1.0

Initial release.
