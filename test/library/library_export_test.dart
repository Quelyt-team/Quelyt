import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:local_study/core/local_store.dart';
import 'package:local_study/core/models.dart';
import 'package:local_study/features/library/library_controller.dart';
import 'package:local_study/services/document_service.dart';
import 'package:local_study/services/ocr_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late LocalStore store;
  late DocumentService documents;
  late LibraryController library;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('library_export_');
    store = LocalStore.inMemory();
    documents = DocumentService(
      Directory(p.join(directory.path, 'app')),
      store,
      OcrService(),
    );
    library = LibraryController(store: store, documents: documents);
  });

  tearDown(() {
    library.dispose();
    store.dispose();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  Future<DocumentRecord> addDocument(String title, {String content = 'pdf'}) async {
    final file = File(p.join(directory.path, '${title.hashCode}.pdf'));
    await file.writeAsString(content);
    final document = DocumentRecord(
      id: 'doc-${title.hashCode}',
      title: title,
      kind: DocumentKind.unspecified,
      filePath: file.path,
      contentHash: 'hash-${title.hashCode}',
      pageCount: 2,
      format: 'pdf',
      originalName: '$title.pdf',
    );
    store.upsertDocument(document);
    library.refresh();
    return store.getDocument(document.id)!;
  }

  test('exports the selected originals with their display names', () async {
    final document = await addDocument('结构化学');
    final destination = Directory(p.join(directory.path, 'out'))..createSync();
    library.selectEntry(library.repository.primaryEntry(document.id)!.id);

    final report = await library.exportSelection(destination.path);
    expect(report, isNotNull);
    expect(report!.exported, 1);
    expect(report.failures, isEmpty);
    final exported = File(p.join(destination.path, '结构化学.pdf'));
    expect(exported.existsSync(), isTrue);
    expect(await exported.readAsString(), 'pdf');
    // The managed copy remains in place.
    expect(File(document.filePath).existsSync(), isTrue);
  });

  test('name conflicts and Windows-reserved names are resolved, never overwritten', () async {
    await addDocument('同名');
    final secondFile = File(p.join(directory.path, 'second.pdf'))
      ..writeAsStringSync('second');
    final second = DocumentRecord(
      id: 'second',
      title: 'CON',
      kind: DocumentKind.unspecified,
      filePath: secondFile.path,
      contentHash: 'hash-second',
      pageCount: 2,
      format: 'pdf',
    );
    store.upsertDocument(second);
    library.refresh();
    final destination = Directory(p.join(directory.path, 'out'))..createSync();
    File(p.join(destination.path, '同名.pdf')).writeAsStringSync('existing');

    library.selectAllVisible();
    final report = await library.exportSelection(destination.path);
    expect(report, isNotNull);
    expect(report!.exported, 2);
    expect(report.renamed, isNotEmpty);
    expect(
      File(p.join(destination.path, '同名.pdf')).readAsStringSync(),
      'existing',
      reason: 'an existing file is never overwritten by export',
    );
    expect(File(p.join(destination.path, '同名 (2).pdf')).existsSync(), isTrue);
    expect(File(p.join(destination.path, 'CON_.pdf')).existsSync(), isTrue);
  });

  test('folder export mirrors the tree and skips duplicate shortcut copies', () async {
    final root = (await library.createFolder(name: '大三上'))!;
    final child = (await library.createFolder(
      name: '高分子化学',
      parentId: root.id,
    ))!;
    final document = await addDocument('教材');
    final primary = library.repository.primaryEntry(document.id)!;
    await library.moveNodes(entryIds: {primary.id}, targetFolderId: child.id);
    await library.createShortcut(document.id, folderId: root.id);

    final destination = Directory(p.join(directory.path, 'out'))..createSync();
    final report = await library.exportFolderTo(root.id, destination.path);
    expect(report, isNotNull);
    expect(report!.exported, 1);
    expect(report.skippedShortcuts, 1);
    expect(
      File(
        p.join(destination.path, '大三上', '高分子化学', '教材.pdf'),
      ).existsSync(),
      isTrue,
    );
  });

  test('the managed directory cannot be used as an export destination', () async {
    await addDocument('资料');
    library.selectAllVisible();
    final report = await library.exportSelection(documents.directory.path);
    expect(report, isNull);
    expect(library.takeError(), contains('托管目录'));
  });
}
