import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../core/local_store.dart';
import '../../../core/models.dart';
import '../../../services/document_service.dart';
import '../data/library_repository.dart';
import 'import_models.dart';

/// One queue for "choose files", "choose folder" and platform drops. Every
/// source goes through the same staging, hashing, duplicate and placement
/// rules; a failure never rolls back items that already landed.
class ImportQueue extends ChangeNotifier {
  ImportQueue({
    required this.store,
    required this.documents,
    required this.repository,
    required this.onLibraryChanged,
    this.onNotice,
  });

  final LocalStore store;
  final DocumentService documents;
  final LibraryRepository repository;

  /// Called after a document or placement changed so the library can reload
  /// without the queue owning UI state.
  final VoidCallback onLibraryChanged;
  final void Function(String message)? onNotice;

  static const _uuid = Uuid();
  static const int scanFileLimit = 4000;
  static const int scanDepthLimit = 32;

  final List<ImportBatch> _batches = [];
  bool _running = false;
  bool _cancelRequested = false;

  List<ImportBatch> get batches => List.unmodifiable(_batches);
  bool get busy => _running;
  bool get hasPending => _batches.any((batch) => batch.active);
  ImportBatch? get latest => _batches.isEmpty ? null : _batches.first;
  int get totalBytes => _batches.fold(0, (sum, batch) => sum + batch.bytesTotal);
  int get doneBytes => _batches.fold(0, (sum, batch) => sum + batch.bytesDone);

  int get importedCount => _batches.fold(
    0,
    (sum, batch) => sum + batch.items
        .where((item) => item.status == ImportItemStatus.imported)
        .length,
  );
  int get existingCount =>
      _batches.fold(0, (sum, batch) => sum + batch.existing);
  int get failedCount =>
      _batches.fold(0, (sum, batch) => sum + batch.failed);

  // ---------------------------------------------------------------------------
  // Scanning
  // ---------------------------------------------------------------------------

  Future<DirectoryScan> scanDirectory(String path) async {
    final root = Directory(path);
    if (!await root.exists()) {
      throw FileSystemException('找不到这个文件夹', path);
    }
    final files = <ScannedFile>[];
    final unsupported = <ScannedFile>[];
    final unreadable = <String>[];
    var truncated = false;
    final pending = <(Directory, String)>[(root, '')];
    var seen = 0;
    while (pending.isNotEmpty) {
      final (directory, relative) = pending.removeLast();
      List<FileSystemEntity> entries;
      try {
        entries = await directory.list(followLinks: false).toList();
      } on FileSystemException {
        unreadable.add(relative.isEmpty ? directory.path : relative);
        continue;
      }
      entries.sort((a, b) => a.path.compareTo(b.path));
      for (final entity in entries) {
        seen++;
        if (seen > scanFileLimit) {
          truncated = true;
          break;
        }
        final name = p.basename(entity.path);
        if (name.startsWith('.')) continue;
        final type = await FileSystemEntity.type(
          entity.path,
          followLinks: false,
        );
        if (type == FileSystemEntityType.link) continue;
        if (type == FileSystemEntityType.directory) {
          if (relative.split('/').length >= scanDepthLimit) {
            truncated = true;
            continue;
          }
          pending.add((Directory(entity.path), p.posix.join(relative, name)));
          continue;
        }
        if (type != FileSystemEntityType.file) continue;
        final extension = p.extension(name).toLowerCase();
        int size;
        try {
          size = await File(entity.path).length();
        } on FileSystemException {
          unreadable.add(entity.path);
          continue;
        }
        final scanned = ScannedFile(
          path: entity.path,
          name: name,
          extension: extension,
          sizeBytes: size,
          relativeDirectory: relative,
        );
        if (DocumentService.supportedExtensions.contains(extension)) {
          files.add(scanned);
        } else {
          unsupported.add(scanned);
        }
      }
      if (truncated) break;
    }
    return DirectoryScan(
      rootName: p.basename(root.path),
      files: files,
      unsupported: unsupported,
      unreadable: unreadable,
      truncated: truncated,
    );
  }

  // ---------------------------------------------------------------------------
  // Enqueue
  // ---------------------------------------------------------------------------

