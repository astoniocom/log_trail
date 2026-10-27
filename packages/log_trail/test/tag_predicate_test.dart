import 'package:log_trail/log_trail.dart';
import 'package:test/test.dart';

void main() {
  const tags = {'network', 'internal.route', 'auth'};

  test('whereVisible without a predicate returns all tags', () {
    expect(tags.whereVisible(null), tags);
  });

  test('whereVisible keeps tags the predicate accepts, in original order', () {
    expect(tags.whereVisible((tag) => !tag.startsWith('internal.')), ['network', 'auth']);
  });

  test('library tags start with libraryLogTagPrefix and are hidden by it with one predicate', () {
    const libraryTags = {startupLogTag, storageLogTag};

    expect(libraryTags, everyElement(startsWith(libraryLogTagPrefix)));
    expect({...libraryTags, 'storage'}.whereVisible((tag) => !tag.startsWith(libraryLogTagPrefix)), ['storage']);
  });
}
