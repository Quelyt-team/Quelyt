import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:local_study/app_controller.dart';
import 'package:local_study/core/local_store.dart';
import 'package:local_study/core/models.dart';
import 'package:local_study/features/library/data/library_repository.dart';
import 'package:local_study/features/notes/data/notes_repository.dart';
import 'package:local_study/features/notes/notes_controller.dart';
import 'package:local_study/features/notes/ui/notes_page.dart';
import 'package:local_study/features/review/data/review_repository.dart';
import 'package:local_study/features/review/models/review_models.dart';
import 'package:local_study/features/review/review_controller.dart';
import 'package:local_study/features/review/ui/review_session_page.dart';
import 'package:local_study/features/schedule/data/schedule_repository.dart';
import 'package:local_study/features/schedule/schedule_controller.dart';
import 'package:local_study/features/schedule/ui/schedule_page.dart';
import 'package:local_study/services/ai_gateway.dart';
import 'package:local_study/services/document_service.dart';
import 'package:local_study/services/file_reveal.dart';
import 'package:local_study/services/ocr_service.dart';
import 'package:local_study/services/platform_file_access.dart';
import 'package:local_study/ui/shell/app_shell.dart';
import 'package:local_study/ui/study_app.dart';
import 'package:local_study/ui/theme/adaptive_layout.dart';
import 'package:local_study/ui/theme/app_theme.dart';
import 'package:local_study/ui/widgets/quelyt_splash.dart';

class _TestVault implements CredentialVault {
  final _map = <String, String>{};
  @override
  Future<void> delete(String accountId) async => _map.remove(accountId);
  @override
  Future<String?> read(String accountId) async => _map[accountId];
  @override
  Future<void> write(String accountId, String value) async =>
      _map[accountId] = value;
}

