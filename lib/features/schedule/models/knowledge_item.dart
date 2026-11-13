import 'material_ref.dart';
import 'study_task.dart';

/// A teachable unit extracted from a plan source. It is not a calendar block:
/// it records what to learn, where it came from and how completion is judged.
class KnowledgeItem {
  KnowledgeItem({
    required this.id,
    required this.planId,
    required this.title,
    this.objective = '',
    this.sourceId,
    this.documentId,
    this.documentHash,
    this.documentTitle = '',
    this.startPage,
    this.endPage,
    this.sourceExcerpt = '',
    this.prerequisiteIds = const [],
    this.priority = 1,
    this.minutes = 45,
    this.activity = TaskActivity.learn,
    this.completionCondition = '',
    this.taskId,
    this.generatedByAi = false,
    this.revision = 1,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? createdAt ?? DateTime.now() {
    if (id.isEmpty || planId.isEmpty) {
      throw ArgumentError('Knowledge item needs a plan and an id.');
    }
    if (title.trim().isEmpty) {
      throw ArgumentError('Knowledge item needs a title.');
    }
    if (priority < 0 || priority > 2) {
      throw ArgumentError.value(priority, 'priority', 'Expected 0–2');
    }
    if (minutes < 5 || minutes > 600) {
      throw ArgumentError.value(minutes, 'minutes', 'Expected 5–600');
    }
    if ((startPage == null) != (endPage == null)) {
      throw ArgumentError('Knowledge source needs both page bounds.');
    }
    if (startPage != null &&
        (startPage! < 1 || endPage! < startPage!)) {
      throw ArgumentError('Knowledge source page range is invalid.');
    }
    if (prerequisiteIds.contains(id)) {
      throw ArgumentError('A knowledge item cannot require itself.');
    }
  }

  final String id;
  final String planId;
  final String title;
  final String objective;
  final String? sourceId;
  final String? documentId;
  final String? documentHash;
  final String documentTitle;
  final int? startPage;
  final int? endPage;
  final String sourceExcerpt;
  final List<String> prerequisiteIds;
  final int priority;
  final int minutes;
  final TaskActivity activity;
  final String completionCondition;
  final String? taskId;
  final bool generatedByAi;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get hasSource =>
      documentId != null &&
      documentHash != null &&
      startPage != null &&
      endPage != null;

  String get priorityLabel => switch (priority) {
    2 => '重点',
    0 => '可选',
    _ => '普通',
  };

  String? get sourcePageLabel => startPage == null
      ? null
      : startPage == endPage
      ? '第 $startPage 页'
      : '第 $startPage–$endPage 页';

  MaterialRef? get materialRef {
    if (!hasSource) return null;
    return MaterialRef(
      documentId: documentId!,
      documentHash: documentHash!,
      title: documentTitle,
      startPage: startPage!,
      endPage: endPage!,
    );
  }

  KnowledgeItem copyWith({
    String? id,
    String? planId,
    String? title,
    String? objective,
    String? sourceId,
    bool clearSource = false,
    String? documentId,
    String? documentHash,
    String? documentTitle,
    int? startPage,
    int? endPage,
    bool clearPages = false,
    String? sourceExcerpt,
    List<String>? prerequisiteIds,
    int? priority,
    int? minutes,
    TaskActivity? activity,
    String? completionCondition,
    String? taskId,
    bool clearTask = false,
    bool? generatedByAi,
    int? revision,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => KnowledgeItem(
    id: id ?? this.id,
    planId: planId ?? this.planId,
    title: title ?? this.title,
    objective: objective ?? this.objective,
    sourceId: clearSource ? null : sourceId ?? this.sourceId,
    documentId: clearSource ? null : documentId ?? this.documentId,
    documentHash: clearSource ? null : documentHash ?? this.documentHash,
    documentTitle: clearSource ? '' : documentTitle ?? this.documentTitle,
    startPage: clearSource || clearPages ? null : startPage ?? this.startPage,
    endPage: clearSource || clearPages ? null : endPage ?? this.endPage,
    sourceExcerpt: clearSource ? '' : sourceExcerpt ?? this.sourceExcerpt,
    prerequisiteIds: prerequisiteIds ?? this.prerequisiteIds,
    priority: priority ?? this.priority,
    minutes: minutes ?? this.minutes,
    activity: activity ?? this.activity,
    completionCondition: completionCondition ?? this.completionCondition,
    taskId: clearTask ? null : taskId ?? this.taskId,
    generatedByAi: generatedByAi ?? this.generatedByAi,
    revision: revision ?? this.revision,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'planId': planId,
    'title': title,
    'objective': objective,
    'sourceId': sourceId,
    'documentId': documentId,
    'documentHash': documentHash,
    'documentTitle': documentTitle,
    'startPage': startPage,
    'endPage': endPage,
    'sourceExcerpt': sourceExcerpt,
    'prerequisiteIds': prerequisiteIds,
    'priority': priority,
    'minutes': minutes,
    'activity': activity.name,
    'completionCondition': completionCondition,
    'taskId': taskId,
    'generatedByAi': generatedByAi,
    'revision': revision,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory KnowledgeItem.fromJson(Map<String, dynamic> json) => KnowledgeItem(
    id: json['id'] as String,
    planId: json['planId'] as String,
    title: json['title'] as String,
    objective: json['objective'] as String? ?? '',
    sourceId: json['sourceId'] as String?,
    documentId: json['documentId'] as String?,
    documentHash: json['documentHash'] as String?,
    documentTitle: json['documentTitle'] as String? ?? '',
    startPage: (json['startPage'] as num?)?.toInt(),
    endPage: (json['endPage'] as num?)?.toInt(),
    sourceExcerpt: json['sourceExcerpt'] as String? ?? '',
    prerequisiteIds: (json['prerequisiteIds'] as List<Object?>? ?? const [])
        .whereType<String>()
        .toList(growable: false),
    priority: (json['priority'] as num?)?.toInt() ?? 1,
    minutes: (json['minutes'] as num?)?.toInt() ?? 45,
    activity: TaskActivity.values.byName(
      json['activity'] as String? ?? 'learn',
    ),
    completionCondition: json['completionCondition'] as String? ?? '',
    taskId: json['taskId'] as String?,
    generatedByAi: json['generatedByAi'] as bool? ?? false,
    revision: (json['revision'] as num?)?.toInt() ?? 1,
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );
}
