import '../models/review_models.dart';
import 'study_time.dart';

/// Explainable step-based scheduler for calculation, derivation, and
/// comprehensive application exercises (`training-rule-v1`).
class TrainingScheduler {
  const TrainingScheduler({this.repeatFailureThreshold = 3});

  static const String algorithmVersion = 'training-rule-v1';

  final int repeatFailureThreshold;

  ReviewScheduleState schedule({
    required ReviewScheduleState current,
    required ReviewItem item,
    required ComplexityOutcome outcome,
    required bool usedAssistance,
    required DateTime nowUtc,
    String timezone = StudyTimeHelper.defaultTimezone,
  }) {
    final now = nowUtc.toUtc();
    final elapsedDays = StudyTimeHelper.safeElapsedDays(
      current.lastReviewAtUtc,
      now,
    );

    if (outcome == ComplexityOutcome.disputed) {
      return current.copyWith(
        mode: ReviewScheduleMode.training,
        algorithmVersion: algorithmVersion,
        elapsedDays: elapsedDays,
        paused: current.paused,
        trainingStage: 'disputed_hold',
        revision: current.revision + 1,
        updatedAt: now,
      );
    }

    var scheduledDays = 1;
    var state = ReviewCardState.learning;
    var stage = current.trainingStage;
    final reps = current.reps + 1;
    var lapses = current.lapses;

    if (outcome == ComplexityOutcome.incomplete) {
      lapses += 1;
      scheduledDays = 1;
      state = ReviewCardState.relearning;
      stage = 'needs_correction';
    } else if (outcome == ComplexityOutcome.partial || usedAssistance) {
      scheduledDays = 1;
      state = ReviewCardState.learning;
      stage = 'assisted_reverify';
    } else {
      // Independent correct without assistance!
      final isVariant = item.variantParentId != null ||
          item.kind == ReviewItemKind.application;
      final wasPriorDay = current.lastReviewAtUtc != null &&
          StudyTimeHelper.studyDayKey(current.lastReviewAtUtc!, timezone: timezone) !=
              StudyTimeHelper.studyDayKey(now, timezone: timezone);

      if (current.trainingStage == 'mixed_14d' || current.scheduledDays >= 7) {
        scheduledDays = 14;
        state = ReviewCardState.review;
        stage = 'mixed_14d';
      } else if (isVariant ||
          current.trainingStage == 'variant_3d' ||
          item.crossDayRedoPassed) {
        scheduledDays = 7;
        state = ReviewCardState.review;
        stage = 'mixed_7d';
      } else if (wasPriorDay || current.reps == 0) {
        scheduledDays = 3;
        state = ReviewCardState.review;
        stage = 'variant_3d';
      } else {
        scheduledDays = 1;
        state = ReviewCardState.learning;
        stage = 'same_day_verified';
      }
    }

    final targetDate = StudyTimeHelper.studyDate(
      now,
      timezone: timezone,
    ).addDays(scheduledDays);
    final dueUtc = StudyTimeHelper.studyDayStartUtc(
      targetDate,
      timezone: timezone,
    );

    return current.copyWith(
      mode: ReviewScheduleMode.training,
      algorithmVersion: algorithmVersion,
      state: state,
      elapsedDays: elapsedDays,
      scheduledDays: scheduledDays,
      reps: reps,
      lapses: lapses,
      trainingStage: stage,
      algorithmDueAtUtc: dueUtc,
      clearDefer: true,
      revision: current.revision + 1,
      lastReviewAtUtc: now,
      updatedAt: now,
    );
  }

  String explainOutcome({
    required ReviewItem item,
    required ComplexityOutcome outcome,
    required bool usedAssistance,
    required ReviewScheduleState nextState,
  }) {
    if (outcome == ComplexityOutcome.disputed) {
      return '参考答案或评语存在争议，已转入待核对列表，暂不顺延间隔。';
    }
    if (outcome == ComplexityOutcome.incomplete) {
      if (item.wrongStreak + 1 >= repeatFailureThreshold) {
        return '连续 ${item.wrongStreak + 1} 次未独立完成：建议回看教材原文、拆解前置概念或修改题面。';
      }
      return '当场完成订正后，建议下一学习日（约 1 天后）重新独立作答。';
    }
    if (outcome == ComplexityOutcome.partial || usedAssistance) {
      return '已记录辅助/部分完成情况，约 1 天后再独立验证一次。';
    }
    if (nextState.scheduledDays >= 14) {
      return '变式与混合应用均已通过，建议 14 天后抽检巩固。';
    }
    if (nextState.scheduledDays >= 7) {
      return '变式独立完成，建议 7 天后纳入综合混合练习。';
    }
    if (nextState.scheduledDays >= 3) {
      return '首次跨日独立正确：建议 3 天后完成一道条件不同的同目标变式题。';
    }
    return '同日巩固完成，建议 1 天后跨日独立重做验证记忆稳定度。';
  }
}
