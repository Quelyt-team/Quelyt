import 'package:flutter_test/flutter_test.dart';

import 'package:local_study/core/models.dart';
import 'package:local_study/features/book_qa/models/book_understanding.dart';
import 'package:local_study/features/book_qa/services/book_understanding_client.dart';
import 'package:local_study/features/book_qa/services/book_understanding_service.dart';

import 'book_fixture.dart';

void main() {
  late BookFixture fixture;
  late BookUnderstandingService service;

  setUp(() async {
    fixture = BookFixture.create();
    await fixture.saveKey();
    service = BookUnderstandingService(
      store: fixture.store,
      repository: fixture.repository,
      client: BookUnderstandingClient(fixture.gateway.transport),
    );
  });

  tearDown(() => fixture.dispose());

  test(
    'structure planning covers every chapter and page without a silent cap',
    () {
      final estimate = service.estimate(fixture.document);
      expect(estimate.chapterCount, 3);
      expect(estimate.chunkCount, 3);
      expect(estimate.pages.readyPages, 12);
      expect(estimate.pendingChunks, 3);
      final chapters = fixture.repository.getChapters(fixture.document.id);
      expect(chapters.map((chapter) => chapter.startPage), [1, 4, 9]);
      expect(chapters.last.endPage, 12);
      final chunks = fixture.repository.getChunks(fixture.document.id);
      expect(chunks.map((chunk) => chunk.startPage), [1, 4, 9]);
      expect(chunks.every((chunk) => chunk.sourceDigest.isNotEmpty), isTrue);
    },
  );

  test(
    'a bounded run processes only its batch and keeps the rest resumable',
    () async {
      final first = await service.run(
        fixture.document,
        fixture.settings,
        maxChunks: 1,
      );
      expect(first.processedChunks, 1);
      expect(first.progress.chunkReady, 1);
      expect(first.progress.chunkTotal, 3);
      expect(first.progress.complete, isFalse);
      expect(first.note, contains('还有 2 块待继续'));

      final estimate = service.estimate(fixture.document);
      expect(estimate.pendingChunks, 2);

      final second = await service.run(
        fixture.document,
        fixture.settings,
        maxChunks: 10,
      );
      expect(second.processedChunks, 2);
      expect(second.progress.chunkReady, 3);
      expect(second.progress.complete, isTrue);
      expect(second.overviewGenerated, isTrue);
      expect(second.progress.overview, isNotNull);
      expect(second.progress.overview!.subject, contains('高分子'));
      expect(fixture.server.chatCalls, 4);
    },
  );

  test('chunk text is limited to the chunk page range', () async {
    await service.run(fixture.document, fixture.settings, maxChunks: 1);
    final user = fixture.chatUserAt(0);
    expect(user['task'], 'understandChunk');
    final pages = (user['pages'] as List).cast<Map<String, dynamic>>();
    expect(pages.map((page) => page['page']), [1, 2, 3]);
    expect((user['book'] as Map)['documentHash'], fixture.document.contentHash);
  });

  test(
    'knowledge points merge by term and keep their chapter and pages',
    () async {
      await service.run(fixture.document, fixture.settings, maxChunks: 10);
      final points = fixture.repository.getKnowledgePoints(fixture.document.id);
      final headToTail = points.where((point) => point.termNorm == '头尾键连');
      expect(headToTail, isNotEmpty);
      expect(headToTail.first.englishAlias, 'head-to-tail');
      expect(headToTail.first.startPage, greaterThanOrEqualTo(1));
      expect(
        points.any((point) => point.term == '单体' && point.chapterId != null),
        isTrue,
      );
    },
  );

  test(
    'a failed chunk is recorded and repeated failures stop the run',
    () async {
      fixture.server.chunkFailure = true;
      final result = await service.run(
        fixture.document,
        fixture.settings,
        maxChunks: 10,
      );
      expect(result.processedChunks, 0);
      expect(result.progress.chunkFailed, 3);
      expect(result.progress.status, BookJobStatus.failed);
      expect(result.note, contains('连续 3 个分块整理失败'));
      expect(fixture.server.chatCalls, 3);
    },
  );

  test('editing page text rebuilds only the affected chunk', () async {
    await service.run(fixture.document, fixture.settings, maxChunks: 10);
    final before = fixture.repository.getChunks(fixture.document.id);
    final ready = before.where(
      (chunk) => chunk.status == BookChunkStatus.ready,
    );
    expect(ready, hasLength(3));
    expect(fixture.repository.progress(fixture.document).complete, isTrue);

    final page = fixture.store.getPage(fixture.document.id, 7)!;
    fixture.store.savePage(
      page.copyWith(
        text: '在常见乙烯基单体的自由基聚合中，聚合物多以头尾键连为主。新增校正说明。',
        status: PageStatus.ready,
        manuallyCorrected: true,
      ),
    );
    final estimate = service.estimate(fixture.document);
    expect(estimate.pendingChunks, 1);
    final after = fixture.repository.getChunks(fixture.document.id);
    expect(
      after.singleWhere((chunk) => chunk.startPage == 4).status,
      BookChunkStatus.pending,
    );
    expect(
      after.singleWhere((chunk) => chunk.startPage == 1).status,
      BookChunkStatus.ready,
    );
    final progress = fixture.repository.progress(fixture.document);
    expect(
      progress.overview,
      isNull,
      reason: 'a stale overview must not be reused',
    );
    expect(progress.complete, isFalse);
  });

  test(
    'an overview failure leaves the book retryable instead of complete',
    () async {
      fixture.server.overviewContent = {
        'subject': '',
        'conventions': 'x',
        'chapterRelations': <String>[],
        'themes': <String>[],
        'unfinished': <String>[],
      };
      final first = await service.run(
        fixture.document,
        fixture.settings,
        maxChunks: 10,
      );
      expect(first.progress.chunkReady, 3);
      expect(first.progress.complete, isFalse);
      expect(first.overviewGenerated, isFalse);
      expect(first.note, contains('全书概览未生成'));
      expect(first.progress.status, BookJobStatus.partial);

      fixture.server.overviewContent = null;
      final second = await service.run(
        fixture.document,
        fixture.settings,
        maxChunks: 10,
      );
      expect(second.processedChunks, 0);
      expect(second.overviewGenerated, isTrue);
      expect(second.progress.complete, isTrue);
    },
  );

  test('user chapter boundaries rebuild chunks and still cover the book', () {
    service.applyChapters(fixture.document, [
      (title: '上半', startPage: 1, endPage: 5),
      (title: '下半', startPage: 6, endPage: 12),
    ]);
    final chapters = fixture.repository.getChapters(fixture.document.id);
    expect(chapters.map((chapter) => chapter.title), ['上半', '下半']);
    final chunks = fixture.repository.getChunks(fixture.document.id);
    expect(chunks, isNotEmpty);
    expect(
      chunks.every((chunk) => chunk.startPage >= 1 && chunk.endPage <= 12),
      isTrue,
    );
  });

  test(
    'an explicitly skipped blank page completes coverage without fake text',
    () {
      service.markPagesSkipped(fixture.document, [12]);
      final progress = fixture.repository.progress(fixture.document);
      expect(progress.pages.skippedPages, 1);
      expect(progress.pages.allParsed, isTrue);
      expect(progress.pages.gapLabel, isEmpty);
    },
  );

  test('more than 40 chunks keep the unprocessed rest persisted', () async {
    fixture.dispose();
    fixture = BookFixture.create(pageCount: 240);
    await fixture.saveKey();
    service = BookUnderstandingService(
      store: fixture.store,
      repository: fixture.repository,
      client: BookUnderstandingClient(fixture.gateway.transport),
    );
    final estimate = service.estimate(fixture.document);
    expect(estimate.chunkCount, greaterThan(40));
    final result = await service.run(
      fixture.document,
      fixture.settings,
      maxChunks: 40,
    );
    expect(result.processedChunks, 40);
    expect(result.progress.chunkReady, 40);
    final remaining = service.estimate(fixture.document);
    expect(remaining.pendingChunks, estimate.chunkCount - 40);
    expect(
      fixture.repository.getChunks(fixture.document.id).length,
      estimate.chunkCount,
    );
  });
}
