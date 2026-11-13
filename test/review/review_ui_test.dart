import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_study/app_controller.dart';
import 'package:local_study/core/local_store.dart';
import 'package:local_study/services/ai_gateway.dart';
import 'package:local_study/services/document_service.dart';
import 'package:local_study/services/ocr_service.dart';
import 'package:local_study/ui/study_app.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late LocalStore store;
  late StudyController controller;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('review_ui_test_');
    store = LocalStore.inMemory();
    final ocr = OcrService();
    controller = StudyController(
      store: store,
      ocr: ocr,
      documents: DocumentService(dir, store, ocr),
      gateway: AiGateway(vault: _TestVault()),
    );
    await Future<void>.value();
  });

  tearDown(() async {
    await controller.shutdown();
    controller.dispose();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  testWidgets(
    'active recall session hides answer initially, reveals on tap, grades and supports undo',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      controller.reviewRepository.createItem(
        objective: '特征值定义',
        prompt: '什么是矩阵 A 的特征值与特征向量？',
        answer: '存在非零向量 v 使得 Av = lambda * v',
        hint: '考虑线性变换下方向不变的向量',
      );
      controller.reviewController.refresh();

      await tester.pumpWidget(StudyApp(controller: controller));
      await tester.pumpAndSettle();

      await tester.tap(find.text('复习').first);
      await tester.pumpAndSettle();
      expect(find.text('什么是矩阵 A 的特征值与特征向量？'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('review-start-btn')));
      await tester.pumpAndSettle();

      // Stage 1: answer is hidden until Reveal is tapped.
      expect(find.text('存在非零向量 v 使得 Av = lambda * v'), findsNothing);
      expect(find.byKey(const ValueKey('review-reveal-btn')), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'Av = λv');
      await tester.tap(find.byKey(const ValueKey('review-reveal-btn')));
      await tester.pumpAndSettle();

      // Stage 2: answer and FSRS rating controls appear.
      expect(find.text('存在非零向量 v 使得 Av = lambda * v'), findsOneWidget);
      expect(find.textContaining('正常想起'), findsOneWidget);

      await tester.tap(find.textContaining('正常想起').first);
      await tester.pumpAndSettle();

      // Session finished summary screen.
      expect(find.text('本轮复习完成'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '320px mini phone with 1.3x text scale renders ReviewPage and manual dialog without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      controller.reviewRepository.createItem(
        objective: '卷积性质',
        prompt: '解释离散卷积与互相关的区别。',
        answer: '卷积核在求和前会先做一次翻转。',
      );
      controller.reviewController.refresh();

      await tester.pumpWidget(StudyApp(controller: controller));
      await tester.pumpAndSettle();

      await tester.tap(find.text('复习').first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Open manual create dialog and verify no overflow.
      await tester.tap(find.text('新建复习题').first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
