import '../../../features/schedule/models/local_date.dart';

/// Deterministic study timezone & study-day calculator.
///
/// The review queue groups cross-day items by the configured study day (00:00
/// boundary in the user's explicit learning timezone) rather than relying on
/// unpinned device `.toLocal()` calls, while short intra-day relearning steps
/// keep exact UTC timestamps.
class StudyTimeHelper {
  StudyTimeHelper._();

  static const String defaultTimezone = 'Asia/Shanghai';

  static const Map<String, int> _fixedOffsetMinutes = {
    'UTC': 0,
    'Etc/UTC': 0,
    'GMT': 0,
    'Asia/Shanghai': 8 * 60,
    'Asia/Hong_Kong': 8 * 60,
    'Asia/Taipei': 8 * 60,
    'Asia/Tokyo': 9 * 60,
    'Asia/Seoul': 9 * 60,
    'Asia/Singapore': 8 * 60,
    'Europe/London': 0,
    'Europe/Paris': 60,
    'Europe/Berlin': 60,
    'America/New_York': -5 * 60,
    'America/Chicago': -6 * 60,
    'America/Denver': -7 * 60,
    'America/Los_Angeles': -8 * 60,
  };

  /// Returns the study-zone offset in minutes at [utcInstant]. Handles US/EU
  /// DST transitions for common IANA zones and explicit `UTC+X` / `+08:00`
  /// specifications so DST boundary tests and cross-timezone devices agree.
  static int offsetMinutesAt(
    DateTime utcInstant, {
    String timezone = defaultTimezone,
  }) {
    final utc = utcInstant.toUtc();
    final trimmed = timezone.trim();
    if (trimmed == 'America/New_York' ||
        trimmed == 'America/Chicago' ||
        trimmed == 'America/Denver' ||
        trimmed == 'America/Los_Angeles') {
      final standard = _fixedOffsetMinutes[trimmed]!;
      return _isUsDst(utc, standard) ? standard + 60 : standard;
    }
    if (trimmed == 'Europe/London' ||
        trimmed == 'Europe/Paris' ||
        trimmed == 'Europe/Berlin') {
      final standard = _fixedOffsetMinutes[trimmed]!;
      return _isEuDst(utc) ? standard + 60 : standard;
    }
    if (_fixedOffsetMinutes.containsKey(trimmed)) {
      return _fixedOffsetMinutes[trimmed]!;
    }
    final match = RegExp(
      r'^(?:UTC|GMT)?([+-])(\d{1,2})(?::?(\d{2}))?$',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (match != null) {
      final sign = match.group(1) == '-' ? -1 : 1;
      final hours = int.parse(match.group(2)!);
      final minutes = int.parse(match.group(3) ?? '0');
      return sign * (hours * 60 + minutes);
    }
    return DateTime.now().timeZoneOffset.inMinutes;
  }

  /// Wall-clock components in the study timezone encoded as a UTC-labelled
  /// [DateTime] for safe calendar arithmetic without host-TZ side effects.
  static DateTime wallClock(
    DateTime utcInstant, {
    String timezone = defaultTimezone,
  }) {
    final utc = utcInstant.toUtc();
    final offset = offsetMinutesAt(utc, timezone: timezone);
    return utc.add(Duration(minutes: offset));
  }

  /// Study day as a [LocalDate] (midnight 00:00 boundary in [timezone]).
  static LocalDate studyDate(
    DateTime utcInstant, {
    String timezone = defaultTimezone,
  }) {
    final wall = wallClock(utcInstant, timezone: timezone);
    return LocalDate(wall.year, wall.month, wall.day);
  }

  static String studyDayKey(
    DateTime utcInstant, {
    String timezone = defaultTimezone,
  }) => studyDate(utcInstant, timezone: timezone).iso;

  /// End-of-study-day UTC instant for [date] (`23:59:59` in [timezone]), or
  /// exact study-day morning cutoff (`00:00:00`) converted back to UTC.
  static DateTime studyDayStartUtc(
    LocalDate date, {
    String timezone = defaultTimezone,
  }) {
    final probeUtc = DateTime.utc(date.year, date.month, date.day, 12);
    final offset = offsetMinutesAt(probeUtc, timezone: timezone);
    return DateTime.utc(date.year, date.month, date.day)
        .subtract(Duration(minutes: offset));
  }

  static DateTime studyDayEndUtc(
    LocalDate date, {
    String timezone = defaultTimezone,
  }) => studyDayStartUtc(date.addDays(1), timezone: timezone).subtract(
    const Duration(milliseconds: 1),
  );

  /// Elapsed days between [previousUtc] and [currentUtc], strictly clamped so a
  /// backwards system clock never creates negative intervals.
  static double safeElapsedDays(DateTime? previousUtc, DateTime currentUtc) {
    if (previousUtc == null) return 0.0;
    final diffMs =
        currentUtc.toUtc().millisecondsSinceEpoch -
        previousUtc.toUtc().millisecondsSinceEpoch;
    if (diffMs <= 0) return 0.0;
    return diffMs / Duration.millisecondsPerDay;
  }

  static bool _isUsDst(DateTime utc, int standardOffsetMinutes) {
    final year = utc.year;
    final start = _nthSundayUtc(year, 3, 2, 2 - (standardOffsetMinutes ~/ 60));
    final end = _nthSundayUtc(year, 11, 1, 1 - (standardOffsetMinutes ~/ 60));
    return !utc.isBefore(start) && utc.isBefore(end);
  }

  static bool _isEuDst(DateTime utc) {
    final year = utc.year;
    final start = _lastSundayUtc(year, 3, 1);
    final end = _lastSundayUtc(year, 10, 1);
    return !utc.isBefore(start) && utc.isBefore(end);
  }

  static DateTime _nthSundayUtc(int year, int month, int nth, int utcHour) {
    var day = 1;
    var count = 0;
    while (day <= 31) {
      final candidate = DateTime.utc(year, month, day, utcHour);
      if (candidate.month != month) break;
      if (candidate.weekday == DateTime.sunday) {
        count++;
        if (count == nth) return candidate;
      }
      day++;
    }
    return DateTime.utc(year, month, 1, utcHour);
  }

  static DateTime _lastSundayUtc(int year, int month, int utcHour) {
    var day = 31;
    while (day >= 1) {
      final candidate = DateTime.utc(year, month, day, utcHour);
      if (candidate.month == month && candidate.weekday == DateTime.sunday) {
        return candidate;
      }
      day--;
    }
    return DateTime.utc(year, month, 28, utcHour);
  }
}
