enum LessonStatus { draft, ready, failed }

/// A local draft answer for one exercise. It is not a learning record; it only
/// preserves what the user typed and whether the solution was revealed.
class LessonDraft {
  const LessonDraft({
    required this.exerciseId,
    this.answer = '',
    this.revealed = false,
    this.selfCheck = '',
  });

  final String exerciseId;
  final String answer;
  final bool revealed;

  /// '', 'correct' or 'review'.
  final String selfCheck;

  LessonDraft copyWith({
    String? answer,
    bool? revealed,
    String? selfCheck,
  }) => LessonDraft(
    exerciseId: exerciseId,
    answer: answer ?? this.answer,
    revealed: revealed ?? this.revealed,
    selfCheck: selfCheck ?? this.selfCheck,
  );

  Map<String, dynamic> toJson() => {
    'exerciseId': exerciseId,
    'answer': answer,
    'revealed': revealed,
    'selfCheck': selfCheck,
  };

  factory LessonDraft.fromJson(Map<String, dynamic> json) => LessonDraft(
    exerciseId: json['exerciseId'] as String,
    answer: json['answer'] as String? ?? '',
    revealed: json['revealed'] as bool? ?? false,
    selfCheck: json['selfCheck'] as String? ?? '',
  );
}

class LessonSection {
  const LessonSection({
    required this.title,
    required this.body,
    this.sourcePage,
  });

  final String title;
  final String body;
  final int? sourcePage;

  Map<String, dynamic> toJson() => {
    'title': title,
    'body': body,
    'sourcePage': sourcePage,
  };

  factory LessonSection.fromJson(Map<String, dynamic> json) => LessonSection(
    title: json['title'] as String,
    body: json['body'] as String,
    sourcePage: (json['sourcePage'] as num?)?.toInt(),
  );
}

class LessonExercise {
  const LessonExercise({
    required this.id,
    required this.prompt,
    required this.answer,
    required this.solution,
    this.sourcePage,
  });
  final String id;
  final String prompt;
  final String answer;
  final String solution;
  final int? sourcePage;

  Map<String, dynamic> toJson() => {
    'id': id,
    'prompt': prompt,
    'answer': answer,
    'solution': solution,
    'sourcePage': sourcePage,
  };

  factory LessonExercise.fromJson(Map<String, dynamic> json) => LessonExercise(
    id: json['id'] as String,
    prompt: json['prompt'] as String,
    answer: json['answer'] as String,
    solution: json['solution'] as String,
    sourcePage: (json['sourcePage'] as num?)?.toInt(),
  );
}

/// A versioned daily lesson generated for one task. Answers and solutions are
/// stored separately from prompts so the UI can require an attempt first.
class DailyLesson {
  DailyLesson({
    required this.id,
    required this.taskId,
    required this.planId,
    required this.title,
    required this.objective,
    required this.sections,
    required this.exercises,
    this.materialDocumentId,
    this.materialHash,
    this.startPage,
    this.endPage,
    this.model = '',
    this.templateVersion = 'lesson-v1',
    this.status = LessonStatus.ready,
    this.version = 1,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? createdAt ?? DateTime.now() {
    if (id.isEmpty || taskId.isEmpty) {
      throw ArgumentError('Lesson needs an id and a task.');
    }
    if (title.trim().isEmpty || objective.trim().isEmpty) {
      throw ArgumentError('Lesson needs a title and objective.');
    }
    if (sections.isEmpty || exercises.isEmpty) {
      throw ArgumentError('A ready lesson needs sections and exercises.');
    }
    for (final exercise in exercises) {
      if (exercise.id.isEmpty ||
          exercise.prompt.trim().isEmpty ||
          exercise.answer.trim().isEmpty ||
          exercise.solution.trim().isEmpty) {
        throw ArgumentError('Exercise is missing a prompt, answer or solution.');
      }
    }
    if (exercises.map((exercise) => exercise.id).toSet().length !=
        exercises.length) {
      throw ArgumentError('Exercise ids must be unique.');
    }
  }

  final String id;
  final String taskId;
  final String planId;
  final String title;
  final String objective;
  final List<LessonSection> sections;
  final List<LessonExercise> exercises;
  final String? materialDocumentId;
  final String? materialHash;
  final int? startPage;
  final int? endPage;
  final String model;
  final String templateVersion;
  final LessonStatus status;
  final int version;
  final DateTime createdAt;
  final DateTime updatedAt;

  String? get sourceRangeLabel => startPage == null
      ? null
      : startPage == endPage
      ? '第 $startPage 页'
      : '第 $startPage–$endPage 页';

  DailyLesson copyWith({
    String? id,
    String? taskId,
    String? planId,
    String? title,
    String? objective,
    List<LessonSection>? sections,
    List<LessonExercise>? exercises,
    String? materialDocumentId,
    String? materialHash,
    int? startPage,
    int? endPage,
    String? model,
    String? templateVersion,
    LessonStatus? status,
    int? version,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => DailyLesson(
    id: id ?? this.id,
    taskId: taskId ?? this.taskId,
    planId: planId ?? this.planId,
    title: title ?? this.title,
    objective: objective ?? this.objective,
    sections: sections ?? this.sections,
    exercises: exercises ?? this.exercises,
    materialDocumentId: materialDocumentId ?? this.materialDocumentId,
    materialHash: materialHash ?? this.materialHash,
    startPage: startPage ?? this.startPage,
    endPage: endPage ?? this.endPage,
    model: model ?? this.model,
    templateVersion: templateVersion ?? this.templateVersion,
    status: status ?? this.status,
    version: version ?? this.version,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'taskId': taskId,
    'planId': planId,
    'title': title,
    'objective': objective,
    'sections': sections.map((section) => section.toJson()).toList(),
    'exercises': exercises.map((exercise) => exercise.toJson()).toList(),
    'materialDocumentId': materialDocumentId,
    'materialHash': materialHash,
    'startPage': startPage,
    'endPage': endPage,
    'model': model,
    'templateVersion': templateVersion,
    'status': status.name,
    'version': version,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory DailyLesson.fromJson(Map<String, dynamic> json) => DailyLesson(
    id: json['id'] as String,
    taskId: json['taskId'] as String,
    planId: json['planId'] as String,
    title: json['title'] as String,
    objective: json['objective'] as String,
    sections: (json['sections'] as List<Object?>? ?? const [])
        .map(
          (value) => LessonSection.fromJson(
            Map<String, dynamic>.from(value as Map),
          ),
        )
        .toList(growable: false),
    exercises: (json['exercises'] as List<Object?>? ?? const [])
        .map(
          (value) => LessonExercise.fromJson(
            Map<String, dynamic>.from(value as Map),
          ),
        )
        .toList(growable: false),
    materialDocumentId: json['materialDocumentId'] as String?,
    materialHash: json['materialHash'] as String?,
    startPage: (json['startPage'] as num?)?.toInt(),
    endPage: (json['endPage'] as num?)?.toInt(),
    model: json['model'] as String? ?? '',
    templateVersion: json['templateVersion'] as String? ?? 'lesson-v1',
    status: LessonStatus.values.byName(json['status'] as String? ?? 'ready'),
    version: (json['version'] as num?)?.toInt() ?? 1,
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );
}
