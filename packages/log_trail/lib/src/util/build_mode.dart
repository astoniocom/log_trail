/// Build mode: it determines what goes to the console.
///
/// This build's mode is [current]. Sinks and formats whose behavior depends on
/// the mode (`ConsoleSink`, `FlutterConsoleFormat`) take it as a parameter
/// defaulting to [current]: this way the behavior of any mode can be checked
/// by a test, which runs in debug.
enum BuildMode {
  /// JIT build for development: `flutter run`, `dart run`, `dart test`.
  debug,

  /// AOT build with profiling: `flutter run --profile`.
  profile,

  /// AOT build for users: a Flutter release build, `dart compile exe`.
  ///
  /// Its console output goes to the device's system log (logcat, os_log) and
  /// ends up in crash reports, so `ConsoleSink` is silent in it by default.
  release;

  /// The mode this code was built in. Detected by the same signals as
  /// `kDebugMode`, `kProfileMode` and `kReleaseMode` in Flutter, but without
  /// depending on it: the library core does not depend on Flutter.
  static const BuildMode current = _isProduct
      ? release
      : _isProfile
      ? profile
      : debug;

  bool get isDebug => this == debug;

  bool get isRelease => this == release;
}

// The only supported way to detect the build mode; kReleaseMode in Flutter
// is defined the same way.
// ignore: do_not_use_environment
const bool _isProduct = bool.fromEnvironment('dart.vm.product');

// kProfileMode in Flutter is defined the same way.
// ignore: do_not_use_environment
const bool _isProfile = bool.fromEnvironment('dart.vm.profile');
