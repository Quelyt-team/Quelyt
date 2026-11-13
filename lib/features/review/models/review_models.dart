import 'dart:convert';

import '../../../core/models.dart';

enum ReviewItemKind { concept, blank, occlusion, problem, application }

extension ReviewItemKindX on ReviewItemKind {
  String get label => switch (this) {
    ReviewItemKind.concept => '概念回忆',
    ReviewItemKind.blank => '填空',
    ReviewItemKind.occlusion => '图片遮挡',
    ReviewItemKind.problem => '计算/推导',
    ReviewItemKind.application => '综合应用',
  };

  ReviewScheduleMode get defaultScheduleMode => switch (this) {
    ReviewItemKind.concept ||
    ReviewItemKind.blank ||
    ReviewItemKind.occlusion => ReviewScheduleMode.fsrs,
    ReviewItemKind.problem ||
    ReviewItemKind.application => ReviewScheduleMode.training,
  };

  static ReviewItemKind parse(Object? raw) => ReviewItemKind.values.firstWhere(
    (value) => value.name == raw,
    orElse: () => ReviewItemKind.concept,
  );
}

enum ReviewScheduleMode { fsrs, training }

extension ReviewScheduleModeX on ReviewScheduleMode {
  String get label => switch (this) {
    ReviewScheduleMode.fsrs => '间隔记忆 (FSRS)',
    ReviewScheduleMode.training => '训练规则',
  };

  static ReviewScheduleMode parse(Object? raw) =>
      ReviewScheduleMode.values.firstWhere(
        (value) => value.name == raw,
        orElse: () => ReviewScheduleMode.fsrs,
      );
}

enum ReviewItemLifecycle { active, paused, archived, trashed }

extension ReviewItemLifecycleX on ReviewItemLifecycle {
  String get label => switch (this) {
    ReviewItemLifecycle.active => '正常',
    ReviewItemLifecycle.paused => '已暂停',
    ReviewItemLifecycle.archived => '已归档',
    ReviewItemLifecycle.trashed => '回收站',
  };

  static ReviewItemLifecycle parse(Object? raw) =>
      ReviewItemLifecycle.values.firstWhere(
        (value) => value.name == raw,
        orElse: () => ReviewItemLifecycle.active,
      );
}

enum ReviewRating { again, hard, good, easy }

extension ReviewRatingX on ReviewRating {
  String get label => switch (this) {
    ReviewRating.again => '没想起',
    ReviewRating.hard => '想起但困难',
    ReviewRating.good => '正常想起',
    ReviewRating.easy => '轻松想起',
  };

  String get shortLabel => switch (this) {
    ReviewRating.again => 'Again',
    ReviewRating.hard => 'Hard',
    ReviewRating.good => 'Good',
    ReviewRating.easy => 'Easy',
  };

  static ReviewRating? tryParse(Object? raw) {
    for (final v in ReviewRating.values) {
      if (v.name == raw) return v;
    }
    return null;
  }
}

enum ComplexityOutcome { independentCorrect, partial, incomplete, disputed }

extension ComplexityOutcomeX on ComplexityOutcome {
  String get label => switch (this) {
    ComplexityOutcome.independentCorrect => '独立正确',
    ComplexityOutcome.partial => '部分完成',
    ComplexityOutcome.incomplete => '未完成',
    ComplexityOutcome.disputed => '答案存疑',
  };

  static ComplexityOutcome? tryParse(Object? raw) {
    for (final v in ComplexityOutcome.values) {
      if (v.name == raw) return v;
    }
    return null;
  }
}

enum ReviewCardState { newCard, learning, review, relearning }

extension ReviewCardStateX on ReviewCardState {
  String get label => switch (this) {
    ReviewCardState.newCard => '新题',
    ReviewCardState.learning => '学习中',
    ReviewCardState.review => '复习中',
    ReviewCardState.relearning => '再学习',
  };

  static ReviewCardState parse(Object? raw) => ReviewCardState.values.firstWhere(
    (value) => value.name == raw,
    orElse: () => ReviewCardState.newCard,
  );
}

enum ReviewCheckStatus { open, resolved, dismissed }

extension ReviewCheckStatusX on ReviewCheckStatus {
  static ReviewCheckStatus parse(Object? raw) =>
      ReviewCheckStatus.values.firstWhere(
        (value) => value.name == raw,
        orElse: () => ReviewCheckStatus.open,
      );
}

enum ReviewCheckTargetType { item, answer, feedback, origin }

extension ReviewCheckTargetTypeX on ReviewCheckTargetType {
  String get label => switch (this) {
    ReviewCheckTargetType.item => '题目本身',
    ReviewCheckTargetType.answer => '参考答案',
    ReviewCheckTargetType.feedback => 'AI/学习评语',
    ReviewCheckTargetType.origin => '出处引用',
  };

  static ReviewCheckTargetType parse(Object? raw) =>
      ReviewCheckTargetType.values.firstWhere(
        (value) => value.name == raw,
        orElse: () => ReviewCheckTargetType.feedback,
      );
}

enum ReviewCandidateStatus { pending, accepted, ignored }

extension ReviewCandidateStatusX on ReviewCandidateStatus {
  static ReviewCandidateStatus parse(Object? raw) =>
      ReviewCandidateStatus.values.firstWhere(
        (value) => value.name == raw,
        orElse: () => ReviewCandidateStatus.pending,
      );
}

enum ReviewSessionMode { formal, free }

extension ReviewSessionModeX on ReviewSessionMode {
  String get label => switch (this) {
    ReviewSessionMode.formal => '正式复习',
    ReviewSessionMode.free => '自由练习',
  };

  static ReviewSessionMode parse(Object? raw) =>
      ReviewSessionMode.values.firstWhere(
        (value) => value.name == raw,
        orElse: () => ReviewSessionMode.formal,
      );
}

enum ReviewSessionStatus { active, paused, completed, abandoned }

extension ReviewSessionStatusX on ReviewSessionStatus {
  static ReviewSessionStatus parse(Object? raw) =>
      ReviewSessionStatus.values.firstWhere(
        (value) => value.name == raw,
        orElse: () => ReviewSessionStatus.active,
      );
}

enum ReviewResultSource { self, rule, aiConfirmed, unknown }

