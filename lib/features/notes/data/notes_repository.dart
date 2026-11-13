import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../../core/local_store.dart';
import '../../../core/models.dart';
import '../../library/models/library_models.dart';
import '../models/note_models.dart';

/// Persistent notes. One note owns a primary entry in the shared folder tree;
/// sources are historical snapshots and deliberately have no foreign key to
/// documents, so permanently deleting a textbook cannot erase a learner's note.
class NotesRepository {
  NotesRepository(this.store);

  final LocalStore store;
  static const _uuid = Uuid();
  static const int maxAutoRevisions = 100;
  static const Duration revisionInterval = Duration(minutes: 5);

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  List<LibraryFolder> folders() => store
      .selectRows(
        'SELECT data FROM library_folders WHERE deleted_at IS NULL '
        'ORDER BY sort_key, name_norm, id',
      )
      .map(
        (row) => LibraryFolder.fromJson(
          Map<String, dynamic>.from(jsonDecode(row['data'] as String) as Map),
        ),
      )
      .toList();

  List<LibraryTag> tags() => store
      .selectRows('SELECT data FROM library_tags ORDER BY name_norm')
      .map(
        (row) => LibraryTag.fromJson(
          Map<String, dynamic>.from(jsonDecode(row['data'] as String) as Map),
        ),
      )
      .toList();

  NoteRecord? getNote(String id) {
    final rows = store.selectRows(
      'SELECT data FROM note_documents WHERE id = ?',
      [id],
    );
    return rows.isEmpty ? null : _note(rows.first);
  }

  NoteEntry? primaryEntry(String noteId) {
    final rows = store.selectRows(
      '''SELECT id, note_id, folder_id, is_shortcut, alias, sort_key, created_at
         FROM note_entries WHERE note_id = ? AND is_shortcut = 0 LIMIT 1''',
      [noteId],
    );
    return rows.isEmpty ? null : _entry(rows.first);
  }

  List<NoteSource> sources(String noteId) => store
      .selectRows(
        'SELECT data FROM note_sources WHERE note_id = ? ORDER BY created_at, id',
        [noteId],
      )
      .map(
        (row) => NoteSource.fromJson(
          Map<String, dynamic>.from(jsonDecode(row['data'] as String) as Map),
        ),
      )
      .toList();

  List<NoteQuestion> questions(String noteId) => store
      .selectRows(
        'SELECT data FROM note_questions WHERE note_id = ? ORDER BY created_at, id',
        [noteId],
      )
      .map(
        (row) => NoteQuestion.fromJson(
          Map<String, dynamic>.from(jsonDecode(row['data'] as String) as Map),
        ),
      )
      .toList();

  Set<String> tagIds(String noteId) => {
    for (final row in store.selectRows(
      'SELECT tag_id FROM note_tags WHERE note_id = ?',
      [noteId],
    ))
      row['tag_id'] as String,
  };

