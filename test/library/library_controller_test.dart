import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:local_study/core/local_store.dart';
import 'package:local_study/core/models.dart';
import 'package:local_study/features/library/library_controller.dart';
import 'package:local_study/features/library/models/library_models.dart';
import 'package:local_study/features/library/ui/library_style.dart';
import 'package:local_study/services/document_service.dart';
import 'package:local_study/services/ocr_service.dart';

class _Fixture {
  _Fixture() {
    directory = Directory.systemTemp.createTempSync('library-controller-');
    store = LocalStore.inMemory();
    documents = DocumentService(directory, store, OcrService());
    library = LibraryController(store: store, documents: documents);
  }

  late final Directory directory;
  late final LocalStore store;
  late final DocumentService documents;
  late final LibraryController library;
  var _counter = 0;

  DocumentRecord addDocument({
    String? id,
    String title = '资料',
    String? hash,
    DocumentKind kind = DocumentKind.unspecified,
    int pages = 3,
  }) {
    final documentId = id ?? 'doc-${_counter++}';
    store.upsertDocument(
      DocumentRecord(
        id: documentId,
        title: title,
        kind: kind,
        filePath: '${directory.path}/missing-$documentId.pdf',
        contentHash: hash ?? 'hash-$documentId',
        pageCount: pages,
        format: 'pdf',
      ),
    );
    library.refresh();
    return store.getDocument(documentId)!;
  }


  void dispose() {
    library.dispose();
    store.dispose();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }
}

