import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../../../core/local_store.dart';
import '../../../services/document_service.dart';

class LibraryBackupException implements Exception {
  const LibraryBackupException(this.message);
  final String message;
  @override
  String toString() => message;
}

class BackupReport {
  const BackupReport({
    required this.path,
    required this.documents,
    required this.bytes,
    this.includeTrash = true,
    this.warnings = const [],
  });

  final String path;
  final int documents;
  final int bytes;
  final bool includeTrash;
  final List<String> warnings;

  String get summary =>
      '已备份 $documents 份资料 · ${_size(bytes)}'
      '${warnings.isEmpty ? '' : ' · ${warnings.length} 个提醒'}';

  static String _size(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(0)} KB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class BackupValidation {
  const BackupValidation({
    required this.path,
    this.manifest,
    this.schemaVersion = 0,
    this.documents = 0,
    this.bytes = 0,
    this.errors = const [],
    this.warnings = const [],
  });

  final String path;
  final Map<String, dynamic>? manifest;
  final int schemaVersion;
  final int documents;
  final int bytes;
  final List<String> errors;
  final List<String> warnings;

  bool get ok => errors.isEmpty;
  bool get includeTrash => manifest?['includeTrash'] as bool? ?? true;
  String get createdAt => manifest?['createdAt'] as String? ?? '';
}

class RestoreResult {
  const RestoreResult({
    required this.applied,
    this.backupPath,
    this.preRestorePath,
    this.error,
  });

  final bool applied;
  final String? backupPath;
  final String? preRestorePath;
  final String? error;
}

/// Whole-library backup and restore.
///
/// A package contains a consistent SQLite snapshot, the managed originals and
/// a manifest with sizes and hashes. Preparing a restore only stages and
/// validates the package; applying it happens before the next launch opens the
/// database, so no live reader or OCR job is ever running against half a
/// library. The previous library is moved aside, not deleted.
class LibraryBackupService {
  LibraryBackupService({required this.store, required this.documents});

  final LocalStore store;
  final DocumentService documents;

  static const int formatVersion = 1;
  static const String manifestName = 'manifest.json';
  static const String databaseName = 'library.sqlite3';
  static const String _stagingName = 'restore-staging';
  static const String _requestName = 'restore-request.json';
  static const String _resultName = 'restore-result.json';

