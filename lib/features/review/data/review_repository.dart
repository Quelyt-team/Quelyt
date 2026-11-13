import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../../../core/local_store.dart';
import '../../../core/models.dart';
import '../../schedule/models/local_date.dart';
import '../../schedule/models/study_plan.dart';
import '../models/review_models.dart';
import '../services/fsrs_scheduler.dart';
import '../services/study_time.dart';
import '../services/training_scheduler.dart';

class ReviewStaleVersionException implements Exception {
  const ReviewStaleVersionException(this.message);
  final String message;
  @override
  String toString() => message;
}

class SubmitGradeResult {
  const SubmitGradeResult({
    required this.item,
    required this.schedule,
    required this.attempt,
    required this.event,
    required this.guidance,
    this.duplicateIgnored = false,
  });

  final ReviewItem item;
  final ReviewScheduleState schedule;
  final ReviewAttempt attempt;
  final ReviewEvent? event;
  final String guidance;
  final bool duplicateIgnored;
}

class ScheduleBatchResult {
  const ScheduleBatchResult({
    required this.taskId,
    required this.blockId,
    required this.dateIso,
    required this.startMinute,
    required this.minutes,
    required this.duplicateReused,
  });

  final String taskId;
  final String blockId;
  final String dateIso;
  final int startMinute;
  final int minutes;
  final bool duplicateReused;
}

/// Core local repository for review items, origins, candidates, feedback/content
/// checks, FSRS & training scheduling, resumable sessions, stats, exam prep,
/// calendar batch linking, and full-fidelity import/export.
class ReviewRepository {
  ReviewRepository(
    this.store, {
    FsrsScheduler? fsrs,
    TrainingScheduler? training,
  }) : fsrs = fsrs ?? const FsrsScheduler(),
       training = training ?? const TrainingScheduler();

  final LocalStore store;
  final FsrsScheduler fsrs;
  final TrainingScheduler training;
  static const _uuid = Uuid();

  static const String _timezoneKey = 'review.timezone';
  static const String _budgetKey = 'review.defaultBudgetMinutes';
  static const String _autoAddLessonMistakesKey = 'review.autoAddLessonMistakes';
  static const String _repeatFailureThresholdKey =
      'review.repeatFailureThreshold';

  String getStudyTimezone() {
    final stored = store.getSetting(_timezoneKey)?.trim();
    if (stored != null && stored.isNotEmpty) return stored;
    final plans = store.selectRows(
      "SELECT data FROM study_plans WHERE status = 'active' ORDER BY updated_at DESC LIMIT 1",
    );
    if (plans.isNotEmpty) {
      final decoded = _decode(plans.first);
      final tz = decoded['timezone'] as String?;
      if (tz != null && tz.isNotEmpty) return tz;
    }
    return StudyTimeHelper.defaultTimezone;
  }

  void setStudyTimezone(String timezone) =>
      store.setSetting(_timezoneKey, timezone.trim());

  int getDefaultBudgetMinutes() {
    final raw = int.tryParse(store.getSetting(_budgetKey) ?? '');
    return raw == null ? 20 : raw.clamp(5, 240);
  }

  void setDefaultBudgetMinutes(int minutes) =>
      store.setSetting(_budgetKey, '${minutes.clamp(5, 240)}');

  bool getAutoAddLessonMistakes() =>
      store.getSetting(_autoAddLessonMistakesKey) == 'true';

  void setAutoAddLessonMistakes(bool enabled) =>
      store.setSetting(_autoAddLessonMistakesKey, enabled ? 'true' : 'false');

  int getRepeatFailureThreshold() {
    final raw = int.tryParse(store.getSetting(_repeatFailureThresholdKey) ?? '');
    return raw == null ? 3 : raw.clamp(2, 10);
  }

  void setRepeatFailureThreshold(int threshold) =>
      store.setSetting(_repeatFailureThresholdKey, '${threshold.clamp(2, 10)}');

  // ---------------------------------------------------------------------------
  // Sync legacy runtime writes (e.g. reader sessions saved after DB open)
  // ---------------------------------------------------------------------------

  void syncSessionChecks(StudySession session, {DocumentRecord? document}) {
    store.transact(() {
      final baseTime = session.updatedAt.millisecondsSinceEpoch;
      final doc = document ?? store.getDocument(session.documentId);
      final sessionOriginKey = 'session_check:${session.id}';
      if (session.needsReview) {
        final checkId = _uuid.v4();
        final data = {
          'id': checkId,
          'originKey': sessionOriginKey,
          'targetType': 'feedback',
          'targetId': session.id,
          'targetVersion': session.attempts.length + 1,
          'sessionId': session.id,
          'documentId': session.documentId,
          'documentTitle': doc?.title ?? '',
          'startPage': session.startPage,
          'endPage': session.endPage,
          'question': session.question.isNotEmpty
              ? session.question
              : session.goal,
          'answer': session.answer,
          'feedback': session.feedback,
          'reason': '阅读评语待核对',
          'status': 'open',
          'createdAt': session.updatedAt.toIso8601String(),
        };
        store.executeSql(
          '''
          INSERT INTO review_checks
            (id, origin_key, target_type, target_id, target_version,
             item_id, document_id, session_id, attempt_key, reason, status,
             resolution_note, created_at, updated_at, data)
          VALUES (?, ?, 'feedback', ?, ?, NULL, ?, ?, ?, '阅读评语待核对', 'open', '', ?, ?, ?)
          ON CONFLICT(origin_key) DO UPDATE SET
            status = 'open',
            updated_at = excluded.updated_at,
            data = excluded.data
        ''',
          [
            checkId,
            sessionOriginKey,
            session.id,
            session.attempts.length + 1,
            session.documentId,
            session.id,
            sessionOriginKey,
            baseTime,
            baseTime,
            jsonEncode(data),
          ],
        );
      } else {
        store.executeSql(
          "UPDATE review_checks SET status = 'resolved', updated_at = ? "
          "WHERE origin_key = ? AND status = 'open'",
          [baseTime, sessionOriginKey],
        );
      }
    });
  }

  // ---------------------------------------------------------------------------
  // CRUD & Origins
  // ---------------------------------------------------------------------------

  ReviewItem createItem({
    String? id,
    ReviewItemKind kind = ReviewItemKind.concept,
    ReviewScheduleMode? scheduleMode,
    String objective = '',
    required String prompt,
    String answer = '',
    List<String> steps = const [],
    String hint = '',
    String explanation = '',
    String? imagePath,
    List<ReviewOcclusionRect> occlusionRects = const [],
    List<String> blankAnswers = const [],
    List<String> choices = const [],
    int? correctChoiceIndex,
    String? variantParentId,
    String? knowledgeObjectiveId,
    int? estimatedSeconds,
    bool starred = false,
    bool aiGenerated = false,
    String errorReason = '',
    String correctionNote = '',
    ReviewOrigin? origin,
    List<String> planIds = const [],
    List<String> tagIds = const [],
    bool includePersonal = true,
    DateTime? nowUtc,
  }) {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    final itemId = id ?? _uuid.v4();
    final mode = scheduleMode ?? kind.defaultScheduleMode;
    final item = ReviewItem(
      id: itemId,
      kind: kind,
      scheduleMode: mode,
      objective: objective.trim(),
      prompt: prompt.trim(),
      answer: answer.trim(),
      steps: steps,
      hint: hint.trim(),
      explanation: explanation.trim(),
      imagePath: imagePath,
      occlusionRects: occlusionRects,
      blankAnswers: blankAnswers,
      choices: choices,
      correctChoiceIndex: correctChoiceIndex,
      variantParentId: variantParentId,
      knowledgeObjectiveId: knowledgeObjectiveId,
      starred: starred,
      estimatedSeconds: estimatedSeconds,
      errorReason: errorReason,
      correctionNote: correctionNote,
      aiGenerated: aiGenerated,
      createdAt: now,
      updatedAt: now,
    );
    final schedule = ReviewScheduleState(
      itemId: itemId,
      mode: mode,
      algorithmVersion: mode == ReviewScheduleMode.fsrs
          ? FsrsScheduler.algorithmVersion
          : TrainingScheduler.algorithmVersion,
      state: ReviewCardState.newCard,
      algorithmDueAtUtc: now,
      updatedAt: now,
    );

    store.transact(() {
      _insertItemRow(item);
      _insertRevisionRow(item, reason: 'create', nowUtc: now);
      _upsertScheduleRow(schedule);
      if (origin != null) {
        final effectiveOrigin = ReviewOrigin(
          id: origin.id.isEmpty ? _uuid.v4() : origin.id,
          itemId: itemId,
          originKey: origin.originKey.isEmpty
              ? '${origin.sourceType}:$itemId'
              : origin.originKey,
          sourceType: origin.sourceType,
          documentId: origin.documentId,
          documentHash: origin.documentHash,
          documentTitle: origin.documentTitle,
          page: origin.page,
          region: origin.region,
          noteId: origin.noteId,
          noteRevision: origin.noteRevision,
          lessonId: origin.lessonId,
          exerciseId: origin.exerciseId,
          sessionId: origin.sessionId,
          taskId: origin.taskId,
          snapshotText: origin.snapshotText,
          sourceAvailable: origin.sourceAvailable,
          createdAt: now,
          updatedAt: now,
        );
        _upsertOriginRow(effectiveOrigin);
        if (effectiveOrigin.documentId != null) {
          _upsertMembership(itemId, 'document', effectiveOrigin.documentId!, now);
        }
      }
      if (includePersonal) {
        _upsertMembership(itemId, 'personal', 'default', now);
      }
      for (final planId in planIds) {
        _upsertMembership(itemId, 'plan', planId, now);
      }
      for (final tagId in tagIds) {
        store.executeSql(
          'INSERT OR IGNORE INTO review_tags (item_id, tag_id) VALUES (?, ?)',
          [itemId, tagId],
        );
      }
      if (imagePath != null && imagePath.isNotEmpty) {
        store.executeSql(
          'INSERT INTO review_asset_refs (id, owner_type, owner_id, asset_path, sha256, created_at) '
          "VALUES (?, 'item', ?, ?, '', ?)",
          [_uuid.v4(), itemId, imagePath, now.millisecondsSinceEpoch],
        );
      }
    });
    return item;
  }

  /// Edits item wording/formatting or substantive objective/answer.
  /// Minor formatting changes preserve schedule; substantive answer/objective
  /// changes increment revision and optionally reset/relearn or spawn a linked item.
  ReviewItem updateItemContent({
    required String itemId,
    String? objective,
    String? prompt,
    String? answer,
    List<String>? steps,
    String? hint,
    String? explanation,
    bool preserveScheduleOnTypo = true,
    bool createNewSuccessorOnSubstantiveChange = false,
    DateTime? nowUtc,
  }) {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    return _atomic(() {
      final current = getItem(itemId);
      if (current == null) {
        throw StateError('Review item not found: $itemId');
      }
      final nextObjective = objective?.trim() ?? current.objective;
      final nextPrompt = prompt?.trim() ?? current.prompt;
      final nextAnswer = answer?.trim() ?? current.answer;
      final substantive =
          !preserveScheduleOnTypo ||
          nextObjective != current.objective ||
          nextAnswer != current.answer;

      if (substantive && createNewSuccessorOnSubstantiveChange) {
        final successor = createItem(
          kind: current.kind,
          scheduleMode: current.scheduleMode,
          objective: nextObjective,
          prompt: nextPrompt,
          answer: nextAnswer,
          steps: steps ?? current.steps,
          hint: hint ?? current.hint,
          explanation: explanation ?? current.explanation,
          variantParentId: current.id,
          nowUtc: now,
        );
        return successor;
      }

      final updated = current.copyWith(
        objective: nextObjective,
        prompt: nextPrompt,
        answer: nextAnswer,
        steps: steps ?? current.steps,
        hint: hint ?? current.hint,
        explanation: explanation ?? current.explanation,
        revision: current.revision + 1,
        updatedAt: now,
      );
      _updateItemRow(updated);
      _insertRevisionRow(
        updated,
        reason: substantive ? 'substantive_edit' : 'typo_edit',
        nowUtc: now,
      );
      if (substantive) {
        final schedule = getSchedule(itemId);
        if (schedule != null && schedule.state != ReviewCardState.newCard) {
          final reset = schedule.copyWith(
            state: ReviewCardState.relearning,
            step: 0,
            algorithmDueAtUtc: now,
            revision: schedule.revision + 1,
            updatedAt: now,
          );
          _upsertScheduleRow(reset);
        }
      }
      return updated;
    });
  }

  void updateErrorDetails({
    required String itemId,
    String? errorReason,
    String? correctionNote,
    bool? corrected,
    bool? starred,
    DateTime? nowUtc,
  }) {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    store.transact(() {
      final current = getItem(itemId);
      if (current == null) return;
      final updated = current.copyWith(
        errorReason: errorReason ?? current.errorReason,
        correctionNote: correctionNote ?? current.correctionNote,
        corrected: corrected ?? current.corrected,
        starred: starred ?? current.starred,
        updatedAt: now,
      );
      _updateItemRow(updated);
    });
  }