extension ReviewResultSourceX on ReviewResultSource {
  String get label => switch (this) {
    ReviewResultSource.self => '自评',
    ReviewResultSource.rule => '本地规则',
    ReviewResultSource.aiConfirmed => 'AI 辅助（已确认）',
    ReviewResultSource.unknown => '未知',
  };

  static ReviewResultSource parse(Object? raw) =>
      ReviewResultSource.values.firstWhere(
        (value) => value.name == raw,
        orElse: () => ReviewResultSource.self,
      );
}

enum KnowledgeEvidenceLevel {
  unpracticed,
  needsStudy,
  practicing,
  crossDayRecall,
  applicationVerified,
}

extension KnowledgeEvidenceLevelX on KnowledgeEvidenceLevel {
  String get label => switch (this) {
    KnowledgeEvidenceLevel.unpracticed => '未练习',
    KnowledgeEvidenceLevel.needsStudy => '需补学',
    KnowledgeEvidenceLevel.practicing => '练习中',
    KnowledgeEvidenceLevel.crossDayRecall => '跨日回忆通过',
    KnowledgeEvidenceLevel.applicationVerified => '应用验证通过',
  };
}

class ReviewErrorReasons {
  static const List<String> presets = [
    '概念混淆',
    '条件遗漏',
    '方法/步骤',
    '计算/符号',
    '审题偏差',
    '遗忘',
    '题目/答案问题',
  ];
}

class ReviewOcclusionRect {
  const ReviewOcclusionRect({
    required this.id,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    this.maskText = '',
  });

  final String id;
  final double left;
  final double top;
  final double width;
  final double height;
  final String maskText;

  Map<String, dynamic> toJson() => {
    'id': id,
    'left': left,
    'top': top,
    'width': width,
    'height': height,
    'maskText': maskText,
  };

  factory ReviewOcclusionRect.fromJson(Map<String, dynamic> json) =>
      ReviewOcclusionRect(
        id: json['id'] as String? ?? '',
        left: (json['left'] as num?)?.toDouble() ?? 0.2,
        top: (json['top'] as num?)?.toDouble() ?? 0.2,
        width: (json['width'] as num?)?.toDouble() ?? 0.3,
        height: (json['height'] as num?)?.toDouble() ?? 0.15,
        maskText: json['maskText'] as String? ?? '',
      );
}

