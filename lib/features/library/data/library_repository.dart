import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../../core/local_store.dart';
import '../../../core/models.dart';
import '../../review/data/review_repository.dart';
import '../models/library_models.dart';

/// Storage access for folders, placements, tags, soft deletion and search
/// metadata. The repository keeps the managed original untouched: it only
/// changes relations, so moving a folder never changes a document id or the
/// pages notes and courses already point at.
class LibraryRepository {
  LibraryRepository(this.store);

  final LocalStore store;
  static const _uuid = Uuid();

  /// Technical protection only; the product does not limit nesting to a smaller
  /// number. Moves check the full subtree height before writing.
  static const int maxFolderDepth = 64;

  // ---------------------------------------------------------------------------
  // Folders
  // ---------------------------------------------------------------------------

  List<LibraryFolder> folders({bool includeDeleted = false}) {
    final rows = store.selectRows(
      '''SELECT data FROM library_folders
      ${includeDeleted ? '' : 'WHERE deleted_at IS NULL'}
      ORDER BY sort_key, name_norm, id''',
    );
    return rows.map(_folder).toList();
  }

  LibraryFolder? folder(String id) {
    final rows = store.selectRows(
      'SELECT data FROM library_folders WHERE id = ?',
      [id],
    );
    return rows.isEmpty ? null : _folder(rows.first);
  }

  bool folderNameExists(
    String? parentId,
    String name, {
    String? exceptId,
  }) {
    final rows = store.selectRows(
      '''SELECT id FROM library_folders
      WHERE COALESCE(parent_id, '') = ? AND name_norm = ?
        AND deleted_at IS NULL
        ${exceptId == null ? '' : 'AND id != ?'}''',
      [parentId ?? '', normalizeFolderName(name), ?exceptId],
    );
    return rows.isNotEmpty;
  }

  int nextFolderSortKey(String? parentId) {
    final value = store
        .selectRows(
          '''SELECT COALESCE(MAX(sort_key), 0) AS value FROM library_folders
          WHERE COALESCE(parent_id, '') = ?''',
          [parentId ?? ''],
        )
        .first['value'];
    return (value as int? ?? 0) + 1024;
  }

  LibraryFolder insertFolder({
    required String name,
    String? parentId,
    int? sortKey,
    FolderColorMode colorMode = FolderColorMode.inherit,
    int? colorValue,
    String? icon,
    String? description,
  }) {
    final now = DateTime.now();
    final folder = LibraryFolder(
      id: _uuid.v4(),
      parentId: parentId,
      name: name.trim(),
      sortKey: sortKey ?? nextFolderSortKey(parentId),
      colorMode: colorMode,
      colorValue: colorMode == FolderColorMode.custom ? colorValue : null,
      icon: icon,
      description: description?.trim() ?? '',
      createdAt: now,
      updatedAt: now,
    );
    _writeFolder(folder, insert: true);
    return folder;
  }

  void updateFolder(LibraryFolder folder) {
    final updated = folder.copyWith(
      revision: folder.revision + 1,
      updatedAt: DateTime.now(),
    );
    _writeFolder(updated, insert: false);
  }

