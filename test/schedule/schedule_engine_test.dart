import 'package:flutter_test/flutter_test.dart';

import 'package:local_study/features/schedule/domain/schedule_engine.dart';
import 'package:local_study/features/schedule/models/calendar_block.dart';
import 'package:local_study/features/schedule/models/local_date.dart';
import 'package:local_study/features/schedule/models/plan_availability.dart';
import 'package:local_study/features/schedule/models/schedule_time.dart';
import 'package:local_study/features/schedule/models/study_task.dart';

StudyTask _task(
  String id,
  int minutes, {
  int priority = 1,
  bool splittable = true,
}) => StudyTask(
  id: id,
  title: id,
  minutes: minutes,
  priority: priority,
  splittable: splittable,
  minChunkMinutes: 10,
);

PlanAvailability _availability({
  List<WeeklySlot>? weekly,
  List<AvailabilityException> exceptions = const [],
  int dailyCap = 120,
  int buffer = 0,
  int maxDays = 7,
  int breakMinutes = 5,
  int unit = 25,
}) => PlanAvailability(
  planId: 'plan',
  weekly:
      weekly ??
      [
        for (var weekday = 1; weekday <= 5; weekday++)
          WeeklySlot(
            weekday: weekday,
            startMinute: 19 * 60 + 30,
            endMinute: 21 * 60,
          ),
      ],
  exceptions: exceptions,
  dailyCapMinutes: dailyCap,
  bufferPercent: buffer,
  maxStudyDaysPerWeek: maxDays,
  breakMinutes: breakMinutes,
  unitMinutes: unit,
);

ScheduleRequest _request({
  required LocalDate start,
  required LocalDate end,
  required PlanAvailability availability,
  required List<StudyTask> tasks,
  List<CalendarBlock> occupied = const [],
  LocalDate? examDate,
  DateTime? now,
}) => ScheduleRequest(
  planId: 'plan',
  availability: availability,
  rangeStart: start,
  rangeEnd: end,
  tasks: [
    for (var index = 0; index < tasks.length; index++)
      TaskWork(task: tasks[index], remainingMinutes: tasks[index].minutes, order: index),
  ],
  occupied: occupied,
  examDate: examDate,
  now: now,
);

void _expectNoOverlap(List<PlannedStudyBlock> blocks) {
  final byDate = <LocalDate, List<PlannedStudyBlock>>{};
  for (final block in blocks) {
    byDate.putIfAbsent(block.date, () => []).add(block);
  }
  for (final day in byDate.values) {
    day.sort((a, b) => a.startMinute.compareTo(b.startMinute));
    for (var index = 1; index < day.length; index++) {
      expect(
        day[index].startMinute,
        greaterThanOrEqualTo(day[index - 1].endMinute),
        reason: 'Blocks on ${day[index].date} overlap',
      );
    }
  }
}