  void setManualDueDate(
    String itemId,
    DateTime dueAtUtc, {
    String reason = '手动调整复习日期',
    DateTime? nowUtc,
  }) {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    store.transact(() {
      final schedule = getSchedule(itemId);
      if (schedule == null) return;
      final next = schedule.copyWith(
        algorithmDueAtUtc: dueAtUtc.toUtc(),
        clearDefer: true,
        revision: schedule.revision + 1,
        updatedAt: now,
      );
      _upsertScheduleRow(next);
      _insertEventRow(
        ReviewEvent(
          id: _uuid.v4(),
          itemId: itemId,
          operationId: _uuid.v4(),
          eventType: 'manual_due',
          algorithmVersion: schedule.algorithmVersion,
          beforeSchedule: schedule,
          afterSchedule: next,
          studyDay: StudyTimeHelper.studyDayKey(
            now,
            timezone: getStudyTimezone(),
          ),
          createdAtUtc: now,
          note: reason,
        ),
      );
    });
  }

  void deferItemUntil(String itemId, DateTime untilUtc, {DateTime? nowUtc}) {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    store.transact(() {
      final schedule = getSchedule(itemId);
      if (schedule == null) return;
      final next = schedule.copyWith(
        deferUntilUtc: untilUtc.toUtc(),
        revision: schedule.revision + 1,
        updatedAt: now,
      );
      _upsertScheduleRow(next);
      _insertEventRow(
        ReviewEvent(
          id: _uuid.v4(),
          itemId: itemId,
          operationId: _uuid.v4(),
          eventType: 'defer',
          algorithmVersion: schedule.algorithmVersion,
          beforeSchedule: schedule,
          afterSchedule: next,
          studyDay: StudyTimeHelper.studyDayKey(
            now,
            timezone: getStudyTimezone(),
          ),
          createdAtUtc: now,
          note: '稍后再看',
        ),
      );
    });
  }

  void setLifecycle(
    Iterable<String> itemIds,
    ReviewItemLifecycle lifecycle, {
    DateTime? nowUtc,
  }) {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    final batchId = lifecycle == ReviewItemLifecycle.trashed ? _uuid.v4() : null;
    store.transact(() {
      for (final id in itemIds) {
        final item = getItem(id);
        if (item == null) continue;
        final updated = item.copyWith(
          lifecycle: lifecycle,
          deletedBatch: batchId,
          clearDeletedBatch: lifecycle != ReviewItemLifecycle.trashed,
          trashedAt: lifecycle == ReviewItemLifecycle.trashed ? now : null,
          clearTrashedAt: lifecycle != ReviewItemLifecycle.trashed,
          updatedAt: now,
        );
        _updateItemRow(updated);
        final schedule = getSchedule(id);
        if (schedule != null) {
          final paused = lifecycle == ReviewItemLifecycle.paused;
          if (schedule.paused != paused) {
            final next = schedule.copyWith(
              paused: paused,
              revision: schedule.revision + 1,
              updatedAt: now,
            );
            _upsertScheduleRow(next);
            _insertEventRow(
              ReviewEvent(
                id: _uuid.v4(),
                itemId: id,
                operationId: _uuid.v4(),
                eventType: paused ? 'pause' : 'resume',
                algorithmVersion: schedule.algorithmVersion,
                beforeSchedule: schedule,
                afterSchedule: next,
                studyDay: StudyTimeHelper.studyDayKey(
                  now,
                  timezone: getStudyTimezone(),
                ),
                createdAtUtc: now,
              ),
            );
          }
        }
      }
    });
  }

  /// Permanently removes trashed/selected items and returns managed image paths
  /// no longer referenced anywhere in `review_asset_refs`.
  List<String> purgeItems(Iterable<String> itemIds) {
    final ids = itemIds.toList();
    if (ids.isEmpty) return const [];
    return store.transact(() {
      final candidatePaths = <String>{};
      for (final id in ids) {
        for (final row in store.selectRows(
          "SELECT asset_path FROM review_asset_refs WHERE owner_type = 'item' AND owner_id = ?",
          [id],
        )) {
          final path = row['asset_path'] as String? ?? '';
          if (path.isNotEmpty) candidatePaths.add(path);
        }
        store.executeSql(
          "DELETE FROM review_asset_refs WHERE owner_type = 'item' AND owner_id = ?",
          [id],
        );
        store.executeSql('DELETE FROM review_items WHERE id = ?', [id]);
      }
      final unusedPaths = <String>[];
      for (final path in candidatePaths) {
        final remaining = store.selectRows(
          'SELECT COUNT(*) AS n FROM review_asset_refs WHERE asset_path = ?',
          [path],
        );
        if (((remaining.first['n'] as num?)?.toInt() ?? 0) == 0) {
          unusedPaths.add(path);
        }
      }
      return unusedPaths;
    });
  }

  void addMembership(String itemId, String scopeType, String scopeId) {
    store.transact(
      () => _upsertMembership(itemId, scopeType, scopeId, DateTime.now().toUtc()),
    );
  }

  void removeMembership(String itemId, String scopeType, String scopeId) {
    store.executeSql(
      'DELETE FROM review_memberships WHERE item_id = ? AND scope_type = ? AND scope_id = ?',
      [itemId, scopeType, scopeId],
    );
  }

  List<Map<String, String>> getMemberships(String itemId) {
    return [
      for (final row in store.selectRows(
        'SELECT scope_type, scope_id FROM review_memberships WHERE item_id = ?',
        [itemId],
      ))
        {
          'scopeType': row['scope_type'] as String,
          'scopeId': row['scope_id'] as String,
        },
    ];
  }

  ReviewItem? getItem(String id) {
    final rows = store.selectRows(
      'SELECT data FROM review_items WHERE id = ?',
      [id],
    );
    return rows.isEmpty ? null : ReviewItem.fromJson(_decode(rows.first));
  }

  ReviewScheduleState? getSchedule(String itemId) {
    final rows = store.selectRows(
      'SELECT data FROM review_schedules WHERE item_id = ?',
      [itemId],
    );
    return rows.isEmpty
        ? null
        : ReviewScheduleState.fromJson(_decode(rows.first));
  }

  List<ReviewOrigin> getOrigins(String itemId) {
    final rows = store.selectRows(
      'SELECT source_available, data FROM review_origins WHERE item_id = ? ORDER BY created_at',
      [itemId],
    );
    return rows.map((row) {
      final json = _decode(row);
      json['sourceAvailable'] = (row['source_available'] as num?)?.toInt() != 0;
      return ReviewOrigin.fromJson(json);
    }).toList();
  }

  ReviewItem? findItemByOriginKey(String originKey) {
    final rows = store.selectRows(
      'SELECT i.data FROM review_items i '
      'INNER JOIN review_origins o ON o.item_id = i.id '
      'WHERE o.origin_key = ? LIMIT 1',
      [originKey],
    );
    return rows.isEmpty ? null : ReviewItem.fromJson(_decode(rows.first));
  }

  // ---------------------------------------------------------------------------
  // Candidates & Checks
  // ---------------------------------------------------------------------------

  ReviewCandidate upsertCandidate({
    required String originKey,
    required String sourceType,
    String? documentId,
    String documentHash = '',
    String documentTitle = '',
    int? startPage,
    int? endPage,
    String? noteId,
    String? lessonId,
    String? exerciseId,
    String? sessionId,
    String? taskId,
    String title = '',
    required String prompt,
    String answer = '',
    String hint = '',
    String explanation = '',
    String reason = '',
    ReviewItemKind kind = ReviewItemKind.concept,
    ReviewCandidateStatus status = ReviewCandidateStatus.pending,
    DateTime? nowUtc,
  }) {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    return _atomic(() {
      final existingItem = findItemByOriginKey(originKey);
      if (existingItem != null) {
        // Already accepted into formal review: update candidate pointer instead
        // of creating duplicates.
        final id = _uuid.v4();
        final existing = _findCandidateByOriginKey(originKey);
        final candidate = ReviewCandidate(
          id: existing?.id ?? id,
          originKey: originKey,
          sourceType: sourceType,
          documentId: documentId,
          documentHash: documentHash,
          documentTitle: documentTitle,
          startPage: startPage,
          endPage: endPage,
          noteId: noteId,
          lessonId: lessonId,
          exerciseId: exerciseId,
          sessionId: sessionId,
          taskId: taskId,
          title: title,
          prompt: prompt,
          answer: answer,
          hint: hint,
          explanation: explanation,
          status: ReviewCandidateStatus.accepted,
          linkedItemId: existingItem.id,
          reason: reason,
          kind: kind,
          createdAt: existing?.createdAt ?? now,
          updatedAt: now,
        );
        _writeCandidateRow(candidate);
        return candidate;
      }

      final existing = _findCandidateByOriginKey(originKey);
      final candidate = ReviewCandidate(
        id: existing?.id ?? _uuid.v4(),
        originKey: originKey,
        sourceType: sourceType,
        documentId: documentId,
        documentHash: documentHash,
        documentTitle: documentTitle,
        startPage: startPage,
        endPage: endPage,
        noteId: noteId,
        lessonId: lessonId,
        exerciseId: exerciseId,
        sessionId: sessionId,
        taskId: taskId,
        title: title,
        prompt: prompt,
        answer: answer,
        hint: hint,
        explanation: explanation,
        status: status,
        linkedItemId: existing?.linkedItemId,
        reason: reason,
        kind: kind,
        createdAt: existing?.createdAt ?? now,
        updatedAt: now,
      );
      _writeCandidateRow(candidate);
      return candidate;
    });
  }

  List<ReviewCandidate> getCandidates({
    ReviewCandidateStatus? status = ReviewCandidateStatus.pending,
    int limit = 100,
    int offset = 0,
  }) {
    final where = status == null ? '' : 'WHERE status = ?';
    final params = <Object?>[
      if (status != null) status.name,
      limit,
      offset,
    ];
    final rows = store.selectRows(
      'SELECT data FROM review_candidates $where ORDER BY updated_at DESC, id LIMIT ? OFFSET ?',
      params,
    );
    return rows.map((r) => ReviewCandidate.fromJson(_decode(r))).toList();
  }

  ReviewItem acceptCandidate(
    String candidateId, {
    String? prompt,
    String? answer,
    String? objective,
    ReviewItemKind? kind,
    List<String> planIds = const [],
    DateTime? nowUtc,
  }) {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    return _atomic(() {
      final rows = store.selectRows(
        'SELECT data FROM review_candidates WHERE id = ?',
        [candidateId],
      );
      if (rows.isEmpty) {
        throw StateError('Candidate not found: $candidateId');
      }
      final candidate = ReviewCandidate.fromJson(_decode(rows.first));
      final existing = findItemByOriginKey(candidate.originKey);
      if (existing != null) {
        final accepted = ReviewCandidate(
          id: candidate.id,
          originKey: candidate.originKey,
          sourceType: candidate.sourceType,
          documentId: candidate.documentId,
          documentHash: candidate.documentHash,
          documentTitle: candidate.documentTitle,
          startPage: candidate.startPage,
          endPage: candidate.endPage,
          noteId: candidate.noteId,
          lessonId: candidate.lessonId,
          exerciseId: candidate.exerciseId,
          sessionId: candidate.sessionId,
          taskId: candidate.taskId,
          title: candidate.title,
          prompt: candidate.prompt,
          answer: candidate.answer,
          hint: candidate.hint,
          explanation: candidate.explanation,
          status: ReviewCandidateStatus.accepted,
          linkedItemId: existing.id,
          reason: candidate.reason,
          kind: candidate.kind,
          createdAt: candidate.createdAt,
          updatedAt: now,
        );
        _writeCandidateRow(accepted);
        return existing;
      }

      final resolvedKind = kind ?? candidate.kind;
      final itemId = _uuid.v4();
      final item = createItem(
        id: itemId,
        kind: resolvedKind,
        objective: objective ?? candidate.title,
        prompt: prompt ?? candidate.prompt,
        answer: answer ?? candidate.answer,
        hint: candidate.hint,
        explanation: candidate.explanation,
        planIds: planIds,
        origin: ReviewOrigin(
          id: _uuid.v4(),
          itemId: itemId,
          originKey: candidate.originKey,
          sourceType: candidate.sourceType,
          documentId: candidate.documentId,
          documentHash: candidate.documentHash,
          documentTitle: candidate.documentTitle,
          page: candidate.startPage,
          noteId: candidate.noteId,
          lessonId: candidate.lessonId,
          exerciseId: candidate.exerciseId,
          sessionId: candidate.sessionId,
          taskId: candidate.taskId,
          snapshotText: candidate.prompt,
        ),
        nowUtc: now,
      );

      final updatedCandidate = ReviewCandidate(
        id: candidate.id,
        originKey: candidate.originKey,
        sourceType: candidate.sourceType,
        documentId: candidate.documentId,
        documentHash: candidate.documentHash,
        documentTitle: candidate.documentTitle,
        startPage: candidate.startPage,
        endPage: candidate.endPage,
        noteId: candidate.noteId,
        lessonId: candidate.lessonId,
        exerciseId: candidate.exerciseId,
        sessionId: candidate.sessionId,
        taskId: candidate.taskId,
        title: candidate.title,
        prompt: candidate.prompt,
        answer: candidate.answer,
        hint: candidate.hint,
        explanation: candidate.explanation,
        status: ReviewCandidateStatus.accepted,
        linkedItemId: item.id,
        reason: candidate.reason,
        kind: resolvedKind,
        createdAt: candidate.createdAt,
        updatedAt: now,
      );
      _writeCandidateRow(updatedCandidate);
      return item;
    });
  }

