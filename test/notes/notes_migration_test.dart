import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'package:local_study/core/local_store.dart';
import 'package:local_study/core/migrations/schema.dart';
import 'package:local_study/core/models.dart';
import 'package:local_study/features/notes/data/notes_repository.dart';
import 'package:local_study/features/notes/models/note_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('v8 old notes become independent v9 notes with source and question', () {
    final temp = Directory.systemTemp.createTempSync('notes_migration_');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final path = p.join(temp.path, 'study.sqlite3');
    final db = sqlite3.open(path);
    db.execute(schemaVersion1);
    db.execute(schemaVersion2);
    db.execute(schemaVersion3);
    db.execute(schemaVersion4);
    db.execute(schemaVersion5);
    db.execute(schemaVersion6);
    db.execute(schemaVersion7);
    db.execute(schemaVersion8);
    db.execute('PRAGMA user_version = 8');
    final document = DocumentRecord(
      id: 'book',
      title: '高分子化学',
      kind: DocumentKind.textbook,
      filePath: p.join(temp.path, 'book.pdf'),
      contentHash: 'hash-book',
      pageCount: 30,
      lifecycle: DocumentLifecycle.active,
    );
    db.execute(
      '''INSERT INTO documents
        (id, content_hash, kind, last_opened_at, data, original_name, format,
         size_bytes, lifecycle, lifecycle_version, starred, learning_mode,
         added_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        document.id,
        document.contentHash,
        document.kind.name,
        document.lastOpenedAt.millisecondsSinceEpoch,
        jsonEncode(document.toJson()),
        '高分子化学.pdf',
        'pdf',
        100,
        'active',
        1,
        0,
        'unspecified',
        document.createdAt.millisecondsSinceEpoch,
      ],
    );
    final note = StudyNote(
      id: 'old-note',
      documentId: 'book',
      documentHash: 'hash-book',
      page: 20,
      region: const SourceRegion(.1, .2, .8, .4),
      understanding: '为什么聚合物多以头尾键连为主？\n这是理解。',
      evidenceText: '头尾键接是主要方式。',
      question: '支链如何影响结晶？',
      createdAt: DateTime.utc(2026, 11, 1, 8),
    );
    db.execute(
      'INSERT INTO notes (id, document_id, page, created_at, data) VALUES (?, ?, ?, ?, ?)',
      [
        note.id,
        note.documentId,
        note.page,
        note.createdAt.millisecondsSinceEpoch,
        jsonEncode(note.toJson()),
      ],
    );
    db.dispose();

    final store = LocalStore.open(temp.path);
    addTearDown(store.dispose);
    expect(store.schemaVersion, 10);
    final repository = NotesRepository(store);
    final migrated = repository.getNote('old-note')!;
    expect(migrated.title, '为什么聚合物多以头尾键连为主？');
    expect(migrated.body, note.understanding);
    expect(migrated.lifecycle, NoteLifecycle.active);
    final sources = repository.sources('old-note');
    expect(sources, hasLength(1));
    expect(sources.single.page, 20);
    expect(sources.single.excerpt, note.evidenceText);
    expect(repository.questions('old-note'), hasLength(1));
    expect(repository.revisions('old-note'), isNotEmpty);
    expect(repository.notesForDocument('book'), hasLength(1));
  });
}