  List<NoteRecord> list({
    NotesScope scope = NotesScope.all,
    String? folderId,
    String query = '',
    String? tagId,
  }) {
    final where = <String>[];
    final args = <Object?>[];
    if (scope == NotesScope.trash) {
      where.add("lifecycle = 'trashed'");
    } else {
      where.add("lifecycle = 'active'");
    }
    if (scope == NotesScope.starred) where.add('starred = 1');
    if (scope == NotesScope.openQuestions) {
      where.add(
        '''EXISTS (
          SELECT 1 FROM note_questions q
          WHERE q.note_id = note_documents.id AND q.status = 'open'
        )''',
      );
    }
    if (scope == NotesScope.related) {
      where.add(
        '''EXISTS (
          SELECT 1 FROM note_sources s
          WHERE s.note_id = note_documents.id AND s.document_id IS NOT NULL
        )''',
      );
    }
    if (scope == NotesScope.unfiled) {
      where.add(
        '''NOT EXISTS (
          SELECT 1 FROM note_entries e
          WHERE e.note_id = note_documents.id
            AND e.is_shortcut = 0 AND e.folder_id IS NOT NULL
        )''',
      );
    }
    if (scope == NotesScope.folder) {
      where.add(
        '''EXISTS (
          SELECT 1 FROM note_entries e
          WHERE e.note_id = note_documents.id
            AND e.is_shortcut = 0 AND e.folder_id = ?
        )''',
      );
      args.add(folderId);
    }
    final text = query.trim();
    if (text.isNotEmpty) {
      final escaped = text
          .replaceAll('\\', '\\\\')
          .replaceAll('%', '\\%')
          .replaceAll('_', '\\_');
      final pattern = '%$escaped%';
      where.add(
        '''(
          title LIKE ? ESCAPE '\\' OR body LIKE ? ESCAPE '\\'
          OR EXISTS (
            SELECT 1 FROM note_sources s
            WHERE s.note_id = note_documents.id
              AND s.excerpt LIKE ? ESCAPE '\\'
          )
          OR EXISTS (
            SELECT 1 FROM note_tags nt JOIN library_tags t ON t.id = nt.tag_id
            WHERE nt.note_id = note_documents.id
              AND t.name LIKE ? ESCAPE '\\'
          )
        )''',
      );
      args.addAll([pattern, pattern, pattern, pattern]);
    }
    if (tagId != null) {
      where.add(
        '''EXISTS (
          SELECT 1 FROM note_tags nt
          WHERE nt.note_id = note_documents.id AND nt.tag_id = ?
        )''',
      );
      args.add(tagId);
    }
    final sql = '''
      SELECT data FROM note_documents
      WHERE ${where.join(' AND ')}
      ORDER BY ${scope == NotesScope.recent ? 'updated_at DESC' : 'updated_at DESC'}
      ${scope == NotesScope.recent ? 'LIMIT 150' : ''}
    ''';
    return store
        .selectRows(sql, args)
        .map((row) => _note(row))
        .toList();
  }

  NoteCounts counts() {
    int one(String sql) =>
        (store.selectRows(sql).first.values.first as int?) ?? 0;
    return NoteCounts(
      all: one("SELECT COUNT(*) AS c FROM note_documents WHERE lifecycle='active'"),
      starred: one(
        "SELECT COUNT(*) AS c FROM note_documents WHERE lifecycle='active' AND starred=1",
      ),
      unfiled: one('''
        SELECT COUNT(*) AS c FROM note_documents n
        WHERE n.lifecycle='active' AND NOT EXISTS (
          SELECT 1 FROM note_entries e
          WHERE e.note_id=n.id AND e.is_shortcut=0 AND e.folder_id IS NOT NULL
        )
      '''),
      trash: one(
        "SELECT COUNT(*) AS c FROM note_documents WHERE lifecycle='trashed'",
      ),
      openQuestions: one('''
        SELECT COUNT(*) AS c FROM note_questions q
        JOIN note_documents n ON n.id=q.note_id
        WHERE q.status='open' AND n.lifecycle='active'
      '''),
      related: one('''
        SELECT COUNT(DISTINCT n.id) AS c FROM note_documents n
        JOIN note_sources s ON s.note_id=n.id
        WHERE n.lifecycle='active' AND s.document_id IS NOT NULL
      '''),
    );
  }

