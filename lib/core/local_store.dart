import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import 'migrations/schema.dart';
import 'models.dart';
import 'search_index.dart';

/// Local SQLite storage. No method in this class makes a network request.
/// API credentials belong in platform secure storage, never in settings.
class LocalStore {
  LocalStore._(this._database, [this._path]) {
    _initialize();
  }

  factory LocalStore.open(String directory) {
    Directory(directory).createSync(recursive: true);
    final path = p.join(directory, 'study.sqlite3');
    return LocalStore._(sqlite3.open(path), path);
  }

  factory LocalStore.inMemory() => LocalStore._(sqlite3.openInMemory());

  static const int currentSchemaVersion = 10;

  final Database _database;
  final String? _path;
  bool _disposed = false;
  final List<String> _backupPaths = [];
  static const _uuid = Uuid();
  int _transactionDepth = 0;

  /// The schema version actually stored in this database.
  int get schemaVersion =>
      _database.select('PRAGMA user_version').first.values.first as int;

  /// All verified snapshots made immediately before schema upgrades in this
  /// process, oldest first. Null/empty for new databases and in-memory stores.
  List<String> get backupPaths => List.unmodifiable(_backupPaths);

  /// The most recent verified pre-upgrade snapshot.
  String? get lastBackupPath =>
      _backupPaths.isEmpty ? null : _backupPaths.last;

  void _initialize() {
    try {
      _initializeSchema();
    } catch (_) {
      if (!_disposed) {
        _database.close();
        _disposed = true;
      }
      rethrow;
    }
  }

  void _initializeSchema() {
    _database.execute('PRAGMA foreign_keys = ON');
    _database.execute('PRAGMA busy_timeout = 5000');
    _database.execute('PRAGMA journal_mode = WAL');
    var version = schemaVersion;
    if (version > currentSchemaVersion) {
      _database.close();
      _disposed = true;
      throw StateError('This library was created by a newer app version.');
    }
    final fresh = version == 0;
    if (version == 0) {
      _migrateToVersion1();
      version = 1;
    }
    if (version == 1) {
      _migrateToVersion2(backup: !fresh);
      version = 2;
    }
    if (version == 2) {
      _migrateToVersion3(backup: !fresh);
      version = 3;
    }
    if (version == 3) {
      _migrateToVersion4(backup: !fresh);
      version = 4;
    }
    if (version == 4) {
      _migrateToVersion5(backup: !fresh);
      version = 5;
    }
    if (version == 5) {
      _migrateToVersion6(backup: !fresh);
      version = 6;
    }
    if (version == 6) {
      _migrateToVersion7(backup: !fresh);
      version = 7;
    }
    if (version == 7) {
      _migrateToVersion8(backup: !fresh);
      version = 8;
    }
    if (version == 8) {
      _migrateToVersion9(backup: !fresh);
      version = 9;
    }
    if (version == 9) {
      _migrateToVersion10(backup: !fresh);
      version = 10;
    }
    assert(version == currentSchemaVersion);
  }

  void _setVersion(int version) {
    _database.execute('PRAGMA user_version = $version');
  }

  void _migrateToVersion1() {
    _transaction(() {
      _database.execute(schemaVersion1);
      _setVersion(1);
    });
  }

  void _migrateToVersion2({required bool backup}) {
    if (backup) {
      _backupBeforeMigration(fromVersion: 1);
    }
    _transaction(() {
      _database.execute(schemaVersion2);
      _setVersion(2);
    });
  }

  void _migrateToVersion3({required bool backup}) {
    if (backup) {
      _backupBeforeMigration(fromVersion: 2);
    }
    _transaction(() {
      _database.execute(schemaVersion3);
      _setVersion(3);
    });
  }

  void _migrateToVersion4({required bool backup}) {
    if (backup) {
      _backupBeforeMigration(fromVersion: 3);
    }
    _transaction(() {
      _database.execute(schemaVersion4);
      _setVersion(4);
    });
  }

  void _migrateToVersion5({required bool backup}) {
    if (backup) {
      _backupBeforeMigration(fromVersion: 4);
    }
    _transaction(() {
      _database.execute(schemaVersion5);
      _setVersion(5);
    });
  }

  void _migrateToVersion6({required bool backup}) {
    if (backup) {
      _backupBeforeMigration(fromVersion: 5);
    }
    _transaction(() {
      _database.execute(schemaVersion6);
      _setVersion(6);
    });
  }

  void _migrateToVersion7({required bool backup}) {
    if (backup) {
      _backupBeforeMigration(fromVersion: 6);
    }
    _transaction(() {
      _database.execute(schemaVersion7);
      _setVersion(7);
    });
  }