  void _writeFolder(LibraryFolder folder, {required bool insert}) {
    if (insert) {
      store.executeSql(
        '''INSERT INTO library_folders
          (id, parent_id, name, name_norm, sort_key, color_mode, color_value,
           icon, description, revision, created_at, updated_at, deleted_batch,
           deleted_at, data)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        [
          folder.id,
          folder.parentId,
          folder.name,
          folder.nameNorm,
          folder.sortKey,
          folder.colorMode.name,
          folder.colorValue,
          folder.icon,
          folder.description,
          folder.revision,
          folder.createdAt.millisecondsSinceEpoch,
          folder.updatedAt.millisecondsSinceEpoch,
          folder.deletedBatch,
          folder.deletedAt?.millisecondsSinceEpoch,
          jsonEncode(folder.toJson()),
        ],
      );
      return;
    }
    store.executeSql(
      '''UPDATE library_folders SET parent_id = ?, name = ?, name_norm = ?,
        sort_key = ?, color_mode = ?, color_value = ?, icon = ?,
        description = ?, revision = ?, updated_at = ?, deleted_batch = ?,
        deleted_at = ?, data = ? WHERE id = ?''',
      [
        folder.parentId,
        folder.name,
        folder.nameNorm,
        folder.sortKey,
        folder.colorMode.name,
        folder.colorValue,
        folder.icon,
        folder.description,
        folder.revision,
        folder.updatedAt.millisecondsSinceEpoch,
        folder.deletedBatch,
        folder.deletedAt?.millisecondsSinceEpoch,
        jsonEncode(folder.toJson()),
        folder.id,
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Entries
  // ---------------------------------------------------------------------------

  List<DocumentEntry> entries({
    String? folderId,
    bool unfiled = false,
    bool includeDeleted = false,
  }) {
    final conditions = <String>[];
    final parameters = <Object?>[];
    if (!includeDeleted) conditions.add('deleted_at IS NULL');
    if (folderId != null) {
      conditions.add('folder_id = ?');
      parameters.add(folderId);
    }
    if (unfiled) conditions.add('folder_id IS NULL');
    final where = conditions.isEmpty ? '' : 'WHERE ${conditions.join(' AND ')}';
    return store
        .selectRows(
          'SELECT data FROM document_entries $where ORDER BY sort_key, created_at, id',
          parameters,
        )
        .map(_entry)
        .toList();
  }

  List<DocumentEntry> entriesForDocument(
    String documentId, {
    bool includeDeleted = false,
  }) => store
      .selectRows(
        '''SELECT data FROM document_entries WHERE document_id = ?
        ${includeDeleted ? '' : 'AND deleted_at IS NULL'}
        ORDER BY is_shortcut, sort_key''',
        [documentId],
      )
      .map(_entry)
      .toList();

  DocumentEntry? primaryEntry(String documentId) {
    final rows = store.selectRows(
      '''SELECT data FROM document_entries
      WHERE document_id = ? AND is_shortcut = 0 AND deleted_at IS NULL''',
      [documentId],
    );
    return rows.isEmpty ? null : _entry(rows.first);
  }

  /// Includes an entry already in the trash. Restoring one item reads it here
  /// so the caller never has to guess which batch or folder it belonged to.
  DocumentEntry? entryById(String id, {bool includeDeleted = true}) {
    final rows = store.selectRows(
      'SELECT data FROM document_entries WHERE id = ?',
      [id],
    );
    if (rows.isEmpty) return null;
    final entry = _entry(rows.first);
    if (!includeDeleted && entry.isDeleted) return null;
    return entry;
  }

  DocumentEntry? primaryEntryIncludingDeleted(String documentId) {
    final rows = store.selectRows(
      '''SELECT data FROM document_entries
      WHERE document_id = ? AND is_shortcut = 0
      ORDER BY deleted_at IS NOT NULL, created_at LIMIT 1''',
      [documentId],
    );
    return rows.isEmpty ? null : _entry(rows.first);
  }

  void deleteEntryRow(String id) {
    store.executeSql('DELETE FROM document_entries WHERE id = ?', [id]);
  }

  /// True while a batch still owns folders, entries or documents. A per-item
  /// restore removes the batch row only after the last item is back.
  bool batchHasRemainingItems(String batchId) {
    final entries = store.selectRows(
      'SELECT 1 FROM document_entries WHERE deleted_batch = ? LIMIT 1',
      [batchId],
    );
    if (entries.isNotEmpty) return true;
    final folders = store.selectRows(
      'SELECT 1 FROM library_folders WHERE deleted_batch = ? LIMIT 1',
      [batchId],
    );
    if (folders.isNotEmpty) return true;
    return store
        .selectRows(
          'SELECT 1 FROM documents WHERE deleted_batch = ? LIMIT 1',
          [batchId],
        )
        .isNotEmpty;
  }

  DocumentEntry? entryInFolder(String? folderId, String documentId) {
    final rows = store.selectRows(
      '''SELECT data FROM document_entries
      WHERE COALESCE(folder_id, '') = ? AND document_id = ?
        AND deleted_at IS NULL''',
      [folderId ?? '', documentId],
    );
    return rows.isEmpty ? null : _entry(rows.first);
  }

  int nextEntrySortKey(String? folderId) {
    final value = store
        .selectRows(
          '''SELECT COALESCE(MAX(sort_key), 0) AS value FROM document_entries
          WHERE COALESCE(folder_id, '') = ?''',
          [folderId ?? ''],
        )
        .first['value'];
    return (value as int? ?? 0) + 1024;
  }

  DocumentEntry insertEntry({
    required String documentId,
    String? folderId,
    bool isShortcut = false,
    String? alias,
    int? sortKey,
  }) {
    final now = DateTime.now();
    final entry = DocumentEntry(
      id: _uuid.v4(),
      documentId: documentId,
      folderId: folderId,
      isShortcut: isShortcut,
      alias: alias,
      sortKey: sortKey ?? nextEntrySortKey(folderId),
      createdAt: now,
    );
    store.executeSql(
      '''INSERT INTO document_entries
        (id, folder_id, document_id, is_shortcut, alias, sort_key, created_at,
         data)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        entry.id,
        entry.folderId,
        entry.documentId,
        entry.isShortcut ? 1 : 0,
        entry.alias,
        entry.sortKey,
        entry.createdAt.millisecondsSinceEpoch,
        jsonEncode(entry.toJson()),
      ],
    );
    return entry;
  }