  Future<BackupReport> create(
    String destination, {
    bool includeTrash = true,
  }) async {
    final destinationDirectory = Directory(destination);
    if (!await destinationDirectory.exists()) {
      throw const LibraryBackupException('备份位置不存在。');
    }
    final managed = p.normalize(p.absolute(documents.directory.path));
    final target = p.normalize(p.absolute(destination));
    if (target == managed || p.isWithin(managed, target)) {
      throw const LibraryBackupException('不能把备份写入应用托管目录。');
    }
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '')
        .replaceAll('.', '')
        .replaceAll('-', '');
    var name = 'Quelyt-backup-$stamp';
    var counter = 2;
    while (await Directory(p.join(destination, name)).exists()) {
      name = 'Quelyt-backup-$stamp-$counter';
      counter++;
    }
    final temp = Directory(
      p.join(destination, '.$name.tmp'),
    );
    if (await temp.exists()) await temp.delete(recursive: true);
    await temp.create(recursive: true);
    final warnings = <String>[];
    try {
      final databaseFile = File(p.join(temp.path, databaseName));
      store.snapshotTo(databaseFile.path);
      _sanitizeSnapshot(databaseFile.path, includeTrash: includeTrash);
      final schemaVersion = _schemaVersion(databaseFile.path);
      final databaseHash = await _sha256(databaseFile);
      final databaseBytes = await databaseFile.length();

      final entries = <Map<String, Object?>>[];
      var bytes = databaseBytes;
      final documentsInBackup = store
          .getDocuments(includeTrashed: includeTrash)
          .toList();
      for (final document in documentsInBackup) {
        var extension = p.extension(document.filePath).toLowerCase();
        if (extension.isEmpty && document.format.isNotEmpty) {
          extension = '.${document.format.toLowerCase()}';
        }
        final relative = 'originals/${document.id}/original$extension';
        final source = File(document.filePath);
        if (!await source.exists()) {
          warnings.add('${document.title}：托管原件缺失，备份只含记录。');
          entries.add({
            'id': document.id,
            'contentHash': document.contentHash,
            'format': document.format,
            'relativePath': null,
            'missing': true,
            'trashed': !document.isActive,
          });
          continue;
        }
        final targetFile = File(p.join(temp.path, relative));
        await targetFile.parent.create(recursive: true);
        await _copyStreaming(source, targetFile);
        final hash = await _sha256(targetFile);
        final size = await targetFile.length();
        bytes += size;
        if (hash != document.contentHash) {
          warnings.add('${document.title}：托管副本与记录的哈希不一致。');
        }
        entries.add({
          'id': document.id,
          'contentHash': document.contentHash,
          'format': document.format,
          'relativePath': relative,
          'sha256': hash,
          'size': size,
          'missing': false,
          'trashed': !document.isActive,
        });
      }
      final manifest = <String, dynamic>{
        'formatVersion': formatVersion,
        'createdAt': DateTime.now().toIso8601String(),
        'schemaVersion': schemaVersion,
        'includeTrash': includeTrash,
        'database': {
          'relativePath': databaseName,
          'sha256': databaseHash,
          'size': databaseBytes,
        },
        'documents': entries,
        'counts': {
          'documents': entries.length,
          'trashed': entries.where((entry) => entry['trashed'] == true).length,
          'missing': entries.where((entry) => entry['missing'] == true).length,
        },
        'note':
            '研究数据与原件；API Key 保存在系统凭据库，不进入备份。',
      };
      await File(
        p.join(temp.path, manifestName),
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(manifest));

      final validation = await validate(temp.path);
      if (!validation.ok) {
        throw LibraryBackupException(
          '备份自检失败：${validation.errors.join('；')}',
        );
      }
      final finalDirectory = Directory(p.join(destination, name));
      await temp.rename(finalDirectory.path);
      return BackupReport(
        path: finalDirectory.path,
        documents: entries.length,
        bytes: bytes,
        includeTrash: includeTrash,
        warnings: warnings,
      );
    } catch (_) {
      if (await temp.exists()) await temp.delete(recursive: true);
      rethrow;
    }
  }

  static Future<BackupValidation> validate(String packagePath) async {
    final directory = Directory(packagePath);
    if (!await directory.exists()) {
      return BackupValidation(
        path: packagePath,
        errors: const ['备份文件夹不存在。'],
      );
    }
    final errors = <String>[];
    final warnings = <String>[];
    Map<String, dynamic>? manifest;
    var schemaVersion = 0;
    var documents = 0;
    var bytes = 0;
    final manifestFile = File(p.join(packagePath, manifestName));
    if (!await manifestFile.exists()) {
      return BackupValidation(
        path: packagePath,
        errors: ['缺少 manifest.json。'],
      );
    }
    try {
      manifest = Map<String, dynamic>.from(
        jsonDecode(await manifestFile.readAsString()) as Map,
      );
    } catch (_) {
      return BackupValidation(
        path: packagePath,
        errors: ['manifest.json 无法解析。'],
      );
    }
    if (manifest['formatVersion'] != formatVersion) {
      errors.add('备份格式版本不受支持。');
    }
    final database = manifest['database'];
    if (database is! Map) {
      errors.add('备份缺少数据库信息。');
    } else {
      final databasePath = p.join(
        packagePath,
        database['relativePath'] as String? ?? databaseName,
      );
      final databaseFile = File(databasePath);
      if (!await databaseFile.exists()) {
        errors.add('备份缺少数据库文件。');
      } else {
        final size = await databaseFile.length();
        bytes += size;
        final expected = database['sha256'] as String?;
        if (expected != null && await _sha256(databaseFile) != expected) {
          errors.add('数据库校验和不匹配。');
        }
        if (size != (database['size'] as num?)?.toInt()) {
          errors.add('数据库大小与清单不一致。');
        }
        try {
          final db = sqlite3.open(databasePath, mode: OpenMode.readOnly);
          try {
            final integrity = db
                .select('PRAGMA integrity_check')
                .first
                .values
                .first;
            if (integrity != 'ok') errors.add('数据库完整性检查失败。');
            schemaVersion =
                db.select('PRAGMA user_version').first.values.first as int;
            if (schemaVersion > LocalStore.currentSchemaVersion) {
              errors.add('备份来自更新的应用版本，当前版本无法恢复。');
            }
          } finally {
            db.close();
          }
        } catch (_) {
          errors.add('数据库无法打开。');
        }
      }
    }
    final entries = manifest['documents'];
    if (entries is! List) {
      errors.add('清单缺少资料列表。');
    } else {
      for (final value in entries) {
        if (value is! Map) continue;
        documents++;
        final relative = value['relativePath'] as String?;
        if (relative == null || value['missing'] == true) {
          warnings.add('清单中有资料缺少原件。');
          continue;
        }
        final file = File(p.join(packagePath, relative));
        if (!await file.exists()) {
          errors.add('缺少原件：$relative');
          continue;
        }
        bytes += await file.length();
        final hash = await _sha256(file);
        if (hash != value['sha256']) {
          errors.add('原件校验和不匹配：$relative');
        }
        if (value['contentHash'] is String &&
            hash != value['contentHash'] &&
            value['sha256'] is String &&
            hash == value['sha256']) {
          warnings.add('原件与资料记录的哈希不一致：$relative');
        }
        if ((value['size'] as num?)?.toInt() != await file.length()) {
          errors.add('原件大小不匹配：$relative');
        }
      }
    }
    return BackupValidation(
      path: packagePath,
      manifest: manifest,
      schemaVersion: schemaVersion,
      documents: documents,
      bytes: bytes,
      errors: errors,
      warnings: warnings,
    );
  }

