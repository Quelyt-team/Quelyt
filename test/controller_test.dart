import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:local_study/app_controller.dart';
import 'package:local_study/core/local_store.dart';
import 'package:local_study/core/models.dart';
import 'package:local_study/services/ai_gateway.dart';
import 'package:local_study/services/document_service.dart';
import 'package:local_study/services/ocr_service.dart';

class _Vault implements CredentialVault {
  final values = <String, String>{};
  @override
  Future<void> delete(String id) async {
    values.remove(id);
  }

  @override
  Future<String?> read(String id) async => values[id];
  @override
  Future<void> write(String id, String value) async {
    values[id] = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late LocalStore store;
  late StudyController controller;
  late DocumentRecord doc;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('local_study_controller_');
    store = LocalStore.inMemory();
    final gateway = AiGateway(
      vault: _Vault(),
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': jsonEncode({
                    'answer': '这是有出处的反馈。',
                    'citations': ['e1'],
                    'insufficientEvidence': false,
                  }),
                },
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
    final ocr = OcrService();
    controller = StudyController(
      store: store,
      ocr: ocr,
      gateway: gateway,
      documents: DocumentService(directory, store, ocr),
    );
    doc = DocumentRecord(
      id: 'book',
      title: 'book',
      kind: DocumentKind.textbook,
      filePath: 'test-only',
      contentHash: 'hash',
      pageCount: 4,
    );
    store.importDocument(
      doc,
      List.generate(
        doc.pageCount,
        (index) => PageRecord(documentId: doc.id, page: index + 1),
      ),
    );
    controller.current = doc;
    store.saveEvidence(
      const Evidence(
        id: 'e1',
        documentId: 'book',
        documentHash: 'hash',
        page: 1,
        region: SourceRegion(.1, .2, .9, .4),
        text: '原文：动量等于质量乘以速度。',
      ),
    );
    await gateway.saveKey(controller.settings, 'test-key-not-real');
  });
  tearDown(() async {
    await controller.shutdown();
    controller.dispose();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('offline answers are retained before AI grading and grading updates that attempt', () async {
    controller.beginSession(start: 1, end: 2, goal: '解释动量', minutes: 20);
    controller.saveSession(controller.session!.copyWith(question: '动量是什么？'));
    controller.saveAnswer('质量乘以速度');
    expect(controller.session!.attempts, hasLength(1));
    expect(controller.session!.attempts.first.feedback, isEmpty);
    final request = controller.prepare(
      AiTask.gradeAnswer,
      '评阅：动量是什么？',
      useRange: true,
    );
    await controller.send(request);
    expect(controller.error, isNull);
    expect(controller.session!.attempts, hasLength(1));
    expect(controller.session!.attempts.first.feedback, isNotEmpty);
    expect(controller.replies.first.tokens, 0);
    controller.saveSession(
      controller.session!.copyWith(answer: '', stage: 'question'),
    );
    controller.saveAnswer('新的独立作答');
    expect(controller.session!.attempts, hasLength(2));
    expect(controller.session!.feedback, isEmpty);
  });

  test(
    'reply citations preserve reviewed text when the background index changes',
    () async {
      final request = controller.prepare(AiTask.explain, '动量');
      store.saveEvidence(
        store.getEvidence(doc.id).first.copyWith(text: '更正后的新版本文字'),
      );
      await controller.send(request);
      expect(controller.replies.single.sources.single.text, '原文：动量等于质量乘以速度。');
      expect(store.getEvidence(doc.id).single.text, '更正后的新版本文字');
      expect(store.getSetting('history:${doc.id}'), contains('原文：动量等于质量乘以速度。'));
    },
  );

  test('chapter evidence never includes a page outside the selected range', () {
    store.saveEvidence(
      const Evidence(
        id: 'e4',
        documentId: 'book',
        documentHash: 'hash',
        page: 4,
        region: SourceRegion.fullPage,
        text: '动量：范围外的证据',
      ),
    );
    controller.beginSession(start: 1, end: 2, goal: '学习', minutes: 20);
    final request = controller.prepare(AiTask.studyPlan, '动量', useRange: true);
    expect(request.evidence.map((e) => e.id), contains('e1'));
    expect(request.evidence.map((e) => e.id), isNot(contains('e4')));
  });

  test(
    'a stale document hash cannot navigate or submit another document sources',
    () async {
      final source = store
          .getEvidence(doc.id)
          .first
          .copyWith(documentHash: 'old-hash');
      await controller.jumpToEvidence(source);
      expect(controller.error, contains('版本'));
      expect(controller.page, 1);
    },
  );
}
