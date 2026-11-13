import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:local_study/core/local_store.dart';
import 'package:local_study/core/models.dart';
import 'package:local_study/features/schedule/data/schedule_repository.dart';
import 'package:local_study/features/schedule/domain/schedule_validator.dart';
import 'package:local_study/features/schedule/models/calendar_block.dart';
import 'package:local_study/features/schedule/models/learning_record.dart';
import 'package:local_study/features/schedule/models/local_date.dart';
import 'package:local_study/features/schedule/models/material_ref.dart';
import 'package:local_study/features/schedule/models/plan_availability.dart';
import 'package:local_study/features/schedule/models/study_plan.dart';
import 'package:local_study/features/schedule/models/study_task.dart';

StudyPlan _plan({
  String id = 'plan',
  LocalDate? start,
  LocalDate? end,
  LocalDate? exam,
}) => StudyPlan(
  id: id,
  title: '期中数学',
  subject: '数学',
  startDate: start ?? LocalDate(2030, 1, 7),
  endDate: end ?? LocalDate(2030, 1, 20),
  examDate: exam,
);

PlanAvailability _availability(String planId, {int buffer = 10}) =>
    PlanAvailability(
      planId: planId,
      weekly: [
        for (var weekday = 1; weekday <= 5; weekday++)
          WeeklySlot(
            weekday: weekday,
            startMinute: 19 * 60 + 30,
            endMinute: 21 * 60,
          ),
      ],
      dailyCapMinutes: 120,
      bufferPercent: buffer,
      maxStudyDaysPerWeek: 5,
      breakMinutes: 0,
      unitMinutes: 45,
    );

StudyTask _task(
  String id, {
  String title = '二次函数练习',
  String? planId = 'plan',
  int minutes = 45,
  TaskActivity activity = TaskActivity.practice,
}) => StudyTask(
  id: id,
  title: title,
  planId: planId,
  activity: activity,
  minutes: minutes,
  minChunkMinutes: 15,
);

CalendarBlock _block(
  String date, {
  int start = 19 * 60 + 30,
  int end = 20 * 60 + 15,
  bool locked = true,
}) => CalendarBlock(
  id: 'template',
  date: LocalDate.parse(date),
  startMinute: start,
  endMinute: end,
  locked: locked,
);

