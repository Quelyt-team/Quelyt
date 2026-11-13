import 'local_date.dart';
import 'schedule_time.dart';

enum BlockKind { study, busy, breakSlot }

extension BlockKindLabel on BlockKind {
  String get label => switch (this) {
    BlockKind.study => '学习',
    BlockKind.busy => '占用',
    BlockKind.breakSlot => '休息',
  };
}

enum BlockState { scheduled, inProgress, completed, skipped, cancelled }

extension BlockStateLabel on BlockState {
  String get label => switch (this) {
    BlockState.scheduled => '未开始',
    BlockState.inProgress => '进行中',
    BlockState.completed => '已完成',
    BlockState.skipped => '已跳过',
    BlockState.cancelled => '已取消',
  };
}

/// The innermost occupied unit on the calendar.
///
/// Completed minutes are stored separately from planned minutes so a partial
/// session never rewrites what was originally planned.
class CalendarBlock {
  CalendarBlock({
    required this.id,
    this.title = '',
    this.taskId,
    this.planId,
    required this.date,
    required this.startMinute,
    required this.endMinute,
    this.kind = BlockKind.study,
    this.state = BlockState.scheduled,
    this.locked = false,
    this.seriesId,
    this.seriesEndDate,
    List<int> seriesWeekdays = const [],
    this.instanceKey,
    this.detached = false,
    this.completedMinutes = 0,
    this.completedAt,
    this.skippedReason = '',
    this.revision = 1,
    DateTime? updatedAt,
  }) : seriesWeekdays = List.unmodifiable(seriesWeekdays),
       updatedAt = updatedAt ?? DateTime.now() {
    if (id.isEmpty) throw ArgumentError('Block needs an id.');
    if (!TimeRange(startMinute, endMinute).isValid) {
      throw ArgumentError('Block needs a valid start and end time.');
    }
    if (completedMinutes < 0 || completedMinutes > minutes) {
      throw ArgumentError.value(
        completedMinutes,
        'completedMinutes',
        'Expected 0–$minutes',
      );
    }
  }

  final String id;
  final String title;
  final String? taskId;
  final String? planId;
  final LocalDate date;
  final int startMinute;
  final int endMinute;
  final BlockKind kind;
  final BlockState state;
  final bool locked;

  /// Non-null when this block belongs to a weekly series.
  final String? seriesId;
  final LocalDate? seriesEndDate;
  final List<int> seriesWeekdays;

  /// Stable identity of one series occurrence: `seriesId|original date|index`.
  final String? instanceKey;

  /// True when the user edited only this occurrence of a series. Later series
  /// edits must not rewrite it.
  final bool detached;

  final int completedMinutes;
  final DateTime? completedAt;
  final String skippedReason;
  final int revision;
  final DateTime updatedAt;

  int get minutes => endMinute - startMinute;

  TimeRange get timeRange => TimeRange(startMinute, endMinute);

  String get timeLabel => timeRange.label;

  bool get isStudy => kind == BlockKind.study;

  bool get isOpen =>
      state == BlockState.scheduled || state == BlockState.inProgress;

  bool get isFinished =>
      state == BlockState.completed ||
      state == BlockState.skipped ||
      state == BlockState.cancelled;

  bool get hasProgress => completedMinutes > 0;

  double get progress => minutes == 0 ? 0 : completedMinutes / minutes;

  /// Overdue is derived from the clock; it is never stored as a state.
  bool isOverdue(DateTime now) {
    if (!isOpen) return false;
    final end = DateTime(
      date.year,
      date.month,
      date.day,
    ).add(Duration(minutes: endMinute));
    return now.isAfter(end);
  }

  /// Automatic scheduling may only move untouched, unlocked, study blocks.
  bool get canAutoMove =>
      isStudy &&
      state == BlockState.scheduled &&
      !locked &&
      completedMinutes == 0;

  String displayTitle(StudyTaskTitleLookup tasks) {
    final taskTitle = taskId == null ? null : tasks(taskId!);
    final value = taskTitle ?? title;
    return value.isEmpty ? '未命名任务' : value;
  }