  /// Creates the library relations without touching managed originals or
  /// learning records. Every existing document becomes an unfiled primary
  /// entry, and old textbook/paper values are kept as the learning-mode
  /// preference so existing sessions resume exactly as before.
  void _migrateToVersion8({required bool backup}) {
    if (backup) {
      _backupBeforeMigration(fromVersion: 7);
    }
    _transaction(() {
      _database.execute(schemaVersion8);
      _setVersion(8);
      final rows = _database.select(
        'SELECT data FROM documents ORDER BY last_opened_at, rowid',
      );
      var index = 0;
      for (final row in rows) {
        final record = DocumentRecord.fromJson(_decode(row));
        final extension = p
            .extension(record.filePath)
            .replaceFirst('.', '')
            .toLowerCase();
        final originalName = record.originalName.isNotEmpty
            ? record.originalName
            : '${record.title}${extension.isEmpty ? '' : '.$extension'}';
        final migrated = record.copyWith(
          originalName: originalName,
          format: record.format.isEmpty ? extension : record.format,
          addedAt: record.createdAt,
        );
        _writeDocumentColumns(migrated);
        final entryId = _uuid.v4();
        final sortKey = index * 1024;
        _database.execute(
          '''
          INSERT OR IGNORE INTO document_entries
            (id, folder_id, document_id, is_shortcut, alias, sort_key,
             created_at, data)
          VALUES (?, NULL, ?, 0, NULL, ?, ?, ?)
        ''',
          [
            entryId,
            migrated.id,
            sortKey,
            migrated.createdAt.millisecondsSinceEpoch,
            jsonEncode({
              'id': entryId,
              'folderId': null,
              'documentId': migrated.id,
              'isShortcut': false,
              'alias': null,
              'sortKey': sortKey,
              'createdAt': migrated.createdAt.toIso8601String(),
            }),
          ],
        );
        index++;
      }
    });
  }


