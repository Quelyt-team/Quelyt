import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:local_study/features/book_qa/models/book_qa_models.dart';
import 'package:local_study/features/book_qa/services/book_qa_client.dart';
import 'package:local_study/features/book_qa/services/book_qa_service.dart';
import 'package:local_study/services/ai_gateway.dart';

import 'book_fixture.dart';

void main() {
  late BookFixture fixture;
  late BookQaService service;
  late BookConversation conversation;

  setUp(() async {
    fixture = BookFixture.create();
    await fixture.saveKey();
    service = BookQaService(
      store: fixture.store,
      repository: fixture.repository,
      transport: fixture.gateway.transport,
    );
    conversation = fixture.repository.ensureConversation(fixture.document);
  });

  tearDown(() => fixture.dispose());

  PreparedBookQaRequest prepare(
    String question, {
    BookAskMode mode = BookAskMode.wholeBookWeb,
    int page = 12,
  }) => service.prepare(
    document: fixture.document,
    conversation: conversation,
    question: question,
    settings: fixture.settings,
    mode: mode,
    currentPage: page,
    history: const [],
  );

  test('a page-12 question reaches page 7 and uses real web sources', () async {
    final prepared = prepare('为什么聚合物多以头尾键连为主？');
    expect(prepared.bookSources, isNotEmpty);
    expect(prepared.bookSources.map((source) => source.page), contains(7));
    expect(prepared.webEnabled, isTrue);
    expect(prepared.searchQueries, hasLength(2));
    expect(prepared.maxSearchRequests, 2);
    expect(prepared.maxFetchRequests, 3);

    final answer = await service.ask(prepared);
    expect(fixture.server.searchCalls, 2);
    expect(fixture.server.fetchCalls, 2);
    expect(fixture.server.chatCalls, 1);
    expect(answer.webStatus, WebLookupStatus.searched);
    expect(answer.webSources, hasLength(2));
    expect(answer.webSources.every((source) => source.fullText), isTrue);
    expect(answer.webSources.map((source) => source.id), ['W1', 'W2']);
    expect(answer.bookSources, isNotEmpty);
    expect(answer.coverage.wholeBookSearched, isTrue);
    expect(answer.coverage.scope, contains('整本教材'));
    expect(answer.blocks, isNotEmpty);
    expect(answer.usage.searchRequests, 2);
    expect(answer.usage.fetchRequests, 2);

    final user = fixture.chatUserAt(0);
    expect(user['task'], 'bookQuestion');
    expect((user['web_lookup'] as Map)['status'], 'searched');
    expect((user['web_sources'] as List), hasLength(2));
    expect((user['book_evidence'] as List), isNotEmpty);
    final cited = (answer.blocks.first.bookCitationIds);
    expect(cited, isNot(contains('B99')));
  });

  test(
    'search failure still produces a book-based answer without fake links',
    () async {
      fixture.server.failSearch = true;
      final prepared = prepare('为什么聚合物多以头尾键连为主？');
      final answer = await service.ask(prepared);
      expect(answer.webStatus, WebLookupStatus.failed);
      expect(answer.webSources, isEmpty);
      expect(answer.blocks, isNotEmpty);
      expect(answer.webNote, contains('仅依据'));
      expect(fixture.server.chatCalls, 1);
      final user = fixture.chatUserAt(0);
      expect((user['web_lookup'] as Map)['status'], 'failed');
      expect(user['web_sources'], isEmpty);
      expect(
        jsonEncode(user),
        isNot(contains('https://chemistry.example.edu')),
      );
    },
  );

  test('book-only mode sends no search or fetch request', () async {
    final prepared = prepare('为什么聚合物多以头尾键连为主？', mode: BookAskMode.bookOnly);
    expect(prepared.webEnabled, isFalse);
    expect(prepared.searchQueries, isEmpty);
    final answer = await service.ask(prepared);
    expect(fixture.server.searchCalls, 0);
    expect(fixture.server.fetchCalls, 0);
    expect(answer.webStatus, WebLookupStatus.disabled);
    expect(answer.webSources, isEmpty);
    expect(fixture.server.chatCalls, 1);
  });

  test('author verification is strict and never uses the web', () async {
    final prepared = prepare('作者到底有没有说过聚合物多以头尾键连为主？');
    expect(prepared.strictAuthor, isTrue);
    expect(prepared.webEnabled, isFalse);
    final answer = await service.ask(prepared);
    expect(fixture.server.searchCalls, 0);
    expect(answer.webStatus, WebLookupStatus.notNeeded);
    final payload =
        jsonDecode(fixture.server.lastChatRequest.body) as Map<String, dynamic>;
    final system =
        ((payload['messages'] as List)[0] as Map)['content'] as String;
    expect(system, contains('只核查'));
    expect(system, contains('不得用外部资料'));
  });

  test(
    'a cached page is reused and marked as cached, not freshly read',
    () async {
      fixture.server.searchContentIncluded = true;
      final first = prepare('为什么聚合物多以头尾键连为主？');
      final firstAnswer = await service.ask(first);
      expect(firstAnswer.webStatus, WebLookupStatus.searched);
      expect(fixture.server.fetchCalls, 0);

      fixture.server.searchContentIncluded = false;
      final second = prepare('为什么聚合物多以头尾键连为主？');
      final secondAnswer = await service.ask(second);
      expect(fixture.server.fetchCalls, 0);
      expect(secondAnswer.webStatus, WebLookupStatus.cached);
      expect(
        secondAnswer.webSources.every((source) => source.fromCache),
        isTrue,
      );
      expect(secondAnswer.webNote, contains('缓存'));
    },
  );

  test(
    'a time-sensitive question bypasses the cache and fetches again',
    () async {
      fixture.server.searchContentIncluded = true;
      await service.ask(prepare('为什么聚合物多以头尾键连为主？'));
      fixture.server.searchContentIncluded = false;
      final prepared = prepare('这个方向最新研究进展是什么？');
      expect(prepared.timeSensitive, isTrue);
      final answer = await service.ask(prepared);
      expect(fixture.server.fetchCalls, greaterThan(0));
      expect(answer.webStatus, WebLookupStatus.searched);
      expect(answer.webSources.every((source) => !source.fromCache), isTrue);
    },
  );

  test('invalid citation IDs are rejected and never become links', () async {
    fixture.server.questionContent = {
      'answerStatus': 'answered',
      'blocks': [
        {
          'text': '教材说……',
          'bookCitations': ['B99'],
          'webCitations': ['W99'],
          'supplemental': false,
        },
      ],
      'bookCoverage': {
        'scope': '全书',
        'matchedChapters': ['不存在的章节'],
        'gaps': <String>[],
      },
      'missingInformation': <String>[],
    };
    final answer = await service.ask(prepare('为什么聚合物多以头尾键连为主？'));
    expect(answer.answerStatus, AnswerStatus.partial);
    expect(answer.rejectedCitationIds, containsAll(['B99', 'W99']));
    expect(answer.requiresVerification, isTrue);
    expect(answer.blocks.single.bookCitationIds, isEmpty);
    expect(answer.blocks.single.webCitationIds, isEmpty);
    expect(answer.coverage.hitChapters, isNot(contains('不存在的章节')));
  });

  test(
    'an answer without citations is valid, not automatically insufficient',
    () async {
      fixture.server.questionContent = {
        'answerStatus': 'answered',
        'blocks': [
          {
            'text': '教材给出了连接方式，原因属于学科解释。',
            'bookCitations': <String>[],
            'webCitations': <String>[],
            'supplemental': true,
          },
        ],
        'bookCoverage': {
          'scope': '全书',
          'matchedChapters': <String>[],
          'gaps': <String>[],
        },
        'missingInformation': <String>[],
      };
      final answer = await service.ask(prepare('为什么聚合物多以头尾键连为主？'));
      expect(answer.answerStatus, AnswerStatus.answered);
      expect(answer.requiresVerification, isFalse);
      expect(answer.blocks.single.text, isNotEmpty);
    },
  );

  test('cancelling before sending prevents every network request', () async {
    final prepared = prepare('为什么聚合物多以头尾键连为主？');
    prepared.cancel();
    await expectLater(
      service.ask(prepared),
      throwsA(
        isA<AiFailure>().having(
          (error) => error.code,
          'code',
          AiError.cancelled,
        ),
      ),
    );
    expect(fixture.server.requests, isEmpty);
  });

  test('a deleted textbook invalidates a prepared question', () async {
    final prepared = prepare('为什么聚合物多以头尾键连为主？');
    fixture.store.deleteDocument(fixture.document.id);
    await expectLater(
      service.ask(prepared),
      throwsA(
        isA<AiFailure>().having(
          (error) => error.code,
          'code',
          AiError.rejected,
        ),
      ),
    );
    expect(fixture.server.requests, isEmpty);
  });

  test('the preview describes the bounded flow instead of unseen text', () {
    final prepared = prepare('为什么聚合物多以头尾键连为主？');
    expect(prepared.previewSummary, contains('搜索词'));
    expect(prepared.previewSummary, contains('2 次搜索'));
    expect(prepared.previewSummary, contains('包含搜索结果的流程授权'));
  });

  test('an empty answer block list is rejected instead of shown', () async {
    fixture.server.questionContent = {
      'answerStatus': 'answered',
      'blocks': <Map<String, dynamic>>[],
      'bookCoverage': {
        'scope': '全书',
        'matchedChapters': <String>[],
        'gaps': <String>[],
      },
      'missingInformation': <String>[],
    };
    await expectLater(
      service.ask(prepare('为什么？', mode: BookAskMode.bookOnly)),
      throwsA(
        isA<AiFailure>().having(
          (error) => error.code,
          'code',
          AiError.invalidResponse,
        ),
      ),
    );
  });

  test('an undeclared answer field is rejected instead of trusted', () async {
    fixture.server.questionContent = {
      'answerStatus': 'answered',
      'blocks': [
        {
          'text': '教材说……',
          'bookCitations': <String>[],
          'webCitations': <String>[],
          'supplemental': false,
        },
      ],
      'bookCoverage': {
        'scope': '全书',
        'matchedChapters': <String>[],
        'gaps': <String>[],
      },
      'missingInformation': <String>[],
      'webStatus': 'searched',
    };
    await expectLater(
      service.ask(prepare('为什么？', mode: BookAskMode.bookOnly)),
      throwsA(
        isA<AiFailure>().having(
          (error) => error.code,
          'code',
          AiError.invalidResponse,
        ),
      ),
    );
  });

  test(
    'an image question uses the vision model and a one-time approval',
    () async {
      const visionSettings = ProviderSettings(
        provider: 'DeepSeek',
        baseUrl: 'https://api.deepseek.com',
        model: 'deepseek-flash',
        visionModel: 'vision-model',
      );
      final attachment = ImageAttachment(
        bytes: base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jC1kAAAAASUVORK5CYII=',
        ),
        mimeType: 'image/png',
        scopeLabel: '第 7 页 · 框选区域',
      );
      final prepared = service.prepare(
        document: fixture.document,
        conversation: conversation,
        question: '这张图里的结构说明了什么？',
        settings: visionSettings,
        mode: BookAskMode.wholeBookWeb,
        currentPage: 7,
        history: const [],
        image: attachment,
      );
      expect(prepared.model, 'vision-model');
      expect(prepared.hasImage, isTrue);
      expect(prepared.previewSummary, contains('图片'));
      await expectLater(
        service.ask(prepared),
        throwsA(
          isA<AiFailure>().having(
            (error) => error.code,
            'code',
            AiError.imageApprovalRequired,
          ),
        ),
      );
      expect(fixture.server.requests, isEmpty);

      final approval = prepared.approveImage();
      final answer = await service.ask(prepared, imageApproval: approval);
      expect(answer.blocks, isNotEmpty);
      final payload = jsonDecode(
        fixture.server.lastChatRequest.body,
      ) as Map<String, dynamic>;
      final content =
          ((payload['messages'] as List)[1] as Map)['content'] as List;
      expect((content[0] as Map)['type'], 'text');
      expect(
        ((content[1] as Map)['image_url'] as Map)['url'],
        startsWith('data:image/png;base64,'),
      );
      expect(payload.containsKey('response_format'), isFalse);
      expect(prepared.isImageApproved(approval), isFalse);
    },
  );
}
