import '../models/calendar_block.dart';
import '../models/local_date.dart';
import '../models/plan_availability.dart';
import '../models/schedule_draft.dart';
import '../models/schedule_time.dart';
import '../models/study_task.dart';

/// One task that still needs time. A partially completed task contributes only
/// its remaining minutes.
class TaskWork {
  const TaskWork({
    required this.task,
    required this.remainingMinutes,
    required this.order,
  });

  final StudyTask task;
  final int remainingMinutes;
  final int order;
}

class ScheduleRequest {
  ScheduleRequest({
    required this.planId,
    required this.availability,
    required this.rangeStart,
    required this.rangeEnd,
    required this.tasks,
    List<CalendarBlock> occupied = const [],
    Set<String> replaceBlockIds = const {},
    this.examDate,
    DateTime? now,
  }) : occupied = List.unmodifiable(occupied),
       replaceBlockIds = Set.unmodifiable(replaceBlockIds),
       now = now ?? DateTime.now();

  final String planId;
  final PlanAvailability availability;
  final LocalDate rangeStart;
  final LocalDate rangeEnd;
  final LocalDate? examDate;
  final List<TaskWork> tasks;

  /// Blocks from every plan that already occupy time, plus this plan's locked
  /// or already-started blocks. Blocks being replaced are not included.
  final List<CalendarBlock> occupied;
  final Set<String> replaceBlockIds;
  final DateTime now;
}

class PlannedStudyBlock {
  const PlannedStudyBlock({
    required this.taskId,
    required this.title,
    required this.date,
    required this.startMinute,
    required this.endMinute,
    required this.chunkIndex,
    required this.planId,
  });

  final String taskId;
  final String title;
  final LocalDate date;
  final int startMinute;
  final int endMinute;
  final int chunkIndex;
  final String planId;

  int get minutes => endMinute - startMinute;
}

class ScheduleOutcome {
  ScheduleOutcome({
    required this.blocks,
    required this.unplaced,
    required this.availableMinutes,
    required this.effectiveMinutes,
    required this.scheduledMinutes,
    required this.breakMinutes,
    required this.bufferMinutes,
    required this.warnings,
    required this.assumptions,
  });

  final List<PlannedStudyBlock> blocks;
  final List<UnplacedTask> unplaced;
  final int availableMinutes;
  final int effectiveMinutes;
  final int scheduledMinutes;
  final int breakMinutes;
  final int bufferMinutes;
  final List<String> warnings;
  final List<String> assumptions;
}

