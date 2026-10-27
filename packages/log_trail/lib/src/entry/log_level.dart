/// Entry level, from least to most important: levels compare with operators
/// (`level >= LogLevel.warning`).
///
/// The set is closed on purpose: the viewer, theme, filter and console know
/// every level (color, icon, name), and exhaustive `switch`es over the level
/// are checked by the compiler. Stored and transmitted by name ([name]), so
/// the order of values may change, the names may not.
enum LogLevel implements Comparable<LogLevel> {
  /// Verbose tracing: per-frame and per-packet events, enabled briefly for one
  /// module (`child(minLevel: LogLevel.trace)`). The default `RootLogger`
  /// threshold is [debug], so without explicit enabling such entries are
  /// dropped before being built.
  trace,

  /// Developer diagnostics: state, transitions, server responses.
  debug,
  info,
  warning,
  error,
  fatal;

  bool operator <(LogLevel other) => index < other.index;

  bool operator <=(LogLevel other) => index <= other.index;

  bool operator >(LogLevel other) => index > other.index;

  bool operator >=(LogLevel other) => index >= other.index;

  @override
  int compareTo(LogLevel other) => index - other.index;
}
