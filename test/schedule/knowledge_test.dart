import 'package:flutter_test/flutter_test.dart';

import 'package:local_study/core/local_store.dart';
import 'package:local_study/core/models.dart';
import 'package:local_study/features/schedule/data/schedule_repository.dart';
import 'package:local_study/features/schedule/domain/schedule_validator.dart';
import 'package:local_study/features/schedule/models/calendar_block.dart';
import 'package:local_study/features/schedule/models/knowledge_item.dart';
import 'package:local_study/features/schedule/models/daily_lesson.dart';
import 'package:local_study/features/schedule/models/local_date.dart';
import 'package:local_study/features/schedule/models/plan_availability.dart';
import 'package:local_study/features/schedule/models/plan_source.dart';
import 'package:local_study/features/schedule/models/material_ref.dart';
import 'package:local_study/features/schedule/models/study_plan.dart';
import 'package:local_study/features/schedule/models/study_task.dart';
import 'package:local_study/features/schedule/schedule_controller.dart';

StudyPlan _plan(ScheduleRepository repository) => repository.savePlan(
  StudyPlan(
    id: 'plan',
    title: '期中数学',
    startDate: LocalDate(2026, 11, 9),
    endDate: LocalDate(2026, 11, 27),
    examDate: LocalDate(2026, 11, 29),
  ),
);

PlanSource _source(StudyPlan plan) => PlanSource(
  id: 'source',
  planId: plan.id,
  documentId: 'book',
  documentHash: 'hash-book',
  documentTitle: '数学教材',
  purpose: MaterialPurpose.textbook,
  startPage: 1,
  endPage: 5,
);

KnowledgeItem _item(
  StudyPlan plan, {
  required String id,
  String title = '二次函数图像',
  List<String> prerequisites = const [],
}) => KnowledgeItem(
  id: id,
  planId: plan.id,
  title: title,
  objective: '能判断开口方向与顶点。',
  sourceId: 'source',
  documentId: 'book',
  documentHash: 'hash-book',
  documentTitle: '数学教材',
  startPage: 2,
  endPage: 3,
  priority: 2,
  minutes: 45,
  prerequisiteIds: prerequisites,
  completionCondition: '独立完成 3 道变式。',
);