/// Deterministic, offline placement of tasks into confirmed availability.
///
/// The engine never invents free time: it only uses [PlanAvailability] minus
/// occupied blocks. The same request always produces the same blocks.
abstract final class ScheduleEngine {
  static ScheduleOutcome plan(ScheduleRequest request) {
    final availability = request.availability;
    final occupied = request.occupied
        .where((block) => !request.replaceBlockIds.contains(block.id))
        .toList();
    final days = <_DayPlan>[];
    var examSkipped = false;

    for (
      var offset = 0;
      request.rangeStart.addDays(offset) <= request.rangeEnd;
      offset++
    ) {
      final date = request.rangeStart.addDays(offset);
      if (request.examDate == date) {
        examSkipped = true;
        continue;
      }
      var windows = availability.rangesFor(date);
      if (windows.isEmpty) continue;
      if (date == LocalDate.fromDateTime(request.now)) {
        final currentMinute =
            request.now.hour * 60 +
            request.now.minute +
            (request.now.second > 0 || request.now.millisecond > 0 ? 1 : 0);
        if (currentMinute >= minutesPerDay) continue;
        final remaining = TimeRange(currentMinute, minutesPerDay);
        windows = [
          for (final window in windows) ?window.intersection(remaining),
        ];
        if (windows.isEmpty) continue;
      }
      final busy = mergeRanges(
        occupied
            .where(
              (block) =>
                  block.date == date &&
                  block.state != BlockState.cancelled &&
                  block.state != BlockState.skipped,
            )
            .map((block) => block.timeRange),
      );
      final free = <TimeRange>[];
      for (final window in windows) {
        free.addAll(subtractRanges(window, busy));
      }
      final merged = mergeRanges(free);
      if (merged.isEmpty) continue;
      final windowMinutes = merged.fold<int>(
        0,
        (sum, range) => sum + range.minutes,
      );
      final capped = windowMinutes < availability.dailyCapMinutes
          ? windowMinutes
          : availability.dailyCapMinutes;
      final usable =
          (capped * (100 - availability.bufferPercent) / 100).floor();
      if (usable < 5) continue;
      days.add(
        _DayPlan(
          date: date,
          free: merged,
          capacity: usable,
          availableMinutes: windowMinutes,
        ),
      );
    }

    _applyWeeklyDayLimit(days, occupied, request);

    final available = days.fold<int>(
      0,
      (sum, day) => sum + day.availableMinutes,
    );
    final effective = days.fold<int>(
      0,
      (sum, day) => sum + day.capacity,
    );

    final tasks = [...request.tasks]
      ..sort((a, b) {
        final priority = b.task.priority.compareTo(a.task.priority);
        if (priority != 0) return priority;
        final order = a.order.compareTo(b.order);
        if (order != 0) return order;
        return a.task.id.compareTo(b.task.id);
      });

    final blocks = <PlannedStudyBlock>[];
    final unplaced = <UnplacedTask>[];
    var breakMinutes = 0;

    for (final work in tasks) {
      if (work.remainingMinutes <= 0) continue;
      final chunks = _chunks(work, availability.unitMinutes);
      var chunkIndex = 0;
      for (final chunk in chunks) {
        final placement = _place(days, chunk, work.task.id, availability);
        if (placement == null) {
          final remaining = chunks
              .skip(chunkIndex)
              .fold<int>(0, (sum, value) => sum + value);
          unplaced.add(
            UnplacedTask(
              taskId: work.task.id,
              title: work.task.title,
              remainingMinutes: remaining,
              reason: available == 0
                  ? '可用时间内没有空档'
                  : '可用时间不足，还差 $remaining 分钟',
            ),
          );
          break;
        }
        breakMinutes += placement.breakUsed;
        blocks.add(
          PlannedStudyBlock(
            taskId: work.task.id,
            title: work.task.title,
            date: placement.day.date,
            startMinute: placement.startMinute,
            endMinute: placement.endMinute,
            chunkIndex: chunkIndex,
            planId: request.planId,
          ),
        );
        chunkIndex++;
      }
      if (chunks.isEmpty && work.remainingMinutes > 0) {
        unplaced.add(
          UnplacedTask(
            taskId: work.task.id,
            title: work.task.title,
            remainingMinutes: work.remainingMinutes,
            reason: '任务时长不合法，无法排入',
          ),
        );
      }
    }

    blocks.sort((a, b) {
      final date = a.date.compareTo(b.date);
      if (date != 0) return date;
      final start = a.startMinute.compareTo(b.startMinute);
      if (start != 0) return start;
      return a.taskId.compareTo(b.taskId);
    });

    final scheduled = blocks.fold<int>(
      0,
      (sum, block) => sum + block.minutes,
    );
    final warnings = <String>[];
    if (examSkipped) {
      warnings.add('考试当天没有自动安排学习任务。');
    }
    final unplacedMinutes = unplaced.fold<int>(
      0,
      (sum, task) => sum + task.remainingMinutes,
    );
    if (unplacedMinutes > 0) {
      warnings.add('还有 $unplacedMinutes 分钟未能排入，请增加可用时间、减少范围或分段建立。');
    }
    if (blocks.isEmpty && tasks.isNotEmpty && unplacedMinutes == 0) {
      warnings.add('没有可排入的学习任务。');
    }

    final assumptions = <String>[
      '只使用已保存的每周可用时间与单日例外，没有自动增加周末。',
      '已扣除其他计划的占用、本计划锁定块和已开始块。',
      '每天上限 ${availability.dailyCapMinutes} 分钟，机动 ${availability.bufferPercent}%。',
      if (request.rangeStart == LocalDate.fromDateTime(request.now))
        '今天只使用当前时间之后的空档。',
    ];
    if (!availability.weekly.any((slot) => slot.isValid)) {
      assumptions.add('当前只有单日例外，没有每周固定时间。');
    }

    return ScheduleOutcome(
      blocks: blocks,
      unplaced: List.unmodifiable(unplaced),
      availableMinutes: available,
      effectiveMinutes: effective,
      scheduledMinutes: scheduled,
      breakMinutes: breakMinutes,
      bufferMinutes: available - effective,
      warnings: List.unmodifiable(warnings),
      assumptions: List.unmodifiable(assumptions),
    );
  }