void main() {
  test('deterministic placement never uses weekends, exam day or overlaps', () {
    final start = LocalDate(2026, 11, 7);
    final end = LocalDate(2026, 11, 20);
    final availability = _availability();
    ScheduleRequest request() => _request(
      start: start,
      end: end,
      availability: availability,
      tasks: [_task('algebra', 90), _task('geometry', 60, priority: 2)],
      examDate: LocalDate(2026, 11, 13),
    );
    final first = ScheduleEngine.plan(request());
    final second = ScheduleEngine.plan(request());
    expect(first.scheduledMinutes, greaterThan(0));
    expect(
      first.blocks.map((block) => '${block.date} ${block.startMinute}-${block.endMinute}').toList(),
      second.blocks.map((block) => '${block.date} ${block.startMinute}-${block.endMinute}').toList(),
    );
    expect(
      first.blocks.any((block) => block.date == LocalDate(2026, 11, 13)),
      isFalse,
      reason: 'exam day must stay free',
    );
    for (final block in first.blocks) {
      expect(block.date.weekday, inInclusiveRange(1, 5));
      expect(block.startMinute, greaterThanOrEqualTo(19 * 60 + 30));
      expect(block.endMinute, lessThanOrEqualTo(21 * 60));
    }
    _expectNoOverlap(first.blocks);
    expect(first.unplaced, isEmpty);
  });

  test('other plans and fixed busy blocks reduce the free windows', () {
    final date = LocalDate(2026, 11, 9);
    final busy = CalendarBlock(
      id: 'busy',
      title: '英语课',
      planId: 'other-plan',
      date: date,
      startMinute: 20 * 60,
      endMinute: 20 * 60 + 30,
      kind: BlockKind.busy,
      locked: true,
    );
    final outcome = ScheduleEngine.plan(
      _request(
        start: date,
        end: date,
        availability: _availability(),
        tasks: [_task('math', 25)],
        occupied: [busy],
      ),
    );
    expect(outcome.blocks, hasLength(1));
    final block = outcome.blocks.single;
    expect(block.startMinute, 19 * 60 + 30);
    expect(block.endMinute, 19 * 60 + 55);
    expect(
      TimeRange(block.startMinute, block.endMinute).overlaps(
        TimeRange(20 * 60, 20 * 60 + 30),
      ),
      isFalse,
    );
  });

  test('capacity shortfall is reported instead of hiding work', () {
    final start = LocalDate(2030, 1, 7);
    final end = LocalDate(2030, 1, 11);
    final outcome = ScheduleEngine.plan(
      _request(
        start: start,
        end: end,
        availability: _availability(buffer: 15),
        tasks: [_task('whole-book', 600, splittable: true)],
      ),
    );
    expect(outcome.availableMinutes, 5 * 90);
    expect(outcome.effectiveMinutes, 5 * 76);
    expect(outcome.scheduledMinutes, lessThanOrEqualTo(outcome.effectiveMinutes));
    expect(outcome.unplaced.single.remainingMinutes, 600 - outcome.scheduledMinutes);
    expect(outcome.unplaced.single.reason, contains('可用时间不足'));
    expect(outcome.warnings.join(), contains('未能排入'));
    _expectNoOverlap(outcome.blocks);
  });

  test('weekly study-day limit is a hard constraint', () {
    final start = LocalDate(2026, 11, 9);
    final end = LocalDate(2026, 11, 15);
    final allWeek = [
      for (var weekday = 1; weekday <= 7; weekday++)
        WeeklySlot(
          weekday: weekday,
          startMinute: 19 * 60 + 30,
          endMinute: 21 * 60,
        ),
    ];
    final outcome = ScheduleEngine.plan(
      _request(
        start: start,
        end: end,
        availability: _availability(weekly: allWeek, maxDays: 3, dailyCap: 90),
        tasks: [_task('a', 60), _task('b', 60), _task('c', 60)],
      ),
    );
    expect(outcome.blocks.map((block) => block.date).toSet(), hasLength(3));
    expect(outcome.unplaced, isEmpty);
  });

  test('a rest-day exception removes that date from the plan', () {
    final rest = LocalDate(2026, 11, 10);
    final outcome = ScheduleEngine.plan(
      _request(
        start: LocalDate(2026, 11, 9),
        end: LocalDate(2026, 11, 11),
        availability: _availability(
          exceptions: [
            AvailabilityException(date: rest, available: false, note: '休息'),
          ],
        ),
        tasks: [_task('math', 120)],
      ),
    );
    expect(outcome.blocks.any((block) => block.date == rest), isFalse);
    expect(outcome.availableMinutes, 2 * 90);
  });

  test('non-splittable tasks are never cut to fill a smaller gap', () {
    final date = LocalDate(2026, 11, 9);
    final busy = CalendarBlock(
      id: 'busy',
      title: '占用',
      date: date,
      startMinute: 20 * 60,
      endMinute: 21 * 60,
      kind: BlockKind.busy,
    );
    final outcome = ScheduleEngine.plan(
      _request(
        start: date,
        end: date,
        availability: _availability(),
        tasks: [_task('mock-exam', 60, splittable: false)],
        occupied: [busy],
      ),
    );
    expect(outcome.blocks, isEmpty);
    expect(outcome.unplaced.single.remainingMinutes, 60);
  });

  test('today never schedules a block that already started', () {
    final date = LocalDate(2026, 11, 9);
    final outcome = ScheduleEngine.plan(
      _request(
        start: date,
        end: date,
        availability: _availability(unit: 45),
        tasks: [_task('math', 45)],
        now: DateTime(2026, 11, 9, 20, 10),
      ),
    );
    expect(outcome.blocks, hasLength(1));
    expect(outcome.blocks.single.startMinute, 20 * 60 + 10);
    expect(outcome.blocks.single.endMinute, 20 * 60 + 55);
    expect(outcome.assumptions.join(), contains('今天只使用当前时间之后'));
  });
}
