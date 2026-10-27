// Tags of entries written by the library itself. They select such entries
// (`LogFilter(tags: {storageLogTag})`) and hide them from output
// (`isTagVisible: (tag) => !tag.startsWith(libraryLogTagPrefix)`).
//
// All library tags, here and in `log_trail_flutter`, start with
// `libraryLogTagPrefix`, as its field names (`LogField`) start with
// `log_trail.`: an unprefixed tag (`storage`, `navigation`) would clash with
// an app module's tag, and a filter on it would mix module entries with
// library warnings. Values do not change between versions, otherwise the
// filter would stop finding previously saved entries.

/// Prefix of all tags set by the library.
const String libraryLogTagPrefix = 'log_trail.';

/// Warning about startup events lost to `RootLogger` buffer overflow.
const String startupLogTag = '${libraryLogTagPrefix}startup';

/// Warning about entries lost to `LogStoreSink` queue overflow: the store
/// could not keep up saving them.
const String storageLogTag = '${libraryLogTagPrefix}storage';
