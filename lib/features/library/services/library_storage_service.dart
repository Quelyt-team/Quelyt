import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../../core/local_store.dart';
import '../../../core/models.dart';
import '../../../services/document_service.dart';

class LibraryStorageException implements Exception {
  const LibraryStorageException(this.message);
  final String message;
  @override
  String toString() => message;
}

class LibraryStorageReport {
  const LibraryStorageReport({
    this.originalsBytes = 0,
    this.cacheBytes = 0,
    this.importsBytes = 0,
    this.databaseBytes = 0,
    this.trashBytes = 0,
    this.documents = 0,
    this.trashedDocuments = 0,
    this.missingOriginals = const [],
  });

  final int originalsBytes;
  final int cacheBytes;
  final int importsBytes;
  final int databaseBytes;
  final int trashBytes;
  final int documents;
  final int trashedDocuments;
  final List<DocumentRecord> missingOriginals;

  int get rebuildableBytes => cacheBytes + importsBytes;
  int get totalBytes =>
      originalsBytes + cacheBytes + importsBytes + databaseBytes;
  bool get hasMissingOriginals => missingOriginals.isNotEmpty;
}

/// Measures and repairs the app-managed copy area. Nothing here deletes a
/// document, note or OCR correction: "cache" is only render/OCR temporary
/// files, and relinking only accepts bytes whose SHA-256 matches the recorded
/// document hash.
class LibraryStorageService {
  LibraryStorageService({required this.store, required this.documents});

  final LocalStore store;
  final DocumentService documents;

  Future<LibraryStorageReport> measure() async {
    await documents.repairManagedPaths();
    final all = store.getDocuments(includeTrashed: true);
    final missing = <DocumentRecord>[];
    var trashBytes = 0;
    for (final document in all) {
      final file = File(document.filePath);
      if (!await file.exists()) {
        missing.add(document);
        continue;
      }
      if (!document.isActive) {
        trashBytes += document.sizeBytes > 0
            ? document.sizeBytes
            : await file.length();
      }
    }
    final root = documents.directory;
    return LibraryStorageReport(
      originalsBytes: await _directorySize(Directory(p.join(root.path, 'documents'))),
      cacheBytes: await _directorySize(Directory(p.join(root.path, 'cache'))),
      importsBytes: await _directorySize(Directory(p.join(root.path, 'imports'))),
      databaseBytes: await _databaseSize(root),
      trashBytes: trashBytes,
      documents: all.where((document) => document.isActive).length,
      trashedDocuments: all.where((document) => !document.isActive).length,
      missingOriginals: missing,
    );
  }

  /// Deletes only files under the managed `cache` directory. Thumbnails and
  /// rendered pages are rebuilt on demand; OCR text, corrections and notes live
  /// in SQLite and are untouched.
  Future<int> clearRebuildableCache() async {
    final cache = _managedDirectory('cache');
    if (!await cache.exists()) return 0;
    var freed = 0;
    await for (final entity in cache.list(followLinks: false)) {
      freed += await _entitySize(entity);
      if (entity is Directory) {
        await entity.delete(recursive: true);
      } else if (entity is File) {
        await entity.delete();
      }
    }
    return freed;
  }

  Future<List<DocumentRecord>> missingDocuments() async {
    await documents.repairManagedPaths();
    final result = <DocumentRecord>[];
    for (final document in store.getDocuments(includeTrashed: true)) {
      if (!await File(document.filePath).exists()) result.add(document);
    }
    return result;
  }

  /// Rebuilds a missing managed copy from a user-selected file. A hash mismatch
  /// is refused; importing changed content must go through the normal import
  /// path so it becomes a new document version instead of silently replacing
  /// old notes and page references.
  Future<void> relinkOriginal(DocumentRecord document, String sourcePath) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw const LibraryStorageException('选择的原件不存在。');
    }
    final digest = (await sha256.bind(source.openRead()).first).toString();
    if (digest != document.contentHash) {
      throw const LibraryStorageException(
        '文件内容与资料记录不一致，没有替换。请把改变的版本作为新资料导入。',
      );
    }
    var extension = p.extension(sourcePath).toLowerCase();
    if (extension.isEmpty && document.format.isNotEmpty) {
      extension = '.${document.format.toLowerCase()}';
    }
    final targetDirectory = _managedDirectory(
      p.join('documents', document.id),
    );
    await targetDirectory.create(recursive: true);
    final target = File(p.join(targetDirectory.path, 'original$extension'));
    if (p.equals(p.normalize(target.path), p.normalize(sourcePath))) {
      return;
    }
    final reader = await source.open();
    final writer = await target.open(mode: FileMode.write);
    try {
      while (true) {
        final chunk = await reader.read(1024 * 1024);
        if (chunk.isEmpty) break;
        await writer.writeFrom(chunk);
      }
      await writer.flush();
    } finally {
      await reader.close();
      await writer.close();
    }
    final size = await target.length();
    store.saveDocumentRecord(
      document.copyWith(filePath: target.path, sizeBytes: size),
    );
  }

  Future<int> _databaseSize(Directory root) async {
    var total = 0;
    for (final name in [
      'study.sqlite3',
      'study.sqlite3-wal',
      'study.sqlite3-shm',
    ]) {
      final file = File(p.join(root.path, name));
      if (await file.exists()) total += await file.length();
    }
    return total;
  }

  Future<int> _directorySize(Directory directory) async {
    if (!await directory.exists()) return 0;
    var total = 0;
    await for (final entity in directory.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        try {
          total += await entity.length();
        } catch (_) {
          /* A file deleted during measurement is simply not counted. */
        }
      }
    }
    return total;
  }

  Future<int> _entitySize(FileSystemEntity entity) async {
    if (entity is File) {
      try {
        return await entity.length();
      } catch (_) {
        return 0;
      }
    }
    if (entity is Directory) return _directorySize(entity);
    return 0;
  }

  Directory _managedDirectory(String relative) {
    final root = p.normalize(p.absolute(documents.directory.path));
    final target = p.normalize(p.join(root, relative));
    if (!p.isWithin(root, target) && target != root) {
      throw const LibraryStorageException('托管路径越界。');
    }
    return Directory(target);
  }
}

String formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

/// Kept for callers that need a JSON-friendly diagnostics value.
Map<String, Object?> storageReportJson(LibraryStorageReport report) => {
  'originalsBytes': report.originalsBytes,
  'cacheBytes': report.cacheBytes,
  'importsBytes': report.importsBytes,
  'databaseBytes': report.databaseBytes,
  'trashBytes': report.trashBytes,
  'documents': report.documents,
  'trashedDocuments': report.trashedDocuments,
  'missingOriginals': report.missingOriginals.map((d) => d.id).toList(),
};
