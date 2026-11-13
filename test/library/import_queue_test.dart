import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:local_study/core/local_store.dart';
import 'package:local_study/features/library/import/import_models.dart';
import 'package:local_study/features/library/ui/import_actions.dart';
import 'package:local_study/features/library/library_controller.dart';
import 'package:local_study/services/document_service.dart';
import 'package:local_study/services/ocr_service.dart';

Future<Uint8List> _png(int red, int green, int blue) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 8, 8),
    ui.Paint()..color = ui.Color.fromARGB(255, red, green, blue),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(8, 8);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late LocalStore store;
  late DocumentService documents;
  late LibraryController library;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('library_import_');
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

  Future<String> writeImage(String name, int red) async {
    final file = File(p.join(directory.path, name));
    await file.writeAsBytes(await _png(red, 20, 30));
    return file.path;
  }

  test('operating-system drop paths are deduplicated and skip empty paths', () {
    expect(
      droppedFilePaths([
        DropItemFile(r'C:\资料\a.pdf'),
        DropItemFile(r'C:\资料\a.pdf'),
        DropItemDirectory(r'C:\资料\课程', const []),
        DropItemFile(''),
      ]),
      [r'C:\资料\a.pdf', r'C:\资料\课程'],
    );
  });

  test('multiple files import without choosing a type and land in the folder', () async {
    final folder = await library.createFolder(name: '教材');
    library.openFolder(folder!.id);
    final first = await writeImage('one.png', 200);
    final second = await writeImage('two.png', 100);
    final batch = await library.queue.enqueueFiles([
      first,
      second,
    ], targetFolderId: folder.id);
    await library.queue.waitUntilIdle();

    expect(batch.items, hasLength(2));
    expect(
      batch.items.map((item) => item.status),
      everyElement(ImportItemStatus.imported),
    );
    expect(store.getDocuments(includeTrashed: true), hasLength(2));
    final entries = library.repository.entries(folderId: folder.id);
    expect(entries, hasLength(2));
    expect(library.counts.forFolder(folder.id), 2);
    for (final document in store.getDocuments()) {
      expect(document.originalName, isNotEmpty);
      expect(document.format, 'png');
      expect(document.sizeBytes, greaterThan(0));
      expect(document.isActive, isTrue);
      expect(document.filePath, isNot(startsWith('/one')));
      expect(File(document.filePath).existsSync(), isTrue);
    }
    // The user's own files stay where they were.
    expect(File(first).existsSync(), isTrue);
    expect(File(second).existsSync(), isTrue);
  });

  test('identical content in the same folder is reported as existing once', () async {
    final folder = await library.createFolder(name: '资料');
    final path = await writeImage('same.png', 180);
    final batch = await library.queue.enqueueFiles([
      path,
      path,
    ], targetFolderId: folder!.id);
    await library.queue.waitUntilIdle();

    expect(batch.items, hasLength(1), reason: 'duplicate source paths collapse');
    expect(batch.items.single.status, ImportItemStatus.imported);
    expect(store.getDocuments(), hasLength(1));

    final again = await library.queue.enqueueFiles([
      path,
    ], targetFolderId: folder.id);
    await library.queue.waitUntilIdle();
    expect(again.items.single.status, ImportItemStatus.existing);
    expect(again.items.single.message, contains('已存在'));
    expect(store.getDocuments(), hasLength(1));
    expect(library.repository.entries(folderId: folder.id), hasLength(1));
  });

  test('identical content in another folder becomes a shortcut', () async {
    final first = await library.createFolder(name: '教材');
    final second = await library.createFolder(name: '期末备考');
    final path = await writeImage('book.png', 150);
    await library.queue.enqueueFiles([path], targetFolderId: first!.id);
    await library.queue.waitUntilIdle();

    final batch = await library.queue.enqueueFiles([
      path,
    ], targetFolderId: second!.id);
    await library.queue.waitUntilIdle();
    expect(batch.items.single.status, ImportItemStatus.existing);
    expect(batch.items.single.message, contains('快捷方式'));
    expect(store.getDocuments(), hasLength(1));
    final entries = library.repository.entriesForDocument(
      store.getDocuments().single.id,
    );
    expect(entries, hasLength(2));
    expect(entries.where((entry) => entry.isShortcut), hasLength(1));
  });

  test('a dropped directory keeps its structure and lists unsupported files', () async {
    final source = Directory(p.join(directory.path, '课程资料'));
    Directory(p.join(source.path, '第一章')).createSync(recursive: true);
    File(p.join(source.path, '封面.png'))
        .writeAsBytesSync(await _png(10, 120, 200));
    File(p.join(source.path, '第一章', '讲义.png'))
        .writeAsBytesSync(await _png(20, 160, 90));
    File(p.join(source.path, '第一章', '说明.txt'))
        .writeAsStringSync('not supported');
    Directory(p.join(source.path, '空目录')).createSync();

    final batch = await library.queue.enqueueDirectory(source.path);
    await library.queue.waitUntilIdle();

    expect(batch.rootFolderName, '课程资料');
    final root = library.folders.firstWhere((folder) => folder.name == '课程资料');
    final chapter = library.folders.firstWhere(
      (folder) => folder.name == '第一章' && folder.parentId == root.id,
    );
    expect(library.repository.entries(folderId: root.id), hasLength(1));
    expect(library.repository.entries(folderId: chapter.id), hasLength(1));
    expect(store.getDocuments(), hasLength(2));
    expect(batch.imported, 2);
    expect(batch.failed, 1);
    final unsupported = batch.items.firstWhere(
      (item) => item.extension == '.txt',
    );
    expect(unsupported.status, ImportItemStatus.unsupported);
    expect(unsupported.message, contains('不支持'));
    expect(library.queue.failedCount, 1);
  });

  test('directory name conflicts create a new folder instead of merging', () async {
    final target = await library.createFolder(name: '课程资料');
    await library.createFolder(name: '课程资料', parentId: target!.id);
    final source = Directory(p.join(directory.path, '课程资料'));
    source.createSync(recursive: true);
    File(p.join(source.path, 'a.png'))
        .writeAsBytesSync(await _png(30, 30, 200));

    final batch = await library.queue.enqueueDirectory(
      source.path,
      targetFolderId: target.id,
    );
    await library.queue.waitUntilIdle();
    expect(batch.rootFolderName, '课程资料 (2)');
    final children = library.childrenOf(target.id);
    expect(children.map((folder) => folder.name), contains('课程资料 (2)'));
  });

  test('queue journal restores completed batches and interrupted items', () async {
    final path = await writeImage('journal.png', 90);
    await library.queue.enqueueFiles([path]);
    await library.queue.waitUntilIdle();
    expect(library.queue.batches, hasLength(1));

    final second = LibraryController(store: store, documents: documents);
    addTearDown(second.dispose);
    await second.queue.restoreJournal();
    expect(second.queue.batches, hasLength(1));
    expect(second.queue.batches.single.items.single.status, ImportItemStatus.imported);
    expect(second.queue.importedCount, 1);
  });
}
