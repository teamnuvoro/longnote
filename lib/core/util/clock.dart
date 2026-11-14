/// Injectable clock so time-based logic (flush, heartbeat, backoff, trial
/// dates) is testable.
abstract class Clock {
  DateTime now();
}

class SystemClock implements Clock {
  const SystemClock();
  @override
  DateTime now() => DateTime.now();
}

class FakeClock implements Clock {
  FakeClock(this._now);
  DateTime _now;
  @override
  DateTime now() => _now;
  void advance(Duration d) => _now = _now.add(d);
  set current(DateTime t) => _now = t;
}

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// "1 h 5 min", "42 min", "under 1 min".
String formatMinutes(Duration d) {
  final mins = d.inMinutes;
  if (mins < 1) return d.inSeconds > 0 ? '${d.inSeconds} s' : 'under 1 min';
  if (mins < 60) return '$mins min';
  final h = mins ~/ 60;
  final m = mins % 60;
  return m == 0 ? '$h h' : '$h h $m min';
}
