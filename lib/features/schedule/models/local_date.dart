/// A calendar date without a time or zone.
///
/// Schedule dates are stored as `YYYY-MM-DD` and are never derived by
/// converting a UTC instant to local time. That keeps the date a user picked
/// on the calendar stable when the device zone changes.
class LocalDate implements Comparable<LocalDate> {
  LocalDate._(this.year, this.month, this.day);

  factory LocalDate(int year, int month, int day) {
    if (year < 1 || year > 9999) {
      throw ArgumentError.value(year, 'year', 'Expected 1...9999');
    }
    final value = DateTime(year, month, day);
    if (value.year != year || value.month != month || value.day != day) {
      throw ArgumentError('Not a calendar date: $year-$month-$day');
    }
    return LocalDate._(year, month, day);
  }

  factory LocalDate.fromDateTime(DateTime value) =>
      LocalDate(value.year, value.month, value.day);

  factory LocalDate.today([DateTime? now]) =>
      LocalDate.fromDateTime(now ?? DateTime.now());

  factory LocalDate.parse(String value) {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
    if (match == null) {
      throw FormatException('Expected YYYY-MM-DD', value);
    }
    return LocalDate(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }

  static LocalDate? tryParse(String value) {
    try {
      return LocalDate.parse(value);
    } catch (_) {
      return null;
    }
  }

  final int year;
  final int month;
  final int day;

  /// ISO weekday: Monday is 1 and Sunday is 7.
  int get weekday => _dateTime.weekday;

  String get weekdayLabel => const ['一', '二', '三', '四', '五', '六', '日'][weekday - 1];

  int get daysInMonth => DateTime(year, month + 1, 0).day;

  bool get isToday => this == LocalDate.today();

  DateTime get _dateTime => DateTime(year, month, day);

  DateTime toDateTime() => _dateTime;

  LocalDate addDays(int days) =>
      LocalDate.fromDateTime(_dateTime.add(Duration(days: days)));

  LocalDate get firstOfMonth => LocalDate(year, month, 1);

  LocalDate get lastOfMonth => LocalDate(year, month, daysInMonth);

  /// The first grid cell of a Monday-first month view.
  LocalDate get gridStart => firstOfMonth.addDays(1 - firstOfMonth.weekday);

  /// Always six weeks; a stable grid avoids the panel jumping between months.
  LocalDate get gridEnd => gridStart.addDays(41);

  /// Number of whole days from [other] to this date (this - other).
  int differenceInDays(LocalDate other) => _dateTime.difference(other._dateTime).inDays;

  String get iso =>
      '${year.toString().padLeft(4, '0')}-'
      '${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')}';

  String get monthLabel => '$year年$month月';

  String get shortLabel => '$month月$day日';

  String get longLabel => '$year年$month月$day日 周$weekdayLabel';

  @override
  int compareTo(LocalDate other) {
    if (year != other.year) return year.compareTo(other.year);
    if (month != other.month) return month.compareTo(other.month);
    return day.compareTo(other.day);
  }

  bool operator <(LocalDate other) => compareTo(other) < 0;

  bool operator <=(LocalDate other) => compareTo(other) <= 0;

  bool operator >(LocalDate other) => compareTo(other) > 0;

  bool operator >=(LocalDate other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is LocalDate &&
      year == other.year &&
      month == other.month &&
      day == other.day;

  @override
  int get hashCode => Object.hash(year, month, day);

  @override
  String toString() => iso;
}
