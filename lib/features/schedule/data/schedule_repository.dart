import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../../core/local_store.dart';
import '../../review/data/review_repository.dart';
import '../../review/models/review_models.dart';
import '../domain/schedule_engine.dart';
import '../domain/schedule_validator.dart';
import '../models/calendar_block.dart';
import '../models/daily_lesson.dart';
import '../models/knowledge_item.dart';
import '../models/lesson_review.dart';
import '../models/learning_record.dart';
import '../models/local_date.dart';
import '../models/plan_availability.dart';
import '../models/plan_source.dart';
import '../models/schedule_draft.dart';
import '../models/schedule_revision.dart';
import '../models/study_plan.dart';
import '../models/study_task.dart';

class ScheduleConflictException implements Exception {
  ScheduleConflictException(this.message);

  final String message;

  @override
  String toString() => message;
}

enum RepeatEditScope { thisOnly, thisAndFuture }

class ScheduleSaveResult {
  const ScheduleSaveResult({required this.tasks, required this.blocks});

  final List<StudyTask> tasks;
  final List<CalendarBlock> blocks;

  StudyTask get task => tasks.first;

  CalendarBlock get block => blocks.first;
}

/// All schedule persistence and transactional rules.
///
/// The repository uses the same [LocalStore] connection as the library so a
/// draft application, block edit and calendar revision bump share one
/// transaction. UI code never writes SQL.
class ScheduleRepository {
  ScheduleRepository(this.store);

  final LocalStore store;
  static const uuid = Uuid();
  static const String _calendarRevisionKey = 'schedule.calendarRevision';

  // ---------------------------------------------------------------------------
  // Revisions and plans
  // ---------------------------------------------------------------------------

  int get calendarRevision {
    final raw = store.getSetting(_calendarRevisionKey);
    return int.tryParse(raw ?? '') ?? 0;
  }

  void _bumpCalendarRevision() {
    store.setSetting(_calendarRevisionKey, '${calendarRevision + 1}');
  }

  List<StudyPlan> getPlans({bool includeArchived = true}) {
    final rows = store.selectRows(
      'SELECT data FROM study_plans '
      '${includeArchived ? '' : "WHERE status != 'archived' "}'
      'ORDER BY start_date, id',
    );
    return rows.map((row) => StudyPlan.fromJson(_decode(row))).toList();
  }

  StudyPlan? getPlan(String id) {
    final rows = store.selectRows(
      'SELECT data FROM study_plans WHERE id = ?',
      [id],
    );
    return rows.isEmpty ? null : StudyPlan.fromJson(_decode(rows.first));
  }

  StudyPlan savePlan(StudyPlan value) {
    if (value.title.trim().isEmpty) {
      throw ScheduleValidationException('计划名称不能为空。');
    }
    if (value.endDate < value.startDate) {
      throw ScheduleValidationException('计划结束日期不能早于开始日期。');
    }
    return store.transact(() => _savePlanInternal(value));
  }

  StudyPlan _savePlanInternal(StudyPlan value) {
    final existing = getPlan(value.id);
    final now = DateTime.now();
    final saved = value.copyWith(
      revision: existing == null ? 1 : existing.revision + 1,
      createdAt: existing?.createdAt ?? value.createdAt,
      updatedAt: now,
    );
    _writePlan(saved);
    _bumpCalendarRevision();
    return saved;
  }

  /// Applies a user-confirmed planning proposal as one transaction: the plan
  /// framework, its availability and the conversation binding either all
  /// succeed or all roll back.
  ({StudyPlan plan, PlanAvailability? availability}) applyPlanningSetup({
    required StudyPlan plan,
    PlanAvailability? availability,
    String? conversationId,
  }) {
    if (plan.title.trim().isEmpty) {
      throw ScheduleValidationException('计划名称不能为空。');
    }
    if (plan.endDate < plan.startDate) {
      throw ScheduleValidationException('计划结束日期不能早于开始日期。');
    }
    return store.transact(() {
      final saved = _savePlanInternal(plan);
      PlanAvailability? savedAvailability;
      if (availability != null) {
        savedAvailability = _saveAvailabilityInternal(
          availability.copyWith(planId: saved.id),
        );
      }
      if (conversationId != null) {
        _attachConversationToPlan(conversationId, saved.id);
      }
      return (plan: saved, availability: savedAvailability);
    });
  }

  void _attachConversationToPlan(String conversationId, String planId) {
    final rows = store.selectRows(
      'SELECT data FROM planning_conversations WHERE id = ?',
      [conversationId],
    );
    if (rows.isEmpty) return;
    final data = _decode(rows.first)..['planId'] = planId;
    final now = DateTime.now();
    data['updatedAt'] = now.toIso8601String();
    store.executeSql(
      'UPDATE planning_conversations SET plan_id = ?, updated_at = ?, data = ? '
      'WHERE id = ?',
      [planId, now.millisecondsSinceEpoch, jsonEncode(data), conversationId],
    );
  }

  void deletePlan(String id) {
    store.transact(() {
      store.executeSql('DELETE FROM study_plans WHERE id = ?', [id]);
      _bumpCalendarRevision();
    });
  }

  void _writePlan(StudyPlan plan) {
    store.executeSql(
      '''
      INSERT INTO study_plans
        (id, title, status, start_date, exam_date, revision, updated_at, data)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET title=excluded.title, status=excluded.status,
        start_date=excluded.start_date, exam_date=excluded.exam_date,
        revision=excluded.revision, updated_at=excluded.updated_at,
        data=excluded.data
      ''',
      [
        plan.id,
        plan.title,
        plan.status.name,
        plan.startDate.iso,
        plan.examDate?.iso,
        plan.revision,
        plan.updatedAt.millisecondsSinceEpoch,
        jsonEncode(plan.toJson()),
      ],
    );
  }

  void _touchPlan(String planId) {
    final plan = getPlan(planId);
    if (plan == null) throw ScheduleValidationException('计划已不存在。');
    final updated = plan.copyWith(
      revision: plan.revision + 1,
      updatedAt: DateTime.now(),
    );
    _writePlan(updated);
  }

  // ---------------------------------------------------------------------------
  // Plan material sources
  // ---------------------------------------------------------------------------

  List<PlanSource> getPlanSources(String planId) {
    final rows = store.selectRows(
      'SELECT data FROM plan_sources WHERE plan_id = ? '
      'ORDER BY purpose, start_page, id',
      [planId],
    );
    return rows.map((row) => PlanSource.fromJson(_decode(row))).toList();
  }

  PlanSource? getPlanSource(String id) {
    final rows = store.selectRows(
      'SELECT data FROM plan_sources WHERE id = ?',
      [id],
    );
    return rows.isEmpty ? null : PlanSource.fromJson(_decode(rows.first));
  }

  PlanSource savePlanSource(PlanSource value) =>
      store.transact(() => _savePlanSourceInternal(value));

  PlanSource _savePlanSourceInternal(PlanSource value) {
    final plan = getPlan(value.planId);
    if (plan == null) {
      throw ScheduleValidationException('计划已不存在，无法绑定材料。');
    }
    final document = store.getDocument(value.documentId);
    if (document == null) {
      throw ScheduleValidationException('这份资料已被删除，无法绑定。');
    }
    if (document.contentHash != value.documentHash) {
      throw ScheduleValidationException('资料版本已改变，请重新选择。');
    }
    if (value.startPage < 1 ||
        value.endPage < value.startPage ||
        value.endPage > document.pageCount) {
      throw ScheduleValidationException(
        '页码需在 1–${document.pageCount} 之间，且结束页不早于开始页。',
      );
    }
    final duplicate = store.selectRows(
      'SELECT id FROM plan_sources WHERE plan_id = ? AND document_id = ? '
      'AND purpose = ? AND start_page = ? AND end_page = ? AND id != ?',
      [
        value.planId,
        value.documentId,
        value.purpose.name,
        value.startPage,
        value.endPage,
        value.id,
      ],
    );
    if (duplicate.isNotEmpty) {
      throw ScheduleValidationException('这段材料已经绑定到这个计划。');
    }
    final existing = getPlanSource(value.id);
    final now = DateTime.now();
    final saved = value.copyWith(
      documentTitle: document.title,
      revision: existing == null ? 1 : existing.revision + 1,
      createdAt: existing?.createdAt ?? value.createdAt,
      updatedAt: now,
    );
    store.executeSql(
      '''
      INSERT INTO plan_sources
        (id, plan_id, document_id, document_hash, purpose, start_page,
         end_page, revision, created_at, updated_at, data)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET plan_id=excluded.plan_id,
        document_id=excluded.document_id, document_hash=excluded.document_hash,
        purpose=excluded.purpose, start_page=excluded.start_page,
        end_page=excluded.end_page, revision=excluded.revision,
        created_at=excluded.created_at, updated_at=excluded.updated_at,
        data=excluded.data
      ''',
      [
        saved.id,
        saved.planId,
        saved.documentId,
        saved.documentHash,
        saved.purpose.name,
        saved.startPage,
        saved.endPage,
        saved.revision,
        saved.createdAt.millisecondsSinceEpoch,
        saved.updatedAt.millisecondsSinceEpoch,
        jsonEncode(saved.toJson()),
      ],
    );
    _touchPlan(saved.planId);
    _bumpCalendarRevision();
    return saved;
  }