  /// Handles a mixed selection: files are queued directly, directories are
  /// scanned and mirrored into a new folder. Files already covered by another
  /// selected directory are skipped, so a parent folder plus one of its files
  /// is never imported twice.
  Future<void> enqueueSources(
    Iterable<String> paths, {
    String? targetFolderId,
  }) async {
    final normalized = <String>[];
    for (final path in paths) {
      final absolute = p.normalize(p.absolute(path));
      if (!normalized.contains(absolute)) normalized.add(absolute);
    }
    final directories = <String>[];
    final files = <String>[];
    for (final path in normalized) {
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        directories.add(path);
      } else if (type == FileSystemEntityType.file) {
        files.add(path);
      }
    }
    files.removeWhere(
      (file) => directories.any((directory) => p.isWithin(directory, file)),
    );
    if (files.isNotEmpty) {
      await enqueueFiles(files, targetFolderId: targetFolderId);
    }
    for (final directory in directories) {
      final scan = await scanDirectory(directory);
      await enqueueDirectory(
        directory,
        scan: scan,
        targetFolderId: targetFolderId,
        keepStructure: true,
      );
    }
  }

  Future<ImportBatch> enqueueFiles(
    Iterable<String> paths, {
    String? targetFolderId,
    String? batchLabel,
  }) async {
    final items = <ImportItem>[];
    final batchId = _uuid.v4();
    final now = DateTime.now();
    for (final path in paths) {
      final absolute = p.normalize(p.absolute(path));
      if (items.any((item) => item.sourcePath == absolute)) continue;
      final name = p.basename(absolute);
      final extension = p.extension(absolute).toLowerCase();
      final item = ImportItem(
        id: _uuid.v4(),
        batchId: batchId,
        sourcePath: absolute,
        sourceName: name,
        extension: extension,
        createdAt: now,
        targetFolderId: targetFolderId,
        status: DocumentService.supportedExtensions.contains(extension)
            ? ImportItemStatus.waiting
            : ImportItemStatus.unsupported,
        message: DocumentService.supportedExtensions.contains(extension)
            ? null
            : '暂不支持 $extension 格式；支持 PDF、JPG 和 PNG。',
      );
      items.add(item);
    }
    if (items.isEmpty) {
      return ImportBatch(
        id: batchId,
        targetFolderId: targetFolderId,
        createdAt: now,
        items: const [],
      );
    }
    final batch = ImportBatch(
      id: batchId,
      targetFolderId: targetFolderId,
      createdAt: now,
      items: items,
    );
    _batches.insert(0, batch);
    _persistBatch(batch);
    for (final item in items) {
      _persistItem(item);
    }
    _notify();
    unawaited(_process());
    return batch;
  }

  Future<ImportBatch> enqueueDirectory(
    String path, {
    DirectoryScan? scan,
    String? targetFolderId,
    bool keepStructure = true,
  }) async {
    final report = scan ?? await scanDirectory(path);
    final batchId = _uuid.v4();
    final now = DateTime.now();
    // A directory import creates its own folder so existing classifications
    // are never silently merged with the dropped tree.
    final rootName = _uniqueFolderName(targetFolderId, report.rootName);
    final rootFolder = repository.insertFolder(
      name: rootName,
      parentId: targetFolderId,
    );
    final items = <ImportItem>[];
    for (final file in report.files) {
      items.add(
        ImportItem(
          id: _uuid.v4(),
          batchId: batchId,
          sourcePath: file.path,
          sourceName: file.name,
          extension: file.extension,
          createdAt: now,
          targetFolderId: rootFolder.id,
          relativeDirectory: keepStructure ? file.relativeDirectory : '',
          bytesTotal: file.sizeBytes,
        ),
      );
    }
    for (final file in report.unsupported) {
      items.add(
        ImportItem(
          id: _uuid.v4(),
          batchId: batchId,
          sourcePath: file.path,
          sourceName: file.name,
          extension: file.extension,
          createdAt: now,
          targetFolderId: rootFolder.id,
          relativeDirectory: keepStructure ? file.relativeDirectory : '',
          status: ImportItemStatus.unsupported,
          bytesTotal: file.sizeBytes,
          message: '暂不支持 ${file.extension} 格式，未导入。',
        ),
      );
    }
    final batch = ImportBatch(
      id: batchId,
      targetFolderId: targetFolderId,
      createdAt: now,
      items: items,
      rootFolderName: rootFolder.name,
      keepStructure: keepStructure,
    )..rootFolderName = rootFolder.name;
    _batches.insert(0, batch);
    _persistBatch(batch);
    for (final item in items) {
      _persistItem(item);
    }
    final skipped = report.unsupported.length;
    if (onNotice != null) {
      onNotice!(
        '「${report.rootName}」发现 ${report.files.length} 个可导入文件'
        '${skipped > 0 ? '，$skipped 个格式不支持' : ''}'
        '${report.unreadable.isNotEmpty ? '，${report.unreadable.length} 项无法读取' : ''}。',
      );
    }
    onLibraryChanged();
    _notify();
    unawaited(_process());
    return batch;
  }

  String _uniqueFolderName(String? parentId, String desired) {
    var name = desired.trim().isEmpty ? '导入的文件夹' : desired.trim();
    var counter = 2;
    while (repository.folderNameExists(parentId, name)) {
      name = '${desired.trim()} ($counter)';
      counter++;
    }
    return name;
  }

  /// Creates nested folders for a dropped directory, reusing already created
  /// segments inside this batch. Returns the folder that should hold the item.
  Future<String?> _resolveTarget(ImportItem item) async {
    final root = item.targetFolderId;
    if (root != null) {
      final folder = repository.folder(root);
      if (folder == null || folder.isDeleted) {
        throw const _ImportTargetMissing();
      }
    }
    if (root == null || item.relativeDirectory.isEmpty) return root;
    var current = root;
    for (final segment in item.relativeDirectory.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      final existing = _childFolder(current, segment);
      if (existing != null) {
        current = existing;
        continue;
      }
      current = repository
          .insertFolder(name: _uniqueFolderName(current, segment), parentId: current)
          .id;
    }
    item.targetFolderId = current;
    return current;
  }

  String? _childFolder(String parentId, String name) {
    for (final folder in repository.folders()) {
      if (folder.parentId == parentId &&
          folder.name.toLowerCase() == name.toLowerCase()) {
        return folder.id;
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Processing
  // ---------------------------------------------------------------------------

  ImportItem? _nextPending() {
    for (final batch in _batches.reversed) {
      for (final item in batch.items) {
        if (item.status == ImportItemStatus.waiting) return item;
      }
    }
    return null;
  }

  Future<void> _process() async {
    if (_running) return;
    _running = true;
    _cancelRequested = false;
    _notify();
    try {
      while (true) {
        final item = _nextPending();
        if (item == null) break;
        if (_cancelRequested) {
          item.status = ImportItemStatus.cancelled;
          item.message = '已取消，未复制。';
          _persistItem(item);
          _notify();
          continue;
        }
        await _processItem(item);
      }
    } finally {
      _running = false;
      _notify();
      onLibraryChanged();
    }
  }

  Future<void> _processItem(ImportItem item) async {
    try {
      final target = await _resolveTarget(item);
      StagedImport staged;
      if (item.stagedPath != null && File(item.stagedPath!).existsSync()) {
        item.status = ImportItemStatus.verifying;
        _notify();
        staged = await documents.adoptStaged(
          item.stagedPath!,
          sourcePath: item.sourcePath,
          sourceName: item.sourceName,
        );
      } else {
        item.status = ImportItemStatus.copying;
        item.bytesDone = 0;
        _persistItem(item);
        _notify();
        staged = await documents.stageFile(
          item.sourcePath,
          batchId: item.batchId,
          onProgress: (done, total) {
            item.bytesDone = done;
            item.bytesTotal = total;
            if (_cancelRequested) {
              throw const _ImportCancelled();
            }
            _notify();
          },
        );
        item.stagedPath = staged.stagedPath;
        item.bytesTotal = staged.sizeBytes;
        item.bytesDone = staged.sizeBytes;
        item.status = ImportItemStatus.verifying;
        _persistItem(item);
        _notify();
      }
      final commit = await documents.commitStaged(
        staged,
        title: p.basenameWithoutExtension(item.sourceName),
      );
      item.stagedPath = null;
      item.documentId = commit.record.id;
      if (commit.duplicate) {
        await _placeDuplicate(item, commit.record, target);
      } else {
        _placeNew(item, commit.record, target);
        item.status = ImportItemStatus.imported;
      }
      item.bytesDone = item.bytesTotal;
      _persistItem(item);
      onLibraryChanged();
      _notify();
    } on _ImportTargetMissing {
      item.status = ImportItemStatus.failed;
      item.error = 'target-missing';
      item.message = '目标文件夹已被删除；暂存副本仍保留，请重新选择目标后重试。';
      _persistItem(item);
      _notify();
    } on _ImportCancelled {
      item.status = ImportItemStatus.cancelled;
      item.message = '已取消，已入库的项目不会删除。';
      _persistItem(item);
      _notify();
    } on FormatException catch (error) {
      item.status = DocumentService.supportedExtensions.contains(item.extension)
          ? ImportItemStatus.failed
          : ImportItemStatus.unsupported;
      item.error = error.message;
      item.message = error.message;
      _deleteStaged(item);
      _persistItem(item);
      _notify();
    } on FileSystemException catch (error) {
      item.status = ImportItemStatus.failed;
      item.error = error.message;
      item.message = '无法读取或写入：${error.message}';
      _persistItem(item);
      _notify();
    } catch (error) {
      item.status = ImportItemStatus.failed;
      item.error = '$error';
      item.message = '导入失败：$error';
      _persistItem(item);
      _notify();
    }
  }

  void _placeNew(ImportItem item, DocumentRecord record, String? target) {
    if (target == null) return;
    final primary = repository.primaryEntry(record.id);
    if (primary == null) {
      repository.insertEntry(documentId: record.id, folderId: target);
      return;
    }
    repository.updateEntry(
      primary.copyWith(
        folderId: target,
        sortKey: repository.nextEntrySortKey(target),
      ),
    );
  }

  Future<void> _placeDuplicate(
    ImportItem item,
    DocumentRecord record,
    String? target,
  ) async {
    item.status = ImportItemStatus.existing;
    if (!record.isActive) {
      item.message = '相同内容已经在回收站；未自动恢复，请到回收站处理。';
      return;
    }
    if (repository.entryInFolder(target, record.id) != null) {
      item.message = '已存在于目标文件夹，没有复制文件。';
      return;
    }
    if (target == null) {
      item.message = '已存在，没有复制文件。';
      return;
    }
    repository.insertEntry(
      documentId: record.id,
      folderId: target,
      isShortcut: true,
    );
    item.message = '内容相同，已在目标文件夹建立快捷方式。';
  }

  void _deleteStaged(ImportItem item) {
    final path = item.stagedPath;
    item.stagedPath = null;
    if (path == null) return;
    try {
      final file = File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      /* A locked staging file is cleaned with the batch later. */
    }
  }

  // ---------------------------------------------------------------------------
  // Queue controls
  // ---------------------------------------------------------------------------

  Future<void> cancelPending() async {
    _cancelRequested = true;
    for (final batch in _batches) {
      for (final item in batch.items) {
        if (item.status == ImportItemStatus.waiting) {
          item.status = ImportItemStatus.cancelled;
          item.message = '已取消，未复制。';
          _persistItem(item);
        }
      }
    }
    _notify();
  }

  Future<void> retry(ImportItem item) async {
    if (item.status == ImportItemStatus.imported ||
        item.status == ImportItemStatus.existing) {
      return;
    }
    item.status = ImportItemStatus.waiting;
    item.error = null;
    item.message = null;
    item.bytesDone = 0;
    _persistItem(item);
    _notify();
    unawaited(_process());
  }

  Future<void> retryFailed() async {
    for (final batch in _batches) {
      for (final item in batch.items) {
        if (item.status == ImportItemStatus.failed ||
            item.status == ImportItemStatus.interrupted) {
          item.status = ImportItemStatus.waiting;
          item.error = null;
          item.message = null;
        }
      }
    }
    _notify();
    unawaited(_process());
  }

  /// Removes finished batches from the panel and the journal. Documents and
  /// placements created by them are not touched.
  void clearFinished() {
    final finished = _batches.where((batch) => !batch.active).toList();
    for (final batch in finished) {
      _batches.remove(batch);
      store.executeSql('DELETE FROM import_batches WHERE id = ?', [batch.id]);
    }
    _notify();
  }

  void dismiss(ImportBatch batch) {
    if (batch.active) return;
    _batches.remove(batch);
    store.executeSql('DELETE FROM import_batches WHERE id = ?', [batch.id]);
    _notify();
  }

  // ---------------------------------------------------------------------------
  // Journal (resume after restart)
  // ---------------------------------------------------------------------------

  Future<void> restoreJournal() async {
    final rows = store.selectRows(
      '''SELECT data FROM import_batches ORDER BY created_at DESC''',
    );
    final batches = <String, ImportBatch>{};
    for (final row in rows) {
      try {
        final data = Map<String, dynamic>.from(
          jsonDecode(row['data'] as String) as Map,
        );
        final batch = ImportBatch(
          id: data['id'] as String,
          targetFolderId: data['targetFolderId'] as String?,
          createdAt: DateTime.parse(data['createdAt'] as String),
          items: <ImportItem>[],
          rootFolderName: data['rootFolderName'] as String?,
          keepStructure: data['keepStructure'] as bool? ?? true,
        );
        batches[batch.id] = batch;
      } catch (_) {
        continue;
      }
    }
    if (batches.isEmpty) return;
    final itemRows = store.selectRows(
      'SELECT data FROM import_items ORDER BY created_at',
    );
    for (final row in itemRows) {
      try {
        final data = Map<String, dynamic>.from(
          jsonDecode(row['data'] as String) as Map,
        );
        final batch = batches[data['batchId'] as String];
        if (batch == null) continue;
        final status = ImportItemStatus.values.asNameMap()[
            data['status'] as String? ?? ''] ??
            ImportItemStatus.failed;
        final item = ImportItem(
          id: data['id'] as String,
          batchId: data['batchId'] as String,
          sourcePath: data['sourcePath'] as String,
          sourceName: data['sourceName'] as String? ??
              p.basename(data['sourcePath'] as String),
          extension: data['extension'] as String? ?? '',
          createdAt: DateTime.parse(data['createdAt'] as String),
          targetFolderId: data['targetFolderId'] as String?,
          relativeDirectory: data['relativeDirectory'] as String? ?? '',
          status: status,
          bytesTotal: (data['bytesTotal'] as num?)?.toInt() ?? 0,
          bytesDone: (data['bytesDone'] as num?)?.toInt() ?? 0,
          documentId: data['documentId'] as String?,
          error: data['error'] as String?,
          message: data['message'] as String?,
          stagedPath: data['stagedPath'] as String?,
        );
        if (status == ImportItemStatus.waiting ||
            status == ImportItemStatus.copying ||
            status == ImportItemStatus.verifying) {
          final staged = item.stagedPath;
          final hasStaged = staged != null && File(staged).existsSync();
          item.status = ImportItemStatus.interrupted;
          item.message = hasStaged
              ? '应用上次关闭时还没完成，可从暂存副本继续。'
              : '应用上次关闭时还没完成；来源可能需要重新选择。';
        }
        batch.items.add(item);
      } catch (_) {
        continue;
      }
    }
    for (final batch in batches.values) {
      if (batch.items.isEmpty &&
          store.selectRows(
                'SELECT 1 FROM import_items WHERE batch_id = ? LIMIT 1',
                [batch.id],
              ).isEmpty) {
        store.executeSql('DELETE FROM import_batches WHERE id = ?', [batch.id]);
        continue;
      }
      _batches.add(batch);
    }
    _batches.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _notify();
  }

  /// Waits until every waiting item reached a terminal state. Automation and
  /// callers that need a deterministic summary use this; the UI keeps observing
  /// progress through notifications instead of blocking.
  Future<void> waitUntilIdle({
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (!_running && _nextPending() == null) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw TimeoutException('Import queue did not finish in time.');
  }

  void _persistBatch(ImportBatch batch) {
    store.executeSql(
      '''INSERT INTO import_batches (id, target_folder_id, created_at, updated_at, data)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET updated_at = excluded.updated_at,
        data = excluded.data''',
      [
        batch.id,
        batch.targetFolderId,
        batch.createdAt.millisecondsSinceEpoch,
        DateTime.now().millisecondsSinceEpoch,
        jsonEncode({
          'id': batch.id,
          'targetFolderId': batch.targetFolderId,
          'createdAt': batch.createdAt.toIso8601String(),
          'rootFolderName': batch.rootFolderName,
          'keepStructure': batch.keepStructure,
        }),
      ],
    );
  }

  void _persistItem(ImportItem item) {
    store.executeSql(
      '''INSERT INTO import_items
        (id, batch_id, source_path, target_folder_id, status, document_id,
         error, bytes_total, bytes_done, created_at, updated_at, data)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET status = excluded.status,
          document_id = excluded.document_id, error = excluded.error,
          bytes_total = excluded.bytes_total, bytes_done = excluded.bytes_done,
          updated_at = excluded.updated_at, data = excluded.data''',
      [
        item.id,
        item.batchId,
        item.sourcePath,
        item.targetFolderId,
        item.status.name,
        item.documentId,
        item.error,
        item.bytesTotal,
        item.bytesDone,
        item.createdAt.millisecondsSinceEpoch,
        DateTime.now().millisecondsSinceEpoch,
        jsonEncode({
          'id': item.id,
          'batchId': item.batchId,
          'sourcePath': item.sourcePath,
          'sourceName': item.sourceName,
          'extension': item.extension,
          'createdAt': item.createdAt.toIso8601String(),
          'targetFolderId': item.targetFolderId,
          'relativeDirectory': item.relativeDirectory,
          'status': item.status.name,
          'bytesTotal': item.bytesTotal,
          'bytesDone': item.bytesDone,
          'documentId': item.documentId,
          'error': item.error,
          'message': item.message,
          'stagedPath': item.stagedPath,
        }),
      ],
    );
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class _ImportTargetMissing implements Exception {
  const _ImportTargetMissing();
}

class _ImportCancelled implements Exception {
  const _ImportCancelled();
}