Widget _wrapViewport(
  Widget child, {
  double textScale = 1.0,
}) {
  return MaterialApp(
    theme: buildAppTheme(Brightness.light),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(body: child),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('AdaptiveLayout size classes match Material width and height thresholds', () {
    expect(AdaptiveLayout.sizeClassForWidth(360), AppWindowSizeClass.compact);
    expect(AdaptiveLayout.sizeClassForWidth(599), AppWindowSizeClass.compact);
    expect(AdaptiveLayout.sizeClassForWidth(600), AppWindowSizeClass.medium);
    expect(AdaptiveLayout.sizeClassForWidth(839), AppWindowSizeClass.medium);
    expect(AdaptiveLayout.sizeClassForWidth(840), AppWindowSizeClass.expanded);
    expect(AdaptiveLayout.isCompactHeight(499), isTrue);
    expect(AdaptiveLayout.isCompactHeight(500), isFalse);
  });

  test('PlatformFileAccess method channel contract & FileReveal Android capabilities', () async {
    const channelName = 'quelyt/android_platform_test';
    final channel = MethodChannel(channelName);
    final recordedCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          recordedCalls.add(call);
          switch (call.method) {
            case 'pickDirectoryAndStage':
              return <String, Object?>{
                'opId': 'op-1',
                'rootName': '线性代数资料',
                'stagingDirectory': '/tmp/saf_imports/op-1',
                'files': <Object?>[
                  <String, Object?>{
                    'path': '/tmp/saf_imports/op-1/ch1.pdf',
                    'name': 'ch1.pdf',
                    'relativePath': 'ch1.pdf',
                    'mime': 'application/pdf',
                    'sizeBytes': 1024,
                  },
                ],
                'unsupported': const <String>[],
                'unreadable': const <String>[],
                'truncated': false,
                'totalBytes': 1024,
              };
            case 'saveFileToUserLocation':
              return <String, Object?>{
                'saved': true,
                'cancelled': false,
                'bytes': 2048,
                'displayName': 'export.zip',
              };
            case 'shareFile':
            case 'openFileExternally':
              return <String, Object?>{'ok': true};
            case 'consumePendingShares':
              return <Object?>[
                <String, Object?>{
                  'opId': 'share-1',
                  'action': 'android.intent.action.SEND',
                  'stagingDirectory': '/tmp/shared_inbox/share-1',
                  'items': <Object?>[
                    <String, Object?>{
                      'path': '/tmp/shared_inbox/share-1/paper.pdf',
                      'name': 'paper.pdf',
                      'relativePath': 'paper.pdf',
                      'mime': 'application/pdf',
                      'sizeBytes': 512,
                    },
                  ],
                  'rejected': const <String>[],
                },
              ];
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final previous = PlatformFileAccess.instance;
    final mockAccess = PlatformFileAccess(
      channel: channel,
      isAndroidOverride: true,
      isDesktopOverride: false,
    );
    PlatformFileAccess.instance = mockAccess;
    addTearDown(() => PlatformFileAccess.instance = previous);

    expect(mockAccess.capabilities.safTree, isTrue);
    expect(mockAccess.capabilities.safSaveAs, isTrue);
    expect(mockAccess.capabilities.shareFile, isTrue);
    expect(mockAccess.capabilities.openExternal, isTrue);
    expect(mockAccess.capabilities.openFolder, isFalse);
    expect(FileReveal.canOpenFolder, isFalse);
    expect(FileReveal.canShare, isTrue);
    expect(FileReveal.canOpenExternal, isTrue);

    final tree = await mockAccess.pickDirectoryAndStage();
    expect(tree, isNotNull);
    expect(tree!.rootName, '线性代数资料');
    expect(tree.files.single.name, 'ch1.pdf');

    final saveResult = await mockAccess.saveFileToUserLocation(
      sourcePath: '/tmp/a.zip',
      fileName: 'export.zip',
    );
    expect(saveResult.saved, isTrue);
    expect(saveResult.displayName, 'export.zip');

    final shareResult = await FileReveal.share('/tmp/a.zip', mimeType: 'application/zip');
    expect(shareResult.ok, isTrue);

    final openResult = await FileReveal.openExternal('/tmp/a.pdf', mimeType: 'application/pdf');
    expect(openResult.ok, isTrue);

    final shares = await mockAccess.consumePendingShares();
    expect(shares, hasLength(1));
    expect(shares.single.items.single.name, 'paper.pdf');
    expect(
      recordedCalls.map((c) => c.method).toList(),
      [
        'pickDirectoryAndStage',
        'saveFileToUserLocation',
        'shareFile',
        'openFileExternally',
        'consumePendingShares',
      ],
    );
  });

  test('ReviewController.resumeActiveItemTimer preserves accumulated seconds across background pause', () async {
    final store = LocalStore.inMemory();
    addTearDown(store.dispose);
    final controller = ReviewController(repository: ReviewRepository(store));
    addTearDown(controller.dispose);

    controller.beginActiveItemTimer();
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    controller.pauseActiveItemTimer();
    final pausedAccumulated = controller.activeAccumulatedSeconds;
    expect(pausedAccumulated, greaterThanOrEqualTo(1));

    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.resumeActiveItemTimer();
    expect(controller.activeAccumulatedSeconds, pausedAccumulated);
    final total = controller.takeActiveItemSeconds();
    expect(total, greaterThanOrEqualTo(pausedAccumulated));
  });

  testWidgets('AppBottomNav and UnifiedHeader handle compact phones at 2.0x text scaling without overflow', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _wrapViewport(
        Column(
          children: [
            UnifiedHeader(
              title: '书库',
              subtitle: '',
              sidebarCollapsed: true,
              onToggleSidebar: () {},
              onOpenSettings: () {},
              showSidebarToggle: false,
              showSubtitle: false,
              showWindowChrome: false,
              compact: true,
            ),
            const Spacer(),
            AppBottomNav(section: AppSection.library, onSelect: (_) {}),
          ],
        ),
        textScale: 2.0,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('SchedulePage renders without overflow across compact phone, landscape, split-screen, and 2.0x text scale', (tester) async {
    final store = LocalStore.inMemory();
    addTearDown(store.dispose);
    final scheduleController = ScheduleController(ScheduleRepository(store))
      ..initialize();
    addTearDown(scheduleController.dispose);

    const viewports = [
      (size: Size(360, 640), scale: 1.0, mode: CalendarDisplayMode.month),
      (size: Size(800, 360), scale: 1.0, mode: CalendarDisplayMode.month),
      (size: Size(420, 800), scale: 1.0, mode: CalendarDisplayMode.list),
      (size: Size(390, 844), scale: 2.0, mode: CalendarDisplayMode.month),
      (size: Size(800, 1280), scale: 1.5, mode: CalendarDisplayMode.month),
    ];

    for (final v in viewports) {
      tester.view.physicalSize = v.size;
      tester.view.devicePixelRatio = 1.0;
      if (scheduleController.calendarMode != v.mode) {
        scheduleController.setCalendarMode(v.mode);
      }

      await tester.pumpWidget(
        _wrapViewport(
          SchedulePage(
            controller: scheduleController,
            onOpenMaterial: (_) async {},
            onOpenTaskMaterial: (_, _) async {},
            onOpenSettings: () {},
          ),
          textScale: v.scale,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.takeException(),
        isNull,
        reason: 'Unexpected exception/overflow on ${v.size} @ ${v.scale}x',
      );
    }
    tester.view.reset();
  });

  group('ReviewSessionPage compact scaling', () {
    late Directory activeDir;
    late LocalStore activeStore;
    late StudyController activeStudy;

    setUp(() async {
      activeDir = Directory.systemTemp.createTempSync('review-adapt-');
      activeStore = LocalStore.inMemory();
      final ocr = OcrService();
      activeStudy = StudyController(
        store: activeStore,
        ocr: ocr,
        documents: DocumentService(activeDir, activeStore, ocr),
        gateway: AiGateway(vault: _TestVault()),
      );
      await Future<void>.value();
    });

    tearDown(() async {
      await activeStudy.shutdown();
      activeStudy.dispose();
      if (activeDir.existsSync()) {
        activeDir.deleteSync(recursive: true);
      }
    });

    testWidgets(
      'ReviewSessionPage FSRS buttons render without overflow on compact 360px screen at 2.0x scale',
      timeout: const Timeout(Duration(seconds: 20)),
      (tester) async {
        tester.view.physicalSize = const Size(360, 740);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final created = activeStudy.reviewRepository.createItem(
          id: 'item-1',
          kind: ReviewItemKind.concept,
          prompt: '请写出热力学第二定律的克劳修斯表述。',
          answer: '热量不能自发地从低温物体传到高温物体而不引起其他变化。',
        );
        activeStudy.reviewController.startOrResumeSession(
          explicitItemIds: [created.id],
        );

        await tester.pumpWidget(
          _wrapViewport(
            ReviewSessionPage(
              study: activeStudy,
              onJumpToSource: (_) async {},
            ),
            textScale: 2.0,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('请写出热力学第二定律的克劳修斯表述。'), findsOneWidget);

        final revealBtn = find.byKey(const ValueKey('review-reveal-btn'));
        await tester.scrollUntilVisible(
          revealBtn,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(revealBtn);
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('记忆提取评分（FSRS v5）'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(find.text('记忆提取评分（FSRS v5）'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });

  testWidgets('NotesPage compact editor has >= 48x48 back button that returns to note list', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final store = LocalStore.inMemory();
    addTearDown(store.dispose);
    final controller = NotesController(
      store: store,
      repository: NotesRepository(store),
      library: LibraryRepository(store),
    );
    addTearDown(controller.dispose);
    controller.initialize();
    controller.createNote(title: '手机端测试笔记', body: '正文');

    await tester.pumpWidget(
      _wrapViewport(NotesPage(controller: controller)),
    );
    await tester.pumpAndSettle();

    final backFinder = find.byTooltip('返回列表');
    expect(backFinder, findsOneWidget);
    final backSize = tester.getSize(backFinder);
    expect(backSize.width, greaterThanOrEqualTo(48));
    expect(backSize.height, greaterThanOrEqualTo(48));

    await tester.tap(backFinder);
    await tester.pumpAndSettle();
    expect(controller.selected, isNull);
  });

  group('Compact header & startup splash animation', () {
    late Directory activeDir;
    late LocalStore activeStore;
    late StudyController activeStudy;

    setUp(() async {
      activeDir = Directory.systemTemp.createTempSync('splash-adapt-');
      activeStore = LocalStore.inMemory();
      final ocr = OcrService();
      activeStudy = StudyController(
        store: activeStore,
        ocr: ocr,
        documents: DocumentService(activeDir, activeStore, ocr),
        gateway: AiGateway(vault: _TestVault()),
      );
      await Future<void>.value();
    });

    tearDown(() async {
      await activeStudy.shutdown();
      activeStudy.dispose();
      if (activeDir.existsSync()) {
        activeDir.deleteSync(recursive: true);
      }
    });

    testWidgets(
      'Compact phone hides window caption controls, places settings at top-right, and plays startup splash cleanly',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          StudyApp(
            controller: activeStudy,
            showWindowChrome: true,
            showSplash: true,
          ),
        );
        await tester.pump(const Duration(milliseconds: 120));
        expect(find.byType(QuelytSplashOverlay), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(QuelytSplashOverlay),
            matching: find.byType(CustomPaint),
          ),
          findsWidgets,
        );
        expect(tester.takeException(), isNull);

        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);

        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('caption-minimize')), findsNothing);
        expect(find.byKey(const ValueKey('caption-maximize')), findsNothing);
        expect(find.byKey(const ValueKey('caption-close')), findsNothing);

        final settingsBtn = find.byTooltip('设置（Ctrl+,）');
        expect(settingsBtn, findsOneWidget);
        expect(tester.getCenter(settingsBtn).dx, greaterThan(320));
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'Compact reader capsule opens Q&A and Notes directly instead of jumping to Study, and handles 2.0x scale',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final doc = DocumentRecord(
          id: 'compact-doc',
          title: '线性代数讲义',
          kind: DocumentKind.unspecified,
          filePath: 'test-only.png',
          contentHash: 'compact-doc-hash',
          pageCount: 12,
          currentPage: 2,
        );
        activeStore.importDocument(doc, [
          for (var p = 1; p <= 12; p++)
            PageRecord(
              documentId: doc.id,
              page: p,
              status: PageStatus.ready,
              text: '第 $p 页正文内容。',
            ),
        ]);
        activeStudy.current = doc;
        activeStudy.page = 2;

        await tester.pumpWidget(StudyApp(controller: activeStudy));
        await tester.pumpAndSettle();

        // Sheet starts collapsed; tapping Q&A (index 1) must land on Q&A, not Study.
        await tester.tap(find.byKey(const ValueKey('learning-dock-1')));
        await tester.pumpAndSettle();
        expect(find.text('暂无问答'), findsOneWidget);
        expect(find.text('直接开始阅读'), findsNothing);

        // Switching to Notes (index 2) while open lands on Notes.
        await tester.tap(find.byKey(const ValueKey('learning-dock-2')));
        await tester.pumpAndSettle();
        expect(find.text('暂无笔记'), findsOneWidget);

        // Tapping active Notes item collapses the sheet.
        await tester.tap(find.byKey(const ValueKey('learning-dock-2')));
        await tester.pumpAndSettle();
        expect(find.text('暂无笔记'), findsNothing);

        // Tapping Notes (index 2) from collapsed must land directly on Notes, not Study.
        await tester.tap(find.byKey(const ValueKey('learning-dock-2')));
        await tester.pumpAndSettle();
        expect(find.text('暂无笔记'), findsOneWidget);
        expect(find.text('直接开始阅读'), findsNothing);

        // Narrow 320px viewport with 2.0x text scale renders capsule without overflow.
        tester.view.physicalSize = const Size(320, 640);
        tester.platformDispatcher.textScaleFactorTestValue = 2.0;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'Exercise mode renders ExerciseStudyPanel in compact reader and allows switching modes',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final doc = DocumentRecord(
          id: 'exercise-doc',
          title: '物理化学第一章习题',
          kind: DocumentKind.exercise,
          filePath: 'test-only.png',
          contentHash: 'exercise-doc-hash',
          pageCount: 4,
          currentPage: 1,
        );
        activeStore.importDocument(doc, [
          PageRecord(
            documentId: doc.id,
            page: 1,
            status: PageStatus.ready,
            text: '1. 计算理想气体等温可逆膨胀功。\n1) 求 Q 和 W。\n2) 求 ΔU。',
          ),
        ]);
        activeStore.saveEvidence(
          Evidence(
            id: 'ex-e1',
            documentId: doc.id,
            documentHash: doc.contentHash,
            page: 1,
            region: const SourceRegion(.1, .1, .9, .3),
            text: '1. 计算理想气体等温可逆膨胀功。\n1) 求 Q 和 W。\n2) 求 ΔU。',
          ),
        );
        activeStudy.current = doc;
        activeStudy.page = 1;

        await tester.pumpWidget(StudyApp(controller: activeStudy));
        await tester.pumpAndSettle();

        // Open Study tab (index 0) on compact phone.
        await tester.tap(find.byKey(const ValueKey('learning-dock-0')));
        await tester.pumpAndSettle();

        expect(find.text('试题进度'), findsOneWidget);
        expect(find.text('求解与整理'), findsOneWidget);
        expect(find.text('解答页段'), findsOneWidget);
        expect(find.text('处理整份作业'), findsOneWidget);
        expect(find.text('暂未选定学习方式'), findsNothing);
        expect(find.byTooltip('切换学习方式'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
