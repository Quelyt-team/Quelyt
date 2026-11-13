import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:local_study/core/local_store.dart';
import 'package:local_study/core/migrations/schema.dart';
import 'package:local_study/core/models.dart';
import 'package:local_study/features/review/data/review_repository.dart';
import 'package:local_study/features/review/models/review_models.dart';
import 'package:local_study/features/schedule/models/local_date.dart';
import 'package:local_study/features/schedule/models/study_plan.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void _seedV9Database(String dbPath) {
  final db = sqlite3.open(dbPath);
  try {
    db.execute(schemaVersion1);
    db.execute(schemaVersion2);
    db.execute(schemaVersion3);
    db.execute(schemaVersion4);
    db.execute(schemaVersion5);
    db.execute(schemaVersion6);
    db.execute(schemaVersion7);
    db.execute(schemaVersion8);
    db.execute(schemaVersion9);
    db.execute('PRAGMA user_version = 9');

    final doc = DocumentRecord(
      id: 'doc-1',
      title: '高等数学',
      kind: DocumentKind.textbook,
      filePath: '/managed/math.pdf',
      contentHash: 'math-hash-v1',
      pageCount: 120,
      currentPage: 12,
    );
    db.execute(
      'INSERT INTO documents (id, content_hash, kind, last_opened_at, data) VALUES (?, ?, ?, ?, ?)',
      [
        doc.id,
        doc.contentHash,
        doc.kind.name,
        doc.lastOpenedAt.millisecondsSinceEpoch,
        jsonEncode(doc.toJson()),
      ],
    );

    final plan = StudyPlan(
      id: 'plan-1',
      title: '期末高等数学',
      startDate: LocalDate(2026, 10, 1),
      endDate: LocalDate(2026, 12, 31),
      examDate: LocalDate(2026, 12, 20),
    );
    db.execute(
      'INSERT INTO study_plans (id, title, status, start_date, exam_date, revision, updated_at, data) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [
        plan.id,
        plan.title,
        plan.status.name,
        plan.startDate.iso,
        plan.examDate?.iso,
        plan.revision,
        1000,
        jsonEncode(plan.toJson()),
      ],
    );

    // Seed > 220 learning_records so any old 200-row cap would lose history!
    // Include one resolved pair where attempt 0 marked selfCheck='review' and
    // a later attempt marked selfCheck='correct'.
    for (var i = 0; i < 230; i++) {
      final isResolvedLater = i == 0;
      final occurredMs = 1700000000000 + i * 1000;
      db.execute(
        'INSERT INTO learning_records (id, block_id, task_id, kind, occurred_at, operation_id, data) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
        [
          'lr-$i',
          null,
          'task-$i',
          'noted',
          occurredMs,
          'op-lr-$i',
          jsonEncode({
            'id': 'lr-$i',
            'kind': 'noted',
            'occurredAt': DateTime.fromMillisecondsSinceEpoch(
              occurredMs,
              isUtc: true,
            ).toIso8601String(),
            'note': jsonEncode({
              'kind': 'lessonAttempt',
              'lessonId': 'lesson-${isResolvedLater ? 999 : i}',
              'exerciseId': 'ex-${isResolvedLater ? 999 : i}',
              'answer': '作答 $i',
              'selfCheck': 'review',
            }),
          }),
        ],
      );
    }
    db.execute(
      'INSERT INTO learning_records (id, block_id, task_id, kind, occurred_at, operation_id, data) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      [
        'lr-resolve-999',
        null,
        'task-0',
        'noted',
        1700000500000,
        'op-lr-resolve-999',
        jsonEncode({
          'id': 'lr-resolve-999',
          'kind': 'noted',
          'occurredAt': DateTime.fromMillisecondsSinceEpoch(
            1700000500000,
            isUtc: true,
          ).toIso8601String(),
          'note': jsonEncode({
            'kind': 'lessonAttempt',
            'lessonId': 'lesson-999',
            'exerciseId': 'ex-999',
            'answer': '订正后正确答案',
            'selfCheck': 'correct',
          }),
        }),
      ],
    );

    // Seed > 25 study sessions (mix of needsReview session, attempt needsReview, and normal).
    for (var s = 0; s < 28; s++) {
      final sess = StudySession(
        id: 'sess-$s',
        documentId: doc.id,
        startPage: 5 + s,
        endPage: 6 + s,
        question: '阅读题目 $s',
        answer: '原回答 $s',
        stage: 'checked',
        needsReview: s < 22,
        attempts: [
          StudyAttempt(
            question: '阅读子题 $s',
            answer: '试答 $s',
            feedback: '错因 $s',
            needsReview: s < 25,
          ),
        ],
      );
      db.execute(
        'INSERT INTO sessions (id, document_id, updated_at, data) VALUES (?, ?, ?, ?)',
        [sess.id, sess.documentId, 1700000000000 + s * 2000, jsonEncode(sess.toJson())],
      );
    }
  } finally {
    db.close();
  }
}

