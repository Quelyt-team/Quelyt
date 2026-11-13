import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'package:local_study/core/local_store.dart';
import 'package:local_study/core/models.dart';
import 'package:local_study/app_controller.dart';
import 'package:local_study/features/library/library_controller.dart';
import 'package:local_study/features/library/services/library_backup_service.dart';
import 'package:local_study/services/document_service.dart';
import 'package:local_study/services/ocr_service.dart';

class _Library {
  _Library(this.root) {
    store = LocalStore.open(root);
    documents = DocumentService(Directory(root), store, OcrService());
    library = LibraryController(store: store, documents: documents);
  }

  final String root;
  late final LocalStore store;
  late final DocumentService documents;
  late final LibraryController library;

  DocumentRecord addDocument(String id, String title, {String content = 'pdf'}) {
    final directory = Directory(p.join(root, 'documents', id))
      ..createSync(recursive: true);
    final file = File(p.join(directory.path, 'original.pdf'))
      ..writeAsStringSync(content);
    final hash = sha256.convert(utf8.encode(content)).toString();
    final document = DocumentRecord(
      id: id,
      title: title,
      kind: DocumentKind.unspecified,
      filePath: file.path,
      contentHash: hash,
      pageCount: 2,
      format: 'pdf',
      originalName: '$title.pdf',
      sizeBytes: content.length,
    );
    store.importDocument(document, [
      PageRecord(
        documentId: id,
        page: 1,
        status: PageStatus.ready,
        text: content,
      ),
      PageRecord(documentId: id, page: 2, status: PageStatus.pending),
    ]);
    library.refresh();
    return store.getDocument(id)!;
  }

  void close() {
    library.dispose();
    store.dispose();
  }
}

