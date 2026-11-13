import 'local_date.dart';

enum PlanStatus { draft, active, paused, archived }

extension PlanStatusLabel on PlanStatus {
  String get label => switch (this) {
    PlanStatus.draft => '草案',
    PlanStatus.active => '进行中',
    PlanStatus.paused => '已暂停',
    PlanStatus.archived => '已归档',
  };
}

enum StudyMode { unknown, foundation, review }

extension StudyModeLabel on StudyMode {
  String get label => switch (this) {
    StudyMode.unknown => '暂不确定',
    StudyMode.foundation => '从头打基础',
    StudyMode.review => '复习提高',
  };
}

/// A study plan groups tasks, availability and an optional exam date.
///
/// The plan is independent from the blocks that carry its time. Moving a
/// block never changes the plan or a task identity.
class StudyPlan {
  StudyPlan({
    required this.id,
    required this.title,
    this.subject = '',
    required this.startDate,
    required this.endDate,
    this.examDate,
    this.examMinute,
    this.timezone = 'Asia/Shanghai',
    this.mode = StudyMode.unknown,
    this.goal = '',
    this.status = PlanStatus.active,
    this.revision = 1,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? createdAt ?? DateTime.now();

  final String id;
  final String title;
  final String subject;
  final LocalDate startDate;
  final LocalDate endDate;
  final LocalDate? examDate;
  final int? examMinute;
  final String timezone;
  final StudyMode mode;
  final String goal;
  final PlanStatus status;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isArchived => status == PlanStatus.archived;

  int? get daysUntilExam {
    final exam = examDate;
    if (exam == null) return null;
    return exam.differenceInDays(LocalDate.today());
  }

  String get rangeLabel =>
      '${startDate.shortLabel} – ${endDate.shortLabel}';

  StudyPlan copyWith({
    String? id,
    String? title,
    String? subject,
    LocalDate? startDate,
    LocalDate? endDate,
    LocalDate? examDate,
    bool clearExamDate = false,
    int? examMinute,
    bool clearExamMinute = false,
    String? timezone,
    StudyMode? mode,
    String? goal,
    PlanStatus? status,
    int? revision,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => StudyPlan(
    id: id ?? this.id,
    title: title ?? this.title,
    subject: subject ?? this.subject,
    startDate: startDate ?? this.startDate,
    endDate: endDate ?? this.endDate,
    examDate: clearExamDate ? null : examDate ?? this.examDate,
    examMinute: clearExamMinute ? null : examMinute ?? this.examMinute,
    timezone: timezone ?? this.timezone,
    mode: mode ?? this.mode,
    goal: goal ?? this.goal,
    status: status ?? this.status,
    revision: revision ?? this.revision,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'subject': subject,
    'startDate': startDate.iso,
    'endDate': endDate.iso,
    'examDate': examDate?.iso,
    'examMinute': examMinute,
    'timezone': timezone,
    'mode': mode.name,
    'goal': goal,
    'status': status.name,
    'revision': revision,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory StudyPlan.fromJson(Map<String, dynamic> json) => StudyPlan(
    id: json['id'] as String,
    title: json['title'] as String,
    subject: json['subject'] as String? ?? '',
    startDate: LocalDate.parse(json['startDate'] as String),
    endDate: LocalDate.parse(json['endDate'] as String),
    examDate: json['examDate'] == null
        ? null
        : LocalDate.parse(json['examDate'] as String),
    examMinute: (json['examMinute'] as num?)?.toInt(),
    timezone: json['timezone'] as String? ?? 'Asia/Shanghai',
    mode: StudyMode.values.byName(json['mode'] as String? ?? 'unknown'),
    goal: json['goal'] as String? ?? '',
    status: PlanStatus.values.byName(json['status'] as String? ?? 'active'),
    revision: (json['revision'] as num?)?.toInt() ?? 1,
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );

  /// The last day the scheduler may place work. The exam day itself is left
  /// alone unless the user explicitly edits it.
  LocalDate get schedulingEnd {
    final exam = examDate;
    if (exam == null) return endDate;
    final beforeExam = exam.addDays(-1);
    return beforeExam < endDate ? beforeExam : endDate;
  }
}