void main() {
  late LocalStore store;
  late ScheduleRepository repository;

  setUp(() {
    store = LocalStore.inMemory();
    repository = ScheduleRepository(store);
    repository.savePlan(_plan());
    repository.saveAvailability(_availability('plan'));
  });

  tearDown(() => store.dispose());

  test('manual task is stored once with its title snapshot and lock', () {
    final result = repository.createManual(
      task: _task('t1'),
      block: _block('2030-01-07'),
    );
    expect(result.blocks.single.taskId, 't1');
    expect(result.blocks.single.locked, isTrue);
    expect(result.blocks.single.title, '二次函数练习');
    expect(repository.calendarRevision, greaterThan(0));
    final stored = repository.getBlocks(planId: 'plan');
    expect(stored, hasLength(1));
    expect(repository.getTasks(planId: 'plan').single.title, '二次函数练习');
  });

  test('overlapping manual tasks are rejected and nothing is half written', () {
    repository.createManual(
      task: _task('t1'),
      block: _block('2030-01-07'),
    );
    expect(
      () => repository.createManual(
        task: _task('t2', title: '英语听力'),
        block: _block('2030-01-07', start: 20 * 60, end: 20 * 60 + 45),
      ),
      throwsA(isA<ScheduleValidationException>()),
    );
    expect(repository.getBlocks(planId: 'plan'), hasLength(1));
    expect(repository.getTasks(planId: 'plan'), hasLength(1));
  });

  test('weekly repeat creates distinct task identities and stable keys', () {
    final result = repository.createManual(
      task: _task('t1', minutes: 45),
      block: _block('2030-01-07'),
      repeat: true,
      weekdays: [1, 3],
      repeatEnd: LocalDate(2030, 1, 20),
    );
    expect(result.blocks.map((block) => block.date.iso), [
      '2030-01-07',
      '2030-01-09',
      '2030-01-14',
      '2030-01-16',
    ]);
    expect(result.tasks.map((task) => task.id).toSet(), hasLength(4));
    expect(result.blocks.map((block) => block.taskId).toSet(), hasLength(4));
    expect(
      result.blocks.map((block) => block.instanceKey).toSet(),
      hasLength(4),
    );
    expect(result.blocks.every((block) => block.seriesId != null), isTrue);
    expect(result.blocks.first.seriesEndDate, LocalDate(2030, 1, 20));
  });

  test('editing this and future keeps history and updates later blocks', () {
    final created = repository.createManual(
      task: _task('t1', minutes: 45),
      block: _block('2030-01-07'),
      repeat: true,
      weekdays: [1, 3],
      repeatEnd: LocalDate(2030, 1, 20),
    );
    final second = created.blocks[1];
    final secondTask = repository.getTask(second.taskId!)!;
    final editedTask = secondTask.copyWith(
      title: '二次函数订正',
      minutes: 60,
      activity: TaskActivity.correct,
    );
    final editedBlock = second.copyWith(
      startMinute: 20 * 60,
      endMinute: 21 * 60,
      seriesWeekdays: [3, 5],
    );
    final result = repository.updateManual(
      task: editedTask,
      block: editedBlock,
      scope: RepeatEditScope.thisAndFuture,
      weekdays: [3, 5],
      repeatEnd: LocalDate(2030, 1, 20),
    );
    expect(result.blocks, hasLength(4));
    expect(result.blocks.first.date.iso, '2030-01-09');
    expect(result.blocks.map((block) => block.date.iso), [
      '2030-01-09',
      '2030-01-11',
      '2030-01-16',
      '2030-01-18',
    ]);
    expect(result.blocks.first.taskId, second.taskId);
    final all = repository.getBlocks(planId: 'plan');
    expect(all, hasLength(5));
    final original = all.firstWhere(
      (block) => block.date.iso == '2030-01-07',
    );
    expect(original.title, '二次函数练习');
    expect(original.taskId, created.blocks.first.taskId);
    expect(
      repository.getTask(second.taskId!)!.title,
      '二次函数订正',
    );
    expect(
      repository.getTask(second.taskId!)!.status,
      TaskStatus.notStarted,
    );
  });

  test('editing a single series occurrence detaches it from later changes', () {
    final created = repository.createManual(
      task: _task('t1'),
      block: _block('2030-01-07'),
      repeat: true,
      weekdays: [1, 3],
      repeatEnd: LocalDate(2030, 1, 16),
    );
    final second = created.blocks[1];
    final secondTask = repository.getTask(second.taskId!)!;
    final single = repository.updateManual(
      task: secondTask.copyWith(title: '只改这一次'),
      block: second.copyWith(startMinute: 20 * 60, endMinute: 20 * 60 + 45),
    );
    expect(single.blocks.single.detached, isTrue);
    expect(repository.getBlock(second.id)!.timeLabel, '20:00–20:45');

    final firstTask = repository.getTask(created.blocks.first.taskId!)!;
    repository.updateManual(
      task: firstTask.copyWith(title: '整组改名'),
      block: created.blocks.first.copyWith(
        startMinute: 18 * 60,
        endMinute: 18 * 60 + 45,
      ),
      scope: RepeatEditScope.thisAndFuture,
      weekdays: [1, 3],
      repeatEnd: LocalDate(2030, 1, 16),
    );
    expect(repository.getBlock(second.id)!.timeLabel, '20:00–20:45');
    expect(repository.getBlock(second.id)!.title, '只改这一次');
  });

  test('completion and partial completion keep real minutes and records', () {
    final created = repository.createManual(
      task: _task('t1', minutes: 60),
      block: _block('2030-01-07', start: 19 * 60, end: 20 * 60),
    );
    final partial = repository.markBlock(
      block: created.block,
      fact: LearningFact.partial,
      completedMinutes: 25,
      note: '做到第二题',
      operationId: 'op-1',
    );
    expect(partial.state, BlockState.inProgress);
    expect(partial.completedMinutes, 25);
    expect(repository.getTask('t1')!.status, TaskStatus.inProgress);
    expect(repository.getLearningRecords(taskId: 't1'), hasLength(1));
    final again = repository.markBlock(
      block: partial,
      fact: LearningFact.partial,
      completedMinutes: 40,
      operationId: 'op-2',
    );
    expect(again.completedMinutes, 40);
    final completed = repository.markBlock(
      block: again,
      fact: LearningFact.completed,
      operationId: 'op-3',
    );
    expect(completed.state, BlockState.completed);
    expect(completed.completedMinutes, 60);
    expect(repository.getTask('t1')!.status, TaskStatus.completed);
    expect(repository.getLearningRecords(taskId: 't1'), hasLength(3));
    final duplicate = repository.markBlock(
      block: completed,
      fact: LearningFact.completed,
      operationId: 'op-3',
    );
    expect(duplicate.state, BlockState.completed);
    expect(repository.getLearningRecords(taskId: 't1'), hasLength(3));
  });

  test('draft application and undo restore the formal calendar', () {
    repository.saveTask(_task('t1', minutes: 45));
    repository.saveTask(_task('t2', title: '错题订正', minutes: 45));
    final draft = repository.buildDraft('plan');
    expect(draft.addedBlocks, hasLength(2));
    expect(draft.scheduledMinutes, 90);
    expect(draft.unplaced, isEmpty);

    final revision = repository.applyDraft(draft);
    expect(repository.getBlocks(planId: 'plan'), hasLength(2));
    expect(repository.canUndoLatest, isTrue);
    expect(
      () => repository.applyDraft(draft),
      throwsA(isA<ScheduleConflictException>()),
    );
    expect(repository.getBlocks(planId: 'plan'), hasLength(2));

    repository.undoRevision(revision.id);
    expect(repository.getBlocks(planId: 'plan'), isEmpty);
    expect(repository.canUndoLatest, isFalse);
    expect(repository.getTask('t1')!.status, TaskStatus.notStarted);
  });

  test('undo is refused after a later schedule edit', () {
    repository.saveTask(_task('t1', minutes: 45));
    final revision = repository.applyDraft(repository.buildDraft('plan'));
    repository.createBusy(
      template: CalendarBlock(
        id: 'busy-template',
        title: '临时占用',
        date: LocalDate(2030, 1, 8),
        startMinute: 12 * 60,
        endMinute: 13 * 60,
        kind: BlockKind.busy,
      ),
    );
    expect(repository.canUndoLatest, isFalse);
    expect(
      () => repository.undoRevision(revision.id),
      throwsA(isA<ScheduleConflictException>()),
    );
  });

  test('deleting a document marks material missing but preserves history', () {
    store.upsertDocument(
      DocumentRecord(
        id: 'book',
        title: '数学课本',
        kind: DocumentKind.textbook,
        filePath: 'managed/book.pdf',
        contentHash: 'book-hash',
        pageCount: 200,
      ),
    );
    final task = _task('t1', planId: null).copyWith(
      material: MaterialRef(
        documentId: 'book',
        documentHash: 'book-hash',
        title: '数学课本',
        startPage: 20,
        endPage: 24,
      ),
    );
    repository.saveTask(task);
    store.deleteDocument('book');
    final restored = repository.getTask('t1')!;
    expect(restored.material, isNotNull);
    expect(restored.material!.missing, isTrue);
    expect(restored.material!.rangeLabel, '第 20–24 页');
    expect(restored.title, '二次函数练习');
  });

  test('deleting a plan cascades its tasks and blocks only', () {
    repository.createManual(
      task: _task('t1'),
      block: _block('2030-01-07'),
    );
    repository.createManual(
      task: _task('t2', planId: null, title: '个人阅读'),
      block: _block('2030-01-08'),
    );
    repository.deletePlan('plan');
    expect(repository.getPlan('plan'), isNull);
    expect(repository.getTasks(planId: 'plan'), isEmpty);
    expect(repository.getBlocks(planId: 'plan'), isEmpty);
    expect(repository.getTasks(planId: null).single.title, '个人阅读');
  });

  test('a file store reopens with schedule data intact', () {
    final directory = Directory.systemTemp.createTempSync('schedule-repo-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final fileStore = LocalStore.open(directory.path);
    final fileRepo = ScheduleRepository(fileStore);
    fileRepo.savePlan(_plan());
    fileRepo.saveAvailability(_availability('plan'));
    fileRepo.createManual(task: _task('t1'), block: _block('2030-01-07'));
    fileStore.dispose();

    final reopened = LocalStore.open(directory.path);
    addTearDown(reopened.dispose);
    final reopenedRepo = ScheduleRepository(reopened);
    expect(reopenedRepo.getBlocks(planId: 'plan').single.title, '二次函数练习');
    expect(reopenedRepo.getTasks(planId: 'plan').single.id, 't1');
  });
}