Future<void> _copyTree(Directory source, Directory target) async {
  await target.create(recursive: true);
  await for (final entity in source.list(recursive: false)) {
    final name = p.basename(entity.path);
    if (entity is Directory) {
      await _copyTree(entity, Directory(p.join(target.path, name)));
    } else if (entity is File) {
      await entity.copy(p.join(target.path, name));
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late _Library library;
  late Directory backups;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('library_backup_');
    library = _Library(p.join(temp.path, 'library-a'));
    backups = Directory(p.join(temp.path, 'backups'))..createSync();
  });

  tearDown(() {
    try {
      library.close();
    } catch (_) {
      /* already closed by a restore test */
    }
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<BackupReport> createBackup({bool includeTrash = true}) async {
    final service = LibraryBackupService(
      store: library.store,
      documents: library.documents,
    );
    return service.create(backups.path, includeTrash: includeTrash);
  }

  Future<void> addRepresentativeContent() async {
    final book = library.addDocument('book', '结构化学', content: 'book-content');
    final paper = library.addDocument('paper', '论文', content: 'paper-content');
    final folder = await library.library.createFolder(name: '大三上');
    final exam = await library.library.createFolder(name: '期末备考');
    final primary = library.library.repository.primaryEntry(book.id)!;
    await library.library.moveNodes(
      entryIds: {primary.id},
      targetFolderId: folder!.id,
    );
    await library.library.createShortcut(book.id, folderId: exam!.id);
    final tag = await library.library.createTag('考试重点');
    await library.library.assignTags(book.id, {tag!.id});
    await library.library.toggleStar(paper.id);
    library.store.saveNote(
      StudyNote(
        id: 'note-book',
        documentId: book.id,
        page: 1,
        understanding: '笔记随备份恢复',
        evidenceText: 'book-content',
        question: '',
      ),
    );
    library.library.refresh();
  }

  test('backup contains a consistent database, originals and hashes', () async {
    await addRepresentativeContent();
    final report = await createBackup();
    expect(report.documents, 2);
    expect(report.bytes, greaterThan(0));
    expect(report.warnings, isEmpty);
    final validation = await LibraryBackupService.validate(report.path);
    expect(validation.ok, isTrue, reason: validation.errors.join('；'));
    expect(validation.schemaVersion, LocalStore.currentSchemaVersion);
    expect(validation.documents, 2);
    expect(
      File(p.join(report.path, LibraryBackupService.manifestName)).existsSync(),
      isTrue,
    );
    expect(
      Directory(p.join(report.path, 'originals', 'book')).existsSync(),
      isTrue,
    );
    final db = sqlite3.open(
      p.join(report.path, LibraryBackupService.databaseName),
      mode: OpenMode.readOnly,
    );
    addTearDown(db.close);
    expect(db.select('PRAGMA integrity_check').first.values.first, 'ok');
    expect(db.select('SELECT COUNT(*) FROM documents').first.values.first, 2);
    // API keys and transient delete intents never enter a backup.
    expect(
      db
          .select("SELECT key FROM settings WHERE key LIKE 'pending-delete:%'")
          .isEmpty,
      isTrue,
    );
  });

  test('restore replaces the library and rebuilds paths on another directory', () async {
    await addRepresentativeContent();
    library.library.refresh();
    expect(library.library.counts.all, 2);
    final report = await createBackup();
    final targetRoot = p.join(temp.path, 'library-b');
    final prepared = await LibraryBackupService.prepareRestore(
      report.path,
      targetRoot,
    );
    expect(prepared.ok, isTrue);

    library.close();
    final result = await LibraryBackupService.applyPendingRestore(targetRoot);
    expect(result, isNotNull);
    expect(result!.applied, isTrue, reason: result.error);

    final restored = _Library(targetRoot);
    addTearDown(restored.close);
    await restored.documents.repairManagedPaths();
    restored.library.refresh();
    expect(restored.store.getDocuments(includeTrashed: true), hasLength(2));
    expect(restored.library.counts.all, 2);
    expect(
      restored.library.folderPathName(
        restored.library.repository.primaryEntry('book')!.folderId,
      ),
      contains('大三上'),
    );
    expect(restored.store.getNotes('book').single.understanding, '笔记随备份恢复');
    expect(restored.store.getDocuments().firstWhere((d) => d.id == 'paper').starred, isTrue);
    expect(
      restored.library.tagIdsByDocument['book'],
      contains(restored.library.tags.single.id),
    );
    expect(
      restored.library.repository.entriesForDocument('book'),
      hasLength(2),
    );
    final book = restored.store.getDocument('book')!;
    expect(p.isWithin(targetRoot, book.filePath), isTrue);
    expect(File(book.filePath).readAsStringSync(), 'book-content');
    final paper = restored.store.getDocument('paper')!;
    expect(File(paper.filePath).readAsStringSync(), 'paper-content');
    expect(restored.library.counts.trash, 0);
    expect(result.preRestorePath, isNotNull);
    expect(Directory(result.preRestorePath!).existsSync(), isTrue);
  });

  test('trash can be excluded from a backup', () async {
    final kept = library.addDocument('kept', '保留', content: 'kept');
    final trashed = library.addDocument('trashed', '回收站', content: 'gone');
    await library.library.trashDocument(trashed.id);
    expect(library.store.getDocument(trashed.id)!.isActive, isFalse);
    final report = await createBackup(includeTrash: false);
    final validation = await LibraryBackupService.validate(report.path);
    expect(validation.ok, isTrue, reason: validation.errors.join('；'));
    expect(validation.documents, 1);

    final targetRoot = p.join(temp.path, 'library-c');
    await LibraryBackupService.prepareRestore(report.path, targetRoot);
    library.close();
    final result = await LibraryBackupService.applyPendingRestore(targetRoot);
    expect(result!.applied, isTrue, reason: result.error);
    final restored = _Library(targetRoot);
    addTearDown(restored.close);
    await restored.documents.repairManagedPaths();
    expect(restored.store.getDocuments(includeTrashed: true), hasLength(1));
    expect(restored.store.getDocument(kept.id), isNotNull);
    expect(restored.store.getDocument(trashed.id), isNull);
    expect(restored.library.counts.trash, 0);
  });

  test('corrupt files are rejected before the live library changes', () async {
    await addRepresentativeContent();
    final report = await createBackup();
    final tampered = Directory(p.join(temp.path, 'tampered'));
    await _copyTree(Directory(report.path), tampered);
    final original = File(
      p.join(tampered.path, 'originals', 'book', 'original.pdf'),
    );
    await original.writeAsString('not-the-same-bytes');
    final validation = await LibraryBackupService.validate(tampered.path);
    expect(validation.ok, isFalse);
    expect(validation.errors.join('；'), contains('校验和不匹配'));

    expect(
      () => LibraryBackupService.prepareRestore(
        tampered.path,
        p.join(temp.path, 'library-d'),
      ),
      throwsA(isA<LibraryBackupException>()),
    );
    // The live library is still readable and unchanged.
    expect(library.store.getDocuments(), hasLength(2));
    expect(library.library.counts.all, 2);
  });

  test('a backup from a newer app version is refused', () async {
    await addRepresentativeContent();
    final report = await createBackup();
    final tampered = Directory(p.join(temp.path, 'newer'));
    await _copyTree(Directory(report.path), tampered);
    final databasePath = p.join(
      tampered.path,
      LibraryBackupService.databaseName,
    );
    final db = sqlite3.open(databasePath);
    db.execute('PRAGMA user_version = 99');
    db.close();
    final manifestFile = File(
      p.join(tampered.path, LibraryBackupService.manifestName),
    );
    final manifest = Map<String, dynamic>.from(
      jsonDecode(await manifestFile.readAsString()) as Map,
    );
    final hash = (await sha256.bind(File(databasePath).openRead()).first)
        .toString();
    manifest['database'] = {
      'relativePath': LibraryBackupService.databaseName,
      'sha256': hash,
      'size': await File(databasePath).length(),
    };
    await manifestFile.writeAsString(jsonEncode(manifest));
    final validation = await LibraryBackupService.validate(tampered.path);
    expect(validation.ok, isFalse);
    expect(validation.errors.join('；'), contains('更新'));
  });

  test('startup applies a prepared restore before opening the database', () async {
    await addRepresentativeContent();
    final report = await createBackup();
    final targetRoot = p.join(temp.path, 'library-f');
    await LibraryBackupService.prepareRestore(report.path, targetRoot);
    library.close();

    final study = await StudyController.create(
      dataDirectory: Directory(targetRoot),
    );
    addTearDown(() async {
      await study.shutdown();
      study.dispose();
    });
    expect(study.error, isNull);
    expect(study.store.getDocuments(includeTrashed: true), hasLength(2));
    expect(study.library, hasLength(2));
    final book = study.store.getDocument('book')!;
    expect(File(book.filePath).existsSync(), isTrue);
    expect(p.isWithin(targetRoot, book.filePath), isTrue);
    expect(study.store.getNotes('book').single.understanding, '笔记随备份恢复');
  });

  test('an interrupted restore can fall back to the pre-restore library', () async {
    final targetRoot = p.join(temp.path, 'library-g');
    final target = _Library(targetRoot);
    target.addDocument('old', '旧库资料', content: 'old-content');
    target.close();

    final previous = Directory(p.join(targetRoot, 'pre-restore-1'))
      ..createSync(recursive: true);
    File(p.join(targetRoot, 'study.sqlite3')).renameSync(
      p.join(previous.path, 'study.sqlite3'),
    );
    Directory(p.join(targetRoot, 'documents')).renameSync(
      p.join(previous.path, 'documents'),
    );
    expect(
      await LibraryBackupService.recoverInterruptedRestore(targetRoot),
      isTrue,
    );
    final recovered = _Library(targetRoot);
    addTearDown(recovered.close);
    expect(recovered.store.getDocuments(), hasLength(1));
    expect(recovered.store.getDocument('old'), isNotNull);
  });

  test('restore request survives a failed validation without touching the library', () async {
    await addRepresentativeContent();
    final report = await createBackup();
    final targetRoot = p.join(temp.path, 'library-e');
    await LibraryBackupService.prepareRestore(report.path, targetRoot);
    // Corrupt the staged database after preparation.
    final stagedDb = File(
      p.join(targetRoot, 'restore-staging', LibraryBackupService.databaseName),
    );
    await stagedDb.writeAsString('broken');
    library.close();
    final result = await LibraryBackupService.applyPendingRestore(targetRoot);
    expect(result, isNotNull);
    expect(result!.applied, isFalse);
    expect(
      File(p.join(targetRoot, LibraryBackupService.databaseName)).existsSync(),
      isFalse,
      reason: 'a failed validation must not install a partial database',
    );
    expect(
      Directory(p.join(targetRoot, 'documents')).existsSync(),
      isFalse,
    );
  });
}
