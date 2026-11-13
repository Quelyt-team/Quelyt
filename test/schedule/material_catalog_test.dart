import 'package:flutter_test/flutter_test.dart';

import 'package:local_study/core/local_store.dart';
import 'package:local_study/core/models.dart';
import 'package:local_study/features/schedule/data/schedule_repository.dart';
import 'package:local_study/features/schedule/models/local_date.dart';
import 'package:local_study/features/schedule/models/plan_source.dart';
import 'package:local_study/features/schedule/models/study_plan.dart';
import 'package:local_study/features/schedule/services/material_catalog_service.dart';

void seedDocument(
  LocalStore store, {
  required String id,
  required String title,
  required List<(PageStatus, String)> pages,
}) {
  store.importDocument(
    DocumentRecord(
      id: id,
      title: title,
      kind: DocumentKind.textbook,
      filePath: '/managed/$id.pdf',
      contentHash: 'hash-$id',
      pageCount: pages.length,
    ),
    [
      for (var index = 0; index < pages.length; index++)
        PageRecord(
          documentId: id,
          page: index + 1,
          status: pages[index].$1,
          text: pages[index].$2,
        ),
    ],
  );
}

StudyPlan seedPlan(ScheduleRepository repository) => repository.savePlan(
  StudyPlan(
    id: 'plan',
    title: '期中数学',
    startDate: LocalDate(2026, 11, 9),
    endDate: LocalDate(2026, 11, 27),
    examDate: LocalDate(2026, 11, 29),
  ),
);

PlanSource source(
  StudyPlan plan,
  String documentId, {
  required String id,
  required int start,
  required int end,
  String chapter = '',
}) => PlanSource(
  id: id,
  planId: plan.id,
  documentId: documentId,
  documentHash: 'hash-$documentId',
  documentTitle: documentId,
  purpose: MaterialPurpose.textbook,
  startPage: start,
  endPage: end,
  chapter: chapter,
);

void main() {
  test('extracts ready pages across documents and skips unfinished ones', () {
    final store = LocalStore.inMemory();
    addTearDown(store.dispose);
    seedDocument(
      store,
      id: 'book',
      title: '数学教材',
      pages: const [
        (PageStatus.ready, '函数定义。'),
        (PageStatus.ready, '函数图像。'),
        (PageStatus.needsOcr, ''),
        (PageStatus.ready, '函数性质。'),
      ],
    );
    seedDocument(
      store,
      id: 'paper',
      title: '真题',
      pages: const [
        (PageStatus.ready, '第一题：求定义域。'),
        (PageStatus.pending, ''),
      ],
    );
    final repository = ScheduleRepository(store);
    final plan = seedPlan(repository);
    repository.savePlanSource(
      source(plan, 'book', id: 's1', start: 1, end: 4, chapter: '第三章'),
    );
    repository.savePlanSource(
      source(plan, 'paper', id: 's2', start: 1, end: 2),
    );

    final extraction = MaterialCatalogService(store).extractPlan(plan.id);
    expect(extraction.selectedPages, 6);
    expect(extraction.readyPages, 4);
    expect(extraction.chunks, hasLength(2));
    expect(extraction.skippedSources.map((s) => s.id), isNot(contains('s1')));
    expect(extraction.chunks.first.chapter, '第三章');
    expect(extraction.chunks.first.text, contains('函数定义'));
    expect(extraction.chunks.first.text, contains('函数性质'));
    // s2 has one ready page; it is still included, while its unfinished page
    // is simply absent from the extracted text.
    expect(extraction.chunks.last.text, contains('第一题'));
    expect(extraction.chunks.last.text, isNot(contains('pending')));
  });

  test('reports sources with no ready pages and respects chunk cap', () {
    final store = LocalStore.inMemory();
    addTearDown(store.dispose);
    seedDocument(
      store,
      id: 'book',
      title: '数学教材',
      pages: [
        (PageStatus.pending, ''),
        (PageStatus.ready, List.filled(900, 'A').join()),
        (PageStatus.ready, List.filled(900, 'B').join()),
      ],
    );
    final repository = ScheduleRepository(store);
    final plan = seedPlan(repository);
    repository.savePlanSource(
      source(plan, 'book', id: 's1', start: 2, end: 3),
    );

    final extraction = MaterialCatalogService(store).extractPlan(
      plan.id,
      maxCharsPerChunk: 1000,
      maxChunks: 1,
    );
    expect(extraction.chunks, hasLength(1));
    expect(extraction.truncated, isTrue);
    expect(extraction.readyPages, 2);
  });

  test('rejects an invalid chunk budget', () {
    final store = LocalStore.inMemory();
    addTearDown(store.dispose);
    expect(
      () => MaterialCatalogService(store).extractPlan(
        'plan',
        maxCharsPerChunk: 100,
      ),
      throwsArgumentError,
    );
  });
}
