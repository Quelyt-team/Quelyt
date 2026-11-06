import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'models.dart';
import 'search_index.dart';

/// Local SQLite storage. No method in this class makes a network request.
/// API credentials belong in platform secure storage, never in settings.
class LocalStore {
  LocalStore._(this._database) {
    _initialize();
  }

  factory LocalStore.open(String directory) {
    Directory(directory).createSync(recursive: true);
    return LocalStore._(sqlite3.open(p.join(directory, 'study.sqlite3')));
  }

  factory LocalStore.inMemory() => LocalStore._(sqlite3.openInMemory());

  final Database _database;
  bool _disposed = false;

  void _initialize() {
    _database.execute('PRAGMA foreign_keys = ON');
    _database.execute('PRAGMA busy_timeout = 5000');
    _database.execute('PRAGMA journal_mode = WAL');
    final version =
        _database.select('PRAGMA user_version').first.values.first as int;
    if (version > 1) {
      _database.close();
      throw StateError('This library was created by a newer app version.');
    }
    _database.execute('''
      CREATE TABLE IF NOT EXISTS documents (
        id TEXT PRIMARY KEY,
        content_hash TEXT NOT NULL,
        kind TEXT NOT NULL,
        last_opened_at INTEGER NOT NULL,
        data TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS pages (
        document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
        page INTEGER NOT NULL CHECK(page > 0),
        status TEXT NOT NULL,
        data TEXT NOT NULL,
        PRIMARY KEY(document_id, page)
      );
      CREATE TABLE IF NOT EXISTS evidence (
        rowid INTEGER PRIMARY KEY AUTOINCREMENT,
        evidence_id TEXT NOT NULL UNIQUE,
        document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
        document_hash TEXT NOT NULL,
        page INTEGER NOT NULL CHECK(page > 0),
        origin TEXT NOT NULL,
        data TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS evidence_document_page ON evidence(document_id, page);
      CREATE VIRTUAL TABLE IF NOT EXISTS evidence_fts USING fts5(terms);
      CREATE TRIGGER IF NOT EXISTS evidence_delete_fts AFTER DELETE ON evidence
      BEGIN
        DELETE FROM evidence_fts WHERE rowid = old.rowid;
      END;
      CREATE TABLE IF NOT EXISTS notes (
        id TEXT PRIMARY KEY,
        document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
        page INTEGER NOT NULL CHECK(page > 0),
        created_at INTEGER NOT NULL,
        data TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS notes_document ON notes(document_id, created_at);
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
        document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
        updated_at INTEGER NOT NULL,
        data TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS sessions_document ON sessions(document_id, updated_at);
      CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      PRAGMA user_version = 1;
    ''');
  }

  void _checkOpen() {
    if (_disposed) {
      throw StateError('The local library has been closed.');
    }
  }