  /// Loads the small amount of source/question/tag/folder metadata used by the
  /// note list cards in aggregate queries rather than one query per card.
  Map<String, NoteListSummary> summariesFor(Iterable<String> noteIds) {
    final ids = noteIds.toList();
    if (ids.isEmpty) return const {};
    final sources = <String, NoteSource>{};
    final questions = <String, int>{};
    final tags = <String, Set<String>>{};
    final folders = <String, String?>{};
    // Stay below SQLite's variable limit even for a 10k-note library.
    for (var offset = 0; offset < ids.length; offset += 400) {
      final chunk = ids.sublist(
        offset,
        offset + 400 > ids.length ? ids.length : offset + 400,
      );
      final placeholders = List.filled(chunk.length, '?').join(',');
      for (final row in store.selectRows(
        '''SELECT note_id, data FROM note_sources
           WHERE note_id IN ($placeholders)
           ORDER BY created_at, id''',
        chunk,
      )) {
        final noteId = row['note_id'] as String;
        sources.putIfAbsent(
          noteId,
          () => NoteSource.fromJson(
            Map<String, dynamic>.from(jsonDecode(row['data'] as String) as Map),
          ),
        );
      }
      for (final row in store.selectRows(
        '''SELECT note_id, COUNT(*) AS c FROM note_questions
           WHERE status='open' AND note_id IN ($placeholders)
           GROUP BY note_id''',
        chunk,
      )) {
        questions[row['note_id'] as String] = (row['c'] as int?) ?? 0;
      }
      for (final row in store.selectRows(
        '''SELECT nt.note_id, nt.tag_id FROM note_tags nt
           WHERE nt.note_id IN ($placeholders)''',
        chunk,
      )) {
        tags
            .putIfAbsent(row['note_id'] as String, () => <String>{})
            .add(row['tag_id'] as String);
      }
      for (final row in store.selectRows(
        '''SELECT note_id, folder_id FROM note_entries
           WHERE is_shortcut=0 AND note_id IN ($placeholders)''',
        chunk,
      )) {
        folders[row['note_id'] as String] = row['folder_id'] as String?;
      }
    }
    return {
      for (final id in ids)
        id: NoteListSummary(
          primarySource: sources[id],
          openQuestions: questions[id] ?? 0,
          tagIds: tags[id] ?? const {},
          folderId: folders[id],
        ),
    };
  }