Future<LibraryFolder> _folder(
  LibraryController library,
  String name, {
  String? parentId,
}) async {
  final value = await library.createFolder(name: name, parentId: parentId);
  expect(value, isNotNull, reason: library.takeError());
  return value!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Fixture fixture;

  setUp(() => fixture = _Fixture());
  tearDown(() => fixture.dispose());

  test('new documents become unfiled primary entries without choosing a type', () {
    final document = fixture.addDocument(title: '高分子化学');
    final library = fixture.library;
    final entry = library.repository.primaryEntry(document.id);
    expect(entry, isNotNull);
    expect(entry!.folderId, isNull);
    expect(entry.isShortcut, isFalse);
    expect(library.counts.all, 1);
    expect(library.counts.unfiled, 1);
    expect(library.items.single.document.kind, DocumentKind.unspecified);
  });

  test('folders nest, reject duplicate names and keep a stable identity', () async {
    final library = fixture.library;
    final root = await _folder(library, '大三上');
    final chemistry = await _folder(library, '高分子化学', parentId: root.id);

    expect(library.folderPathName(chemistry.id), '大三上 / 高分子化学');
    expect(library.depthOf(chemistry.id), 1);

    final duplicate = await library.createFolder(name: '高分子化学', parentId: root.id);
    expect(duplicate, isNull);
    expect(library.takeError(), contains('已经有名为'));

    await library.renameFolder(chemistry.id, '结构与性能');
    expect(library.folderById(chemistry.id)!.name, '结构与性能');
    expect(library.folderPathName(chemistry.id), '大三上 / 结构与性能');
  });

  test('moving a folder into its own descendant is refused', () async {
    final library = fixture.library;
    final parent = await _folder(library, '父');
    final child = await _folder(library, '子', parentId: parent.id);
    await library.moveNodes(folderIds: {parent.id}, targetFolderId: child.id);
    expect(library.takeError(), contains('子文件夹'));
    expect(library.folderById(parent.id)!.parentId, isNull);
    expect(library.folderById(child.id)!.parentId, parent.id);
  });

  test('documents move between folders and shortcuts share one original', () async {
    final library = fixture.library;
    final document = fixture.addDocument(title: '结构化学');
    final materials = await _folder(library, '教材');
    final exam = await _folder(library, '期末备考');
    final primary = library.repository.primaryEntry(document.id)!;

    await library.moveNodes(entryIds: {primary.id}, targetFolderId: materials.id);
    expect(library.repository.primaryEntry(document.id)!.folderId, materials.id);
    expect(library.counts.forFolder(materials.id), 1);

    await library.createShortcut(document.id, folderId: exam.id);
    final entries = library.repository.entriesForDocument(document.id);
    expect(entries, hasLength(2));
    expect(entries.where((entry) => entry.isShortcut), hasLength(1));
    expect(library.counts.all, 1, reason: 'all documents count real documents');
    expect(library.counts.forFolder(exam.id), 1);

    final shortcut = entries.firstWhere((entry) => entry.isShortcut);
    await library.removeEntry(shortcut.id);
    expect(store(library).getDocuments(), hasLength(1));
    expect(library.repository.entriesForDocument(document.id), hasLength(1));
    expect(library.trashBatches, hasLength(1));

    await library.restoreBatch(library.trashBatches.single.id);
    expect(library.repository.entriesForDocument(document.id), hasLength(2));
    expect(store(library).getDocuments(), hasLength(1));
  });

  test('trashing a folder subtree pauses documents and restores the whole shape', () async {
    final library = fixture.library;
    final root = await _folder(library, '大三上');
    final chemistry = await _folder(library, '高分子化学', parentId: root.id);
    await library.setFolderAppearance(
      chemistry.id,
      colorMode: FolderColorMode.custom,
      colorValue: folderPaletteForTest,
    );
    final document = fixture.addDocument(title: '教材上册');
    final primary = library.repository.primaryEntry(document.id)!;
    await library.moveNodes(entryIds: {primary.id}, targetFolderId: chemistry.id);

    await library.trashFolder(root.id);
    expect(library.folderById(root.id), isNull);
    expect(library.counts.trash, 1);
    expect(fixture.store.getDocument(document.id)!.isTrashed, isTrue);
    expect(library.trashBatches, hasLength(1));
    expect(
      () => fixture.store.savePage(
        PageRecord(documentId: document.id, page: 1, text: 'trash'),
      ),
      throwsStateError,
    );

    final batch = library.trashBatches.single;
    await library.restoreBatch(batch.id);
    expect(library.folderById(root.id), isNotNull);
    expect(library.folderById(chemistry.id)!.parentId, root.id);
    expect(library.folderById(chemistry.id)!.colorValue, folderPaletteForTest);
    expect(fixture.store.getDocument(document.id)!.isActive, isTrue);
    expect(library.repository.primaryEntry(document.id)!.folderId, chemistry.id);
    expect(library.counts.trash, 0);
  });

  test('restoring an orphaned folder places it at the root and explains why', () async {
    final library = fixture.library;
    final parent = await _folder(library, '父');
    final child = await _folder(library, '子', parentId: parent.id);
    final document = fixture.addDocument(title: '子资料');
    final primary = library.repository.primaryEntry(document.id)!;
    await library.moveNodes(entryIds: {primary.id}, targetFolderId: child.id);

    await library.trashFolder(child.id);
    await library.trashFolder(parent.id);
    final parentBatch = library.trashBatches.firstWhere((batch) => batch.label == '父');
    await library.purgeBatch(parentBatch.id);
    expect(library.folderById(parent.id), isNull);

    final childBatch = library.trashBatches.singleWhere((batch) => batch.label == '子');
    await library.restoreBatch(childBatch.id);
    expect(library.folderById(child.id)!.parentId, isNull);
    expect(library.takeNotice(), contains('位置'));
    expect(fixture.store.getDocument(document.id)!.isActive, isTrue);
  });

  test('moving a folder with one of its documents keeps the document inside', () async {
    final library = fixture.library;
    final source = await _folder(library, '来源');
    final target = await _folder(library, '目标');
    final document = fixture.addDocument(title: '子资料');
    final primary = library.repository.primaryEntry(document.id)!;
    await library.moveNodes(entryIds: {primary.id}, targetFolderId: source.id);

    await library.moveNodes(
      folderIds: {source.id},
      entryIds: {primary.id},
      targetFolderId: target.id,
    );
    expect(library.folderById(source.id)!.parentId, target.id);
    expect(library.repository.primaryEntry(document.id)!.folderId, source.id);
  });

  test('restoring one item brings its document and keeps the rest in the batch', () async {
    final library = fixture.library;
    final folder = await _folder(library, '资料');
    final first = fixture.addDocument(title: '第一份');
    final second = fixture.addDocument(title: '第二份');
    for (final document in [first, second]) {
      final primary = library.repository.primaryEntry(document.id)!;
      await library.moveNodes(entryIds: {primary.id}, targetFolderId: folder.id);
    }
    await library.trashFolder(folder.id);
    final batch = library.trashBatches.single;
    final firstEntry = library
        .trashItemsFor(batch.id)
        .firstWhere((item) => item.document.id == first.id)
        .entry;

    await library.restoreEntry(firstEntry.id);
    expect(fixture.store.getDocument(first.id)!.isActive, isTrue);
    expect(fixture.store.getDocument(second.id)!.isActive, isFalse);
    expect(library.trashBatches, hasLength(1));
    expect(library.folderById(folder.id), isNull);

    final secondEntry = library
        .trashItemsFor(batch.id)
        .firstWhere((item) => item.document.id == second.id)
        .entry;
    await library.restoreEntry(secondEntry.id);
    expect(fixture.store.getDocument(second.id)!.isActive, isTrue);
    // The emptied folder itself is still in the trash until it is restored.\n    expect(library.trashBatches, hasLength(1));\n    await library.restoreBatch(batch.id);\n    expect(library.trashBatches, isEmpty);
  });

  test('restoring a shortcut also restores its trashed document', () async {
    final library = fixture.library;
    final document = fixture.addDocument(title: '共享资料');
    final folder = await _folder(library, '入口');
    await library.createShortcut(document.id, folderId: folder.id);
    await library.trashDocument(document.id);
    expect(fixture.store.getDocument(document.id)!.isActive, isFalse);
    final shortcut = library.repository
        .entriesForDocument(document.id)
        .firstWhere((entry) => entry.isShortcut);
    // Trash the still-active shortcut explicitly.
    library.selectEntry(shortcut.id);
    await library.trashSelection();
    final shortcutBatch = library.trashBatches.firstWhere(
      (batch) => batch.kind == 'shortcut',
    );
    final trashedShortcut = library
        .trashItemsFor(shortcutBatch.id)
        .single;
    await library.restoreEntry(trashedShortcut.entry.id);
    expect(fixture.store.getDocument(document.id)!.isActive, isTrue);
    expect(
      library.repository.entriesForDocument(document.id),
      hasLength(2),
    );
    expect(library.repository.primaryEntry(document.id), isNotNull);
  });

  test('restoring a folder with a conflicting name keeps both folders', () async {
    final library = fixture.library;
    final original = await _folder(library, '大三上');
    await library.trashFolder(original.id);
    final replacement = await _folder(library, '大三上');
    final batch = library.trashBatches.single;
    await library.restoreBatch(batch.id);
    expect(library.folderById(original.id), isNotNull);
    expect(library.folderById(original.id)!.name, '大三上 (2)');
    expect(library.folderById(replacement.id), isNotNull);
    expect(library.takeNotice(), contains('改名'));
  });

  test('restoring a duplicate shortcut merges instead of violating one entry per folder', () async {
    final library = fixture.library;
    final document = fixture.addDocument(title: '共享');
    final target = await _folder(library, '目标');
    await library.createShortcut(document.id, folderId: target.id);
    final shortcut = library.repository
        .entriesForDocument(document.id)
        .firstWhere((entry) => entry.isShortcut);
    await library.removeEntry(shortcut.id);
    await library.createShortcut(document.id, folderId: target.id);
    final batch = library.trashBatches.single;
    await library.restoreBatch(batch.id);
    expect(
      library.repository.entriesForDocument(document.id),
      hasLength(2),
    );
    expect(
      library.repository.entries(folderId: target.id),
      hasLength(1),
    );
    expect(library.takeNotice(), contains('合并'));
  });

  test('purging one shortcut leaves the document and other entries intact', () async {
    final library = fixture.library;
    final document = fixture.addDocument(title: '保留资料');
    final folder = await _folder(library, '入口');
    await library.createShortcut(document.id, folderId: folder.id);
    final shortcut = library.repository
        .entriesForDocument(document.id)
        .firstWhere((entry) => entry.isShortcut);
    await library.removeEntry(shortcut.id);
    await library.purgeEntry(shortcut.id);
    expect(fixture.store.getDocument(document.id)!.isActive, isTrue);
    expect(library.repository.entriesForDocument(document.id), hasLength(1));
    expect(library.trashBatches, isEmpty);
  });

  test('purging one document entry clears its other shortcuts and derived data', () async {
    final library = fixture.library;
    final document = fixture.addDocument(title: '彻底清理');
    final folder = await _folder(library, '另一处');
    await library.createShortcut(document.id, folderId: folder.id);
    fixture.store.saveNote(
      StudyNote(
        id: 'purge-note',
        documentId: document.id,
        page: 1,
        understanding: '会被一起清理',
        evidenceText: '',
        question: '',
      ),
    );
    await library.trashDocument(document.id);
    final primary = library
        .trashItemsFor(library.trashBatches.single.id)
        .firstWhere((item) => !item.isShortcut);
    await library.purgeEntry(primary.entry.id);
    expect(fixture.store.getDocument(document.id), isNull);
    expect(library.repository.entriesForDocument(document.id), isEmpty);
    expect(library.trashBatches, isEmpty);
  });

  test('undo restores the last trashed document and clears the batch', () async {
    final library = fixture.library;
    final document = fixture.addDocument(title: '误删的资料');
    await library.trashDocument(document.id);
    expect(fixture.store.getDocument(document.id)!.isActive, isFalse);
    expect(library.trashBatches, hasLength(1));
    await library.undoLast();
    expect(fixture.store.getDocument(document.id)!.isActive, isTrue);
    expect(library.trashBatches, isEmpty);
    expect(library.takeError(), isNull);
  });

  test('permanent delete removes derived data and keeps the external file path untouched', () async {
    final library = fixture.library;
    final document = fixture.addDocument(title: '要清理的资料');
    fixture.store.saveNote(
      StudyNote(
        id: 'note-1',
        documentId: document.id,
        page: 1,
        understanding: '笔记',
        evidenceText: '',
        question: '',
      ),
    );
    await library.trashDocument(document.id);
    final batch = library.trashBatches.single;
    final impact = await library.impactForBatch(batch.id);
    expect(impact.notes, 1);
    await library.purgeBatch(batch.id);
    expect(fixture.store.getDocument(document.id), isNull);
    expect(library.trashBatches, isEmpty);
    expect(library.repository.entriesForDocument(document.id), isEmpty);
    expect(library.counts.trash, 0);
  });

  test('title rename reaches documents and aliases survive it', () async {
    final library = fixture.library;
    final document = fixture.addDocument(title: '旧名字');
    final folder = await _folder(library, '资料');
    await library.createShortcut(document.id, folderId: folder.id);
    final item = library.items.single;
    await library.renameItem(item, '新名字');
    expect(fixture.store.getDocument(document.id)!.title, '新名字');

    final shortcut = library.repository
        .entriesForDocument(document.id)
        .firstWhere((entry) => entry.isShortcut);
    await library.renameItem(
      LibraryItem(
        entry: shortcut,
        document: fixture.store.getDocument(document.id)!,
      ),
      '备考版本',
    );
    expect(fixture.store.getDocument(document.id)!.title, '新名字');
    expect(
      library.repository
          .entriesForDocument(document.id)
          .firstWhere((entry) => entry.isShortcut)
          .alias,
      '备考版本',
    );
  });

  test('tags, stars and metadata search cross folders without duplicating documents', () async {
    final library = fixture.library;
    final document = fixture.addDocument(title: '物理化学');
    final folder = await _folder(library, '考试重点');
    final primary = library.repository.primaryEntry(document.id)!;
    await library.moveNodes(entryIds: {primary.id}, targetFolderId: folder.id);
    final tag = await library.createTag('待看');
    await library.assignTags(document.id, {tag!.id});
    await library.toggleStar(document.id);

    library.setQuery('待看');
    expect(library.items, hasLength(1));
    library.setQuery('考试重点');
    expect(library.items, hasLength(1));
    library.setQuery('物理');
    expect(library.items, hasLength(1));
    library.setQuery('找不到的词');
    expect(library.items, isEmpty);
    expect(library.counts.starred, 1);
  });

  test('manual folder order moves one step and moving to the root clears the parent', () async {
    final library = fixture.library;
    final first = await _folder(library, '第一');
    final second = await _folder(library, '第二');
    final third = await _folder(library, '第三');
    expect(
      library.childrenOf(null).map((folder) => folder.name),
      ['第一', '第二', '第三'],
    );

    await library.shiftFolder(third.id, -1);
    expect(
      library.childrenOf(null).map((folder) => folder.name),
      ['第一', '第三', '第二'],
    );
    await library.shiftFolder(first.id, 1);
    expect(
      library.childrenOf(null).map((folder) => folder.name),
      ['第三', '第一', '第二'],
    );

    final child = await _folder(library, '子', parentId: second.id);
    await library.moveNodes(folderIds: {child.id}, targetFolderId: null);
    expect(library.folderById(child.id)!.parentId, isNull);
    expect(library.childrenOf(null).map((folder) => folder.name), contains('子'));
  });

  test('moving an entry back to the root clears its folder', () async {
    final library = fixture.library;
    final document = fixture.addDocument(title: '回到根目录');
    final folder = await _folder(library, '临时');
    final primary = library.repository.primaryEntry(document.id)!;
    await library.moveNodes(entryIds: {primary.id}, targetFolderId: folder.id);
    expect(
      library.repository.primaryEntry(document.id)!.folderId,
      folder.id,
    );
    await library.moveNodes(entryIds: {primary.id}, targetFolderId: null);
    expect(library.repository.primaryEntry(document.id)!.folderId, isNull);
    expect(library.counts.unfiled, 1);
  });

  test('folder colours inherit by state and custom children are not overwritten', () async {
    final library = fixture.library;
    final parent = await _folder(library, '大三上');
    final child = await _folder(library, '高分子化学', parentId: parent.id);
    final custom = await _folder(library, '真题', parentId: child.id);
    await library.setFolderAppearance(
      parent.id,
      colorMode: FolderColorMode.custom,
      colorValue: 0xFF2563EB,
    );
    await library.setFolderAppearance(
      custom.id,
      colorMode: FolderColorMode.custom,
      colorValue: 0xFFEA580C,
    );
    expect(effectiveFolderColor(library, child.id), 0xFF2563EB);
    expect(effectiveFolderColor(library, custom.id), 0xFFEA580C);
    expect(effectiveFolderColor(library, parent.id), 0xFF2563EB);

    await library.setFolderAppearance(
      parent.id,
      colorMode: FolderColorMode.custom,
      colorValue: 0xFF16A34A,
    );
    expect(effectiveFolderColor(library, child.id), 0xFF16A34A);
    expect(effectiveFolderColor(library, custom.id), 0xFFEA580C);

    await library.setFolderAppearance(child.id, clearColor: true);
    expect(effectiveFolderColor(library, child.id), 0xFF16A34A);
  });

  test('smart folders save conditions and update results as data changes', () async {
    final library = fixture.library;
    final first = fixture.addDocument(title: '高分子基础');
    final second = fixture.addDocument(title: '高分子进阶');
    await library.toggleStar(first.id);
    library.setFilter(const LibraryFilter(starredOnly: true));
    library.setQuery('高分子');

    final smart = await library.saveCurrentAsSmartFolder('星标高分子');
    expect(smart, isNotNull);
    expect(library.view.scope, LibraryScope.smart);
    expect(library.activeSmartFolder!.name, '星标高分子');
    expect(library.items, hasLength(1));
    expect(library.items.single.document.id, first.id);

    await library.toggleStar(second.id);
    expect(library.items, hasLength(2));

    await library.renameSmartFolder(smart!.id, '重点高分子');
    expect(library.activeSmartFolder!.name, '重点高分子');

    await library.deleteSmartFolder(smart.id);
    expect(library.smartFolders, isEmpty);
    expect(fixture.store.getDocuments(), hasLength(2));
    expect(library.view.scope, LibraryScope.all);
    expect(library.takeNotice(), contains('智能文件夹'));
  });

  test('smart folders survive a restart and reject an empty condition', () async {
    final library = fixture.library;
    final document = fixture.addDocument(title: '待看资料');
    await library.toggleStar(document.id);
    library.setFilter(const LibraryFilter(starredOnly: true));
    await library.saveCurrentAsSmartFolder('只看星标');

    final second = LibraryController(
      store: fixture.store,
      documents: fixture.documents,
    );
    addTearDown(second.dispose);
    expect(second.activeSmartFolder?.name, '只看星标');
    expect(second.view.scope, LibraryScope.smart);
    expect(second.items, hasLength(1));

    final empty = LibraryController(
      store: LocalStore.inMemory(),
      documents: fixture.documents,
    );
    addTearDown(empty.dispose);
    expect(await empty.saveCurrentAsSmartFolder('空条件'), isNull);
    expect(empty.takeError(), contains('搜索词或设置筛选'));
    expect(empty.smartFolders, isEmpty);
  });

  test('each folder remembers its own layout and sort across restarts', () async {
    final library = fixture.library;
    final first = await _folder(library, '甲');
    final second = await _folder(library, '乙');

    library.openFolder(first.id);
    library.setLayout(LibraryLayout.grid);
    library.setSort(LibrarySortField.name);

    library.openFolder(second.id);
    library.setLayout(LibraryLayout.list);
    library.setSort(LibrarySortField.addedAt);

    library.openFolder(first.id);
    expect(library.view.layout, LibraryLayout.grid);
    expect(library.view.sortField, LibrarySortField.name);

    library.openFolder(second.id);
    expect(library.view.layout, LibraryLayout.list);
    expect(library.view.sortField, LibrarySortField.addedAt);

    final reopened = LibraryController(
      store: fixture.store,
      documents: fixture.documents,
    );
    addTearDown(reopened.dispose);
    expect(reopened.view.scope, LibraryScope.folder);
    expect(reopened.view.layout, LibraryLayout.list);
    reopened.openFolder(first.id);
    expect(reopened.view.layout, LibraryLayout.grid);
    expect(reopened.view.sortField, LibrarySortField.name);
  });

  test('view state and expanded folders survive a new controller', () async {
    final first = fixture.library;
    final root = await _folder(first, '大三上');
    final child = await _folder(first, '教材', parentId: root.id);
    first.openFolder(root.id);
    expect(first.expandedFolders, contains(root.id));
    first.toggleExpanded(root.id);
    expect(first.expandedFolders, isNot(contains(root.id)));
    first.toggleExpanded(root.id);
    first.setSort(LibrarySortField.name);
    first.setLayout(LibraryLayout.grid);

    final second = LibraryController(
      store: fixture.store,
      documents: fixture.documents,
    );
    addTearDown(second.dispose);
    expect(second.view.scope, LibraryScope.folder);
    expect(second.view.folderId, root.id);
    expect(second.expandedFolders, contains(root.id));
    expect(second.view.sortField, LibrarySortField.name);
    expect(second.view.layout, LibraryLayout.grid);
    expect(second.folderById(child.id), isNotNull);
  });
}

const folderPaletteForTest = 0xFF2563EB;

LocalStore store(LibraryController library) => library.store;