  static List<int> _chunks(TaskWork work, int unitMinutes) {
    final task = work.task;
    final remaining = work.remainingMinutes;
    if (remaining <= 0) return const [];
    if (!task.splittable) return [remaining];
    final chunks = <int>[];
    var left = remaining;
    var unit = unitMinutes;
    if (unit < 10) unit = 10;
    while (left > unit) {
      chunks.add(unit);
      left -= unit;
    }
    if (left > 0) {
      if (chunks.isNotEmpty && left < task.minChunkMinutes) {
        chunks[chunks.length - 1] += left;
      } else {
        chunks.add(left);
      }
    }
    return chunks;
  }

  static _Placement? _place(
    List<_DayPlan> days,
    int minutes,
    String taskId,
    PlanAvailability availability,
  ) {
    if (minutes < 5) return null;
    for (final day in days) {
      final breakCost = day.hasBlocks ? availability.breakMinutes : 0;
      if (day.studyMinutes + day.breakMinutes + breakCost + minutes >
          day.capacity) {
        continue;
      }
      for (var index = 0; index < day.free.length; index++) {
        final range = day.free[index];
        final start = day.cursor[index];
        final end = start + minutes;
        if (end > range.endMinute) continue;
        day.cursor[index] = end + availability.breakMinutes;
        day.studyMinutes += minutes;
        day.breakMinutes += breakCost;
        final breakUsed = breakCost;
        day.hasBlocks = true;
        return _Placement(
          day: day,
          startMinute: start,
          endMinute: end,
          breakUsed: breakUsed,
        );
      }
    }
    return null;
  }

  static void _applyWeeklyDayLimit(
    List<_DayPlan> days,
    List<CalendarBlock> occupied,
    ScheduleRequest request,
  ) {
    final used = <LocalDate, Set<LocalDate>>{};
    for (final block in occupied) {
      if (!block.isStudy || block.planId != request.planId) continue;
      if (block.state == BlockState.cancelled) continue;
      used.putIfAbsent(_mondayOf(block.date), () => <LocalDate>{}).add(block.date);
    }
    final limit = request.availability.maxStudyDaysPerWeek.clamp(1, 7);
    for (final day in days) {
      final week = _mondayOf(day.date);
      final set = used.putIfAbsent(week, () => <LocalDate>{});
      if (set.contains(day.date)) continue;
      if (set.length >= limit) {
        day.capacity = 0;
        day.free = const [];
        continue;
      }
      set.add(day.date);
    }
    days.removeWhere((day) => day.free.isEmpty || day.capacity < 5);
  }

  static LocalDate _mondayOf(LocalDate date) => date.addDays(1 - date.weekday);
}

class _DayPlan {
  _DayPlan({
    required this.date,
    required this.free,
    required this.capacity,
    required this.availableMinutes,
  }) : cursor = List<int>.generate(free.length, (index) => free[index].startMinute);

  final LocalDate date;
  List<TimeRange> free;
  int capacity;
  final int availableMinutes;
  final List<int> cursor;
  int studyMinutes = 0;
  int breakMinutes = 0;
  bool hasBlocks = false;
}

class _Placement {
  const _Placement({
    required this.day,
    required this.startMinute,
    required this.endMinute,
    required this.breakUsed,
  });

  final _DayPlan day;
  final int startMinute;
  final int endMinute;
  final int breakUsed;
}