  CalendarBlock copyWith({
    String? id,
    String? title,
    String? taskId,
    bool clearTask = false,
    String? planId,
    bool clearPlan = false,
    LocalDate? date,
    int? startMinute,
    int? endMinute,
    BlockKind? kind,
    BlockState? state,
    bool? locked,
    String? seriesId,
    bool clearSeries = false,
    LocalDate? seriesEndDate,
    bool clearSeriesEnd = false,
    List<int>? seriesWeekdays,
    String? instanceKey,
    bool clearInstanceKey = false,
    bool? detached,
    int? completedMinutes,
    DateTime? completedAt,
    bool clearCompletedAt = false,
    String? skippedReason,
    int? revision,
    DateTime? updatedAt,
  }) => CalendarBlock(
    id: id ?? this.id,
    title: title ?? this.title,
    taskId: clearTask ? null : taskId ?? this.taskId,
    planId: clearPlan ? null : planId ?? this.planId,
    date: date ?? this.date,
    startMinute: startMinute ?? this.startMinute,
    endMinute: endMinute ?? this.endMinute,
    kind: kind ?? this.kind,
    state: state ?? this.state,
    locked: locked ?? this.locked,
    seriesId: clearSeries ? null : seriesId ?? this.seriesId,
    seriesEndDate: clearSeriesEnd
        ? null
        : seriesEndDate ?? this.seriesEndDate,
    seriesWeekdays: seriesWeekdays ?? this.seriesWeekdays,
    instanceKey: clearInstanceKey ? null : instanceKey ?? this.instanceKey,
    detached: detached ?? this.detached,
    completedMinutes: completedMinutes ?? this.completedMinutes,
    completedAt: clearCompletedAt ? null : completedAt ?? this.completedAt,
    skippedReason: skippedReason ?? this.skippedReason,
    revision: revision ?? this.revision,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'taskId': taskId,
    'planId': planId,
    'date': date.iso,
    'startMinute': startMinute,
    'endMinute': endMinute,
    'kind': kind.name,
    'state': state.name,
    'locked': locked,
    'seriesId': seriesId,
    'seriesEndDate': seriesEndDate?.iso,
    'seriesWeekdays': seriesWeekdays,
    'instanceKey': instanceKey,
    'detached': detached,
    'completedMinutes': completedMinutes,
    'completedAt': completedAt?.toIso8601String(),
    'skippedReason': skippedReason,
    'revision': revision,
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory CalendarBlock.fromJson(Map<String, dynamic> json) => CalendarBlock(
    id: json['id'] as String,
    title: json['title'] as String? ?? '',
    taskId: json['taskId'] as String?,
    planId: json['planId'] as String?,
    date: LocalDate.parse(json['date'] as String),
    startMinute: (json['startMinute'] as num).toInt(),
    endMinute: (json['endMinute'] as num).toInt(),
    kind: BlockKind.values.byName(json['kind'] as String? ?? 'study'),
    state: BlockState.values.byName(json['state'] as String? ?? 'scheduled'),
    locked: json['locked'] as bool? ?? false,
    seriesId: json['seriesId'] as String?,
    seriesEndDate: json['seriesEndDate'] == null
        ? null
        : LocalDate.parse(json['seriesEndDate'] as String),
    seriesWeekdays: [
      for (final value in (json['seriesWeekdays'] as List? ?? const []))
        (value as num).toInt(),
    ],
    instanceKey: json['instanceKey'] as String?,
    detached: json['detached'] as bool? ?? false,
    completedMinutes: (json['completedMinutes'] as num?)?.toInt() ?? 0,
    completedAt: json['completedAt'] == null
        ? null
        : DateTime.parse(json['completedAt'] as String),
    skippedReason: json['skippedReason'] as String? ?? '',
    revision: (json['revision'] as num?)?.toInt() ?? 1,
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );
}

typedef StudyTaskTitleLookup = String? Function(String taskId);