  void ignoreCandidate(String candidateId) {
    store.executeSql(
      "UPDATE review_candidates SET status = 'ignored', updated_at = ? WHERE id = ?",
      [DateTime.now().toUtc().millisecondsSinceEpoch, candidateId],
    );
  }

  ReviewCheck upsertCheck({
    String? originKey,
    ReviewCheckTargetType targetType = ReviewCheckTargetType.feedback,
    String targetId = '',
    int targetVersion = 1,
    String? itemId,
    String? documentId,
    String documentTitle = '',
    String? sessionId,
    String? attemptKey,
    int? startPage,
    int? endPage,
    String question = '',
    String answer = '',
    String feedback = '',
    required String reason,
    DateTime? nowUtc,
  }) {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    final check = ReviewCheck(
      id: _uuid.v4(),
      originKey: originKey,
      targetType: targetType,
      targetId: targetId,
      targetVersion: targetVersion,
      itemId: itemId,
      documentId: documentId,
      documentTitle: documentTitle,
      sessionId: sessionId,
      attemptKey: attemptKey,
      startPage: startPage,
      endPage: endPage,
      question: question,
      answer: answer,
      feedback: feedback,
      reason: reason,
      status: ReviewCheckStatus.open,
      createdAt: now,
      updatedAt: now,
    );
    store.transact(() {
      if (originKey != null) {
        final existing = store.selectRows(
          'SELECT id FROM review_checks WHERE origin_key = ?',
          [originKey],
        );
        if (existing.isNotEmpty) {
          final existingId = existing.first['id'] as String;
          store.executeSql(
            "UPDATE review_checks SET status = 'open', reason = ?, updated_at = ?, data = ? WHERE id = ?",
            [
              reason,
              now.millisecondsSinceEpoch,
              jsonEncode(check.toJson()..['id'] = existingId),
              existingId,
            ],
          );
          return;
        }
      }
      store.executeSql(
        '''
        INSERT INTO review_checks
          (id, origin_key, target_type, target_id, target_version, item_id,
           document_id, session_id, attempt_key, reason, status, resolution_note,
           created_at, updated_at, data)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'open', '', ?, ?, ?)
      ''',
        [
          check.id,
          check.originKey,
          check.targetType.name,
          check.targetId,
          check.targetVersion,
          check.itemId,
          check.documentId,
          check.sessionId,
          check.attemptKey,
          check.reason,
          now.millisecondsSinceEpoch,
          now.millisecondsSinceEpoch,
          jsonEncode(check.toJson()),
        ],
      );
    });
    return check;
  }

  List<ReviewCheck> getChecks({
    ReviewCheckStatus? status = ReviewCheckStatus.open,
    int limit = 100,
    int offset = 0,
  }) {
    final where = status == null ? '' : 'WHERE status = ?';
    final params = <Object?>[
      if (status != null) status.name,
      limit,
      offset,
    ];
    final rows = store.selectRows(
      'SELECT data FROM review_checks $where ORDER BY updated_at DESC, id LIMIT ? OFFSET ?',
      params,
    );
    return rows.map((r) => ReviewCheck.fromJson(_decode(r))).toList();
  }

