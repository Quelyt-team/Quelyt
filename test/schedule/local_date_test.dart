import 'package:flutter_test/flutter_test.dart';

import 'package:local_study/features/schedule/domain/schedule_validator.dart';
import 'package:local_study/features/schedule/models/calendar_block.dart';
import 'package:local_study/features/schedule/models/local_date.dart';
import 'package:local_study/features/schedule/models/schedule_time.dart';

void main() {
  test('LocalDate rejects impossible dates and keeps leap day', () {
    expect(() => LocalDate(2026, 2, 30), throwsArgumentError);
    expect(() => LocalDate(2026, 13, 1), throwsArgumentError);
    expect(LocalDate(2024, 2, 29).iso, '2024-02-29');
    expect(LocalDate.parse('2026-11-07').weekday, 6);
    expect(LocalDate.parse('2026-11-07').weekdayLabel, '六');
    expect(LocalDate.parse('2026-11-07').gridStart.iso, '2026-10-26');
    expect(LocalDate(2026, 12, 31).addDays(1).iso, '2027-01-01');
    expect(LocalDate(2026, 11, 7).differenceInDays(LocalDate(2026, 11, 1)), 6);
  });

  test('minute helpers format and reject invalid wall-clock values', () {
    expect(formatMinuteOfDay(19 * 60 + 30), '19:30');
    expect(parseMinuteOfDay('7:05'), 425);
    expect(parseMinuteOfDay('24:00'), 1440);
    expect(() => parseMinuteOfDay('24:01'), throwsFormatException);
    expect(() => formatMinuteOfDay(1441), throwsRangeError);
    expect(formatDuration(90), '1 小时 30 分钟');
    expect(subtractRanges(
      const TimeRange(0, 120),
      [const TimeRange(30, 60)],
    ), [const TimeRange(0, 30), const TimeRange(60, 120)]);
    expect(mergeRanges([
      const TimeRange(0, 30),
      const TimeRange(30, 60),
      const TimeRange(90, 120),
    ]), [const TimeRange(0, 60), const TimeRange(90, 120)]);
  });

  test('weekly expansion is inclusive and refuses silent truncation', () {
    final dates = ScheduleRules.expandWeekly(
      start: LocalDate(2026, 11, 9),
      end: LocalDate(2026, 11, 15),
      weekdays: [1, 3, 5],
    );
    expect(dates.map((date) => date.iso), [
      '2026-11-09',
      '2026-11-11',
      '2026-11-13',
    ]);
    expect(
      () => ScheduleRules.expandWeekly(
        start: LocalDate(2026, 1, 1),
        end: LocalDate(2027, 6, 1),
        weekdays: [1],
      ),
      throwsA(isA<ScheduleValidationException>()),
    );
    expect(
      () => ScheduleRules.expandWeekly(
        start: LocalDate(2026, 11, 9),
        end: LocalDate(2026, 11, 15),
        weekdays: const [],
      ),
      throwsA(isA<ScheduleValidationException>()),
    );
  });

  test('conflict rules ignore cancelled blocks and report concrete times', () {
    CalendarBlock block(String id, String date, int start, int end, BlockState state) =>
        CalendarBlock(
          id: id,
          title: id,
          date: LocalDate.parse(date),
          startMinute: start,
          endMinute: end,
          state: state,
        );
    final candidate = block('candidate', '2026-11-09', 1200, 1260, BlockState.scheduled);
    final existing = [
      block('cancelled', '2026-11-09', 1200, 1260, BlockState.cancelled),
      block('live', '2026-11-09', 1230, 1290, BlockState.scheduled),
      block('other-day', '2026-11-10', 1200, 1260, BlockState.scheduled),
    ];
    final conflicts = ScheduleRules.findConflicts(
      candidates: [candidate],
      existing: existing,
    );
    expect(conflicts, hasLength(1));
    expect(conflicts.single.existingTitle, 'live');
    expect(conflicts.single.describe(), contains('20:30–21:30'));
  });
}