  /// Moves every old StudyNote into an independent note. The old table stays
  /// for snapshot compatibility; all app code switches to the new tables.
  /// Existing ids are reused so links and copied references keep working.
  void _migrateToVersion9({required bool backup}) {
    if (backup) {
      _backupBeforeMigration(fromVersion: 8);
    }
    _transaction(() {
      _database.execute(schemaVersion9);
      _setVersion(9);
      final documents = <String, DocumentRecord>{};
      for (final row in _database.select('SELECT data FROM documents')) {
        final document = DocumentRecord.fromJson(_decode(row));
        documents[document.id] = document;
      }
      final existing = <String>{
        for (final row in _database.select('SELECT id FROM note_documents'))
          row['id'] as String,
      };
      final rows = _database.select(
        'SELECT data FROM notes ORDER BY created_at, id',
      );
      for (final row in rows) {
        final old = StudyNote.fromJson(_decode(row));
        if (!existing.add(old.id)) continue;
        final document = documents[old.documentId];
        final title = _legacyNoteTitle(old, document);
        final lifecycle = document?.lifecycle ?? DocumentLifecycle.active;
        final deletedBatch = document?.deletedBatch;
        final trashedAt = document?.trashedAt;
        final sourceRegion = old.region.isValid ? old.region : SourceRegion.fullPage;
        final noteData = {
          'id': old.id,
          'title': title,
          'body': old.understanding,
          'bodyFormat': 'markdown',
          'bodySchemaVersion': 1,
          'revision': 1,
          'starred': false,
          'lifecycle': lifecycle.name,
          'deletedBatch': deletedBatch,
          'trashedAt': trashedAt?.toIso8601String(),
          'createdAt': old.createdAt.toIso8601String(),
          'updatedAt': old.createdAt.toIso8601String(),
          'lastOpenedAt': 0,
        };
        _database.execute(
          '''
          INSERT INTO note_documents
            (id, title, body, body_format, body_schema_version, revision,
             starred, lifecycle, deleted_batch, trashed_at, created_at,
             updated_at, last_opened_at, data)
          VALUES (?, ?, ?, 'markdown', 1, 1, 0, ?, ?, ?, ?, ?, 0, ?)
        ''',
          [
            old.id,
            title,
            old.understanding,
            lifecycle.name,
            deletedBatch,
            trashedAt?.millisecondsSinceEpoch,
            old.createdAt.millisecondsSinceEpoch,
            old.createdAt.millisecondsSinceEpoch,
            jsonEncode(noteData),
          ],
        );
        final folderRows = _database.select(
          '''SELECT folder_id FROM document_entries
             WHERE document_id = ? AND is_shortcut = 0
             ORDER BY sort_key, rowid LIMIT 1''',
          [old.documentId],
        );
        final folderId = folderRows.isEmpty
            ? null
            : folderRows.first['folder_id'] as String?;
        final entryId = _uuid.v4();
        final entryData = {
          'id': entryId,
          'noteId': old.id,
          'folderId': folderId,
          'isShortcut': false,
          'alias': null,
          'sortKey': 0,
          'createdAt': old.createdAt.toIso8601String(),
        };
        _database.execute(
          '''
          INSERT INTO note_entries
            (id, note_id, folder_id, is_shortcut, alias, sort_key, created_at, data)
          VALUES (?, ?, ?, 0, NULL, 0, ?, ?)
        ''',
          [
            entryId,
            old.id,
            folderId,
            old.createdAt.millisecondsSinceEpoch,
            jsonEncode(entryData),
          ],
        );
        final sourceId = _uuid.v4();
        final sourceData = {
          'id': sourceId,
          'noteId': old.id,
          'documentId': old.documentId,
          'documentHash': old.documentHash,
          'page': old.page,
          'region': sourceRegion.toJson(),
          'excerpt': old.evidenceText,
          'sourceType': 'document',
          'title': document?.title ?? '',
          'createdAt': old.createdAt.toIso8601String(),
        };
        _database.execute(
          '''
          INSERT INTO note_sources
            (id, note_id, document_id, document_hash, page, region, excerpt,
             source_type, title, created_at, data)
          VALUES (?, ?, ?, ?, ?, ?, ?, 'document', ?, ?, ?)
        ''',
          [
            sourceId,
            old.id,
            old.documentId,
            old.documentHash,
            old.page,
            jsonEncode(sourceRegion.toJson()),
            old.evidenceText,
            document?.title ?? '',
            old.createdAt.millisecondsSinceEpoch,
            jsonEncode(sourceData),
          ],
        );
        if (old.question.trim().isNotEmpty) {
          final questionId = _uuid.v4();
          final questionData = {
            'id': questionId,
            'noteId': old.id,
            'text': old.question,
            'status': 'open',
            'createdAt': old.createdAt.toIso8601String(),
            'resolvedAt': null,
          };
          _database.execute(
            '''
            INSERT INTO note_questions
              (id, note_id, text, status, created_at, resolved_at, data)
            VALUES (?, ?, ?, 'open', ?, NULL, ?)
          ''',
            [
              questionId,
              old.id,
              old.question,
              old.createdAt.millisecondsSinceEpoch,
              jsonEncode(questionData),
            ],
          );
        }
        final revisionId = _uuid.v4();
        final revisionData = {
          'id': revisionId,
          'noteId': old.id,
          'revision': 1,
          'title': title,
          'body': old.understanding,
          'reason': 'migration',
          'createdAt': old.createdAt.toIso8601String(),
          'manual': true,
        };
        _database.execute(
          '''
          INSERT INTO note_revisions
            (id, note_id, revision, title, body, reason, created_at, manual, data)
          VALUES (?, ?, 1, ?, ?, 'migration', ?, 1, ?)
        ''',
          [
            revisionId,
            old.id,
            title,
            old.understanding,
            old.createdAt.millisecondsSinceEpoch,
            jsonEncode(revisionData),
          ],
        );
      }
    });
  }