  void deletePlanSource(String id) {
    store.transact(() {
      final source = getPlanSource(id);
      if (source == null) return;
      store.executeSql('DELETE FROM plan_sources WHERE id = ?', [id]);
      _touchPlan(source.planId);
      _bumpCalendarRevision();
    });
  }

  /// Computes coverage from committed page rows. Missing rows are reported as
  /// missing instead of being treated as covered.
  MaterialCoverage coverageFor(PlanSource source) {
    final document = store.getDocument(source.documentId);
    final total = source.pageCount;
    if (document == null) {
      return MaterialCoverage(
        totalPages: total,
        missingPages: total,
        documentExists: false,
        versionMatches: false,
      );
    }
    if (document.contentHash != source.documentHash) {
      return MaterialCoverage(
        totalPages: total,
        missingPages: total,
        versionMatches: false,
      );
    }
    final rows = store.selectRows(
      'SELECT status, data FROM pages '
      'WHERE document_id = ? AND page >= ? AND page <= ?',
      [source.documentId, source.startPage, source.endPage],
    );
    var ready = 0;
    var needsOcr = 0;
    var pending = 0;
    var failed = 0;
    for (final row in rows) {
      final data = jsonDecode(row['data'] as String) as Map<String, dynamic>;
      final text = (data['text'] as String? ?? '').trim();
      if (row['status'] == 'ready' && text.isNotEmpty) {
        ready++;
      } else if (row['status'] == 'needsOcr' || row['status'] == 'ready') {
        needsOcr++;
      } else if (row['status'] == 'failed') {
        failed++;
      } else {
        pending++;
      }
    }
    return MaterialCoverage(
      totalPages: total,
      readyPages: ready,
      needsOcrPages: needsOcr,
      pendingPages: pending,
      failedPages: failed,
      missingPages: (total - rows.length).clamp(0, total),
    );
  }

  /// Expected page numbers that still need text/OCR before a material can be
  /// used as teaching evidence. Missing page rows are included.
  List<int> pagesNeedingAttention(PlanSource source) {
    final rows = store.selectRows(
      'SELECT page, status, data FROM pages WHERE document_id = ? '
      'AND page >= ? AND page <= ? ORDER BY page',
      [source.documentId, source.startPage, source.endPage],
    );
    final readyPages = <int>{};
    for (final row in rows) {
      final data = jsonDecode(row['data'] as String) as Map<String, dynamic>;
      if (row['status'] == 'ready' &&
          (data['text'] as String? ?? '').trim().isNotEmpty) {
        readyPages.add((row['page'] as num).toInt());
      }
    }
    return [
      for (var page = source.startPage; page <= source.endPage; page++)
        if (!readyPages.contains(page)) page,
    ];
  }

  // ---------------------------------------------------------------------------
  // Availability
  // ---------------------------------------------------------------------------

  PlanAvailability? getAvailability(String planId) {
    final rows = store.selectRows(
      'SELECT data FROM schedule_availability WHERE plan_id = ?',
      [planId],
    );
    return rows.isEmpty ? null : PlanAvailability.fromJson(_decode(rows.first));
  }

  PlanAvailability saveAvailability(PlanAvailability value) {
    final problems = value.validate();
    if (problems.isNotEmpty) {
      throw ScheduleValidationException(problems.join('\n'));
    }
    return store.transact(() => _saveAvailabilityInternal(value));
  }

  PlanAvailability _saveAvailabilityInternal(PlanAvailability value) {
    final problems = value.validate();
    if (problems.isNotEmpty) {
      throw ScheduleValidationException(problems.join('\n'));
    }
    _touchPlan(value.planId);
    store.executeSql(
      '''
      INSERT INTO schedule_availability (plan_id, data) VALUES (?, ?)
      ON CONFLICT(plan_id) DO UPDATE SET data=excluded.data
      ''',
      [value.planId, jsonEncode(value.toJson())],
    );
    _bumpCalendarRevision();
    return value;
  }

  // ---------------------------------------------------------------------------
  // Knowledge items
  // ---------------------------------------------------------------------------

  List<KnowledgeItem> getKnowledgeItems(String planId) {
    final rows = store.selectRows(
      'SELECT data FROM knowledge_items WHERE plan_id = ? '
      'ORDER BY priority DESC, updated_at, id',
      [planId],
    );
    return rows.map((row) => KnowledgeItem.fromJson(_decode(row))).toList();
  }

  KnowledgeItem? getKnowledgeItem(String id) {
    final rows = store.selectRows(
      'SELECT data FROM knowledge_items WHERE id = ?',
      [id],
    );
    return rows.isEmpty ? null : KnowledgeItem.fromJson(_decode(rows.first));
  }

  KnowledgeItem saveKnowledgeItem(KnowledgeItem value) =>
      store.transact(() {
        _validateKnowledgeGraph({
          for (final item in getKnowledgeItems(value.planId)) item.id: item,
          value.id: value,
        }, value.planId);
        return _saveKnowledgeInternal(value);
      });

  List<KnowledgeItem> saveKnowledgeItems(List<KnowledgeItem> values) {
    if (values.isEmpty) return const [];
    return store.transact(() {
      final all = <String, KnowledgeItem>{
        for (final item in getKnowledgeItems(values.first.planId))
          item.id: item,
        for (final item in values) item.id: item,
      };
      _validateKnowledgeGraph(all, values.first.planId);
      return [for (final item in values) _saveKnowledgeInternal(item)];
    });
  }

  KnowledgeItem _saveKnowledgeInternal(KnowledgeItem value) {
    if (getPlan(value.planId) == null) {
      throw ScheduleValidationException('知识点所属计划已不存在。');
    }
    final sourceId = value.sourceId;
    if (sourceId != null) {
      final source = getPlanSource(sourceId);
      if (source == null || source.planId != value.planId) {
        throw ScheduleValidationException('知识点的材料来源不属于这个计划。');
      }
    }
    final existing = getKnowledgeItem(value.id);
    final now = DateTime.now();
    final saved = value.copyWith(
      revision: existing == null ? 1 : existing.revision + 1,
      createdAt: existing?.createdAt ?? value.createdAt,
      updatedAt: now,
    );
    _writeKnowledge(saved);
    _touchPlan(saved.planId);
    _bumpCalendarRevision();
    return saved;
  }

  void _writeKnowledge(KnowledgeItem item) {
    store.executeSql(
      '''
      INSERT INTO knowledge_items
        (id, plan_id, title, priority, minutes, source_id, task_id,
         revision, updated_at, data)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET plan_id=excluded.plan_id,
        title=excluded.title, priority=excluded.priority,
        minutes=excluded.minutes, source_id=excluded.source_id,
        task_id=excluded.task_id, revision=excluded.revision,
        updated_at=excluded.updated_at, data=excluded.data
      ''',
      [
        item.id,
        item.planId,
        item.title,
        item.priority,
        item.minutes,
        item.sourceId,
        item.taskId,
        item.revision,
        item.updatedAt.millisecondsSinceEpoch,
        jsonEncode(item.toJson()),
      ],
    );
  }

