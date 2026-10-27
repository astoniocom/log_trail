/// Whether to show a tag: for the console and log screens, where service tags (for example, added by app
/// wrappers to route entries) only get in the way of reading. Does not affect entry selection, only
/// output.
///
/// ```dart
/// ConsoleLogFormat(isTagVisible: (tag) => !tag.startsWith('internal.'));
/// ```
typedef TagPredicate = bool Function(String tag);

/// Selecting tags to show by a [TagPredicate] that may be unset.
extension VisibleTags on Iterable<String> {
  /// The tags that [isTagVisible] shows; all if it is unset. For custom formats and screens, so they
  /// interpret [isTagVisible] the same way as `ConsoleLogFormat` and the viewer.
  Iterable<String> whereVisible(TagPredicate? isTagVisible) => isTagVisible == null ? this : where(isTagVisible);
}
