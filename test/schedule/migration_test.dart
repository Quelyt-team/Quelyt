import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'package:local_study/core/local_store.dart';
import 'package:local_study/core/migrations/schema.dart';
import 'package:local_study/core/models.dart';
import 'package:local_study/features/schedule/data/schedule_repository.dart';
import 'package:local_study/features/schedule/models/local_date.dart';
import 'package:local_study/features/schedule/models/study_plan.dart';

Database _openRaw(String directory) =>
    sqlite3.open(p.join(directory, 'study.sqlite3'));

void _seedVersion1(Database db) {
  db.execute(schemaVersion1);
  db.execute('PRAGMA user_version = 1');
  final document = DocumentRecord(
    id: 'book',
    title: '力学',
    kind: DocumentKind.textbook,
    filePath: '/managed/book.pdf',
    contentHash: 'hash-v1',
    pageCount: 220,
    currentPage: 21,
  );
  db.execute(
    'INSERT INTO documents (id, content_hash, kind, last_opened_at, data) VALUES (?, ?, ?, ?, ?)',
    [
      document.id,
      document.contentHash,
      document.kind.name,
      document.lastOpenedAt.millisecondsSinceEpoch,
      jsonEncode(document.toJson()),
    ],
  );
  const evidence = Evidence(
    id: 'source',
    documentId: 'book',
    documentHash: 'hash-v1',
    page: 21,
    region: SourceRegion(.1, .2, .8, .4),
    text: '动量等于质量乘以速度。',
  );
  db.execute(
    'INSERT INTO evidence (evidence_id, document_id, document_hash, page, origin, data) VALUES (?, ?, ?, ?, ?, ?)',
    [
      evidence.id,
      evidence.documentId,
      evidence.documentHash,
      evidence.page,
      evidence.origin.name,
      jsonEncode(evidence.toJson()),
    ],
  );
  db.execute('INSERT INTO evidence_fts (rowid, terms) VALUES (?, ?)', [
    db.lastInsertRowId,
    '动量 质量 速度',
  ]);
  db.execute(
    'INSERT INTO settings (key, value) VALUES (?, ?)',
    ['ui.theme', 'dark'],
  );
}

void _seedVersion2(Database db) {
  _seedVersion1(db);
  db.execute(schemaVersion2);
  db.execute('PRAGMA user_version = 2');
}

void _seedVersion3(Database db) {
  _seedVersion2(db);
  db.execute(schemaVersion3);
  db.execute('PRAGMA user_version = 3');
}

void _seedVersion4(Database db) {
  _seedVersion3(db);
  db.execute(schemaVersion4);
  db.execute('PRAGMA user_version = 4');
}

void _seedVersion5(Database db) {
  _seedVersion4(db);
  db.execute(schemaVersion5);
  db.execute('PRAGMA user_version = 5');
}

void _seedVersion6(Database db) {
  _seedVersion5(db);
  db.execute(schemaVersion6);
  db.execute('PRAGMA user_version = 6');
}

void _seedVersion7(Database db) {
  _seedVersion6(db);
  db.execute(schemaVersion7);
  db.execute('PRAGMA user_version = 7');
}