  /// Validates and copies the package into the app's restore staging area.
  /// Nothing in the live library changes until the next launch applies it.
  static Future<BackupValidation> prepareRestore(
    String packagePath,
    String libraryDirectory,
  ) async {
    final validation = await validate(packagePath);
    if (!validation.ok) {
      throw LibraryBackupException(validation.errors.join('；'));
    }
    final library = Directory(libraryDirectory);
    await library.create(recursive: true);
    final staging = Directory(p.join(library.path, _stagingName));
    if (await staging.exists()) await staging.delete(recursive: true);
    await staging.create(recursive: true);
    try {
      await _copyFile(
        File(p.join(packagePath, manifestName)),
        File(p.join(staging.path, manifestName)),
      );
      await _copyFile(
        File(p.join(packagePath, databaseName)),
        File(p.join(staging.path, databaseName)),
      );
      for (final value in validation.manifest!['documents'] as List) {
        if (value is! Map) continue;
        final relative = value['relativePath'] as String?;
        if (relative == null) continue;
        await _copyFile(
          File(p.join(packagePath, relative)),
          File(p.join(staging.path, relative)),
        );
      }
      final staged = await validate(staging.path);
      if (!staged.ok) {
        throw LibraryBackupException(
          '暂存副本自检失败：${staged.errors.join('；')}',
        );
      }
      await File(p.join(library.path, _requestName)).writeAsString(
        jsonEncode({
          'stagingPath': staging.path,
          'sourcePackage': packagePath,
          'preparedAt': DateTime.now().toIso8601String(),
        }),
      );
      return staged;
    } catch (_) {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
  }

  /// Runs before the database is opened. On failure the previous library is
  /// put back and an error is recorded instead of leaving a partial restore.
  static Future<RestoreResult?> applyPendingRestore(
    String libraryDirectory,
  ) async {
    final library = Directory(libraryDirectory);
    final requestFile = File(p.join(library.path, _requestName));
    if (!await requestFile.exists()) return null;
    Map<String, dynamic> request;
    try {
      request = Map<String, dynamic>.from(
        jsonDecode(await requestFile.readAsString()) as Map,
      );
    } catch (_) {
      await _recordResult(libraryDirectory, const RestoreResult(
        applied: false,
        error: '恢复请求无法读取。',
      ));
      await requestFile.delete();
      return const RestoreResult(applied: false, error: '恢复请求无法读取。');
    }
    final stagingPath = request['stagingPath'] as String?;
    final sourcePackage = request['sourcePackage'] as String?;
    final validation = stagingPath == null
        ? const BackupValidation(path: '', errors: ['恢复暂存目录缺失。'])
        : await validate(stagingPath);
    if (!validation.ok) {
      await recoverInterruptedRestore(libraryDirectory);
      await _recordResult(
        libraryDirectory,
        RestoreResult(
          applied: false,
          backupPath: sourcePackage,
          error: validation.errors.join('；'),
        ),
      );
      await requestFile.delete();
      if (stagingPath != null && await Directory(stagingPath).exists()) {
        await Directory(stagingPath).delete(recursive: true);
      }
      return RestoreResult(
        applied: false,
        backupPath: sourcePackage,
        error: validation.errors.join('；'),
      );
    }
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final previous = Directory(p.join(library.path, 'pre-restore-$stamp'));
    final moved = <String>[];
    try {
      await previous.create(recursive: true);
      for (final name in [
        'study.sqlite3',
        'study.sqlite3-wal',
        'study.sqlite3-shm',
        'documents',
        'cache',
        'imports',
      ]) {
        final source = FileSystemEntity.typeSync(p.join(library.path, name));
        if (source == FileSystemEntityType.notFound) continue;
        await _moveEntity(p.join(library.path, name), p.join(previous.path, name));
        moved.add(name);
      }
      await _copyFile(
        File(p.join(validation.path, databaseName)),
        File(p.join(library.path, 'study.sqlite3')),
      );
      final documentsDirectory = Directory(
        p.join(library.path, 'documents'),
      );
      await documentsDirectory.create(recursive: true);
      for (final value in validation.manifest!['documents'] as List) {
        if (value is! Map) continue;
        final relative = value['relativePath'] as String?;
        if (relative == null) continue;
        final id = value['id'] as String;
        final extension = p.extension(relative);
        final target = File(
          p.join(documentsDirectory.path, id, 'original$extension'),
        );
        await target.parent.create(recursive: true);
        await _copyFile(File(p.join(validation.path, relative)), target);
      }
      await _recordResult(
        libraryDirectory,
        RestoreResult(
          applied: true,
          backupPath: sourcePackage,
          preRestorePath: previous.path,
        ),
      );
      await requestFile.delete();
      final staging = Directory(validation.path);
      if (await staging.exists()) await staging.delete(recursive: true);
      return RestoreResult(
        applied: true,
        backupPath: sourcePackage,
        preRestorePath: previous.path,
      );
    } catch (error) {
      // Roll back the files that were moved aside.
      try {
        for (final name in [
          'study.sqlite3',
          'study.sqlite3-wal',
          'study.sqlite3-shm',
          'documents',
          'cache',
          'imports',
        ]) {
          final target = p.join(library.path, name);
          if (FileSystemEntity.typeSync(target) !=
              FileSystemEntityType.notFound) {
            await _deleteEntity(target);
          }
        }
        for (final name in moved) {
          final source = p.join(previous.path, name);
          if (FileSystemEntity.typeSync(source) !=
              FileSystemEntityType.notFound) {
            await _moveEntity(source, p.join(library.path, name));
          }
        }
      } catch (_) {
        /* The pre-restore folder remains for manual recovery. */
      }
      await _recordResult(
        libraryDirectory,
        RestoreResult(
          applied: false,
          backupPath: sourcePackage,
          preRestorePath: previous.path,
          error: '$error',
        ),
      );
      await requestFile.delete();
      return RestoreResult(
        applied: false,
        backupPath: sourcePackage,
        preRestorePath: previous.path,
        error: '$error',
      );
    }
  }

  /// If a previous restore was interrupted after moving the old library aside
  /// but before installing a new database, put the newest pre-restore copy
  /// back. Without this a crash mid-restore would open an empty library.
  static Future<bool> recoverInterruptedRestore(String libraryDirectory) async {
    final library = Directory(libraryDirectory);
    if (!await library.exists()) return false;
    if (await File(p.join(library.path, 'study.sqlite3')).exists()) {
      return false;
    }
    final candidates = <Directory>[];
    await for (final entity in library.list()) {
      if (entity is Directory &&
          p.basename(entity.path).startsWith('pre-restore-')) {
        candidates.add(entity);
      }
    }
    candidates.sort((a, b) => b.path.compareTo(a.path));
    for (final candidate in candidates) {
      if (!await File(
        p.join(candidate.path, 'study.sqlite3'),
      ).exists()) {
        continue;
      }
      for (final name in [
        'study.sqlite3',
        'study.sqlite3-wal',
        'study.sqlite3-shm',
        'documents',
        'cache',
        'imports',
      ]) {
        final source = p.join(candidate.path, name);
        if (FileSystemEntity.typeSync(source) ==
            FileSystemEntityType.notFound) {
          continue;
        }
        final target = p.join(library.path, name);
        if (FileSystemEntity.typeSync(target) !=
            FileSystemEntityType.notFound) {
          await _deleteEntity(target);
        }
        await _moveEntity(source, target);
      }
      return true;
    }
    return false;
  }

  /// Last restore outcome, shown in settings and used for diagnostics.
  static Future<Map<String, dynamic>?> readLastResult(
    String libraryDirectory,
  ) async {
    final file = File(p.join(libraryDirectory, _resultName));
    if (!await file.exists()) return null;
    try {
      return Map<String, dynamic>.from(
        jsonDecode(await file.readAsString()) as Map,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> _recordResult(
    String libraryDirectory,
    RestoreResult result,
  ) async {
    try {
      await File(p.join(libraryDirectory, _resultName)).writeAsString(
        jsonEncode({
          'applied': result.applied,
          'backupPath': result.backupPath,
          'preRestorePath': result.preRestorePath,
          'error': result.error,
          'at': DateTime.now().toIso8601String(),
        }),
      );
    } catch (_) {
      /* A result log must not block startup. */
    }
  }

  static void _sanitizeSnapshot(String path, {required bool includeTrash}) {
    final db = sqlite3.open(path);
    try {
      db.execute('PRAGMA foreign_keys = OFF');
      db.execute("DELETE FROM settings WHERE key LIKE 'pending-delete:%'");
      db.execute('DELETE FROM import_items');
      db.execute('DELETE FROM import_batches');
      if (!includeTrash) {
        db.execute("DELETE FROM documents WHERE lifecycle != 'active'");
        db.execute(
          'DELETE FROM document_entries WHERE deleted_at IS NOT NULL OR '
          'folder_id IN (SELECT id FROM library_folders '
          'WHERE deleted_at IS NOT NULL)',
        );
        db.execute('DELETE FROM library_folders WHERE deleted_at IS NOT NULL');
        db.execute('DELETE FROM deletion_batches');
        for (final table in [
          'pages',
          'evidence',
          'notes',
          'sessions',
          'document_entries',
          'document_tags',
          'plan_sources',
          'book_understanding_jobs',
          'book_chapters',
          'book_chunks',
          'book_knowledge_points',
          'book_qa_conversations',
        ]) {
          db.execute(
            'DELETE FROM $table WHERE document_id NOT IN '
            '(SELECT id FROM documents)',
          );
        }
        db.execute(
          'DELETE FROM book_qa_messages WHERE conversation_id NOT IN '
          '(SELECT id FROM book_qa_conversations)',
        );
        db.execute(
          'UPDATE knowledge_items SET source_id = NULL WHERE source_id '
          'NOT IN (SELECT id FROM plan_sources)',
        );
        db.execute(
          'UPDATE study_tasks SET material_document_id = NULL, '
          'material_hash = NULL WHERE material_document_id NOT IN '
          '(SELECT id FROM documents)',
        );
      }
    } finally {
      db.close();
    }
  }

  static int _schemaVersion(String path) {
    final db = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      return db.select('PRAGMA user_version').first.values.first as int;
    } finally {
      db.close();
    }
  }

  static Future<String> _sha256(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();

  static Future<void> _copyStreaming(File source, File target) async {
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
  }

  static Future<void> _copyFile(File source, File target) async {
    await target.parent.create(recursive: true);
    await _copyStreaming(source, target);
  }

  static Future<void> _moveEntity(String source, String target) async {
    final type = FileSystemEntity.typeSync(source);
    if (type == FileSystemEntityType.directory) {
      await Directory(target).parent.create(recursive: true);
      await Directory(source).rename(target);
    } else if (type == FileSystemEntityType.file) {
      await File(target).parent.create(recursive: true);
      await File(source).rename(target);
    }
  }

  static Future<void> _deleteEntity(String path) async {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: true);
    } else if (type == FileSystemEntityType.file) {
      await File(path).delete();
    }
  }
}


