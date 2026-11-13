import '../models/review_models.dart';

class LocalRuleCheckResult {
  const LocalRuleCheckResult({
    required this.decided,
    required this.isCorrect,
    required this.explanation,
  });

  final bool decided;
  final bool isCorrect;
  final String explanation;
}

/// Objective rule-based local grading helper.
///
/// Only unambiguous formats (single-choice option indices and concise exact-slot
/// fill-in-the-blank tokens) are evaluated locally. Units, mathematical formulas,
/// derivations and open-ended wording differences are never auto-marked wrong.
class ReviewAnswerEvaluator {
  const ReviewAnswerEvaluator._();

  static LocalRuleCheckResult evaluateChoice({
    required ReviewItem item,
    required int? selectedIndex,
  }) {
    final expected = item.correctChoiceIndex;
    if (item.choices.isEmpty ||
        expected == null ||
        expected < 0 ||
        expected >= item.choices.length ||
        selectedIndex == null) {
      return const LocalRuleCheckResult(
        decided: false,
        isCorrect: false,
        explanation: '此题需要结合解析人工核对。',
      );
    }
    final ok = selectedIndex == expected;
    return LocalRuleCheckResult(
      decided: true,
      isCorrect: ok,
      explanation: ok
          ? '选择正确（${_choiceLetter(expected)}）。'
          : '所选为 ${_choiceLetter(selectedIndex)}，参考选项为 ${_choiceLetter(expected)}。',
    );
  }

  static LocalRuleCheckResult evaluateBlanks({
    required ReviewItem item,
    required List<String> userBlanks,
  }) {
    if (item.kind != ReviewItemKind.blank || item.blankAnswers.isEmpty) {
      return const LocalRuleCheckResult(
        decided: false,
        isCorrect: false,
        explanation: '非明确分空答案，请对照参考解析自评。',
      );
    }
    // Formulas / multi-word explanations are NOT evaluated by naive equality.
    for (final expected in item.blankAnswers) {
      if (_looksLikeFormulaOrLongPhrase(expected)) {
        return const LocalRuleCheckResult(
          decided: false,
          isCorrect: false,
          explanation: '包含公式、单位或较长表述，为避免等价表述误判，请核对参考答案后自评。',
        );
      }
    }
    if (userBlanks.length != item.blankAnswers.length) {
      return const LocalRuleCheckResult(
        decided: false,
        isCorrect: false,
        explanation: '空位数量不一致，请人工核对。',
      );
    }
    var allMatch = true;
    for (var i = 0; i < item.blankAnswers.length; i++) {
      if (_normalizeToken(userBlanks[i]) !=
          _normalizeToken(item.blankAnswers[i])) {
        allMatch = false;
        break;
      }
    }
    return LocalRuleCheckResult(
      decided: true,
      isCorrect: allMatch,
      explanation: allMatch
          ? '全部 ${item.blankAnswers.length} 个术语空位与参考答案一致。'
          : '部分空位与参考术语有差异，请核对解析确认是否等价。',
    );
  }

  static bool _looksLikeFormulaOrLongPhrase(String text) {
    final trimmed = text.trim();
    if (trimmed.length > 24 || trimmed.contains(' ') && trimmed.split(' ').length > 3) {
      return true;
    }
    return RegExp(r'[=+\-*/^_{}\\]').hasMatch(trimmed);
  }

  static String _normalizeToken(String raw) => raw
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll('（', '(')
      .replaceAll('）', ')');

  static String _choiceLetter(int index) =>
      String.fromCharCode('A'.codeUnitAt(0) + index);
}
