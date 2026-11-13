import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:local_study/app_controller.dart';
import 'package:local_study/core/local_store.dart';
import 'package:local_study/core/models.dart';
import 'package:local_study/features/library/library_controller.dart';
import 'package:local_study/features/library/models/library_models.dart';
import 'package:local_study/features/schedule/data/schedule_repository.dart';
import 'package:local_study/features/schedule/models/calendar_block.dart';
import 'package:local_study/features/schedule/models/daily_lesson.dart';
import 'package:local_study/features/schedule/models/local_date.dart';
import 'package:local_study/features/schedule/models/study_plan.dart';
import 'package:local_study/features/schedule/models/study_task.dart';
import 'package:local_study/services/ai_gateway.dart';
import 'package:local_study/services/document_service.dart';
import 'package:local_study/services/ocr_service.dart';
import 'package:local_study/ui/study_app.dart';

class _MemoryVault implements CredentialVault {
  final _values = <String, String>{};
  @override
  Future<void> delete(String accountId) async => _values.remove(accountId);
  @override
  Future<String?> read(String accountId) async => _values[accountId];
  @override
  Future<void> write(String accountId, String value) async =>
      _values[accountId] = value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LocalStore store;
  late StudyController controller;
  late Directory directory;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('local_study_ui_');
    store = LocalStore.inMemory();
    final ocr = OcrService();
    controller = StudyController(
      store: store,
      ocr: ocr,
      documents: DocumentService(directory, store, ocr),
      gateway: AiGateway(vault: _MemoryVault()),
    );
    await Future<void>.value();
  });

  tearDown(() async {
    await controller.shutdown();
    controller.dispose();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  Future<void> size(WidgetTester tester, Size value) async {
    tester.view.physicalSize = value;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets(
    'phone library, review and settings remain usable without a document or key',
    (tester) async {
      await size(tester, const Size(390, 844));
      await tester.pumpWidget(StudyApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.text('书库为空'), findsOneWidget);
      expect(find.text('选择文件'), findsOneWidget);
      expect(find.text('选择文件夹'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('复习'));
      await tester.pumpAndSettle();
      expect(find.textContaining('完成作答后会显示在这里'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byTooltip('设置（Ctrl+,）'));
      await tester.pumpAndSettle();
      expect(find.text('模型服务'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop library searches local documents and creates a folder tree',
    (tester) async {
      await size(tester, const Size(1440, 1000));
      store.upsertDocument(
        DocumentRecord(
          id: 'book',
          title: '热力学基础 · 界面样例',
          kind: DocumentKind.textbook,
          filePath: 'test-only.png',
          contentHash: 'bookhash',
          pageCount: 216,
          currentPage: 18,
        ),
      );
      store.upsertDocument(
        DocumentRecord(
          id: 'paper',
          title: 'Attention Is All You Need · 界面样例',
          kind: DocumentKind.paper,
          filePath: 'test-only.pdf',
          contentHash: 'paperhash',
          pageCount: 15,
          currentPage: 3,
        ),
      );
      await tester.pumpWidget(StudyApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.text('热力学基础 · 界面样例'), findsOneWidget);
      expect(find.text('Attention Is All You Need · 界面样例'), findsOneWidget);
      expect(find.text('全部资料'), findsWidgets);
      expect(find.byType(DropTarget), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, '搜索资料、标签或正文'),
        '热力学',
      );
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.text('热力学基础 · 界面样例'), findsOneWidget);
      expect(find.text('Attention Is All You Need · 界面样例'), findsNothing);

      await tester.tap(find.byTooltip('清除搜索'));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.text('Attention Is All You Need · 界面样例'), findsOneWidget);

      expect(find.text('新建第一个文件夹'), findsOneWidget);
      await tester.tap(find.text('新建第一个文件夹'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.byType(TextField),
        ),
        '大三上',
      );
      await tester.tap(find.text('新建'));
      await tester.pumpAndSettle();
      expect(find.text('大三上'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('existing folder tree renders and opens a folder view', (
    tester,
  ) async {
    await size(tester, const Size(1440, 1000));
    final library = LibraryController(
      store: store,
      documents: controller.documents,
    );
    final root = await library.createFolder(name: '大三上');
    final chemistry = await library.createFolder(
      name: '高分子化学',
      parentId: root!.id,
    );
    final materials = await library.createFolder(
      name: '教材',
      parentId: chemistry!.id,
    );
    await library.setFolderAppearance(
      chemistry.id,
      colorMode: FolderColorMode.custom,
      colorValue: 0xFF2563EB,
    );
    store.upsertDocument(
      DocumentRecord(
        id: 'tree-doc',
        title: '结构化学教材',
        kind: DocumentKind.unspecified,
        filePath: 'test-only.png',
        contentHash: 'tree-hash',
        pageCount: 3,
      ),
    );
    library.refresh();
    final primary = library.repository.primaryEntry('tree-doc')!;
    await library.moveNodes(
      entryIds: {primary.id},
      targetFolderId: materials!.id,
    );
    library.dispose();

    await tester.pumpWidget(StudyApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.text('大三上'), findsWidgets);
    expect(find.text('高分子化学'), findsWidgets);
    expect(find.text('教材'), findsWidgets);
    await tester.tap(find.text('大三上').first);
    await tester.pumpAndSettle();
    expect(find.text('全部资料'), findsWidgets);
    expect(find.text('高分子化学'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings exposes whole-library backup and restore entries', (
    tester,
  ) async {
    await size(tester, const Size(1440, 1000));
    await tester.pumpWidget(StudyApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('隐私与数据').first);
    await tester.pumpAndSettle();
    expect(find.text('整库备份'), findsOneWidget);
    expect(find.text('整库恢复'), findsOneWidget);
    expect(find.text('整库恢复'), findsOneWidget);
    expect(find.text('上次恢复结果'), findsOneWidget);
    expect(find.text('存储与原件修复'), findsOneWidget);
    expect(find.textContaining('API Key'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('saving a search as a smart folder keeps conditions, not copies', (
    tester,
  ) async {
    await size(tester, const Size(1440, 1000));
    store.upsertDocument(
      DocumentRecord(
        id: 'smart-a',
        title: '热力学资料',
        kind: DocumentKind.unspecified,
        filePath: 'test-only.png',
        contentHash: 'smart-a',
        pageCount: 3,
      ),
    );
    store.upsertDocument(
      DocumentRecord(
        id: 'smart-b',
        title: '无关资料',
        kind: DocumentKind.unspecified,
        filePath: 'test-only.png',
        contentHash: 'smart-b',
        pageCount: 3,
      ),
    );
    await tester.pumpWidget(StudyApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, '搜索资料、标签或正文'),
      '热力',
    );
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('保存为智能文件夹'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(TextField),
      ),
      '热力资料',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('热力资料'), findsWidgets);
    expect(find.textContaining('智能文件夹 · 热力资料'), findsOneWidget);
    expect(find.text('无关资料'), findsNothing);

    await tester.tap(find.text('全部资料').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('清除搜索'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(find.text('无关资料'), findsOneWidget);
    expect(find.text('热力资料'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone long press enters multi-select without opening a document', (
    tester,
  ) async {
    await size(tester, const Size(390, 844));
    store.upsertDocument(
      DocumentRecord(
        id: 'touch-a',
        title: '触摸资料甲',
        kind: DocumentKind.unspecified,
        filePath: 'test-only.png',
        contentHash: 'touch-a',
        pageCount: 2,
      ),
    );
    store.upsertDocument(
      DocumentRecord(
        id: 'touch-b',
        title: '触摸资料乙',
        kind: DocumentKind.unspecified,
        filePath: 'test-only.png',
        contentHash: 'touch-b',
        pageCount: 2,
      ),
    );
    await tester.pumpWidget(StudyApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('触摸资料甲'));
    await tester.pumpAndSettle();
    expect(find.text('已选择 1 项'), findsOneWidget);
    expect(controller.current, isNull, reason: 'long press must not open the reader');
    await tester.longPress(find.text('触摸资料乙'));
    await tester.pumpAndSettle();
    expect(find.text('已选择 2 项'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone library opens the folder tree in a drawer', (tester) async {
    await size(tester, const Size(390, 844));
    store.upsertDocument(
      DocumentRecord(
        id: 'phone-doc',
        title: '手机上的资料',
        kind: DocumentKind.unspecified,
        filePath: 'test-only.png',
        contentHash: 'phone-hash',
        pageCount: 2,
      ),
    );
    await tester.pumpWidget(StudyApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.text('手机上的资料'), findsOneWidget);
    await tester.tap(find.byTooltip('文件夹'));
    await tester.pumpAndSettle();
    expect(find.text('新建第一个文件夹'), findsOneWidget);
    expect(find.text('回收站'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'library item menu moves a document to the trash and restores it',
    (tester) async {
      await size(tester, const Size(1440, 1000));
      store.upsertDocument(
        DocumentRecord(
          id: 'trash-me',
          title: '可恢复的资料',
          kind: DocumentKind.unspecified,
          filePath: 'test-only.png',
          contentHash: 'trash-hash',
          pageCount: 4,
          currentPage: 1,
        ),
      );
      await tester.pumpWidget(StudyApp(controller: controller));
      await tester.pumpAndSettle();
      expect(find.text('可恢复的资料'), findsOneWidget);

      await tester.tap(find.byTooltip('资料操作').first);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.text('阅读'), findsOneWidget);
      await tester.tap(find.text('移入回收站'));
      await tester.pumpAndSettle();
      expect(find.text('移入回收站？'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '移入回收站'));
      await tester.pumpAndSettle();
      expect(find.text('可恢复的资料'), findsNothing);

      await tester.tap(find.text('回收站').first);
      await tester.pumpAndSettle();
      expect(find.text('可恢复的资料'), findsOneWidget);
      await tester.tap(find.text('恢复').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部资料').first);
      await tester.pumpAndSettle();
      expect(find.text('可恢复的资料'), findsOneWidget);
      expect(controller.store.getDocuments(), hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('export real Flutter widget preview on Windows', (tester) async {
    if (!Platform.isWindows) return;
    final font = File(r'C:\Windows\Fonts\msyh.ttc');
    if (font.existsSync()) {
      final loader = FontLoader('Roboto')
        ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
      await loader.load();
    }
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    await size(tester, const Size(1440, 1000));
    store.upsertDocument(
      DocumentRecord(
        id: 'sample-book',
        title: '热力学基础 · 界面样例',
        kind: DocumentKind.textbook,
        filePath: 'test-only.png',
        contentHash: 'sample-book',
        pageCount: 216,
        currentPage: 18,
      ),
    );
    store.upsertDocument(
      DocumentRecord(
        id: 'sample-paper',
        title: 'Attention Is All You Need · 界面样例',
        kind: DocumentKind.paper,
        filePath: 'test-only.pdf',
        contentHash: 'sample-paper',
        pageCount: 15,
        currentPage: 3,
      ),
    );
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: StudyApp(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final output = File('build/preview/library-desktop.png');
      await output.parent.create(recursive: true);
      await output.writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
  });

  testWidgets('review page opens a lesson marked for review', (tester) async {
    await size(tester, const Size(1440, 1000));
    final today = LocalDate.today();
    final repository = ScheduleRepository(store);
    final plan = repository.savePlan(
      StudyPlan(
        id: 'plan',
        title: '复习计划',
        startDate: today,
        endDate: today.addDays(10),
      ),
    );
    final task = repository.saveTask(
      StudyTask(id: 'task', title: '二次函数复习', planId: plan.id, minutes: 45),
    );
    final lesson = repository.saveLesson(
      DailyLesson(
        id: 'lesson',
        taskId: task.id,
        planId: plan.id,
        title: '二次函数课程',
        objective: '能判断顶点。',
        sections: const [LessonSection(title: '讲解', body: '内容')],
        exercises: const [
          LessonExercise(
            id: 'e1',
            prompt: '顶点是什么？',
            answer: '(1,2)',
            solution: '配方。',
          ),
        ],
      ),
    );
    final block = repository.createManual(
      task: task,
      block: CalendarBlock(
        id: 'block',
        date: today,
        startMinute: 19 * 60,
        endMinute: 19 * 60 + 45,
        taskId: task.id,
        planId: plan.id,
      ),
    ).block;
    repository.saveLessonAttemptRecord(
      lessonId: lesson.id,
      taskId: task.id,
      exerciseId: 'e1',
      answer: '我的答案',
      correct: false,
      minutes: 20,
      blockId: block.id,
      operationId: 'review-1',
    );

    await tester.pumpWidget(StudyApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复习'));
    await tester.pumpAndSettle();
    expect(find.text('课程自评待复习'), findsOneWidget);
    expect(find.text('顶点是什么？'), findsOneWidget);
    await tester.tap(find.text('回到课程'));
    await tester.pumpAndSettle();
    expect(find.text('今日课程'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('library selection bar floats at bottom without shifting items', (
    tester,
  ) async {
    await size(tester, const Size(1280, 800));
    store.upsertDocument(
      DocumentRecord(
        id: 'select-doc',
        title: '稳定列表资料',
        kind: DocumentKind.unspecified,
        filePath: 'test-only.png',
        contentHash: 'select-hash',
        pageCount: 3,
      ),
    );
    await tester.pumpWidget(StudyApp(controller: controller));
    await tester.pumpAndSettle();

    final docText = find.text('稳定列表资料').first;
    final itemBefore = tester.getTopLeft(docText);
    await tester.longPress(docText);
    await tester.pumpAndSettle();

    final bar = find.byKey(const ValueKey('library-selection-bar'));
    expect(bar, findsOneWidget);
    expect(find.text('已选择 1 项'), findsOneWidget);
    final itemAfter = tester.getTopLeft(docText);
    expect(itemAfter.dy, itemBefore.dy);
    expect(tester.getTopLeft(bar).dy, greaterThan(itemAfter.dy));
    expect(tester.takeException(), isNull);
  });
}