  void deleteKnowledgeItem(String id) {
    store.transact(() {
      final item = getKnowledgeItem(id);
      if (item == null) return;
      store.executeSql('DELETE FROM knowledge_items WHERE id = ?', [id]);
      _touchPlan(item.planId);
      _bumpCalendarRevision();
    });
  }

  /// Creates one pending study task for a knowledge item and links the two.
  /// Re-clicking returns the already linked task instead of duplicating it.
  StudyTask createTaskFromKnowledge(
    KnowledgeItem item, {
    TaskActivity? activity,
    int? minutes,
  }) {
    return store.transact(() {
      final current = getKnowledgeItem(item.id);
      if (current == null) {
        throw ScheduleValidationException('知识点已不存在。');
      }
      final linked = current.taskId == null ? null : getTask(current.taskId!);
      if (linked != null) return linked;
      final document = current.documentId == null
          ? null
          : store.getDocument(current.documentId!);
      final material =
          document != null &&
              current.hasSource &&
              document.contentHash == current.documentHash
          ? current.materialRef
          : null;
      final task = StudyTask(
        id: uuid.v4(),
        title: current.title,
        planId: current.planId,
        activity: activity ?? current.activity,
        minutes: minutes ?? current.minutes,
        priority: current.priority,
        knowledge: current.objective.isEmpty
            ? current.title
            : '${current.title}：${current.objective}',
        completionCondition: current.completionCondition,
        material: material,
      );
      _writeTask(task);
      _writeKnowledge(current.copyWith(taskId: task.id));
      _touchPlan(current.planId);
      _bumpCalendarRevision();
      return task;
    });
  }

