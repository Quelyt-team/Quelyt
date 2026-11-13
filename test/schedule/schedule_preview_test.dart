import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:local_study/app_controller.dart';
import 'package:local_study/core/local_store.dart';
import 'package:local_study/core/models.dart';
import 'package:local_study/features/schedule/data/schedule_repository.dart';
import 'package:local_study/features/schedule/models/calendar_block.dart';
import 'package:local_study/features/schedule/models/knowledge_item.dart';
import 'package:local_study/features/schedule/models/learning_record.dart';
import 'package:local_study/features/schedule/models/local_date.dart';
import 'package:local_study/features/schedule/models/plan_availability.dart';
import 'package:local_study/features/schedule/models/plan_source.dart';
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
  late Directory directory;
  late LocalStore store;
  late StudyController controller;
  late ScheduleRepository repository;
  var previewKey = GlobalKey();

  setUpAll(() async {
    if (Platform.isWindows) {
      final fontFile = File(r'C:\Windows\Fonts\msyh.ttc');
      if (fontFile.existsSync()) {
        final bytes = ByteData.sublistView(fontFile.readAsBytesSync());
        for (final family in const [
          'Roboto',
          'Segoe UI',
          'Microsoft YaHei UI',
        ]) {
          final loader = FontLoader(family)
            ..addFont(Future<ByteData>.value(bytes));
          await loader.load();
        }
      }
      final manrope = File('assets/brand/Manrope.ttf');
      if (manrope.existsSync()) {
        final loader = FontLoader('Manrope')
          ..addFont(
            Future<ByteData>.value(
              ByteData.sublistView(manrope.readAsBytesSync()),
            ),
          );
        await loader.load();
      }
    }
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  setUp(() {
    directory = Directory.systemTemp.createTempSync('schedule-preview-');
    store = LocalStore.inMemory();
    repository = ScheduleRepository(store);
    final ocr = OcrService();
    controller = StudyController(
      store: store,
      ocr: ocr,
      documents: DocumentService(directory, store, ocr),
      gateway: AiGateway(vault: _MemoryVault()),
    );
    _seed(repository);
  });

  tearDown(() async {
    await controller.shutdown();
    controller.dispose();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    previewKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: previewKey,
        child: StudyApp(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('日程').first);
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    final boundary =
        previewKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final output = File('build/preview/schedule/$name.png');
      await output.parent.create(recursive: true);
      await output.writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
    expect(tester.takeException(), isNull);
  }

  testWidgets('schedule preview: desktop and phone', (tester) async {
    await pump(tester, const Size(1440, 900));
    await capture(tester, '01-schedule-desktop');

    await tester.tap(find.byKey(const ValueKey('month-picker')));
    await tester.pumpAndSettle();
    await capture(tester, '09-month-picker-desktop');
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('收起日详情'));
    await tester.pumpAndSettle();
    await capture(tester, '10-day-panel-collapsed');
    final first = LocalDate(
      LocalDate.today().year,
      LocalDate.today().month,
      1,
    );
    await tester.tap(find.byKey(ValueKey('schedule-day-${first.iso}')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('schedule-day-${LocalDate.today().iso}')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('日程操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('管理计划').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('材料').first);
    await tester.pumpAndSettle();
    await capture(tester, '11-plan-materials-desktop');
    await tester.tap(find.text('完成').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('知识点').first);
    await tester.pumpAndSettle();
    await capture(tester, '12-plan-knowledge-desktop');
    await tester.tap(find.text('完成').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('日程操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('可用时间').last);
    await tester.pumpAndSettle();
    await capture(tester, '02-availability-desktop');
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('日程操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('自动排期').last);
    await tester.pumpAndSettle();
    await capture(tester, '03-draft-desktop');
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('schedule-add')));
    await tester.pumpAndSettle();
    await capture(tester, '04-task-editor-desktop');
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('planning-bar')));
    await tester.pumpAndSettle();
    await capture(tester, '07-planning-sheet-desktop');
    await tester.tap(find.byTooltip('关闭排期对话'));
    await tester.pumpAndSettle();

    await pump(tester, const Size(390, 844));
    await capture(tester, '05-schedule-phone');

    await tester.tap(find.byKey(const ValueKey('schedule-add')));
    await tester.pumpAndSettle();
    await capture(tester, '06-task-editor-phone');
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('planning-bar')));
    await tester.pumpAndSettle();
    await capture(tester, '08-planning-sheet-phone');
    await tester.tap(find.byTooltip('关闭排期对话'));
    await tester.pumpAndSettle();
  });
}

void _seed(ScheduleRepository repository) {
  final today = LocalDate.today();
  final plan = repository.savePlan(
    StudyPlan(
      id: 'plan',
      title: '期中数学备考',
      subject: '数学',
      startDate: today.addDays(-2),
      endDate: today.addDays(20),
      examDate: today.addDays(22),
      goal: '覆盖二次函数、判别式与错题订正。',
    ),
  );
  repository.saveAvailability(
    PlanAvailability(
      planId: plan.id,
      weekly: [
        for (var weekday = 1; weekday <= 5; weekday++)
          WeeklySlot(
            weekday: weekday,
            startMinute: 19 * 60 + 30,
            endMinute: 21 * 60,
          ),
      ],
      dailyCapMinutes: 120,
      bufferPercent: 15,
      maxStudyDaysPerWeek: 5,
      breakMinutes: 5,
      unitMinutes: 25,
    ),
  );
  repository.store.importDocument(
    DocumentRecord(
      id: 'book',
      title: '人教版数学 · 九年级上册',
      kind: DocumentKind.textbook,
      filePath: '/managed/book.pdf',
      contentHash: 'hash-book',
      pageCount: 12,
    ),
    [
      for (var page = 1; page <= 12; page++)
        PageRecord(
          documentId: 'book',
          page: page,
          text: page <= 8 ? '第 $page 页：二次函数教材内容。' : '',
          status: page <= 8
              ? PageStatus.ready
              : page == 9
              ? PageStatus.needsOcr
              : PageStatus.pending,
        ),
    ],
  );
  repository.savePlanSource(
    PlanSource(
      id: 'source-1',
      planId: plan.id,
      documentId: 'book',
      documentHash: 'hash-book',
      documentTitle: '人教版数学 · 九年级上册',
      purpose: MaterialPurpose.textbook,
      startPage: 1,
      endPage: 12,
      chapter: '第二十二章 二次函数',
    ),
  );
  repository.saveKnowledgeItems([
    KnowledgeItem(
      id: 'knowledge-1',
      planId: plan.id,
      title: '二次函数的图像与顶点',
      objective: '能从一般式判断开口方向，并求出顶点与对称轴。',
      sourceId: 'source-1',
      documentId: 'book',
      documentHash: 'hash-book',
      documentTitle: '人教版数学 · 九年级上册',
      startPage: 2,
      endPage: 4,
      priority: 2,
      minutes: 45,
      completionCondition: '独立完成 3 道顶点与对称轴的变式题。',
      generatedByAi: true,
    ),
    KnowledgeItem(
      id: 'knowledge-2',
      planId: plan.id,
      title: '判别式与根的关系',
      objective: '能根据判别式判断方程根的情况。',
      sourceId: 'source-1',
      documentId: 'book',
      documentHash: 'hash-book',
      documentTitle: '人教版数学 · 九年级上册',
      startPage: 5,
      endPage: 7,
      prerequisiteIds: const ['knowledge-1'],
      priority: 1,
      minutes: 40,
      completionCondition: '能解释判别式三种取值对应的图像关系。',
      generatedByAi: true,
    ),
  ]);
  final study = repository.createManual(
    task: StudyTask(
      id: 'task-1',
      title: '二次函数：顶点式与对称轴',
      subject: '数学',
      planId: plan.id,
      activity: TaskActivity.learn,
      minutes: 45,
      priority: 2,
      completionCondition: '能不用配方直接说出顶点与对称轴，并完成 3 道变式。',
      knowledge: '二次函数图像',
    ),
    block: CalendarBlock(
      id: 'block-1',
      date: today,
      startMinute: 19 * 60 + 30,
      endMinute: 20 * 60 + 15,
      locked: true,
    ),
  );
  repository.markBlock(
    block: study.block,
    fact: LearningFact.partial,
    completedMinutes: 20,
    note: '说明会了，变式还差一道',
  );
  repository.createManual(
    task: StudyTask(
      id: 'task-2',
      title: '判别式错题订正',
      subject: '数学',
      planId: plan.id,
      activity: TaskActivity.correct,
      minutes: 30,
      minChunkMinutes: 15,
      completionCondition: '每道错题写出错因，并回到原题重做。',
    ),
    block: CalendarBlock(
      id: 'block-2',
      date: today,
      startMinute: 20 * 60 + 30,
      endMinute: 21 * 60,
      locked: true,
    ),
  );
  repository.createBusy(
    template: CalendarBlock(
      id: 'busy-1',
      title: '英语网课',
      date: today,
      startMinute: 18 * 60,
      endMinute: 19 * 60,
      kind: BlockKind.busy,
    ),
  );
  repository.saveTask(
    StudyTask(
      id: 'task-3',
      title: '二次函数综合练习',
      subject: '数学',
      planId: plan.id,
      activity: TaskActivity.practice,
      minutes: 60,
      priority: 1,
      completionCondition: '限时完成 8 题，记录错因。',
    ),
  );
  repository.saveTask(
    StudyTask(
      id: 'task-4',
      title: '考前回顾：三种表示法',
      subject: '数学',
      planId: plan.id,
      activity: TaskActivity.review,
      minutes: 45,
      priority: 2,
    ),
  );
}