class ReviewItem {
  ReviewItem({
    required this.id,
    this.kind = ReviewItemKind.concept,
    ReviewScheduleMode? scheduleMode,
    this.objective = '',
    required this.prompt,
    this.answer = '',
    this.steps = const [],
    this.hint = '',
    this.explanation = '',
    this.imagePath,
    this.occlusionRects = const [],
    this.blankAnswers = const [],
    this.choices = const [],
    this.correctChoiceIndex,
    this.variantParentId,
    this.knowledgeObjectiveId,
    this.lifecycle = ReviewItemLifecycle.active,
    this.starred = false,
    this.revision = 1,
    int? estimatedSeconds,
    this.wrongStreak = 0,
    this.correctStreak = 0,
    this.errorReason = '',
    this.correctionNote = '',
    this.corrected = false,
    this.crossDayRedoPassed = false,
    this.applicationVerified = false,
    this.aiGenerated = false,
    this.deletedBatch,
    this.trashedAt,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : scheduleMode = scheduleMode ?? kind.defaultScheduleMode,
       estimatedSeconds =
           estimatedSeconds ??
           (kind == ReviewItemKind.problem ||
                   kind == ReviewItemKind.application
               ? 300
               : 30),
       createdAt = (createdAt ?? DateTime.now()).toUtc(),
       updatedAt = (updatedAt ?? DateTime.now()).toUtc();

  final String id;
  final ReviewItemKind kind;
  final ReviewScheduleMode scheduleMode;
  final String objective;
  final String prompt;
  final String answer;
  final List<String> steps;
  final String hint;
  final String explanation;
  final String? imagePath;
  final List<ReviewOcclusionRect> occlusionRects;
  final List<String> blankAnswers;
  final List<String> choices;
  final int? correctChoiceIndex;
  final String? variantParentId;
  final String? knowledgeObjectiveId;
  final ReviewItemLifecycle lifecycle;
  final bool starred;
  final int revision;
  final int estimatedSeconds;
  final int wrongStreak;
  final int correctStreak;
  final String errorReason;
  final String correctionNote;
  final bool corrected;
  final bool crossDayRedoPassed;
  final bool applicationVerified;
  final bool aiGenerated;
  final String? deletedBatch;
  final DateTime? trashedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isActive => lifecycle == ReviewItemLifecycle.active;
  bool get isPaused => lifecycle == ReviewItemLifecycle.paused;
  bool get isTrashed => lifecycle == ReviewItemLifecycle.trashed;
  bool get isComplex => scheduleMode == ReviewScheduleMode.training;

  ReviewItem copyWith({
    String? id,
    ReviewItemKind? kind,
    ReviewScheduleMode? scheduleMode,
    String? objective,
    String? prompt,
    String? answer,
    List<String>? steps,
    String? hint,
    String? explanation,
    String? imagePath,
    bool clearImagePath = false,
    List<ReviewOcclusionRect>? occlusionRects,
    List<String>? blankAnswers,
    List<String>? choices,
    int? correctChoiceIndex,
    bool clearChoiceIndex = false,
    String? variantParentId,
    String? knowledgeObjectiveId,
    ReviewItemLifecycle? lifecycle,
    bool? starred,
    int? revision,
    int? estimatedSeconds,
    int? wrongStreak,
    int? correctStreak,
    String? errorReason,
    String? correctionNote,
    bool? corrected,
    bool? crossDayRedoPassed,
    bool? applicationVerified,
    bool? aiGenerated,
    String? deletedBatch,
    bool clearDeletedBatch = false,
    DateTime? trashedAt,
    bool clearTrashedAt = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => ReviewItem(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    scheduleMode: scheduleMode ?? this.scheduleMode,
    objective: objective ?? this.objective,
    prompt: prompt ?? this.prompt,
    answer: answer ?? this.answer,
    steps: steps ?? this.steps,
    hint: hint ?? this.hint,
    explanation: explanation ?? this.explanation,
    imagePath: clearImagePath ? null : imagePath ?? this.imagePath,
    occlusionRects: occlusionRects ?? this.occlusionRects,
    blankAnswers: blankAnswers ?? this.blankAnswers,
    choices: choices ?? this.choices,
    correctChoiceIndex: clearChoiceIndex
        ? null
        : correctChoiceIndex ?? this.correctChoiceIndex,
    variantParentId: variantParentId ?? this.variantParentId,
    knowledgeObjectiveId: knowledgeObjectiveId ?? this.knowledgeObjectiveId,
    lifecycle: lifecycle ?? this.lifecycle,
    starred: starred ?? this.starred,
    revision: revision ?? this.revision,
    estimatedSeconds: estimatedSeconds ?? this.estimatedSeconds,
    wrongStreak: wrongStreak ?? this.wrongStreak,
    correctStreak: correctStreak ?? this.correctStreak,
    errorReason: errorReason ?? this.errorReason,
    correctionNote: correctionNote ?? this.correctionNote,
    corrected: corrected ?? this.corrected,
    crossDayRedoPassed: crossDayRedoPassed ?? this.crossDayRedoPassed,
    applicationVerified: applicationVerified ?? this.applicationVerified,
    aiGenerated: aiGenerated ?? this.aiGenerated,
    deletedBatch: clearDeletedBatch ? null : deletedBatch ?? this.deletedBatch,
    trashedAt: clearTrashedAt ? null : trashedAt ?? this.trashedAt,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'scheduleMode': scheduleMode.name,
    'objective': objective,
    'prompt': prompt,
    'answer': answer,
    'steps': steps,
    'hint': hint,
    'explanation': explanation,
    'imagePath': imagePath,
    'occlusionRects': occlusionRects.map((e) => e.toJson()).toList(),
    'blankAnswers': blankAnswers,
    'choices': choices,
    'correctChoiceIndex': correctChoiceIndex,
    'variantParentId': variantParentId,
    'knowledgeObjectiveId': knowledgeObjectiveId,
    'lifecycle': lifecycle.name,
    'starred': starred,
    'revision': revision,
    'estimatedSeconds': estimatedSeconds,
    'wrongStreak': wrongStreak,
    'correctStreak': correctStreak,
    'errorReason': errorReason,
    'correctionNote': correctionNote,
    'corrected': corrected,
    'crossDayRedoPassed': crossDayRedoPassed,
    'applicationVerified': applicationVerified,
    'aiGenerated': aiGenerated,
    'deletedBatch': deletedBatch,
    'trashedAt': trashedAt?.toIso8601String(),
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory ReviewItem.fromJson(Map<String, dynamic> json) => ReviewItem(
    id: json['id'] as String,
    kind: ReviewItemKindX.parse(json['kind']),
    scheduleMode: ReviewScheduleModeX.parse(json['scheduleMode']),
    objective: json['objective'] as String? ?? '',
    prompt: json['prompt'] as String? ?? '',
    answer: json['answer'] as String? ?? '',
    steps: (json['steps'] as List? ?? const []).map((e) => '$e').toList(),
    hint: json['hint'] as String? ?? '',
    explanation: json['explanation'] as String? ?? '',
    imagePath: json['imagePath'] as String?,
    occlusionRects: (json['occlusionRects'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => ReviewOcclusionRect.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
    blankAnswers: (json['blankAnswers'] as List? ?? const [])
        .map((e) => '$e')
        .toList(),
    choices: (json['choices'] as List? ?? const []).map((e) => '$e').toList(),
    correctChoiceIndex: (json['correctChoiceIndex'] as num?)?.toInt(),
    variantParentId: json['variantParentId'] as String?,
    knowledgeObjectiveId: json['knowledgeObjectiveId'] as String?,
    lifecycle: ReviewItemLifecycleX.parse(json['lifecycle']),
    starred: json['starred'] as bool? ?? false,
    revision: (json['revision'] as num?)?.toInt() ?? 1,
    estimatedSeconds: (json['estimatedSeconds'] as num?)?.toInt(),
    wrongStreak: (json['wrongStreak'] as num?)?.toInt() ?? 0,
    correctStreak: (json['correctStreak'] as num?)?.toInt() ?? 0,
    errorReason: json['errorReason'] as String? ?? '',
    correctionNote: json['correctionNote'] as String? ?? '',
    corrected: json['corrected'] as bool? ?? false,
    crossDayRedoPassed: json['crossDayRedoPassed'] as bool? ?? false,
    applicationVerified: json['applicationVerified'] as bool? ?? false,
    aiGenerated: json['aiGenerated'] as bool? ?? false,
    deletedBatch: json['deletedBatch'] as String?,
    trashedAt: json['trashedAt'] == null
        ? null
        : DateTime.parse(json['trashedAt'] as String),
    createdAt: json['createdAt'] == null
        ? null
        : DateTime.parse(json['createdAt'] as String),
    updatedAt: json['updatedAt'] == null
        ? null
        : DateTime.parse(json['updatedAt'] as String),
  );
}

class ReviewOrigin {
  ReviewOrigin({
    required this.id,
    required this.itemId,
    required this.originKey,
    this.sourceType = 'manual',
    this.documentId,
    this.documentHash = '',
    this.documentTitle = '',
    this.page,
    this.region = SourceRegion.fullPage,
    this.noteId,
    this.noteRevision,
    this.lessonId,
    this.exerciseId,
    this.sessionId,
    this.taskId,
    this.snapshotText = '',
    this.sourceAvailable = true,
    this.sourceNoteUpdated = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = (createdAt ?? DateTime.now()).toUtc(),
       updatedAt = (updatedAt ?? DateTime.now()).toUtc();

  final String id;
  final String itemId;
  final String originKey;
  final String sourceType;
  final String? documentId;
  final String documentHash;
  final String documentTitle;
  final int? page;
  final SourceRegion region;
  final String? noteId;
  final int? noteRevision;
  final String? lessonId;
  final String? exerciseId;
  final String? sessionId;
  final String? taskId;
  final String snapshotText;
  final bool sourceAvailable;
  final bool sourceNoteUpdated;
  final DateTime createdAt;
  final DateTime updatedAt;

  String get displayLabel {
    if (documentTitle.isNotEmpty) {
      return page != null ? '$documentTitle · 第 $page 页' : documentTitle;
    }
    return switch (sourceType) {
      'note' => '笔记来源',
      'lesson' => '每日课程',
      'book_qa' => '整书问答',
      'session' => '阅读练习',
      _ => '手动创建',
    };
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'itemId': itemId,
    'originKey': originKey,
    'sourceType': sourceType,
    'documentId': documentId,
    'documentHash': documentHash,
    'documentTitle': documentTitle,
    'page': page,
    'region': region.toJson(),
    'noteId': noteId,
    'noteRevision': noteRevision,
    'lessonId': lessonId,
    'exerciseId': exerciseId,
    'sessionId': sessionId,
    'taskId': taskId,
    'snapshotText': snapshotText,
    'sourceAvailable': sourceAvailable,
    'sourceNoteUpdated': sourceNoteUpdated,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory ReviewOrigin.fromJson(Map<String, dynamic> json) => ReviewOrigin(
    id: json['id'] as String? ?? '',
    itemId: json['itemId'] as String? ?? '',
    originKey: json['originKey'] as String? ?? '',
    sourceType: json['sourceType'] as String? ?? 'manual',
    documentId: json['documentId'] as String?,
    documentHash: json['documentHash'] as String? ?? '',
    documentTitle: json['documentTitle'] as String? ?? '',
    page: (json['page'] as num?)?.toInt(),
    region: json['region'] is Map
        ? SourceRegion.fromJson(Map<String, dynamic>.from(json['region'] as Map))
        : SourceRegion.fullPage,
    noteId: json['noteId'] as String?,
    noteRevision: (json['noteRevision'] as num?)?.toInt(),
    lessonId: json['lessonId'] as String?,
    exerciseId: json['exerciseId'] as String?,
    sessionId: json['sessionId'] as String?,
    taskId: json['taskId'] as String?,
    snapshotText: json['snapshotText'] as String? ?? '',
    sourceAvailable: json['sourceAvailable'] as bool? ?? true,
    sourceNoteUpdated: json['sourceNoteUpdated'] as bool? ?? false,
    createdAt: json['createdAt'] == null
        ? null
        : DateTime.parse(json['createdAt'] as String),
    updatedAt: json['updatedAt'] == null
        ? null
        : DateTime.parse(json['updatedAt'] as String),
  );
}

class ReviewCandidate {
  ReviewCandidate({
    required this.id,
    required this.originKey,
    required this.sourceType,
    this.documentId,
    this.documentHash = '',
    this.documentTitle = '',
    this.startPage,
    this.endPage,
    this.noteId,
    this.lessonId,
    this.exerciseId,
    this.sessionId,
    this.taskId,
    this.title = '',
    required this.prompt,
    this.answer = '',
    this.hint = '',
    this.explanation = '',
    this.status = ReviewCandidateStatus.pending,
    this.linkedItemId,
    this.reason = '',
    this.kind = ReviewItemKind.concept,
    this.extra = const {},
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = (createdAt ?? DateTime.now()).toUtc(),
       updatedAt = (updatedAt ?? DateTime.now()).toUtc();

  final String id;
  final String originKey;
  final String sourceType;
  final String? documentId;
  final String documentHash;
  final String documentTitle;
  final int? startPage;
  final int? endPage;
  final String? noteId;
  final String? lessonId;
  final String? exerciseId;
  final String? sessionId;
  final String? taskId;
  final String title;
  final String prompt;
  final String answer;
  final String hint;
  final String explanation;
  final ReviewCandidateStatus status;
  final String? linkedItemId;
  final String reason;
  final ReviewItemKind kind;
  final Map<String, dynamic> extra;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'originKey': originKey,
    'sourceType': sourceType,
    'documentId': documentId,
    'documentHash': documentHash,
    'documentTitle': documentTitle,
    'startPage': startPage,
    'endPage': endPage,
    'noteId': noteId,
    'lessonId': lessonId,
    'exerciseId': exerciseId,
    'sessionId': sessionId,
    'taskId': taskId,
    'title': title,
    'prompt': prompt,
    'answer': answer,
    'hint': hint,
    'explanation': explanation,
    'status': status.name,
    'linkedItemId': linkedItemId,
    'reason': reason,
    'kind': kind.name,
    'extra': extra,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory ReviewCandidate.fromJson(Map<String, dynamic> json) =>
      ReviewCandidate(
        id: json['id'] as String,
        originKey: json['originKey'] as String? ?? '',
        sourceType: json['sourceType'] as String? ?? 'lesson',
        documentId: json['documentId'] as String?,
        documentHash: json['documentHash'] as String? ?? '',
        documentTitle: json['documentTitle'] as String? ?? '',
        startPage: (json['startPage'] as num?)?.toInt(),
        endPage: (json['endPage'] as num?)?.toInt(),
        noteId: json['noteId'] as String?,
        lessonId: json['lessonId'] as String?,
        exerciseId: json['exerciseId'] as String?,
        sessionId: json['sessionId'] as String?,
        taskId: json['taskId'] as String?,
        title: json['title'] as String? ?? '',
        prompt: json['prompt'] as String? ?? '',
        answer: json['answer'] as String? ?? '',
        hint: json['hint'] as String? ?? '',
        explanation: json['explanation'] as String? ?? '',
        status: ReviewCandidateStatusX.parse(json['status']),
        linkedItemId: json['linkedItemId'] as String?,
        reason: json['reason'] as String? ?? '',
        kind: ReviewItemKindX.parse(json['kind']),
        extra: json['extra'] is Map
            ? Map<String, dynamic>.from(json['extra'] as Map)
            : json,
        createdAt: json['createdAt'] == null
            ? null
            : DateTime.parse(json['createdAt'] as String),
        updatedAt: json['updatedAt'] == null
            ? null
            : DateTime.parse(json['updatedAt'] as String),
      );
}

class ReviewCheck {
  ReviewCheck({
    required this.id,
    this.originKey,
    this.targetType = ReviewCheckTargetType.feedback,
    this.targetId = '',
    this.targetVersion = 1,
    this.itemId,
    this.documentId,
    this.documentTitle = '',
    this.sessionId,
    this.attemptKey,
    this.startPage,
    this.endPage,
    this.question = '',
    this.answer = '',
    this.feedback = '',
    this.reason = '',
    this.status = ReviewCheckStatus.open,
    this.resolutionNote = '',
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = (createdAt ?? DateTime.now()).toUtc(),
       updatedAt = (updatedAt ?? DateTime.now()).toUtc();

  final String id;
  final String? originKey;
  final ReviewCheckTargetType targetType;
  final String targetId;
  final int targetVersion;
  final String? itemId;
  final String? documentId;
  final String documentTitle;
  final String? sessionId;
  final String? attemptKey;
  final int? startPage;
  final int? endPage;
  final String question;
  final String answer;
  final String feedback;
  final String reason;
  final ReviewCheckStatus status;
  final String resolutionNote;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'originKey': originKey,
    'targetType': targetType.name,
    'targetId': targetId,
    'targetVersion': targetVersion,
    'itemId': itemId,
    'documentId': documentId,
    'documentTitle': documentTitle,
    'sessionId': sessionId,
    'attemptKey': attemptKey,
    'startPage': startPage,
    'endPage': endPage,
    'question': question,
    'answer': answer,
    'feedback': feedback,
    'reason': reason,
    'status': status.name,
    'resolutionNote': resolutionNote,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory ReviewCheck.fromJson(Map<String, dynamic> json) => ReviewCheck(
    id: json['id'] as String,
    originKey: json['originKey'] as String?,
    targetType: ReviewCheckTargetTypeX.parse(json['targetType']),
    targetId: json['targetId'] as String? ?? '',
    targetVersion: (json['targetVersion'] as num?)?.toInt() ?? 1,
    itemId: json['itemId'] as String?,
    documentId: json['documentId'] as String?,
    documentTitle: json['documentTitle'] as String? ?? '',
    sessionId: json['sessionId'] as String?,
    attemptKey: json['attemptKey'] as String?,
    startPage: (json['startPage'] as num?)?.toInt(),
    endPage: (json['endPage'] as num?)?.toInt(),
    question: json['question'] as String? ?? '',
    answer: json['answer'] as String? ?? '',
    feedback: json['feedback'] as String? ?? '',
    reason: json['reason'] as String? ?? '',
    status: ReviewCheckStatusX.parse(json['status']),
    resolutionNote: json['resolutionNote'] as String? ?? '',
    createdAt: json['createdAt'] == null
        ? null
        : DateTime.parse(json['createdAt'] as String),
    updatedAt: json['updatedAt'] == null
        ? null
        : DateTime.parse(json['updatedAt'] as String),
  );
}

class ReviewScheduleState {
  ReviewScheduleState({
    required this.itemId,
    this.mode = ReviewScheduleMode.fsrs,
    this.algorithmVersion = 'fsrs-v5-default-19w',
    this.state = ReviewCardState.newCard,
    this.stability = 0.0,
    this.difficulty = 0.0,
    this.elapsedDays = 0.0,
    this.scheduledDays = 0,
    this.reps = 0,
    this.lapses = 0,
    this.step = 0,
    this.trainingStage = 'initial',
    this.algorithmDueAtUtc,
    this.deferUntilUtc,
    this.paused = false,
    this.revision = 1,
    this.lastReviewAtUtc,
    DateTime? updatedAt,
  }) : updatedAt = (updatedAt ?? DateTime.now()).toUtc();

  final String itemId;
  final ReviewScheduleMode mode;
  final String algorithmVersion;
  final ReviewCardState state;
  final double stability;
  final double difficulty;
  final double elapsedDays;
  final int scheduledDays;
  final int reps;
  final int lapses;
  final int step;
  final String trainingStage;
  final DateTime? algorithmDueAtUtc;
  final DateTime? deferUntilUtc;
  final bool paused;
  final int revision;
  final DateTime? lastReviewAtUtc;
  final DateTime updatedAt;

  bool isDeferredAt(DateTime nowUtc) =>
      deferUntilUtc != null && deferUntilUtc!.isAfter(nowUtc);

  ReviewScheduleState copyWith({
    String? itemId,
    ReviewScheduleMode? mode,
    String? algorithmVersion,
    ReviewCardState? state,
    double? stability,
    double? difficulty,
    double? elapsedDays,
    int? scheduledDays,
    int? reps,
    int? lapses,
    int? step,
    String? trainingStage,
    DateTime? algorithmDueAtUtc,
    bool clearDueAt = false,
    DateTime? deferUntilUtc,
    bool clearDefer = false,
    bool? paused,
    int? revision,
    DateTime? lastReviewAtUtc,
    DateTime? updatedAt,
  }) => ReviewScheduleState(
    itemId: itemId ?? this.itemId,
    mode: mode ?? this.mode,
    algorithmVersion: algorithmVersion ?? this.algorithmVersion,
    state: state ?? this.state,
    stability: stability ?? this.stability,
    difficulty: difficulty ?? this.difficulty,
    elapsedDays: elapsedDays ?? this.elapsedDays,
    scheduledDays: scheduledDays ?? this.scheduledDays,
    reps: reps ?? this.reps,
    lapses: lapses ?? this.lapses,
    step: step ?? this.step,
    trainingStage: trainingStage ?? this.trainingStage,
    algorithmDueAtUtc: clearDueAt
        ? null
        : algorithmDueAtUtc ?? this.algorithmDueAtUtc,
    deferUntilUtc: clearDefer ? null : deferUntilUtc ?? this.deferUntilUtc,
    paused: paused ?? this.paused,
    revision: revision ?? this.revision,
    lastReviewAtUtc: lastReviewAtUtc ?? this.lastReviewAtUtc,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'itemId': itemId,
    'mode': mode.name,
    'algorithmVersion': algorithmVersion,
    'state': state.name,
    'stability': stability,
    'difficulty': difficulty,
    'elapsedDays': elapsedDays,
    'scheduledDays': scheduledDays,
    'reps': reps,
    'lapses': lapses,
    'step': step,
    'trainingStage': trainingStage,
    'algorithmDueAtUtc': algorithmDueAtUtc?.toIso8601String(),
    'deferUntilUtc': deferUntilUtc?.toIso8601String(),
    'paused': paused,
    'revision': revision,
    'lastReviewAtUtc': lastReviewAtUtc?.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory ReviewScheduleState.fromJson(Map<String, dynamic> json) =>
      ReviewScheduleState(
        itemId: json['itemId'] as String,
        mode: ReviewScheduleModeX.parse(json['mode']),
        algorithmVersion:
            json['algorithmVersion'] as String? ?? 'fsrs-v5-default-19w',
        state: ReviewCardStateX.parse(json['state']),
        stability: (json['stability'] as num?)?.toDouble() ?? 0.0,
        difficulty: (json['difficulty'] as num?)?.toDouble() ?? 0.0,
        elapsedDays: (json['elapsedDays'] as num?)?.toDouble() ?? 0.0,
        scheduledDays: (json['scheduledDays'] as num?)?.toInt() ?? 0,
        reps: (json['reps'] as num?)?.toInt() ?? 0,
        lapses: (json['lapses'] as num?)?.toInt() ?? 0,
        step: (json['step'] as num?)?.toInt() ?? 0,
        trainingStage: json['trainingStage'] as String? ?? 'initial',
        algorithmDueAtUtc: json['algorithmDueAtUtc'] == null
            ? null
            : DateTime.parse(json['algorithmDueAtUtc'] as String).toUtc(),
        deferUntilUtc: json['deferUntilUtc'] == null
            ? null
            : DateTime.parse(json['deferUntilUtc'] as String).toUtc(),
        paused: json['paused'] as bool? ?? false,
        revision: (json['revision'] as num?)?.toInt() ?? 1,
        lastReviewAtUtc: json['lastReviewAtUtc'] == null
            ? null
            : DateTime.parse(json['lastReviewAtUtc'] as String).toUtc(),
        updatedAt: json['updatedAt'] == null
            ? null
            : DateTime.parse(json['updatedAt'] as String).toUtc(),
      );
}

class ReviewRatingPreview {
  const ReviewRatingPreview({
    required this.rating,
    required this.nextState,
    required this.intervalLabel,
  });

  final ReviewRating rating;
  final ReviewScheduleState nextState;
  final String intervalLabel;
}

class ReviewAttempt {
  ReviewAttempt({
    required this.id,
    required this.itemId,
    this.sessionId,
    this.itemRevision = 1,
    this.mode = 'formal',
    this.answerText = '',
    this.usedHint = false,
    this.viewedSource = false,
    this.selfEval = true,
    this.rating,
    this.complexityOutcome,
    this.aiSuggestion,
    this.aiDisputed = false,
    this.resultSource = ReviewResultSource.self,
    this.activeSeconds = 0,
    required this.studyDay,
    required this.createdAtUtc,
    required this.operationId,
    this.undone = false,
    this.errorReason = '',
    this.correctionNote = '',
  });

  final String id;
  final String itemId;
  final String? sessionId;
  final int itemRevision;
  final String mode; // formal | free | consolidation
  final String answerText;
  final bool usedHint;
  final bool viewedSource;
  final bool selfEval;
  final ReviewRating? rating;
  final ComplexityOutcome? complexityOutcome;
  final AiReviewSuggestion? aiSuggestion;
  final bool aiDisputed;
  final ReviewResultSource resultSource;
  final int activeSeconds;
  final String studyDay;
  final DateTime createdAtUtc;
  final String operationId;
  final bool undone;
  final String errorReason;
  final String correctionNote;

  bool get isAssisted => usedHint || viewedSource;

  bool get isIndependentSuccess =>
      !undone &&
      mode == 'formal' &&
      !isAssisted &&
      ((rating != null && rating != ReviewRating.again) ||
          complexityOutcome == ComplexityOutcome.independentCorrect);

  Map<String, dynamic> toJson() => {
    'id': id,
    'itemId': itemId,
    'sessionId': sessionId,
    'itemRevision': itemRevision,
    'mode': mode,
    'answerText': answerText,
    'usedHint': usedHint,
    'viewedSource': viewedSource,
    'selfEval': selfEval,
    'rating': rating?.name,
    'complexityOutcome': complexityOutcome?.name,
    'aiSuggestion': aiSuggestion?.toJson(),
    'aiDisputed': aiDisputed,
    'resultSource': resultSource.name,
    'activeSeconds': activeSeconds,
    'studyDay': studyDay,
    'createdAtUtc': createdAtUtc.toIso8601String(),
    'operationId': operationId,
    'undone': undone,
    'errorReason': errorReason,
    'correctionNote': correctionNote,
  };

  factory ReviewAttempt.fromJson(Map<String, dynamic> json) => ReviewAttempt(
    id: json['id'] as String,
    itemId: json['itemId'] as String,
    sessionId: json['sessionId'] as String?,
    itemRevision: (json['itemRevision'] as num?)?.toInt() ?? 1,
    mode: json['mode'] as String? ?? 'formal',
    answerText: json['answerText'] as String? ?? '',
    usedHint: json['usedHint'] as bool? ?? false,
    viewedSource: json['viewedSource'] as bool? ?? false,
    selfEval: json['selfEval'] as bool? ?? true,
    rating: ReviewRatingX.tryParse(json['rating']),
    complexityOutcome: ComplexityOutcomeX.tryParse(json['complexityOutcome']),
    aiSuggestion: json['aiSuggestion'] is Map
        ? AiReviewSuggestion.fromJson(
            Map<String, dynamic>.from(json['aiSuggestion'] as Map),
          )
        : null,
    aiDisputed: json['aiDisputed'] as bool? ?? false,
    resultSource: ReviewResultSourceX.parse(json['resultSource']),
    activeSeconds: (json['activeSeconds'] as num?)?.toInt() ?? 0,
    studyDay: json['studyDay'] as String? ?? '',
    createdAtUtc: DateTime.parse(json['createdAtUtc'] as String).toUtc(),
    operationId: json['operationId'] as String? ?? '',
    undone: json['undone'] as bool? ?? false,
    errorReason: json['errorReason'] as String? ?? '',
    correctionNote: json['correctionNote'] as String? ?? '',
  );
}

class ReviewEvent {
  ReviewEvent({
    required this.id,
    required this.itemId,
    this.attemptId,
    required this.operationId,
    required this.eventType,
    required this.algorithmVersion,
    required this.beforeSchedule,
    required this.afterSchedule,
    required this.studyDay,
    required this.createdAtUtc,
    this.note = '',
  });

  final String id;
  final String itemId;
  final String? attemptId;
  final String operationId;
  final String eventType;
  final String algorithmVersion;
  final ReviewScheduleState beforeSchedule;
  final ReviewScheduleState afterSchedule;
  final String studyDay;
  final DateTime createdAtUtc;
  final String note;

  Map<String, dynamic> toJson() => {
    'id': id,
    'itemId': itemId,
    'attemptId': attemptId,
    'operationId': operationId,
    'eventType': eventType,
    'algorithmVersion': algorithmVersion,
    'beforeSchedule': beforeSchedule.toJson(),
    'afterSchedule': afterSchedule.toJson(),
    'studyDay': studyDay,
    'createdAtUtc': createdAtUtc.toIso8601String(),
    'note': note,
  };

  factory ReviewEvent.fromJson(Map<String, dynamic> json) => ReviewEvent(
    id: json['id'] as String,
    itemId: json['itemId'] as String,
    attemptId: json['attemptId'] as String?,
    operationId: json['operationId'] as String,
    eventType: json['eventType'] as String,
    algorithmVersion: json['algorithmVersion'] as String? ?? '',
    beforeSchedule: ReviewScheduleState.fromJson(
      Map<String, dynamic>.from(json['beforeSchedule'] as Map),
    ),
    afterSchedule: ReviewScheduleState.fromJson(
      Map<String, dynamic>.from(json['afterSchedule'] as Map),
    ),
    studyDay: json['studyDay'] as String? ?? '',
    createdAtUtc: DateTime.parse(json['createdAtUtc'] as String).toUtc(),
    note: json['note'] as String? ?? '',
  );
}

class ReviewSessionItem {
  ReviewSessionItem({
    required this.sessionId,
    required this.position,
    required this.itemId,
    required this.itemRevision,
    this.draftAnswer = '',
    this.draftNotes = '',
    this.usedHint = false,
    this.viewedSource = false,
    this.status = 'pending', // pending | done | skipped | deferred
    this.attemptId,
    DateTime? updatedAtUtc,
  }) : updatedAtUtc = (updatedAtUtc ?? DateTime.now()).toUtc();

  final String sessionId;
  final int position;
  final String itemId;
  final int itemRevision;
  final String draftAnswer;
  final String draftNotes;
  final bool usedHint;
  final bool viewedSource;
  final String status;
  final String? attemptId;
  final DateTime updatedAtUtc;

  ReviewSessionItem copyWith({
    String? draftAnswer,
    String? draftNotes,
    bool? usedHint,
    bool? viewedSource,
    String? status,
    String? attemptId,
    DateTime? updatedAtUtc,
  }) => ReviewSessionItem(
    sessionId: sessionId,
    position: position,
    itemId: itemId,
    itemRevision: itemRevision,
    draftAnswer: draftAnswer ?? this.draftAnswer,
    draftNotes: draftNotes ?? this.draftNotes,
    usedHint: usedHint ?? this.usedHint,
    viewedSource: viewedSource ?? this.viewedSource,
    status: status ?? this.status,
    attemptId: attemptId ?? this.attemptId,
    updatedAtUtc: updatedAtUtc ?? DateTime.now().toUtc(),
  );
}

class ReviewSession {
  ReviewSession({
    required this.id,
    required this.mode,
    required this.scope,
    required this.budgetMinutes,
    required this.status,
    required this.currentIndex,
    required this.activeSeconds,
    required this.studyDay,
    this.scheduleTaskId,
    this.scheduleBlockId,
    required this.startedAtUtc,
    required this.updatedAtUtc,
    this.completedAtUtc,
    this.items = const [],
  });

  final String id;
  final ReviewSessionMode mode;
  final ReviewScopeFilter scope;
  final int budgetMinutes;
  final ReviewSessionStatus status;
  final int currentIndex;
  final int activeSeconds;
  final String studyDay;
  final String? scheduleTaskId;
  final String? scheduleBlockId;
  final DateTime startedAtUtc;
  final DateTime updatedAtUtc;
  final DateTime? completedAtUtc;
  final List<ReviewSessionItem> items;

  int get completedCount => items.where((i) => i.status == 'done').length;

  ReviewSession copyWith({
    ReviewSessionStatus? status,
    int? currentIndex,
    int? activeSeconds,
    DateTime? updatedAtUtc,
    DateTime? completedAtUtc,
    List<ReviewSessionItem>? items,
  }) => ReviewSession(
    id: id,
    mode: mode,
    scope: scope,
    budgetMinutes: budgetMinutes,
    status: status ?? this.status,
    currentIndex: currentIndex ?? this.currentIndex,
    activeSeconds: activeSeconds ?? this.activeSeconds,
    studyDay: studyDay,
    scheduleTaskId: scheduleTaskId,
    scheduleBlockId: scheduleBlockId,
    startedAtUtc: startedAtUtc,
    updatedAtUtc: updatedAtUtc ?? DateTime.now().toUtc(),
    completedAtUtc: completedAtUtc ?? this.completedAtUtc,
    items: items ?? this.items,
  );
}

class ReviewScopeFilter {
  const ReviewScopeFilter({
    this.documentId,
    this.planId,
    this.tagId,
    this.query = '',
    this.kind,
    this.mistakesOnly = false,
  });

  final String? documentId;
  final String? planId;
  final String? tagId;
  final String query;
  final ReviewItemKind? kind;
  final bool mistakesOnly;

  Map<String, dynamic> toJson() => {
    'documentId': documentId,
    'planId': planId,
    'tagId': tagId,
    'query': query,
    'kind': kind?.name,
    'mistakesOnly': mistakesOnly,
  };

  factory ReviewScopeFilter.fromJson(Map<String, dynamic> json) =>
      ReviewScopeFilter(
        documentId: json['documentId'] as String?,
        planId: json['planId'] as String?,
        tagId: json['tagId'] as String?,
        query: json['query'] as String? ?? '',
        kind: json['kind'] == null
            ? null
            : ReviewItemKindX.parse(json['kind']),
        mistakesOnly: json['mistakesOnly'] as bool? ?? false,
      );

  static ReviewScopeFilter tryDecode(String raw) {
    try {
      return ReviewScopeFilter.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return const ReviewScopeFilter();
    }
  }
}

class ReviewQueueEntry {
  const ReviewQueueEntry({
    required this.item,
    required this.schedule,
    required this.origins,
    required this.reasonLabel,
    required this.overdueDays,
    required this.priorityScore,
    this.isNew = false,
    this.isDueToday = false,
  });

  final ReviewItem item;
  final ReviewScheduleState schedule;
  final List<ReviewOrigin> origins;
  final String reasonLabel;
  final int overdueDays;
  final double priorityScore;
  final bool isNew;
  final bool isDueToday;

  ReviewOrigin? get primaryOrigin => origins.isEmpty ? null : origins.first;
}

class ReviewDashboardSummary {
  const ReviewDashboardSummary({
    required this.dueCount,
    required this.overdueCount,
    required this.newCount,
    required this.plannedRoundCount,
    required this.plannedConceptCount,
    required this.plannedComplexCount,
    required this.plannedMinutes,
    required this.unscheduledDueCount,
    required this.openChecksCount,
    required this.pendingCandidatesCount,
    required this.mistakesCount,
    required this.totalActiveCount,
    required this.todayCompletedCount,
    required this.todayActiveMinutes,
    this.activeSession,
  });

  final int dueCount;
  final int overdueCount;
  final int newCount;
  final int plannedRoundCount;
  final int plannedConceptCount;
  final int plannedComplexCount;
  final int plannedMinutes;
  final int unscheduledDueCount;
  final int openChecksCount;
  final int pendingCandidatesCount;
  final int mistakesCount;
  final int totalActiveCount;
  final int todayCompletedCount;
  final int todayActiveMinutes;
  final ReviewSession? activeSession;
}

class ReviewDailyTrend {
  const ReviewDailyTrend({
    required this.studyDay,
    required this.completedCount,
    required this.activeSeconds,
    required this.independentSuccessCount,
    required this.independentTotalCount,
  });

  final String studyDay;
  final int completedCount;
  final int activeSeconds;
  final int independentSuccessCount;
  final int independentTotalCount;
}

class KnowledgeEvidenceSummary {
  const KnowledgeEvidenceSummary({
    required this.objective,
    required this.itemCount,
    required this.level,
    required this.independentCrossDayDays,
    required this.lastActivityAt,
  });

  final String objective;
  final int itemCount;
  final KnowledgeEvidenceLevel level;
  final int independentCrossDayDays;
  final DateTime? lastActivityAt;
}

class ReviewStatsSummary {
  const ReviewStatsSummary({
    required this.windowDays,
    required this.totalAttempts,
    required this.independentSampleCount,
    required this.independentSuccessCount,
    required this.assistedCount,
    required this.activeMinutes,
    required this.errorsLogged,
    required this.correctedCount,
    required this.crossDayRedoPassedCount,
    required this.variantPassedCount,
    required this.dailyTrends,
    required this.forecastNext14Days,
    required this.knowledgeEvidence,
    required this.weakObjectives,
  });

  final int windowDays;
  final int totalAttempts;
  final int independentSampleCount;
  final int independentSuccessCount;
  final int assistedCount;
  final int activeMinutes;
  final int errorsLogged;
  final int correctedCount;
  final int crossDayRedoPassedCount;
  final int variantPassedCount;
  final List<ReviewDailyTrend> dailyTrends;
  final Map<String, int> forecastNext14Days;
  final List<KnowledgeEvidenceSummary> knowledgeEvidence;
  final List<String> weakObjectives;

  double? get independentRecallRate => independentSampleCount == 0
      ? null
      : independentSuccessCount / independentSampleCount;
}

class ExamPrepSummary {
  const ExamPrepSummary({
    required this.planId,
    required this.planTitle,
    required this.examDateIso,
    required this.daysRemaining,
    required this.coveredItemCount,
    required this.uncoveredKnowledgeCount,
    required this.dueAndOverdueCount,
    required this.weakItemCount,
    required this.estimatedRequiredMinutes,
    required this.estimatedAvailableMinutes,
    required this.deficitMinutes,
  });

  final String planId;
  final String planTitle;
  final String examDateIso;
  final int daysRemaining;
  final int coveredItemCount;
  final int uncoveredKnowledgeCount;
  final int dueAndOverdueCount;
  final int weakItemCount;
  final int estimatedRequiredMinutes;
  final int estimatedAvailableMinutes;
  final int deficitMinutes;

  bool get hasDeficit => deficitMinutes > 0;
}

class AiQuestionDraft {
  const AiQuestionDraft({
    required this.prompt,
    required this.answer,
    this.kind = ReviewItemKind.concept,
    this.objective = '',
    this.hint = '',
    this.explanation = '',
    this.steps = const [],
    this.sourceDocumentId,
    this.sourceDocumentHash = '',
    this.sourcePage,
    this.sourceExcerpt = '',
    this.validationErrors = const [],
  });

  final String prompt;
  final String answer;
  final ReviewItemKind kind;
  final String objective;
  final String hint;
  final String explanation;
  final List<String> steps;
  final String? sourceDocumentId;
  final String sourceDocumentHash;
  final int? sourcePage;
  final String sourceExcerpt;
  final List<String> validationErrors;

  bool get isValid => validationErrors.isEmpty;
}

class AiReviewSuggestion {
  const AiReviewSuggestion({
    required this.itemRevision,
    required this.answerHash,
    required this.suggestedOutcome,
    required this.rationale,
    this.correctPoints = const [],
    this.missingPoints = const [],
    this.citations = const [],
    required this.createdAtUtc,
  });

  final int itemRevision;
  final String answerHash;
  final ComplexityOutcome suggestedOutcome;
  final String rationale;
  final List<String> correctPoints;
  final List<String> missingPoints;
  final List<String> citations;
  final DateTime createdAtUtc;

  Map<String, dynamic> toJson() => {
    'itemRevision': itemRevision,
    'answerHash': answerHash,
    'suggestedOutcome': suggestedOutcome.name,
    'rationale': rationale,
    'correctPoints': correctPoints,
    'missingPoints': missingPoints,
    'citations': citations,
    'createdAtUtc': createdAtUtc.toIso8601String(),
  };

  factory AiReviewSuggestion.fromJson(Map<String, dynamic> json) =>
      AiReviewSuggestion(
        itemRevision: (json['itemRevision'] as num?)?.toInt() ?? 1,
        answerHash: json['answerHash'] as String? ?? '',
        suggestedOutcome:
            ComplexityOutcomeX.tryParse(json['suggestedOutcome']) ??
            ComplexityOutcome.partial,
        rationale: json['rationale'] as String? ?? '',
        correctPoints: (json['correctPoints'] as List? ?? const [])
            .map((e) => '$e')
            .toList(),
        missingPoints: (json['missingPoints'] as List? ?? const [])
            .map((e) => '$e')
            .toList(),
        citations: (json['citations'] as List? ?? const [])
            .map((e) => '$e')
            .toList(),
        createdAtUtc: json['createdAtUtc'] == null
            ? DateTime.now().toUtc()
            : DateTime.parse(json['createdAtUtc'] as String).toUtc(),
      );
}
