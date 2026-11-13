import 'dart:convert';

import '../../../services/ai_gateway.dart';
import '../data/review_repository.dart';
import '../models/review_models.dart';

/// Structured AI draft generation and rubric-based review grading.
///
/// Reuses [AiGateway.prepare] / [AiGateway.send] so credential isolation,
/// HTTPS validation, request previews, and user cancellation guarantees remain
/// identical across the app. Stale responses after editing or moving to another
/// answer revision are rejected via [itemRevision] & [answerHash].
class ReviewAiService {
  const ReviewAiService({required this.gateway});

  final AiGateway gateway;

  PreparedAiRequest prepareQuestionDrafts({
    required ProviderSettings settings,
    required String objective,
    required ReviewItemKind kind,
    required int count,
    required List<AiEvidence> evidence,
    String sourceNoteText = '',
  }) {
    final boundedCount = count.clamp(1, 5);
    final instruction = '''
请围绕学习目标“$objective”生成 $boundedCount 道「${kind.label}」复习草案（默认少量精炼，不要把长笔记整段塞成一题）。
要求只返回 JSON 数组（不要 markdown 代码块以外的多余废话），每项字段：
{
  "prompt": "清晰简短的问题",
  "answer": "明确参考答案",
  "hint": "可选提示",
  "explanation": "简明解析与依据",
  "steps": ["关键步骤1", "关键步骤2"],
  "objective": "$objective",
  "kind": "${kind.name}",
  "source_page": 页码整数或null
}
${sourceNoteText.trim().isEmpty ? '' : '\n补充学习笔记上下文（非教材原文）：\n${sourceNoteText.trim()}'}
''';
    return gateway.prepare(
      settings: settings,
      task: AiTask.generateQuestion,
      question: instruction,
      evidence: evidence,
      coverageNote: evidence.isEmpty ? '无指定教材页段证据' : null,
      maxOutputTokens: 1600,
    );
  }

  List<AiQuestionDraft> parseAndValidateDrafts(
    String rawText, {
    required Map<int, AiEvidence> evidenceByPage,
  }) {
    final cleaned = _extractJsonArray(rawText);
    if (cleaned == null) return const [];
    final list = jsonDecode(cleaned);
    if (list is! List) return const [];

    final drafts = <AiQuestionDraft>[];
    for (final raw in list.take(5)) {
      if (raw is! Map) continue;
      final map = Map<String, dynamic>.from(raw);
      final prompt = (map['prompt'] as String? ?? '').trim();
      final answer = (map['answer'] as String? ?? '').trim();
      final hint = (map['hint'] as String? ?? '').trim();
      final explanation = (map['explanation'] as String? ?? '').trim();
      final objective = (map['objective'] as String? ?? '').trim();
      final steps = (map['steps'] as List? ?? const [])
          .map((e) => '$e'.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      final kind = ReviewItemKindX.parse(map['kind']);
      final page = (map['source_page'] as num?)?.toInt();
      final matchedEvidence = page == null ? null : evidenceByPage[page];

      final errors = <String>[];
      if (prompt.isEmpty) errors.add('缺少题干');
      if (answer.isEmpty) errors.add('缺少参考答案');
      if (prompt.length > 600) errors.add('题干过长，请拆分');
      if (evidenceByPage.isNotEmpty && matchedEvidence == null) {
        errors.add('未核验到对应的教材页码引用');
      }

      drafts.add(
        AiQuestionDraft(
          prompt: prompt,
          answer: answer,
          kind: kind,
          objective: objective,
          hint: hint,
          explanation: explanation,
          steps: steps,
          sourceDocumentId: matchedEvidence?.documentId,
          sourceDocumentHash: matchedEvidence?.documentHash ?? '',
          sourcePage: matchedEvidence?.page ?? page,
          sourceExcerpt: matchedEvidence?.text ?? '',
          validationErrors: errors,
        ),
      );
    }
    return drafts;
  }

  PreparedAiRequest prepareAnswerReview({
    required ProviderSettings settings,
    required ReviewItem item,
    required String learnerAnswer,
    required List<AiEvidence> evidence,
  }) {
    final prompt = '''
请对照题目与参考答案评阅学习者作答，不要因措辞不同而强制判错。
题目：${item.prompt}
参考答案：${item.answer}
${item.steps.isEmpty ? '' : '评分要点：${item.steps.join('；')}'}
只返回严格 JSON：
{
  "suggested_outcome": "independentCorrect" | "partial" | "incomplete" | "disputed",
  "correct_points": ["做对的要点"],
  "missing_points": ["遗漏或偏差条件"],
  "rationale": "评阅理由与依据",
  "citations": ["出处页码或原文摘要"]
}
''';
    return gateway.prepare(
      settings: settings,
      task: AiTask.gradeAnswer,
      question: prompt,
      learnerAnswer: learnerAnswer,
      evidence: evidence,
      maxOutputTokens: 1200,
    );
  }

  AiReviewSuggestion parseReviewSuggestion({
    required String rawText,
    required int expectedItemRevision,
    required String expectedAnswerHash,
  }) {
    final jsonText = _extractJsonObject(rawText);
    if (jsonText != null) {
      try {
        final decoded = Map<String, dynamic>.from(jsonDecode(jsonText) as Map);
        return AiReviewSuggestion(
          itemRevision: expectedItemRevision,
          answerHash: expectedAnswerHash,
          suggestedOutcome:
              ComplexityOutcomeX.tryParse(decoded['suggested_outcome']) ??
              ComplexityOutcome.partial,
          rationale: (decoded['rationale'] as String? ?? rawText).trim(),
          correctPoints: (decoded['correct_points'] as List? ?? const [])
              .map((e) => '$e')
              .toList(),
          missingPoints: (decoded['missing_points'] as List? ?? const [])
              .map((e) => '$e')
              .toList(),
          citations: (decoded['citations'] as List? ?? const [])
              .map((e) => '$e')
              .toList(),
          createdAtUtc: DateTime.now().toUtc(),
        );
      } catch (_) {
        // Fall through to plain-text suggestion when model does not emit JSON.
      }
    }
    return AiReviewSuggestion(
      itemRevision: expectedItemRevision,
      answerHash: expectedAnswerHash,
      suggestedOutcome: ComplexityOutcome.partial,
      rationale: rawText.trim(),
      createdAtUtc: DateTime.now().toUtc(),
    );
  }

  bool isSuggestionFresh({
    required AiReviewSuggestion suggestion,
    required ReviewItem currentItem,
    required String currentAnswerText,
  }) {
    return suggestion.itemRevision == currentItem.revision &&
        suggestion.answerHash == ReviewRepository.hashAnswer(currentAnswerText);
  }

  static String? _extractJsonArray(String text) {
    final start = text.indexOf('[');
    final end = text.lastIndexOf(']');
    if (start == -1 || end <= start) return null;
    return text.substring(start, end + 1);
  }

  static String? _extractJsonObject(String text) {
    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start == -1 || end <= start) return null;
    return text.substring(start, end + 1);
  }
}
