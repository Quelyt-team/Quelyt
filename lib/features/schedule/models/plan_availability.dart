import 'local_date.dart';
import 'schedule_time.dart';

/// One weekly availability window. [weekday] uses ISO numbering (Mon = 1).
class WeeklySlot {
  const WeeklySlot({
    required this.weekday,
    required this.startMinute,
    required this.endMinute,
  });

  final int weekday;
  final int startMinute;
  final int endMinute;

  TimeRange get range => TimeRange(startMinute, endMinute);

  bool get isValid => weekday >= 1 && weekday <= 7 && range.isValid;

  Map<String, dynamic> toJson() => {
    'weekday': weekday,
    'startMinute': startMinute,
    'endMinute': endMinute,
  };

  factory WeeklySlot.fromJson(Map<String, dynamic> json) => WeeklySlot(
    weekday: (json['weekday'] as num).toInt(),
    startMinute: (json['startMinute'] as num).toInt(),
    endMinute: (json['endMinute'] as num).toInt(),
  );
}

/// A single-date override. It wins over every weekly slot for that date.
class AvailabilityException {
  AvailabilityException({
    required this.date,
    required this.available,
    List<TimeRange> ranges = const [],
    this.note = '',
  }) : ranges = List.unmodifiable(ranges);

  final LocalDate date;
  final bool available;
  final List<TimeRange> ranges;
  final String note;

  bool get isRestDay => !available;

  Map<String, dynamic> toJson() => {
    'date': date.iso,
    'available': available,
    'ranges': [
      for (final range in ranges)
        {'startMinute': range.startMinute, 'endMinute': range.endMinute},
    ],
    'note': note,
  };

  factory AvailabilityException.fromJson(Map<String, dynamic> json) =>
      AvailabilityException(
        date: LocalDate.parse(json['date'] as String),
        available: json['available'] as bool,
        ranges: [
          for (final value in (json['ranges'] as List? ?? const []))
            TimeRange(
              (value['startMinute'] as num).toInt(),
              (value['endMinute'] as num).toInt(),
            ),
        ],
        note: json['note'] as String? ?? '',
      );
}

/// Availability and capacity rules for one plan.
///
/// A suggestion is offered in the editor, but it is not written to the
/// database until the user saves it. The scheduler treats an empty rule set as
/// "no capacity", never as "all day is free".
class PlanAvailability {
  PlanAvailability({
    required this.planId,
    List<WeeklySlot> weekly = const [],
    List<AvailabilityException> exceptions = const [],
    this.dailyCapMinutes = 120,
    this.bufferPercent = 15,
    this.maxStudyDaysPerWeek = 5,
    this.breakMinutes = 5,
    this.unitMinutes = 25,
  }) : weekly = List.unmodifiable(weekly),
       exceptions = List.unmodifiable(exceptions);

  final String planId;
  final List<WeeklySlot> weekly;
  final List<AvailabilityException> exceptions;

  /// Upper bound for study minutes on one date, after availability windows.
  final int dailyCapMinutes;

  /// Share of available time kept free for catch-up, 0–50%.
  final int bufferPercent;

  /// Maximum number of dates with study blocks in one ISO week.
  final int maxStudyDaysPerWeek;

  /// Gap inserted between two placed blocks in the same free window.
  final int breakMinutes;

  /// Preferred chunk size when a task may be split.
  final int unitMinutes;

  bool get isConfigured =>
      weekly.any((slot) => slot.isValid) ||
      exceptions.any((exception) => exception.available && exception.ranges.isNotEmpty);

  /// A clearly labeled starting point: weekday evenings only. The editor
  /// requires an explicit save, so this is never applied silently.
  factory PlanAvailability.suggestion(String planId) => PlanAvailability(
    planId: planId,
    weekly: const [
      WeeklySlot(weekday: 1, startMinute: 19 * 60 + 30, endMinute: 21 * 60),
      WeeklySlot(weekday: 2, startMinute: 19 * 60 + 30, endMinute: 21 * 60),
      WeeklySlot(weekday: 3, startMinute: 19 * 60 + 30, endMinute: 21 * 60),
      WeeklySlot(weekday: 4, startMinute: 19 * 60 + 30, endMinute: 21 * 60),
      WeeklySlot(weekday: 5, startMinute: 19 * 60 + 30, endMinute: 21 * 60),
    ],
  );