  void resolveCheck(
    String checkId, {
    ReviewCheckStatus status = ReviewCheckStatus.resolved,
    String resolutionNote = '',
    String? updatedItemAnswer,
    DateTime? nowUtc,
  }) {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    store.transact(() {
      final rows = store.selectRows(
        'SELECT data FROM review_checks WHERE id = ?',
        [checkId],
      );
      if (rows.isEmpty) return;
      final existing = ReviewCheck.fromJson(_decode(rows.first));
      final updated = ReviewCheck(
        id: existing.id,
        originKey: existing.originKey,
        targetType: existing.targetType,
        targetId: existing.targetId,
        targetVersion: existing.targetVersion,
        itemId: existing.itemId,
        documentId: existing.documentId,
        documentTitle: existing.documentTitle,
        sessionId: existing.sessionId,
        attemptKey: existing.attemptKey,
        startPage: existing.startPage,
        endPage: existing.endPage,
        question: existing.question,
        answer: existing.answer,
        feedback: existing.feedback,
        reason: existing.reason,
        status: status,
        resolutionNote: resolutionNote.trim(),
        createdAt: existing.createdAt,
        updatedAt: now,
      );
      store.executeSql(
        'UPDATE review_checks SET status = ?, resolution_note = ?, updated_at = ?, data = ? WHERE id = ?',
        [
          status.name,
          updated.resolutionNote,
          now.millisecondsSinceEpoch,
          jsonEncode(updated.toJson()),
          checkId,
        ],
      );
      if (updatedItemAnswer != null &&
          updatedItemAnswer.trim().isNotEmpty &&
          existing.itemId != null) {
        updateItemContent(
          itemId: existing.itemId!,
          answer: updatedItemAnswer.trim(),
          preserveScheduleOnTypo: true,
          nowUtc: now,
        );
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Queue Selection, Budget & Dashboard
  // ---------------------------------------------------------------------------

  List<ReviewQueueEntry> buildTodayQueue({
    ReviewScopeFilter scope = const ReviewScopeFilter(),
    int? budgetMinutes,
    bool includeOverflow = false,
    bool allowNewCardsWhenBacklogged = false,
    DateTime? nowUtc,
  }) {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    final tz = getStudyTimezone();
    final today = StudyTimeHelper.studyDate(now, timezone: tz);
    final budgetSeconds = (budgetMinutes ?? getDefaultBudgetMinutes()) * 60;

    final openBlockingItems = <String>{
      for (final r in store.selectRows(
        "SELECT item_id FROM review_checks WHERE status = 'open' "
        "AND item_id IS NOT NULL AND target_type IN ('item', 'answer')",
      ))
        r['item_id'] as String,
    };

    final planStatuses = <String, String>{
      for (final r in store.selectRows('SELECT id, status FROM study_plans'))
        r['id'] as String: r['status'] as String,
    };
    final examBoostPlans = <String>{
      for (final r in store.selectRows(
        "SELECT id, exam_date FROM study_plans WHERE status = 'active' AND exam_date IS NOT NULL",
      ))
        if (LocalDate.parse(r['exam_date'] as String).differenceInDays(today) <=
            14)
          r['id'] as String,
    };

    final rows = _loadActiveItemRows(scope);
    final dueReviews = <ReviewQueueEntry>[];
    final newItems = <ReviewQueueEntry>[];

    for (final entry in rows) {
      final item = entry.$1;
      final schedule = entry.$2;
      final origins = entry.$3;
      if (schedule.paused || item.lifecycle != ReviewItemLifecycle.active) {
        continue;
      }
      if (schedule.isDeferredAt(now)) continue;
      if (openBlockingItems.contains(item.id)) continue;

      final memberships = getMemberships(item.id);
      if (!_isAutoEnqueueAllowed(memberships, planStatuses, scope)) {
        continue;
      }

      final hasExamBoost = memberships.any(
        (m) => m['scopeType'] == 'plan' && examBoostPlans.contains(m['scopeId']),
      );

      final isNew = schedule.state == ReviewCardState.newCard;
      final isIntraDayStep =
          schedule.state == ReviewCardState.learning ||
          schedule.state == ReviewCardState.relearning;
      final dueUtc = schedule.algorithmDueAtUtc;

      if (isNew) {
        final score =
            (item.starred ? 12.0 : 0.0) +
            (hasExamBoost ? 10.0 : 0.0) +
            (item.wrongStreak > 0 ? 15.0 : 0.0);
        newItems.add(
          ReviewQueueEntry(
            item: item,
            schedule: schedule,
            origins: origins,
            reasonLabel: hasExamBoost ? '考前重点 · 新题' : '新加入',
            overdueDays: 0,
            priorityScore: score,
            isNew: true,
            isDueToday: true,
          ),
        );
        continue;
      }

      if (dueUtc == null) continue;
      bool isDue;
      var overdueDays = 0;
      if (isIntraDayStep) {
        isDue = !dueUtc.isAfter(now);
      } else {
        final dueDate = StudyTimeHelper.studyDate(dueUtc, timezone: tz);
        overdueDays = today.differenceInDays(dueDate);
        isDue = overdueDays >= 0;
      }
      if (!isDue) continue;

      final reason = item.wrongStreak > 0
          ? '上次未独立完成'
          : (overdueDays > 0
                ? '逾期 $overdueDays 天'
                : (hasExamBoost ? '考前重点 · 今日到期' : '今日到期'));
      final score =
          100.0 +
          overdueDays * 18.0 +
          item.wrongStreak * 20.0 +
          (hasExamBoost ? 25.0 : 0.0) +
          (item.starred ? 8.0 : 0.0) -
          (item.estimatedSeconds / 120.0);

      dueReviews.add(
        ReviewQueueEntry(
          item: item,
          schedule: schedule,
          origins: origins,
          reasonLabel: reason,
          overdueDays: overdueDays,
          priorityScore: score,
          isDueToday: true,
        ),
      );
    }

    dueReviews.sort((a, b) => b.priorityScore.compareTo(a.priorityScore));
    newItems.sort((a, b) => b.priorityScore.compareTo(a.priorityScore));

    final combined = <ReviewQueueEntry>[...dueReviews];
    final dueEstimatedSeconds = dueReviews.fold<int>(
      0,
      (sum, e) => sum + e.item.estimatedSeconds,
    );
    if (allowNewCardsWhenBacklogged || dueEstimatedSeconds < budgetSeconds) {
      combined.addAll(newItems);
    }

    final interleaved = _spaceSiblings(combined);
    if (includeOverflow) return interleaved;

    final selected = <ReviewQueueEntry>[];
    var accumulated = 0;
    for (final entry in interleaved) {
      if (selected.isNotEmpty && accumulated + entry.item.estimatedSeconds > budgetSeconds) {
        // Always include at least one item if budget > 0, and stop cleanly at
        // budget without fabricating completions for unscheduled items.
        break;
      }
      selected.add(entry);
      accumulated += entry.item.estimatedSeconds;
    }
    return selected;
  }

  bool _isAutoEnqueueAllowed(
    List<Map<String, String>> memberships,
    Map<String, String> planStatuses,
    ReviewScopeFilter scope,
  ) {
    if (scope.planId != null) {
      final status = planStatuses[scope.planId!];
      return status == 'active' || status == null;
    }
    if (memberships.isEmpty) return true;
    final hasPersonal = memberships.any((m) => m['scopeType'] == 'personal');
    if (hasPersonal) return true;
    final planMemberships = memberships.where((m) => m['scopeType'] == 'plan');
    if (planMemberships.isEmpty) return true;
    return planMemberships.any(
      (m) => (planStatuses[m['scopeId']] ?? 'active') == 'active',
    );
  }

  /// Gently separates consecutive items coming from the same document page so
  /// sibling cards do not leak each other's answers.
  List<ReviewQueueEntry> _spaceSiblings(List<ReviewQueueEntry> input) {
    if (input.length <= 2) return input;
    final remaining = [...input];
    final result = <ReviewQueueEntry>[];
    String? lastKey;
    while (remaining.isNotEmpty) {
      var pickIndex = 0;
      if (lastKey != null) {
        final alt = remaining.indexWhere((e) => _siblingKey(e) != lastKey);
        if (alt != -1) pickIndex = alt;
      }
      final picked = remaining.removeAt(pickIndex);
      result.add(picked);
      lastKey = _siblingKey(picked);
    }
    return result;
  }

  String _siblingKey(ReviewQueueEntry entry) {
    final origin = entry.primaryOrigin;
    if (origin?.documentId != null && origin?.page != null) {
      return '${origin!.documentId}:${origin.page}';
    }
    if (entry.item.objective.isNotEmpty) {
      return 'obj:${entry.item.objective}';
    }
    return 'id:${entry.item.id}';
  }

  ReviewDashboardSummary buildDashboardSummary({
    ReviewScopeFilter scope = const ReviewScopeFilter(),
    int? budgetMinutes,
    DateTime? nowUtc,
  }) {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    final tz = getStudyTimezone();
    final todayDay = StudyTimeHelper.studyDayKey(now, timezone: tz);

    final allQueue = buildTodayQueue(
      scope: scope,
      budgetMinutes: budgetMinutes,
      includeOverflow: true,
      allowNewCardsWhenBacklogged: true,
      nowUtc: now,
    );
    final roundQueue = buildTodayQueue(
      scope: scope,
      budgetMinutes: budgetMinutes,
      includeOverflow: false,
      allowNewCardsWhenBacklogged: false,
      nowUtc: now,
    );

    final dueCount = allQueue.where((e) => !e.isNew).length;
    final overdueCount = allQueue.where((e) => e.overdueDays > 0).length;
    final newCount = allQueue.where((e) => e.isNew).length;
    final roundSeconds = roundQueue.fold<int>(
      0,
      (s, e) => s + e.item.estimatedSeconds,
    );
    final conceptCount = roundQueue.where((e) => !e.item.isComplex).length;
    final complexCount = roundQueue.where((e) => e.item.isComplex).length;

    final openChecksCount = _countQuery(
      "SELECT COUNT(*) AS n FROM review_checks WHERE status = 'open'",
    );
    final pendingCandidatesCount = _countQuery(
      "SELECT COUNT(*) AS n FROM review_candidates WHERE status = 'pending'",
    );
    final mistakesCount = _countQuery(
      "SELECT COUNT(*) AS n FROM review_items WHERE lifecycle = 'active' "
      "AND (wrong_streak > 0 OR error_reason != '')",
    );
    final totalActiveCount = _countQuery(
      "SELECT COUNT(*) AS n FROM review_items WHERE lifecycle = 'active'",
    );
    final todayAttemptRows = store.selectRows(
      'SELECT COUNT(DISTINCT item_id) AS items, COALESCE(SUM(active_seconds), 0) AS secs '
      "FROM review_attempts WHERE study_day = ? AND undone = 0 AND mode = 'formal'",
      [todayDay],
    );
    final todayCompleted =
        (todayAttemptRows.first['items'] as num?)?.toInt() ?? 0;
    final todaySeconds =
        (todayAttemptRows.first['secs'] as num?)?.toInt() ?? 0;

    return ReviewDashboardSummary(
      dueCount: dueCount,
      overdueCount: overdueCount,
      newCount: newCount,
      plannedRoundCount: roundQueue.length,
      plannedConceptCount: conceptCount,
      plannedComplexCount: complexCount,
      plannedMinutes: roundSeconds == 0 ? 0 : math.max(1, (roundSeconds / 60).round()),
      unscheduledDueCount: math.max(0, dueCount - roundQueue.where((e) => !e.isNew).length),
      openChecksCount: openChecksCount,
      pendingCandidatesCount: pendingCandidatesCount,
      mistakesCount: mistakesCount,
      totalActiveCount: totalActiveCount,
      todayCompletedCount: todayCompleted,
      todayActiveMinutes: (todaySeconds / 60).round(),
      activeSession: getActiveSession(),
    );
  }

  // ---------------------------------------------------------------------------
  // Sessions & Idempotent Grading Transactions
  // ---------------------------------------------------------------------------

  ReviewSession? getActiveSession() {
    final rows = store.selectRows(
      "SELECT id FROM review_sessions WHERE status IN ('active', 'paused') "
      'ORDER BY updated_at_utc DESC LIMIT 1',
    );
    if (rows.isEmpty) return null;
    return getSession(rows.first['id'] as String);
  }

  ReviewSession? getSession(String sessionId) {
    final rows = store.selectRows(
      'SELECT * FROM review_sessions WHERE id = ?',
      [sessionId],
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    final itemRows = store.selectRows(
      'SELECT * FROM review_session_items WHERE session_id = ? ORDER BY position ASC',
      [sessionId],
    );
    return ReviewSession(
      id: r['id'] as String,
      mode: ReviewSessionModeX.parse(r['mode']),
      scope: ReviewScopeFilter.tryDecode(r['scope_json'] as String? ?? '{}'),
      budgetMinutes: (r['budget_minutes'] as num).toInt(),
      status: ReviewSessionStatusX.parse(r['status']),
      currentIndex: (r['current_index'] as num).toInt(),
      activeSeconds: (r['active_seconds'] as num).toInt(),
      studyDay: r['study_day'] as String,
      scheduleTaskId: r['schedule_task_id'] as String?,
      scheduleBlockId: r['schedule_block_id'] as String?,
      startedAtUtc: DateTime.fromMillisecondsSinceEpoch(
        (r['started_at_utc'] as num).toInt(),
        isUtc: true,
      ),
      updatedAtUtc: DateTime.fromMillisecondsSinceEpoch(
        (r['updated_at_utc'] as num).toInt(),
        isUtc: true,
      ),
      completedAtUtc: r['completed_at_utc'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (r['completed_at_utc'] as num).toInt(),
              isUtc: true,
            ),
      items: [
        for (final ir in itemRows)
          ReviewSessionItem(
            sessionId: sessionId,
            position: (ir['position'] as num).toInt(),
            itemId: ir['item_id'] as String,
            itemRevision: (ir['item_revision'] as num).toInt(),
            draftAnswer: ir['draft_answer'] as String? ?? '',
            draftNotes: ir['draft_notes'] as String? ?? '',
            usedHint: (ir['used_hint'] as num).toInt() != 0,
            viewedSource: (ir['viewed_source'] as num).toInt() != 0,
            status: ir['status'] as String? ?? 'pending',
            attemptId: ir['attempt_id'] as String?,
            updatedAtUtc: DateTime.fromMillisecondsSinceEpoch(
              (ir['updated_at_utc'] as num).toInt(),
              isUtc: true,
            ),
          ),
      ],
    );
  }

  ReviewSession startSession({
    ReviewSessionMode mode = ReviewSessionMode.formal,
    ReviewScopeFilter scope = const ReviewScopeFilter(),
    int? budgetMinutes,
    List<String>? explicitItemIds,
    String? scheduleTaskId,
    String? scheduleBlockId,
    DateTime? nowUtc,
  }) {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    final budget = budgetMinutes ?? getDefaultBudgetMinutes();
    final tz = getStudyTimezone();
    final studyDay = StudyTimeHelper.studyDayKey(now, timezone: tz);

    return store.transact(() {
      final items = <ReviewItem>[];
      if (explicitItemIds != null && explicitItemIds.isNotEmpty) {
        for (final id in explicitItemIds) {
          final item = getItem(id);
          if (item != null && item.lifecycle == ReviewItemLifecycle.active) {
            items.add(item);
          }
        }
      } else if (mode == ReviewSessionMode.free) {
        final all = queryItems(
          scope: scope,
          lifecycle: ReviewItemLifecycle.active,
          limit: 50,
        );
        items.addAll(all.map((e) => e.item));
      } else {
        final queue = buildTodayQueue(
          scope: scope,
          budgetMinutes: budget,
          nowUtc: now,
        );
        items.addAll(queue.map((e) => e.item));
      }

      final sessionId = _uuid.v4();
      final session = ReviewSession(
        id: sessionId,
        mode: mode,
        scope: scope,
        budgetMinutes: budget,
        status: ReviewSessionStatus.active,
        currentIndex: 0,
        activeSeconds: 0,
        studyDay: studyDay,
        scheduleTaskId: scheduleTaskId,
        scheduleBlockId: scheduleBlockId,
        startedAtUtc: now,
        updatedAtUtc: now,
        items: [
          for (var i = 0; i < items.length; i++)
            ReviewSessionItem(
              sessionId: sessionId,
              position: i,
              itemId: items[i].id,
              itemRevision: items[i].revision,
              updatedAtUtc: now,
            ),
        ],
      );

      store.executeSql(
        '''
        INSERT INTO review_sessions
          (id, mode, scope_json, budget_minutes, status, current_index,
           active_seconds, study_day, schedule_task_id, schedule_block_id,
           started_at_utc, updated_at_utc, completed_at_utc, data)
        VALUES (?, ?, ?, ?, ?, 0, 0, ?, ?, ?, ?, ?, NULL, ?)
      ''',
        [
          session.id,
          session.mode.name,
          jsonEncode(scope.toJson()),
          budget,
          session.status.name,
          studyDay,
          scheduleTaskId,
          scheduleBlockId,
          now.millisecondsSinceEpoch,
          now.millisecondsSinceEpoch,
          jsonEncode({'budgetMinutes': budget}),
        ],
      );
      for (final si in session.items) {
        store.executeSql(
          '''
          INSERT INTO review_session_items
            (session_id, position, item_id, item_revision, draft_answer,
             draft_notes, used_hint, viewed_source, status, attempt_id, updated_at_utc)
          VALUES (?, ?, ?, ?, '', '', 0, 0, 'pending', NULL, ?)
        ''',
          [
            si.sessionId,
            si.position,
            si.itemId,
            si.itemRevision,
            now.millisecondsSinceEpoch,
          ],
        );
      }
      return session;
    });
  }

  void updateSessionProgress(
    String sessionId, {
    int? position,
    String? draftAnswer,
    String? draftNotes,
    bool? usedHint,
    bool? viewedSource,
    String? itemStatus,
    int? activeSecondsDelta,
    ReviewSessionStatus? sessionStatus,
    DateTime? nowUtc,
  }) {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    store.transact(() {
      if (position != null) {
        final sets = <String>['updated_at_utc = ?'];
        final params = <Object?>[now.millisecondsSinceEpoch];
        if (draftAnswer != null) {
          sets.add('draft_answer = ?');
          params.add(draftAnswer);
        }
        if (draftNotes != null) {
          sets.add('draft_notes = ?');
          params.add(draftNotes);
        }
        if (usedHint != null) {
          sets.add('used_hint = ?');
          params.add(usedHint ? 1 : 0);
        }
        if (viewedSource != null) {
          sets.add('viewed_source = ?');
          params.add(viewedSource ? 1 : 0);
        }
        if (itemStatus != null) {
          sets.add('status = ?');
          params.add(itemStatus);
        }
        params.addAll([sessionId, position]);
        store.executeSql(
          'UPDATE review_session_items SET ${sets.join(', ')} WHERE session_id = ? AND position = ?',
          params,
        );
      }
      final sSets = <String>['updated_at_utc = ?'];
      final sParams = <Object?>[now.millisecondsSinceEpoch];
      if (sessionStatus != null) {
        sSets.add('status = ?');
        sParams.add(sessionStatus.name);
        if (sessionStatus == ReviewSessionStatus.completed) {
          sSets.add('completed_at_utc = ?');
          sParams.add(now.millisecondsSinceEpoch);
        }
      }
      if (activeSecondsDelta != null && activeSecondsDelta > 0) {
        sSets.add('active_seconds = active_seconds + ?');
        sParams.add(activeSecondsDelta);
      }
      sParams.add(sessionId);
      store.executeSql(
        'UPDATE review_sessions SET ${sSets.join(', ')} WHERE id = ?',
        sParams,
      );
    });
  }

  void skipOrAdvanceSessionItem(
    String sessionId,
    int position, {
    String status = 'skipped',
    DateTime? nowUtc,
  }) {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    store.transact(() {
      store.executeSql(
        'UPDATE review_session_items SET status = ?, updated_at_utc = ? WHERE session_id = ? AND position = ?',
        [status, now.millisecondsSinceEpoch, sessionId, position],
      );
      _advanceSessionIndexLocked(sessionId, now);
    });
  }

  /// Atomic review submission & scheduling commit.
  ///
  /// Guarantees idempotency via [operationId], checks optimistic
  /// [expectedItemRevision] and active lifecycle, saves the attempt and audit
  /// event in the same transaction as the updated schedule, and advances the
  /// session cursor if [sessionId] & [sessionPosition] are provided.
  SubmitGradeResult submitAttemptAndGrade({
    required String itemId,
    required String operationId,
    int? expectedItemRevision,
    String? sessionId,
    int? sessionPosition,
    String mode = 'formal', // formal | free | consolidation
    String answerText = '',
    bool usedHint = false,
    bool viewedSource = false,
    bool selfEval = true,
    ReviewRating? rating,
    ComplexityOutcome? complexityOutcome,
    AiReviewSuggestion? aiSuggestion,
    bool aiDisputed = false,
    ReviewResultSource resultSource = ReviewResultSource.self,
    int activeSeconds = 0,
    String? errorReason,
    String? correctionNote,
    DateTime? nowUtc,
    int? fuzzSeed,
  }) {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    final tz = getStudyTimezone();
    final studyDay = StudyTimeHelper.studyDayKey(now, timezone: tz);

    return store.transact(() {
      final existingAttemptRows = store.selectRows(
        'SELECT data FROM review_attempts WHERE operation_id = ?',
        [operationId],
      );
      if (existingAttemptRows.isNotEmpty) {
        final existingAttempt = ReviewAttempt.fromJson(
          _decode(existingAttemptRows.first),
        );
        final item = getItem(itemId)!;
        final schedule = getSchedule(itemId)!;
        return SubmitGradeResult(
          item: item,
          schedule: schedule,
          attempt: existingAttempt,
          event: null,
          guidance: '已保存本次提交（重复提交已自动去重）。',
          duplicateIgnored: true,
        );
      }

      final currentItem = getItem(itemId);
      if (currentItem == null || currentItem.lifecycle == ReviewItemLifecycle.trashed) {
        throw const ReviewStaleVersionException('这道题已被删除或移入回收站，不能继续保存评分。');
      }
      if (expectedItemRevision != null &&
          currentItem.revision != expectedItemRevision) {
        throw ReviewStaleVersionException(
          '题目内容在作答期间已更新（当前版本 v${currentItem.revision}），请先核对新题面后再提交。',
        );
      }

      final beforeSchedule =
          getSchedule(itemId) ??
          ReviewScheduleState(
            itemId: itemId,
            mode: currentItem.scheduleMode,
            algorithmDueAtUtc: now,
            updatedAt: now,
          );

      // Avoid recording assistance as an independent recall pass.
      var effectiveMode = mode;
      if (sessionId != null && mode == 'formal') {
        final priorDoneInSession = store.selectRows(
          "SELECT 1 FROM review_attempts WHERE session_id = ? AND item_id = ? AND undone = 0 AND mode = 'formal' LIMIT 1",
          [sessionId, itemId],
        );
        if (priorDoneInSession.isNotEmpty) {
          effectiveMode = 'consolidation';
        }
      }

      final attemptId = _uuid.v4();
      final attempt = ReviewAttempt(
        id: attemptId,
        itemId: itemId,
        sessionId: sessionId,
        itemRevision: currentItem.revision,
        mode: effectiveMode,
        answerText: answerText,
        usedHint: usedHint,
        viewedSource: viewedSource,
        selfEval: selfEval,
        rating: rating,
        complexityOutcome: complexityOutcome,
        aiSuggestion: aiSuggestion,
        aiDisputed: aiDisputed,
        resultSource: resultSource,
        activeSeconds: math.max(0, activeSeconds),
        studyDay: studyDay,
        createdAtUtc: now,
        operationId: operationId,
        errorReason: errorReason ?? currentItem.errorReason,
        correctionNote: correctionNote ?? currentItem.correctionNote,
      );

      ReviewScheduleState nextSchedule = beforeSchedule;
      var updatedItem = currentItem;
      var guidance = '';

      if (effectiveMode == 'formal') {
        if (currentItem.scheduleMode == ReviewScheduleMode.fsrs) {
          final r = rating ?? ReviewRating.good;
          final effectiveRating =
              (usedHint || viewedSource) && r == ReviewRating.again
                  ? ReviewRating.again
                  : r;
          nextSchedule = fsrs.grade(
            beforeSchedule,
            effectiveRating,
            nowUtc: now,
            seed: fuzzSeed,
          );
          final failed = effectiveRating == ReviewRating.again;
          final independent = !failed && !usedHint && !viewedSource;
          final priorIndependentDays = _distinctIndependentDays(itemId);
          final nextCrossDay = currentItem.crossDayRedoPassed ||
              (independent &&
                  priorIndependentDays.isNotEmpty &&
                  !priorIndependentDays.contains(studyDay));

          updatedItem = currentItem.copyWith(
            wrongStreak: failed ? currentItem.wrongStreak + 1 : 0,
            correctStreak: independent ? currentItem.correctStreak + 1 : 0,
            crossDayRedoPassed: nextCrossDay,
            errorReason: errorReason ?? currentItem.errorReason,
            correctionNote: correctionNote ?? currentItem.correctionNote,
            corrected:
                (correctionNote != null && correctionNote.trim().isNotEmpty)
                    ? true
                    : currentItem.corrected,
            updatedAt: now,
          );
          guidance =
              '下次建议时间：${FsrsScheduler.formatInterval(now, nextSchedule.algorithmDueAtUtc!)}';
        } else {
          final outcome = complexityOutcome ?? ComplexityOutcome.partial;
          final trainer = TrainingScheduler(
            repeatFailureThreshold: getRepeatFailureThreshold(),
          );
          nextSchedule = trainer.schedule(
            current: beforeSchedule,
            item: currentItem,
            outcome: outcome,
            usedAssistance: usedHint || viewedSource,
            nowUtc: now,
            timezone: tz,
          );
          guidance = trainer.explainOutcome(
            item: currentItem,
            outcome: outcome,
            usedAssistance: usedHint || viewedSource,
            nextState: nextSchedule,
          );
          final failed = outcome == ComplexityOutcome.incomplete;
          final independent =
              outcome == ComplexityOutcome.independentCorrect &&
              !usedHint &&
              !viewedSource;
          final priorIndependentDays = _distinctIndependentDays(itemId);
          final crossDay = currentItem.crossDayRedoPassed ||
              (independent &&
                  (priorIndependentDays.isNotEmpty &&
                      !priorIndependentDays.contains(studyDay)));
          final appVerified = currentItem.applicationVerified ||
              (independent &&
                  (currentItem.kind == ReviewItemKind.application ||
                      currentItem.variantParentId != null));
          updatedItem = currentItem.copyWith(
            wrongStreak: failed
                ? currentItem.wrongStreak + 1
                : (independent ? 0 : currentItem.wrongStreak),
            correctStreak: independent ? currentItem.correctStreak + 1 : 0,
            crossDayRedoPassed: crossDay,
            applicationVerified: appVerified,
            errorReason: errorReason ?? currentItem.errorReason,
            correctionNote: correctionNote ?? currentItem.correctionNote,
            corrected:
                (correctionNote != null && correctionNote.trim().isNotEmpty)
                    ? true
                    : currentItem.corrected,
            updatedAt: now,
          );
          if (outcome == ComplexityOutcome.disputed || aiDisputed) {
            upsertCheck(
              originKey: 'attempt_dispute:$attemptId',
              targetType: ReviewCheckTargetType.answer,
              targetId: itemId,
              targetVersion: currentItem.revision,
              itemId: itemId,
              sessionId: sessionId,
              question: currentItem.prompt,
              answer: answerText,
              feedback: aiSuggestion?.rationale ?? '',
              reason: aiDisputed ? 'AI 评语存疑' : '参考答案/评分存疑',
              nowUtc: now,
            );
          }
        }
      } else {
        guidance = effectiveMode == 'free'
            ? '自由练习已记录，未改动正式复习计划。'
            : '本轮巩固重复已记录，不重复计入正式到期完成。';
      }

      _insertAttemptRow(attempt);
      _updateItemRow(updatedItem);

      ReviewEvent? event;
      if (effectiveMode == 'formal') {
        _upsertScheduleRow(nextSchedule);
        event = ReviewEvent(
          id: _uuid.v4(),
          itemId: itemId,
          attemptId: attemptId,
          operationId: operationId,
          eventType: 'grade',
          algorithmVersion: nextSchedule.algorithmVersion,
          beforeSchedule: beforeSchedule,
          afterSchedule: nextSchedule,
          studyDay: studyDay,
          createdAtUtc: now,
          note: guidance,
        );
        _insertEventRow(event);
      }

      if (sessionId != null && sessionPosition != null) {
        store.executeSql(
          "UPDATE review_session_items SET status = 'done', attempt_id = ?, "
          'used_hint = ?, viewed_source = ?, updated_at_utc = ? '
          'WHERE session_id = ? AND position = ?',
          [
            attemptId,
            usedHint ? 1 : 0,
            viewedSource ? 1 : 0,
            now.millisecondsSinceEpoch,
            sessionId,
            sessionPosition,
          ],
        );
        if (activeSeconds > 0) {
          store.executeSql(
            'UPDATE review_sessions SET active_seconds = active_seconds + ? WHERE id = ?',
            [activeSeconds, sessionId],
          );
        }
        _advanceSessionIndexLocked(sessionId, now);
      }

      return SubmitGradeResult(
        item: updatedItem,
        schedule: nextSchedule,
        attempt: attempt,
        event: event,
        guidance: guidance,
      );
    });
  }

  /// Reverts the latest formal grade event for [itemId] without deleting history.
  ReviewScheduleState? undoLastGrade(
    String itemId, {
    String? sessionId,
    DateTime? nowUtc,
  }) {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    return _atomic(() {
      final eventRows = store.selectRows(
        "SELECT data FROM review_events WHERE item_id = ? AND event_type = 'grade' "
        'ORDER BY created_at_utc DESC LIMIT 1',
        [itemId],
      );
      if (eventRows.isEmpty) return null;
      final lastGrade = ReviewEvent.fromJson(_decode(eventRows.first));
      final alreadyUndone = store.selectRows(
        'SELECT undone FROM review_attempts WHERE id = ?',
        [lastGrade.attemptId],
      );
      if (alreadyUndone.isEmpty ||
          (alreadyUndone.first['undone'] as num).toInt() != 0) {
        return getSchedule(itemId);
      }

      store.executeSql(
        'UPDATE review_attempts SET undone = 1 WHERE id = ?',
        [lastGrade.attemptId],
      );
      final restored = lastGrade.beforeSchedule.copyWith(
        revision: (getSchedule(itemId)?.revision ?? lastGrade.afterSchedule.revision) + 1,
        updatedAt: now,
      );
      _upsertScheduleRow(restored);
      _insertEventRow(
        ReviewEvent(
          id: _uuid.v4(),
          itemId: itemId,
          attemptId: lastGrade.attemptId,
          operationId: _uuid.v4(),
          eventType: 'undo',
          algorithmVersion: restored.algorithmVersion,
          beforeSchedule: lastGrade.afterSchedule,
          afterSchedule: restored,
          studyDay: StudyTimeHelper.studyDayKey(now, timezone: getStudyTimezone()),
          createdAtUtc: now,
          note: '撤销上一次评分',
        ),
      );

      if (sessionId != null) {
        store.executeSql(
          "UPDATE review_session_items SET status = 'pending', attempt_id = NULL, updated_at_utc = ? "
          'WHERE session_id = ? AND item_id = ?',
          [now.millisecondsSinceEpoch, sessionId, itemId],
        );
        final rows = store.selectRows(
          "SELECT MIN(position) AS pos FROM review_session_items WHERE session_id = ? AND status = 'pending'",
          [sessionId],
        );
        final minPos = (rows.first['pos'] as num?)?.toInt();
        if (minPos != null) {
          store.executeSql(
            "UPDATE review_sessions SET status = 'active', current_index = ?, completed_at_utc = NULL, updated_at_utc = ? WHERE id = ?",
            [minPos, now.millisecondsSinceEpoch, sessionId],
          );
        }
      }
      return restored;
    });
  }

  /// Deterministic replay of all non-undone formal attempts for [itemId].
  ReviewScheduleState? recomputeItemSchedule(String itemId, {DateTime? nowUtc}) {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    return _atomic(() {
      final item = getItem(itemId);
      if (item == null) return null;
      var state = ReviewScheduleState(
        itemId: itemId,
        mode: item.scheduleMode,
        algorithmDueAtUtc: item.createdAt,
        updatedAt: item.createdAt,
      );
      final attempts = store.selectRows(
        "SELECT data FROM review_attempts WHERE item_id = ? AND undone = 0 AND mode = 'formal' "
        'ORDER BY created_at_utc ASC',
        [itemId],
      );
      final tz = getStudyTimezone();
      for (final row in attempts) {
        final a = ReviewAttempt.fromJson(_decode(row));
        if (item.scheduleMode == ReviewScheduleMode.fsrs && a.rating != null) {
          state = fsrs.grade(state, a.rating!, nowUtc: a.createdAtUtc);
        } else if (item.scheduleMode == ReviewScheduleMode.training &&
            a.complexityOutcome != null) {
          state = training.schedule(
            current: state,
            item: item,
            outcome: a.complexityOutcome!,
            usedAssistance: a.isAssisted,
            nowUtc: a.createdAtUtc,
            timezone: tz,
          );
        }
      }
      _upsertScheduleRow(state.copyWith(updatedAt: now));
      return state;
    });
  }

  // ---------------------------------------------------------------------------
  // Paginated Queries, Search, Notes Sync & Document Source Updates
  // ---------------------------------------------------------------------------

  List<ReviewQueueEntry> queryItems({
    ReviewScopeFilter scope = const ReviewScopeFilter(),
    ReviewItemLifecycle? lifecycle,
    bool? pausedOnly,
    int limit = 50,
    int offset = 0,
    DateTime? nowUtc,
  }) {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    final tz = getStudyTimezone();
    final today = StudyTimeHelper.studyDate(now, timezone: tz);

    final where = <String>[];
    final params = <Object?>[];

    if (lifecycle != null) {
      where.add('i.lifecycle = ?');
      params.add(lifecycle.name);
    } else {
      where.add("i.lifecycle != 'trashed'");
    }
    if (pausedOnly == true) {
      where.add("i.lifecycle = 'paused'");
    }
    if (scope.kind != null) {
      where.add('i.kind = ?');
      params.add(scope.kind!.name);
    }
    if (scope.mistakesOnly) {
      where.add("(i.wrong_streak > 0 OR i.error_reason != '')");
    }
    if (scope.query.trim().isNotEmpty) {
      final like = '%${scope.query.trim()}%';
      where.add(
        '(i.prompt LIKE ? OR i.objective LIKE ? OR i.error_reason LIKE ? OR i.correction_note LIKE ?)',
      );
      params.addAll([like, like, like, like]);
    }
    if (scope.documentId != null) {
      where.add(
        'EXISTS (SELECT 1 FROM review_origins o WHERE o.item_id = i.id AND o.document_id = ?)',
      );
      params.add(scope.documentId);
    }
    if (scope.planId != null) {
      where.add(
        "EXISTS (SELECT 1 FROM review_memberships m WHERE m.item_id = i.id AND m.scope_type = 'plan' AND m.scope_id = ?)",
      );
      params.add(scope.planId);
    }
    if (scope.tagId != null) {
      where.add(
        'EXISTS (SELECT 1 FROM review_tags t WHERE t.item_id = i.id AND t.tag_id = ?)',
      );
      params.add(scope.tagId);
    }

    final sql =
        'SELECT i.data AS item_data, s.data AS sched_data '
        'FROM review_items i '
        'LEFT JOIN review_schedules s ON s.item_id = i.id '
        '${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'} '
        'ORDER BY i.starred DESC, i.updated_at DESC, i.id '
        'LIMIT ? OFFSET ?';
    params.addAll([limit, offset]);

    final rows = store.selectRows(sql, params);
    return [
      for (final r in rows)
        _hydrateEntry(
          ReviewItem.fromJson(_decodeString(r['item_data'] as String)),
          r['sched_data'] == null
              ? ReviewScheduleState(itemId: '')
              : ReviewScheduleState.fromJson(
                  _decodeString(r['sched_data'] as String),
                ),
          today: today,
          tz: tz,
        ),
    ];
  }

  List<ReviewAttempt> queryAttemptHistory({
    String? itemId,
    bool includeUndone = false,
    int limit = 50,
    int offset = 0,
  }) {
    final where = <String>[];
    final params = <Object?>[];
    if (itemId != null) {
      where.add('item_id = ?');
      params.add(itemId);
    }
    if (!includeUndone) {
      where.add('undone = 0');
    }
    params.addAll([limit, offset]);
    final rows = store.selectRows(
      'SELECT data FROM review_attempts '
      '${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'} '
      'ORDER BY created_at_utc DESC LIMIT ? OFFSET ?',
      params,
    );
    return rows.map((r) => ReviewAttempt.fromJson(_decode(r))).toList();
  }

  /// Syncs note revisions so items backed by a modified note surface
  /// "来源笔记已更新" cleanly without altering the item automatically.
  int detectUpdatedSourceNotes() {
    final rows = store.selectRows(
      'SELECT o.id, o.note_revision AS orig_rev, n.revision AS live_rev '
      'FROM review_origins o '
      'INNER JOIN note_documents n ON n.id = o.note_id '
      'WHERE o.note_id IS NOT NULL AND o.note_revision IS NOT NULL',
    );
    var updatedCount = 0;
    for (final r in rows) {
      final origRev = (r['orig_rev'] as num).toInt();
      final liveRev = (r['live_rev'] as num).toInt();
      if (liveRev > origRev) updatedCount++;
    }
    return updatedCount;
  }

  void acknowledgeNoteSourceUpdate({
    required String itemId,
    required String noteId,
    required int currentNoteRevision,
    String? updatedPrompt,
    String? updatedAnswer,
    bool keepSchedule = true,
  }) {
    store.transact(() {
      final now = DateTime.now().toUtc();
      store.executeSql(
        'UPDATE review_origins SET note_revision = ?, updated_at = ? WHERE item_id = ? AND note_id = ?',
        [currentNoteRevision, now.millisecondsSinceEpoch, itemId, noteId],
      );
      if (updatedPrompt != null || updatedAnswer != null) {
        updateItemContent(
          itemId: itemId,
          prompt: updatedPrompt,
          answer: updatedAnswer,
          preserveScheduleOnTypo: keepSchedule,
          nowUtc: now,
        );
      }
    });
  }

  /// Called when documents are trashed, restored, or permanently purged so
  /// confirmed review items keep their snapshots while marking source status.
  void handleDocumentsLifecycleChanged(
    Iterable<String> documentIds, {
    required bool available,
    bool permanentPurge = false,
  }) {
    final ids = documentIds.toList();
    if (ids.isEmpty) return;
    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    _atomic<void>(() {
      for (final docId in ids) {
        store.executeSql(
          'UPDATE review_origins SET source_available = ?, updated_at = ? WHERE document_id = ?',
          [available ? 1 : 0, now, docId],
        );
        if (permanentPurge) {
          store.executeSql(
            "DELETE FROM review_candidates WHERE document_id = ? AND status = 'pending'",
            [docId],
          );
        }
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Calendar Batches & Exam Prep
  // ---------------------------------------------------------------------------

  /// Schedules one review batch task (`TaskActivity.review`) + calendar block
  /// into `study_tasks` and `calendar_blocks` without altering any card's
  /// `algorithmDueAtUtc`. Reuses an existing open block for the same day/session.
  ScheduleBatchResult scheduleReviewBatchToCalendar({
    required String planId,
    required LocalDate date,
    int startMinute = 19 * 60,
    int budgetMinutes = 20,
    String? sessionId,
    String title = '今日复习批次',
    DateTime? nowUtc,
  }) {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    final safeStart = startMinute.clamp(0, 1440 - budgetMinutes);
    final safeEnd = (safeStart + budgetMinutes).clamp(safeStart + 5, 1440);
    return store.transact(() {
      if (sessionId != null) {
        final existing = store.selectRows(
          'SELECT task_id, block_id, target_minutes FROM review_task_links '
          "WHERE session_id = ? AND status IN ('planned', 'active') LIMIT 1",
          [sessionId],
        );
        if (existing.isNotEmpty) {
          return ScheduleBatchResult(
            taskId: existing.first['task_id'] as String,
            blockId: existing.first['block_id'] as String? ?? '',
            dateIso: date.iso,
            startMinute: safeStart,
            minutes: (existing.first['target_minutes'] as num).toInt(),
            duplicateReused: true,
          );
        }
      }

      final taskId = _uuid.v4();
      final blockId = _uuid.v4();
      final nowIso = now.toIso8601String();
      final nowMs = now.millisecondsSinceEpoch;

      final taskData = {
        'id': taskId,
        'planId': planId,
        'title': title,
        'activity': 'review',
        'minutes': budgetMinutes,
        'priority': 8,
        'status': 'pending',
        'knowledge': '复习批次',
        'createdAt': nowIso,
        'updatedAt': nowIso,
      };
      store.executeSql(
        '''
        INSERT INTO study_tasks
          (id, plan_id, status, minutes, priority, material_document_id,
           material_hash, updated_at, data)
        VALUES (?, ?, 'pending', ?, 8, NULL, NULL, ?, ?)
      ''',
        [taskId, planId, budgetMinutes, nowMs, jsonEncode(taskData)],
      );

      final blockData = {
        'id': blockId,
        'planId': planId,
        'taskId': taskId,
        'title': title,
        'activity': 'review',
        'date': date.iso,
        'startMinute': safeStart,
        'endMinute': safeEnd,
        'kind': 'planned',
        'state': 'planned',
        'locked': false,
        'revision': 1,
        'updatedAt': nowIso,
      };
      store.executeSql(
        '''
        INSERT INTO calendar_blocks
          (id, plan_id, task_id, date, start_minute, end_minute, kind, state,
           locked, series_id, instance_key, revision, updated_at, data)
        VALUES (?, ?, ?, ?, ?, ?, 'planned', 'planned', 0, NULL, ?, 1, ?, ?)
      ''',
        [
          blockId,
          planId,
          taskId,
          date.iso,
          safeStart,
          safeEnd,
          'review_batch:$taskId',
          nowMs,
          jsonEncode(blockData),
        ],
      );

      store.executeSql(
        '''
        INSERT INTO review_task_links
          (id, task_id, block_id, session_id, plan_id, study_day, target_minutes,
           actual_seconds, status, created_at_utc, updated_at_utc, data)
        VALUES (?, ?, ?, ?, ?, ?, ?, 0, 'planned', ?, ?, ?)
      ''',
        [
          _uuid.v4(),
          taskId,
          blockId,
          sessionId,
          planId,
          date.iso,
          budgetMinutes,
          nowMs,
          nowMs,
          jsonEncode({'title': title}),
        ],
      );

      return ScheduleBatchResult(
        taskId: taskId,
        blockId: blockId,
        dateIso: date.iso,
        startMinute: safeStart,
        minutes: budgetMinutes,
        duplicateReused: false,
      );
    });
  }

  /// Marks a review calendar batch done while keeping real active seconds separate
  /// from the scheduled block duration.
  void completeScheduledBatch(
    String taskId, {
    required int actualActiveSeconds,
    bool partial = false,
    DateTime? nowUtc,
  }) {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    final nowMs = now.millisecondsSinceEpoch;
    store.transact(() {
      final linkRows = store.selectRows(
        'SELECT block_id, plan_id FROM review_task_links WHERE task_id = ?',
        [taskId],
      );
      if (linkRows.isEmpty) return;
      final blockId = linkRows.first['block_id'] as String?;
      store.executeSql(
        'UPDATE review_task_links SET status = ?, actual_seconds = ?, updated_at_utc = ? WHERE task_id = ?',
        [
          partial ? 'partial' : 'completed',
          math.max(0, actualActiveSeconds),
          nowMs,
          taskId,
        ],
      );
      if (blockId != null) {
        final bRows = store.selectRows(
          'SELECT data, revision FROM calendar_blocks WHERE id = ?',
          [blockId],
        );
        if (bRows.isNotEmpty) {
          final bData = _decodeString(bRows.first['data'] as String);
          bData['state'] = partial ? 'partial' : 'completed';
          bData['actualSeconds'] = actualActiveSeconds;
          bData['updatedAt'] = now.toIso8601String();
          final nextRev = (bRows.first['revision'] as num).toInt() + 1;
          store.executeSql(
            'UPDATE calendar_blocks SET state = ?, revision = ?, updated_at = ?, data = ? WHERE id = ?',
            [
              partial ? 'partial' : 'completed',
              nextRev,
              nowMs,
              jsonEncode(bData),
              blockId,
            ],
          );
        }
      }
    });
  }

  List<ExamPrepSummary> computeExamSummaries({
    int? dailyBudgetMinutes,
    DateTime? nowUtc,
  }) {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    final tz = getStudyTimezone();
    final today = StudyTimeHelper.studyDate(now, timezone: tz);
    final budget = dailyBudgetMinutes ?? getDefaultBudgetMinutes();

    final planRows = store.selectRows(
      "SELECT data FROM study_plans WHERE exam_date IS NOT NULL AND status = 'active' ORDER BY exam_date ASC",
    );
    final summaries = <ExamPrepSummary>[];
    for (final row in planRows) {
      final plan = StudyPlan.fromJson(_decode(row));
      final examDate = plan.examDate;
      if (examDate == null) continue;
      final daysRemaining = math.max(0, examDate.differenceInDays(today));
      final planQueue = buildTodayQueue(
        scope: ReviewScopeFilter(planId: plan.id),
        budgetMinutes: budget,
        includeOverflow: true,
        allowNewCardsWhenBacklogged: true,
        nowUtc: now,
      );
      final coveredItems = queryItems(
        scope: ReviewScopeFilter(planId: plan.id),
        lifecycle: ReviewItemLifecycle.active,
        limit: 5000,
      );
      final knowledgeRows = store.selectRows(
        'SELECT id FROM knowledge_items WHERE plan_id = ?',
        [plan.id],
      );
      final totalKnowledge = knowledgeRows.length;
      final coveredKnowledgeIds = <String>{
        for (final entry in coveredItems)
          if (entry.item.knowledgeObjectiveId != null &&
              entry.item.knowledgeObjectiveId!.isNotEmpty)
            entry.item.knowledgeObjectiveId!,
      };
      final coveredKnowledge = knowledgeRows
          .where((r) => coveredKnowledgeIds.contains(r['id'] as String))
          .length;
      final requiredSeconds = planQueue.fold<int>(
        0,
        (s, e) => s + e.item.estimatedSeconds,
      );
      final requiredMinutes = requiredSeconds == 0
          ? 0
          : math.max(1, (requiredSeconds / 60).ceil());
      final availableMinutes = math.max(1, daysRemaining) * budget;
      summaries.add(
        ExamPrepSummary(
          planId: plan.id,
          planTitle: plan.title,
          examDateIso: examDate.iso,
          daysRemaining: daysRemaining,
          coveredItemCount: coveredItems.length,
          uncoveredKnowledgeCount: math.max(0, totalKnowledge - coveredKnowledge),
          dueAndOverdueCount: planQueue.length,
          weakItemCount: coveredItems.where((e) => e.item.wrongStreak > 0).length,
          estimatedRequiredMinutes: requiredMinutes,
          estimatedAvailableMinutes: availableMinutes,
          deficitMinutes: math.max(0, requiredMinutes - availableMinutes),
        ),
      );
    }
    return summaries;
  }

  // ---------------------------------------------------------------------------
  // Statistics & Knowledge Evidence
  // ---------------------------------------------------------------------------

  ReviewStatsSummary computeStats({int windowDays = 30, DateTime? nowUtc}) {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    final tz = getStudyTimezone();
    final today = StudyTimeHelper.studyDate(now, timezone: tz);
    final sinceDate = today.addDays(-(windowDays - 1));
    final sinceIso = sinceDate.iso;

    final attemptRows = store.selectRows(
      'SELECT data FROM review_attempts WHERE undone = 0 AND study_day >= ? ORDER BY created_at_utc ASC',
      [sinceIso],
    );
    final attempts = attemptRows.map((r) => ReviewAttempt.fromJson(_decode(r))).toList();

    var totalAttempts = 0;
    var independentSample = 0;
    var independentSuccess = 0;
    var assisted = 0;
    var activeSeconds = 0;
    var errors = 0;

    final trendMap = <String, _MutableDayTrend>{};
    for (var i = 0; i < windowDays; i++) {
      final d = sinceDate.addDays(i).iso;
      trendMap[d] = _MutableDayTrend(d);
    }

    for (final a in attempts) {
      totalAttempts += 1;
      activeSeconds += a.activeSeconds;
      final t = trendMap[a.studyDay];
      if (t != null) {
        t.completedCount += 1;
        t.activeSeconds += a.activeSeconds;
      }
      if (a.mode != 'formal') continue;
      if (a.isAssisted) {
        assisted += 1;
        continue;
      }
      final failed =
          a.rating == ReviewRating.again ||
          a.complexityOutcome == ComplexityOutcome.incomplete;
      if (failed) errors += 1;
      independentSample += 1;
      final success = a.isIndependentSuccess;
      if (success) independentSuccess += 1;
      if (t != null) {
        t.independentTotal += 1;
        if (success) t.independentSuccess += 1;
      }
    }

    final itemRows = store.selectRows(
      "SELECT data FROM review_items WHERE lifecycle != 'trashed'",
    );
    final items = itemRows.map((r) => ReviewItem.fromJson(_decode(r))).toList();
    final correctedCount = items.where((i) => i.corrected).length;
    final crossDayCount = items.where((i) => i.crossDayRedoPassed).length;
    final variantCount = items.where((i) => i.applicationVerified).length;

    // 14-day due forecast
    final forecast = <String, int>{
      for (var i = 0; i < 14; i++) today.addDays(i).iso: 0,
    };
    for (final r in store.selectRows(
      'SELECT s.algorithm_due_at_utc, s.paused, i.lifecycle '
      'FROM review_schedules s INNER JOIN review_items i ON i.id = s.item_id '
      "WHERE s.paused = 0 AND i.lifecycle = 'active' AND s.algorithm_due_at_utc IS NOT NULL",
    )) {
      final dueMs = (r['algorithm_due_at_utc'] as num).toInt();
      final dueDay = StudyTimeHelper.studyDate(
        DateTime.fromMillisecondsSinceEpoch(dueMs, isUtc: true),
        timezone: tz,
      );
      final dayKey = dueDay.compareTo(today) < 0 ? today.iso : dueDay.iso;
      if (forecast.containsKey(dayKey)) {
        forecast[dayKey] = forecast[dayKey]! + 1;
      }
    }

    // Objective evidence tags
    final byObjective = <String, List<ReviewItem>>{};
    for (final item in items) {
      final key = item.objective.trim().isEmpty ? '未分类目标' : item.objective.trim();
      byObjective.putIfAbsent(key, () => []).add(item);
    }
    final evidenceList = <KnowledgeEvidenceSummary>[];
    final weakObjectives = <String>[];

    for (final entry in byObjective.entries) {
      final group = entry.value;
      final groupIds = {for (final i in group) i.id};
      final days = <String>{};
      DateTime? lastAt;
      var hasWrong = false;
      var hasApp = false;
      for (final i in group) {
        if (i.wrongStreak > 0) hasWrong = true;
        if (i.applicationVerified) hasApp = true;
        if (lastAt == null || i.updatedAt.isAfter(lastAt)) {
          lastAt = i.updatedAt;
        }
      }
      for (final a in attempts) {
        if (groupIds.contains(a.itemId) && a.isIndependentSuccess) {
          days.add(a.studyDay);
        }
      }
      final KnowledgeEvidenceLevel level;
      if (attempts.every((a) => !groupIds.contains(a.itemId)) &&
          group.every((i) => !i.crossDayRedoPassed && !i.applicationVerified)) {
        level = hasWrong
            ? KnowledgeEvidenceLevel.needsStudy
            : KnowledgeEvidenceLevel.unpracticed;
      } else if (hasApp && days.length >= 2) {
        level = KnowledgeEvidenceLevel.applicationVerified;
      } else if (days.length >= 2 || group.any((i) => i.crossDayRedoPassed)) {
        level = KnowledgeEvidenceLevel.crossDayRecall;
      } else if (hasWrong) {
        level = KnowledgeEvidenceLevel.needsStudy;
      } else {
        level = KnowledgeEvidenceLevel.practicing;
      }
      if (hasWrong && entry.key != '未分类目标') {
        weakObjectives.add(entry.key);
      }
      evidenceList.add(
        KnowledgeEvidenceSummary(
          objective: entry.key,
          itemCount: group.length,
          level: level,
          independentCrossDayDays: days.length,
          lastActivityAt: lastAt,
        ),
      );
    }

    return ReviewStatsSummary(
      windowDays: windowDays,
      totalAttempts: totalAttempts,
      independentSampleCount: independentSample,
      independentSuccessCount: independentSuccess,
      assistedCount: assisted,
      activeMinutes: (activeSeconds / 60).round(),
      errorsLogged: errors,
      correctedCount: correctedCount,
      crossDayRedoPassedCount: crossDayCount,
      variantPassedCount: variantCount,
      dailyTrends: [for (final m in trendMap.values) m.build()],
      forecastNext14Days: forecast,
      knowledgeEvidence: evidenceList,
      weakObjectives: weakObjectives,
    );
  }

  // ---------------------------------------------------------------------------
  // Export & Full Package Round-Trip
  // ---------------------------------------------------------------------------

  String exportMarkdownReport({DateTime? nowUtc}) {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    final stats = computeStats(nowUtc: now);
    final items = queryItems(limit: 5000, nowUtc: now);
    final buf = StringBuffer()
      ..writeln('# Quelyt 复习与错题报告')
      ..writeln()
      ..writeln('生成时间（UTC）：${now.toIso8601String()}')
      ..writeln('近 30 天正式独立回忆样本：${stats.independentSuccessCount}/${stats.independentSampleCount}')
      ..writeln('有效活跃复习用时：${stats.activeMinutes} 分钟')
      ..writeln('已订正：${stats.correctedCount} · 跨日重做通过：${stats.crossDayRedoPassedCount}')
      ..writeln();
    for (final entry in items) {
      final i = entry.item;
      buf.writeln('## ${i.objective.isEmpty ? i.prompt : i.objective}');
      buf.writeln('- 题型：${i.kind.label} · 调度：${i.scheduleMode.label}');
      buf.writeln('- 题目：${i.prompt}');
      if (i.answer.isNotEmpty) buf.writeln('- 参考答案：${i.answer}');
      if (i.errorReason.isNotEmpty) buf.writeln('- 错因：${i.errorReason}');
      if (i.correctionNote.isNotEmpty) buf.writeln('- 订正笔记：${i.correctionNote}');
      if (entry.primaryOrigin != null) {
        buf.writeln(
          '- 来源：${entry.primaryOrigin!.displayLabel}'
          '${entry.primaryOrigin!.sourceAvailable ? '' : '（原出处已不可用，已保留快照）'}',
        );
      }
      buf.writeln();
    }
    return buf.toString();
  }

  String exportCsv() {
    final items = queryItems(limit: 5000);
    String esc(String s) => '"${s.replaceAll('"', '""')}"';
    final buf = StringBuffer()
      ..writeln(
        '# Quelyt Review CSV Export (Note: generic CSV does not preserve binary images, full event logs or FSRS state; use JSON package for full restore)',
      )
      ..writeln('id,kind,schedule_mode,objective,prompt,answer,hint,error_reason,correction_note,due_utc');
    for (final e in items) {
      buf.writeln(
        [
          esc(e.item.id),
          esc(e.item.kind.name),
          esc(e.item.scheduleMode.name),
          esc(e.item.objective),
          esc(e.item.prompt),
          esc(e.item.answer),
          esc(e.item.hint),
          esc(e.item.errorReason),
          esc(e.item.correctionNote),
          esc(e.schedule.algorithmDueAtUtc?.toIso8601String() ?? ''),
        ].join(','),
      );
    }
    return buf.toString();
  }

  String exportFullPackageJson() {
    final items = [
      for (final r in store.selectRows('SELECT data FROM review_items'))
        _decode(r),
    ];
    final schedules = [
      for (final r in store.selectRows('SELECT data FROM review_schedules'))
        _decode(r),
    ];
    final origins = [
      for (final r in store.selectRows('SELECT data FROM review_origins'))
        _decode(r),
    ];
    final attempts = [
      for (final r in store.selectRows('SELECT data FROM review_attempts'))
        _decode(r),
    ];
    final events = [
      for (final r in store.selectRows('SELECT data FROM review_events'))
        _decode(r),
    ];
    final checks = [
      for (final r in store.selectRows('SELECT data FROM review_checks'))
        _decode(r),
    ];
    final candidates = [
      for (final r in store.selectRows('SELECT data FROM review_candidates'))
        _decode(r),
    ];
    return const JsonEncoder.withIndent('  ').convert({
      'format': 'quelyt-review-package',
      'formatVersion': 1,
      'exportedAtUtc': DateTime.now().toUtc().toIso8601String(),
      'items': items,
      'schedules': schedules,
      'origins': origins,
      'attempts': attempts,
      'events': events,
      'checks': checks,
      'candidates': candidates,
    });
  }

  int importFullPackageJson(String jsonRaw) {
    final decoded = jsonDecode(jsonRaw);
    if (decoded is! Map || decoded['format'] != 'quelyt-review-package') {
      throw const FormatException('不是有效的 Quelyt 复习导出包。');
    }
    return store.transact(() {
      var imported = 0;
      for (final raw in (decoded['items'] as List? ?? const [])) {
        if (raw is! Map) continue;
        final item = ReviewItem.fromJson(Map<String, dynamic>.from(raw));
        _insertItemRow(item, replace: true);
        imported++;
      }
      for (final raw in (decoded['schedules'] as List? ?? const [])) {
        if (raw is! Map) continue;
        final sched = ReviewScheduleState.fromJson(
          Map<String, dynamic>.from(raw),
        );
        _upsertScheduleRow(sched);
      }
      for (final raw in (decoded['origins'] as List? ?? const [])) {
        if (raw is! Map) continue;
        final origin = ReviewOrigin.fromJson(Map<String, dynamic>.from(raw));
        _upsertOriginRow(origin);
      }
      for (final raw in (decoded['attempts'] as List? ?? const [])) {
        if (raw is! Map) continue;
        final attempt = ReviewAttempt.fromJson(Map<String, dynamic>.from(raw));
        _insertAttemptRow(attempt, ignoreDuplicate: true);
      }
      for (final raw in (decoded['events'] as List? ?? const [])) {
        if (raw is! Map) continue;
        final event = ReviewEvent.fromJson(Map<String, dynamic>.from(raw));
        _insertEventRow(event, ignoreDuplicate: true);
      }
      return imported;
    });
  }

  // ---------------------------------------------------------------------------
  // Internal SQL Helpers
  // ---------------------------------------------------------------------------

  ReviewQueueEntry _hydrateEntry(
    ReviewItem item,
    ReviewScheduleState schedule, {
    required LocalDate today,
    required String tz,
  }) {
    final origins = getOrigins(item.id);
    var overdueDays = 0;
    var reason = '已暂停';
    var isDue = false;
    final isNew = schedule.state == ReviewCardState.newCard;
    if (item.lifecycle == ReviewItemLifecycle.active && !schedule.paused) {
      if (isNew) {
        reason = '新加入';
        isDue = true;
      } else if (schedule.algorithmDueAtUtc != null) {
        final dueDate = StudyTimeHelper.studyDate(
          schedule.algorithmDueAtUtc!,
          timezone: tz,
        );
        overdueDays = today.differenceInDays(dueDate);
        isDue = overdueDays >= 0;
        reason = item.wrongStreak > 0
            ? '上次未独立完成'
            : (overdueDays > 0
                  ? '逾期 $overdueDays 天'
                  : (overdueDays == 0 ? '今日到期' : '${-overdueDays} 天后到期'));
      }
    }
    return ReviewQueueEntry(
      item: item,
      schedule: schedule,
      origins: origins,
      reasonLabel: reason,
      overdueDays: overdueDays,
      priorityScore: 0,
      isNew: isNew,
      isDueToday: isDue,
    );
  }

  List<(ReviewItem, ReviewScheduleState, List<ReviewOrigin>)> _loadActiveItemRows(
    ReviewScopeFilter scope,
  ) {
    final where = <String>["i.lifecycle = 'active'"];
    final params = <Object?>[];
    if (scope.kind != null) {
      where.add('i.kind = ?');
      params.add(scope.kind!.name);
    }
    if (scope.mistakesOnly) {
      where.add("(i.wrong_streak > 0 OR i.error_reason != '')");
    }
    if (scope.query.trim().isNotEmpty) {
      final like = '%${scope.query.trim()}%';
      where.add('(i.prompt LIKE ? OR i.objective LIKE ?)');
      params.addAll([like, like]);
    }
    if (scope.documentId != null) {
      where.add(
        'EXISTS (SELECT 1 FROM review_origins o WHERE o.item_id = i.id AND o.document_id = ?)',
      );
      params.add(scope.documentId);
    }
    if (scope.planId != null) {
      where.add(
        "EXISTS (SELECT 1 FROM review_memberships m WHERE m.item_id = i.id AND m.scope_type = 'plan' AND m.scope_id = ?)",
      );
      params.add(scope.planId);
    }
    if (scope.tagId != null) {
      where.add(
        'EXISTS (SELECT 1 FROM review_tags t WHERE t.item_id = i.id AND t.tag_id = ?)',
      );
      params.add(scope.tagId);
    }

    final rows = store.selectRows(
      'SELECT i.data AS item_data, s.data AS sched_data '
      'FROM review_items i LEFT JOIN review_schedules s ON s.item_id = i.id '
      'WHERE ${where.join(' AND ')}',
      params,
    );
    return [
      for (final r in rows)
        () {
          final item = ReviewItem.fromJson(
            _decodeString(r['item_data'] as String),
          );
          final schedule = r['sched_data'] == null
              ? ReviewScheduleState(
                  itemId: item.id,
                  mode: item.scheduleMode,
                  algorithmDueAtUtc: item.createdAt,
                )
              : ReviewScheduleState.fromJson(
                  _decodeString(r['sched_data'] as String),
                );
          return (item, schedule, getOrigins(item.id));
        }(),
    ];
  }

  Set<String> _distinctIndependentDays(String itemId) {
    final rows = store.selectRows(
      "SELECT data FROM review_attempts WHERE item_id = ? AND undone = 0 AND mode = 'formal'",
      [itemId],
    );
    return {
      for (final r in rows)
        if (ReviewAttempt.fromJson(_decode(r)).isIndependentSuccess)
          ReviewAttempt.fromJson(_decode(r)).studyDay,
    };
  }

  void _advanceSessionIndexLocked(String sessionId, DateTime now) {
    final pendingRows = store.selectRows(
      "SELECT position FROM review_session_items WHERE session_id = ? AND status = 'pending' "
      'ORDER BY position ASC LIMIT 1',
      [sessionId],
    );
    if (pendingRows.isEmpty) {
      final totalRows = store.selectRows(
        'SELECT COUNT(*) AS n FROM review_session_items WHERE session_id = ?',
        [sessionId],
      );
      final total = (totalRows.first['n'] as num).toInt();
      store.executeSql(
        "UPDATE review_sessions SET status = 'completed', current_index = ?, "
        'completed_at_utc = ?, updated_at_utc = ? WHERE id = ?',
        [
          total,
          now.millisecondsSinceEpoch,
          now.millisecondsSinceEpoch,
          sessionId,
        ],
      );
    } else {
      final nextPos = (pendingRows.first['position'] as num).toInt();
      store.executeSql(
        'UPDATE review_sessions SET current_index = ?, updated_at_utc = ? WHERE id = ?',
        [nextPos, now.millisecondsSinceEpoch, sessionId],
      );
    }
  }

  void _insertItemRow(ReviewItem item, {bool replace = false}) {
    final onConflict = replace
        ? '''
      ON CONFLICT(id) DO UPDATE SET
        kind = excluded.kind,
        schedule_mode = excluded.schedule_mode,
        objective = excluded.objective,
        prompt = excluded.prompt,
        answer = excluded.answer,
        steps_json = excluded.steps_json,
        hint = excluded.hint,
        explanation = excluded.explanation,
        lifecycle = excluded.lifecycle,
        starred = excluded.starred,
        revision = excluded.revision,
        estimated_seconds = excluded.estimated_seconds,
        wrong_streak = excluded.wrong_streak,
        correct_streak = excluded.correct_streak,
        error_reason = excluded.error_reason,
        correction_note = excluded.correction_note,
        deleted_batch = excluded.deleted_batch,
        trashed_at = excluded.trashed_at,
        updated_at = excluded.updated_at,
        data = excluded.data
    '''
        : '';
    store.executeSql(
      '''
      INSERT INTO review_items
        (id, kind, schedule_mode, objective, prompt, answer, steps_json, hint,
         explanation, lifecycle, starred, revision, estimated_seconds,
         wrong_streak, correct_streak, error_reason, correction_note,
         deleted_batch, trashed_at, created_at, updated_at, data)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      $onConflict
    ''',
      [
        item.id,
        item.kind.name,
        item.scheduleMode.name,
        item.objective,
        item.prompt,
        item.answer,
        jsonEncode(item.steps),
        item.hint,
        item.explanation,
        item.lifecycle.name,
        item.starred ? 1 : 0,
        item.revision,
        item.estimatedSeconds,
        item.wrongStreak,
        item.correctStreak,
        item.errorReason,
        item.correctionNote,
        item.deletedBatch,
        item.trashedAt?.millisecondsSinceEpoch,
        item.createdAt.millisecondsSinceEpoch,
        item.updatedAt.millisecondsSinceEpoch,
        jsonEncode(item.toJson()),
      ],
    );
  }

  void _updateItemRow(ReviewItem item) => _insertItemRow(item, replace: true);

  void _insertRevisionRow(
    ReviewItem item, {
    required String reason,
    required DateTime nowUtc,
  }) {
    store.executeSql(
      '''
      INSERT INTO review_item_revisions
        (id, item_id, revision, reason, prompt, answer, created_at, data)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ''',
      [
        _uuid.v4(),
        item.id,
        item.revision,
        reason,
        item.prompt,
        item.answer,
        nowUtc.millisecondsSinceEpoch,
        jsonEncode(item.toJson()),
      ],
    );
  }

  void _upsertOriginRow(ReviewOrigin origin) {
    store.executeSql(
      '''
      INSERT INTO review_origins
        (id, item_id, origin_key, source_type, document_id, document_hash,
         page, region_json, note_id, note_revision, lesson_id, exercise_id,
         session_id, snapshot_text, source_available, created_at, updated_at, data)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(origin_key) DO UPDATE SET
        item_id = excluded.item_id,
        source_available = excluded.source_available,
        updated_at = excluded.updated_at,
        data = excluded.data
    ''',
      [
        origin.id,
        origin.itemId,
        origin.originKey,
        origin.sourceType,
        origin.documentId,
        origin.documentHash,
        origin.page,
        jsonEncode(origin.region.toJson()),
        origin.noteId,
        origin.noteRevision,
        origin.lessonId,
        origin.exerciseId,
        origin.sessionId,
        origin.snapshotText,
        origin.sourceAvailable ? 1 : 0,
        origin.createdAt.millisecondsSinceEpoch,
        origin.updatedAt.millisecondsSinceEpoch,
        jsonEncode(origin.toJson()),
      ],
    );
  }

  void _upsertScheduleRow(ReviewScheduleState schedule) {
    store.executeSql(
      '''
      INSERT INTO review_schedules
        (item_id, mode, algorithm_version, state, stability, difficulty,
         elapsed_days, scheduled_days, reps, lapses, step, training_stage,
         algorithm_due_at_utc, defer_until_utc, paused, revision,
         last_review_at_utc, updated_at, data)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(item_id) DO UPDATE SET
        mode = excluded.mode,
        algorithm_version = excluded.algorithm_version,
        state = excluded.state,
        stability = excluded.stability,
        difficulty = excluded.difficulty,
        elapsed_days = excluded.elapsed_days,
        scheduled_days = excluded.scheduled_days,
        reps = excluded.reps,
        lapses = excluded.lapses,
        step = excluded.step,
        training_stage = excluded.training_stage,
        algorithm_due_at_utc = excluded.algorithm_due_at_utc,
        defer_until_utc = excluded.defer_until_utc,
        paused = excluded.paused,
        revision = excluded.revision,
        last_review_at_utc = excluded.last_review_at_utc,
        updated_at = excluded.updated_at,
        data = excluded.data
    ''',
      [
        schedule.itemId,
        schedule.mode.name,
        schedule.algorithmVersion,
        schedule.state.name,
        schedule.stability,
        schedule.difficulty,
        schedule.elapsedDays,
        schedule.scheduledDays,
        schedule.reps,
        schedule.lapses,
        schedule.step,
        schedule.trainingStage,
        schedule.algorithmDueAtUtc?.millisecondsSinceEpoch,
        schedule.deferUntilUtc?.millisecondsSinceEpoch,
        schedule.paused ? 1 : 0,
        schedule.revision,
        schedule.lastReviewAtUtc?.millisecondsSinceEpoch,
        schedule.updatedAt.millisecondsSinceEpoch,
        jsonEncode(schedule.toJson()),
      ],
    );
  }

  void _insertAttemptRow(
    ReviewAttempt attempt, {
    bool ignoreDuplicate = false,
  }) {
    final verb = ignoreDuplicate ? 'INSERT OR IGNORE' : 'INSERT';
    store.executeSql(
      '''
      $verb INTO review_attempts
        (id, item_id, session_id, item_revision, mode, answer_text,
         answer_payload_json, used_hint, viewed_source, self_eval, rating,
         complexity_outcome, ai_suggestion_json, ai_disputed, result_source,
         active_seconds, study_day, created_at_utc, operation_id, undone, data)
      VALUES (?, ?, ?, ?, ?, ?, '{}', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''',
      [
        attempt.id,
        attempt.itemId,
        attempt.sessionId,
        attempt.itemRevision,
        attempt.mode,
        attempt.answerText,
        attempt.usedHint ? 1 : 0,
        attempt.viewedSource ? 1 : 0,
        attempt.selfEval ? 1 : 0,
        attempt.rating?.name,
        attempt.complexityOutcome?.name,
        attempt.aiSuggestion == null
            ? null
            : jsonEncode(attempt.aiSuggestion!.toJson()),
        attempt.aiDisputed ? 1 : 0,
        attempt.resultSource.name,
        attempt.activeSeconds,
        attempt.studyDay,
        attempt.createdAtUtc.millisecondsSinceEpoch,
        attempt.operationId,
        attempt.undone ? 1 : 0,
        jsonEncode(attempt.toJson()),
      ],
    );
  }

  void _insertEventRow(ReviewEvent event, {bool ignoreDuplicate = false}) {
    final verb = ignoreDuplicate ? 'INSERT OR IGNORE' : 'INSERT';
    store.executeSql(
      '''
      $verb INTO review_events
        (id, item_id, attempt_id, operation_id, event_type, algorithm_version,
         before_schedule_json, after_schedule_json, study_day, created_at_utc, data)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''',
      [
        event.id,
        event.itemId,
        event.attemptId,
        event.operationId,
        event.eventType,
        event.algorithmVersion,
        jsonEncode(event.beforeSchedule.toJson()),
        jsonEncode(event.afterSchedule.toJson()),
        event.studyDay,
        event.createdAtUtc.millisecondsSinceEpoch,
        jsonEncode(event.toJson()),
      ],
    );
  }

  void _upsertMembership(
    String itemId,
    String scopeType,
    String scopeId,
    DateTime nowUtc,
  ) {
    store.executeSql(
      'INSERT OR IGNORE INTO review_memberships (id, item_id, scope_type, scope_id, created_at) '
      'VALUES (?, ?, ?, ?, ?)',
      [_uuid.v4(), itemId, scopeType, scopeId, nowUtc.millisecondsSinceEpoch],
    );
  }

  ReviewCandidate? _findCandidateByOriginKey(String originKey) {
    final rows = store.selectRows(
      'SELECT data FROM review_candidates WHERE origin_key = ? LIMIT 1',
      [originKey],
    );
    return rows.isEmpty ? null : ReviewCandidate.fromJson(_decode(rows.first));
  }

  void _writeCandidateRow(ReviewCandidate candidate) {
    store.executeSql(
      '''
      INSERT INTO review_candidates
        (id, origin_key, source_type, document_id, note_id, lesson_id,
         exercise_id, session_id, title, prompt, answer, hint, explanation,
         status, linked_item_id, reason, created_at, updated_at, data)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(origin_key) DO UPDATE SET
        title = excluded.title,
        prompt = excluded.prompt,
        answer = excluded.answer,
        hint = excluded.hint,
        explanation = excluded.explanation,
        status = excluded.status,
        linked_item_id = excluded.linked_item_id,
        reason = excluded.reason,
        updated_at = excluded.updated_at,
        data = excluded.data
    ''',
      [
        candidate.id,
        candidate.originKey,
        candidate.sourceType,
        candidate.documentId,
        candidate.noteId,
        candidate.lessonId,
        candidate.exerciseId,
        candidate.sessionId,
        candidate.title,
        candidate.prompt,
        candidate.answer,
        candidate.hint,
        candidate.explanation,
        candidate.status.name,
        candidate.linkedItemId,
        candidate.reason,
        candidate.createdAt.millisecondsSinceEpoch,
        candidate.updatedAt.millisecondsSinceEpoch,
        jsonEncode(candidate.toJson()),
      ],
    );
  }

  int _countQuery(String sql, [List<Object?> params = const []]) {
    final rows = store.selectRows(sql, params);
    return (rows.first['n'] as num?)?.toInt() ?? 0;
  }

  T _atomic<T>(T Function() action) =>
      store.inTransaction ? action() : store.transact(action);

  static String hashAnswer(String answer) =>
      sha256.convert(utf8.encode(answer.trim())).toString();

  static Map<String, dynamic> _decode(Map<String, Object?> row) =>
      _decodeString(row['data'] as String);

  static Map<String, dynamic> _decodeString(String raw) =>
      Map<String, dynamic>.from(jsonDecode(raw) as Map);
}

class _MutableDayTrend {
  _MutableDayTrend(this.studyDay);
  final String studyDay;
  int completedCount = 0;
  int activeSeconds = 0;
  int independentSuccess = 0;
  int independentTotal = 0;

  ReviewDailyTrend build() => ReviewDailyTrend(
    studyDay: studyDay,
    completedCount: completedCount,
    activeSeconds: activeSeconds,
    independentSuccessCount: independentSuccess,
    independentTotalCount: independentTotal,
  );
}
