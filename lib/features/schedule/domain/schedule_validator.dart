import '../models/calendar_block.dart';
import '../models/local_date.dart';
import '../models/study_task.dart';

class ScheduleValidationException implements Exception {
  ScheduleValidationException(this.message, {this.conflicts = const []});

  final String message;
  final List<ScheduleConflict> conflicts;

  @override
  String toString() => message;
}

class ScheduleConflict {
  const ScheduleConflict({
    required this.date,
    required this.candidate,
    required this.existing,
    required this.existingTitle,
  });

  final LocalDate date;
  final CalendarBlock candidate;
  final CalendarBlock existing;
  final String existingTitle;

  String describe() =>
      '${date.shortLabel} ${existing.timeLabel} 已有「$existingTitle」';
}

/// Pure rules shared by the editor, repository and scheduler.
abstract final class ScheduleRules {
  static const int maxRepeatDays = 366;

  /// Expands a weekly rule into concrete dates.
  ///
  /// The first and last dates are inclusive. A range longer than [maxRepeatDays]
  /// is rejected instead of being silently truncated.
  static List<LocalDate> expandWeekly({
    required LocalDate start,
    required LocalDate end,
    required Iterable<int> weekdays,
  }) {
    if (end < start) {
      throw ScheduleValidationException('重复安排的结束日期不能早于开始日期。');
    }
    final selected = weekdays.toSet();
    if (selected.isEmpty) {
      throw ScheduleValidationException('请至少选择一个星期。');
    }
    if (selected.any((weekday) => weekday < 1 || weekday > 7)) {
      throw ScheduleValidationException('重复安排的星期不合法。');
    }
    final span = end.differenceInDays(start) + 1;
    if (span > maxRepeatDays) {
      throw ScheduleValidationException(
        '一次最多展开 $maxRepeatDays 天。请分段建立这次重复安排。',
      );
    }
    final dates = <LocalDate>[];
    for (var offset = 0; offset < span; offset++) {
      final date = start.addDays(offset);
      if (selected.contains(date.weekday)) dates.add(date);
    }
    if (dates.isEmpty) {
      throw ScheduleValidationException('当前日期范围内没有匹配的星期。');
    }
    return dates;
  }

  static String instanceKey(String seriesId, LocalDate date, int index) =>
      '$seriesId|${date.iso}|$index';

  /// Validates a task and the block that carries it. [block] may be a template
  /// whose id is not yet final.
  static void validateManual({
    required StudyTask task,
    required CalendarBlock block,
  }) {
    if (task.title.trim().isEmpty) {
      throw ScheduleValidationException('任务标题不能为空。');
    }
    if (block.endMinute <= block.startMinute) {
      throw ScheduleValidationException('结束时间必须晚于开始时间。');
    }
    if (block.startMinute < 0 || block.endMinute > 24 * 60) {
      throw ScheduleValidationException('时间必须落在同一天内。');
    }
    if (block.endMinute - block.startMinute != task.minutes) {
      throw ScheduleValidationException('任务时长与时间块的起止时间不一致。');
    }
    if (block.minutes < 5) {
      throw ScheduleValidationException('每个学习块至少 5 分钟。');
    }
  }

  static List<ScheduleConflict> findConflicts({
    required Iterable<CalendarBlock> candidates,
    required Iterable<CalendarBlock> existing,
    Set<String> excludeIds = const {},
  }) {
    final conflicts = <ScheduleConflict>[];
    final candidateList = candidates.toList();
    final existingList = existing
        .where(
          (block) =>
              !excludeIds.contains(block.id) &&
              block.state != BlockState.cancelled &&
              block.state != BlockState.skipped,
        )
        .toList();
    for (var i = 0; i < candidateList.length; i++) {
      final candidate = candidateList[i];
      for (final block in existingList) {
        if (block.date != candidate.date) continue;
        if (!block.timeRange.overlaps(candidate.timeRange)) continue;
        conflicts.add(
          ScheduleConflict(
            date: candidate.date,
            candidate: candidate,
            existing: block,
            existingTitle: block.title.isEmpty ? '另一项安排' : block.title,
          ),
        );
      }
      for (var j = i + 1; j < candidateList.length; j++) {
        final other = candidateList[j];
        if (other.date != candidate.date) continue;
        if (!other.timeRange.overlaps(candidate.timeRange)) continue;
        conflicts.add(
          ScheduleConflict(
            date: candidate.date,
            candidate: candidate,
            existing: other,
            existingTitle: other.title.isEmpty ? '本次重复安排' : other.title,
          ),
        );
      }
    }
    return conflicts;
  }

  static void requireNoConflicts(List<ScheduleConflict> conflicts) {
    if (conflicts.isEmpty) return;
    final shown = conflicts.take(3).map((conflict) => conflict.describe());
    final rest = conflicts.length - 3;
    throw ScheduleValidationException(
      '时间冲突：${shown.join('；')}${rest > 0 ? '；另有 $rest 处' : ''}。请先调整时间。',
      conflicts: conflicts,
    );
  }
}