void main() {
  test('v1 library upgrades to v7 with verified backups and keeps records', () {
    final directory = Directory.systemTemp.createTempSync('schedule-migrate-');
    addTearDown(() => directory.deleteSync(recursive: true));

    final raw = _openRaw(directory.path);
    _seedVersion1(raw);
    raw.close();

    final store = LocalStore.open(directory.path);
    addTearDown(store.dispose);
    expect(store.schemaVersion, 10);
    expect(store.backupPaths, hasLength(9));
    expect(File(store.backupPaths.first).existsSync(), isTrue);
    expect(File(store.backupPaths.last).existsSync(), isTrue);
    final v1Backup = sqlite3.open(
      store.backupPaths.first,
      mode: OpenMode.readOnly,
    );
    expect(v1Backup.select('PRAGMA integrity_check').first.values.first, 'ok');
    expect(
      v1Backup.select('PRAGMA user_version').first.values.first,
      1,
      reason: 'the first backup must be the untouched v1 database',
    );
    v1Backup.close();
    final v9Backup = sqlite3.open(
      store.backupPaths.last,
      mode: OpenMode.readOnly,
    );
    addTearDown(v9Backup.close);
    expect(
      v9Backup.select('PRAGMA user_version').first.values.first,
      9,
      reason: 'the last backup must be the v9 database before review tables',
    );

    expect(store.getDocument('book')!.currentPage, 21);
    expect(store.searchEvidence('动量').single.documentId, 'book');
    expect(store.getSetting('ui.theme'), 'dark');

    final repository = ScheduleRepository(store);
    final plan = repository.savePlan(
      StudyPlan(
        id: 'plan',
        title: '期中数学',
        startDate: LocalDate(2026, 11, 9),
        endDate: LocalDate(2026, 11, 27),
        examDate: LocalDate(2026, 11, 29),
      ),
    );
    expect(plan.revision, 1);
    expect(repository.getPlans().single.title, '期中数学');
    store.dispose();

    final reopened = LocalStore.open(directory.path);
    addTearDown(reopened.dispose);
    expect(reopened.schemaVersion, 10);
    expect(reopened.backupPaths, isEmpty);
    expect(reopened.getDocument('book')!.contentHash, 'hash-v1');
    expect(ScheduleRepository(reopened).getPlan('plan')!.title, '期中数学');
  });

  test('v2 library upgrades to v7 and creates planning, material and knowledge tables', () {
    final directory = Directory.systemTemp.createTempSync('schedule-v2-');
    addTearDown(() => directory.deleteSync(recursive: true));

    final raw = _openRaw(directory.path);
    _seedVersion2(raw);
    raw.close();

    final store = LocalStore.open(directory.path);
    addTearDown(store.dispose);
    expect(store.schemaVersion, 10);
    expect(store.backupPaths, hasLength(8));
    expect(store.backupPaths.first, contains('.v2-backup-'));
    expect(store.backupPaths.last, contains('.v9-backup-'));
    final backup = sqlite3.open(
      store.backupPaths.first,
      mode: OpenMode.readOnly,
    );
    expect(backup.select('PRAGMA user_version').first.values.first, 2);
    backup.close();
    expect(store.getDocument('book')!.contentHash, 'hash-v1');
    expect(
      store
          .selectRows(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name IN ('planning_conversations', 'planning_messages', "
            "'plan_sources', 'knowledge_items') ORDER BY name",
          )
          .map((row) => row['name']),
      [
        'knowledge_items',
        'plan_sources',
        'planning_conversations',
        'planning_messages',
      ],
    );
  });

  test('v3 library upgrades to v7 with v3, v4, v5 and v6 backups', () {
    final directory = Directory.systemTemp.createTempSync('schedule-v3-');
    addTearDown(() => directory.deleteSync(recursive: true));

    final raw = _openRaw(directory.path);
    _seedVersion3(raw);
    raw.close();

    final store = LocalStore.open(directory.path);
    addTearDown(store.dispose);
    expect(store.schemaVersion, 10);
    expect(store.backupPaths, hasLength(7));
    expect(store.backupPaths.first, contains('.v3-backup-'));
    expect(store.backupPaths.last, contains('.v9-backup-'));
    final backup = sqlite3.open(
      store.backupPaths.first,
      mode: OpenMode.readOnly,
    );
    expect(backup.select('PRAGMA user_version').first.values.first, 3);
    backup.close();
    expect(
      store
          .selectRows(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name = 'knowledge_items'",
          )
          .single['name'],
      'knowledge_items',
    );
  });

  test('a failed migration rolls back and leaves the v1 database readable', () {
    final directory = Directory.systemTemp.createTempSync('schedule-fail-');
    addTearDown(() => directory.deleteSync(recursive: true));

    final raw = _openRaw(directory.path);
    _seedVersion1(raw);
    raw.execute('CREATE TABLE study_plans (wrong_column TEXT)');
    raw.close();

    expect(() => LocalStore.open(directory.path), throwsA(anything));

    final check = _openRaw(directory.path);
    addTearDown(check.close);
    expect(check.select('PRAGMA user_version').first.values.first, 1);
    expect(check.select('SELECT COUNT(*) FROM documents').first.values.first, 1);
    expect(
      check
          .select("SELECT name FROM sqlite_master WHERE name = 'calendar_blocks'")
          .isEmpty,
      isTrue,
    );
    final backups = directory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.contains('.v1-backup-'))
        .toList();
    expect(backups, hasLength(1));
  });

  test('a failed v2 to v3 migration keeps v2 data and a v2 backup', () {
    final directory = Directory.systemTemp.createTempSync('schedule-v2-fail-');
    addTearDown(() => directory.deleteSync(recursive: true));

    final raw = _openRaw(directory.path);
    _seedVersion2(raw);
    raw.execute('CREATE TABLE planning_conversations (wrong_column TEXT)');
    raw.close();

    expect(() => LocalStore.open(directory.path), throwsA(anything));

    final check = _openRaw(directory.path);
    addTearDown(check.close);
    expect(check.select('PRAGMA user_version').first.values.first, 2);
    expect(check.select('SELECT COUNT(*) FROM documents').first.values.first, 1);
    final backups = directory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.contains('.v2-backup-'))
        .toList();
    expect(backups, hasLength(1));
  });

  test('a failed v3 to v4 migration keeps v3 data and a v3 backup', () {
    final directory = Directory.systemTemp.createTempSync('schedule-v3-fail-');
    addTearDown(() => directory.deleteSync(recursive: true));

    final raw = _openRaw(directory.path);
    _seedVersion3(raw);
    raw.execute('CREATE TABLE plan_sources (wrong_column TEXT)');
    raw.close();

    expect(() => LocalStore.open(directory.path), throwsA(anything));

    final check = _openRaw(directory.path);
    addTearDown(check.close);
    expect(check.select('PRAGMA user_version').first.values.first, 3);
    expect(check.select('SELECT COUNT(*) FROM documents').first.values.first, 1);
    final backups = directory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.contains('.v3-backup-'))
        .toList();
    expect(backups, hasLength(1));
  });

  test('v4 library upgrades to v7 with v4, v5 and v6 backups', () {
    final directory = Directory.systemTemp.createTempSync('schedule-v4-');
    addTearDown(() => directory.deleteSync(recursive: true));

    final raw = _openRaw(directory.path);
    _seedVersion4(raw);
    raw.close();

    final store = LocalStore.open(directory.path);
    addTearDown(store.dispose);
    expect(store.schemaVersion, 10);
    expect(store.backupPaths, hasLength(6));
    expect(store.backupPaths.first, contains('.v4-backup-'));
    expect(store.backupPaths.last, contains('.v9-backup-'));
    final backup = sqlite3.open(
      store.backupPaths.first,
      mode: OpenMode.readOnly,
    );
    expect(backup.select('PRAGMA user_version').first.values.first, 4);
    backup.close();
    expect(
      store
          .selectRows(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name IN ('knowledge_items', 'daily_lessons') ORDER BY name",
          )
          .map((row) => row['name']),
      ['daily_lessons', 'knowledge_items'],
    );
  });

  test('a failed v4 to v5 migration keeps v4 data and a v4 backup', () {
    final directory = Directory.systemTemp.createTempSync('schedule-v4-fail-');
    addTearDown(() => directory.deleteSync(recursive: true));

    final raw = _openRaw(directory.path);
    _seedVersion4(raw);
    raw.execute('CREATE TABLE knowledge_items (wrong_column TEXT)');
    raw.close();

    expect(() => LocalStore.open(directory.path), throwsA(anything));

    final check = _openRaw(directory.path);
    addTearDown(check.close);
    expect(check.select('PRAGMA user_version').first.values.first, 4);
    expect(check.select('SELECT COUNT(*) FROM documents').first.values.first, 1);
    final backups = directory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.contains('.v4-backup-'))
        .toList();
    expect(backups, hasLength(1));
  });

  test('v5 library upgrades to v7 with v5 and v6 backups', () {
    final directory = Directory.systemTemp.createTempSync('schedule-v5-');
    addTearDown(() => directory.deleteSync(recursive: true));

    final raw = _openRaw(directory.path);
    _seedVersion5(raw);
    raw.close();

    final store = LocalStore.open(directory.path);
    addTearDown(store.dispose);
    expect(store.schemaVersion, 10);
    expect(store.backupPaths, hasLength(5));
    expect(store.backupPaths.first, contains('.v5-backup-'));
    expect(store.backupPaths.last, contains('.v9-backup-'));
    expect(store.getDocument('book')!.contentHash, 'hash-v1');
  });

  test('v6 library upgrades to v7 and creates book QA tables', () {
    final directory = Directory.systemTemp.createTempSync('schedule-v6-');
    addTearDown(() => directory.deleteSync(recursive: true));

    final raw = _openRaw(directory.path);
    _seedVersion6(raw);
    raw.close();

    final store = LocalStore.open(directory.path);
    addTearDown(store.dispose);
    expect(store.schemaVersion, 10);
    expect(store.backupPaths, hasLength(4));
    expect(store.backupPaths.first, contains('.v6-backup-'));
    expect(store.backupPaths.last, contains('.v9-backup-'));
    final backup = sqlite3.open(
      store.backupPaths.first,
      mode: OpenMode.readOnly,
    );
    expect(backup.select('PRAGMA user_version').first.values.first, 6);
    backup.close();
    expect(store.getDocument('book')!.contentHash, 'hash-v1');
    expect(store.searchEvidence('动量').single.documentId, 'book');
    expect(
      store
          .selectRows(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name IN ('book_understanding_jobs', 'book_chapters', "
            "'book_chunks', 'book_knowledge_points', 'book_qa_conversations', "
            "'book_qa_messages', 'web_source_cache') ORDER BY name",
          )
          .map((row) => row['name']),
      [
        'book_chapters',
        'book_chunks',
        'book_knowledge_points',
        'book_qa_conversations',
        'book_qa_messages',
        'book_understanding_jobs',
        'web_source_cache',
      ],
    );
  });

  test('a failed v6 to v7 migration keeps v6 data and a v6 backup', () {
    final directory = Directory.systemTemp.createTempSync('schedule-v6-fail-');
    addTearDown(() => directory.deleteSync(recursive: true));

    final raw = _openRaw(directory.path);
    _seedVersion6(raw);
    raw.execute('CREATE TABLE book_chapters (wrong_column TEXT)');
    raw.close();

    expect(() => LocalStore.open(directory.path), throwsA(anything));

    final check = _openRaw(directory.path);
    addTearDown(check.close);
    expect(check.select('PRAGMA user_version').first.values.first, 6);
    expect(check.select('SELECT COUNT(*) FROM documents').first.values.first, 1);
    expect(
      check
          .select(
            "SELECT name FROM sqlite_master WHERE name = 'book_qa_messages'",
          )
          .isEmpty,
      isTrue,
    );
    final backups = directory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.contains('.v6-backup-'))
        .toList();
    expect(backups, hasLength(1));
  });

  test('v7 library upgrades to v8 and creates an unfiled primary entry', () {
    final directory = Directory.systemTemp.createTempSync('schedule-v7-');
    addTearDown(() => directory.deleteSync(recursive: true));

    final raw = _openRaw(directory.path);
    _seedVersion7(raw);
    raw.close();

    final store = LocalStore.open(directory.path);
    addTearDown(store.dispose);
    expect(store.schemaVersion, 10);
    expect(store.backupPaths, hasLength(3));
    expect(store.backupPaths.last, contains('.v9-backup-'));
    final document = store.getDocument('book')!;
    expect(document.contentHash, 'hash-v1');
    expect(document.kind, DocumentKind.textbook);
    expect(document.originalName, isNotEmpty);
    expect(document.format, 'pdf');
    expect(document.isActive, isTrue);
    final entries = store.selectRows(
      'SELECT folder_id, is_shortcut FROM document_entries',
    );
    expect(entries, hasLength(1));
    expect(entries.single['folder_id'], isNull);
    expect(entries.single['is_shortcut'], 0);
    expect(store.searchEvidence('动量').single.documentId, 'book');
    expect(
      store
          .selectRows(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name IN ('library_folders', 'document_entries', "
            "'library_tags', 'document_tags', 'deletion_batches', "
            "'import_batches', 'import_items') ORDER BY name",
          )
          .map((row) => row['name']),
      [
        'deletion_batches',
        'document_entries',
        'document_tags',
        'import_batches',
        'import_items',
        'library_folders',
        'library_tags',
      ],
    );
  });

  test('a failed v7 to v8 migration keeps v7 data and a v7 backup', () {
    final directory = Directory.systemTemp.createTempSync('schedule-v7-fail-');
    addTearDown(() => directory.deleteSync(recursive: true));

    final raw = _openRaw(directory.path);
    _seedVersion7(raw);
    raw.execute('CREATE TABLE library_folders (wrong_column TEXT)');
    raw.close();

    expect(() => LocalStore.open(directory.path), throwsA(anything));

    final check = _openRaw(directory.path);
    addTearDown(check.close);
    expect(check.select('PRAGMA user_version').first.values.first, 7);
    expect(check.select('SELECT COUNT(*) FROM documents').first.values.first, 1);
    expect(
      check
          .select(
            "SELECT name FROM sqlite_master WHERE name = 'document_entries'",
          )
          .isEmpty,
      isTrue,
    );
    final backups = directory
        .listSync()
        .whereType<File>()
        .where((file) => file.path.contains('.v7-backup-'))
        .toList();
    expect(backups, hasLength(1));
  });

  test('a database from a newer app version is refused', () {
    final directory = Directory.systemTemp.createTempSync('schedule-newer-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final raw = _openRaw(directory.path);
    raw.execute('PRAGMA user_version = 99');
    raw.close();
    expect(() => LocalStore.open(directory.path), throwsStateError);
  });
}
