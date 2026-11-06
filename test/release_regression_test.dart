import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:local_study/app_controller.dart';
import 'package:local_study/core/local_store.dart';
import 'package:local_study/core/models.dart';
import 'package:local_study/services/ai_gateway.dart';
import 'package:local_study/services/document_service.dart';
import 'package:local_study/services/ocr_service.dart';
import 'package:local_study/ui/dialogs/app_dialogs.dart';
import 'package:local_study/ui/theme/app_theme.dart';

class _Vault implements CredentialVault {
  @override
  Future<String?> read(String id) async => 'synthetic-test-key';
  @override
  Future<void> write(String id, String value) async {}
  @override
  Future<void> delete(String id) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late StudyController controller;
  late LocalStore store;
  late DocumentRecord document;
  late List<http.Request> sent;
  late bool insufficient;
  late int status;
  Completer<void>? started;
  Completer<void>? finish;

  setUp(() {
    sent = [];
    insufficient = false;
    status = 200;
    started = null;
    finish = null;
    store = LocalStore.inMemory();
    final ocr = OcrService();
    controller = StudyController(
      store: store,
      ocr: ocr,
      documents: DocumentService(Directory.systemTemp, store, ocr),
      gateway: AiGateway(
        vault: _Vault(),
        client: MockClient((request) async {
          sent.add(request);
          started?.complete();
          await finish?.future;
          final user = jsonDecode(
            jsonDecode(request.body)['messages'][1]['content'] as String,
          ) as Map;
          final evidence = user['evidence'] as List? ?? [];
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'choices': [
                  {
                    'finish_reason': 'stop',
                    'message': {
                      'content': jsonEncode({
                        'answer': insufficient ? '请补充资料后再试。' : '核验用的模拟回答。',
                        'citations': insufficient || evidence.isEmpty
                            ? <String>[]
                            : [evidence.first['id']],
                        'insufficientEvidence': insufficient,
                      }),
                    },
                  },
                ],
              }),
            ),
            status,
          );
        }),
      ),
    );
    document = DocumentRecord(
      id: 'release-test',
      title: '合成验收资料',
      kind: DocumentKind.paper,
      filePath: 'synthetic-only',
      contentHash: 'fixture-v1',
      pageCount: 20,
    );
    store.importDocument(
      document,
      List.generate(
        20,
        (index) => PageRecord(documentId: document.id, page: index + 1),
      ),
    );
    controller.current = document;
    store.saveEvidence(
      Evidence(
        id: 'e1',
        documentId: document.id,
        documentHash: document.contentHash,
        page: 1,
        region: SourceRegion.fullPage,
        text: '动量等于质量与速度的乘积。',
      ),
    );
  });

  tearDown(() async {
    if (finish != null && !finish!.isCompleted) finish!.complete();
    await controller.shutdown();
    controller.dispose();
  });

  testWidgets(
    'preview shows all added history and coverage; cancel sends nothing',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      store.setSetting(
        'history:${document.id}',
        jsonEncode([
          SavedReply(
            question: '可预览的上一问',
            answer: '可预览的上一答',
            sources: [],
            model: 'fixture',
            tokens: 0,
            task: AiTask.explain.name,
            documentHash: document.contentHash,
          ).toJson(),
        ]),
      );
      final followup = controller.prepare(AiTask.explain, '继续解释');
      final overview = controller.prepare(AiTask.paperGuide, '导读');
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  for (final entry in [
                    ('history', followup),
                    ('overview', overview),
                  ])
                    TextButton(
                      onPressed: () async {
                        final action = await showRequestPreview(
                          context,
                          request: entry.$2,
                          wholePage: false,
                        );
                        if (action == 'send') await controller.send(entry.$2);
                      },
                      child: Text(entry.$1),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('history'));
      await tester.pumpAndSettle();
      expect(find.textContaining('可预览的上一问'), findsOneWidget);
      expect(find.textContaining('可预览的上一答'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('overview'));
      await tester.pumpAndSettle();
      expect(find.text(overview.coverageNote!), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(sent, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  test('paper guide includes late limitations even with many introduction fragments', () {
    for (var i = 0; i < 12; i++) {
      store.saveEvidence(
        Evidence(
          id: 'intro-$i',
          documentId: document.id,
          documentHash: document.contentHash,
          page: 1,
          region: SourceRegion.fullPage,
          text: 'Introduction background fragment $i.',
        ),
      );
    }
    store.saveEvidence(
      Evidence(
        id: 'limits',
        documentId: document.id,
        documentHash: document.contentHash,
        page: 20,
        region: SourceRegion.fullPage,
        text: 'Limitations: small sample size.',
      ),
    );
    final request = controller.prepare(
      AiTask.paperGuide,
      '导读本文并说明局限',
      useRange: true,
    );
    expect(request.evidence.map((e) => e.page), [1, 20]);
    expect(request.evidence.last.text, contains('small sample'));
    expect(request.coverageNote, contains('局部导读'));
    expect(request.payloadJson, contains(request.coverageNote!));
  });

  test('long guide stays within budget and includes first and last pages of its range', () {
    for (var page = 1; page <= 20; page++) {
      store.saveEvidence(
        Evidence(
          id: 'long-$page',
          documentId: document.id,
          documentHash: document.contentHash,
          page: page,
          region: SourceRegion.fullPage,
          text: 'Start. ${'x' * 20000} Page $page end.',
        ),
      );
    }
    controller.beginSession(start: 3, end: 19, goal: '指定页段', minutes: 20);
    final request = controller.prepare(AiTask.paperGuide, '导读', useRange: true);
    expect(request.evidence.length, AiGateway.maxEvidenceCount);
    expect(
      request.contextCharacters,
      lessThanOrEqualTo(AiGateway.maxEvidenceCharacters),
    );
    expect(request.evidence.first.page, 3);
    expect(request.evidence.last.page, 19);
    expect(request.evidence.last.text, endsWith('Page 19 end.'));
    expect(request.coverageNote, contains('局部导读'));
  });

  test(
    'follow-up reads persisted, scoped history and freezes it in the payload',
    () async {
      await controller.send(controller.prepare(AiTask.explain, '第一问：解释动量'));
      controller.replies =
          []; // The widget's in-memory history is not authoritative.
      final request = controller.prepare(AiTask.explain, '刚才那点再解释简单些');
      expect(request.history.single.question, contains('第一问'));
      final content = jsonDecode(
        jsonDecode(request.payloadJson)['messages'][1]['content'] as String,
      );
      expect(content['conversation_history'][0]['answer'], '核验用的模拟回答。');
      store.setSetting('history:${document.id}', '[]');
      expect(request.history.single.question, contains('第一问'));
      expect(() => request.history.clear(), throwsUnsupportedError);
      await controller.send(request);
      expect(sent.last.body, request.payloadJson);
    },
  );

  test('history does not cross learning sessions or attach to search term translation', () async {
    controller.beginSession(start: 1, end: 2, goal: '旧小节', minutes: 20);
    await controller.send(controller.prepare(AiTask.explain, '旧小节的问题'));
    expect(controller.prepare(AiTask.searchTerms, '动量').history, isEmpty);
    controller.beginSession(start: 1, end: 2, goal: '新小节', minutes: 20);
    expect(controller.prepare(AiTask.explain, '再解释').history, isEmpty);
  });

  test('history stays bounded and legacy replies remain readable without being sent', () {
    final replies = List.generate(
      9,
      (i) => SavedReply(
        question: 'question $i',
        answer: 'a' * 1400,
        sources: [],
        model: 'fixture',
        tokens: 0,
        task: AiTask.explain.name,
        documentHash: document.contentHash,
      ),
    );
    replies.add(
      SavedReply(
        question: 'legacy private question',
        answer: 'legacy',
        sources: [],
        model: 'old',
        tokens: 0,
      ),
    );
    store.setSetting(
      'history:${document.id}',
      jsonEncode(replies.map((r) => r.toJson()).toList()),
    );
    final request = controller.prepare(AiTask.explain, '追问');
    expect(request.history.length, 5);
    expect(request.history.last.question, 'question 8');
    expect(request.payloadJson, isNot(contains('legacy private')));
    expect(
      SavedReply.fromJson({
        'question': 'old',
        'answer': 'old',
        'sources': [],
        'model': 'old',
        'tokens': 0,
        'insufficient': false,
        'createdAt': '2026-11-01T00:00:00',
      }).task,
      isNull,
    );
  });

  test('insufficient evidence never becomes an exercise', () async {
    insufficient = true;
    controller.beginSession(start: 1, end: 2, goal: '学习', minutes: 20);
    final before = controller.session;
    await controller.send(
      controller.prepare(AiTask.generateQuestion, '出题', useRange: true),
    );
    expect(controller.session, same(before));
    expect(store.getSessions(document.id).single.question, isEmpty);
    expect(controller.replies.single.insufficient, isTrue);
  });

  test('insufficient grading preserves the independent answer and ungraded attempt', () async {
    insufficient = true;
    controller.beginSession(start: 1, end: 2, goal: '学习', minutes: 20);
    controller.saveSession(controller.session!.copyWith(question: '动量是什么？'));
    controller.saveAnswer('质量乘速度');
    final before = controller.session;
    await controller.send(
      controller.prepare(AiTask.gradeAnswer, '评阅', useRange: true),
    );
    expect(controller.session, same(before));
    expect(controller.session!.stage, 'answered');
    expect(controller.session!.attempts.single.feedback, isEmpty);
  });

  test(
    'server rejection preserves learning state and does not save a fake reply',
    () async {
      status = 401;
      controller.beginSession(start: 1, end: 2, goal: '学习', minutes: 20);
      final before = controller.session;
      await controller.send(
        controller.prepare(AiTask.generateQuestion, '出题', useRange: true),
      );
      expect(controller.session, same(before));
      expect(controller.replies, isEmpty);
      expect(controller.error, contains('API Key'));
      expect(sent, hasLength(1));
    },
  );

  test('a request prepared for another session is rejected before any network call', () async {
    controller.beginSession(start: 1, end: 2, goal: '旧小节', minutes: 20);
    final request = controller.prepare(
      AiTask.generateQuestion,
      '出题',
      useRange: true,
    );
    controller.beginSession(start: 1, end: 2, goal: '新小节', minutes: 20);
    await controller.send(request);
    expect(sent, isEmpty);
    expect(controller.error, contains('重新预览'));
    expect(controller.session!.question, isEmpty);
  });

  test(
    'a source-free request is still bound to its original document',
    () async {
      final request = controller.prepare(AiTask.searchTerms, '动量');
      controller.current = document.copyWith(id: 'another-document');
      await controller.send(request);
      expect(sent, isEmpty);
      expect(controller.error, contains('重新预览'));
    },
  );

  test(
    'late question generation cannot overwrite a locally edited question',
    () async {
      started = Completer<void>();
      finish = Completer<void>();
      controller.beginSession(start: 1, end: 2, goal: '学习', minutes: 20);
      final request = controller.prepare(
        AiTask.generateQuestion,
        '出题',
        useRange: true,
      );
      final operation = controller.send(request);
      await started!.future;
      controller.saveSession(
        controller.session!.copyWith(question: '我刚刚自己写的问题'),
      );
      finish!.complete();
      await operation;
      expect(controller.session!.question, '我刚刚自己写的问题');
      expect(controller.replies.single.answer, '核验用的模拟回答。');
      expect(sent, hasLength(1));
    },
  );
}
