/// Entry time in local time, the same in the console, export and log screens; for custom sinks and
/// screens, so entries look the same. UTC time (for example, of an entry read from a store) is converted
/// to local here: `LogEntry.time` keeps the instant as is.
library;

/// `yyyy-MM-dd HH:mm:ss.mmm`: the full entry instant for export and the entry screen, where the log
/// spans several days.
String formatLogTimestamp(DateTime time) {
  final local = time.toLocal();
  return '${_date(local)} ${_timeOfDay(local)}.${_pad(local.millisecond, 3)}';
}

/// `HH:mm:ss.mmm`: time for the console, where entries follow one another and the date is clear from
/// context.
String formatLogTimeOfDay(DateTime time) {
  final local = time.toLocal();
  return '${_timeOfDay(local)}.${_pad(local.millisecond, 3)}';
}

/// Time for a list: `HH:mm:ss` for today's entries (relative to [now], the current moment by default),
/// `yyyy-MM-dd HH:mm:ss` for the rest, so entries of different days are distinguishable.
String formatLogTime(DateTime time, {DateTime? now}) {
  final local = time.toLocal();
  final today = (now ?? DateTime.now()).toLocal();
  final isToday = local.year == today.year && local.month == today.month && local.day == today.day;
  return isToday ? _timeOfDay(local) : '${_date(local)} ${_timeOfDay(local)}';
}

String _date(DateTime time) => '${_pad(time.year, 4)}-${_pad(time.month, 2)}-${_pad(time.day, 2)}';

String _timeOfDay(DateTime time) => '${_pad(time.hour, 2)}:${_pad(time.minute, 2)}:${_pad(time.second, 2)}';

String _pad(int value, int width) => value.toString().padLeft(width, '0');