  void _migrateToVersion10({required bool backup}) {
    if (backup) {
      _backupBeforeMigration(fromVersion: 9);
    }
    _transaction(() {
      _database.execute(schemaVersion10);
      _setVersion(10);

      final documents = <String, DocumentRecord>{};
      for (final row in _database.select('SELECT data FROM documents')) {
        final doc = DocumentRecord.fromJson(_decode(row));
        documents[doc.id] = doc;
      }

      // 1. Migrate reading sessions: separate "needsReview" feedback checks
      // from practice candidates, and inspect every historical attempt rather
      // than only the session's current flag.
      for (final row in _database.select(
        'SELECT data FROM sessions ORDER BY updated_at ASC, id ASC',
      )) {
        final session = StudySession.fromJson(_decode(row));
        final doc = documents[session.documentId];
        final baseTime = session.updatedAt.millisecondsSinceEpoch;

        for (var i = 0; i < session.attempts.length; i++) {
          final attempt = session.attempts[i];
          if (!attempt.needsReview) continue;
          final digest = sha256
              .convert(
                utf8.encode(
                  '${attempt.question}\n${attempt.answer}\n${attempt.feedback}',
                ),
              )
              .toString()
              .substring(0, 8);
          final originKey = 'session_attempt:${session.id}:$i:$digest';
          final checkId = _uuid.v4();
          final checkData = {
            'id': checkId,
            'originKey': originKey,
            'targetType': 'feedback',
            'targetId': '${session.id}:$i',
            'targetVersion': i + 1,
            'sessionId': session.id,
            'documentId': session.documentId,
            'documentTitle': doc?.title ?? '',
            'startPage': session.startPage,
            'endPage': session.endPage,
            'question': attempt.question,
            'answer': attempt.answer,
            'feedback': attempt.feedback,
            'reason': '旧版阅读评语待核对（第 ${i + 1} 次作答）',
            'migratedFromV9': true,
            'status': 'open',
            'createdAt': attempt.createdAt.toIso8601String(),
          };
          _database.execute(
            '''
            INSERT OR IGNORE INTO review_checks
              (id, origin_key, target_type, target_id, target_version,
               item_id, document_id, session_id, attempt_key, reason, status,
               resolution_note, created_at, updated_at, data)
            VALUES (?, ?, 'feedback', ?, ?, NULL, ?, ?, ?, ?, 'open', '', ?, ?, ?)
          ''',
            [
              checkId,
              originKey,
              '${session.id}:$i',
              i + 1,
              session.documentId,
              session.id,
              originKey,
              '旧版阅读评语待核对',
              attempt.createdAt.millisecondsSinceEpoch,
              attempt.createdAt.millisecondsSinceEpoch,
              jsonEncode(checkData),
            ],
          );
        }

        if (session.needsReview) {
          final hasOpenAttemptCheck = session.attempts.any(
            (a) => a.needsReview,
          );
          if (!hasOpenAttemptCheck) {
            final originKey = 'session_check:${session.id}';
            final checkId = _uuid.v4();
            final checkData = {
              'id': checkId,
              'originKey': originKey,
              'targetType': 'feedback',
              'targetId': session.id,
              'targetVersion': session.attempts.length + 1,
              'sessionId': session.id,
              'documentId': session.documentId,
              'documentTitle': doc?.title ?? '',
              'startPage': session.startPage,
              'endPage': session.endPage,
              'question': session.question.isNotEmpty
                  ? session.question
                  : session.goal,
              'answer': session.answer,
              'feedback': session.feedback,
              'reason': '旧版会话反馈待核对',
              'migratedFromV9': true,
              'status': 'open',
              'createdAt': session.updatedAt.toIso8601String(),
            };
            _database.execute(
              '''
              INSERT OR IGNORE INTO review_checks
                (id, origin_key, target_type, target_id, target_version,
                 item_id, document_id, session_id, attempt_key, reason, status,
                 resolution_note, created_at, updated_at, data)
              VALUES (?, ?, 'feedback', ?, 1, NULL, ?, ?, ?, ?, 'open', '', ?, ?, ?)
            ''',
              [
                checkId,
                originKey,
                session.id,
                session.documentId,
                session.id,
                originKey,
                '旧版会话反馈待核对',
                baseTime,
                baseTime,
                jsonEncode(checkData),
              ],
            );
          }
        }

        if (session.attempts.isNotEmpty) {
          final last = session.attempts.last;
          final prompt = last.question.trim().isNotEmpty
              ? last.question.trim()
              : (session.question.trim().isNotEmpty
                    ? session.question.trim()
                    : session.goal.trim());
          if (prompt.isNotEmpty) {
            final originKey = 'session:${session.id}';
            final candidateId = _uuid.v4();
            final candidateData = {
              'id': candidateId,
              'originKey': originKey,
              'sourceType': 'session',
              'documentId': session.documentId,
              'documentHash': doc?.contentHash ?? '',
              'documentTitle': doc?.title ?? '',
              'startPage': session.startPage,
              'endPage': session.endPage,
              'sessionId': session.id,
              'title': doc == null
                  ? '阅读练习候选'
                  : '${doc.title} · 第 ${session.startPage}–${session.endPage} 页',
              'prompt': prompt,
              'answer': last.feedback.trim().isNotEmpty
                  ? last.feedback.trim()
                  : last.answer.trim(),
              'legacyAttempts': [
                for (var idx = 0; idx < session.attempts.length; idx++)
                  {
                    'legacyKey': 'session_attempt:${session.id}:$idx',
                    ...session.attempts[idx].toJson(),
                  },
              ],
              'independenceUnknown': true,
              'migratedFromV9': true,
            };
            _database.execute(
              '''
              INSERT OR IGNORE INTO review_candidates
                (id, origin_key, source_type, document_id, note_id, lesson_id,
                 exercise_id, session_id, title, prompt, answer, hint,
                 explanation, status, linked_item_id, reason, created_at,
                 updated_at, data)
              VALUES (?, ?, 'session', ?, NULL, NULL, NULL, ?, ?, ?, ?, '', ?, 'pending', NULL, ?, ?, ?, ?)
            ''',
              [
                candidateId,
                originKey,
                session.documentId,
                session.id,
                candidateData['title'] as String,
                prompt,
                candidateData['answer'] as String,
                last.feedback.trim(),
                '阅读练习历史候选',
                baseTime,
                baseTime,
                jsonEncode(candidateData),
              ],
            );
          }
        }
      }

      // 2. Migrate ALL daily lesson learning_records chronologically without the
      // legacy 200-log / 20-item caps. Merge same (lessonId, exerciseId) attempts
      // so later "correct" self-checks settle open failure candidates while
      // preserving full prior mistake history.
      final lessons = <String, Map<String, dynamic>>{};
      for (final row in _database.select('SELECT id, data FROM daily_lessons')) {
        lessons[row['id'] as String] = _decode(row);
      }
      final tasks = <String, Map<String, dynamic>>{};
      for (final row in _database.select('SELECT id, data FROM study_tasks')) {
        tasks[row['id'] as String] = _decode(row);
      }

      final lessonBuckets = <String, List<Map<String, dynamic>>>{};
      for (final row in _database.select(
        'SELECT id, task_id, block_id, kind, occurred_at, data '
        'FROM learning_records ORDER BY occurred_at ASC, id ASC',
      )) {
        if (row['kind'] != 'noted') continue;
        final decodedRow = _decode(row);
        final rawNote = decodedRow['note'] as String? ?? '';
        if (rawNote.isEmpty) continue;
        Map<String, dynamic> note;
        try {
          final decoded = jsonDecode(rawNote);
          if (decoded is! Map) continue;
          note = Map<String, dynamic>.from(decoded);
        } catch (_) {
          continue;
        }
        if (note['kind'] != 'lessonAttempt') continue;
        final lessonId = note['lessonId'];
        final exerciseId = note['exerciseId'];
        if (lessonId is! String || exerciseId is! String) continue;
        final key = 'lesson_attempt:$lessonId:$exerciseId';
        lessonBuckets.putIfAbsent(key, () => []).add({
          'recordId': row['id'],
          'taskId': row['task_id'],
          'blockId': row['block_id'],
          'createdAt': row['occurred_at'],
          'selfCheck': note['selfCheck'],
          'answer': note['answer'],
          'lessonId': lessonId,
          'exerciseId': exerciseId,
        });
      }

      for (final entry in lessonBuckets.entries) {
        final events = entry.value;
        final first = events.first;
        final latest = events.last;
        final lessonId = first['lessonId'] as String;
        final exerciseId = first['exerciseId'] as String;
        final hasReviewRequest = events.any((e) => e['selfCheck'] == 'review');
        if (!hasReviewRequest) continue;

        final lesson = lessons[lessonId];
        Map<String, dynamic>? matchedExercise;
        if (lesson != null && lesson['exercises'] is List) {
          for (final ex in lesson['exercises'] as List) {
            if (ex is Map && ex['id'] == exerciseId) {
              matchedExercise = Map<String, dynamic>.from(ex);
              break;
            }
          }
        }
        final taskId = latest['taskId'] as String?;
        final task = taskId == null ? null : tasks[taskId];
        final material = task?['material'] is Map
            ? Map<String, dynamic>.from(task!['material'] as Map)
            : null;
        final docId = material?['documentId'] as String?;
        final docHash = material?['documentHash'] as String? ?? '';
        final latestCheck = latest['selfCheck'] as String? ?? '';
        final settledByLaterSelfCheck = latestCheck == 'correct';
        final prompt = matchedExercise?['prompt'] as String? ??
            '课程练习题（$lessonId / $exerciseId）';
        final referenceAnswer =
            (matchedExercise?['answer'] as String?) ??
            (matchedExercise?['referenceAnswer'] as String?) ??
            '';
        final title = task?['title'] as String? ?? '课程待复习';
        final createdAt = (first['createdAt'] as num).toInt();
        final updatedAt = (latest['createdAt'] as num).toInt();
        final status = settledByLaterSelfCheck ? 'ignored' : 'pending';
        final reason = settledByLaterSelfCheck
            ? '先需复习，后续自评已正确（保留历史）'
            : '课程自评标记需要复习';

        final candidateData = {
          'id': _uuid.v4(),
          'originKey': entry.key,
          'sourceType': 'lesson',
          'documentId': docId,
          'documentHash': docHash,
          'startPage': material?['startPage'],
          'endPage': material?['endPage'],
          'taskId': taskId,
          'lessonId': lessonId,
          'exerciseId': exerciseId,
          'title': title,
          'prompt': prompt,
          'answer': referenceAnswer,
          'selfCheckHistory': events,
          'independenceUnknown': true,
          'settledBySelfCheck': settledByLaterSelfCheck,
          'migratedFromV9': true,
        };
        _database.execute(
          '''
          INSERT OR IGNORE INTO review_candidates
            (id, origin_key, source_type, document_id, note_id, lesson_id,
             exercise_id, session_id, title, prompt, answer, hint,
             explanation, status, linked_item_id, reason, created_at,
             updated_at, data)
          VALUES (?, ?, 'lesson', ?, NULL, ?, ?, NULL, ?, ?, ?, '', ?, ?, NULL, ?, ?, ?, ?)
        ''',
          [
            candidateData['id'] as String,
            entry.key,
            docId,
            lessonId,
            exerciseId,
            title,
            prompt,
            referenceAnswer,
            matchedExercise?['guidance'] as String? ?? '',
            status,
            reason,
            createdAt,
            updatedAt,
            jsonEncode(candidateData),
          ],
        );
      }
    });
  }

