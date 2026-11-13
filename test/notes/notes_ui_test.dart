import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:local_study/core/local_store.dart';
import 'package:local_study/features/library/data/library_repository.dart';
import 'package:local_study/features/notes/data/notes_repository.dart';
import 'package:local_study/features/notes/notes_controller.dart';
import 'package:local_study/features/notes/ui/notes_page.dart';
import 'package:local_study/ui/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('notes page edits and autosaves an independent note', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
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
    controller.createNote(title: '测试笔记', body: '第一行内容');

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Scaffold(body: NotesPage(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('测试笔记'), findsWidgets);
    expect(find.text('第一行内容'), findsWidgets);
    expect(tester.takeException(), isNull);

    final bodyField = find.byType(TextField).last;
    await tester.enterText(bodyField, '第一行内容\n新增的理解');
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pumpAndSettle();
    final note = controller.selected!;
    expect(controller.repository.getNote(note.id)!.body, contains('新增的理解'));
    expect(controller.saveState, 'saved');
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact notes page opens the editor without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
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
    controller.createNote(title: '手机笔记', body: '一段正文');
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Scaffold(body: NotesPage(controller: controller)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('手机笔记'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}