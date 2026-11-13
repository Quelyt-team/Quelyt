import 'dart:math' as math;

import '../models/review_models.dart';
import 'study_time.dart';

/// Locked FSRS v5 memory scheduler (`fsrs-v5-default-19w`) for concepts, short
/// questions, blanks, and image occlusion.
///
/// Mirrors the Open Spaced Repetition FSRS v5 default 19 weights with a target
/// retention of 0.90, explicit short learning/relearning steps, strict UTC
/// timestamps, clock-backwards protection, and optional deterministic fuzz.
class FsrsScheduler {
  const FsrsScheduler({
    this.requestRetention = 0.90,
    this.maximumInterval = 36500,
    this.learningSteps = const [Duration(minutes: 1), Duration(minutes: 10)],
    this.relearningSteps = const [Duration(minutes: 10)],
    this.enableFuzz = false,
  });

  static const String algorithmVersion = 'fsrs-v5-default-19w';

  /// Official FSRS v5 default parameters (w0..w18).
  static const List<double> defaultWeights = [
    0.40255,
    1.18385,
    3.173,
    15.69105,
    7.1949,
    0.5345,
    1.4604,
    0.0046,
    1.54575,
    0.1192,
    1.01925,
    1.9395,
    0.11,
    0.29605,
    2.2698,
    0.2315,
    2.9898,
    0.51655,
    0.6621,
  ];

  final double requestRetention;
  final int maximumInterval;
  final List<Duration> learningSteps;
  final List<Duration> relearningSteps;
  final bool enableFuzz;

  static const double _decay = -0.5;
  static double get _factor => math.pow(0.9, 1 / _decay).toDouble() - 1;

  List<ReviewRatingPreview> previewAll(
    ReviewScheduleState current, {
    required DateTime nowUtc,
    int? seed,
  }) {
    return [
      for (final rating in ReviewRating.values)
        _previewOne(current, rating, nowUtc: nowUtc, seed: seed),
    ];
  }

  ReviewRatingPreview _previewOne(
    ReviewScheduleState current,
    ReviewRating rating, {
    required DateTime nowUtc,
    int? seed,
  }) {
    final next = grade(current, rating, nowUtc: nowUtc, seed: seed);
    return ReviewRatingPreview(
      rating: rating,
      nextState: next,
      intervalLabel: formatInterval(nowUtc, next.algorithmDueAtUtc!),
    );
  }

  ReviewScheduleState grade(
    ReviewScheduleState current,
    ReviewRating rating, {
    required DateTime nowUtc,
    int? seed,
  }) {
    final now = nowUtc.toUtc();
    final elapsedDays = current.state == ReviewCardState.newCard
        ? 0.0
        : StudyTimeHelper.safeElapsedDays(current.lastReviewAtUtc, now);
    final w = defaultWeights;
    final gradeVal = switch (rating) {
      ReviewRating.again => 1,
      ReviewRating.hard => 2,
      ReviewRating.good => 3,
      ReviewRating.easy => 4,
    };

    var stability = current.stability;
    var difficulty = current.difficulty;
    var state = current.state;
    var step = current.step;
    final reps = current.reps + 1;
    var lapses = current.lapses;
    var scheduledDays = 0;
    late DateTime dueAtUtc;

    if (current.state == ReviewCardState.newCard) {
      difficulty = _initDifficulty(gradeVal, w);
      stability = _initStability(gradeVal, w);
      if (rating == ReviewRating.easy || learningSteps.isEmpty) {
        state = ReviewCardState.review;
        step = 0;
        scheduledDays = _nextInterval(stability, elapsedDays, seed: seed);
        dueAtUtc = now.add(Duration(days: scheduledDays));
      } else {
        state = ReviewCardState.learning;
        step = rating == ReviewRating.again ? 0 : (rating == ReviewRating.good ? 1 : 0);
        if (step >= learningSteps.length) {
          state = ReviewCardState.review;
          step = 0;
          scheduledDays = _nextInterval(stability, elapsedDays, seed: seed);
          dueAtUtc = now.add(Duration(days: scheduledDays));
        } else {
          dueAtUtc = now.add(learningSteps[step]);
        }
      }
    } else if (current.state == ReviewCardState.learning ||
        current.state == ReviewCardState.relearning) {
      final steps = current.state == ReviewCardState.learning
          ? learningSteps
          : relearningSteps;
      final prevStability = stability > 0 ? stability : _initStability(gradeVal, w);
      final prevDifficulty = difficulty > 0 ? difficulty : _initDifficulty(gradeVal, w);
      stability = _shortTermStability(prevStability, gradeVal, w);
      difficulty = _nextDifficulty(prevDifficulty, gradeVal, w);

      if (rating == ReviewRating.again) {
        step = 0;
        dueAtUtc = steps.isNotEmpty
            ? now.add(steps[0])
            : now.add(const Duration(minutes: 10));
      } else if (rating == ReviewRating.hard) {
        final idx = math.min(math.max(step, 0), math.max(0, steps.length - 1));
        final dur = steps.isNotEmpty
            ? Duration(
                seconds: math.min(
                  86400,
                  math.max(60, (steps[idx].inSeconds * 1.5).round()),
                ),
              )
            : const Duration(minutes: 15);
        dueAtUtc = now.add(dur);
      } else if (rating == ReviewRating.good) {
        final nextStep = step + 1;
        if (nextStep >= steps.length) {
          state = ReviewCardState.review;
          step = 0;
          scheduledDays = _nextInterval(stability, elapsedDays, seed: seed);
          dueAtUtc = now.add(Duration(days: scheduledDays));
        } else {
          step = nextStep;
          dueAtUtc = now.add(steps[step]);
        }
      } else {
        state = ReviewCardState.review;
        step = 0;
        scheduledDays = _nextInterval(
          math.max(stability, _initStability(4, w)),
          elapsedDays,
          seed: seed,
        );
        dueAtUtc = now.add(Duration(days: scheduledDays));
      }
    } else {
      // Review state.
      final lastS = current.stability > 0 ? current.stability : 1.0;
      final lastD = current.difficulty > 0 ? current.difficulty : 5.0;
      final r = _forgettingCurve(elapsedDays, lastS);
      difficulty = _nextDifficulty(lastD, gradeVal, w);

      if (rating == ReviewRating.again) {
        lapses += 1;
        stability = _nextForgetStability(lastD, lastS, r, w);
        if (relearningSteps.isEmpty) {
          state = ReviewCardState.review;
          step = 0;
          scheduledDays = _nextInterval(stability, elapsedDays, seed: seed);
          dueAtUtc = now.add(Duration(days: scheduledDays));
        } else {
          state = ReviewCardState.relearning;
          step = 0;
          dueAtUtc = now.add(relearningSteps[0]);
        }
      } else {
        stability = _nextRecallStability(lastD, lastS, r, gradeVal, w);
        state = ReviewCardState.review;
        step = 0;
        scheduledDays = _nextInterval(stability, elapsedDays, seed: seed);
        // Keep distinct spacing across Hard <= Good <= Easy when intervals
        // collapse on small stability values.
        if (rating == ReviewRating.easy && scheduledDays <= 1) {
          scheduledDays = math.max(scheduledDays, 2);
        }
        dueAtUtc = now.add(Duration(days: scheduledDays));
      }
    }

    return current.copyWith(
      mode: ReviewScheduleMode.fsrs,
      algorithmVersion: algorithmVersion,
      state: state,
      stability: _round6(stability),
      difficulty: _round6(difficulty),
      elapsedDays: _round6(elapsedDays),
      scheduledDays: scheduledDays,
      reps: reps,
      lapses: lapses,
      step: step,
      algorithmDueAtUtc: dueAtUtc.toUtc(),
      clearDefer: true,
      revision: current.revision + 1,
      lastReviewAtUtc: now,
      updatedAt: now,
    );
  }

