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
import 'package:local_study/ui/bootstrap_error.dart';
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
  late Uint8List pageBytes;
  late DocumentRecord book;
  late StudySession session;
  late List<SavedReply> replies;
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
      final manropeFile = File('assets/brand/Manrope.ttf');
      if (manropeFile.existsSync()) {
        final mBytes = ByteData.sublistView(manropeFile.readAsBytesSync());
        final mLoader = FontLoader('Manrope')
          ..addFont(Future<ByteData>.value(mBytes));
        await mLoader.load();
      }
    }
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    pageBytes = await _makePage();
  });

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('local_study_preview_');
    store = LocalStore.inMemory();
    final ocr = OcrService();
    controller = StudyController(
      store: store,
      ocr: ocr,
      documents: DocumentService(directory, store, ocr),
      gateway: AiGateway(vault: _MemoryVault()),
    );

    book = DocumentRecord(
      id: 'book',
      title: '热力学基础 · 界面样例',
      kind: DocumentKind.textbook,
      filePath: 'test-only.png',
      contentHash: 'book-hash',
      pageCount: 216,
      currentPage: 18,
    );
    final paper = DocumentRecord(
      id: 'paper',
      title: 'Attention Is All You Need · 界面样例',
      kind: DocumentKind.paper,
      filePath: 'test-only.pdf',
      contentHash: 'paper-hash',
      pageCount: 15,
      currentPage: 3,
    );
    store.importDocument(book, [
      for (var page = 1; page <= book.pageCount; page++)
        PageRecord(
          documentId: book.id,
          page: page,
          status: PageStatus.ready,
          text: '第 $page 页：动量等于质量乘以速度，冲量是力对时间的积累。',
        ),
    ]);
    store.importDocument(paper, [
      for (var page = 1; page <= paper.pageCount; page++)
        PageRecord(
          documentId: paper.id,
          page: page,
          status: PageStatus.ready,
          text: 'Page $page: The dominant sequence transduction models are based on '
              'complex recurrent or convolutional neural networks.',
        ),
    ]);

    session = StudySession(
      id: 'session-book',
      documentId: book.id,
      startPage: 17,
      endPage: 20,
      goal: '分清动量与冲量：能用自己的话解释，并举一个生活例子。',
      minutes: 25,
      stage: 'answered',
      question: '用自己的话说明动量与冲量的关系，并给出一个生活例子。',
      answer: '动量是质量乘以速度，描述物体的运动状态；冲量是力对时间的积累，等于动量的变化。',
      attempts: [
        StudyAttempt(
          question: '用自己的话说明动量与冲量的关系，并给出一个生活例子。',
          answer: '动量是质量乘以速度，描述物体的运动状态；冲量是力对时间的积累，等于动量的变化。',
          feedback: '你抓住了两个量的定义与关系。还缺少适用条件：合外力为恒力时，冲量才等于动量的变化。',
          needsReview: true,
        ),
      ],
      needsReview: true,
    );
    store.saveSession(session);

    store.saveEvidence(
      Evidence(
        id: 'e1',
        documentId: book.id,
        documentHash: book.contentHash,
        page: 18,
        region: const SourceRegion(.12, .60, .86, .72),
        text: '动量等于质量乘以速度，是描述物体运动状态的物理量。冲量等于力与作用时间的乘积。',
      ),
    );
    store.saveNote(
      StudyNote(
        id: 'n1',
        documentId: book.id,
        documentHash: book.contentHash,
        page: 18,
        region: const SourceRegion(.12, .60, .86, .72),
        understanding: '动量描述“运动有多难停下来”，冲量描述“力作用多久改变了它”。',
        evidenceText: '动量等于质量乘以速度。冲量等于力与作用时间的乘积。',
        question: '合外力不是恒力时，冲量还等于动量变化吗？',
      ),
    );

    replies = [
      SavedReply(
        question: '为什么冲量等于动量的变化？',
        answer: '由牛顿第二定律 F = ma 与加速度定义，合外力的冲量等于动量变化。'
            '这一步要求合外力在作用时间内可积；碰撞中常取平均力来估算。',
        sources: [
          Evidence(
            id: 'e1',
            documentId: book.id,
            documentHash: book.contentHash,
            page: 18,
            region: const SourceRegion(.12, .60, .86, .72),
            text: '动量等于质量乘以速度。',
          ),
        ],
        model: 'deepseek-flash',
        tokens: 1280,
      ),
    ];
  });

  tearDown(() async {
    await controller.shutdown();
    controller.dispose();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  void enterReader() {
    controller.current = book;
    controller.page = 18;
    controller.selection = const SourceRegion(.12, .60, .86, .72);
    controller.highlight = null;
    controller.session = session;
    controller.replies = replies;
    controller.raster = RenderedPage(pageBytes, 1000, 1400);
    controller.error = null;
    controller.indexing = false;
    controller.paused = false;
  }

  Future<void> setView(
    WidgetTester tester,
    Size size, {
    double scale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  Future<void> pumpApp(
    WidgetTester tester, {
    required bool dark,
    bool showWindowChrome = false,
  }) async {
    store.setSetting('ui.theme', dark ? 'dark' : 'light');
    previewKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: previewKey,
        child: StudyApp(
          controller: controller,
          showWindowChrome: showWindowChrome,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pump();
  }

  Future<void> capture(WidgetTester tester, String name) async {
    await tester.pumpAndSettle();
    final exception = tester.takeException();
    final boundary =
        previewKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final output = File('build/preview/design/$name.png');
      await output.parent.create(recursive: true);
      await output.writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
    if (exception != null) {
      if (exception is FlutterError) {
        // ignore: avoid_print
        print(exception.toStringDeep());
      }
      fail('$name rendered an exception: $exception');
    }
  }

  Future<void> openSettings(WidgetTester tester) async {
    final sidebarEntry = find.text('设置');
    if (sidebarEntry.evaluate().isNotEmpty) {
      await tester.tap(sidebarEntry.first);
    } else {
      await tester.tap(find.byTooltip('设置（Ctrl+,）'));
    }
    await tester.pumpAndSettle();
  }

  Future<void> closeSettings(WidgetTester tester) async {
    final close = find.byTooltip('关闭设置');
    if (close.evaluate().isEmpty) return;
    await tester.tap(close.first);
    await tester.pumpAndSettle();
  }

  testWidgets('design preview: desktop and reader layouts', (tester) async {    await setView(tester, const Size(1440, 900));
    await pumpApp(tester, dark: false);
    await capture(tester, '01-library-desktop');

    await tester.tap(find.text('复习').first);
    await tester.pumpAndSettle();
    await capture(tester, '02-review-desktop');

    await openSettings(tester);
    await capture(tester, '03-settings-desktop');
    await tester.tap(find.text('模型服务'));
    await tester.pumpAndSettle();
    await capture(tester, '30-settings-models-desktop');
    await closeSettings(tester);

    await pumpApp(tester, dark: true);
    await openSettings(tester);
    await capture(tester, '04-settings-desktop-dark');
    await closeSettings(tester);

    await tester.tap(find.text('书库').first);
    await tester.pumpAndSettle();
    await capture(tester, '05-library-desktop-dark');

    enterReader();
    await pumpApp(tester, dark: true);
    await capture(tester, '06-reader-desktop-dark');

    await pumpApp(tester, dark: false);
    await capture(tester, '07-reader-desktop');

    await pumpApp(tester, dark: false, showWindowChrome: true);
    await capture(tester, '31-reader-desktop-caption');

    await tester.tap(find.text('笔记').first);
    await tester.pumpAndSettle();
    await capture(tester, '32-reader-notes');

    await tester.tap(find.text('问答').first);
    await tester.pumpAndSettle();
    await capture(tester, '33-reader-questions');

    await setView(tester, const Size(1000, 700));
    await pumpApp(tester, dark: false);
    await capture(tester, '08-reader-1000');

    await tester.tap(find.byKey(const ValueKey('learning-dock-1')));
    await tester.pumpAndSettle();
    await capture(tester, '09-reader-1000-drawer');

    await setView(tester, const Size(390, 844));
    await pumpApp(tester, dark: false);
    await capture(tester, '10-reader-phone-collapsed');

    await tester.tap(find.textContaining('学习面板 ·'));
    await tester.pumpAndSettle();
    await capture(tester, '11-reader-phone-panel');

    controller.current = null;
    controller.raster = null;
    controller.session = null;
    await pumpApp(tester, dark: false);
    await openSettings(tester);
    await capture(tester, '12-settings-phone');
    await closeSettings(tester);

    await capture(tester, '13-library-phone');

    await setView(tester, const Size(390, 844), scale: 1.6);
    await pumpApp(tester, dark: false);
    await capture(tester, '14-library-phone-scale1.6');

    await openSettings(tester);
    await capture(tester, '15-settings-phone-scale1.6');
    await closeSettings(tester);

    await setView(tester, const Size(320, 640), scale: 1.3);
    await pumpApp(tester, dark: false);
    await openSettings(tester);
    await capture(tester, '16-settings-phone-320');
    await closeSettings(tester);

    enterReader();
    await pumpApp(tester, dark: false);
    await capture(tester, '17-reader-phone-320');

    controller.current = null;
    controller.raster = null;
    controller.session = null;
    await setView(tester, const Size(390, 844));
    store.deleteDocument(book.id);
    store.deleteDocument('paper');
    await pumpApp(tester, dark: false);
    await capture(tester, '18-library-empty-phone');

    await setView(tester, const Size(1440, 900));
    await pumpApp(tester, dark: false);
    await capture(tester, '19-library-empty-desktop');
  });

  testWidgets('design preview: dialogs', (tester) async {
    await setView(tester, const Size(1440, 900));
    await pumpApp(tester, dark: false);

    await tester.tap(find.text('导入资料'));
    await tester.pumpAndSettle();
    await capture(tester, '20-dialog-import');
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('资料操作').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除资料'));
    await tester.pumpAndSettle();
    await capture(tester, '21-dialog-delete');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    enterReader();
    await pumpApp(tester, dark: false);

    await tester.tap(find.byTooltip('更多页面工具'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('键盘快捷键'));
    await tester.pumpAndSettle();
    await capture(tester, '22-dialog-shortcuts');
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('检索本篇原文（Ctrl+F）'));
    await tester.pumpAndSettle();
    await capture(tester, '23-dialog-search');
    await tester.enterText(find.byType(TextField).last, '动量');
    await tester.pumpAndSettle();
    await capture(tester, '24-dialog-search-results');
    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('18 / 216'));
    await tester.pumpAndSettle();
    await capture(tester, '25-dialog-jump');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('本节操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑学习目标'));
    await tester.pumpAndSettle();
    await capture(tester, '26-dialog-session');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('换题'));
    await tester.pumpAndSettle();
    await capture(tester, '27-dialog-request-preview');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('笔记'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('新建笔记'));
    await tester.pumpAndSettle();
    await capture(tester, '28-dialog-note');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    // Bootstrap error screen preview (monochrome Page-Q mark + Manrope wordmark)
    previewKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: previewKey,
        child: BootstrapErrorApp(error: StateError('应用数据目录被其他进程占用')),
      ),
    );
    await tester.pumpAndSettle();
    await capture(tester, '29-bootstrap-error');
  });
}

