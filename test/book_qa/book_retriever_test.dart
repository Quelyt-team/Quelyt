import 'package:flutter_test/flutter_test.dart';

import 'package:local_study/core/models.dart';
import 'package:local_study/features/book_qa/models/book_understanding.dart';

import 'book_fixture.dart';

void main() {
  late BookFixture fixture;

  setUp(() => fixture = BookFixture.create());
  tearDown(() => fixture.dispose());

  test('a question asked on an unrelated page still reaches page 7', () {
    final retrieval = fixture.retriever.retrieve(
      fixture.document,
      '为什么聚合物多以头尾键连为主？',
      focusPage: 12,
    );
    expect(retrieval.analysis.asksWhy, isTrue);
    expect(retrieval.searchedWholeBook, isTrue);
    expect(retrieval.evidence, isNotEmpty);
    expect(retrieval.evidence.map((item) => item.page), contains(7));
    expect(
      retrieval.evidence.any((item) => item.page >= 4 && item.page <= 8),
      isTrue,
    );
    final coverage = retrieval.coverage();
    expect(coverage.scope, contains('整本教材'));
    expect(coverage.wholeBookSearched, isTrue);
    expect(coverage.parsedPages, 12);
    expect(coverage.canClaimFullCheck, isFalse);
  });

  test('chapter detection and knowledge-point aliases improve recall', () {
    fixture.repository.replaceChapters(fixture.document, [
      BookChapter(
        id: 'c1',
        documentId: fixture.document.id,
        documentHash: fixture.document.contentHash,
        ordinal: 0,
        title: '第一章 聚合物基础',
        startPage: 1,
        endPage: 3,
      ),
      BookChapter(
        id: 'c2',
        documentId: fixture.document.id,
        documentHash: fixture.document.contentHash,
        ordinal: 1,
        title: '第二章 链结构',
        startPage: 4,
        endPage: 8,
      ),
      BookChapter(
        id: 'c3',
        documentId: fixture.document.id,
        documentHash: fixture.document.contentHash,
        ordinal: 2,
        title: '第三章 共聚',
        startPage: 9,
        endPage: 12,
      ),
    ]);
    fixture.repository.saveKnowledgePoints([
      BookKnowledgePoint(
        id: 'kp-head-tail',
        documentId: fixture.document.id,
        documentHash: fixture.document.contentHash,
        chapterId: 'c2',
        term: '头尾键连',
        termNorm: '头尾键连',
        startPage: 7,
        endPage: 8,
        englishAlias: 'head-to-tail',
        definition: '重复单元以头—尾方向相连。',
        aliases: const ['键接', '头尾连接', 'head-to-tail'],
        verified: true,
      ),
    ]);

    final retrieval = fixture.retriever.retrieve(
      fixture.document,
      'head-to-tail 键接为什么更常见？',
      focusPage: 1,
    );
    expect(retrieval.matchedKnowledge.single.term, '头尾键连');
    expect(retrieval.evidence.map((item) => item.page), contains(7));
    expect(retrieval.hitChapters.map((chapter) => chapter.id), contains('c2'));
  });

  test('current-page mode never returns another page', () {
    final retrieval = fixture.retriever.retrieve(
      fixture.document,
      '头尾键连是什么？',
      focusPage: 11,
      currentPageOnly: true,
    );
    expect(retrieval.searchedWholeBook, isFalse);
    expect(retrieval.evidence, isNotEmpty);
    expect(
      retrieval.evidence.every((item) => item.page >= 10 && item.page <= 12),
      isTrue,
    );
    expect(retrieval.coverage().scope, contains('第 11 页'));
    expect(retrieval.coverage().wholeBookSearched, isFalse);
  });

  test(
    'missing pages are reported as gaps instead of "the book does not say"',
    () {
      final page = fixture.store.getPage(fixture.document.id, 12)!;
      fixture.store.savePage(
        page.copyWith(text: '', status: PageStatus.needsOcr),
      );
      final retrieval = fixture.retriever.retrieve(
        fixture.document,
        '这本书有没有讲超导？',
        focusPage: 3,
      );
      final coverage = retrieval.coverage();
      expect(coverage.gaps, contains(contains('第 12 页')));
      expect(coverage.note, contains('未命中不能说明全书没有'));
      expect(coverage.canClaimFullCheck, isFalse);
    },
  );

  test('author-intent questions are classified separately', () {
    final analysis = fixture.retriever.analyze('作者到底有没有说过头尾连接？');
    expect(analysis.asksAuthor, isTrue);
  });

  test('web queries stay short and use a known English alias', () {
    fixture.repository.saveKnowledgePoints([
      BookKnowledgePoint(
        id: 'kp',
        documentId: fixture.document.id,
        documentHash: fixture.document.contentHash,
        chapterId: null,
        term: '头尾键连',
        termNorm: '头尾键连',
        startPage: 7,
        endPage: 7,
        englishAlias: 'head-to-tail addition',
        aliases: const ['键接'],
        verified: true,
      ),
    ]);
    final retrieval = fixture.retriever.retrieve(
      fixture.document,
      '为什么聚合物多以头尾键连为主？',
      focusPage: 12,
    );
    final queries = retrieval.webQueries();
    expect(queries, hasLength(2));
    expect(queries.first, contains('头尾键连'));
    expect(queries.first, contains('原因'));
    expect(queries.last.toLowerCase(), contains('head-to-tail'));
    expect(queries.every((query) => query.runes.length <= 128), isTrue);
  });
}
