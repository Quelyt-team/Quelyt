import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:local_study/core/local_store.dart';
import 'package:local_study/features/library/data/library_repository.dart';
import 'package:local_study/features/notes/data/notes_repository.dart';
import 'package:local_study/features/notes/models/note_models.dart';
import 'package:local_study/features/notes/notes_controller.dart';
import 'package:local_study/features/notes/ui/notes_page.dart';
import 'package:local_study/ui/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('design preview: notes workspace', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _loadFonts();

    final store = LocalStore.inMemory();
    addTearDown(store.dispose);
    final library = LibraryRepository(store);
    final repository = NotesRepository(store);
    final controller = NotesController(
      store: store,
      repository: repository,
      library: library,
    );
    addTearDown(controller.dispose);
    controller.initialize();
    final study = library.insertFolder(name: '高分子化学', colorValue: 0xFF5B8DEF);
    final reading = library.insertFolder(name: '阅读方法', colorValue: 0xFFE8A23D);
    final tag = library.createTag('考试重点');
    final note = controller.createNote(
      title: '为什么聚合物多以头尾键连为主？',
      body:
          '## 我的理解\n\n头尾键接能让主链更规整，位阻更小，因此是聚合反应的**主要方式**。\n\n'
          '- 头尾连接\n- 头头／尾尾连接较少\n\n> 需要结合第 20 页的链结构图再确认。\n',
      folderId: study.id,
    )!;
    repository.setTags(note.id, {tag.id});
    repository.addSource(
      NoteSource(
        id: '',
        noteId: note.id,
        documentId: 'book',
        documentHash: 'hash',
        page: 20,
        excerpt: '聚合物链的键接方式主要包括头尾键接、头头键接和尾尾键接。',
        title: '高分子化学（第六版）',
        createdAt: DateTime.now(),
      ),
    );
    repository.addQuestion(
      NoteQuestion(
        id: '',
        noteId: note.id,
        text: '支链如何影响结晶？',
        createdAt: DateTime.now(),
      ),
    );
    controller.select(note.id, force: true);
    controller.createNote(
      title: '论文阅读：方法部分的证据链',
      body: '## 研究问题\n\n作者如何排除替代解释？\n\n## 待补\n\n- 对照图 3\n',
      folderId: reading.id,
    );
    controller.createNote(
      title: 'Chapter 4 · 热力学第二定律',
      body: '熵增的条件与可逆过程。\n',
    );
    controller.reload();
    controller.select(note.id, force: true);

    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(Brightness.light),
          home: Scaffold(body: NotesPage(controller: controller)),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 800));
    expect(tester.takeException(), isNull);

    final boundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final out = Directory('build/preview/design')
        ..createSync(recursive: true);
      await File(
        '${out.path}/22-notes-workspace.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
    });
    await tester.tap(find.text('预览'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    final previewBoundary =
        key.currentContext!.findRenderObject() as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await previewBoundary.toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      await File(
        'build/preview/design/23-notes-preview.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
    });  });
}

Future<void> _loadFonts() async {
  if (Platform.isWindows) {
    final fontFile = File(r'C:\Windows\Fonts\msyh.ttc');
    if (fontFile.existsSync()) {
      final bytes = ByteData.sublistView(fontFile.readAsBytesSync());
      for (final family in const [
        'Roboto',
        'Segoe UI',
        'Microsoft YaHei UI',
      ]) {
        final loader = FontLoader(family)..addFont(Future<ByteData>.value(bytes));
        await loader.load();
      }
    }
    final manropeFile = File('assets/brand/Manrope.ttf');
    if (manropeFile.existsSync()) {
      final bytes = ByteData.sublistView(manropeFile.readAsBytesSync());
      final loader = FontLoader('Manrope')..addFont(Future<ByteData>.value(bytes));
      await loader.load();
    }
  }
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await icons.load();
}