  PlanAvailability copyWith({
    String? planId,
    List<WeeklySlot>? weekly,
    List<AvailabilityException>? exceptions,
    int? dailyCapMinutes,
    int? bufferPercent,
    int? maxStudyDaysPerWeek,
    int? breakMinutes,
    int? unitMinutes,
  }) => PlanAvailability(
    planId: planId ?? this.planId,
    weekly: weekly ?? this.weekly,
    exceptions: exceptions ?? this.exceptions,
    dailyCapMinutes: dailyCapMinutes ?? this.dailyCapMinutes,
    bufferPercent: bufferPercent ?? this.bufferPercent,
    maxStudyDaysPerWeek: maxStudyDaysPerWeek ?? this.maxStudyDaysPerWeek,
    breakMinutes: breakMinutes ?? this.breakMinutes,
    unitMinutes: unitMinutes ?? this.unitMinutes,
  );

  /// The exception for [date] or null when the weekly rule applies.
  AvailabilityException? exceptionFor(LocalDate date) {
    for (final exception in exceptions) {
      if (exception.date == date) return exception;
    }
    return null;
  }

  /// Merged windows for [date]. A rest-day exception returns an empty list.
  List<TimeRange> rangesFor(LocalDate date) {
    final exception = exceptionFor(date);
    if (exception != null) {
      if (!exception.available) return const [];
      return mergeRanges(exception.ranges);
    }
    return mergeRanges(
      weekly
          .where((slot) => slot.weekday == date.weekday && slot.isValid)
          .map((slot) => slot.range),
    );
  }

  List<String> validate() {
    final problems = <String>[];
    if (dailyCapMinutes < 15 || dailyCapMinutes > 720) {
      problems.add('每日上限需在 15–720 分钟之间。');
    }
    if (bufferPercent < 0 || bufferPercent > 50) {
      problems.add('机动比例需在 0–50% 之间。');
    }
    if (maxStudyDaysPerWeek < 1 || maxStudyDaysPerWeek > 7) {
      problems.add('每周学习天数需在 1–7 之间。');
    }
    if (breakMinutes < 0 || breakMinutes > 30) {
      problems.add('块间休息需在 0–30 分钟之间。');
    }
    if (unitMinutes < 10 || unitMinutes > 120) {
      problems.add('学习单元需在 10–120 分钟之间。');
    }
    for (final slot in weekly) {
      if (!slot.isValid) problems.add('每周可用时间存在非法时段。');
    }
    for (final exception in exceptions) {
      if (exception.available &&
          (exception.ranges.isEmpty ||
              exception.ranges.any((range) => !range.isValid))) {
        problems.add('${exception.date.shortLabel} 的例外时间非法。');
      }
      if (exception.ranges.any((range) => !range.isValid)) {
        problems.add('${exception.date.shortLabel} 的例外时间非法。');
      }
    }
    return problems;
  }

  Map<String, dynamic> toJson() => {
    'planId': planId,
    'weekly': [for (final slot in weekly) slot.toJson()],
    'exceptions': [for (final exception in exceptions) exception.toJson()],
    'dailyCapMinutes': dailyCapMinutes,
    'bufferPercent': bufferPercent,
    'maxStudyDaysPerWeek': maxStudyDaysPerWeek,
    'breakMinutes': breakMinutes,
    'unitMinutes': unitMinutes,
  };

  factory PlanAvailability.fromJson(Map<String, dynamic> json) =>
      PlanAvailability(
        planId: json['planId'] as String,
        weekly: [
          for (final value in (json['weekly'] as List? ?? const []))
            WeeklySlot.fromJson(Map<String, dynamic>.from(value as Map)),
        ],
        exceptions: [
          for (final value in (json['exceptions'] as List? ?? const []))
            AvailabilityException.fromJson(
              Map<String, dynamic>.from(value as Map),
            ),
        ],
        dailyCapMinutes: (json['dailyCapMinutes'] as num?)?.toInt() ?? 120,
        bufferPercent: (json['bufferPercent'] as num?)?.toInt() ?? 15,
        maxStudyDaysPerWeek:
            (json['maxStudyDaysPerWeek'] as num?)?.toInt() ?? 5,
        breakMinutes: (json['breakMinutes'] as num?)?.toInt() ?? 5,
        unitMinutes: (json['unitMinutes'] as num?)?.toInt() ?? 25,
      );
}