  String _legacyNoteTitle(StudyNote note, DocumentRecord? document) {
    String candidate = note.understanding
        .split('\n')
        .firstWhere((line) => line.trim().isNotEmpty, orElse: () => '')
        .trim();
    if (candidate.isEmpty) {
      candidate = note.question
          .split('\n')
          .firstWhere((line) => line.trim().isNotEmpty, orElse: () => '')
          .trim();
    }
    if (candidate.isEmpty) {
      candidate = '${document?.title ?? '资料'} · 第 ${note.page} 页笔记';
    }
    return candidate.length > 60 ? '${candidate.substring(0, 60)}…' : candidate;
  }
  /// A WAL database cannot be copied reliably with a plain file copy. This
  /// writes a consistent snapshot and leaves verification to the caller.
  void snapshotTo(String destination) {
    _checkOpen();
    if (_transactionDepth > 0) {
      throw StateError('A database snapshot cannot be taken inside a transaction.');
    }
    final file = File(destination);
    if (file.existsSync()) file.deleteSync();
    _database.execute('VACUUM INTO ?', [destination]);
  }

  /// A WAL database cannot be copied reliably with a plain file copy. VACUUM
  /// INTO writes a consistent snapshot, which is then opened and checked
  /// before the migration transaction starts.
  void _backupBeforeMigration({required int fromVersion}) {
    final path = _path;
    if (path == null) return;
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('.', '');
    final backup = '$path.v$fromVersion-backup-$stamp';
    _database.execute('VACUUM INTO ?', [backup]);
    Database? check;
    try {
      check = sqlite3.open(backup, mode: OpenMode.readOnly);
      final result = check.select('PRAGMA integrity_check').first.values.first;
      if (result != 'ok') {
        throw StateError('Backup integrity check failed: $result');
      }
    } catch (_) {
      check?.close();
      final file = File(backup);
      if (file.existsSync()) file.deleteSync();
      rethrow;
    }
    check.close();
    _backupPaths.add(backup);
  }

