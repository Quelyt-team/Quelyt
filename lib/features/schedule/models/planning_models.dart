import '../../../services/ai_types.dart';
import 'local_date.dart';
import 'plan_availability.dart';
import 'study_plan.dart';

enum PlanningKind {
  text,
  clarification,
  proposal,
  answer,
  insufficientMaterial,
  error,
  cancelled,
}

extension PlanningKindLabel on PlanningKind {
  String get label => switch (this) {
    PlanningKind.text => '对话',
    PlanningKind.clarification => '需要补充信息',
    PlanningKind.proposal => '排期草案',
    PlanningKind.answer => '说明',
    PlanningKind.insufficientMaterial => '缺少资料',
    PlanningKind.error => '未完成',
    PlanningKind.cancelled => '已取消',
  };
}

enum PlanningRole { user, assistant }

class PlanningConversation {
  PlanningConversation({
    required this.id,
    this.planId,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String? planId;
  final DateTime createdAt;
  final DateTime updatedAt;

  PlanningConversation copyWith({
    String? id,
    String? planId,
    bool clearPlan = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => PlanningConversation(
    id: id ?? this.id,
    planId: clearPlan ? null : planId ?? this.planId,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'planId': planId,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory PlanningConversation.fromJson(Map<String, dynamic> json) =>
      PlanningConversation(
        id: json['id'] as String,
        planId: json['planId'] as String?,
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
      );
}

class PlanningQuestion {
  const PlanningQuestion({
    required this.field,
    required this.question,
    this.options = const [],
  });

  final String field;
  final String question;
  final List<String> options;

  Map<String, dynamic> toJson() => {
    'field': field,
    'question': question,
    'options': options,
  };

  factory PlanningQuestion.fromJson(Map<String, dynamic> json) =>
      PlanningQuestion(
        field: json['field'] as String,
        question: json['question'] as String,
        options: [
          for (final value in (json['options'] as List? ?? const []))
            value as String,
        ],
      );
}

/// A proposed change to a plan's framework, not to the formal calendar.
///
/// Every field is optional so a conversation can update only the exam date or
/// only the weekly availability. The user still confirms before it is saved.
class PlanningProposal {
  PlanningProposal({
    this.planId,
    this.title,
    this.subject,
    this.goal,
    this.startDate,
    this.endDate,
    this.examDate,
    this.mode,
    this.availability,
    List<String> assumptions = const [],
    List<String> unsupported = const [],
  }) : assumptions = List.unmodifiable(assumptions),
       unsupported = List.unmodifiable(unsupported);

  final String? planId;
  final String? title;
  final String? subject;
  final String? goal;
  final LocalDate? startDate;
  final LocalDate? endDate;
  final LocalDate? examDate;
  final StudyMode? mode;
  final PlanAvailability? availability;
  final List<String> assumptions;
  final List<String> unsupported;

  bool get hasChanges =>
      title != null ||
      subject != null ||
      goal != null ||
      startDate != null ||
      endDate != null ||
      examDate != null ||
      mode != null ||
      availability != null;

  bool get changesPlan =>
      title != null ||
      subject != null ||
      goal != null ||
      startDate != null ||
      endDate != null ||
      examDate != null ||
      mode != null;

  List<String> summaryLines(StudyPlan? existing) {
    final lines = <String>[];
    final name = title ?? existing?.title;
    final subjectValue = subject ?? existing?.subject;
    if (name != null && name.trim().isNotEmpty) {
      lines.add(
        '计划：$name${subjectValue == null || subjectValue.trim().isEmpty ? '' : ' · $subjectValue'}',
      );
    }
    final start = startDate ?? existing?.startDate;
    final end = endDate ?? existing?.endDate;
    if (start != null && end != null) {
      lines.add('日期：${start.shortLabel}–${end.shortLabel}');
    }
    final exam = examDate ?? existing?.examDate;
    if (exam != null) lines.add('考试：${exam.longLabel}');
    if (availability != null || startDate != null) {
      final value = availability;
      if (value != null) {
        final days = value.weekly.map((slot) => slot.weekday).toSet();
        final dayLabel = days.isEmpty
            ? '未设置'
            : '星期${days.map((day) => const ['一', '二', '三', '四', '五', '六', '日'][day - 1]).join('、')}';
        lines.add('每周可用：$dayLabel，每日上限 ${value.dailyCapMinutes} 分钟');
      }
    }
    lines.addAll(assumptions.map((item) => '假设：$item'));
    lines.addAll(unsupported.map((item) => '未覆盖：$item'));
    return lines;
  }

  Map<String, dynamic> toJson() => {
    'planId': planId,
    'title': title,
    'subject': subject,
    'goal': goal,
    'startDate': startDate?.iso,
    'endDate': endDate?.iso,
    'examDate': examDate?.iso,
    'mode': mode?.name,
    'availability': availability?.toJson(),
    'assumptions': assumptions,
    'unsupported': unsupported,
  };

  factory PlanningProposal.fromJson(Map<String, dynamic> json) =>
      PlanningProposal(
        planId: json['planId'] as String?,
        title: json['title'] as String?,
        subject: json['subject'] as String?,
        goal: json['goal'] as String?,
        startDate: json['startDate'] == null
            ? null
            : LocalDate.parse(json['startDate'] as String),
        endDate: json['endDate'] == null
            ? null
            : LocalDate.parse(json['endDate'] as String),
        examDate: json['examDate'] == null
            ? null
            : LocalDate.parse(json['examDate'] as String),
        mode: json['mode'] == null
            ? null
            : StudyMode.values.byName(json['mode'] as String),
        availability: json['availability'] == null
            ? null
            : PlanAvailability.fromJson(
                Map<String, dynamic>.from(json['availability'] as Map),
              ),
        assumptions: [
          for (final value in (json['assumptions'] as List? ?? const []))
            value as String,
        ],
        unsupported: [
          for (final value in (json['unsupported'] as List? ?? const []))
            value as String,
        ],
      );
}

class PlanningReply {
  PlanningReply({
    required this.kind,
    required this.message,
    List<PlanningQuestion> questions = const [],
    this.proposal,
    List<String> missingMaterial = const [],
  }) : questions = List.unmodifiable(questions),
       missingMaterial = List.unmodifiable(missingMaterial);

  final PlanningKind kind;
  final String message;
  final List<PlanningQuestion> questions;
  final PlanningProposal? proposal;
  final List<String> missingMaterial;

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    'message': message,
    'questions': [for (final question in questions) question.toJson()],
    'proposal': proposal?.toJson(),
    'missingMaterial': missingMaterial,
  };

  factory PlanningReply.fromJson(Map<String, dynamic> json) => PlanningReply(
    kind: PlanningKind.values.byName(json['kind'] as String),
    message: json['message'] as String,
    questions: [
      for (final value in (json['questions'] as List? ?? const []))
        PlanningQuestion.fromJson(Map<String, dynamic>.from(value as Map)),
    ],
    proposal: json['proposal'] == null
        ? null
        : PlanningProposal.fromJson(
            Map<String, dynamic>.from(json['proposal'] as Map),
          ),
    missingMaterial: [
      for (final value in (json['missingMaterial'] as List? ?? const []))
        value as String,
    ],
  );
}

class PlanningMessage {
  PlanningMessage({
    required this.id,
    required this.conversationId,
    required this.sequence,
    required this.role,
    required this.kind,
    required this.text,
    required this.createdAt,
    this.requestId,
    this.proposal,
    List<PlanningQuestion> questions = const [],
    this.model,
    this.usage,
    this.failed = false,
    this.applied = false,
    List<String> missingMaterial = const [],
  }) : questions = List.unmodifiable(questions),
       missingMaterial = List.unmodifiable(missingMaterial);

  final String id;
  final String conversationId;
  final int sequence;
  final PlanningRole role;
  final PlanningKind kind;
  final String text;
  final DateTime createdAt;
  final String? requestId;
  final PlanningProposal? proposal;
  final List<PlanningQuestion> questions;
  final String? model;
  final TokenUsage? usage;
  final bool failed;
  final bool applied;
  final List<String> missingMaterial;

  PlanningMessage copyWith({
    String? id,
    String? conversationId,
    int? sequence,
    PlanningRole? role,
    PlanningKind? kind,
    String? text,
    DateTime? createdAt,
    String? requestId,
    PlanningProposal? proposal,
    bool clearProposal = false,
    List<PlanningQuestion>? questions,
    String? model,
    TokenUsage? usage,
    bool? failed,
    bool? applied,
    List<String>? missingMaterial,
  }) => PlanningMessage(
    id: id ?? this.id,
    conversationId: conversationId ?? this.conversationId,
    sequence: sequence ?? this.sequence,
    role: role ?? this.role,
    kind: kind ?? this.kind,
    text: text ?? this.text,
    createdAt: createdAt ?? this.createdAt,
    requestId: requestId ?? this.requestId,
    proposal: clearProposal ? null : proposal ?? this.proposal,
    questions: questions ?? this.questions,
    model: model ?? this.model,
    usage: usage ?? this.usage,
    failed: failed ?? this.failed,
    applied: applied ?? this.applied,
    missingMaterial: missingMaterial ?? this.missingMaterial,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'conversationId': conversationId,
    'sequence': sequence,
    'role': role.name,
    'kind': kind.name,
    'text': text,
    'createdAt': createdAt.toIso8601String(),
    'requestId': requestId,
    'proposal': proposal?.toJson(),
    'questions': [for (final question in questions) question.toJson()],
    'model': model,
    'usage': usage?.toJson(),
    'failed': failed,
    'applied': applied,
    'missingMaterial': missingMaterial,
  };

  factory PlanningMessage.fromJson(Map<String, dynamic> json) => PlanningMessage(
    id: json['id'] as String,
    conversationId: json['conversationId'] as String,
    sequence: (json['sequence'] as num).toInt(),
    role: PlanningRole.values.byName(json['role'] as String),
    kind: PlanningKind.values.byName(json['kind'] as String),
    text: json['text'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    requestId: json['requestId'] as String?,
    proposal: json['proposal'] == null
        ? null
        : PlanningProposal.fromJson(
            Map<String, dynamic>.from(json['proposal'] as Map),
          ),
    questions: [
      for (final value in (json['questions'] as List? ?? const []))
        PlanningQuestion.fromJson(Map<String, dynamic>.from(value as Map)),
    ],
    model: json['model'] as String?,
    usage: json['usage'] == null
        ? null
        : TokenUsage.fromJson(Map<String, dynamic>.from(json['usage'] as Map)),
    failed: json['failed'] as bool? ?? false,
    applied: json['applied'] as bool? ?? false,
    missingMaterial: [
      for (final value in (json['missingMaterial'] as List? ?? const []))
        value as String,
    ],
  );
}
