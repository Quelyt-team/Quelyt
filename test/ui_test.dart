import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:local_study/app_controller.dart';
import 'package:local_study/core/local_store.dart';
import 'package:local_study/core/models.dart';
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
      expect(find.text('教材自学'), findsOneWidget);
      expect(find.text('论文精读'), findsOneWidget);
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

  testWidgets('desktop library filters and searches only local documents', (
    tester,
  ) async {
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
    expect(find.byKey(const ValueKey('library-document-book')), findsOneWidget);
    await tester.tap(find.text('论文').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('library-document-book')), findsNothing);
    expect(
      find.byKey(const ValueKey('library-document-paper')),
      findsOneWidget,
    );
    await tester.tap(find.text('全部'));
    await tester.enterText(find.widgetWithText(TextField, '查找资料名称'), '热力学');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('library-document-book')), findsOneWidget);
    expect(find.byKey(const ValueKey('library-document-paper')), findsNothing);
    expect(tester.takeException(), isNull);
  });

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
}
