import 'material_ref.dart';

enum TaskActivity { learn, practice, review, quiz, correct, read, other }

extension TaskActivityLabel on TaskActivity {
  String get label => switch (this) {
    TaskActivity.learn => '新学',
    TaskActivity.practice => '练习',
    TaskActivity.review => '复习',
    TaskActivity.quiz => '测验',
    TaskActivity.correct => '订正',
    TaskActivity.read => '阅读',
    TaskActivity.other => '其他',
  };

  /// A short description of how this activity is taught.
  String get methodHint => switch (this) {
    TaskActivity.learn => '讲解概念与例题，再用变式练习',
    TaskActivity.practice => '先独立作答，再对照步骤与原因',
    TaskActivity.review => '合上资料回忆，再做旧题或复述',
    TaskActivity.quiz => '限时完成，保留真实作答与用时',
    TaskActivity.correct => '找出错因，回到对应原文再练',
    TaskActivity.read => '标出主张、证据与未解决的问题',
    TaskActivity.other => '按完成条件记录实际做了什么',
  };
}

enum TaskStatus { notStarted, inProgress, completed, blocked, skipped }

extension TaskStatusLabel on TaskStatus {
  String get label => switch (this) {
    TaskStatus.notStarted => '未开始',
    TaskStatus.inProgress => '进行中',
    TaskStatus.completed => '已完成',
    TaskStatus.blocked => '受阻',
    TaskStatus.skipped => '已跳过',
  };
}

/// A unit of study that is independent from the time it occupies.
///
/// One task may be split across multiple calendar blocks. Moving or splitting
/// the blocks never changes the task id.
class StudyTask {
  StudyTask({
    required this.id,
    required this.title,
    this.subject = '',
    this.planId,
    this.activity = TaskActivity.learn,
    required this.minutes,
    this.priority = 1,
    this.splittable = true,
    this.minChunkMinutes = 15,
    this.knowledge = '',
    this.completionCondition = '',
    this.notes = '',
    this.material,
    this.readerSessionBindings = const {},
    this.status = TaskStatus.notStarted,
    this.revision = 1,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? createdAt ?? DateTime.now() {
    if (id.isEmpty) throw ArgumentError('Task needs an id.');
    if (title.trim().isEmpty) throw ArgumentError('Task needs a title.');
    if (minutes < 5 || minutes > 600) {
      throw ArgumentError.value(minutes, 'minutes', 'Expected 5–600');
    }
    if (priority < 0 || priority > 2) {
      throw ArgumentError.value(priority, 'priority', 'Expected 0–2');
    }
    if (minChunkMinutes < 5 || minChunkMinutes > minutes) {
      throw ArgumentError.value(
        minChunkMinutes,
        'minChunkMinutes',
        'Expected 5–minutes',
      );
    }
  }

  final String id;
  final String title;
  final String subject;
  final String? planId;
  final TaskActivity activity;
  final int minutes;
  final int priority;
  final bool splittable;
  final int minChunkMinutes;
  final String knowledge;
  final String completionCondition;
  final String notes;
  final MaterialRef? material;

  /// documentId → reader session id. A task can span multiple materials;
  /// opening the same task again restores the exact session instead of the
  /// most recently opened session for that document.
  final Map<String, String> readerSessionBindings;
  final TaskStatus status;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;

  String get priorityLabel => switch (priority) {
    2 => '重点',
    0 => '可选',
    _ => '普通',
  };

  StudyTask copyWith({
    String? id,
    String? title,
    String? subject,
    String? planId,
    bool clearPlan = false,
    TaskActivity? activity,
    int? minutes,
    int? priority,
    bool? splittable,
    int? minChunkMinutes,
    String? knowledge,
    String? completionCondition,
    String? notes,
    MaterialRef? material,
    bool clearMaterial = false,
    Map<String, String>? readerSessionBindings,
    TaskStatus? status,
    int? revision,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => StudyTask(
    id: id ?? this.id,
    title: title ?? this.title,
    subject: subject ?? this.subject,
    planId: clearPlan ? null : planId ?? this.planId,
    activity: activity ?? this.activity,
    minutes: minutes ?? this.minutes,
    priority: priority ?? this.priority,
    splittable: splittable ?? this.splittable,
    minChunkMinutes: minChunkMinutes ?? this.minChunkMinutes,
    knowledge: knowledge ?? this.knowledge,
    completionCondition: completionCondition ?? this.completionCondition,
    notes: notes ?? this.notes,
    material: clearMaterial ? null : material ?? this.material,
    readerSessionBindings:
        readerSessionBindings ?? this.readerSessionBindings,
    status: status ?? this.status,
    revision: revision ?? this.revision,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'subject': subject,
    'planId': planId,
    'activity': activity.name,
    'minutes': minutes,
    'priority': priority,
    'splittable': splittable,
    'minChunkMinutes': minChunkMinutes,
    'knowledge': knowledge,
    'completionCondition': completionCondition,
    'notes': notes,
    'material': material?.toJson(),
    'readerSessionBindings': readerSessionBindings,
    'status': status.name,
    'revision': revision,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory StudyTask.fromJson(Map<String, dynamic> json) => StudyTask(
    id: json['id'] as String,
    title: json['title'] as String,
    subject: json['subject'] as String? ?? '',
    planId: json['planId'] as String?,
    activity: TaskActivity.values.byName(
      json['activity'] as String? ?? 'learn',
    ),
    minutes: (json['minutes'] as num).toInt(),
    priority: (json['priority'] as num?)?.toInt() ?? 1,
    splittable: json['splittable'] as bool? ?? true,
    minChunkMinutes: (json['minChunkMinutes'] as num?)?.toInt() ?? 15,
    knowledge: json['knowledge'] as String? ?? '',
    completionCondition: json['completionCondition'] as String? ?? '',
    notes: json['notes'] as String? ?? '',
    material: json['material'] == null
        ? null
        : MaterialRef.fromJson(
            Map<String, dynamic>.from(json['material'] as Map),
          ),
    readerSessionBindings: (json['readerSessionBindings'] as Map?)
            ?.map<String, String>(
              (key, value) => MapEntry('$key', '$value'),
            ) ??
        const {},
    status: TaskStatus.values.byName(
      json['status'] as String? ?? 'notStarted',
    ),
    revision: (json['revision'] as num?)?.toInt() ?? 1,
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );
}
