import 'package:flutter/material.dart';
import 'package:log_trail/log_trail.dart';
import 'package:log_trail_flutter/src/widgets/tag_color.dart';

/// Log viewer colors: an extension of the app theme.
///
/// Without configuration the colors derive from the current theme's [ColorScheme]
/// ([LogViewerTheme.fallback]), so light and dark themes work out of the box. To override, add
/// the extension to the theme:
///
/// ```dart
/// ThemeData(extensions: [LogViewerTheme.fallback(colorScheme).copyWith(fatalColor: Colors.black)]);
/// ```
@immutable
class LogViewerTheme extends ThemeExtension<LogViewerTheme> {
  const LogViewerTheme({
    required this.traceColor,
    required this.debugColor,
    required this.infoColor,
    required this.warningColor,
    required this.errorColor,
    required this.fatalColor,
    required this.warningBackground,
    required this.errorBackground,
    this.tagColor = colorForTag,
  });

  /// Default colors for [scheme]: the trace, debug, info and error levels take scheme colors;
  /// Material has no colors for warning and fatal, so those are constant.
  factory LogViewerTheme.fallback(ColorScheme scheme) {
    final isDark = scheme.brightness == Brightness.dark;
    return LogViewerTheme(
      traceColor: scheme.outlineVariant,
      debugColor: scheme.outline,
      infoColor: scheme.primary,
      warningColor: Colors.deepOrangeAccent,
      errorColor: scheme.error,
      fatalColor: Colors.purple,
      warningBackground: isDark ? const Color(0xFF201300) : const Color(0xFFFFFDE7),
      errorBackground: isDark ? const Color(0xFF200000) : scheme.error.withAlpha(50),
    );
  }

  /// Theme from the context: the extension from [ThemeData.extensions], or
  /// [LogViewerTheme.fallback] for the current [ColorScheme].
  factory LogViewerTheme.of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<LogViewerTheme>() ?? LogViewerTheme.fallback(theme.colorScheme);
  }

  /// [theme] with the [LogViewerTheme] extension: the same theme if it already has one, otherwise
  /// a copy with [LogViewerTheme.fallback]. The list page wraps its tiles in it so each finds a
  /// ready theme via [LogViewerTheme.of] instead of building a fallback on every build. Compute
  /// the result in `didChangeDependencies`, not in `build`: [ThemeData.copyWith] is not free.
  static ThemeData resolveIn(ThemeData theme) => theme.extension<LogViewerTheme>() != null
      ? theme
      : theme.copyWith(extensions: [...theme.extensions.values, LogViewerTheme.fallback(theme.colorScheme)]);

  /// Colors of the level icons in the list.
  final Color traceColor;
  final Color debugColor;
  final Color infoColor;
  final Color warningColor;
  final Color errorColor;
  final Color fatalColor;

  /// Tile background for warnings and for errors (error and fatal).
  final Color warningBackground;
  final Color errorBackground;

  /// Tag color: the same tag is always colored the same.
  final Color Function(String tag) tagColor;

  Color levelColor(LogLevel level) => switch (level) {
    LogLevel.trace => traceColor,
    LogLevel.debug => debugColor,
    LogLevel.info => infoColor,
    LogLevel.warning => warningColor,
    LogLevel.error => errorColor,
    LogLevel.fatal => fatalColor,
  };

  /// Tile background for [level]; `null` means the regular background.
  Color? levelBackground(LogLevel level) => switch (level) {
    LogLevel.trace || LogLevel.debug || LogLevel.info => null,
    LogLevel.warning => warningBackground,
    LogLevel.error || LogLevel.fatal => errorBackground,
  };

  @override
  LogViewerTheme copyWith({
    Color? traceColor,
    Color? debugColor,
    Color? infoColor,
    Color? warningColor,
    Color? errorColor,
    Color? fatalColor,
    Color? warningBackground,
    Color? errorBackground,
    Color Function(String tag)? tagColor,
  }) => LogViewerTheme(
    traceColor: traceColor ?? this.traceColor,
    debugColor: debugColor ?? this.debugColor,
    infoColor: infoColor ?? this.infoColor,
    warningColor: warningColor ?? this.warningColor,
    errorColor: errorColor ?? this.errorColor,
    fatalColor: fatalColor ?? this.fatalColor,
    warningBackground: warningBackground ?? this.warningBackground,
    errorBackground: errorBackground ?? this.errorBackground,
    tagColor: tagColor ?? this.tagColor,
  );

  @override
  LogViewerTheme lerp(LogViewerTheme? other, double t) {
    if (other == null) return this;
    return LogViewerTheme(
      traceColor: Color.lerp(traceColor, other.traceColor, t)!,
      debugColor: Color.lerp(debugColor, other.debugColor, t)!,
      infoColor: Color.lerp(infoColor, other.infoColor, t)!,
      warningColor: Color.lerp(warningColor, other.warningColor, t)!,
      errorColor: Color.lerp(errorColor, other.errorColor, t)!,
      fatalColor: Color.lerp(fatalColor, other.fatalColor, t)!,
      warningBackground: Color.lerp(warningBackground, other.warningBackground, t)!,
      errorBackground: Color.lerp(errorBackground, other.errorBackground, t)!,
      // A function cannot be interpolated: switch halfway through the animation.
      tagColor: t < 0.5 ? tagColor : other.tagColor,
    );
  }

  /// Themes with the same colors and the same [tagColor] function are equal: [ThemeData] compares
  /// extensions by `==`, and without equality every new theme copy would rebuild all its
  /// consumers.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LogViewerTheme &&
          other.traceColor == traceColor &&
          other.debugColor == debugColor &&
          other.infoColor == infoColor &&
          other.warningColor == warningColor &&
          other.errorColor == errorColor &&
          other.fatalColor == fatalColor &&
          other.warningBackground == warningBackground &&
          other.errorBackground == errorBackground &&
          other.tagColor == tagColor;

  @override
  int get hashCode => Object.hash(
    traceColor,
    debugColor,
    infoColor,
    warningColor,
    errorColor,
    fatalColor,
    warningBackground,
    errorBackground,
    tagColor,
  );
}
