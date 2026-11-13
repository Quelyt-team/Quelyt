import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:local_study/core/models.dart';
import 'package:local_study/features/book_qa/data/book_qa_repository.dart';
import 'package:local_study/features/book_qa/models/book_qa_models.dart';

import 'book_fixture.dart';

void main() {
  late BookFixture fixture;
  late BookQaRepository repository;
  late BookConversation conversation;

  setUp(() {
    fixture = BookFixture.create();
    repository = fixture.repository;
    conversation = repository.ensureConversation(fixture.document);
  });

  tearDown(() => fixture.dispose());

  test('questions and answers are paired in order and survive a reload', () {
    final first = repository.appendQuestion(
      conversation,
      '为什么头尾连接更常见？',
      BookAskMode.wholeBookWeb,
    );
    repository.saveAnswer(conversation, first, _answer('第一个回答'));
    final second = repository.appendQuestion(
      conversation,
      '那头头连接为什么少？',
      BookAskMode.wholeBookWeb,
    );
    repository.saveFailure(conversation, second, '网络未完成');

    final turns = repository.getTurns(conversation.id);
    expect(turns, hasLength(2));
    expect(turns.first.question, '为什么头尾连接更常见？');
    expect(turns.first.answer?.plainText, '第一个回答');
    expect(turns.last.failure, '网络未完成');
    expect(turns.last.answer, isNull);
    expect(repository.getConversation(conversation.id)!.title, '为什么头尾连接更常见？');
  });

  test('legacy replies are imported once with their book sources', () {
    fixture.store.setSetting(
      'history:${fixture.document.id}',
      jsonEncode([
        {
          'question': '旧问题',
          'answer': '旧回答',
          'sources': [
            Evidence(
              id: 'old-source',
              documentId: fixture.document.id,
              documentHash: fixture.document.contentHash,
              page: 7,
              region: const SourceRegion(.1, .1, .9, .9),
              text: '旧原文',
            ).toJson(),
          ],
          'model': 'old-model',
          'tokens': 42,
          'insufficient': false,
          'task': 'explain',
          'sessionId': 'old-session',
          'documentHash': fixture.document.contentHash,
          'createdAt': '2026-01-01T00:00:00.000',
        },
      ]),
    );
    final replies = [
      LegacyBookReply(
        question: '旧问题',
        answer: '旧回答',
        sources: [
          Evidence(
            id: 'old-source',
            documentId: fixture.document.id,
            documentHash: fixture.document.contentHash,
            page: 7,
            region: const SourceRegion(.1, .1, .9, .9),
            text: '旧原文',
          ),
        ],
        model: 'old-model',
        tokens: 42,
      ),
    ];
    expect(repository.importLegacyReplies(conversation, replies), 1);
    expect(repository.importLegacyReplies(conversation, replies), 0);
    final turns = repository.getTurns(conversation.id);
    expect(turns, hasLength(1));
    expect(turns.single.answer?.bookSources.single.page, 7);
    expect(turns.single.answer?.webStatus, WebLookupStatus.notNeeded);
  });

  test('deleting a textbook cascades through conversations and messages', () {
    final turn = repository.appendQuestion(
      conversation,
      '会被一起删除吗？',
      BookAskMode.bookOnly,
    );
    repository.saveAnswer(conversation, turn, _answer('会'));
    fixture.store.deleteDocument(fixture.document.id);
    expect(repository.getConversation(conversation.id), isNull);
    final counts = fixture.store.selectRows('''SELECT
        (SELECT COUNT(*) FROM book_qa_messages) AS messages,
        (SELECT COUNT(*) FROM book_qa_conversations) AS conversations,
        (SELECT COUNT(*) FROM book_understanding_jobs) AS jobs''').single;
    expect(counts['messages'], 0);
    expect(counts['conversations'], 0);
    expect(counts['jobs'], 0);
  });

  test('web pages are cached with age limits and pruned', () {
    final now = DateTime.now();
    repository.saveCachedPage(
      WebCacheEntry(
        url: 'https://example.edu/a',
        title: 'A',
        content: '正文',
        fetchedAt: now,
      ),
    );
    expect(repository.getCachedPage('https://example.edu/a')!.title, 'A');
    expect(
      repository.getCachedPage(
        'https://example.edu/a',
        maxAge: const Duration(days: 7),
      ),
      isNotNull,
    );
    repository.saveCachedPage(
      WebCacheEntry(
        url: 'https://example.edu/old',
        title: 'old',
        content: '旧正文',
        fetchedAt: now.subtract(const Duration(days: 60)),
      ),
    );
    expect(
      repository.getCachedPage(
        'https://example.edu/old',
        maxAge: const Duration(days: 7),
      ),
      isNull,
    );
    repository.pruneWebCache(maxAge: const Duration(days: 30));
    expect(repository.getCachedPage('https://example.edu/old'), isNull);
    expect(repository.getCachedPage('https://example.edu/a'), isNotNull);
  });

  test('a cancelled or failed turn stays visible', () {
    final turn = repository.appendQuestion(
      conversation,
      '取消的问题',
      BookAskMode.wholeBookWeb,
    );
    repository.saveCancelled(conversation, turn);
    final reloaded = repository.getTurns(conversation.id).single;
    expect(reloaded.cancelled, isTrue);
    expect(reloaded.pending, isFalse);
  });
}

BookQaAnswer _answer(String text) {
  final evidence = Evidence(
    id: 'book-1:7:t0',
    documentId: 'book-1',
    documentHash: 'sha256-book-version-1',
    page: 7,
    region: const SourceRegion(.08, .1, .95, .92),
    text: '聚合物多以头尾键连为主。',
  );
  return BookQaAnswer(
    answerStatus: AnswerStatus.answered,
    blocks: [
      BookAnswerBlock(text: text, bookCitationIds: const ['B1']),
    ],
    coverage: const BookCoverage(
      scope: '整本教材 12/12 页',
      wholeBookSearched: true,
      understandingComplete: false,
      parsedPages: 12,
      totalPages: 12,
    ),
    webStatus: WebLookupStatus.searched,
    bookSources: [BookCitation(id: 'B1', evidence: evidence)],
    webSources: const [],
    usage: const BookQaUsage(searchRequests: 1),
    model: 'test-model',
    provider: '测试',
    requestId: 'r1',
    webNote: '搜索 1 次',
  );
}
