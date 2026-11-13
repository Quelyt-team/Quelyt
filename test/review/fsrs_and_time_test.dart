import 'package:flutter_test/flutter_test.dart';
import 'package:local_study/features/review/models/review_models.dart';
import 'package:local_study/features/review/services/fsrs_scheduler.dart';
import 'package:local_study/features/review/services/review_answer_evaluator.dart';
import 'package:local_study/features/review/services/study_time.dart';
import 'package:local_study/features/review/services/training_scheduler.dart';
import 'package:local_study/features/schedule/models/local_date.dart';

void main() {
  group('FSRS v5 scheduler invariants', () {
    const scheduler = FsrsScheduler();
    final t0 = DateTime.utc(2026, 11, 1, 2, 0);

    test('uses locked FSRS v5 algorithm version, retention 0.90, and 19 weights', () {
      expect(FsrsScheduler.algorithmVersion, 'fsrs-v5-default-19w');
      expect(scheduler.requestRetention, 0.90);
      expect(FsrsScheduler.defaultWeights, hasLength(19));
    });

    test('ratings yield monotonic intervals and preview equals commit', () {
      final initial = ReviewScheduleState(
        itemId: 'card-1',
        state: ReviewCardState.newCard,
      );
      final previews = scheduler.previewAll(initial, nowUtc: t0, seed: 42);
      expect(previews, hasLength(4));

      final dueTimes = [
        for (final p in previews) p.nextState.algorithmDueAtUtc!,
      ];
      for (var i = 0; i < dueTimes.length - 1; i++) {
        expect(
          dueTimes[i].millisecondsSinceEpoch <=
              dueTimes[i + 1].millisecondsSinceEpoch,
          isTrue,
          reason: 'Rating ${previews[i].rating} due should not exceed ${previews[i + 1].rating}',
        );
      }

      for (final p in previews) {
        final committed = scheduler.grade(
          initial,
          p.rating,
          nowUtc: t0,
          seed: 42,
        );
        expect(committed.algorithmDueAtUtc, p.nextState.algorithmDueAtUtc);
        expect(committed.stability, closeTo(p.nextState.stability, 1e-9));
        expect(committed.difficulty, closeTo(p.nextState.difficulty, 1e-9));
        expect(committed.scheduledDays, p.nextState.scheduledDays);
      }
    });

    test('deterministic fuzz returns identical interval for same seed within bounds', () {
      const fuzzScheduler = FsrsScheduler(enableFuzz: true, maximumInterval: 180);
      final reviewed = ReviewScheduleState(
        itemId: 'card-2',
        state: ReviewCardState.review,
        stability: 20.0,
        difficulty: 5.0,
        reps: 4,
        lapses: 0,
        lastReviewAtUtc: t0.subtract(const Duration(days: 20)),
        algorithmDueAtUtc: t0,
      );

      final a = fuzzScheduler.grade(
        reviewed,
        ReviewRating.good,
        nowUtc: t0,
        seed: 991,
      );
      final b = fuzzScheduler.grade(
        reviewed,
        ReviewRating.good,
        nowUtc: t0,
        seed: 991,
      );
      expect(a.scheduledDays, b.scheduledDays);
      expect(a.scheduledDays, inInclusiveRange(1, 180));
    });

    test('protects against backwards device clock (elapsedDays >= 0, finite state)', () {
      final futureLastReview = t0.add(const Duration(days: 5));
      final corruptedClockState = ReviewScheduleState(
        itemId: 'card-clock',
        state: ReviewCardState.review,
        stability: 10.0,
        difficulty: 5.2,
        reps: 2,
        lastReviewAtUtc: futureLastReview,
        algorithmDueAtUtc: futureLastReview.add(const Duration(days: 10)),
      );

      final next = scheduler.grade(
        corruptedClockState,
        ReviewRating.good,
        nowUtc: t0,
      );
      expect(next.elapsedDays, 0.0);
      expect(next.stability.isFinite, isTrue);
      expect(next.stability, greaterThan(0));
      expect(next.difficulty.isFinite, isTrue);
      expect(next.scheduledDays, greaterThanOrEqualTo(1));
    });
  });

  group('StudyTimeHelper timezone and DST', () {
    test('separates Asia/Shanghai and UTC midnight cleanly', () {
      final instant = DateTime.utc(2026, 11, 10, 16, 30); // 00:30 next day in +08
      expect(
        StudyTimeHelper.studyDayKey(instant, timezone: 'Asia/Shanghai'),
        '2026-11-11',
      );
      expect(
        StudyTimeHelper.studyDayKey(instant, timezone: 'UTC'),
        '2026-11-10',
      );
    });

    test('handles America/New_York DST spring forward and fall back', () {
      final winterUtc = DateTime.utc(2026, 1, 15, 12, 0);
      final summerUtc = DateTime.utc(2026, 7, 15, 12, 0);
      expect(
        StudyTimeHelper.offsetMinutesAt(winterUtc, timezone: 'America/New_York'),
        -300,
      );
      expect(
        StudyTimeHelper.offsetMinutesAt(summerUtc, timezone: 'America/New_York'),
        -240,
      );

      final beforeFallBack = DateTime.utc(2026, 11, 1, 4, 30); // EDT (-4) -> 00:30
      expect(
        StudyTimeHelper.studyDate(beforeFallBack, timezone: 'America/New_York'),
        LocalDate(2026, 11, 1),
      );
    });
  });

  group('TrainingScheduler explainable progression', () {
    const training = TrainingScheduler();
    final day1 = DateTime.utc(2026, 11, 1, 3, 0);

    test('caps assisted or partial answers at 1 day and progresses independent work', () {
      final item = ReviewItem(
        id: 'calc-1',
        kind: ReviewItemKind.problem,
        scheduleMode: ReviewScheduleMode.training,
        prompt: '求极限',
        answer: '1',
      );
      final start = ReviewScheduleState(
        itemId: 'calc-1',
        mode: ReviewScheduleMode.training,
        state: ReviewCardState.newCard,
      );

      final assisted = training.schedule(
        current: start,
        item: item,
        outcome: ComplexityOutcome.independentCorrect,
        usedAssistance: true,
        nowUtc: day1,
      );
      expect(assisted.scheduledDays, 1);
      expect(assisted.trainingStage, 'assisted_reverify');

      final wrong = training.schedule(
        current: start,
        item: item,
        outcome: ComplexityOutcome.incomplete,
        usedAssistance: false,
        nowUtc: day1,
      );
      expect(wrong.scheduledDays, 1);
      expect(wrong.lapses, 1);
      expect(wrong.state, ReviewCardState.relearning);

      final firstIndependent = training.schedule(
        current: start,
        item: item,
        outcome: ComplexityOutcome.independentCorrect,
        usedAssistance: false,
        nowUtc: day1,
      );
      expect(firstIndependent.scheduledDays, 3);
      expect(firstIndependent.trainingStage, 'variant_3d');

      final crossDaySecond = training.schedule(
        current: firstIndependent,
        item: item,
        outcome: ComplexityOutcome.independentCorrect,
        usedAssistance: false,
        nowUtc: day1.add(const Duration(days: 3)),
      );
      expect(crossDaySecond.scheduledDays, 7);
      expect(crossDaySecond.trainingStage, 'mixed_7d');

      final disputedHold = training.schedule(
        current: crossDaySecond,
        item: item,
        outcome: ComplexityOutcome.disputed,
        usedAssistance: false,
        nowUtc: day1.add(const Duration(days: 3)),
      );
      expect(disputedHold.trainingStage, 'disputed_hold');
      expect(
        disputedHold.algorithmDueAtUtc,
        crossDaySecond.algorithmDueAtUtc,
      );
    });
  });

  group('ReviewAnswerEvaluator conservative local checks', () {
    test('evaluates concise tokens locally and declines formula auto-marking', () {
      final tokenItem = ReviewItem(
        id: 'b1',
        kind: ReviewItemKind.blank,
        prompt: '牛顿第二定律由{{牛顿}}在《{{自然哲学的数学原理}}》中阐述。',
        blankAnswers: const ['Newton', 'Principia'],
      );
      final ok = ReviewAnswerEvaluator.evaluateBlanks(
        item: tokenItem,
        userBlanks: const ['newton ', ' principia'],
      );
      expect(ok.decided, isTrue);
      expect(ok.isCorrect, isTrue);

      final mismatched = ReviewAnswerEvaluator.evaluateBlanks(
        item: tokenItem,
        userBlanks: const ['Newton', 'Opticks'],
      );
      expect(mismatched.decided, isTrue);
      expect(mismatched.isCorrect, isFalse);

      final formulaItem = ReviewItem(
        id: 'b2',
        kind: ReviewItemKind.blank,
        prompt: '公式是{{F=ma}}。',
        blankAnswers: const ['F=ma'],
      );
      final formulaCheck = ReviewAnswerEvaluator.evaluateBlanks(
        item: formulaItem,
        userBlanks: const ['f = ma'],
      );
      expect(formulaCheck.decided, isFalse);
    });
  });
}