  void _validateKnowledgeGraph(
    Map<String, KnowledgeItem> items,
    String planId,
  ) {
    final visiting = <String>{};
    final visited = <String>{};
    bool visit(String id) {
      if (visited.contains(id)) return true;
      if (!visiting.add(id)) return false;
      final item = items[id];
      if (item == null) return false;
      if (item.planId != planId) return false;
      for (final prerequisite in item.prerequisiteIds) {
        if (!visit(prerequisite)) return false;
      }
      visiting.remove(id);
      visited.add(id);
      return true;
    }

    for (final item in items.values) {
      if (item.planId != planId) {
        throw ScheduleValidationException('知识点不能跨计划引用。');
      }
      if (item.prerequisiteIds.contains(item.id)) {
        throw ScheduleValidationException('知识点不能把自己设为前置。');
      }
      if (!visit(item.id)) {
        throw ScheduleValidationException('知识点前置关系存在循环或缺失引用。');
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Daily lessons
  // ---------------------------------------------------------------------------

  DailyLesson saveLesson(DailyLesson value) {
    if (getTask(value.taskId) == null) {
      throw ScheduleValidationException('课程所属任务已不存在。');
    }
    if (getPlan(value.planId) == null) {
      throw ScheduleValidationException('课程所属计划已不存在。');
    }
    return store.transact(() {
      final latest = store.selectRows(
        'SELECT data FROM daily_lessons WHERE task_id = ? '
        'ORDER BY version DESC LIMIT 1',
        [value.taskId],
      );
      final version = latest.isEmpty
          ? 1
          : (DailyLesson.fromJson(_decode(latest.first)).version + 1);
      final saved = value.copyWith(
        version: version,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      store.executeSql(
        '''
        INSERT INTO daily_lessons
          (id, task_id, plan_id, status, version, updated_at, data)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          saved.id,
          saved.taskId,
          saved.planId,
          saved.status.name,
          saved.version,
          saved.updatedAt.millisecondsSinceEpoch,
          jsonEncode(saved.toJson()),
        ],
      );
      _touchPlan(saved.planId);
      _bumpCalendarRevision();
      return saved;
    });
  }

  DailyLesson? latestLessonForTask(String taskId) {
    final rows = store.selectRows(
      'SELECT data FROM daily_lessons WHERE task_id = ? '
      'ORDER BY version DESC LIMIT 1',
      [taskId],
    );
    return rows.isEmpty ? null : DailyLesson.fromJson(_decode(rows.first));
  }

  List<DailyLesson> getLessons(String taskId) {
    final rows = store.selectRows(
      'SELECT data FROM daily_lessons WHERE task_id = ? ORDER BY version',
      [taskId],
    );
    return rows.map((row) => DailyLesson.fromJson(_decode(row))).toList();
  }

  DailyLesson? getLessonById(String id) {
    final rows = store.selectRows(
      'SELECT data FROM daily_lessons WHERE id = ?',
      [id],
    );
    return rows.isEmpty ? null : DailyLesson.fromJson(_decode(rows.first));
  }

  /// Lesson attempts whose latest self-check still requires review, newest
  /// first. Later passing attempts settle the pair while preserving full
  /// history in [learning_records].
  List<LessonReviewItem> getLessonReviewItems({int limit = 200}) {
    final items = <LessonReviewItem>[];
    final seenPairs = <String>{};
    final rows = store.selectRows(
      "SELECT data FROM learning_records WHERE kind = 'noted' "
      'ORDER BY occurred_at DESC, id DESC',
    );
    for (final row in rows) {
      final record = LearningRecord.fromJson(_decode(row));
      if (record.taskId == null) continue;
      Map<String, dynamic> note;
      try {
        final decoded = jsonDecode(record.note);
        if (decoded is! Map) continue;
        note = Map<String, dynamic>.from(decoded);
      } catch (_) {
        continue;
      }
      if (note['kind'] != 'lessonAttempt') continue;
      final lessonId = note['lessonId'];
      final exerciseId = note['exerciseId'];
      final selfCheck = note['selfCheck'];
      if (lessonId is! String || exerciseId is! String) continue;
      final pairKey = '$lessonId:$exerciseId';
      if (!seenPairs.add(pairKey)) continue;
      if (selfCheck != 'review') continue;
      final lesson = getLessonById(lessonId);
      final task = getTask(record.taskId!);
      if (lesson == null || task == null) continue;
      final exercises = lesson.exercises.where(
        (exercise) => exercise.id == exerciseId,
      );
      if (exercises.isEmpty) continue;
      final block = record.blockId == null ? null : getBlock(record.blockId!);
      items.add(
        LessonReviewItem(
          record: record,
          task: task,
          block: block,
          lesson: lesson,
          exercise: exercises.first,
        ),
      );
      if (items.length >= limit) break;
    }
    return items;
  }

  /// Answer drafts are deliberately in settings, not learning records: they
  /// are unfinished UI state and must not look like completed study.
  Map<String, LessonDraft> getLessonDrafts(String lessonId) {
    final raw = store.getSetting('schedule.lessonDraft.$lessonId');
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const {};
      return {
        for (final value in decoded.whereType<Map>())
          if (value['exerciseId'] is String)
            value['exerciseId'] as String: LessonDraft.fromJson(
              Map<String, dynamic>.from(value),
            ),
      };
    } catch (_) {
      return const {};
    }
  }

  void saveLessonDrafts(String lessonId, Map<String, LessonDraft> drafts) {
    store.setSetting(
      'schedule.lessonDraft.$lessonId',
      jsonEncode([
        for (final draft in drafts.values) draft.toJson(),
      ]),
    );
  }

  // ---------------------------------------------------------------------------
  // Tasks
  // ---------------------------------------------------------------------------

  List<StudyTask> getTasks({String? planId}) {
    final rows = store.selectRows(
      'SELECT data FROM study_tasks '
      '${planId == null ? '' : 'WHERE plan_id = ? '}'
      'ORDER BY priority DESC, updated_at, id',
      planId == null ? [] : [planId],
    );
    return rows.map((row) => StudyTask.fromJson(_decode(row))).toList();
  }

  StudyTask? getTask(String id) {
    final rows = store.selectRows(
      'SELECT data FROM study_tasks WHERE id = ?',
      [id],
    );
    return rows.isEmpty ? null : StudyTask.fromJson(_decode(rows.first));
  }

  StudyTask saveTask(StudyTask value) {
    if (value.planId != null && getPlan(value.planId!) == null) {
      throw ScheduleValidationException('任务所属计划已不存在。');
    }
    return store.transact(() {
      final existing = getTask(value.id);
      final now = DateTime.now();
      final saved = value.copyWith(
        revision: existing == null ? 1 : existing.revision + 1,
        createdAt: existing?.createdAt ?? value.createdAt,
        updatedAt: now,
      );
      _writeTask(saved);
      _bumpCalendarRevision();
      return saved;
    });
  }

  void deleteTask(String id) {
    store.transact(() {
      store.executeSql('DELETE FROM study_tasks WHERE id = ?', [id]);
      _bumpCalendarRevision();
    });
  }

  void _writeTask(StudyTask task) {
    store.executeSql(
      '''
      INSERT INTO study_tasks
        (id, plan_id, status, minutes, priority, material_document_id,
         material_hash, updated_at, data)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET plan_id=excluded.plan_id,
        status=excluded.status, minutes=excluded.minutes,
        priority=excluded.priority,
        material_document_id=excluded.material_document_id,
        material_hash=excluded.material_hash,
        updated_at=excluded.updated_at, data=excluded.data
      ''',
      [
        task.id,
        task.planId,
        task.status.name,
        task.minutes,
        task.priority,
        task.material?.documentId,
        task.material?.documentHash,
        task.updatedAt.millisecondsSinceEpoch,
        jsonEncode(task.toJson()),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Blocks
  // ---------------------------------------------------------------------------

  List<CalendarBlock> getBlocks({
    LocalDate? start,
    LocalDate? end,
    String? planId,
    String? taskId,
    String? seriesId,
    bool includeCancelled = false,
  }) {
    final conditions = <String>[];
    final parameters = <Object?>[];
    if (start != null) {
      conditions.add('date >= ?');
      parameters.add(start.iso);
    }
    if (end != null) {
      conditions.add('date <= ?');
      parameters.add(end.iso);
    }
    if (planId != null) {
      conditions.add('plan_id = ?');
      parameters.add(planId);
    }
    if (taskId != null) {
      conditions.add('task_id = ?');
      parameters.add(taskId);
    }
    if (seriesId != null) {
      conditions.add('series_id = ?');
      parameters.add(seriesId);
    }
    if (!includeCancelled) {
      conditions.add("state != 'cancelled'");
    }
    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')} ';
    final rows = store.selectRows(
      'SELECT data FROM calendar_blocks $where'
      'ORDER BY date, start_minute, id',
      parameters,
    );
    return rows.map((row) => CalendarBlock.fromJson(_decode(row))).toList();
  }

  /// Adds one catch-up block for an existing task without duplicating the
  /// task, so history and material bindings stay on the same identity.
  CalendarBlock appendCatchUpBlock({
    required StudyTask task,
    required LocalDate date,
    required int startMinute,
    required int endMinute,
  }) {
    final current = getTask(task.id);
    if (current == null) {
      throw ScheduleValidationException('任务已不存在。');
    }
    final block = CalendarBlock(
      id: uuid.v4(),
      title: current.title,
      taskId: current.id,
      planId: current.planId,
      date: date,
      startMinute: startMinute,
      endMinute: endMinute,
      kind: BlockKind.study,
      state: BlockState.scheduled,
      locked: true,
    );
    ScheduleRules.validateManual(task: current, block: block);
    return store.transact(() {
      _requireNoConflicts([block], start: date, end: date);
      _writeBlock(block);
      _bumpCalendarRevision();
      return block;
    });
  }

  CalendarBlock? getBlock(String id) {    final rows = store.selectRows(
      'SELECT data FROM calendar_blocks WHERE id = ?',
      [id],
    );
    return rows.isEmpty ? null : CalendarBlock.fromJson(_decode(rows.first));
  }

  void _writeBlock(CalendarBlock block) {
    store.executeSql(
      '''
      INSERT INTO calendar_blocks
        (id, plan_id, task_id, date, start_minute, end_minute, kind, state,
         locked, series_id, instance_key, revision, updated_at, data)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET plan_id=excluded.plan_id,
        task_id=excluded.task_id, date=excluded.date,
        start_minute=excluded.start_minute, end_minute=excluded.end_minute,
        kind=excluded.kind, state=excluded.state, locked=excluded.locked,
        series_id=excluded.series_id, instance_key=excluded.instance_key,
        revision=excluded.revision, updated_at=excluded.updated_at,
        data=excluded.data
      ''',
      [
        block.id,
        block.planId,
        block.taskId,
        block.date.iso,
        block.startMinute,
        block.endMinute,
        block.kind.name,
        block.state.name,
        block.locked ? 1 : 0,
        block.seriesId,
        block.instanceKey,
        block.revision,
        block.updatedAt.millisecondsSinceEpoch,
        jsonEncode(block.toJson()),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Manual schedule: create, edit, delete
  // ---------------------------------------------------------------------------

  List<LocalDate> _seriesDates({
    required LocalDate start,
    required LocalDate end,
    required List<int> weekdays,
  }) {
    if (end < start) {
      throw ScheduleValidationException('重复安排的结束日期不能早于开始日期。');
    }
    if (end.differenceInDays(start) + 1 > ScheduleRules.maxRepeatDays) {
      throw ScheduleValidationException(
        '一次最多展开 ${ScheduleRules.maxRepeatDays} 天。请分段建立这次重复安排。',
      );
    }
    final dates = <LocalDate>[start];
    if (end > start) {
      dates.addAll(
        ScheduleRules.expandWeekly(
          start: start.addDays(1),
          end: end,
          weekdays: weekdays,
        ),
      );
    }
    return dates;
  }

  ScheduleSaveResult createManual({
    required StudyTask task,
    required CalendarBlock block,
    bool repeat = false,
    List<int> weekdays = const [],
    LocalDate? repeatEnd,
    DateTime? now,
  }) {
    if (task.planId != null && getPlan(task.planId!) == null) {
      throw ScheduleValidationException('任务所属计划已不存在。');
    }
    if (block.planId != null && block.planId != task.planId) {
      throw ScheduleValidationException('任务与时间块的计划不一致。');
    }
    final at = now ?? DateTime.now();
    final blockTemplate = block.copyWith(
      title: task.title,
      planId: task.planId,
      clearPlan: task.planId == null,
    );
    ScheduleRules.validateManual(task: task, block: blockTemplate);
    final dates = repeat
        ? _seriesDates(
            start: blockTemplate.date,
            end: repeatEnd ?? blockTemplate.date,
            weekdays: weekdays,
          )
        : <LocalDate>[blockTemplate.date];
    final seriesId = repeat ? uuid.v4() : null;
    final tasks = <StudyTask>[];
    final blocks = <CalendarBlock>[];
    for (var index = 0; index < dates.length; index++) {
      final date = dates[index];
      final taskId = repeat ? uuid.v4() : task.id;
      final occurrenceTask = task.copyWith(
        id: taskId,
        planId: task.planId,
        clearPlan: task.planId == null,
        createdAt: at,
        updatedAt: at,
        revision: 1,
      );
      final occurrenceBlock = blockTemplate.copyWith(
        id: uuid.v4(),
        taskId: taskId,
        date: date,
        title: task.title,
        seriesId: seriesId,
        seriesEndDate: repeat ? repeatEnd : null,
        seriesWeekdays: repeat ? weekdays : const [],
        instanceKey: repeat
            ? ScheduleRules.instanceKey(seriesId!, date, index)
            : null,
        clearInstanceKey: !repeat,
        clearSeries: !repeat,
        clearSeriesEnd: !repeat,
        revision: 1,
        updatedAt: at,
      );
      tasks.add(occurrenceTask);
      blocks.add(occurrenceBlock);
    }
    return store.transact(() {
      _requireNoConflicts(blocks, start: dates.first, end: dates.last);
      for (var index = 0; index < tasks.length; index++) {
        _writeTask(tasks[index]);
        _writeBlock(blocks[index]);
      }
      _bumpCalendarRevision();
      return ScheduleSaveResult(tasks: tasks, blocks: blocks);
    });
  }

  ScheduleSaveResult updateManual({
    required StudyTask task,
    required CalendarBlock block,
    RepeatEditScope scope = RepeatEditScope.thisOnly,
    List<int>? weekdays,
    LocalDate? repeatEnd,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    return store.transact(() {
      final existingBlock = getBlock(block.id);
      if (existingBlock == null) {
        throw ScheduleConflictException('这个时间块已被删除，请刷新日程。');
      }
      if (existingBlock.state != BlockState.scheduled) {
        throw ScheduleValidationException('已开始或已完成的学习记录不能改写。');
      }
      final existingTask = existingBlock.taskId == null
          ? null
          : getTask(existingBlock.taskId!);
      if (existingTask == null) {
        throw ScheduleValidationException('这个学习任务已不存在，请删除后重新创建。');
      }
      if (task.planId != null && getPlan(task.planId!) == null) {
        throw ScheduleValidationException('任务所属计划已不存在。');
      }
      final updatedTask = task.copyWith(
        id: existingTask.id,
        planId: task.planId,
        clearPlan: task.planId == null,
        status: existingTask.status,
        createdAt: existingTask.createdAt,
        updatedAt: at,
        revision: existingTask.revision + 1,
      );
      final isSeries =
          existingBlock.seriesId != null &&
          existingBlock.seriesWeekdays.isNotEmpty &&
          !existingBlock.detached;
      if (!isSeries || scope == RepeatEditScope.thisOnly) {
        final updatedBlock = block.copyWith(
          id: existingBlock.id,
          taskId: existingTask.id,
          planId: updatedTask.planId,
          clearPlan: updatedTask.planId == null,
          title: updatedTask.title,
          seriesId: existingBlock.seriesId,
          seriesEndDate: existingBlock.seriesEndDate,
          seriesWeekdays: existingBlock.seriesWeekdays,
          instanceKey: existingBlock.instanceKey,
          detached: existingBlock.seriesId != null,
          revision: existingBlock.revision + 1,
          updatedAt: at,
        );
        ScheduleRules.validateManual(task: updatedTask, block: updatedBlock);
        _requireNoConflicts(
          [updatedBlock],
          start: updatedBlock.date,
          end: updatedBlock.date,
          excludeIds: {existingBlock.id},
        );
        _writeTask(updatedTask);
        _writeBlock(updatedBlock);
        _bumpCalendarRevision();
        return ScheduleSaveResult(tasks: [updatedTask], blocks: [updatedBlock]);
      }

      final seriesId = existingBlock.seriesId!;
      final selectedWeekdays = (weekdays == null || weekdays.isEmpty)
          ? (existingBlock.seriesWeekdays.toList()..sort())
          : (weekdays.toSet().toList()..sort());
      final seriesEnd =
          repeatEnd ?? existingBlock.seriesEndDate ?? existingBlock.date;
      final allSeries = getBlocks(seriesId: seriesId);
      final future = allSeries
          .where(
            (item) =>
                item.date >= existingBlock.date &&
                !item.detached &&
                item.state == BlockState.scheduled &&
                item.completedMinutes == 0,
          )
          .toList();
      final futureIds = future.map((item) => item.id).toSet();
      final occupiedDates = allSeries
          .where(
            (item) =>
                item.date >= existingBlock.date &&
                !futureIds.contains(item.id) &&
                item.state != BlockState.cancelled,
          )
          .map((item) => item.date)
          .toSet();
      final dates = _seriesDates(
        start: block.date,
        end: seriesEnd,
        weekdays: selectedWeekdays,
      ).where((date) => !occupiedDates.contains(date)).toList();
      if (dates.isEmpty) {
        throw ScheduleValidationException('这个重复安排没有可更新的日期。');
      }
      final tasks = <StudyTask>[];
      final blocks = <CalendarBlock>[];
      for (var index = 0; index < dates.length; index++) {
        final date = dates[index];
        final isCurrent = index == 0;
        final taskId = isCurrent ? existingTask.id : uuid.v4();
        final occurrenceTask = updatedTask.copyWith(
          id: taskId,
          createdAt: isCurrent ? existingTask.createdAt : at,
          revision: isCurrent ? existingTask.revision + 1 : 1,
        );
        final occurrenceBlock = block.copyWith(
          id: isCurrent ? existingBlock.id : uuid.v4(),
          taskId: taskId,
          planId: occurrenceTask.planId,
          clearPlan: occurrenceTask.planId == null,
          title: occurrenceTask.title,
          date: date,
          seriesId: seriesId,
          seriesEndDate: seriesEnd,
          seriesWeekdays: selectedWeekdays,
          instanceKey: isCurrent
              ? existingBlock.instanceKey ??
                    ScheduleRules.instanceKey(seriesId, date, index)
              : ScheduleRules.instanceKey(seriesId, date, index),
          detached: false,
          revision: isCurrent ? existingBlock.revision + 1 : 1,
          updatedAt: at,
        );
        ScheduleRules.validateManual(
          task: occurrenceTask,
          block: occurrenceBlock,
        );
        tasks.add(occurrenceTask);
        blocks.add(occurrenceBlock);
      }
      _requireNoConflicts(
        blocks,
        start: dates.first,
        end: seriesEnd,
        excludeIds: {...futureIds, existingBlock.id},
      );
      for (final item in future) {
        if (item.id == existingBlock.id) continue;
        store.executeSql('DELETE FROM calendar_blocks WHERE id = ?', [item.id]);
      }
      _removeOrphanTasks(future.map((item) => item.taskId));
      for (var index = 0; index < tasks.length; index++) {
        _writeTask(tasks[index]);
        _writeBlock(blocks[index]);
      }
      _bumpCalendarRevision();
      return ScheduleSaveResult(tasks: tasks, blocks: blocks);
    });
  }

  void deleteOccurrence(
    CalendarBlock block, {
    bool thisAndFuture = false,
    DateTime? now,
  }) {
    store.transact(() {
      final existing = getBlock(block.id);
      if (existing == null) return;
      if (existing.state != BlockState.scheduled) {
        throw ScheduleValidationException('已开始、已完成或已跳过的时间块不能删除。');
      }
      var targets = <CalendarBlock>[existing];
      if (thisAndFuture && existing.seriesId != null) {
        final end = existing.seriesEndDate ?? existing.date;
        targets = getBlocks(seriesId: existing.seriesId)
            .where(
              (item) =>
                  item.date >= existing.date &&
                  item.date <= end &&
                  !item.detached &&
                  item.state == BlockState.scheduled &&
                  item.completedMinutes == 0,
            )
            .toList();
        if (targets.isEmpty) targets = [existing];
      }
      final taskIds = <String?>[];
      for (final item in targets) {
        taskIds.add(item.taskId);
        store.executeSql('DELETE FROM calendar_blocks WHERE id = ?', [item.id]);
      }
      _removeOrphanTasks(taskIds);
      _bumpCalendarRevision();
    });
  }

  // ---------------------------------------------------------------------------
  // Busy (fixed personal) blocks
  // ---------------------------------------------------------------------------

  CalendarBlock setBlockLocked(
    CalendarBlock block, {
    required bool locked,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    return store.transact(() {
      final existing = getBlock(block.id);
      if (existing == null) {
        throw ScheduleConflictException('这个时间块已被删除，请刷新日程。');
      }
      if (existing.state != BlockState.scheduled) {
        throw ScheduleValidationException('已开始或已完成的记录不能改锁定状态。');
      }
      final updated = existing.copyWith(
        locked: locked,
        revision: existing.revision + 1,
        updatedAt: at,
      );
      _writeBlock(updated);
      _bumpCalendarRevision();
      return updated;
    });
  }

  List<CalendarBlock> createBusy({
    required CalendarBlock template,
    bool repeat = false,
    List<int> weekdays = const [],
    LocalDate? repeatEnd,
    DateTime? now,
  }) {
    if (template.title.trim().isEmpty) {
      throw ScheduleValidationException('占用时间需要一个标题。');
    }
    if (template.kind == BlockKind.study) {
      throw ScheduleValidationException('个人占用不能作为学习块。');
    }
    final at = now ?? DateTime.now();
    final dates = repeat
        ? _seriesDates(
            start: template.date,
            end: repeatEnd ?? template.date,
            weekdays: weekdays,
          )
        : <LocalDate>[template.date];
    final seriesId = repeat ? uuid.v4() : null;
    final blocks = <CalendarBlock>[];
    for (var index = 0; index < dates.length; index++) {
      blocks.add(
        template.copyWith(
          id: uuid.v4(),
          date: dates[index],
          seriesId: seriesId,
          seriesEndDate: repeat ? repeatEnd : null,
          seriesWeekdays: repeat ? weekdays : const [],
          instanceKey: repeat
              ? ScheduleRules.instanceKey(seriesId!, dates[index], index)
              : null,
          clearInstanceKey: !repeat,
          clearSeries: !repeat,
          clearSeriesEnd: !repeat,
          revision: 1,
          updatedAt: at,
        ),
      );
    }
    return store.transact(() {
      _requireNoConflicts(blocks, start: dates.first, end: dates.last);
      for (final block in blocks) {
        _writeBlock(block);
      }
      _bumpCalendarRevision();
      return blocks;
    });
  }

  CalendarBlock updateBusy(
    CalendarBlock block, {
    RepeatEditScope scope = RepeatEditScope.thisOnly,
    List<int>? weekdays,
    LocalDate? repeatEnd,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    return store.transact(() {
      final existing = getBlock(block.id);
      if (existing == null) {
        throw ScheduleConflictException('这个占用块已被删除，请刷新日程。');
      }
      if (existing.isStudy) {
        throw ScheduleValidationException('学习块不能作为个人占用修改。');
      }
      final isSeries = existing.seriesId != null && !existing.detached;
      if (!isSeries || scope == RepeatEditScope.thisOnly) {
        final updated = block.copyWith(
          id: existing.id,
          kind: existing.kind,
          taskId: null,
          clearTask: true,
          seriesId: existing.seriesId,
          seriesEndDate: existing.seriesEndDate,
          seriesWeekdays: existing.seriesWeekdays,
          instanceKey: existing.instanceKey,
          detached: existing.seriesId != null,
          revision: existing.revision + 1,
          updatedAt: at,
        );
        _requireNoConflicts(
          [updated],
          start: updated.date,
          end: updated.date,
          excludeIds: {existing.id},
        );
        _writeBlock(updated);
        _bumpCalendarRevision();
        return updated;
      }
      final seriesId = existing.seriesId!;
      final selectedWeekdays = (weekdays == null || weekdays.isEmpty)
          ? (existing.seriesWeekdays.toList()..sort())
          : (weekdays.toSet().toList()..sort());
      final seriesEnd =
          repeatEnd ?? existing.seriesEndDate ?? existing.date;
      final future = getBlocks(seriesId: seriesId)
          .where(
            (item) =>
                item.date >= existing.date &&
                !item.detached &&
                item.state == BlockState.scheduled,
          )
          .toList();
      final futureIds = future.map((item) => item.id).toSet();
      final occupiedDates = getBlocks(seriesId: seriesId)
          .where(
            (item) =>
                item.date >= existing.date &&
                !futureIds.contains(item.id) &&
                item.state != BlockState.cancelled,
          )
          .map((item) => item.date)
          .toSet();
      final dates = _seriesDates(
        start: block.date,
        end: seriesEnd,
        weekdays: selectedWeekdays,
      ).where((date) => !occupiedDates.contains(date)).toList();
      if (dates.isEmpty) {
        throw ScheduleValidationException('这个重复占用没有可更新的日期。');
      }
      final blocks = <CalendarBlock>[
        for (var index = 0; index < dates.length; index++)
          block.copyWith(
            id: index == 0 ? existing.id : uuid.v4(),
            kind: existing.kind,
            taskId: null,
            clearTask: true,
            date: dates[index],
            seriesId: seriesId,
            seriesEndDate: seriesEnd,
            seriesWeekdays: selectedWeekdays,
            instanceKey: index == 0
                ? existing.instanceKey ??
                      ScheduleRules.instanceKey(seriesId, dates[index], index)
                : ScheduleRules.instanceKey(seriesId, dates[index], index),
            detached: false,
            revision: index == 0 ? existing.revision + 1 : 1,
            updatedAt: at,
          ),
      ];
      _requireNoConflicts(
        blocks,
        start: dates.first,
        end: seriesEnd,
        excludeIds: {...future.map((item) => item.id), existing.id},
      );
      for (final item in future) {
        if (item.id == existing.id) continue;
        store.executeSql('DELETE FROM calendar_blocks WHERE id = ?', [item.id]);
      }
      for (final item in blocks) {
        _writeBlock(item);
      }
      _bumpCalendarRevision();
      return blocks.first;
    });
  }

  // ---------------------------------------------------------------------------
  // Learning records
  // ---------------------------------------------------------------------------

  List<LearningRecord> getLearningRecords({
    String? taskId,
    String? blockId,
    int limit = 50,
  }) {
    final conditions = <String>[];
    final parameters = <Object?>[];
    if (taskId != null) {
      conditions.add('task_id = ?');
      parameters.add(taskId);
    }
    if (blockId != null) {
      conditions.add('block_id = ?');
      parameters.add(blockId);
    }
    parameters.add(limit);
    final rows = store.selectRows(
      'SELECT data FROM learning_records '
      '${conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')} '}'
      'ORDER BY occurred_at DESC, id LIMIT ?',
      parameters,
    );
    return rows.map((row) => LearningRecord.fromJson(_decode(row))).toList();
  }

  /// Records one self-checked lesson exercise. The full answer and self-check
  /// live in the note JSON; the row is a formal learning record, not a draft.
  LearningRecord saveLessonAttemptRecord({
    required String lessonId,
    required String taskId,
    required String exerciseId,
    required String answer,
    required bool correct,
    required int minutes,
    String? blockId,
    String? operationId,
  }) {
    if (minutes < 1 || minutes > 600) {
      throw ScheduleValidationException('实际用时需在 1–600 分钟之间。');
    }
    final at = DateTime.now();
    final operation = operationId ?? uuid.v4();
    final record = LearningRecord(
      id: uuid.v4(),
      blockId: blockId,
      taskId: taskId,
      fact: LearningFact.noted,
      minutes: minutes,
      note: jsonEncode({
        'kind': 'lessonAttempt',
        'lessonId': lessonId,
        'exerciseId': exerciseId,
        'answer': answer,
        'selfCheck': correct ? 'correct' : 'review',
      }),
      occurredAt: at,
      operationId: operation,
    );
    store.transact(() {
      final existing = store.selectRows(
        'SELECT data FROM learning_records WHERE operation_id = ?',
        [operation],
      );
      if (existing.isNotEmpty) return;
      store.executeSql(
        '''
        INSERT INTO learning_records
          (id, block_id, task_id, kind, occurred_at, operation_id, data)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          record.id,
          record.blockId,
          record.taskId,
          record.fact.name,
          record.occurredAt.millisecondsSinceEpoch,
          record.operationId,
          jsonEncode(record.toJson()),
        ],
      );
      _syncLessonReviewCandidate(
        lessonId: lessonId,
        taskId: taskId,
        exerciseId: exerciseId,
        answer: answer,
        correct: correct,
        occurredAt: at,
      );
    });
    return record;
  }

  void _syncLessonReviewCandidate({
    required String lessonId,
    required String taskId,
    required String exerciseId,
    required String answer,
    required bool correct,
    required DateTime occurredAt,
  }) {
    final lesson = getLessonById(lessonId);
    final task = getTask(taskId);
    LessonExercise? exercise;
    if (lesson != null) {
      for (final ex in lesson.exercises) {
        if (ex.id == exerciseId) {
          exercise = ex;
          break;
        }
      }
    }
    final reviewRepo = ReviewRepository(store);
    final originKey = 'lesson_attempt:$lessonId:$exerciseId';
    if (!correct) {
      final prompt = exercise?.prompt.trim().isNotEmpty == true
          ? exercise!.prompt.trim()
          : '课程练习题（$lessonId / $exerciseId）';
      final refAnswer = exercise?.answer.trim() ?? '';
      final doc = task?.material?.documentId == null
          ? null
          : store.getDocument(task!.material!.documentId);
      reviewRepo.upsertCandidate(
        originKey: originKey,
        sourceType: 'lesson',
        documentId: task?.material?.documentId,
        documentHash: task?.material?.documentHash ?? '',
        documentTitle: doc?.title ?? task?.material?.title ?? '',
        startPage: task?.material?.startPage,
        endPage: task?.material?.endPage,
        lessonId: lessonId,
        exerciseId: exerciseId,
        taskId: taskId,
        title: task?.title ?? '课程待复习',
        prompt: prompt,
        answer: refAnswer,
        explanation: answer.trim().isEmpty ? '' : '上次作答：$answer',
        reason: '课程自评标记需要复习',
        status: ReviewCandidateStatus.pending,
        nowUtc: occurredAt.toUtc(),
      );
      return;
    }

    // Later "correct" settles any still-pending candidate while retaining
    // complete learning_records history.
    final rows = store.selectRows(
      'SELECT id, status FROM review_candidates WHERE origin_key = ?',
      [originKey],
    );
    for (final row in rows) {
      if (row['status'] == ReviewCandidateStatus.pending.name) {
        store.executeSql(
          'UPDATE review_candidates SET status = ?, reason = ?, updated_at = ? '
          'WHERE id = ?',
          [
            ReviewCandidateStatus.ignored.name,
            '先需复习，后续自评已正确（保留历史）',
            occurredAt.toUtc().millisecondsSinceEpoch,
            row['id'],
          ],
        );
      }
    }
  }

  CalendarBlock markBlock({
    required CalendarBlock block,
    required LearningFact fact,
    int? completedMinutes,
    String note = '',
    DateTime? now,
    String? operationId,
  }) {    if (fact != LearningFact.completed &&
        fact != LearningFact.partial &&
        fact != LearningFact.skipped) {
      throw ScheduleValidationException('不支持的学习记录类型。');
    }
    final at = now ?? DateTime.now();
    final operation = operationId ?? uuid.v4();
    return store.transact(() {
      final existingOperation = store.selectRows(
        'SELECT 1 FROM learning_records WHERE operation_id = ?',
        [operation],
      );
      final existing = getBlock(block.id);
      if (existing == null) {
        throw ScheduleConflictException('这个时间块已被删除，请刷新日程。');
      }
      if (existingOperation.isNotEmpty) return existing;
      if (existing.state == BlockState.completed ||
          existing.state == BlockState.skipped ||
          existing.state == BlockState.cancelled) {
        throw ScheduleValidationException('这条学习记录已经结束，不能重复提交。');
      }
      late final CalendarBlock updated;
      late final int recordedMinutes;
      switch (fact) {
        case LearningFact.completed:
          recordedMinutes = existing.minutes - existing.completedMinutes;
          updated = existing.copyWith(
            state: BlockState.completed,
            completedMinutes: existing.minutes,
            completedAt: at,
            skippedReason: '',
            revision: existing.revision + 1,
            updatedAt: at,
          );
        case LearningFact.partial:
          final partial = completedMinutes ?? 0;
          if (partial < 1 || partial >= existing.minutes) {
            throw ScheduleValidationException('部分完成需填写 1–${existing.minutes - 1} 分钟。');
          }
          if (partial < existing.completedMinutes) {
            throw ScheduleValidationException(
              '已记录 ${existing.completedMinutes} 分钟，不能改成更少。',
            );
          }
          recordedMinutes = partial - existing.completedMinutes;
          updated = existing.copyWith(
            state: BlockState.inProgress,
            completedMinutes: partial,
            completedAt: at,
            revision: existing.revision + 1,
            updatedAt: at,
          );
        case LearningFact.skipped:
          recordedMinutes = 0;
          updated = existing.copyWith(
            state: BlockState.skipped,
            skippedReason: note.trim(),
            revision: existing.revision + 1,
            updatedAt: at,
          );
        case LearningFact.opened:
        case LearningFact.noted:
          throw ScheduleValidationException('不支持的学习记录类型。');
      }
      _writeBlock(updated);
      final record = LearningRecord(
        id: uuid.v4(),
        blockId: existing.id,
        taskId: existing.taskId,
        fact: fact,
        minutes: recordedMinutes,
        note: note,
        occurredAt: at,
        operationId: operation,
      );
      store.executeSql(
        '''
        INSERT INTO learning_records
          (id, block_id, task_id, kind, occurred_at, operation_id, data)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          record.id,
          record.blockId,
          record.taskId,
          record.fact.name,
          record.occurredAt.millisecondsSinceEpoch,
          record.operationId,
          jsonEncode(record.toJson()),
        ],
      );
      if (existing.taskId != null) _refreshTaskStatus(existing.taskId!, at);
      _bumpCalendarRevision();
      return updated;
    });
  }

  void _refreshTaskStatus(String taskId, DateTime now) {
    final task = getTask(taskId);
    if (task == null) return;
    final blocks = getBlocks(taskId: taskId);
    var completed = 0;
    var anyProgress = false;
    var allSkipped = blocks.isNotEmpty;
    for (final block in blocks) {
      completed += block.completedMinutes;
      if (block.state == BlockState.inProgress || block.completedMinutes > 0) {
        anyProgress = true;
      }
      if (block.state != BlockState.skipped) allSkipped = false;
    }
    final status = completed >= task.minutes
        ? TaskStatus.completed
        : allSkipped
        ? TaskStatus.skipped
        : anyProgress
        ? TaskStatus.inProgress
        : TaskStatus.notStarted;
    if (status == task.status) return;
    final updated = task.copyWith(
      status: status,
      revision: task.revision + 1,
      updatedAt: now,
    );
    _writeTask(updated);
  }

  // ---------------------------------------------------------------------------
  // Drafts, application and undo
  // ---------------------------------------------------------------------------

  ScheduleDraft buildDraft(String planId, {DateTime? now}) {
    final plan = getPlan(planId);
    if (plan == null) throw ScheduleValidationException('计划已不存在。');
    final availability = getAvailability(planId);
    if (availability == null || !availability.isConfigured) {
      throw ScheduleValidationException('请先为这个计划设置每周可用时间。');
    }
    final at = now ?? DateTime.now();
    final today = LocalDate.today(at);
    final rangeStart = plan.startDate > today ? plan.startDate : today;
    final rangeEnd = plan.schedulingEnd;
    if (rangeEnd < rangeStart) {
      return ScheduleDraft(
        planId: planId,
        planTitle: plan.title,
        baseRevision: calendarRevision,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
        generatedAt: at,
        warnings: const ['计划已结束，没有可排期的日期。'],
      );
    }
    final calendarBlocks = getBlocks(start: rangeStart, end: rangeEnd);
    final planBlocks = getBlocks(planId: planId);
    final blocksByTask = <String, List<CalendarBlock>>{};
    for (final block in planBlocks) {
      if (block.taskId == null) continue;
      blocksByTask.putIfAbsent(block.taskId!, () => []).add(block);
    }
    final tasks = getTasks(
      planId: planId,
    ).where((task) => task.status != TaskStatus.completed).toList();
    final work = <TaskWork>[];
    final replaceIds = <String>{};
    final warnings = <String>[];
    var order = 0;
    for (final task in tasks) {
      final blocks = blocksByTask[task.id] ?? const <CalendarBlock>[];
      if (blocks.isEmpty) {
        work.add(TaskWork(task: task, remainingMinutes: task.minutes, order: order++));
        continue;
      }
      if (blocks.every((block) => block.canAutoMove)) {
        replaceIds.addAll(blocks.map((block) => block.id));
        work.add(TaskWork(task: task, remainingMinutes: task.minutes, order: order++));
        continue;
      }
      warnings.add('「${task.title}」已有锁定或已开始的时间块，本次不自动调整。');
    }
    if (work.isEmpty) {
      return ScheduleDraft(
        planId: planId,
        planTitle: plan.title,
        baseRevision: calendarRevision,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
        generatedAt: at,
        warnings: [...warnings, '没有可自动排期的任务。可在计划里新增待安排任务后再试。'],
      );
    }
    final occupied = calendarBlocks
        .where((block) => !replaceIds.contains(block.id))
        .toList();
    final outcome = ScheduleEngine.plan(
      ScheduleRequest(
        planId: planId,
        availability: availability,
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
        tasks: work,
        occupied: occupied,
        replaceBlockIds: replaceIds,
        examDate: plan.examDate,
        now: at,
      ),
    );
    final added = [
      for (final block in outcome.blocks)
        CalendarBlock(
          id: uuid.v4(),
          title: block.title,
          taskId: block.taskId,
          planId: planId,
          date: block.date,
          startMinute: block.startMinute,
          endMinute: block.endMinute,
          revision: 1,
          updatedAt: at,
        ),
    ];
    final removed = planBlocks
        .where((block) => replaceIds.contains(block.id))
        .toList();
    final assumptions = <String>[
      ...outcome.assumptions,
      if (rangeStart > plan.startDate) '计划开始日期已过，从今天开始排期。',
      if (plan.examDate != null) '考试日 ${plan.examDate!.shortLabel} 不自动安排学习。',
    ];
    return ScheduleDraft(
      planId: planId,
      planTitle: plan.title,
      baseRevision: calendarRevision,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
      generatedAt: at,
      addedBlocks: added,
      removedBlocks: removed,
      unplaced: outcome.unplaced,
      availableMinutes: outcome.availableMinutes,
      effectiveMinutes: outcome.effectiveMinutes,
      scheduledMinutes: outcome.scheduledMinutes,
      breakMinutes: outcome.breakMinutes,
      bufferMinutes: outcome.bufferMinutes,
      warnings: [...warnings, ...outcome.warnings],
      assumptions: assumptions,
    );
  }

  ScheduleRevision applyDraft(ScheduleDraft draft, {DateTime? now}) {
    if (draft.addedBlocks.isEmpty && draft.removedBlocks.isEmpty) {
      throw ScheduleValidationException('草案没有可应用的改动。');
    }
    final at = now ?? DateTime.now();
    return store.transact(() {
      if (calendarRevision != draft.baseRevision) {
        throw ScheduleConflictException('日历在预览期间发生了修改，请重新生成排期草案。');
      }
      if (getPlan(draft.planId) == null) {
        throw ScheduleConflictException('计划已删除，草案无法应用。');
      }
      for (final block in draft.removedBlocks) {
        final current = getBlock(block.id);
        if (current == null || !current.canAutoMove) {
          throw ScheduleConflictException('草案中的时间块已被修改或开始学习，请重新生成。');
        }
      }
      for (final block in draft.addedBlocks) {
        if (block.taskId == null || getTask(block.taskId!) == null) {
          throw ScheduleConflictException('草案包含已删除的任务，请重新生成。');
        }
      }
      final removedIds = draft.removedBlocks.map((block) => block.id).toSet();
      final existing = getBlocks(
        start: draft.rangeStart,
        end: draft.rangeEnd,
      ).where((block) => !removedIds.contains(block.id));
      _requireNoConflicts(
        draft.addedBlocks,
        start: draft.rangeStart,
        end: draft.rangeEnd,
        existing: existing,
      );
      for (final id in removedIds) {
        store.executeSql('DELETE FROM calendar_blocks WHERE id = ?', [id]);
      }
      for (final block in draft.addedBlocks) {
        _writeBlock(block);
      }
      _bumpCalendarRevision();
      final revision = ScheduleRevision(
        id: uuid.v4(),
        planId: draft.planId,
        summary:
            '自动排期：新增 ${draft.addedBlocks.length} 个学习块，'
            '移除 ${draft.removedBlocks.length} 个未开始块',
        appliedAt: at,
        calendarRevision: calendarRevision,
        beforeBlocks: draft.removedBlocks,
        afterBlocks: draft.addedBlocks,
        unplaced: draft.unplaced,
      );
      _writeRevision(revision);
      return revision;
    });
  }

  List<ScheduleRevision> getRevisions({int limit = 20}) {
    final rows = store.selectRows(
      'SELECT data FROM schedule_revisions ORDER BY applied_at DESC, id LIMIT ?',
      [limit],
    );
    return rows.map((row) => ScheduleRevision.fromJson(_decode(row))).toList();
  }

  ScheduleRevision? latestUndoableRevision() {
    final rows = store.selectRows(
      'SELECT data FROM schedule_revisions ORDER BY applied_at DESC, id LIMIT 1',
    );
    if (rows.isEmpty) return null;
    final revision = ScheduleRevision.fromJson(_decode(rows.first));
    return revision.isUndone ? null : revision;
  }

  bool get canUndoLatest {
    final revision = latestUndoableRevision();
    return revision != null && revision.calendarRevision == calendarRevision;
  }

  ScheduleRevision undoRevision(String revisionId, {DateTime? now}) {
    final at = now ?? DateTime.now();
    return store.transact(() {
      ScheduleRevision? revision;
      for (final item in getRevisions(limit: 200)) {
        if (item.id == revisionId) {
          revision = item;
          break;
        }
      }
      if (revision == null) {
        throw ScheduleValidationException('找不到这次排期记录。');
      }
      if (revision.isUndone) {
        throw ScheduleValidationException('这次排期已经撤销。');
      }
      if (revision.calendarRevision != calendarRevision) {
        throw ScheduleConflictException('之后已有新的日程修改，不能再直接撤销。');
      }
      final afterIds = revision.afterBlocks.map((block) => block.id).toSet();
      for (final block in revision.afterBlocks) {
        final current = getBlock(block.id);
        if (current == null || !current.canAutoMove) {
          throw ScheduleConflictException('排期后的学习块已开始或完成，不能直接撤销。');
        }
      }
      final existing = getBlocks().where(
        (block) => !afterIds.contains(block.id),
      );
      _requireNoConflicts(
        revision.beforeBlocks,
        start: revision.beforeBlocks.isEmpty
            ? LocalDate.today(at)
            : revision.beforeBlocks
                  .map((block) => block.date)
                  .reduce((a, b) => a < b ? a : b),
        end: revision.beforeBlocks.isEmpty
            ? LocalDate.today(at)
            : revision.beforeBlocks
                  .map((block) => block.date)
                  .reduce((a, b) => a > b ? a : b),
        existing: existing,
      );
      for (final id in afterIds) {
        store.executeSql('DELETE FROM calendar_blocks WHERE id = ?', [id]);
      }
      for (final block in revision.beforeBlocks) {
        _writeBlock(block);
      }
      final undone = ScheduleRevision(
        id: revision.id,
        planId: revision.planId,
        summary: revision.summary,
        appliedAt: revision.appliedAt,
        calendarRevision: revision.calendarRevision,
        undoneAt: at,
        beforeBlocks: revision.beforeBlocks,
        afterBlocks: revision.afterBlocks,
        unplaced: revision.unplaced,
      );
      _writeRevision(undone);
      _bumpCalendarRevision();
      for (final taskId in {
        ...revision.afterBlocks.map((block) => block.taskId),
        ...revision.beforeBlocks.map((block) => block.taskId),
      }) {
        if (taskId != null) _refreshTaskStatus(taskId, at);
      }
      return undone;
    });
  }

  void _writeRevision(ScheduleRevision revision) {
    store.executeSql(
      '''
      INSERT INTO schedule_revisions
        (id, plan_id, applied_at, undone_at, data)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET undone_at=excluded.undone_at,
        data=excluded.data
      ''',
      [
        revision.id,
        revision.planId,
        revision.appliedAt.millisecondsSinceEpoch,
        revision.undoneAt?.millisecondsSinceEpoch,
        jsonEncode(revision.toJson()),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  void _requireNoConflicts(
    List<CalendarBlock> candidates, {
    required LocalDate start,
    required LocalDate end,
    Set<String> excludeIds = const {},
    Iterable<CalendarBlock>? existing,
  }) {
    if (candidates.isEmpty) return;
    final blocks =
        existing?.toList() ?? getBlocks(start: start, end: end);
    final conflicts = ScheduleRules.findConflicts(
      candidates: candidates,
      existing: blocks,
      excludeIds: excludeIds,
    );
    ScheduleRules.requireNoConflicts(conflicts);
  }

  void _removeOrphanTasks(Iterable<String?> taskIds) {
    for (final taskId in taskIds.toSet()) {
      if (taskId == null) continue;
      final remaining = store.selectRows(
        'SELECT 1 FROM calendar_blocks WHERE task_id = ? LIMIT 1',
        [taskId],
      );
      if (remaining.isEmpty) {
        store.executeSql('DELETE FROM study_tasks WHERE id = ?', [taskId]);
      }
    }
  }

  static Map<String, dynamic> _decode(Map<String, Object?> row) =>
      Map<String, dynamic>.from(jsonDecode(row['data'] as String) as Map);
}
