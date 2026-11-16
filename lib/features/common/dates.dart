/// Short date/time words used on the paywall, plan, Ask and import screens.
/// English only for v1 (the app is English-only).
library;

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
];
const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _daysLong = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'
];

/// "Nov 19"
String monthDay(DateTime d) => '${_months[d.month - 1]} ${d.day}';

/// "Wed, Nov 19"
String weekdayMonthDay(DateTime d) => '${_days[d.weekday - 1]}, ${monthDay(d)}';

/// "Wednesday, Nov 19"
String longWeekdayMonthDay(DateTime d) =>
    '${_daysLong[d.weekday - 1]}, ${monthDay(d)}';

/// "Nov 19, 2027"
String monthDayYear(DateTime d) => '${monthDay(d)}, ${d.year}';

/// "9:05 AM"
String clockTime(DateTime d) {
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final m = d.minute.toString().padLeft(2, '0');
  return '$h:$m ${d.hour < 12 ? 'AM' : 'PM'}';
}

/// "19th"
String ordinal(int n) {
  if (n % 100 >= 11 && n % 100 <= 13) return '${n}th';
  return switch (n % 10) {
    1 => '${n}st',
    2 => '${n}nd',
    3 => '${n}rd',
    _ => '${n}th'
  };
}

/// "Today", "Yesterday", "Mon" (this week) or "Nov 3".
String dayLabel(DateTime d, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  if (diff > 1 && diff < 7) return _days[d.weekday - 1];
  return d.year == now.year ? monthDay(d) : monthDayYear(d);
}

/// "14:02" or "1:02:05" for a position in a recording.
String clockPosition(int ms) {
  final d = Duration(milliseconds: ms < 0 ? 0 : ms);
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// "118 MB", "4.2 MB", "820 KB"
String megabytes(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KB';
  final mb = bytes / (1024 * 1024);
  return mb < 10 ? '${mb.toStringAsFixed(1)} MB' : '${mb.round()} MB';
}
