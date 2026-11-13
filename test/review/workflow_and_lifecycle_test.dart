import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_study/core/local_store.dart';
import 'package:local_study/core/models.dart';
import 'package:local_study/features/review/data/review_repository.dart';
import 'package:local_study/features/review/models/review_models.dart';
import 'package:local_study/features/schedule/data/schedule_repository.dart';
import 'package:local_study/features/schedule/models/local_date.dart';
import 'package:local_study/features/schedule/models/study_plan.dart';
import 'package:path/path.dart' as p;

void main() {
  test('offline manual creation, occlusion non-leak, and edit versioning', () {
    final temp = Directory.systemTemp.createTempSync('review_offline_');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final store = LocalStore.inMemory();
    addTearDown(store.dispose);
    final repo = ReviewRepository(store);
    final assetFile = File(p.join(temp.path, 'diagram.png'))
      ..writeAsBytesSync([1, 2, 3, 4]);

    final t0 = DateTime.utc(2026, 11, 2, 1, 0);
    final occlusion = repo.createItem(
      kind: ReviewItemKind.occlusion,
      objective: '心脏瓣膜结构',
      prompt: '指出图中遮挡处的瓣膜名称',
      answer: '二尖瓣（左房室瓣）',
      imagePath: assetFile.path,
      occlusionRects: const [
        ReviewOcclusionRect(
          id: 'rect-1',
          left: 0.2,
          top: 0.3,
          width: 0.25,
          height: 0.15,
          maskText: '二尖瓣',
        ),
      ],
      nowUtc: t0,
    );

    expect(occlusion.kind, ReviewItemKind.occlusion);
    expect(occlusion.occlusionRects, hasLength(1));

    // Grade twice to build mature stability.
    repo.submitAttemptAndGrade(
      itemId: occlusion.id,
      operationId: 'occ-1',
      rating: ReviewRating.easy,
      answerText: '二尖瓣',
      nowUtc: t0,
    );
    final reviewedSched = repo.getSchedule(occlusion.id)!;
    expect(reviewedSched.reps, 1);

    // Typo fix on prompt preserves FSRS schedule intact!
    final typoFixed = repo.updateItemContent(
      itemId: occlusion.id,
      prompt: '请指出图中遮挡处的瓣膜名称',
      preserveScheduleOnTypo: true,
      nowUtc: t0.add(const Duration(minutes: 5)),
    );
    expect(typoFixed.revision, 2);
    expect(repo.getSchedule(occlusion.id)!.reps, 1);

    // Substantive change moves reviewed card into immediate relearning.
    repo.updateItemContent(
      itemId: occlusion.id,
      prompt: '比较二尖瓣与三尖瓣在血流方向上的差异',
      preserveScheduleOnTypo: false,
      nowUtc: t0.add(const Duration(minutes: 10)),
    );
    expect(repo.getSchedule(occlusion.id)!.state, ReviewCardState.relearning);
    expect(repo.getSchedule(occlusion.id)!.step, 0);

    // Purge cleans up orphan asset file.
    repo.setLifecycle([occlusion.id], ReviewItemLifecycle.trashed);
    final removedAssets = repo.purgeItems([occlusion.id]);
    expect(removedAssets, contains(assetFile.path));
    for (final path in removedAssets) {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    }
    expect(assetFile.existsSync(), isFalse);
  });

  test('assisted attempts never inflate independent recall rate or cross-day streak', () {
    final store = LocalStore.inMemory();
    addTearDown(store.dispose);
    final repo = ReviewRepository(store);
    final day1 = DateTime.utc(2026, 11, 1, 2, 0);

    final item = repo.createItem(
      objective: '伯努利方程',
      prompt: '写出不可压缩定常流体的伯努利方程。',
      answer: 'p + 1/2*rho*v^2 + rho*g*h = const',
      nowUtc: day1,
    );

    // Day 1: used hint -> rated Good -> MUST be counted as assisted, NOT independent pass!
    final r1 = repo.submitAttemptAndGrade(
      itemId: item.id,
      operationId: 'assist-1',
      usedHint: true,
      rating: ReviewRating.good,
      answerText: '看了提示后写出',
      nowUtc: day1,
    );
    expect(r1.attempt.usedHint || r1.attempt.viewedSource, isTrue);

    final statsAfterAssist = repo.computeStats(nowUtc: day1);
    expect(statsAfterAssist.assistedCount, 1);
    expect(statsAfterAssist.independentSampleCount, 0);
    expect(statsAfterAssist.independentRecallRate, isNull);

    // Day 2: fail twice, Day 3: fail once -> 3-strike guidance; Day 4: independent pass.
    repo.submitAttemptAndGrade(
      itemId: item.id,
      operationId: 'wrong-1',
      rating: ReviewRating.again,
      errorReason: '条件遗漏',
      correctionNote: '漏了不可压缩假设',
      nowUtc: day1.add(const Duration(days: 1)),
    );
    final r3 = repo.submitAttemptAndGrade(
      itemId: item.id,
      operationId: 'wrong-2',
      rating: ReviewRating.again,
      nowUtc: day1.add(const Duration(days: 1, hours: 1)),
    );
    final r4 = repo.submitAttemptAndGrade(
      itemId: item.id,
      operationId: 'wrong-3',
      rating: ReviewRating.again,
      nowUtc: day1.add(const Duration(days: 2)),
    );
    expect(r3.item.wrongStreak, 2);
    expect(r4.item.wrongStreak, 3);
    expect(r4.guidance, isNotEmpty);

    // Day 5: first independent recall; Day 6: cross-day independent redo!
    final ind1 = repo.submitAttemptAndGrade(
      itemId: item.id,
      operationId: 'ind-1',
      rating: ReviewRating.good,
      answerText: 'p + rho*v^2/2 + rho*g*h = C',
      nowUtc: day1.add(const Duration(days: 4)),
    );
    expect(ind1.item.wrongStreak, 0);
    expect(ind1.item.crossDayRedoPassed, isFalse);

    final ind2 = repo.submitAttemptAndGrade(
      itemId: item.id,
      operationId: 'ind-2',
      rating: ReviewRating.good,
      answerText: 'p + rho*v^2/2 + rho*g*h = C',
      nowUtc: day1.add(const Duration(days: 5)),
    );
    expect(ind2.item.crossDayRedoPassed, isTrue);

    final finalStats = repo.computeStats(nowUtc: day1.add(const Duration(days: 5)));
    expect(finalStats.independentSampleCount, 5); // 3 fails + 2 passes
    expect(finalStats.independentSuccessCount, 2);
    expect(finalStats.independentRecallRate, closeTo(2 / 5, 1e-6));
    expect(finalStats.crossDayRedoPassedCount, 1);
  });

  test('document trash/purge keeps active items with snapshots and cleans pending candidates', () {
    final store = LocalStore.inMemory();
    addTearDown(store.dispose);
    final repo = ReviewRepository(store);
    final doc = DocumentRecord(
      id: 'doc-bio',
      title: '分子生物学',
      kind: DocumentKind.textbook,
      filePath: '/managed/bio.pdf',
      contentHash: 'bio-h1',
      pageCount: 50,
    );
    store.upsertDocument(doc);

    final activeItem = repo.createItem(
      objective: 'DNA 复制方向',
      prompt: 'DNA 聚合酶沿什么方向合成新链？',
      answer: "5' -> 3'",
      origin: ReviewOrigin(
        id: '',
        itemId: '',
        originKey: 'doc-bio:p10',
        sourceType: 'document',
        documentId: doc.id,
        documentHash: doc.contentHash,
        documentTitle: doc.title,
        page: 10,
        snapshotText: 'DNA 聚合酶只能从 5 端向 3 端延伸。',
      ),
    );
    repo.upsertCandidate(
      originKey: 'sess:doc-bio:1',
      sourceType: 'session',
      documentId: doc.id,
      documentHash: doc.contentHash,
      documentTitle: doc.title,
      title: '待确认候选',
      prompt: '转录和复制的模板差异？',
    );

    // Trash doc: origin becomes sourceAvailable = false, active item remains intact.
    repo.handleDocumentsLifecycleChanged([doc.id], available: false);
    final trashedOrigins = repo.getOrigins(activeItem.id);
    expect(trashedOrigins.single.sourceAvailable, isFalse);
    expect(trashedOrigins.single.snapshotText, contains('5 端向 3 端'));

    // Restore doc: origin becomes available again.
    repo.handleDocumentsLifecycleChanged([doc.id], available: true);
    expect(repo.getOrigins(activeItem.id).single.sourceAvailable, isTrue);

    // Permanent purge: pending candidates removed, active item & snapshot retained!
    repo.handleDocumentsLifecycleChanged(
      [doc.id],
      available: false,
      permanentPurge: true,
    );
    expect(repo.getItem(activeItem.id), isNotNull);
    expect(repo.getOrigins(activeItem.id).single.sourceAvailable, isFalse);
    expect(
      repo.getCandidates(status: ReviewCandidateStatus.pending),
      isEmpty,
    );
  });

  test('paused plans isolate auto-enqueue, exam deficit, calendar batch, and full export/import', () {
    final store = LocalStore.inMemory();
    addTearDown(store.dispose);
    final scheduleRepo = ScheduleRepository(store);
    final repo = ReviewRepository(store);
    final t0 = DateTime.utc(2026, 11, 10, 2, 0);

    final pausedPlan = StudyPlan(
      id: 'plan-paused',
      title: '已暂停备考',
      status: PlanStatus.paused,
      startDate: LocalDate(2026, 11, 1),
      endDate: LocalDate(2026, 12, 1),
    );
    final examPlan = StudyPlan(
      id: 'plan-exam',
      title: '三天后考试',
      status: PlanStatus.active,
      startDate: LocalDate(2026, 11, 1),
      endDate: LocalDate(2026, 11, 20),
      examDate: LocalDate(2026, 11, 12),
    );
    scheduleRepo.savePlan(pausedPlan);
    scheduleRepo.savePlan(examPlan);

    repo.createItem(
      objective: '暂停计划专属题',
      prompt: '仅属暂停计划，不在个人库',
      answer: 'A',
      includePersonal: false,
      planIds: [pausedPlan.id],
      nowUtc: t0,
    );
    for (var i = 0; i < 6; i++) {
      repo.createItem(
        objective: '考前重点 $i',
        prompt: '推导第 $i 题',
        answer: '结论 $i',
        estimatedSeconds: 300, // 5 min each -> 30 min total vs 10 min/day * 2d = 20 min capacity
        planIds: [examPlan.id],
        nowUtc: t0,
      );
    }

    final defaultQueue = repo.buildTodayQueue(budgetMinutes: 60, nowUtc: t0);
    expect(
      defaultQueue.any((e) => e.item.objective == '暂停计划专属题'),
      isFalse,
    );

    final examSummaries = repo.computeExamSummaries(
      dailyBudgetMinutes: 10,
      nowUtc: t0,
    );
    expect(examSummaries, hasLength(1));
    expect(examSummaries.single.hasDeficit, isTrue);
    expect(examSummaries.single.deficitMinutes, greaterThan(0));

    // Calendar batch scheduling creates block + deduplicates for same session.
    final sess = repo.startSession(nowUtc: t0);
    final b1 = repo.scheduleReviewBatchToCalendar(
      planId: examPlan.id,
      date: LocalDate(2026, 11, 10),
      budgetMinutes: 20,
      sessionId: sess.id,
      nowUtc: t0,
    );
    final b2 = repo.scheduleReviewBatchToCalendar(
      planId: examPlan.id,
      date: LocalDate(2026, 11, 10),
      budgetMinutes: 20,
      sessionId: sess.id,
      nowUtc: t0,
    );
    expect(b1.duplicateReused, isFalse);
    expect(b2.duplicateReused, isTrue);
    expect(b2.taskId, b1.taskId);

    // Export Markdown, CSV, and round-trip Full JSON into fresh database!
    expect(repo.exportMarkdownReport(nowUtc: t0), contains('考前重点 0'));
    expect(repo.exportCsv(), contains('id,kind,schedule_mode'));
    final pkgJson = repo.exportFullPackageJson();

    final freshStore = LocalStore.inMemory();
    addTearDown(freshStore.dispose);
    final freshRepo = ReviewRepository(freshStore);
    final importedCount = freshRepo.importFullPackageJson(pkgJson);
    expect(importedCount, 7);
    expect(freshRepo.queryItems(limit: 50), hasLength(7));
  });
}