void main() {
  test('knowledge items persist sources, priorities and prerequisites', () {
    final store = LocalStore.inMemory();
    addTearDown(store.dispose);
    store.importDocument(
      DocumentRecord(
        id: 'book',
        title: '数学教材',
        kind: DocumentKind.textbook,
        filePath: '/managed/book.pdf',
        contentHash: 'hash-book',
        pageCount: 5,
      ),
      [
        for (var page = 1; page <= 5; page++)
          PageRecord(
            documentId: 'book',
            page: page,
            text: '第 $page 页：函数内容。',
            status: PageStatus.ready,
          ),
      ],
    );
    final repository = ScheduleRepository(store);
    final plan = _plan(repository);
    repository.savePlanSource(_source(plan));

    final first = repository.saveKnowledgeItem(_item(plan, id: 'k1'));
    final second = repository.saveKnowledgeItem(
      _item(plan, id: 'k2', title: '判别式', prerequisites: ['k1']),
    );
    expect(first.revision, 1);
    expect(second.prerequisiteIds, ['k1']);
    expect(repository.getKnowledgeItems(plan.id), hasLength(2));
    expect(repository.getPlan(plan.id)!.revision, greaterThan(2));

    expect(
      () => repository.saveKnowledgeItem(
        _item(plan, id: 'k3', prerequisites: ['missing']),
      ),
      throwsA(isA<ScheduleValidationException>()),
    );
    expect(
      () => repository.saveKnowledgeItem(
        first.copyWith(prerequisiteIds: ['k2']),
      ),
      throwsA(isA<ScheduleValidationException>()),
    );
  });

  test('a knowledge item creates one linked pending task', () {
    final store = LocalStore.inMemory();
    addTearDown(store.dispose);
    final repository = ScheduleRepository(store);
    final plan = _plan(repository);
    store.importDocument(
      DocumentRecord(
        id: 'book',
        title: '数学教材',
        kind: DocumentKind.textbook,
        filePath: '/managed/book.pdf',
        contentHash: 'hash-book',
        pageCount: 5,
      ),
      [const PageRecord(documentId: 'book', page: 1)],
    );
    repository.savePlanSource(_source(plan));
    final item = repository.saveKnowledgeItem(_item(plan, id: 'k1'));

    final task = repository.createTaskFromKnowledge(item);
    expect(task.planId, plan.id);
    expect(task.knowledge, contains('二次函数图像'));
    expect(task.material?.startPage, 2);
    expect(repository.getTasks(planId: plan.id), hasLength(1));
    expect(repository.getKnowledgeItem('k1')!.taskId, task.id);

    final again = repository.createTaskFromKnowledge(item);
    expect(again.id, task.id);
    expect(repository.getTasks(planId: plan.id), hasLength(1));
  });

  test('deleting a plan removes its knowledge items', () {
    final store = LocalStore.inMemory();
    addTearDown(store.dispose);
    final repository = ScheduleRepository(store);
    final plan = _plan(repository);
    store.importDocument(
      DocumentRecord(
        id: 'book',
        title: '数学教材',
        kind: DocumentKind.textbook,
        filePath: '/managed/book.pdf',
        contentHash: 'hash-book',
        pageCount: 5,
      ),
      [const PageRecord(documentId: 'book', page: 1)],
    );
    repository.savePlanSource(_source(plan));
    repository.saveKnowledgeItem(_item(plan, id: 'k1'));

    repository.deletePlan(plan.id);
    expect(repository.getKnowledgeItems(plan.id), isEmpty);
  });

  test('knowledge JSON keeps a source snapshot without inventing pages', () {
    final plan = StudyPlan(
      id: 'plan',
      title: '计划',
      startDate: LocalDate(2026, 11, 9),
      endDate: LocalDate(2026, 11, 20),
    );
    final item = _item(plan, id: 'k1');
    final copy = KnowledgeItem.fromJson(item.toJson());
    expect(copy.materialRef?.endPage, 3);
    expect(copy.sourcePageLabel, '第 2–3 页');
    expect(copy.priority, 2);
    expect(copy.activity, TaskActivity.learn);
  });

  test('task reader-session bindings survive JSON round-trip', () {
    final task = StudyTask(
      id: 'task',
      title: '读教材',
      minutes: 30,
      planId: 'plan',
      readerSessionBindings: const {'book': 'session-a', 'paper': 'session-b'},
    );
    final copy = StudyTask.fromJson(task.toJson());
    expect(copy.readerSessionBindings['book'], 'session-a');
    expect(copy.readerSessionBindings['paper'], 'session-b');
  });

  test('daily lessons persist answers separately from prompts', () {
    final store = LocalStore.inMemory();
    addTearDown(store.dispose);
    final repository = ScheduleRepository(store);
    final plan = _plan(repository);
    final task = repository.saveTask(
      StudyTask(id: 'task', title: '二次函数', planId: plan.id, minutes: 45),
    );
    final lesson = DailyLesson(
      id: 'lesson',
      taskId: task.id,
      planId: plan.id,
      title: '二次函数图像',
      objective: '能判断顶点。',
      sections: const [
        LessonSection(title: '概念', body: '抛物线。', sourcePage: 2),
      ],
      exercises: const [
        LessonExercise(
          id: 'e1',
          prompt: '顶点是什么？',
          answer: '(1,2)',
          solution: '配方得到顶点。',
          sourcePage: 2,
        ),
      ],
      startPage: 2,
      endPage: 3,
    );
    final saved = repository.saveLesson(lesson);
    expect(saved.version, 1);
    expect(repository.latestLessonForTask(task.id)!.exercises.single.answer, '(1,2)');
    expect(
      DailyLesson.fromJson(saved.toJson()).exercises.single.solution,
      '配方得到顶点。',
    );
    repository.saveLessonDrafts('lesson', const {
      'e1': LessonDraft(exerciseId: 'e1', answer: '草稿答案', revealed: true),
    });
    final drafts = repository.getLessonDrafts('lesson');
    expect(drafts['e1']!.answer, '草稿答案');
    expect(drafts['e1']!.revealed, isTrue);

    repository.saveLessonAttemptRecord(
      lessonId: 'lesson',
      taskId: task.id,
      exerciseId: 'e1',
      answer: '我的答案',
      correct: false,
      minutes: 12,
      operationId: 'attempt-1',
    );
    repository.saveLessonAttemptRecord(
      lessonId: 'lesson',
      taskId: task.id,
      exerciseId: 'e1',
      answer: '我的答案',
      correct: false,
      minutes: 12,
      operationId: 'attempt-1',
    );
    final records = repository.getLearningRecords(taskId: task.id);
    expect(records, hasLength(1));
    expect(records.single.minutes, 12);
    expect(records.single.note, contains('lessonAttempt'));
    expect(records.single.note, contains('review'));
    final reviews = repository.getLessonReviewItems();
    expect(reviews, hasLength(1));
    expect(reviews.single.exercise.prompt, '顶点是什么？');
  });

  test('catch-up suggestions append a locked block without a new task', () {
    final store = LocalStore.inMemory();
    addTearDown(store.dispose);
    final repository = ScheduleRepository(store);
    final today = LocalDate.today();
    final plan = repository.savePlan(
      StudyPlan(
        id: 'plan',
        title: '补课',
        startDate: today,
        endDate: today.addDays(10),
      ),
    );
    repository.saveAvailability(
      PlanAvailability(
        planId: plan.id,
        weekly: [
          for (var weekday = 1; weekday <= 7; weekday++)
            WeeklySlot(
              weekday: weekday,
              startMinute: 19 * 60 + 30,
              endMinute: 21 * 60,
            ),
        ],
      ),
    );
    final task = repository.saveTask(
      StudyTask(id: 'task', title: '补课任务', planId: plan.id, minutes: 45),
    );
    final original = repository.createManual(
      task: task,
      block: CalendarBlock(
        id: 'block',
        date: today,
        startMinute: 19 * 60 + 30,
        endMinute: 20 * 60 + 15,
        taskId: task.id,
        planId: plan.id,
      ),
    ).block;
    final controller = ScheduleController(repository);
    addTearDown(controller.dispose);
    final suggestions = controller.suggestCatchUp(task, original);
    expect(suggestions, isNotEmpty);
    expect(suggestions.first.date, today.addDays(1));
    expect(suggestions.first.startMinute, 19 * 60 + 30);

    final added = controller.applyCatchUp(task, suggestions.first);
    expect(added.taskId, task.id);
    expect(repository.getTasks(planId: plan.id), hasLength(1));
    expect(
      repository.getBlocks(planId: plan.id).where((b) => b.taskId == task.id),
      hasLength(2),
    );
  });

  test('lesson cache is hidden when the task page range changes', () {    final store = LocalStore.inMemory();
    addTearDown(store.dispose);
    final repository = ScheduleRepository(store);
    final controller = ScheduleController(repository);
    addTearDown(controller.dispose);
    final plan = _plan(repository);
    store.importDocument(
      DocumentRecord(
        id: 'book',
        title: '数学教材',
        kind: DocumentKind.textbook,
        filePath: '/managed/book.pdf',
        contentHash: 'hash-book',
        pageCount: 5,
      ),
      [const PageRecord(documentId: 'book', page: 1)],
    );
    final material = MaterialRef(
      documentId: 'book',
      documentHash: 'hash-book',
      title: '数学教材',
      startPage: 2,
      endPage: 3,
    );
    final task = repository.saveTask(
      StudyTask(
        id: 'task',
        title: '二次函数',
        planId: plan.id,
        minutes: 45,
        material: material,
      ),
    );
    repository.saveLesson(
      DailyLesson(
        id: 'lesson',
        taskId: task.id,
        planId: plan.id,
        title: '课程',
        objective: '目标',
        sections: const [LessonSection(title: '讲解', body: '内容')],
        exercises: const [
          LessonExercise(
            id: 'e1',
            prompt: '题',
            answer: '答',
            solution: '解',
          ),
        ],
        materialDocumentId: 'book',
        materialHash: 'hash-book',
        startPage: 2,
        endPage: 3,
      ),
    );
    expect(controller.lessonForTask(task.id), isNotNull);

    repository.saveTask(
      task.copyWith(
        material: MaterialRef(
          documentId: 'book',
          documentHash: 'hash-book',
          title: '数学教材',
          startPage: 2,
          endPage: 4,
        ),
      ),
    );
    expect(controller.lessonForTask(task.id), isNull);
  });
}
