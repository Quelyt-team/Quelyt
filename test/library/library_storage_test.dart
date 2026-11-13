import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:local_study/core/local_store.dart';
import 'package:local_study/core/models.dart';
import 'package:local_study/features/library/services/library_storage_service.dart';
import 'package:local_study/services/document_service.dart';
import 'package:local_study/services/ocr_service.dart';

DocumentRecord _document(
  String id, {
  DocumentLifecycle lifecycle = DocumentLifecycle.active,
}) => DocumentRecord(
  id: id,
  title: '资料 $id',
  kind: DocumentKind.unspecified,
  filePath: '',
  contentHash: 'hash-$id',
  pageCount: 2,
  format: 'pdf',
  lifecycle: lifecycle,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late Directory root;
  late LocalStore store;
  late DocumentService documents;
  late LibraryStorageService storage;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('library_storage_');
    root = Directory(p.join(temp.path, 'app'));
    store = LocalStore.inMemory();
    documents = DocumentService(root, store, OcrService());
    storage = LibraryStorageService(store: store, documents: documents);
  });

  tearDown(() {
    store.dispose();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  DocumentRecord addDocument(
    String id,
    String content, {
    DocumentLifecycle lifecycle = DocumentLifecycle.active,
  }) {
    final directory = Directory(p.join(root.path, 'documents', id))
      ..createSync(recursive: true);
    final file = File(p.join(directory.path, 'original.pdf'))
      ..writeAsStringSync(content);
    final hash = sha256.convert(utf8.encode(content)).toString();
    final active = _document(id).copyWith(
      filePath: file.path,
      contentHash: hash,
      sizeBytes: content.length,
    );
    store.importDocument(active, [
      PageRecord(documentId: id, page: 1, status: PageStatus.ready, text: content),
      PageRecord(documentId: id, page: 2, status: PageStatus.pending),
    ]);
    if (lifecycle != DocumentLifecycle.active) {
      store.saveDocumentRecord(
        active.copyWith(
          lifecycle: lifecycle,
          lifecycleVersion: active.lifecycleVersion + 1,
          trashedAt: DateTime.now(),
        ),
      );
    }
    return store.getDocument(id)!;
  }

  test('measures originals, cache and trash without counting cache as data', () async {
    addDocument('one', 'first-content');
    addDocument('trashed', 'trashed-content', lifecycle: DocumentLifecycle.trashed);
    final cache = Directory(p.join(root.path, 'cache', 'one'))
      ..createSync(recursive: true);
    File(p.join(cache.path, 'page.png')).writeAsBytesSync(List.filled(128, 7));
    final imports = Directory(p.join(root.path, 'imports', 'batch'))
      ..createSync(recursive: true);
    File(p.join(imports.path, 'part.tmp')).writeAsBytesSync(List.filled(64, 9));

    final report = await storage.measure();
    expect(report.documents, 1);
    expect(report.trashedDocuments, 1);
    expect(report.originalsBytes, greaterThan(0));
    expect(report.cacheBytes, 128);
    expect(report.importsBytes, 64);
    expect(report.rebuildableBytes, 192);
    expect(report.trashBytes, greaterThan(0));
    expect(report.missingOriginals, isEmpty);
    expect(formatBytes(0), '0 B');
    expect(formatBytes(2048), '2 KB');
  });

  test('clearing cache removes only rebuildable files', () async {
    final document = addDocument('cached', 'content');
    final nested = Directory(p.join(root.path, 'cache', 'cached', 'pages'))
      ..createSync(recursive: true);
    File(p.join(nested.path, '1.png')).writeAsBytesSync(List.filled(50, 1));
    File(p.join(root.path, 'cache', 'index.bin')).writeAsBytesSync(
      List.filled(25, 2),
    );

    final freed = await storage.clearRebuildableCache();
    expect(freed, 75);
    expect(
      Directory(p.join(root.path, 'cache')).listSync(recursive: true),
      isEmpty,
    );
    expect(File(document.filePath).existsSync(), isTrue);
    expect(store.getDocuments(), hasLength(1));
  });

  test('missing originals are listed and relinked only when the hash matches', () async {
    final document = addDocument('lost', 'lost-content');
    final goodCopy = File(p.join(temp.path, 'good.pdf'))
      ..writeAsStringSync('lost-content');
    final other = File(p.join(temp.path, 'other.pdf'))
      ..writeAsStringSync('changed-content');
    File(document.filePath).deleteSync();

    final missing = await storage.missingDocuments();
    expect(missing.map((item) => item.id), contains('lost'));
    final report = await storage.measure();
    expect(report.hasMissingOriginals, isTrue);

    await expectLater(
      storage.relinkOriginal(document, other.path),
      throwsA(isA<LibraryStorageException>()),
    );
    expect(File(store.getDocument('lost')!.filePath).existsSync(), isFalse);

    await storage.relinkOriginal(document, goodCopy.path);
    final restored = store.getDocument('lost')!;
    expect(File(restored.filePath).existsSync(), isTrue);
    expect(File(restored.filePath).readAsStringSync(), 'lost-content');
    expect(restored.contentHash, sha256.convert(utf8.encode('lost-content')).toString());
    expect(await storage.missingDocuments(), isEmpty);
  });

  test('relinking refuses a path that is not the recorded content', () async {
    final document = addDocument('versioned', 'version-one');
    final source = File(p.join(temp.path, 'v2.pdf'))..writeAsStringSync('version-two');
    await expectLater(
      storage.relinkOriginal(document, source.path),
      throwsA(
        predicate(
          (error) => '$error'.contains('内容与资料记录不一致'),
        ),
      ),
    );
    expect(File(document.filePath).readAsStringSync(), 'version-one');
  });
}
