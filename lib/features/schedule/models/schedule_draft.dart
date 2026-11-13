import 'calendar_block.dart';
import 'local_date.dart';

class UnplacedTask {
  const UnplacedTask({
    required this.taskId,
    required this.title,
    required this.remainingMinutes,
    required this.reason,
  });

  final String taskId;
  final String title;
  final int remainingMinutes;
  final String reason;

  Map<String, dynamic> toJson() => {
    'taskId': taskId,
    'title': title,
    'remainingMinutes': remainingMinutes,
    'reason': reason,
  };

  factory UnplacedTask.fromJson(Map<String, dynamic> json) => UnplacedTask(
    taskId: json['taskId'] as String,
    title: json['title'] as String,
    remainingMinutes: (json['remainingMinutes'] as num).toInt(),
    reason: json['reason'] as String,
  );
}

/// A proposed schedule that has not touched the formal calendar yet.
///
/// The preview shows added and removed blocks, capacity, unplaced work and
/// every assumption. Only [ScheduleDraft] application writes to the database.
class ScheduleDraft {
  ScheduleDraft({
    required this.planId,
    required this.planTitle,
    required this.baseRevision,
    required this.rangeStart,
    required this.rangeEnd,
    required this.generatedAt,
    List<CalendarBlock> addedBlocks = const [],
    List<CalendarBlock> removedBlocks = const [],
    List<UnplacedTask> unplaced = const [],
    this.availableMinutes = 0,
    this.effectiveMinutes = 0,
    this.scheduledMinutes = 0,
    this.breakMinutes = 0,
    this.bufferMinutes = 0,
    List<String> warnings = const [],
    List<String> assumptions = const [],
  }) : addedBlocks = List.unmodifiable(addedBlocks),
       removedBlocks = List.unmodifiable(removedBlocks),
       unplaced = List.unmodifiable(unplaced),
       warnings = List.unmodifiable(warnings),
       assumptions = List.unmodifiable(assumptions);

  final String planId;
  final String planTitle;
  final int baseRevision;
  final LocalDate rangeStart;
  final LocalDate rangeEnd;
  final DateTime generatedAt;
  final List<CalendarBlock> addedBlocks;
  final List<CalendarBlock> removedBlocks;
  final List<UnplacedTask> unplaced;

  /// Total minutes offered by availability rules in the range.
  final int availableMinutes;

  /// Availability minus breaks and the reserved buffer.
  final int effectiveMinutes;
  final int scheduledMinutes;
  final int breakMinutes;
  final int bufferMinutes;
  final List<String> warnings;

  /// Visible assumptions, for example that weekends were never opened.
  final List<String> assumptions;

  bool get isEmpty => addedBlocks.isEmpty && removedBlocks.isEmpty;

  bool get hasUnplaced => unplaced.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'planId': planId,
    'planTitle': planTitle,
    'baseRevision': baseRevision,
    'rangeStart': rangeStart.iso,
    'rangeEnd': rangeEnd.iso,
    'generatedAt': generatedAt.toIso8601String(),
    'addedBlocks': [for (final block in addedBlocks) block.toJson()],
    'removedBlocks': [for (final block in removedBlocks) block.toJson()],
    'unplaced': [for (final task in unplaced) task.toJson()],
    'availableMinutes': availableMinutes,
    'effectiveMinutes': effectiveMinutes,
    'scheduledMinutes': scheduledMinutes,
    'breakMinutes': breakMinutes,
    'bufferMinutes': bufferMinutes,
    'warnings': warnings,
    'assumptions': assumptions,
  };

  factory ScheduleDraft.fromJson(Map<String, dynamic> json) => ScheduleDraft(
    planId: json['planId'] as String,
    planTitle: json['planTitle'] as String,
    baseRevision: (json['baseRevision'] as num).toInt(),
    rangeStart: LocalDate.parse(json['rangeStart'] as String),
    rangeEnd: LocalDate.parse(json['rangeEnd'] as String),
    generatedAt: DateTime.parse(json['generatedAt'] as String),
    addedBlocks: [
      for (final value in (json['addedBlocks'] as List? ?? const []))
        CalendarBlock.fromJson(Map<String, dynamic>.from(value as Map)),
    ],
    removedBlocks: [
      for (final value in (json['removedBlocks'] as List? ?? const []))
        CalendarBlock.fromJson(Map<String, dynamic>.from(value as Map)),
    ],
    unplaced: [
      for (final value in (json['unplaced'] as List? ?? const []))
        UnplacedTask.fromJson(Map<String, dynamic>.from(value as Map)),
    ],
    availableMinutes: (json['availableMinutes'] as num?)?.toInt() ?? 0,
    effectiveMinutes: (json['effectiveMinutes'] as num?)?.toInt() ?? 0,
    scheduledMinutes: (json['scheduledMinutes'] as num?)?.toInt() ?? 0,
    breakMinutes: (json['breakMinutes'] as num?)?.toInt() ?? 0,
    bufferMinutes: (json['bufferMinutes'] as num?)?.toInt() ?? 0,
    warnings: [
      for (final value in (json['warnings'] as List? ?? const []))
        value as String,
    ],
    assumptions: [
      for (final value in (json['assumptions'] as List? ?? const []))
        value as String,
    ],
  );
}
