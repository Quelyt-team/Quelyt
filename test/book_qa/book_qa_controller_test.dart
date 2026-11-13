import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';

import 'package:local_study/app_controller.dart';
import 'package:local_study/core/models.dart';
import 'package:local_study/features/book_qa/book_qa_controller.dart';
import 'package:local_study/services/ai_gateway.dart';
import 'package:local_study/services/document_service.dart';
import 'package:local_study/services/ocr_service.dart';

import 'book_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BookFixture fixture;
  late Directory directory;
  late StudyController study;
  late BookQaController qa;
  late MemoryVault vault;
  late Completer<void> chatGate;
  late Completer<void> chatStarted;
  late bool delayChat;

  DocumentRecord secondBook() {
    final document = DocumentRecord(
      id: 'book-2',
      title: '有机化学',
      kind: DocumentKind.textbook,
      filePath: r'C:\managed\book-2\original.pdf',
      contentHash: 'sha256-book-version-2',
      pageCount: 4,
    );
    fixture.store.importDocument(
      document,
      List.generate(
        4,
        (index) => PageRecord(
          documentId: document.id,
          page: index + 1,
          text: '第 ${index + 1} 章 有机化学 ${bookPageTexts[index]}',
          status: PageStatus.ready,
        ),
      ),
    );
    for (var page = 1; page <= 4; page++) {
      fixture.store.replacePageEvidence(document.id, page, [
        Evidence(
          id: '${document.id}:$page:t0',
          documentId: document.id,
          documentHash: document.contentHash,
          page: page,
          region: const SourceRegion(.08, .1, .95, .92),
          text: '第 $page 页 有机化学内容，讨论官能团与反应。',
        ),
      ]);
    }
    return document;
  }

  setUp(() async {
    fixture = BookFixture.create();
    directory = Directory.systemTemp.createTempSync('book-qa-controller-');
    vault = MemoryVault();
    await vault.write(fixture.settings.credentialId, 'test-secret-key');
    chatGate = Completer<void>();
    chatStarted = Completer<void>();
    delayChat = false;
    final gateway = AiGateway(
      vault: vault,
      client: MockClient((request) async {
        if (delayChat && request.url.path.contains('chat')) {
          if (!chatStarted.isCompleted) chatStarted.complete();
          await chatGate.future;
        }
        return fixture.server.handle(request);
      }),
    );
    final ocr = OcrService();
    study = StudyController(
      store: fixture.store,
      ocr: ocr,
      gateway: gateway,
      documents: DocumentService(directory, fixture.store, ocr),
    );
    study.current = fixture.document;
    study.settings = fixture.settings;
    qa = BookQaController(study: study);
    qa.attach(fixture.document);
    addTearDown(() async {
      qa.dispose();
      study.dispose();
      await study.shutdown();
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
  });

  test('turning pages does not clear the textbook conversation', () async {
    final prepared = await qa.prepare('为什么聚合物多以头尾键连为主？');
    await qa.send(prepared);
    expect(qa.turns, hasLength(1));
    expect(qa.turns.single.answer, isNotNull);

    study.page = 3;
    qa.attach(fixture.document);
    expect(qa.turns, hasLength(1));
    expect(qa.turns.single.question, '为什么聚合物多以头尾键连为主？');

    study.page = 10;
    qa.attach(fixture.document);
    expect(qa.turns, hasLength(1));
  });

  test(
    'switching books switches conversations without losing the first',
    () async {
      final first = await qa.prepare('为什么聚合物多以头尾键连为主？');
      await qa.send(first);
      final firstConversation = qa.conversation!.id;
      final second = secondBook();

      study.current = second;
      qa.attach(second);
      expect(qa.conversation!.id, isNot(firstConversation));
      expect(qa.turns, isEmpty);

      final prepared = await qa.prepare('官能团是什么？');
      await qa.send(prepared);
      expect(qa.turns.single.question, '官能团是什么？');

      study.current = fixture.document;
      qa.attach(fixture.document);
      expect(qa.conversation!.id, firstConversation);
      expect(qa.turns, hasLength(1));
      expect(qa.turns.single.answer, isNotNull);
    },
  );

  test('a late answer is stored in its original conversation after switching books', () async {
    delayChat = true;
    final prepared = await qa.prepare('为什么聚合物多以头尾键连为主？');
    final firstConversation = qa.conversation!.id;
    final sending = qa.send(prepared);
    await chatStarted.future;

    final second = secondBook();
    study.current = second;
    qa.attach(second);
    expect(qa.turns, isEmpty);

    chatGate.complete();
    await sending;

    expect(
      qa.turns,
      isEmpty,
      reason: 'the visible conversation is the new book',
    );
    final stored = fixture.repository.getTurns(firstConversation);
    expect(stored, hasLength(1));
    expect(stored.single.answer, isNotNull);

    study.current = fixture.document;
    qa.attach(fixture.document);
    expect(qa.turns, hasLength(1));
    expect(qa.turns.single.answer, isNotNull);
  });

  test('cancelling before the network writes a cancelled turn', () async {
    final prepared = await qa.prepare('为什么聚合物多以头尾键连为主？');
    prepared.cancel();
    await qa.send(prepared);
    expect(fixture.server.requests, isEmpty);
    expect(qa.turns, hasLength(1));
    expect(qa.turns.single.cancelled, isTrue);
    expect(qa.notice, contains('取消'));
  });

  test(
    'legacy replies appear in the new panel and keep their sources',
    () async {
      fixture.store.setSetting(
        'history:${fixture.document.id}',
        jsonEncode([
          {
            'question': '以前问过的问题',
            'answer': '以前保存的回答',
            'sources': [
              Evidence(
                id: 'legacy-source',
                documentId: fixture.document.id,
                documentHash: fixture.document.contentHash,
                page: 7,
                region: const SourceRegion(.1, .1, .9, .9),
                text: '以前的原文',
              ).toJson(),
            ],
            'model': 'old-model',
            'tokens': 12,
            'insufficient': false,
            'task': 'explain',
            'documentHash': fixture.document.contentHash,
            'createdAt': '2026-01-01T00:00:00.000',
          },
        ]),
      );
      qa.attach(null);
      qa.attach(fixture.document);
      expect(qa.turns, hasLength(1));
      expect(qa.turns.single.question, '以前问过的问题');
      expect(qa.turns.single.answer!.bookSources.single.page, 7);
    },
  );
}
