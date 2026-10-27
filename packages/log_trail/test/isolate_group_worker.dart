import 'dart:io';
import 'dart:isolate';

import 'package:log_trail/isolates.dart';
import 'package:log_trail/log_trail.dart';

const _payload = LogField('test.payload', LogCodec.raw);

/// Entry point of an isolate from another group (`Isolate.spawnUri`), like the
/// isolates the engine starts for FCM or WorkManager: writes to the spool
/// (`args[0]` is the directory) and notifies the main isolate via [notify].
void main(List<String> args, SendPort notify) {
  RootLogger(
      sinks: [LogSpoolSink(LogSpool(Directory(args.single)), notify: notify)],
      dispatch: LogDispatchPolicy.synchronous,
    )
    ..finishStartup()
    ..log(
      'from another group',
      tags: {'fcm'},
      attributes: [
        _payload(
          LogMap({
            'ids': LogList(const [LogInt(1), LogInt(2)]),
          }),
        ),
      ],
    );
}