Future<Uint8List> _makePage() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const width = 1000.0;
  const height = 1400.0;
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, width, height),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  canvas.drawRect(
    const Rect.fromLTWH(100, 835, 800, 170),
    Paint()..color = const Color(0xFFF1F5EC),
  );
  canvas.drawRect(
    const Rect.fromLTWH(100, 1080, 800, 120),
    Paint()..color = const Color(0xFFF8F3E6),
  );

  void draw(
    String text, {
    required double x,
    required double y,
    double size = 22,
    FontWeight weight = FontWeight.w400,
    Color color = const Color(0xFF26332D),
    double maxWidth = 800,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: 'Roboto',
          fontSize: size,
          height: 1.75,
          fontWeight: weight,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: maxWidth);
    painter.paint(canvas, Offset(x, y));
  }

  draw(
    '第三章 动量与冲量',
    x: 100,
    y: 92,
    size: 40,
    weight: FontWeight.w700,
  );
  draw('3.1 动量与冲量的定义', x: 100, y: 185, size: 26, weight: FontWeight.w600);
  const lines = [
    '动量是描述物体运动状态的物理量，等于质量与速度的乘积。',
    '冲量是力与作用时间的乘积，描述力对运动状态的累积影响。',
    '当合外力为恒力时，合外力的冲量等于物体动量的变化。',
    '这一关系称为动量定理，它是牛顿第二定律的积分形式。',
    '动量与动能都能描述运动，但前者是矢量，后者是标量。',
    '在碰撞问题中，系统所受合外力的冲量往往远小于内力冲量。',
    '因此可以近似认为碰撞前后系统的总动量保持不变。',
    '使用动量定理时，需要先规定正方向，再代入带符号的矢量。',
    '若合外力随时间变化，冲量应写成力对时间的积分。',
    '图 3-1 给出了恒力作用下物体的动量随时间的变化关系。',
  ];
  for (var i = 0; i < lines.length; i++) {
    draw(lines[i], x: 100, y: 245 + i * 52, size: 20);
  }
  draw(
    'F Δt = Δp',
    x: 100,
    y: 780,
    size: 24,
    weight: FontWeight.w600,
    color: const Color(0xFF245D4A),
  );
  draw(
    '关键结论：合外力的冲量等于动量的变化，方向同样重要。',
    x: 125,
    y: 870,
    size: 20,
    weight: FontWeight.w600,
    color: const Color(0xFF245D4A),
  );
  draw(
    '计算时先取正方向，再分别写出初、末动量与合外力冲量。',
    x: 125,
    y: 918,
    size: 18,
    color: const Color(0xFF3B4A43),
  );
  draw(
    '例 3-1  质量 2 kg 的物体在 5 N 的恒力作用下由静止开始运动，求 4 s 末的动量。',
    x: 100,
    y: 1100,
    size: 18,
    weight: FontWeight.w600,
    color: const Color(0xFF6B4E16),
  );
  draw(
    '解：冲量 I = FΔt = 20 N·s，故末动量 p = 20 kg·m/s，方向与力相同。',
    x: 100,
    y: 1150,
    size: 17,
    color: const Color(0xFF3B4A43),
  );
  draw('18', x: 480, y: 1320, size: 18, color: const Color(0xFF8A968F));

  final image = await recorder.endRecording().toImage(
    width.toInt(),
    height.toInt(),
  );
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}
