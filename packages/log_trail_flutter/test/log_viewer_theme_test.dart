import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:log_trail_flutter/log_trail_flutter.dart';
import 'package:log_trail_flutter/widgets.dart';

LogEntry _entry(LogLevel level) =>
    LogEntry(time: DateTime(2026, 1, 1, 12), level: level, message: 'message', tags: const {'net'});

void main() {
  test('tag color is the same on every platform: the hue is pinned', () {
    // Values computed with the 31-bit hash formula; a mismatch on web
    // (32-bit shifts) or VM (64-bit) fails the test on that platform.
    expect(HSLColor.fromColor(colorForTag('network')).hue, closeTo(110, 0.5));
    expect(HSLColor.fromColor(colorForTag('ui')).hue, closeTo(132, 0.5));
    expect(colorForTag('network'), colorForTag('network'));
    expect(colorForTag('network'), isNot(colorForTag('ui')));
  });

  testWidgets('without the extension, colors derive from the theme ColorScheme', (tester) async {
    final scheme = ColorScheme.fromSeed(seedColor: Colors.teal, brightness: Brightness.dark);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(colorScheme: scheme),
        home: Scaffold(body: LogEntryTile(_entry(LogLevel.error))),
      ),
    );

    final icon = tester.widget<Icon>(find.byType(Icon));
    expect(icon.color, scheme.error);
    final material = tester.widget<Material>(
      find.ancestor(of: find.byType(ListTile), matching: find.byType(Material)).first,
    );
    expect(material.color, LogViewerTheme.fallback(scheme).errorBackground);
  });

  testWidgets('the theme extension overrides icon, background and tag colors', (tester) async {
    final theme = LogViewerTheme.fallback(const ColorScheme.light()).copyWith(
      warningColor: Colors.pink,
      warningBackground: Colors.lime,
      tagColor: (_) => Colors.indigo,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: [theme]),
        home: Scaffold(body: LogEntryTile(_entry(LogLevel.warning))),
      ),
    );

    expect(tester.widget<Icon>(find.byType(Icon)).color, Colors.pink);
    final material = tester.widget<Material>(
      find.ancestor(of: find.byType(ListTile), matching: find.byType(Material)).first,
    );
    expect(material.color, Colors.lime);
    expect(tester.widget<Text>(find.text('net')).style?.color, Colors.indigo);
  });

  test('levelColor and levelBackground cover all levels', () {
    final theme = LogViewerTheme.fallback(const ColorScheme.light());

    for (final level in LogLevel.values) {
      expect(theme.levelColor(level), isA<Color>());
    }
    expect(theme.levelColor(LogLevel.trace), theme.traceColor);
    expect(theme.levelBackground(LogLevel.trace), isNull);
    expect(theme.levelBackground(LogLevel.debug), isNull);
    expect(theme.levelBackground(LogLevel.info), isNull);
    expect(theme.levelBackground(LogLevel.warning), theme.warningBackground);
    expect(theme.levelBackground(LogLevel.error), theme.errorBackground);
    expect(theme.levelBackground(LogLevel.fatal), theme.errorBackground);
  });

  test('lerp interpolates colors and switches the tag function at the midpoint', () {
    Color red(String _) => Colors.red;
    Color blue(String _) => Colors.blue;
    final a = LogViewerTheme.fallback(const ColorScheme.light()).copyWith(infoColor: Colors.black, tagColor: red);
    final b = a.copyWith(infoColor: Colors.white, tagColor: blue);

    final quarter = a.lerp(b, 0.25);
    expect(quarter.infoColor, Color.lerp(Colors.black, Colors.white, 0.25));
    expect(quarter.tagColor('x'), Colors.red);
    expect(a.lerp(b, 0.75).tagColor('x'), Colors.blue);
    expect(a.lerp(null, 0.5), same(a));
  });

  test('themes with the same colors and tag function are equal: a ThemeData copy does not rebuild consumers', () {
    const scheme = ColorScheme.light();
    final a = LogViewerTheme.fallback(scheme);
    final b = LogViewerTheme.fallback(scheme);

    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a, isNot(a.copyWith(infoColor: Colors.black)));
    expect(a, isNot(a.copyWith(tagColor: (_) => Colors.red)));
    expect(
      LogViewerTheme.resolveIn(ThemeData(colorScheme: scheme)),
      LogViewerTheme.resolveIn(ThemeData(colorScheme: scheme)),
    );
  });

  testWidgets('filter chips show selection state via FilterChip.selected', (tester) async {
    const initial = LogFilter(levels: {LogLevel.error}, tags: {'net'});
    LogFilter? applied;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LogFilterSheet(
            initialFilter: initial,
            availableTags: const {'net', 'ui'},
            onFilterChanged: (update) => applied = update(initial),
          ),
        ),
      ),
    );

    FilterChip chip(String label) => tester.widget<FilterChip>(find.widgetWithText(FilterChip, label));
    expect(chip('error').selected, isTrue);
    expect(chip('info').selected, isFalse);
    expect(chip('net').selected, isTrue);
    expect(chip('ui').selected, isFalse);

    await tester.tap(find.widgetWithText(FilterChip, 'info'));
    await tester.pump();
    expect(chip('info').selected, isTrue);
    expect(applied?.levels, {LogLevel.error, LogLevel.info});

    await tester.tap(find.widgetWithText(FilterChip, 'net'));
    await tester.pump();
    expect(chip('net').selected, isFalse);
    expect(applied?.tags, isEmpty);
  });
}
