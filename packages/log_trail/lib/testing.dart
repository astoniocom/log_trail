/// Test doubles and checks for code that logs or extends the library:
/// `RecordingLogSink` records entries and lifecycle calls in place of a mock,
/// which the `base` `LogSink` does not allow; `compareLogStores` checks a
/// `LogStore` implementation against the in-memory reference over a random
/// scenario (`LogStoreScenario`) and reports where they disagree. Depends on
/// no test framework. Separate from `log_trail.dart` so that application code
/// does not see it.
library;

export 'package:log_trail/src/testing/log_store_contract.dart';
export 'package:log_trail/src/testing/recording_log_sink.dart';
