import 'calendar_block.dart';
import 'schedule_draft.dart';

/// One applied schedule change. Undo restores [beforeBlocks] and removes
/// [afterBlocks]; it never rewrites learning records.
class ScheduleRevision {
  ScheduleRevision({
    required this.id,
    required this.planId,
    required this.summary,
    required this.appliedAt,
    this.calendarRevision = 0,
    this.undoneAt,
    List<CalendarBlock> beforeBlocks = const [],
    List<CalendarBlock> afterBlocks = const [],
    List<UnplacedTask> unplaced = const [],
  }) : beforeBlocks = List.unmodifiable(beforeBlocks),
       afterBlocks = List.unmodifiable(afterBlocks),
       unplaced = List.unmodifiable(unplaced);

  final String id;
  final String planId;
  final String summary;
  final DateTime appliedAt;

  /// The global calendar revision this application produced. Any later edit
  /// makes undo unsafe, even when the affected blocks look untouched.
  final int calendarRevision;
  final DateTime? undoneAt;
  final List<CalendarBlock> beforeBlocks;
  final List<CalendarBlock> afterBlocks;
  final List<UnplacedTask> unplaced;

  bool get isUndone => undoneAt != null;

  Map<String, dynamic> toJson() => {
    'id': id,
    'planId': planId,
    'summary': summary,
    'appliedAt': appliedAt.toIso8601String(),
    'calendarRevision': calendarRevision,
    'undoneAt': undoneAt?.toIso8601String(),
    'beforeBlocks': [for (final block in beforeBlocks) block.toJson()],
    'afterBlocks': [for (final block in afterBlocks) block.toJson()],
    'unplaced': [for (final task in unplaced) task.toJson()],
  };

  factory ScheduleRevision.fromJson(Map<String, dynamic> json) =>
      ScheduleRevision(
        id: json['id'] as String,
        planId: json['planId'] as String,
        summary: json['summary'] as String,
        appliedAt: DateTime.parse(json['appliedAt'] as String),
        calendarRevision: (json['calendarRevision'] as num?)?.toInt() ?? 0,
        undoneAt: json['undoneAt'] == null
            ? null
            : DateTime.parse(json['undoneAt'] as String),
        beforeBlocks: [
          for (final value in (json['beforeBlocks'] as List? ?? const []))
            CalendarBlock.fromJson(Map<String, dynamic>.from(value as Map)),
        ],
        afterBlocks: [
          for (final value in (json['afterBlocks'] as List? ?? const []))
            CalendarBlock.fromJson(Map<String, dynamic>.from(value as Map)),
        ],
        unplaced: [
          for (final value in (json['unplaced'] as List? ?? const []))
            UnplacedTask.fromJson(Map<String, dynamic>.from(value as Map)),
        ],
      );
}