  double _initStability(int grade, List<double> w) =>
      math.max(0.1, w[grade - 1]);

  double _initDifficulty(int grade, List<double> w) =>
      (w[4] - math.exp(w[5] * (grade - 1)) + 1).clamp(1.0, 10.0);

  double _forgettingCurve(double elapsedDays, double stability) {
    if (elapsedDays <= 0 || stability <= 0) return 1.0;
    return math.pow(1 + _factor * elapsedDays / stability, _decay).toDouble();
  }

  double _nextDifficulty(double d, int grade, List<double> w) {
    final deltaD = -w[6] * (grade - 3);
    final nextD = d + deltaD * (10.0 - d) / 9.0;
    final meanTarget = _initDifficulty(4, w);
    return (w[7] * meanTarget + (1.0 - w[7]) * nextD).clamp(1.0, 10.0);
  }

  double _shortTermStability(double s, int grade, List<double> w) =>
      math.max(0.1, s * math.exp(w[17] * (grade - 3 + w[18])));

  double _nextRecallStability(
    double d,
    double s,
    double r,
    int grade,
    List<double> w,
  ) {
    final hardPenalty = grade == 2 ? w[15] : 1.0;
    final easyBonus = grade == 4 ? w[16] : 1.0;
    final next =
        s *
        (1 +
            math.exp(w[8]) *
                (11 - d) *
                math.pow(s, -w[9]) *
                (math.exp((1 - r) * w[10]) - 1) *
                hardPenalty *
                easyBonus);
    return math.max(0.1, next);
  }

  double _nextForgetStability(
    double d,
    double s,
    double r,
    List<double> w,
  ) {
    final next =
        w[11] *
        math.pow(d, -w[12]) *
        (math.pow(s + 1, w[13]) - 1) *
        math.exp((1 - r) * w[14]);
    return math.min(next, s).clamp(0.1, maximumInterval.toDouble());
  }

  int _nextInterval(double stability, double elapsedDays, {int? seed}) {
    final raw = (stability / _factor) *
        (math.pow(requestRetention, 1 / _decay) - 1);
    var days = raw.round().clamp(1, maximumInterval);
    if (enableFuzz && days >= 3 && seed != null) {
      final rng = math.Random(seed);
      final delta = math.max(1, (days * 0.05).round());
      final minD = math.max(2, days - delta);
      final maxD = math.min(maximumInterval, days + delta);
      if (maxD > minD) {
        days = minD + rng.nextInt(maxD - minD + 1);
      }
    }
    return days;
  }

  static double _round6(double value) => (value * 1000000).round() / 1000000;

  static String formatInterval(DateTime nowUtc, DateTime dueAtUtc) {
    final diff = dueAtUtc.toUtc().difference(nowUtc.toUtc());
    if (diff.inSeconds < 60) return '1 分钟内';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟';
    if (diff.inHours < 24) return '${diff.inHours} 小时';
    final days = (diff.inHours / 24).round().clamp(1, 36500);
    if (days < 30) return '$days 天';
    if (days < 365) return '${(days / 30).round()} 个月';
    return '${(days / 365).toStringAsFixed(1)} 年';
  }
}
