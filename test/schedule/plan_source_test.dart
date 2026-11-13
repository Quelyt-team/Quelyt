import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:local_study/core/local_store.dart';
import 'package:local_study/core/models.dart';
import 'package:local_study/features/schedule/data/schedule_repository.dart';
import 'package:local_study/features/schedule/domain/schedule_validator.dart';
import 'package:local_study/features/schedule/models/local_date.dart';
import 'package:local_study/features/schedule/models/plan_source.dart';
import 'package:local_study/features/schedule/models/study_plan.dart';

void seedForPlan(
  LocalStore store, {
  String documentId = 'doc',
  int pageCount = 7,
  int? pageRecords,
  List<PageStatus> statuses = const [],
}) {
  store.importDocument(
    DocumentRecord(
      id: documentId,
      title: '数学教材',
      kind: DocumentKind.textbook,
      filePath: '/managed/$documentId.pdf',
      contentHash: 'hash-$documentId',
      pageCount: pageCount,
    ),
    List.generate(
      pageRecords ?? pageCount,
      (index) => PageRecord(
        documentId: documentId,
        page: index + 1,
        text: statuses.length > index && statuses[index] == PageStatus.ready
            ? '第 ${index + 1} 页正文'
            : '',
        status: statuses.length > index
            ? statuses[index]
            : PageStatus.pending,
      ),
    ),
  );
}

StudyPlan seedPlan(ScheduleRepository repository, {String id = 'plan'}) =>
    repository.savePlan(
      StudyPlan(
        id: id,
        title: '期中数学',
        startDate: LocalDate(2026, 11, 9),
        endDate: LocalDate(2026, 11, 27),
        examDate: LocalDate(2026, 11, 29),
      ),
    );

PlanSource sourceFor(
  StudyPlan plan, {
  String id = 'source',
  int start = 1,
  int end = 7,
}) => PlanSource(
  id: id,
  planId: plan.id,
  documentId: 'doc',
  documentHash: 'hash-doc',
  documentTitle: '数学教材',
  purpose: MaterialPurpose.textbook,
  startPage: start,
  endPage: end,
  chapter: '第三章 函数',
);

void main() {
  test('plan sources persist a versioned page range and coverage', () {
    final store = LocalStore.inMemory();
    addTearDown(store.dispose);
    seedForPlan(
      store,
      pageRecords: 6,
      statuses: const [
        PageStatus.ready,
        PageStatus.ready,
        PageStatus.ready,
        PageStatus.needsOcr,
        PageStatus.pending,
        PageStatus.failed,
      ],
    );
    final repository = ScheduleRepository(store);
    final plan = seedPlan(repository);

    final saved = repository.savePlanSource(sourceFor(plan));
    expect(saved.revision, 1);
    expect(saved.documentTitle, '数学教材');
    expect(saved.rangeLabel, '第 1–7 页');
    expect(saved.label, '第三章 函数 · 教材 · 第 1–7 页');
    expect(repository.getPlanSources(plan.id), hasLength(1));
    expect(repository.getPlan(plan.id)!.revision, 2);

    final coverage = repository.coverageFor(saved);
    expect(coverage.totalPages, 7);
    expect(coverage.readyPages, 3);
    expect(coverage.needsOcrPages, 1);
    expect(coverage.pendingPages, 1);
    expect(coverage.failedPages, 1);
    expect(coverage.missingPages, 1);
    expect(coverage.attentionPages, 4);
    expect(coverage.allReady, isFalse);
    expect(repository.pagesNeedingAttention(saved), [4, 5, 6, 7]);

    expect(
      () => repository.savePlanSource(sourceFor(plan, id: 'other')),
      throwsA(isA<ScheduleValidationException>()),
    );

    final updated = repository.savePlanSource(
      sourceFor(plan, start: 1, end: 3),
    );
    expect(updated.revision, 2);
    expect(repository.coverageFor(updated).allReady, isTrue);
    expect(repository.pagesNeedingAttention(updated), isEmpty);

    repository.deletePlanSource(updated.id);
    expect(repository.getPlanSources(plan.id), isEmpty);
    expect(repository.getPlan(plan.id)!.revision, greaterThan(2));
  });

  test('plan and document deletion cascade material references', () {
    final store = LocalStore.inMemory();
    addTearDown(store.dispose);
    seedForPlan(store);
    final repository = ScheduleRepository(store);
    final plan = seedPlan(repository);
    repository.savePlanSource(sourceFor(plan));

    store.deleteDocument('doc');
    expect(repository.getPlanSources(plan.id), isEmpty);

    seedForPlan(store);
    repository.savePlanSource(sourceFor(plan));
    repository.deletePlan(plan.id);
    expect(repository.getPlanSources(plan.id), isEmpty);
  });

  test('coverage reports changed document versions instead of assuming text', () {
    final store = LocalStore.inMemory();
    addTearDown(store.dispose);
    seedForPlan(store, statuses: const [PageStatus.ready]);
    final repository = ScheduleRepository(store);
    final plan = seedPlan(repository);
    final source = repository.savePlanSource(sourceFor(plan, end: 1));

    final record = store.getDocument('doc')!;
    final changed = record.toJson()..['contentHash'] = 'hash-v2';
    store.executeSql(
      'UPDATE documents SET content_hash = ?, data = ? WHERE id = ?',
      ['hash-v2', jsonEncode(changed), record.id],
    );
    final coverage = repository.coverageFor(source);
    expect(coverage.versionMatches, isFalse);
    expect(coverage.readyPages, 0);
    expect(coverage.missingPages, 1);
    expect(coverage.summary, '资料版本已改变');
  });

  test('PlanSource JSON keeps its source snapshot', () {
    final source = PlanSource(
      id: 's',
      planId: 'p',
      documentId: 'd',
      documentHash: 'h',
      documentTitle: '真题',
      purpose: MaterialPurpose.pastPaper,
      startPage: 4,
      endPage: 8,
      chapter: '2025 年',
    );
    final copy = PlanSource.fromJson(source.toJson());
    expect(copy.purpose, MaterialPurpose.pastPaper);
    expect(copy.materialRef.startPage, 4);
    expect(copy.materialRef.title, '真题');
  });
}