  T _transaction<T>(T Function() action) {
    _checkOpen();
    _database.execute('BEGIN IMMEDIATE');
    try {
      final result = action();
      _database.execute('COMMIT');
      return result;
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  static Map<String, dynamic> _decode(Row row) =>
      Map<String, dynamic>.from(jsonDecode(row['data'] as String) as Map);

  void upsertDocument(DocumentRecord document) {
    _checkOpen();
    if (document.id.isEmpty ||
        document.contentHash.isEmpty ||
        document.pageCount < 1 ||
        document.currentPage < 1 ||
        document.currentPage > document.pageCount) {
      throw ArgumentError('Invalid document or reading page.');
    }
    final existing = getDocument(document.id);
    if (existing != null && existing.contentHash != document.contentHash) {
      throw ArgumentError('Import a changed file as a new document version.');
    }
    _database.execute(
      '''
      INSERT INTO documents (id, content_hash, kind, last_opened_at, data)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET content_hash=excluded.content_hash,
        kind=excluded.kind, last_opened_at=excluded.last_opened_at, data=excluded.data
    ''',
      [
        document.id,
        document.contentHash,
        document.kind.name,
        document.lastOpenedAt.millisecondsSinceEpoch,
        jsonEncode(document.toJson()),
      ],
    );
  }

  List<DocumentRecord> getDocuments({DocumentKind? kind}) {
    _checkOpen();
    final rows = _database.select('''
      SELECT data FROM documents ${kind == null ? '' : 'WHERE kind = ?'}
      ORDER BY last_opened_at DESC, id
    ''', kind == null ? [] : [kind.name]);
    return rows.map((row) => DocumentRecord.fromJson(_decode(row))).toList();
  }

  DocumentRecord? getDocument(String id) {
    _checkOpen();
    final rows = _database.select('SELECT data FROM documents WHERE id = ?', [
      id,
    ]);
    return rows.isEmpty ? null : DocumentRecord.fromJson(_decode(rows.first));
  }

  /// Removes database records and FTS entries. The import service separately
  /// removes its managed local copy and render cache, never the external file.
  void deleteDocument(String id) {
    _transaction(() {
      _database.execute('DELETE FROM documents WHERE id = ?', [id]);
      _database.execute('DELETE FROM settings WHERE key = ?', ['history:$id']);
    });
  }

  void importDocument(DocumentRecord document, Iterable<PageRecord> pages) {
    _transaction(() {
      upsertDocument(document);
      for (final page in pages) {
        if (page.documentId != document.id) {
          throw ArgumentError('Imported pages must belong to this document.');
        }
        savePage(page);
      }
    });
  }

  DocumentRecord _requireDocument(String id, {int? page, String? hash}) {
    final document = getDocument(id);
    if (document == null) {
      throw ArgumentError('Document is not in the library.');
    }
    if (page != null && (page < 1 || page > document.pageCount)) {
      throw RangeError.range(page, 1, document.pageCount, 'page');
    }
    if (hash != null && hash != document.contentHash) {
      throw ArgumentError('Evidence belongs to another document version.');
    }
    return document;
  }

  void savePage(PageRecord page) {
    _checkOpen();
    _requireDocument(page.documentId, page: page.page);
    _database.execute(
      '''
      INSERT INTO pages (document_id, page, status, data) VALUES (?, ?, ?, ?)
      ON CONFLICT(document_id, page) DO UPDATE SET status=excluded.status,
        data=excluded.data
    ''',
      [page.documentId, page.page, page.status.name, jsonEncode(page.toJson())],
    );
  }

  List<PageRecord> getPages(String documentId) {
    _checkOpen();
    return _database
        .select('SELECT data FROM pages WHERE document_id = ? ORDER BY page', [
          documentId,
        ])
        .map((row) => PageRecord.fromJson(_decode(row)))
        .toList();
  }

  PageRecord? getPage(String documentId, int page) {
    _checkOpen();
    final rows = _database.select(
      'SELECT data FROM pages WHERE document_id = ? AND page = ?',
      [documentId, page],
    );
    return rows.isEmpty ? null : PageRecord.fromJson(_decode(rows.first));
  }

  void _writeEvidence(Evidence evidence) {
    _requireDocument(
      evidence.documentId,
      page: evidence.page,
      hash: evidence.documentHash,
    );
    if (evidence.id.isEmpty || !evidence.region.isValid) {
      throw ArgumentError(
        'Evidence needs an id and a valid original-page region.',
      );
    }
    final confidence = evidence.confidence;
    if (confidence != null &&
        (!confidence.isFinite || confidence < 0 || confidence > 1)) {
      throw ArgumentError.value(confidence, 'confidence', 'Expected 0 to 1.');
    }
    // Delete + insert also invokes the FTS cleanup trigger for a corrected
    // paragraph, preventing old OCR text from remaining searchable.
    _database.execute('DELETE FROM evidence WHERE evidence_id = ?', [
      evidence.id,
    ]);
    _database.execute(
      '''
      INSERT INTO evidence (evidence_id, document_id, document_hash, page, origin, data)
      VALUES (?, ?, ?, ?, ?, ?)
    ''',
      [
        evidence.id,
        evidence.documentId,
        evidence.documentHash,
        evidence.page,
        evidence.origin.name,
        jsonEncode(evidence.toJson()),
      ],
    );
    _database.execute('INSERT INTO evidence_fts (rowid, terms) VALUES (?, ?)', [
      _database.lastInsertRowId,
      SearchIndex.indexText(evidence.text),
    ]);
  }

  void saveEvidence(Evidence evidence) =>
      _transaction(() => _writeEvidence(evidence));

  /// Atomically replaces automatically extracted spans on one page. Manual
  /// source annotations remain attached to their original coordinates.
  void replacePageEvidence(
    String documentId,
    int page,
    List<Evidence> evidence, {
    bool preserveManual = true,
  }) {
    _transaction(
      () => _replacePageEvidence(
        documentId,
        page,
        evidence,
        preserveManual: preserveManual,
      ),
    );
  }

  void savePageWithEvidence(
    PageRecord page,
    List<Evidence> evidence, {
    bool preserveManual = true,
  }) {
    _transaction(() {
      _replacePageEvidence(
        page.documentId,
        page.page,
        evidence,
        preserveManual: preserveManual,
      );
      savePage(page);
    });
  }

  void _replacePageEvidence(
    String documentId,
    int page,
    List<Evidence> evidence, {
    required bool preserveManual,
  }) {
    _requireDocument(documentId, page: page);
    for (final item in evidence) {
      if (item.documentId != documentId || item.page != page) {
        throw ArgumentError('Replacement evidence must belong to this page.');
      }
    }
    _database.execute(
      '''
        DELETE FROM evidence WHERE document_id = ? AND page = ?
        ${preserveManual ? "AND origin != 'manual'" : ''}
      ''',
      [documentId, page],
    );
    for (final item in evidence) {
      _writeEvidence(item);
    }
  }

  List<Evidence> getEvidence(
    String documentId, {
    int? page,
    int? startPage,
    int? endPage,
  }) {
    _checkOpen();
    final conditions = <String>['document_id = ?'];
    final parameters = <Object?>[documentId];
    if (page != null) {
      conditions.add('page = ?');
      parameters.add(page);
    }
    if (startPage != null) {
      conditions.add('page >= ?');
      parameters.add(startPage);
    }
    if (endPage != null) {
      conditions.add('page <= ?');
      parameters.add(endPage);
    }
    return _database
        .select(
          'SELECT data FROM evidence WHERE ${conditions.join(' AND ')} ORDER BY page, rowid',
          parameters,
        )
        .map((row) => Evidence.fromJson(_decode(row)))
        .toList();
  }

  List<Evidence> searchEvidence(
    String query, {
    String? documentId,
    int? startPage,
    int? endPage,
    int limit = 12,
  }) {
    _checkOpen();
    if (limit < 1 || limit > 100) {
      throw RangeError.range(limit, 1, 100, 'limit');
    }
    final match = SearchIndex.matchQuery(query);
    if (match.isEmpty) {
      return [];
    }
    final conditions = <String>['evidence_fts MATCH ?'];
    final parameters = <Object?>[match];
    if (documentId != null) {
      conditions.add('e.document_id = ?');
      parameters.add(documentId);
    }
    if (startPage != null) {
      conditions.add('e.page >= ?');
      parameters.add(startPage);
    }
    if (endPage != null) {
      conditions.add('e.page <= ?');
      parameters.add(endPage);
    }
    parameters.add(limit);
    return _database
        .select('''
      SELECT e.data FROM evidence_fts JOIN evidence e ON e.rowid = evidence_fts.rowid
      WHERE ${conditions.join(' AND ')}
      ORDER BY bm25(evidence_fts), e.page, e.rowid LIMIT ?
    ''', parameters)
        .map((row) => Evidence.fromJson(_decode(row)))
        .toList();
  }

  void saveNote(StudyNote note) {
    _checkOpen();
    final document = _requireDocument(
      note.documentId,
      page: note.page,
      hash: note.documentHash.isEmpty ? null : note.documentHash,
    );
    if (note.id.isEmpty || !note.region.isValid) {
      throw ArgumentError('Invalid source note.');
    }
    final versioned = note.documentHash.isEmpty
        ? note.copyWith(documentHash: document.contentHash)
        : note;
    _database.execute(
      '''
      INSERT INTO notes (id, document_id, page, created_at, data) VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET document_id=excluded.document_id,
        page=excluded.page, created_at=excluded.created_at, data=excluded.data
    ''',
      [
        versioned.id,
        versioned.documentId,
        versioned.page,
        versioned.createdAt.millisecondsSinceEpoch,
        jsonEncode(versioned.toJson()),
      ],
    );
  }

  List<StudyNote> getNotes(String documentId) {
    _checkOpen();
    return _database
        .select(
          '''SELECT data FROM notes WHERE document_id = ?
      ORDER BY created_at DESC, id''',
          [documentId],
        )
        .map((row) => StudyNote.fromJson(_decode(row)))
        .toList();
  }

  void deleteNote(String id) {
    _checkOpen();
    _database.execute('DELETE FROM notes WHERE id = ?', [id]);
  }

  void saveSession(StudySession session) {
    _checkOpen();
    _requireDocument(session.documentId, page: session.startPage);
    _requireDocument(session.documentId, page: session.endPage);
    if (session.id.isEmpty ||
        session.endPage < session.startPage ||
        session.minutes < 1) {
      throw ArgumentError('Invalid learning range or duration.');
    }
    _database.execute(
      '''
      INSERT INTO sessions (id, document_id, updated_at, data) VALUES (?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET document_id=excluded.document_id,
        updated_at=excluded.updated_at, data=excluded.data
    ''',
      [
        session.id,
        session.documentId,
        session.updatedAt.millisecondsSinceEpoch,
        jsonEncode(session.toJson()),
      ],
    );
  }

  List<StudySession> getSessions(String documentId) {
    _checkOpen();
    return _database
        .select(
          '''SELECT data FROM sessions WHERE document_id = ?
      ORDER BY updated_at DESC, id''',
          [documentId],
        )
        .map((row) => StudySession.fromJson(_decode(row)))
        .toList();
  }

  String? getSetting(String key) {
    _checkOpen();
    final rows = _database.select('SELECT value FROM settings WHERE key = ?', [
      key,
    ]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Map<String, String> getSettings({String prefix = ''}) {
    _checkOpen();
    return {
      for (final row in _database.select('SELECT key, value FROM settings'))
        if ((row['key'] as String).startsWith(prefix))
          row['key'] as String: row['value'] as String,
    };
  }

  void deleteSetting(String key) {
    _checkOpen();
    _database.execute('DELETE FROM settings WHERE key = ?', [key]);
  }

  void setSetting(String key, String value) {
    _checkOpen();
    if (RegExp(
      r'api.?key|secret|password|credential',
      caseSensitive: false,
    ).hasMatch(key)) {
      throw ArgumentError('Credentials must use platform secure storage.');
    }
    _database.execute(
      '''INSERT INTO settings (key, value) VALUES (?, ?)
      ON CONFLICT(key) DO UPDATE SET value=excluded.value''',
      [key, value],
    );
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _database.close();
    _disposed = true;
  }
}
