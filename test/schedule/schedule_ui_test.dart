import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:local_study/app_controller.dart';
import 'package:local_study/core/local_store.dart';
import 'package:local_study/core/models.dart';
import 'package:local_study/features/schedule/data/schedule_repository.dart';
import 'package:local_study/features/schedule/models/calendar_block.dart';
import 'package:local_study/features/schedule/models/daily_lesson.dart';
import 'package:local_study/features/schedule/models/local_date.dart';
import 'package:local_study/features/schedule/models/material_ref.dart';
import 'package:local_study/features/schedule/models/plan_availability.dart';
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

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('schedule-ui-');
    store = LocalStore.inMemory();
    repository = ScheduleRepository(store);
    final ocr = OcrService();
    controller = StudyController(
      store: store,
      ocr: ocr,
      documents: DocumentService(directory, store, ocr),
      gateway: AiGateway(vault: _MemoryVault()),
    );
  });

  tearDown(() async {
    await controller.shutdown();
    controller.dispose();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  Future<void> pumpApp(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(StudyApp(controller: controller));
    await tester.pumpAndSettle();
  }

  Future<void> openSchedule(WidgetTester tester, {bool mobile = false}) async {
    await tester.tap(find.text('日程').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('schedule-page')), findsOneWidget);
    if (!mobile) {
      expect(find.text('全部计划'), findsOneWidget);
    }
  }

  testWidgets('desktop schedule creates a task, persists it across navigation, '
      'and blocks a conflicting time', (tester) async {
    await pumpApp(tester, const Size(1440, 1000));
    await openSchedule(tester);

    await tester.tap(find.byKey(const ValueKey('schedule-add')));
    await tester.pumpAndSettle();
    expect(find.text('新增安排'), findsWidgets);
    await tester.enterText(
      find.byKey(const ValueKey('schedule-task-title')),
      '二次函数练习',
    );
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();
    expect(find.text('二次函数练习'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('复习').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('日程').first);
    await tester.pumpAndSettle();
    expect(find.text('二次函数练习'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('schedule-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('schedule-task-title')),
      '英语听力',
    );
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('时间冲突'), findsOneWidget);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('new task editor starts with basic fields and expands details', (
    tester,
  ) async {
    await pumpApp(tester, const Size(1440, 1000));
    await openSchedule(tester);
    await tester.tap(find.byKey(const ValueKey('schedule-add')));
    await tester.pumpAndSettle();
    expect(find.text('展开学习内容、重复与更多设置'), findsOneWidget);
    expect(find.text('每周重复'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('task-editor-more')));
    await tester.pumpAndSettle();
    expect(find.text('每周重复'), findsOneWidget);
    expect(find.text('收起学习内容与更多设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('repeat control expands a weekly task', (tester) async {
    await pumpApp(tester, const Size(1440, 1000));
    await openSchedule(tester);
    await tester.tap(find.byKey(const ValueKey('schedule-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('schedule-task-title')),
      '每周复习',
    );
    await tester.tap(find.byKey(const ValueKey('task-editor-more')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('每周重复'));
    await tester.tap(find.text('每周重复'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();
    final blocks = repository.getBlocks();
    expect(blocks.length, greaterThan(1));
    expect(blocks.map((block) => block.seriesId).toSet(), hasLength(1));
    expect(blocks.every((block) => block.seriesId != null), isTrue);
  });

  testWidgets('plan manager and availability dialogs render', (tester) async {
    final today = LocalDate.today();
    repository.savePlan(
      StudyPlan(
        id: 'plan',
        title: '期中数学',
        subject: '数学',
        startDate: today,
        endDate: today.addDays(10),
        examDate: today.addDays(12),
      ),
    );
    await pumpApp(tester, const Size(1440, 1000));
    await openSchedule(tester);

    await tester.tap(find.byTooltip('日程操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('管理计划').last);
    await tester.pumpAndSettle();
    expect(find.text('学习计划'), findsOneWidget);
    expect(find.text('新建计划'), findsOneWidget);
    await tester.tap(find.text('完成').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('日程操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('可用时间').last);
    await tester.pumpAndSettle();
    expect(find.text('保存可用时间'), findsOneWidget);
    expect(find.text('默认建议，尚未生效'), findsOneWidget);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('这一天'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设为休息日'));
    await tester.pumpAndSettle();
    expect(find.textContaining('这个日期在所选计划中被标记为休息'), findsOneWidget);

    await tester.tap(find.byTooltip('这一天'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复每周安排'));
    await tester.pumpAndSettle();
    expect(find.textContaining('这个日期在所选计划中被标记为休息'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('auto schedule preview applies to the calendar and can be undone', (
    tester,
  ) async {
    final today = LocalDate.today();
    repository.savePlan(
      StudyPlan(
        id: 'plan',
        title: '期中数学',
        subject: '数学',
        startDate: today,
        endDate: today.addDays(10),
        examDate: today.addDays(12),
      ),
    );
    repository.saveAvailability(
      PlanAvailability(
        planId: 'plan',
        weekly: [
          for (var weekday = 1; weekday <= 7; weekday++)
            WeeklySlot(
              weekday: weekday,
              startMinute: 19 * 60 + 30,
              endMinute: 21 * 60,
            ),
        ],
        dailyCapMinutes: 120,
        bufferPercent: 0,
        maxStudyDaysPerWeek: 7,
        breakMinutes: 0,
        unitMinutes: 45,
      ),
    );
    repository.saveTask(
      StudyTask(
        id: 'task',
        title: '二次函数练习',
        planId: 'plan',
        minutes: 45,
        minChunkMinutes: 15,
      ),
    );

    await pumpApp(tester, const Size(1440, 1000));
    await openSchedule(tester);

    await tester.tap(find.byTooltip('日程操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('自动排期').last);
    await tester.pumpAndSettle();
    expect(find.text('排期草案'), findsOneWidget);
    await tester.tap(find.text('应用计划'));
    await tester.pumpAndSettle();
    expect(repository.getBlocks(planId: 'plan'), hasLength(1));
    expect(find.text('二次函数练习'), findsOneWidget);

    await tester.tap(find.byTooltip('日程操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('撤销上次排期').last);
    await tester.pumpAndSettle();
    expect(repository.getBlocks(planId: 'plan'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone bottom navigation opens a usable schedule', (tester) async {
    await pumpApp(tester, const Size(390, 844));
    await openSchedule(tester, mobile: true);
    expect(find.text('新增'), findsNothing);
    expect(find.byKey(const ValueKey('schedule-add')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('schedule-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('schedule-task-title')),
      '手机端任务',
    );
    await tester.tap(find.text('保存').last);
    await tester.pumpAndSettle();
    expect(repository.getBlocks(), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('month navigation settles with the calendar transition', (
    tester,
  ) async {
    await pumpApp(tester, const Size(1440, 1000));
    await openSchedule(tester);
    final next = LocalDate(
      LocalDate.today().year,
      LocalDate.today().month,
      1,
    ).addDays(32).firstOfMonth;
    await tester.tap(find.byTooltip('下个月'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text(next.monthLabel), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('上个月'));
    await tester.pumpAndSettle();
    expect(find.text(LocalDate.today().firstOfMonth.monthLabel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('plan materials bind a document page range', (tester) async {
    final today = LocalDate.today();
    repository.savePlan(
      StudyPlan(
        id: 'plan',
        title: '期中数学',
        subject: '数学',
        startDate: today,
        endDate: today.addDays(20),
        examDate: today.addDays(22),
      ),
    );
    controller.store.importDocument(
      DocumentRecord(
        id: 'book',
        title: '数学教材',
        kind: DocumentKind.textbook,
        filePath: '/managed/book.pdf',
        contentHash: 'hash-book',
        pageCount: 4,
      ),
      [
        for (var page = 1; page <= 4; page++)
          PageRecord(
            documentId: 'book',
            page: page,
            text: '第 $page 页',
            status: PageStatus.ready,
          ),
      ],
    );
    await pumpApp(tester, const Size(1440, 1000));
    await openSchedule(tester);

    await tester.tap(find.byTooltip('日程操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('管理计划').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('材料').first);
    await tester.pumpAndSettle();
    expect(find.text('教材与材料'), findsOneWidget);

    await tester.tap(find.text('添加材料').first);
    await tester.pumpAndSettle();
    expect(find.text('添加材料'), findsWidgets);
    await tester.tap(find.text('绑定'));
    await tester.pumpAndSettle();
    expect(find.text('数学教材'), findsWidgets);
    expect(find.text('已就绪'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('manual knowledge item creates a pending task', (tester) async {
    final today = LocalDate.today();
    repository.savePlan(
      StudyPlan(
        id: 'plan',
        title: '期中数学',
        subject: '数学',
        startDate: today,
        endDate: today.addDays(20),
        examDate: today.addDays(22),
      ),
    );
    await pumpApp(tester, const Size(1440, 1000));
    await openSchedule(tester);

    await tester.tap(find.byTooltip('日程操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('管理计划').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('知识点').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('手动添加'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('knowledge-title')),
      '二次函数图像',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('二次函数图像'), findsOneWidget);
    expect(find.text('无材料来源'), findsOneWidget);

    await tester.tap(find.text('加入待安排任务'));
    await tester.pumpAndSettle();
    expect(find.text('已在待安排任务'), findsOneWidget);
    expect(repository.getTasks(planId: 'plan'), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('task card starts a lesson page and restores the answer draft', (
    tester,
  ) async {
    final today = LocalDate.today();
    final plan = repository.savePlan(
      StudyPlan(
        id: 'plan',
        title: '课程计划',
        startDate: today,
        endDate: today.addDays(10),
      ),
    );
    controller.store.importDocument(
      DocumentRecord(
        id: 'book',
        title: '数学教材',
        kind: DocumentKind.textbook,
        filePath: '/managed/book.pdf',
        contentHash: 'hash-book',
        pageCount: 4,
        currentPage: 1,
      ),
      [
        for (var page = 1; page <= 4; page++)
          PageRecord(
            documentId: 'book',
            page: page,
            text: '第 $page 页',
            status: PageStatus.ready,
          ),
      ],
    );
    final material = MaterialRef(
      documentId: 'book',
      documentHash: 'hash-book',
      title: '数学教材',
      startPage: 1,
      endPage: 4,
    );
    final task = repository.saveTask(
      StudyTask(
        id: 'task',
        title: '二次函数学习',
        planId: plan.id,
        minutes: 45,
        material: material,
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
    repository.saveLesson(
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
        materialDocumentId: 'book',
        materialHash: 'hash-book',
        startPage: 1,
        endPage: 4,
      ),
    );

    await pumpApp(tester, const Size(1440, 1000));
    await openSchedule(tester);
    expect(find.text('开始学习'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('start-lesson-${block.id}')));
    await tester.pumpAndSettle();
    expect(find.text('今日课程'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('lesson-answer-e1')),
      '我的草稿答案',
    );
    await tester.tap(find.text('返回日程'));
    await tester.pumpAndSettle();
    expect(find.text('开始学习'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('start-lesson-${block.id}')));
    await tester.pumpAndSettle();
    expect(find.text('我的草稿答案'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('calendar content filter exposes all layers', (tester) async {
    await pumpApp(tester, const Size(1440, 1000));
    await openSchedule(tester);
    await tester.tap(find.byKey(const ValueKey('calendar-layer-filter')));
    await tester.pumpAndSettle();
    expect(find.text('学习安排'), findsOneWidget);
    expect(find.text('复习安排'), findsOneWidget);
    expect(find.text('考试'), findsOneWidget);
    expect(find.text('个人占用'), findsWidgets);
    expect(find.text('已完成项目'), findsOneWidget);
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('calendar path and list views switch without losing state', (
    tester,
  ) async {
    await pumpApp(tester, const Size(1440, 1000));
    await openSchedule(tester);

    await tester.tap(find.text('学习路径'));
    await tester.pumpAndSettle();
    expect(find.text('选择计划查看学习路径'), findsOneWidget);

    await tester.tap(find.text('日历'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('calendar-mode-switch')), findsOneWidget);
    await tester.tap(find.text('列表'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('schedule-agenda-list')), findsOneWidget);
    expect(find.text('未来 14 天还没有安排'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('day panel collapses and reopens when a date is clicked', (
    tester,
  ) async {
    await pumpApp(tester, const Size(1440, 1000));
    await openSchedule(tester);
    final panel = find.byKey(const ValueKey('day-panel'));
    expect(tester.getSize(panel).width, 400);

    await tester.tap(find.byTooltip('收起日详情'));
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).width, 0);

    final first = LocalDate(
      LocalDate.today().year,
      LocalDate.today().month,
      1,
    );
    await tester.tap(find.byKey(ValueKey('schedule-day-${first.iso}')));
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).width, 400);
    expect(tester.takeException(), isNull);
  });

  testWidgets('month picker jumps to a month in the year view', (tester) async {
    await pumpApp(tester, const Size(1440, 1000));
    await openSchedule(tester);
    await tester.tap(find.byKey(const ValueKey('month-picker')));
    await tester.pumpAndSettle();
    expect(find.text('选择月份'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('month-option-12')));
    await tester.pumpAndSettle();
    expect(
      find.text('${LocalDate.today().year}年12月'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening the planning dialog leaves the calendar size unchanged', (
    tester,
  ) async {
    await pumpApp(tester, const Size(1440, 1000));
    await openSchedule(tester);
    final cell = find.byKey(
      ValueKey('schedule-day-${LocalDate.today().iso}'),
    );
    final before = tester.getSize(cell).height;
    await tester.tap(find.byKey(const ValueKey('planning-bar')));
    await tester.pumpAndSettle();
    expect(tester.getSize(cell).height, before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('320px schedule and editor do not overflow', (tester) async {
    await pumpApp(tester, const Size(320, 640));
    await openSchedule(tester, mobile: true);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('schedule-quick-jump')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('jump-dialog-input')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('年/月/日'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('schedule-add')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('schedule-task-title')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('year, day, typed date and quick jump navigation work cleanly', (
    tester,
  ) async {
    await pumpApp(tester, const Size(1440, 1000));
    await openSchedule(tester);

    // 1. Select year then month via unified picker.
    await tester.tap(find.byKey(const ValueKey('month-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('年份'));
    await tester.pumpAndSettle();
    expect(find.text('选择年份'), findsOneWidget);
    final targetYear = LocalDate.today().year + 1;
    await tester.tap(find.byKey(ValueKey('year-option-$targetYear')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('month-option-3')));
    await tester.pumpAndSettle();
    expect(find.text('$targetYear年3月'), findsOneWidget);

    // 2. Open day picker and jump to a specific day.
    await tester.tap(find.byKey(const ValueKey('day-picker')));
    await tester.pumpAndSettle();
    expect(find.text('选择日期'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('day-picker-day-18')));
    await tester.pumpAndSettle();
    expect(find.text('3月18日'), findsWidgets);

    // 3. Typed date direct jump from day picker.
    await tester.tap(find.byKey(const ValueKey('day-picker')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('date-jump-input')),
      '2029-05-20',
    );
    await tester.tap(find.byKey(const ValueKey('date-jump-submit')));
    await tester.pumpAndSettle();
    expect(find.text('2029年5月'), findsOneWidget);
    expect(find.text('5月20日'), findsWidgets);

    // 4. Jump dialog shortcut + day panel next day.
    final today = LocalDate.today();
    final tomorrow = today.addDays(1);
    await tester.tap(find.byKey(const ValueKey('schedule-quick-jump')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('明天（${tomorrow.shortLabel}）'));
    await tester.pumpAndSettle();
    expect(find.text(tomorrow.longLabel), findsOneWidget);

    await tester.tap(find.byTooltip('后一天'));
    await tester.pumpAndSettle();
    expect(find.text(tomorrow.addDays(1).longLabel), findsOneWidget);

    // 5. Jump dialog text input supports relative expressions (e.g. +10).
    await tester.tap(find.byKey(const ValueKey('schedule-quick-jump')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('jump-dialog-input')),
      '+10',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('jump-dialog-input-submit')));
    await tester.pumpAndSettle();
    expect(find.text(today.addDays(10).longLabel), findsOneWidget);

    // 6. Jump dialog numeric relative offset (select number + unit + direction).
    await tester.tap(find.byKey(const ValueKey('schedule-quick-jump')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('jump-preset-3')));
    await tester.tap(find.byKey(const ValueKey('jump-unit-week')));
    await tester.tap(find.byKey(const ValueKey('jump-dir-after')));
    await tester.pumpAndSettle();
    final threeWeeks = today.addDays(21);
    expect(find.text(threeWeeks.longLabel), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('jump-numeric-submit')));
    await tester.pumpAndSettle();
    expect(find.text(threeWeeks.longLabel), findsOneWidget);

    // 7. Jump dialog custom number + Y/M/D number selector mode.
    await tester.tap(find.byKey(const ValueKey('schedule-quick-jump')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('jump-amount-input')),
      '12',
    );
    await tester.tap(find.byKey(const ValueKey('jump-dir-before')));
    await tester.pumpAndSettle();
    expect(find.text(today.addDays(-12).longLabel), findsWidgets);

    await tester.tap(find.text('年/月/日'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('jump-year-inc')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('jump-numeric-submit')));
    await tester.pumpAndSettle();
    expect(find.text('${threeWeeks.year + 1}年${threeWeeks.month}月'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