  Map<String, int> countsByFolder() {
    final result = <String, int>{};
    for (final row in store.selectRows('''
      SELECT e.folder_id AS folder_id, COUNT(*) AS c
      FROM note_entries e JOIN note_documents n ON n.id = e.note_id
      WHERE e.is_shortcut=0 AND e.folder_id IS NOT NULL AND n.lifecycle='active'
      GROUP BY e.folder_id
    ''')) {
      result[row['folder_id'] as String] = (row['c'] as int?) ?? 0;
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Create / save
  // ---------------------------------------------------------------------------

  NoteRecord create({
    String title = '',
    String body = '',
    String? folderId,
    List<NoteSource> sources = const [],
    List<NoteQuestion> questions = const [],
  }) {
    final now = DateTime.now();
    final id = _uuid.v4();
    final note = NoteRecord(
      id: id,
      title: title,
      body: body,
      createdAt: now,
      updatedAt: now,
    );
    return store.transact(() {
      _insertNote(note);
      _insertPrimaryEntry(id, folderId, now);
      for (final source in sources) {
        addSource(
          NoteSource(
            id: source.id.isEmpty ? _uuid.v4() : source.id,
            noteId: id,
            documentId: source.documentId,
            documentHash: source.documentHash,
            page: source.page,
            region: source.region,
            excerpt: source.excerpt,
            sourceType: source.sourceType,
            title: source.title,
            createdAt: source.createdAt,
          ),
        );
      }
      for (final question in questions) {
        addQuestion(
          NoteQuestion(
            id: question.id.isEmpty ? _uuid.v4() : question.id,
            noteId: id,
            text: question.text,
            createdAt: question.createdAt,
          ),
        );
      }
      _insertRevision(note, reason: 'create', manual: false);
      return note;
    });
  }

  /// Saves a full note snapshot. When [expectedRevision] is supplied, a stale
  /// editor is rejected instead of overwriting newer content. A revision is
  /// recorded before a real change, throttled for autosaves.
  NoteRecord save(
    NoteRecord note, {
    String reason = 'auto',
    bool forceRevision = false,
    int? expectedRevision,
  }) {
    final current = getNote(note.id);
    if (current == null) throw const NotesException('笔记不存在或已删除。');
    if (expectedRevision != null && current.revision != expectedRevision) {
      throw const NotesException('笔记已在其他位置更新，请重新打开后再修改。');
    }
    final changed =
        current.title != note.title || current.body != note.body;
    final now = DateTime.now();
    final revision = changed ? current.revision + 1 : current.revision;
    final updated = note.copyWith(
      revision: revision,
      updatedAt: changed || forceRevision ? now : note.updatedAt,
    );
    return store.transact(() {
      if (changed) {
        final latest = store.selectRows(
          'SELECT created_at FROM note_revisions WHERE note_id = ? '
          'ORDER BY created_at DESC LIMIT 1',
          [note.id],
        );
        final lastAt = latest.isEmpty
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                latest.first['created_at'] as int,
              );
        final due =
            forceRevision ||
            lastAt == null ||
            now.difference(lastAt) >= revisionInterval;
        if (due) {
          _insertRevision(current, reason: reason, manual: forceRevision);
        }
      }
      store.executeSql(
        '''UPDATE note_documents SET title=?, body=?, body_format=?,
           body_schema_version=?, revision=?, starred=?, updated_at=?, data=?
           WHERE id=?''',
        [
          updated.title,
          updated.body,
          updated.bodyFormat,
          updated.bodySchemaVersion,
          updated.revision,
          updated.starred ? 1 : 0,
          updated.updatedAt.millisecondsSinceEpoch,
          jsonEncode(updated.toJson()),
          updated.id,
        ],
      );
      _pruneRevisions(updated.id);
      return getNote(updated.id)!;
    });
  }

  void touch(String id) {
    final note = getNote(id);
    if (note == null) return;
    store.executeSql(
      'UPDATE note_documents SET last_opened_at=?, data=? WHERE id=?',
      [
        DateTime.now().millisecondsSinceEpoch,
        jsonEncode(note.copyWith(lastOpenedAt: DateTime.now()).toJson()),
        id,
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Organisation and lifecycle
  // ---------------------------------------------------------------------------

  void move(String noteId, String? folderId) {
    final entry = primaryEntry(noteId);
    if (entry == null) return;
    final folder = folderId != null && _folderExists(folderId);
    final data = {
      ..._entryData(entry),
      'folderId': folder ? folderId : null,
    };
    store.executeSql(
      'UPDATE note_entries SET folder_id=?, data=? WHERE id=?',
      [folder ? folderId : null, jsonEncode(data), entry.id],
    );
  }

  void setStarred(String noteId, bool value) {
    final note = getNote(noteId);
    if (note == null) return;
    final updated = note.copyWith(starred: value, updatedAt: DateTime.now());
    store.executeSql(
      'UPDATE note_documents SET starred=?, updated_at=?, data=? WHERE id=?',
      [
        value ? 1 : 0,
        updated.updatedAt.millisecondsSinceEpoch,
        jsonEncode(updated.toJson()),
        noteId,
      ],
    );
  }

  void setTags(String noteId, Set<String> tagIds) {
    store.transact(() {
      store.executeSql('DELETE FROM note_tags WHERE note_id = ?', [noteId]);
      for (final tagId in tagIds) {
        store.executeSql(
          'INSERT OR IGNORE INTO note_tags (note_id, tag_id) VALUES (?, ?)',
          [noteId, tagId],
        );
      }
    });
  }

  String trash(List<String> ids) {
    final batch = _uuid.v4();
    final now = DateTime.now().millisecondsSinceEpoch;
    store.transact(() {
      for (final id in ids) {
        final note = getNote(id);
        if (note == null || note.isTrashed) continue;
        final updated = note.copyWith(
          lifecycle: NoteLifecycle.trashed,
          deletedBatch: batch,
          trashedAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        store.executeSql(
          '''UPDATE note_documents SET lifecycle='trashed', deleted_batch=?,
             trashed_at=?, updated_at=?, data=? WHERE id=?''',
          [
            batch,
            now,
            updated.updatedAt.millisecondsSinceEpoch,
            jsonEncode(updated.toJson()),
            id,
          ],
        );
      }
    });
    return batch;
  }

  void restore(List<String> ids) {
    store.transact(() {
      for (final id in ids) {
        final note = getNote(id);
        if (note == null) continue;
        final entry = primaryEntry(id);
        final folderValid = entry?.folderId != null &&
            _folderExists(entry!.folderId!);
        final updated = note.copyWith(
          lifecycle: NoteLifecycle.active,
          clearDeletedBatch: true,
          clearTrashedAt: true,
          updatedAt: DateTime.now(),
        );
        store.executeSql(
          '''UPDATE note_documents SET lifecycle='active', deleted_batch=NULL,
             trashed_at=NULL, updated_at=?, data=? WHERE id=?''',
          [
            updated.updatedAt.millisecondsSinceEpoch,
            jsonEncode(updated.toJson()),
            id,
          ],
        );
        if (!folderValid && entry != null) {
          move(id, null);
        }
      }
    });
  }

  void purge(List<String> ids) {
    store.transact(() {
      for (final id in ids) {
        store.executeSql('DELETE FROM note_documents WHERE id=?', [id]);
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Sources, questions, revisions
  // ---------------------------------------------------------------------------

  NoteSource addSource(NoteSource source) {
    final id = source.id.isEmpty ? _uuid.v4() : source.id;
    final value = NoteSource(
      id: id,
      noteId: source.noteId,
      documentId: source.documentId,
      documentHash: source.documentHash,
      page: source.page,
      region: source.region,
      excerpt: source.excerpt,
      sourceType: source.sourceType,
      title: source.title,
      createdAt: source.createdAt,
    );
    store.executeSql(
      '''INSERT INTO note_sources
        (id, note_id, document_id, document_hash, page, region, excerpt,
         source_type, title, created_at, data)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        value.id,
        value.noteId,
        value.documentId,
        value.documentHash,
        value.page,
        jsonEncode(value.region.toJson()),
        value.excerpt,
        value.sourceType,
        value.title,
        value.createdAt.millisecondsSinceEpoch,
        jsonEncode(value.toJson()),
      ],
    );
    return value;
  }

  void deleteSource(String id) =>
      store.executeSql('DELETE FROM note_sources WHERE id=?', [id]);

  NoteQuestion addQuestion(NoteQuestion question) {
    final id = question.id.isEmpty ? _uuid.v4() : question.id;
    final value = NoteQuestion(
      id: id,
      noteId: question.noteId,
      text: question.text,
      createdAt: question.createdAt,
    );
    store.executeSql(
      '''INSERT INTO note_questions
        (id, note_id, text, status, created_at, resolved_at, data)
        VALUES (?, ?, ?, 'open', ?, NULL, ?)''',
      [
        value.id,
        value.noteId,
        value.text,
        value.createdAt.millisecondsSinceEpoch,
        jsonEncode(value.toJson()),
      ],
    );
    return value;
  }

  void toggleQuestion(NoteQuestion question) {
    final resolved = question.isOpen;
    final now = DateTime.now();
    final value = question.copyWith(
      status: resolved
          ? NoteQuestionStatus.resolved
          : NoteQuestionStatus.open,
      resolvedAt: resolved ? now : null,
      clearResolvedAt: !resolved,
    );
    store.executeSql(
      'UPDATE note_questions SET status=?, resolved_at=?, data=? WHERE id=?',
      [
        value.status.name,
        value.resolvedAt?.millisecondsSinceEpoch,
        jsonEncode(value.toJson()),
        value.id,
      ],
    );
  }

  void deleteQuestion(String id) =>
      store.executeSql('DELETE FROM note_questions WHERE id=?', [id]);

  List<NoteRevision> revisions(String noteId) => store
      .selectRows(
        'SELECT data FROM note_revisions WHERE note_id=? ORDER BY created_at DESC, id',
        [noteId],
      )
      .map(
        (row) => NoteRevision.fromJson(
          Map<String, dynamic>.from(jsonDecode(row['data'] as String) as Map),
        ),
      )
      .toList();

  void restoreRevision(NoteRevision revision) {
    final note = getNote(revision.noteId);
    if (note == null) return;
    save(
      note.copyWith(
        title: revision.title,
        body: revision.body,
        updatedAt: DateTime.now(),
      ),
      reason: 'restore',
      forceRevision: true,
      expectedRevision: note.revision,
    );
  }

  String markdown(NoteRecord note, List<NoteSource> sources) {
    final buffer = StringBuffer();
    if (note.title.trim().isNotEmpty) buffer.writeln('# ${note.title.trim()}');
    if (note.body.trim().isNotEmpty) {
      buffer.writeln(note.body.trim());
      buffer.writeln();
    }
    if (sources.isNotEmpty) {
      buffer.writeln('## 来源');
      for (final source in sources) {
        buffer.writeln();
        buffer.writeln(
          '### ${source.title.isEmpty ? '资料' : source.title}'
          '${source.page == null ? '' : ' · 第 ${source.page} 页'}',
        );
        if (source.excerpt.trim().isNotEmpty) {
          for (final line in source.excerpt.trim().split('\n')) {
            buffer.writeln('> $line');
          }
        }
        if (source.documentHash.isNotEmpty) {
          buffer.writeln('\n<!-- document:${source.documentId} '
              'hash:${source.documentHash} page:${source.page} -->');
        }
      }
    }
    return buffer.toString();
  }

  List<NoteRecord> notesReferencing(String documentId, {int limit = 8}) =>
      store
          .selectRows(
            '''SELECT n.data FROM note_sources s
               JOIN note_documents n ON n.id = s.note_id
               WHERE s.document_id = ? AND n.lifecycle = 'active'
               GROUP BY n.id
               ORDER BY n.updated_at DESC
               LIMIT ?''',
            [documentId, limit],
          )
          .map(
            (row) => NoteRecord.fromJson(
              Map<String, dynamic>.from(
                jsonDecode(row['data'] as String) as Map,
              ),
            ),
          )
          .toList();

  Map<String, int> openQuestionCounts(Iterable<String> noteIds) {
    final ids = noteIds.toList();
    if (ids.isEmpty) return const {};
    final placeholders = List.filled(ids.length, '?').join(',');
    return {
      for (final row in store.selectRows(
        '''SELECT note_id, COUNT(*) AS c FROM note_questions
           WHERE status='open' AND note_id IN ($placeholders)
           GROUP BY note_id''',
        ids,
      ))
        row['note_id'] as String: (row['c'] as int?) ?? 0,
    };
  }

  // ---------------------------------------------------------------------------
  // Legacy adapter for the reader panel
  // ---------------------------------------------------------------------------

  String? folderForDocument(String documentId) {
    final rows = store.selectRows(
      '''SELECT folder_id FROM document_entries
         WHERE document_id=? AND is_shortcut=0 ORDER BY sort_key, rowid LIMIT 1''',
      [documentId],
    );
    return rows.isEmpty ? null : rows.first['folder_id'] as String?;
  }

  List<StudyNote> notesForDocument(String documentId) {
    final rows = store.selectRows(
      '''SELECT n.data AS note, s.data AS source
         FROM note_sources s JOIN note_documents n ON n.id=s.note_id
         WHERE s.document_id=? AND n.lifecycle='active'
         ORDER BY n.updated_at DESC, s.created_at''',
      [documentId],
    );
    final seen = <String>{};
    final result = <StudyNote>[];
    for (final row in rows) {
      final note = _note({'data': row['note']});
      if (!seen.add(note.id)) continue;
      final source = NoteSource.fromJson(
        Map<String, dynamic>.from(jsonDecode(row['source'] as String) as Map),
      );
      final noteQuestions = questions(note.id);
      final open = noteQuestions.where((q) => q.isOpen).firstOrNull;
      result.add(
        StudyNote(
          id: note.id,
          documentId: source.documentId ?? documentId,
          documentHash: source.documentHash,
          page: source.page ?? 1,
          region: source.region,
          understanding: note.body,
          evidenceText: source.excerpt,
          question: open?.text ?? '',
          createdAt: note.createdAt,
        ),
      );
    }
    for (final legacy in store.getNotes(documentId)) {
      if (seen.add(legacy.id)) {
        result.add(legacy);
      }
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  void _insertNote(NoteRecord note) {
    store.executeSql(
      '''INSERT INTO note_documents
        (id, title, body, body_format, body_schema_version, revision, starred,
         lifecycle, deleted_batch, trashed_at, created_at, updated_at,
         last_opened_at, data)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        note.id,
        note.title,
        note.body,
        note.bodyFormat,
        note.bodySchemaVersion,
        note.revision,
        note.starred ? 1 : 0,
        note.lifecycle.name,
        note.deletedBatch,
        note.trashedAt?.millisecondsSinceEpoch,
        note.createdAt.millisecondsSinceEpoch,
        note.updatedAt.millisecondsSinceEpoch,
        note.lastOpenedAt?.millisecondsSinceEpoch ?? 0,
        jsonEncode(note.toJson()),
      ],
    );
  }

  void _insertPrimaryEntry(String noteId, String? folderId, DateTime now) {
    final id = _uuid.v4();
    final validFolder = folderId != null && _folderExists(folderId);
    final data = {
      'id': id,
      'noteId': noteId,
      'folderId': validFolder ? folderId : null,
      'isShortcut': false,
      'alias': null,
      'sortKey': 0,
      'createdAt': now.toIso8601String(),
    };
    store.executeSql(
      '''INSERT INTO note_entries
        (id, note_id, folder_id, is_shortcut, alias, sort_key, created_at, data)
        VALUES (?, ?, ?, 0, NULL, 0, ?, ?)''',
      [
        id,
        noteId,
        validFolder ? folderId : null,
        now.millisecondsSinceEpoch,
        jsonEncode(data),
      ],
    );
  }

  void _insertRevision(
    NoteRecord note, {
    required String reason,
    required bool manual,
  }) {
    final id = _uuid.v4();
    final revision = NoteRevision(
      id: id,
      noteId: note.id,
      revision: note.revision,
      title: note.title,
      body: note.body,
      reason: reason,
      createdAt: DateTime.now(),
      manual: manual,
    );
    store.executeSql(
      '''INSERT INTO note_revisions
        (id, note_id, revision, title, body, reason, created_at, manual, data)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        id,
        note.id,
        revision.revision,
        revision.title,
        revision.body,
        reason,
        revision.createdAt.millisecondsSinceEpoch,
        manual ? 1 : 0,
        jsonEncode(revision.toJson()),
      ],
    );
  }

  void _pruneRevisions(String noteId) {
    final auto = store.selectRows(
      '''SELECT id FROM note_revisions
         WHERE note_id=? AND manual=0 ORDER BY created_at DESC, id''',
      [noteId],
    );
    if (auto.length <= maxAutoRevisions) return;
    for (final row in auto.skip(maxAutoRevisions)) {
      store.executeSql('DELETE FROM note_revisions WHERE id=?', [
        row['id'] as String,
      ]);
    }
  }

  bool _folderExists(String id) => store
      .selectRows(
        'SELECT 1 FROM library_folders WHERE id=? AND deleted_at IS NULL',
        [id],
      )
      .isNotEmpty;

  NoteRecord _note(Map<String, Object?> row) => NoteRecord.fromJson(
    Map<String, dynamic>.from(jsonDecode(row['data'] as String) as Map),
  );

  NoteEntry _entry(Map<String, Object?> row) => NoteEntry(
    id: row['id'] as String,
    noteId: row['note_id'] as String,
    folderId: row['folder_id'] as String?,
    isShortcut: (row['is_shortcut'] as int? ?? 0) != 0,
    alias: row['alias'] as String?,
    sortKey: (row['sort_key'] as int?) ?? 0,
    createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
  );

  Map<String, dynamic> _entryData(NoteEntry entry) => {
    'id': entry.id,
    'noteId': entry.noteId,
    'folderId': entry.folderId,
    'isShortcut': entry.isShortcut,
    'alias': entry.alias,
    'sortKey': entry.sortKey,
    'createdAt': entry.createdAt.toIso8601String(),
  };
}
