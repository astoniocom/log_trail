import 'package:log_trail/log_trail.dart';
import 'package:test/test.dart';

void main() {
  test('dart test runs in debug', () {
    expect(BuildMode.current, BuildMode.debug);
  });

  test('isDebug and isRelease', () {
    expect(BuildMode.debug.isDebug, isTrue);
    expect(BuildMode.debug.isRelease, isFalse);
    expect(BuildMode.profile.isDebug, isFalse);
    expect(BuildMode.profile.isRelease, isFalse);
    expect(BuildMode.release.isDebug, isFalse);
    expect(BuildMode.release.isRelease, isTrue);
  });
}