  void updateEntry(DocumentEntry entry) {
    store.executeSql(
      '''UPDATE document_entries SET folder_id = ?, alias = ?, sort_key = ?,
        deleted_batch = ?, deleted_at = ?, data = ? WHERE id = ?''',
      [
        entry.folderId,
        entry.alias,
        entry.sortKey,
        entry.deletedBatch,
        entry.deletedAt?.millisecondsSinceEpoch,
        jsonEncode(entry.toJson()),
        entry.id,
      ],
    );
  }

  /// Ensures the document has exactly one primary placement. Imports call this
  /// after the document row exists; a duplicate import reuses the existing
  /// entry instead of creating a second primary location.
  DocumentEntry ensurePrimaryEntry(String documentId) {
    final existing = primaryEntry(documentId);
    if (existing != null) return existing;
    return insertEntry(documentId: documentId);
  }

  // ---------------------------------------------------------------------------
  // Tags
  // ---------------------------------------------------------------------------

  List<LibraryTag> tags() => store
      .selectRows('SELECT data FROM library_tags ORDER BY name_norm')
      .map(
        (row) => LibraryTag.fromJson(
          Map<String, dynamic>.from(jsonDecode(row['data'] as String) as Map),
        ),
      )
      .toList();

  LibraryTag? tagByNorm(String nameNorm) {
    final rows = store.selectRows(
      'SELECT data FROM library_tags WHERE name_norm = ?',
      [nameNorm],
    );
    return rows.isEmpty ? null : LibraryTag.fromJson(_json(rows.first));
  }

  LibraryTag createTag(String name, {int? colorValue}) {
    final tag = LibraryTag(
      id: _uuid.v4(),
      name: name.trim(),
      nameNorm: normalizeFolderName(name),
      colorValue: colorValue,
      createdAt: DateTime.now(),
    );
    store.executeSql(
      '''INSERT INTO library_tags (id, name, name_norm, color_value, created_at, data)
      VALUES (?, ?, ?, ?, ?, ?)''',
      [
        tag.id,
        tag.name,
        tag.nameNorm,
        tag.colorValue,
        tag.createdAt.millisecondsSinceEpoch,
        jsonEncode(tag.toJson()),
      ],
    );
    return tag;
  }

  void renameTag(LibraryTag tag, String name) {
    final updated = tag.copyWith(
      name: name.trim(),
      nameNorm: normalizeFolderName(name),
    );
    store.executeSql(
      'UPDATE library_tags SET name = ?, name_norm = ?, data = ? WHERE id = ?',
      [updated.name, updated.nameNorm, jsonEncode(updated.toJson()), tag.id],
    );
  }

  void deleteTag(String id) {
    store.executeSql('DELETE FROM library_tags WHERE id = ?', [id]);
  }

  Map<String, Set<String>> documentTagIds() {
    final result = <String, Set<String>>{};
    for (final row in store.selectRows(
      'SELECT document_id, tag_id FROM document_tags',
    )) {
      result
          .putIfAbsent(row['document_id'] as String, () => <String>{})
          .add(row['tag_id'] as String);
    }
    return result;
  }

