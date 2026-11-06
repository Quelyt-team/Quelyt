import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:local_study/app_controller.dart';
import 'package:local_study/core/local_store.dart';
import 'package:local_study/core/models.dart';
import 'package:local_study/services/ai_gateway.dart';
import 'package:local_study/services/document_service.dart';
import 'package:local_study/services/ocr_service.dart';
import 'package:local_study/ui/shell/app_chrome.dart';
import 'package:local_study/ui/study_app.dart';
import 'package:local_study/ui/theme/app_theme.dart';
import 'package:local_study/ui/widgets/app_surfaces.dart';

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

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('local_study_round3_');
    store = LocalStore.inMemory();
    final ocr = OcrService();
    controller = StudyController(
      store: store,
      ocr: ocr,
      documents: DocumentService(directory, store, ocr),
      gateway: AiGateway(vault: _MemoryVault()),
    );
    store.upsertDocument(
      DocumentRecord(
        id: 'book',
        title: '热力学基础 · 界面样例',
        kind: DocumentKind.textbook,
        filePath: 'test-only.png',
        contentHash: 'book-hash',
        pageCount: 10,
        currentPage: 2,
      ),
    );
    store.saveSession(
      StudySession(
        id: 'session-1',
        documentId: 'book',
        startPage: 1,
        endPage: 2,
        question: '用自己的话说明动量与冲量的关系。',
        stage: 'answered',
        attempts: [
          StudyAttempt(
            question: '用自己的话说明动量与冲量的关系。',
            answer: '动量是质量乘以速度。',
            feedback: '定义正确，可以再补一个生活例子。',
          ),
        ],
      ),
    );
  });

  tearDown(() async {
    await controller.shutdown();
    controller.dispose();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  Future<void> setSize(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('review filter and empty state stay on the same left edge', (
    tester,
  ) async {
    await setSize(tester, const Size(1440, 1000));
    await tester.pumpWidget(StudyApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('复习'));
    await tester.pumpAndSettle();

    final allRect = tester.getRect(find.byKey(const ValueKey('review-filter')));
    expect(find.text('继续练习'), findsOneWidget);

    await tester.tap(find.text('待核对'));
    await tester.pumpAndSettle();
    final pendingRect = tester.getRect(
      find.byKey(const ValueKey('review-filter')),
    );
    expect(find.byKey(const ValueKey('review-empty')), findsOneWidget);
    expect((pendingRect.left - allRect.left).abs(), lessThan(0.5));

    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    final again = tester.getRect(find.byKey(const ValueKey('review-filter')));
    expect((again.left - allRect.left).abs(), lessThan(0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('caption controls are 46x48 and hit the bottom edge', (
    tester,
  ) async {
    var minimize = 0;
    var maximize = 0;
    var close = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: lightTheme,
        home: Scaffold(
          body: Center(
            child: WindowCaptionControls(
              onMinimize: () => minimize++,
              onMaximize: () => maximize++,
              onClose: () => close++,
            ),
          ),
        ),
      ),
    );
    final minButton = find.byKey(const ValueKey('caption-minimize'));
    final maxButton = find.byKey(const ValueKey('caption-maximize'));
    final closeButton = find.byKey(const ValueKey('caption-close'));
    expect(tester.getSize(minButton), const Size(46, 48));
    expect(tester.getSize(maxButton), const Size(46, 48));
    expect(tester.getSize(closeButton), const Size(46, 48));

    final bottom = tester.getRect(minButton).bottomCenter - const Offset(0, 2);
    await tester.tapAt(bottom);
    await tester.pump();
    expect(minimize, 1);
    await tester.tap(maxButton);
    await tester.pump();
    expect(maximize, 1);
    await tester.tap(closeButton);
    await tester.pump();
    expect(close, 1);
  });

  testWidgets('segment width is independent of count digits', (tester) async {
    Future<double> pumpCount(int count) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: lightTheme,
          home: Scaffold(
            body: Center(
              child: AppSegmentedControl(
                segmentMinWidth: 104,
                segments: [
                  AppSegment(label: '全部', count: count),
                  const AppSegment(label: '待核对', count: 0),
                ],
                selectedIndex: 0,
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return tester.getSize(find.byType(AppSegmentedControl)).width;
    }

    final zero = await pumpCount(0);
    final ten = await pumpCount(10);
    expect(ten, zero);
  });

  testWidgets('settings opens as a modal and switches sections', (
    tester,
  ) async {
    await setSize(tester, const Size(1440, 1000));
    await tester.pumpWidget(StudyApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('关闭设置'), findsOneWidget);
    expect(find.text('通用'), findsWidgets);

    await tester.tap(find.text('模型服务'));
    await tester.pumpAndSettle();
    expect(find.text('服务商预设'), findsOneWidget);

    await tester.tap(find.byTooltip('关闭设置'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('关闭设置'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Ctrl+comma opens settings', (tester) async {
    await setSize(tester, const Size(1440, 1000));
    await tester.pumpWidget(StudyApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.byTooltip('关闭设置'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭设置'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('header does not overflow at desktop widths', (tester) async {
    for (final size in const [
      Size(1440, 900),
      Size(1200, 900),
      Size(1000, 900),
      Size(900, 900),
      Size(760, 900),
      Size(600, 900),
    ]) {
      await setSize(tester, size);
      await tester.pumpWidget(
        StudyApp(controller: controller, showWindowChrome: true),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'width ${size.width}');
    }
  });
}
