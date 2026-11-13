import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:local_study/app_controller.dart';
import 'package:local_study/core/models.dart';
import 'package:local_study/features/book_qa/book_qa_controller.dart';
import 'package:local_study/features/book_qa/models/book_qa_models.dart';
import 'package:local_study/features/book_qa/ui/book_qa_panel.dart';
import 'package:local_study/services/ai_gateway.dart';
import 'package:local_study/services/document_service.dart';
import 'package:local_study/services/ocr_service.dart';
import 'package:local_study/ui/theme/app_theme.dart';

import 'book_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late BookFixture fixture;
  late Directory directory;
  late StudyController study;
  late BookQaController qa;
  late List<Evidence> jumps;

  setUp(() async {
    fixture = BookFixture.create();
    directory = Directory.systemTemp.createTempSync('book-qa-ui-');
    final ocr = OcrService();
    study = StudyController(
      store: fixture.store,
      ocr: ocr,
      gateway: AiGateway(
        vault: fixture.vault,
        client: MockClient((_) async => http.Response('{}', 500)),
      ),
      documents: DocumentService(directory, fixture.store, ocr),
    );
    study.current = fixture.document;
    study.settings = fixture.settings;
    jumps = [];
    qa = BookQaController(study: study);
    addTearDown(() async {
      qa.dispose();
      study.dispose();
      await study.shutdown();
      fixture.server.requests.clear();
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
  });

  Widget panel({double width = 420, double height = 900}) => MaterialApp(
    theme: lightTheme,
    home: Scaffold(
      body: SizedBox(
        width: width,
        height: height,
        child: BookQaPanel(
          controller: qa,
          study: study,
          onJump: (evidence) async => jumps.add(evidence),
        ),
      ),
    ),
  );

  testWidgets(
    'shows whole-book modes and an honest empty understanding state',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      study.selection = const SourceRegion(.1, .1, .5, .5);
      qa.attach(fixture.document);
      await tester.pumpWidget(panel());
      await tester.pumpAndSettle();

      expect(find.text('教材问答'), findsOneWidget);
      expect(find.text('全书＋联网'), findsOneWidget);
      expect(find.text('仅依据教材'), findsOneWidget);
      expect(find.text('只看当前页'), findsOneWidget);
      expect(find.text('待整理'), findsOneWidget);
      expect(find.text('还没有教材问答'), findsOneWidget);
      expect(find.text('建立理解'), findsOneWidget);
      expect(find.byTooltip('问这张图'), findsOneWidget);
    },
  );

  testWidgets(
    'a narrow panel keeps every control reachable without overflowing',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      qa.attach(fixture.document);
      await tester.pumpWidget(panel(width: 320, height: 800));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('教材问答'), findsOneWidget);
      expect(find.text('全书＋联网'), findsOneWidget);
    },
  );

  testWidgets(
    'renders separated book and web sources and opens a page citation',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final conversation = fixture.repository.ensureConversation(
        fixture.document,
      );
      final evidence = Evidence(
        id: 'book-1:7:t0',
        documentId: fixture.document.id,
        documentHash: fixture.document.contentHash,
        page: 7,
        region: const SourceRegion(.08, .1, .95, .92),
        text: '在常见乙烯基单体的自由基聚合中，聚合物多以头尾键连为主。',
      );
      final turn = fixture.repository.appendQuestion(
        conversation,
        '为什么聚合物多以头尾键连为主？',
        BookAskMode.wholeBookWeb,
      );
      fixture.repository.saveAnswer(
        conversation,
        turn,
        BookQaAnswer(
          answerStatus: AnswerStatus.answered,
          blocks: [
            BookAnswerBlock(
              text: '教材给出了结论，原因需要结合机理补充。',
              bookCitationIds: const ['B1'],
              webCitationIds: const ['W1'],
            ),
            BookAnswerBlock(
              text: '外部资料从过渡态稳定和位阻两方面解释。',
              webCitationIds: const ['W1'],
              supplemental: true,
            ),
          ],
          coverage: const BookCoverage(
            scope: '整本教材 12/12 页可用文字',
            wholeBookSearched: true,
            understandingComplete: false,
            parsedPages: 12,
            totalPages: 12,
            hitChapters: ['第二章 链结构'],
          ),
          webStatus: WebLookupStatus.searched,
          bookSources: [
            BookCitation(id: 'B1', evidence: evidence, chapterTitle: '第二章 链结构'),
          ],
          webSources: [
            WebCitation(
              id: 'W1',
              title: 'Addition polymerisation',
              url: 'https://chemistry.example.edu/addition',
              excerpt: 'Head-to-tail addition is favoured.',
              fetchedAt: DateTime(2026, 1, 2),
              siteName: 'Example University',
              publishedAt: '2026-01-02T00:00:00Z',
              fullText: true,
              searchQuery: '头尾键连 原因 机理',
            ),
          ],
          usage: const BookQaUsage(searchRequests: 2, fetchRequests: 1),
          model: 'deepseek-flash',
          provider: 'DeepSeek',
          requestId: 'r1',
          webNote: '搜索 2 次；读取 1 个网页',
          searchQueries: const ['头尾键连 原因 机理'],
        ),
      );
      qa.attach(fixture.document);
      await tester.pumpWidget(panel());
      await tester.pumpAndSettle();

      expect(find.textContaining('教材给出了结论'), findsOneWidget);
      expect(find.textContaining('外部资料从过渡态稳定'), findsOneWidget);
      expect(find.text('解释与补充'), findsOneWidget);
      expect(find.text('教材出处'), findsOneWidget);
      expect(find.text('网络参考 · 1'), findsOneWidget);
      expect(find.textContaining('第 7 页'), findsWidgets);
      expect(find.text('已联网检索'), findsOneWidget);

      await tester.ensureVisible(find.text('网络参考 · 1'));
      await tester.tap(find.text('网络参考 · 1'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('https://chemistry.example.edu/addition'),
        findsWidgets,
      );

      final citation = tester.widget<ActionChip>(
        find.widgetWithText(ActionChip, '第 7 页').first,
      );
      citation.onPressed!();
      await tester.pump();
      expect(jumps.single.page, 7);
    },
  );
}