  void _checkOpen() {
    if (_disposed) {
      throw StateError('The local library has been closed.');
    }
  }

  T _transaction<T>(T Function() action) {
    _checkOpen();
    _database.execute('BEGIN IMMEDIATE');
    _transactionDepth++;
    try {
      final result = action();
      _transactionDepth--;
      _database.execute('COMMIT');
      return result;
    } catch (_) {
      _transactionDepth--;
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  /// Runs [action] atomically. Nested document writes join the transaction
  /// opened by a caller such as [importDocument] or the library repository.
  T _atomic<T>(T Function() action) =>
      _transactionDepth > 0 ? action() : _transaction(action);

  static Map<String, dynamic> _decode(Row row) =>
      Map<String, dynamic>.from(jsonDecode(row['data'] as String) as Map);

  void upsertDocument(DocumentRecord document) {
    _checkOpen();
    _validateDocument(document);
    final existing = getDocument(document.id);
    if (existing != null && existing.contentHash != document.contentHash) {
      throw ArgumentError('Import a changed file as a new document version.');
    }
    // A reader progress save must never move a document out of the trash or
    // overwrite a name the user changed while the page was rendering. Identity,
    // placement metadata and lifecycle belong to the library layer.
    final merged = existing == null
        ? document
        : document.copyWith(
            title: existing.title,
            kind: existing.kind,
            filePath: existing.filePath,
            originalName: existing.originalName.isEmpty
                ? document.originalName
                : existing.originalName,
            format: existing.format.isEmpty
                ? document.format
                : existing.format,
            sizeBytes: existing.sizeBytes == 0
                ? document.sizeBytes
                : existing.sizeBytes,
            lifecycle: existing.lifecycle,
            lifecycleVersion: existing.lifecycleVersion,
            starred: existing.starred,
            addedAt: existing.addedAt,
            createdAt: existing.createdAt,
            deletedBatch: existing.deletedBatch,
            clearDeletedBatch: existing.deletedBatch == null,
            trashedAt: existing.trashedAt,
            clearTrashedAt: existing.trashedAt == null,
          );
    _atomic(() {
      _writeDocumentColumns(merged);
      if (existing == null) {
        _ensurePrimaryEntry(merged);
      }
    });
  }


  void _validateDocument(DocumentRecord document) {
    if (document.id.isEmpty ||
        document.contentHash.isEmpty ||
        document.pageCount < 1 ||
        document.currentPage < 1 ||
        document.currentPage > document.pageCount) {
      throw ArgumentError('Invalid document or reading page.');
    }
  }

  void _writeDocumentColumns(DocumentRecord document) {
    _database.execute(
      '''
      INSERT INTO documents (
        id, content_hash, kind, last_opened_at, original_name, format,
        size_bytes, lifecycle, lifecycle_version, starred, learning_mode,
        added_at, deleted_batch, trashed_at, data
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        content_hash=excluded.content_hash,
        kind=excluded.kind,
        last_opened_at=excluded.last_opened_at,
        original_name=excluded.original_name,
        format=excluded.format,
        size_bytes=excluded.size_bytes,
        lifecycle=excluded.lifecycle,
        lifecycle_version=excluded.lifecycle_version,
        starred=excluded.starred,
        learning_mode=excluded.learning_mode,
        added_at=excluded.added_at,
        deleted_batch=excluded.deleted_batch,
        trashed_at=excluded.trashed_at,
        data=excluded.data
    ''',
      [
        document.id,
        document.contentHash,
        document.kind.name,
        document.lastOpenedAt.millisecondsSinceEpoch,
        document.originalName,
        document.format,
        document.sizeBytes,
        document.lifecycle.name,
        document.lifecycleVersion,
        document.starred ? 1 : 0,
        document.kind.name,
        document.addedAt.millisecondsSinceEpoch,
        document.deletedBatch,
        document.trashedAt?.millisecondsSinceEpoch,
        jsonEncode(document.toJson()),
      ],
    );
  }

  /// Every active document has exactly one primary placement. Documents
  /// created by older code paths or by tests still become reachable in the
  /// library instead of disappearing from "unfiled".
  void _ensurePrimaryEntry(DocumentRecord document) {
    final existing = _database.select(
      '''SELECT id FROM document_entries
      WHERE document_id = ? AND is_shortcut = 0 AND deleted_at IS NULL''',
      [document.id],
    );
    if (existing.isNotEmpty) return;
    final entryId = _uuid.v4();
    final sortKey = _nextEntrySortKey(null);
    final createdAt = document.addedAt;
    _database.execute(
      '''
      INSERT INTO document_entries
        (id, folder_id, document_id, is_shortcut, alias, sort_key,
         created_at, data)
      VALUES (?, NULL, ?, 0, NULL, ?, ?, ?)
    ''',
      [
        entryId,
        document.id,
        sortKey,
        createdAt.millisecondsSinceEpoch,
        jsonEncode({
          'id': entryId,
          'folderId': null,
          'documentId': document.id,
          'isShortcut': false,
          'alias': null,
          'sortKey': sortKey,
          'createdAt': createdAt.toIso8601String(),
        }),
      ],
    );
  }

  int _nextEntrySortKey(String? folderId) {
    final rows = _database.select(
      '''SELECT COALESCE(MAX(sort_key), 0) AS value FROM document_entries
      WHERE COALESCE(folder_id, '') = ?''',
      [folderId ?? ''],
    );
    return (rows.first['value'] as int) + 1024;
  }

  List<DocumentRecord> getDocuments({
    DocumentKind? kind,
    bool includeTrashed = false,
  }) {
    _checkOpen();
    final conditions = <String>[];
    final parameters = <Object?>[];
    if (!includeTrashed) conditions.add("lifecycle = 'active'");
    if (kind != null) {
      conditions.add('kind = ?');
      parameters.add(kind.name);
    }
    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';
    final rows = _database.select('''
      SELECT data FROM documents $where
      ORDER BY last_opened_at DESC, id
    ''', parameters);
    return rows.map((row) => DocumentRecord.fromJson(_decode(row))).toList();
  }

  DocumentRecord? getDocument(String id) {
    _checkOpen();
    final rows = _database.select('SELECT data FROM documents WHERE id = ?', [
      id,
    ]);
    return rows.isEmpty ? null : DocumentRecord.fromJson(_decode(rows.first));
  }

  /// Duplicate detection is based on the managed copy's hash, never the file
  /// name. Trashed matches are returned with their lifecycle so the import
  /// queue can ask instead of silently restoring or duplicating them.
  DocumentRecord? findDocumentByHash(String hash) {
    _checkOpen();
    final rows = _database.select(
      '''SELECT data FROM documents WHERE content_hash = ?
      ORDER BY CASE lifecycle WHEN 'active' THEN 0 WHEN 'trashed' THEN 1 ELSE 2 END,
               added_at, id
      LIMIT 1''',
      [hash],
    );
    return rows.isEmpty ? null : DocumentRecord.fromJson(_decode(rows.first));
  }

  /// Saves only reading progress. Background page renders use this so a stale
  /// record cannot overwrite a rename or a lifecycle change.
  DocumentRecord saveReadingProgress(
    String id, {
    required int page,
    required DateTime lastOpenedAt,
  }) {
    _checkOpen();
    return _atomic(() {
      final document = getDocument(id);
      if (document == null) throw ArgumentError('Document is not in the library.');
      if (!document.isActive) {
        throw StateError('This document is in the trash.');
      }
      if (page < 1 || page > document.pageCount) {
        throw RangeError.range(page, 1, document.pageCount, 'page');
      }
      final updated = document.copyWith(
        currentPage: page,
        lastOpenedAt: lastOpenedAt,
      );
      _writeDocumentColumns(updated);
      return updated;
    });
  }

  DocumentRecord renameDocument(String id, String title) {
    _checkOpen();
    final trimmed = title.trim();
    if (trimmed.isEmpty) throw ArgumentError('Document title cannot be empty.');
    return _atomic(() {
      final document = getDocument(id);
      if (document == null) throw ArgumentError('Document is not in the library.');
      final updated = document.copyWith(title: trimmed);
      _writeDocumentColumns(updated);
      return updated;
    });
  }

  DocumentRecord setDocumentStarred(String id, bool starred) {
    _checkOpen();
    return _atomic(() {
      final document = getDocument(id);
      if (document == null) throw ArgumentError('Document is not in the library.');
      final updated = document.copyWith(starred: starred);
      _writeDocumentColumns(updated);
      return updated;
    });
  }

  DocumentRecord setDocumentLearningMode(String id, DocumentKind kind) {
    _checkOpen();
    return _atomic(() {
      final document = getDocument(id);
      if (document == null) throw ArgumentError('Document is not in the library.');
      final updated = document.copyWith(kind: kind);
      _writeDocumentColumns(updated);
      return updated;
    });
  }

  /// Raw row write for the library repository, which changes lifecycle and
  /// identity fields inside its own transaction. Prefer the narrow methods
  /// above from feature code.
  void saveDocumentRecord(DocumentRecord document) {
    _checkOpen();
    _validateDocument(document);
    _writeDocumentColumns(document);
  }

  /// Removes database records and FTS entries. The import service separately
  /// removes its managed local copy and render cache, never the external file.
  ///
  /// Schedule tasks keep their wording, page range and history, but the
  /// material reference is marked missing so a deleted document cannot become
  /// a silently broken "open textbook" action.
  void deleteDocument(String id) {
    _transaction(() {
      final linked = _database.select(
        'SELECT id, data FROM study_tasks WHERE material_document_id = ?',
        [id],
      );
      for (final row in linked) {
        final data = _decode(row);
        final material = data['material'];
        if (material is Map) {
          material['missing'] = true;
          data['material'] = material;
        }
        _database.execute('UPDATE study_tasks SET data = ? WHERE id = ?', [
          jsonEncode(data),
          row['id'],
        ]);
      }
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
    if (!document.isActive) {
      throw StateError('Document is in the trash.');
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

  /// Controlled access for feature repositories (the schedule uses the same
  /// connection so a draft application and the calendar revision share one
  /// transaction). Feature code must not open a second database.
  List<Map<String, Object?>> selectRows(
    String sql, [
    List<Object?> parameters = const [],
  ]) {
    _checkOpen();
    return _database
        .select(sql, parameters)
        .map((row) => Map<String, Object?>.from(row))
        .toList();
  }

  /// Executes one statement inside or outside a transaction and returns the
  /// number of modified rows for optimistic checks.
  int executeSql(String sql, [List<Object?> parameters = const []]) {
    _checkOpen();
    _database.execute(sql, parameters);
    return _database.updatedRows;
  }

  /// Whether a SQLite transaction opened via [transact] is currently active.
  bool get inTransaction => _transactionDepth > 0;

  /// Runs [action] atomically. Nested calls are not allowed: compose the
  /// operations inside one callback instead of opening a second transaction.
  T transact<T>(T Function() action) => _transaction(action);

  void dispose() {
    if (_disposed) {
      return;
    }
    _database.close();
    _disposed = true;
  }
}