  void setDocumentTags(String documentId, Set<String> tagIds) {
    store.transact(() {
      store.executeSql('DELETE FROM document_tags WHERE document_id = ?', [
        documentId,
      ]);
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final tagId in tagIds) {
        store.executeSql(
          'INSERT INTO document_tags (document_id, tag_id, created_at) VALUES (?, ?, ?)',
          [documentId, tagId, now],
        );
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Counts
  // ---------------------------------------------------------------------------

  LibraryCounts counts() {
    final activeDocuments = store
        .selectRows("SELECT COUNT(*) AS value FROM documents WHERE lifecycle = 'active'")
        .first['value'] as int;
    final unfiled = store
        .selectRows(
          '''SELECT COUNT(*) AS value FROM document_entries e
          JOIN documents d ON d.id = e.document_id
          WHERE e.folder_id IS NULL AND e.deleted_at IS NULL
            AND d.lifecycle = 'active' AND e.is_shortcut = 0''',
        )
        .first['value'] as int;
    final starred = store
        .selectRows(
          "SELECT COUNT(*) AS value FROM documents WHERE lifecycle = 'active' AND starred = 1",
        )
        .first['value'] as int;
    final trash = store
        .selectRows(
          "SELECT COUNT(*) AS value FROM documents WHERE lifecycle != 'active'",
        )
        .first['value'] as int;
    final folders = <String, int>{};
    for (final row in store.selectRows(
      '''SELECT e.folder_id AS folder_id, COUNT(*) AS value
      FROM document_entries e JOIN documents d ON d.id = e.document_id
      WHERE e.deleted_at IS NULL AND e.folder_id IS NOT NULL
        AND d.lifecycle = 'active'
      GROUP BY e.folder_id''',
    )) {
      folders[row['folder_id'] as String] = row['value'] as int;
    }
    return LibraryCounts(
      all: activeDocuments,
      unfiled: unfiled,
      starred: starred,
      trash: trash,
      folders: folders,
    );
  }

  // ---------------------------------------------------------------------------
  // Deletion batches
  // ---------------------------------------------------------------------------

  List<DeletionBatch> deletionBatches() => store
      .selectRows('SELECT data FROM deletion_batches ORDER BY created_at DESC')
      .map(_batch)
      .toList();

  DeletionBatch? deletionBatch(String id) {
    final rows = store.selectRows(
      'SELECT data FROM deletion_batches WHERE id = ?',
      [id],
    );
    return rows.isEmpty ? null : _batch(rows.first);
  }

  DeletionBatch insertDeletionBatch({
    required String kind,
    required String label,
    String? rootId,
    required int itemCount,
    required int documentCount,
    Map<String, Object?> details = const {},
  }) {
    final batch = DeletionBatch(
      id: _uuid.v4(),
      kind: kind,
      label: label,
      rootId: rootId,
      createdAt: DateTime.now(),
      itemCount: itemCount,
      documentCount: documentCount,
      details: details,
    );
    store.executeSql(
      '''INSERT INTO deletion_batches
        (id, kind, label, root_id, created_at, item_count, document_count, data)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        batch.id,
        batch.kind,
        batch.label,
        batch.rootId,
        batch.createdAt.millisecondsSinceEpoch,
        batch.itemCount,
        batch.documentCount,
        jsonEncode(batch.toJson()),
      ],
    );
    return batch;
  }

  void deleteDeletionBatch(String id) {
    store.executeSql('DELETE FROM deletion_batches WHERE id = ?', [id]);
  }

  // ---------------------------------------------------------------------------
  // Search helpers
  // ---------------------------------------------------------------------------

  /// Documents whose visible metadata matches [query]. Full-text snippets are
  /// added by the controller from the existing local FTS index, always limited
  /// to active documents.
  Set<String> metadataMatches(String query) {
    final like = '%${query.trim().toLowerCase()}%';
    if (query.trim().isEmpty) return {};
    final ids = <String>{};
    for (final row in store.selectRows(
      r'''SELECT id FROM documents
      WHERE lifecycle = 'active' AND (
        lower(json_extract(data, '$.title')) LIKE ?
        OR lower(original_name) LIKE ?
      )''',
      [like, like],
    )) {
      ids.add(row['id'] as String);
    }
    for (final row in store.selectRows(
      '''SELECT DISTINCT e.document_id AS id FROM document_entries e
      JOIN library_folders f ON f.id = e.folder_id
      WHERE e.deleted_at IS NULL AND f.deleted_at IS NULL
        AND (lower(f.name) LIKE ? OR lower(f.description) LIKE ?)''',
      [like, like],
    )) {
      ids.add(row['id'] as String);
    }
    for (final row in store.selectRows(
      '''SELECT DISTINCT e.document_id AS id FROM document_entries e
      JOIN document_tags dt ON dt.document_id = e.document_id
      JOIN library_tags t ON t.id = dt.tag_id
      WHERE e.deleted_at IS NULL AND lower(t.name) LIKE ?''',
      [like],
    )) {
      ids.add(row['id'] as String);
    }
    return ids;
  }

  // ---------------------------------------------------------------------------
  // Purge impact
  // ---------------------------------------------------------------------------

  LibraryPurgeImpact purgeImpactForDocuments(Iterable<String> documentIds) {
    final ids = documentIds.toList();
    if (ids.isEmpty) return const LibraryPurgeImpact();
    final placeholders = List.filled(ids.length, '?').join(',');
    int count(String table, String column) =>
        store
                .selectRows(
                  'SELECT COUNT(*) AS value FROM $table WHERE $column IN ($placeholders)',
                  ids,
                )
                .first['value']
            as int;
    final bytes = store
        .selectRows(
          'SELECT COALESCE(SUM(size_bytes), 0) AS value FROM documents WHERE id IN ($placeholders)',
          ids,
        )
        .first['value'] as int;
    final tasks = count('study_tasks', 'material_document_id');
    final planSources = count('plan_sources', 'document_id');
    final bookQa = count('book_qa_conversations', 'document_id');
    final entries = count('document_entries', 'document_id');
    return LibraryPurgeImpact(
      documents: ids.length,
      entries: entries,
      notes: count('notes', 'document_id'),
      sessions: count('sessions', 'document_id'),
      pages: count('pages', 'document_id'),
      evidence: count('evidence', 'document_id'),
      tasks: tasks,
      planSources: planSources,
      bookQa: bookQa,
      bytes: bytes,
    );
  }

  LibraryPurgeImpact purgeImpactForFolders(Iterable<String> folderIds) {
    final ids = folderIds.toList();
    if (ids.isEmpty) return const LibraryPurgeImpact();
    final placeholders = List.filled(ids.length, '?').join(',');
    final entries = store
        .selectRows(
          '''SELECT document_id, id FROM document_entries
          WHERE deleted_at IS NOT NULL AND folder_id IN ($placeholders)''',
          ids,
        )
        .toList();
    final documentIds = <String>{
      for (final row in entries)
        if (row['document_id'] is String) row['document_id'] as String,
    };
    return purgeImpactForDocuments(documentIds) +
        LibraryPurgeImpact(folders: ids.length, entries: entries.length);
  }

  // ---------------------------------------------------------------------------
  // Low-level helpers used by the controller inside one transaction
  // ---------------------------------------------------------------------------

  int markFoldersDeleted(
    Iterable<String> folderIds,
    String batchId,
    DateTime at,
  ) {
    if (folderIds.isEmpty) return 0;
    final ids = folderIds.toList();
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = store.selectRows(
      'SELECT data FROM library_folders WHERE id IN ($placeholders)',
      ids,
    );
    for (final row in rows) {
      final folder = _folder(row);
      final updated = folder.copyWith(
        deletedBatch: batchId,
        deletedAt: at,
        revision: folder.revision + 1,
        updatedAt: at,
      );
      _writeFolder(updated, insert: false);
    }
    return rows.length;
  }

  int markEntriesDeleted(
    Iterable<String> entryIds,
    String batchId,
    DateTime at,
  ) {
    if (entryIds.isEmpty) return 0;
    final ids = entryIds.toList();
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = store.selectRows(
      'SELECT data FROM document_entries WHERE id IN ($placeholders)',
      ids,
    );
    for (final row in rows) {
      final entry = _entry(row);
      updateEntry(
        entry.copyWith(deletedBatch: batchId, deletedAt: at),
      );
    }
    return rows.length;
  }

  List<DocumentEntry> activeEntriesInFolders(Iterable<String> folderIds) {
    final ids = folderIds.toList();
    if (ids.isEmpty) return const [];
    final placeholders = List.filled(ids.length, '?').join(',');
    return store
        .selectRows(
          '''SELECT data FROM document_entries
          WHERE deleted_at IS NULL AND folder_id IN ($placeholders)''',
          ids,
        )
        .map(_entry)
        .toList();
  }

  List<DocumentEntry> activeShortcutsForDocument(String documentId) => store
      .selectRows(
        '''SELECT data FROM document_entries
        WHERE document_id = ? AND is_shortcut = 1 AND deleted_at IS NULL''',
        [documentId],
      )
      .map(_entry)
      .toList();

  List<LibraryFolder> deletedFoldersInBatch(String batchId) => store
      .selectRows(
        '''SELECT data FROM library_folders
        WHERE deleted_batch = ? AND deleted_at IS NOT NULL''',
        [batchId],
      )
      .map(_folder)
      .toList();

  List<DocumentEntry> deletedEntriesInBatch(String batchId) => store
      .selectRows(
        '''SELECT data FROM document_entries
        WHERE deleted_batch = ? AND deleted_at IS NOT NULL''',
        [batchId],
      )
      .map(_entry)
      .toList();

  List<DocumentRecord> trashedDocuments() => store
      .getDocuments(includeTrashed: true)
      .where((document) => !document.isActive)
      .toList();

  /// Permanently removes documents and their derived data. Schedules keep their
  /// wording and history; the material reference is marked missing just like the
  /// original delete path, so a plan never shows a clickable dead textbook.
  /// Filesystem cleanup is the caller's responsibility and happens only after
  /// this transaction commits.
  void purgeDocuments(Iterable<String> documentIds) {
    for (final id in documentIds) {
      for (final row in store.selectRows(
        'SELECT id, data FROM study_tasks WHERE material_document_id = ?',
        [id],
      )) {
        final data = Map<String, dynamic>.from(
          jsonDecode(row['data'] as String) as Map,
        );
        final material = data['material'];
        if (material is Map) {
          material['missing'] = true;
          data['material'] = material;
        }
        store.executeSql('UPDATE study_tasks SET data = ? WHERE id = ?', [
          jsonEncode(data),
          row['id'],
        ]);
      }
      store.executeSql("DELETE FROM settings WHERE key = ?", ['history:$id']);
      store.executeSql('DELETE FROM documents WHERE id = ?', [id]);
    }
    ReviewRepository(store).handleDocumentsLifecycleChanged(
      documentIds,
      available: false,
      permanentPurge: true,
    );
  }

  void purgeEntriesInBatch(String batchId) {
    store.executeSql(
      'DELETE FROM document_entries WHERE deleted_batch = ?',
      [batchId],
    );
  }

  void purgeFolders(Iterable<String> folderIds) {
    final ids = folderIds.toList();
    if (ids.isEmpty) return;
    // Delete children before parents; entries first because the folder
    // reference uses RESTRICT.
    final folders = <String, LibraryFolder>{};
    for (final id in ids) {
      final value = folder(id);
      if (value != null) folders[id] = value;
    }
    final depth = <String, int>{};
    int depthOf(String id) {
      final cached = depth[id];
      if (cached != null) return cached;
      var level = 0;
      var current = folders[id];
      final seen = <String>{id};
      while (true) {
        final parentId = current?.parentId;
        if (parentId == null ||
            !folders.containsKey(parentId) ||
            !seen.add(parentId)) {
          break;
        }
        level++;
        current = folders[parentId];
      }
      depth[id] = level;
      return level;
    }

    final ordered = ids.toList()..sort((a, b) => depthOf(b).compareTo(depthOf(a)));
    for (final id in ordered) {
      // Folders in other deletion batches may still point at this parent.
      // Keep them restorable at the root instead of failing a foreign key.
      store.executeSql(
        'UPDATE library_folders SET parent_id = NULL WHERE parent_id = ?',
        [id],
      );
      store.executeSql(
        'UPDATE document_entries SET folder_id = NULL WHERE folder_id = ?',
        [id],
      );
      store.executeSql('DELETE FROM library_folders WHERE id = ?', [id]);
    }
  }

  void clearDeletionBatch(String batchId) {
    store.executeSql(
      'UPDATE library_folders SET deleted_batch = NULL, deleted_at = NULL WHERE deleted_batch = ?',
      [batchId],
    );
    store.executeSql(
      'UPDATE document_entries SET deleted_batch = NULL, deleted_at = NULL WHERE deleted_batch = ?',
      [batchId],
    );
  }

  // ---------------------------------------------------------------------------
  // Row decoding
  // ---------------------------------------------------------------------------

  static Map<String, dynamic> _json(Map<String, Object?> row) =>
      Map<String, dynamic>.from(jsonDecode(row['data'] as String) as Map);

  static LibraryFolder _folder(Map<String, Object?> row) =>
      LibraryFolder.fromJson(_json(row));

  static DocumentEntry _entry(Map<String, Object?> row) =>
      DocumentEntry.fromJson(_json(row));

  static DeletionBatch _batch(Map<String, Object?> row) {
    final json = _json(row);
    return DeletionBatch(
      id: json['id'] as String,
      kind: json['kind'] as String,
      label: json['label'] as String,
      rootId: json['rootId'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      itemCount: (json['itemCount'] as num?)?.toInt() ?? 0,
      documentCount: (json['documentCount'] as num?)?.toInt() ?? 0,
      details: json,
    );
  }
}
