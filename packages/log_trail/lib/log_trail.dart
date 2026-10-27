/// Logging facade: `RootLogger` (dispatches entries outside the logger call,
/// `LogDispatchPolicy`), the `Logger` interface for modules, the `LogEntry`
/// record with typed attributes, sinks (`LogSink`: console, filtering,
/// repeat collapsing), entry processing (`LogProcessor`, `LogRedactor`),
/// output formats and diagnostics.
///
/// Storing, reading and viewing the log (`LogStore`, `LogStoreSink`,
/// `InMemoryLogStore`, `LogQuery`, `LogWindow`, `exportLog`) is a separate
/// library, `package:log_trail/storage.dart`: code that only writes to the log
/// does not need the store contract, and store implementations depend on that
/// contract rather than on the whole facade. Logging from background isolates:
/// `package:log_trail/isolates.dart`.
library;

export 'package:log_trail/src/diagnostics/log_diagnostic.dart';
export 'package:log_trail/src/entry/call_site.dart' show WrapperFramePredicate;
export 'package:log_trail/src/entry/log_attributes.dart';
export 'package:log_trail/src/entry/log_entry.dart';
export 'package:log_trail/src/entry/log_level.dart';
export 'package:log_trail/src/entry/log_tags.dart';
export 'package:log_trail/src/entry/log_value.dart';
export 'package:log_trail/src/format/console_log_format.dart';
export 'package:log_trail/src/format/log_entry_format.dart';
export 'package:log_trail/src/format/log_entry_json_codec.dart';
export 'package:log_trail/src/format/log_export_format.dart';
export 'package:log_trail/src/format/log_time_format.dart';
export 'package:log_trail/src/format/tag_predicate.dart';
export 'package:log_trail/src/logger/log_call.dart';
export 'package:log_trail/src/logger/log_dispatch_policy.dart';
export 'package:log_trail/src/logger/log_processor.dart';
export 'package:log_trail/src/logger/log_redactor.dart';
export 'package:log_trail/src/logger/logger.dart';
export 'package:log_trail/src/logger/root_logger.dart';
export 'package:log_trail/src/sinks/console_sink.dart';
export 'package:log_trail/src/sinks/delegating_sink.dart';
export 'package:log_trail/src/sinks/filtering_sink.dart';
export 'package:log_trail/src/sinks/log_sink.dart';
export 'package:log_trail/src/sinks/repeat_collapsing_sink.dart';
export 'package:log_trail/src/util/build_mode.dart';