void main() {
  test('v9 -> v10 migration preserves full >200 history without legacy caps and stays idempotent', () {
    final tempDir = Directory.systemTemp.createTempSync('review_mig_');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    final dbPath = p.join(tempDir.path, 'study.sqlite3');
    _seedV9Database(dbPath);

    final store = LocalStore.open(tempDir.path);
    var closedFirst = false;
    addTearDown(() {
      if (!closedFirst) store.dispose();
    });
    expect(store.schemaVersion, 10);
    expect(store.backupPaths.last, contains('.v9-backup-'));

    final repo = ReviewRepository(store);
    // All 229 unresolved lessonAttempt records migrated without 200-row cap.
    final pendingLessonCandidates = repo
        .getCandidates(status: ReviewCandidateStatus.pending, limit: 1000)
        .where((c) => c.sourceType == 'lesson')
        .toList();
    expect(pendingLessonCandidates, hasLength(229));

    // The earlier 'review' settled by a later 'correct' attempt became ignored.
    final ignored = repo
        .getCandidates(status: ReviewCandidateStatus.ignored, limit: 100)
        .where((c) => c.originKey == 'lesson_attempt:lesson-999:ex-999')
        .toList();
    expect(ignored, hasLength(1));

    // All 25 sessions needing review (22 session.needsReview + 3 attempt.needsReview) preserved (> 20 legacy cap),
    // and all 28 sessions with attempts become review candidates without dropping beyond 20.
    final openChecks = repo.getChecks(status: ReviewCheckStatus.open);
    expect(openChecks, hasLength(25));
    final sessionCandidates = repo
        .getCandidates(status: ReviewCandidateStatus.pending, limit: 1000)
        .where((c) => c.sourceType == 'session')
        .toList();
    expect(sessionCandidates, hasLength(28));

    // Reopen is idempotent and does not duplicate candidates or checks.
    store.dispose();
    closedFirst = true;
    final reopened = LocalStore.open(tempDir.path);
    addTearDown(reopened.dispose);
    final repo2 = ReviewRepository(reopened);
    expect(reopened.schemaVersion, 10);
    expect(repo2.getChecks(status: ReviewCheckStatus.open), hasLength(25));
    expect(
      repo2
          .getCandidates(status: ReviewCandidateStatus.pending, limit: 1000)
          .where((c) => c.sourceType == 'lesson')
          .length,
      229,
    );
  });

  test('operationId deduplication, optimistic revision guard, undo & schedule recompute', () {
    final store = LocalStore.inMemory();
    addTearDown(store.dispose);
    final repo = ReviewRepository(store);
    final t0 = DateTime.utc(2026, 11, 5, 4, 0);

    final item = repo.createItem(
      objective: '泰勒展开',
      prompt: '写出 sin(x) 的前两项泰勒展开。',
      answer: 'x - x^3/6',
      nowUtc: t0,
    );

    final first = repo.submitAttemptAndGrade(
      itemId: item.id,
      operationId: 'op-grade-1',
      expectedItemRevision: item.revision,
      answerText: 'x - x^3/6',
      rating: ReviewRating.good,
      activeSeconds: 25,
      nowUtc: t0.add(const Duration(seconds: 25)),
    );
    // Retrying with same operationId returns the original result without double scheduling.
    final duplicate = repo.submitAttemptAndGrade(
      itemId: item.id,
      operationId: 'op-grade-1',
      expectedItemRevision: item.revision,
      answerText: 'x - x^3/6',
      rating: ReviewRating.good,
      activeSeconds: 25,
      nowUtc: t0.add(const Duration(seconds: 30)),
    );
    expect(duplicate.duplicateIgnored, isTrue);
    expect(duplicate.attempt.id, first.attempt.id);
    expect(repo.queryAttemptHistory(itemId: item.id), hasLength(1));

    // Stale expectedItemRevision throws without mutating item/schedule.
    final updated = repo.updateItemContent(
      itemId: item.id,
      prompt: '写出 sin(x) 在 x=0 处的三阶泰勒展开。',
      preserveScheduleOnTypo: true,
      nowUtc: t0.add(const Duration(minutes: 1)),
    );
    expect(updated.revision, 2);
    expect(
      () => repo.submitAttemptAndGrade(
        itemId: item.id,
        operationId: 'op-stale-rev',
        expectedItemRevision: 1,
        answerText: 'test',
        rating: ReviewRating.good,
      ),
      throwsA(isA<ReviewStaleVersionException>()),
    );

    // Grade again, then undo and verify schedule restoration + recompute consistency.
    final beforeSecond = repo.getSchedule(item.id)!;
    repo.submitAttemptAndGrade(
      itemId: item.id,
      operationId: 'op-grade-2',
      expectedItemRevision: updated.revision,
      answerText: 'x - x^3/6',
      rating: ReviewRating.easy,
      activeSeconds: 12,
      nowUtc: t0.add(const Duration(days: 1)),
    );
    final afterUndo = repo.undoLastGrade(item.id)!;
    expect(afterUndo.reps, beforeSecond.reps);
    expect(afterUndo.algorithmDueAtUtc, beforeSecond.algorithmDueAtUtc);
    expect(repo.queryAttemptHistory(itemId: item.id), hasLength(1));
    expect(
      repo.queryAttemptHistory(itemId: item.id, includeUndone: true),
      hasLength(2),
    );

    final recomputed = repo.recomputeItemSchedule(item.id)!;
    expect(recomputed.reps, beforeSecond.reps);
    expect(recomputed.stability, closeTo(beforeSecond.stability, 1e-6));
  });
}
