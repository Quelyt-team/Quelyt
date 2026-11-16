import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
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
    this.reviewAssets = 0,
    this.includeTrash = true,
    this.isZip = false,
    this.warnings = const [],
  });

  final String path;
  final int documents;
  final int bytes;
  final int reviewAssets;
  final bool includeTrash;
  final bool isZip;
  final List<String> warnings;

  String get summary =>
      '已备份 $documents 份资料'
      '${reviewAssets > 0 ? ' · $reviewAssets 张复习图片' : ''}'
      ' · ${_size(bytes)}'
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
    this.reviewAssets = 0,
    this.bytes = 0,
    this.errors = const [],
    this.warnings = const [],
  });

  final String path;
  final Map<String, dynamic>? manifest;
  final int schemaVersion;
  final int documents;
  final int reviewAssets;
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

  static const int formatVersion = 2;
  static const List<int> supportedFormatVersions = [1, 2];
  static const String manifestName = 'manifest.json';
  static const String databaseName = 'library.sqlite3';
  static const String reviewAssetsDirName = 'review_assets';
  static const String zipExtension = '.quelyt-backup.zip';
  static const String _stagingName = 'restore-staging';
  static const String _requestName = 'restore-request.json';
  static const String _resultName = 'restore-result.json';
  static const int _maxZipEntries = 100000;
  static const int _maxZipUncompressedBytes = 2 * 1024 * 1024 * 1024;

  Future<BackupReport> create(
    String destination, {
    bool includeTrash = true,
  }) async {
    final destinationDirectory = Directory(destination);
    if (!await destinationDirectory.exists()) {
      throw const LibraryBackupException('备份位置不存在。');
    }
    _ensureOutsideManaged(destination);
    final stamp = _backupStamp();
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
    try {
      final staged = await _buildPackageInDirectory(
        temp,
        includeTrash: includeTrash,
      );
      final finalDirectory = Directory(p.join(destination, name));
      await temp.rename(finalDirectory.path);
      return BackupReport(
        path: finalDirectory.path,
        documents: staged.documents,
        bytes: staged.bytes,
        reviewAssets: staged.reviewAssets,
        includeTrash: includeTrash,
        warnings: staged.warnings,
      );
    } catch (_) {
      if (await temp.exists()) await temp.delete(recursive: true);
      rethrow;
    }
  }

  /// Builds a portable single-file `.quelyt-backup.zip` backup package
  /// containing the SQLite snapshot, originals, and review occlusion assets.
  Future<BackupReport> createZip(
    String destinationDirectoryPath, {
    String? fileName,
    bool includeTrash = true,
  }) async {
    final destinationDirectory = Directory(destinationDirectoryPath);
    if (!await destinationDirectory.exists()) {
      await destinationDirectory.create(recursive: true);
    }
    final resolvedName = (fileName != null && fileName.trim().isNotEmpty)
        ? fileName.trim()
        : 'Quelyt-backup-${_backupStamp()}$zipExtension';
    var targetPath = p.join(destinationDirectory.path, resolvedName);
    if (await File(targetPath).exists()) {
      final stem = resolvedName.endsWith(zipExtension)
          ? resolvedName.substring(0, resolvedName.length - zipExtension.length)
          : p.basenameWithoutExtension(resolvedName);
      final ext = resolvedName.endsWith(zipExtension)
          ? zipExtension
          : p.extension(resolvedName);
      var counter = 2;
      while (await File(targetPath).exists()) {
        targetPath = p.join(destinationDirectory.path, '$stem-$counter$ext');
        counter++;
      }
    }
    final tempDir = await Directory.systemTemp.createTemp('quelyt_zip_backup_');
    final tempZipPath = '$targetPath.tmp';
    try {
      final staged = await _buildPackageInDirectory(
        tempDir,
        includeTrash: includeTrash,
      );
      final encoder = ZipFileEncoder();
      await encoder.zipDirectory(
        tempDir,
        filename: tempZipPath,
        level: ZipFileEncoder.gzip,
      );
      final zipFile = File(tempZipPath);
      await zipFile.rename(targetPath);
      final finalBytes = await File(targetPath).length();
      return BackupReport(
        path: targetPath,
        documents: staged.documents,
        bytes: finalBytes,
        reviewAssets: staged.reviewAssets,
        includeTrash: includeTrash,
        isZip: true,
        warnings: staged.warnings,
      );
    } catch (_) {
      final tmp = File(tempZipPath);
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    } finally {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    }
  }

  void _ensureOutsideManaged(String destination) {
    final managed = p.normalize(p.absolute(documents.directory.path));
    final target = p.normalize(p.absolute(destination));
    if (target == managed || p.isWithin(managed, target)) {
      throw const LibraryBackupException('不能把备份写入应用托管目录。');
    }
  }

  static String _backupStamp() => DateTime.now()
      .toUtc()
      .toIso8601String()
      .replaceAll(':', '')
      .replaceAll('.', '')
      .replaceAll('-', '');

  Future<({int documents, int reviewAssets, int bytes, List<String> warnings})>
  _buildPackageInDirectory(
    Directory targetDir, {
    required bool includeTrash,
  }) async {
    final warnings = <String>[];
    final databaseFile = File(p.join(targetDir.path, databaseName));
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
      final targetFile = File(p.join(targetDir.path, relative));
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

    // Collect review image assets (both referenced in SQLite review_items and
    // any files residing inside <library>/review_assets).
    final assetEntries = <Map<String, Object?>>[];
    final collectedNames = <String>{};
    final referencedAssets = _readReferencedReviewAssets(databaseFile.path);
    for (final ref in referencedAssets) {
      final sourcePath = ref.imagePath;
      final fileName = _safeAssetFileName(p.basename(sourcePath), fallbackId: ref.itemId);
      final source = await _locateReviewAssetFile(
        sourcePath: sourcePath,
        fileName: fileName,
      );
      if (source == null) {
        warnings.add('复习图片缺失：$fileName');
        assetEntries.add({
          'itemId': ref.itemId,
          'fileName': fileName,
          'relativePath': null,
          'missing': true,
        });
        continue;
      }
      if (!collectedNames.add(fileName)) {
        continue;
      }
      final relative = '$reviewAssetsDirName/$fileName';
      final targetFile = File(p.join(targetDir.path, relative));
      await targetFile.parent.create(recursive: true);
      await _copyStreaming(source, targetFile);
      final hash = await _sha256(targetFile);
      final size = await targetFile.length();
      bytes += size;
      assetEntries.add({
        'itemId': ref.itemId,
        'fileName': fileName,
        'relativePath': relative,
        'sha256': hash,
        'size': size,
        'missing': false,
      });
    }
    final assetsDirectory = Directory(
      p.join(documents.directory.path, reviewAssetsDirName),
    );
    if (await assetsDirectory.exists()) {
      await for (final entity in assetsDirectory.list(followLinks: false)) {
        if (entity is! File) continue;
        final fileName = _safeAssetFileName(p.basename(entity.path));
        if (!collectedNames.add(fileName)) continue;
        final relative = '$reviewAssetsDirName/$fileName';
        final targetFile = File(p.join(targetDir.path, relative));
        await targetFile.parent.create(recursive: true);
        await _copyStreaming(entity, targetFile);
        final hash = await _sha256(targetFile);
        final size = await targetFile.length();
        bytes += size;
        assetEntries.add({
          'fileName': fileName,
          'relativePath': relative,
          'sha256': hash,
          'size': size,
          'missing': false,
        });
      }
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
      'reviewAssets': assetEntries,
      'counts': {
        'documents': entries.length,
        'trashed': entries.where((entry) => entry['trashed'] == true).length,
        'missing': entries.where((entry) => entry['missing'] == true).length,
        'reviewAssets': assetEntries.where((entry) => entry['missing'] != true).length,
      },
      'note':
          '研究数据、原件与复习图片；API Key 保存在系统凭据库，不进入备份。',
    };
    await File(
      p.join(targetDir.path, manifestName),
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(manifest));

    final validation = await _validateDirectory(
      targetDir.path,
      displayPath: targetDir.path,
    );
    if (!validation.ok) {
      throw LibraryBackupException(
        '备份自检失败：${validation.errors.join('；')}',
      );
    }
    return (
      documents: entries.length,
      reviewAssets: assetEntries.where((entry) => entry['missing'] != true).length,
      bytes: bytes,
      warnings: warnings,
    );
  }

  Future<File?> _locateReviewAssetFile({
    required String sourcePath,
    required String fileName,
  }) async {
    final direct = File(sourcePath);
    if (await direct.exists()) return direct;
    final managed = File(
      p.join(documents.directory.path, reviewAssetsDirName, fileName),
    );
    if (await managed.exists()) return managed;
    return null;
  }

  static String _safeAssetFileName(String raw, {String? fallbackId}) {
    final cleaned = raw.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').trim();
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
      return '${fallbackId ?? 'asset'}.bin';
    }
    return cleaned;
  }

  static List<({String itemId, String imagePath})> _readReferencedReviewAssets(
    String databasePath,
  ) {
    final db = sqlite3.open(databasePath, mode: OpenMode.readOnly);
    try {
      final tables = db
          .select(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'review_asset_refs'",
          )
          .toList();
      if (tables.isEmpty) return const [];
      final rows = db.select(
        "SELECT owner_id, asset_path FROM review_asset_refs WHERE asset_path IS NOT NULL AND TRIM(asset_path) != ''",
      );
      return [
        for (final row in rows)
          (
            itemId: row['owner_id'] as String? ?? '',
            imagePath: row['asset_path'] as String? ?? '',
          ),
      ];
    } finally {
      db.close();
    }
  }

  static Future<BackupValidation> validate(String packagePath) async {
    if (await File(packagePath).exists()) {
      return validateZip(packagePath);
    }
    return _validateDirectory(packagePath, displayPath: packagePath);
  }

  static Future<BackupValidation> validateZip(String zipPath) async {
    final file = File(zipPath);
    if (!await file.exists()) {
      return BackupValidation(path: zipPath, errors: const ['备份压缩包不存在。']);
    }
    final tempDir = await Directory.systemTemp.createTemp('quelyt_zip_val_');
    try {
      await _extractZipSafely(zipPath, tempDir.path);
      return await _validateDirectory(tempDir.path, displayPath: zipPath);
    } catch (error) {
      return BackupValidation(
        path: zipPath,
        errors: [error.toString()],
      );
    } finally {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    }
  }

  static Future<BackupValidation> _validateDirectory(
    String directoryPath, {
    required String displayPath,
  }) async {
    final directory = Directory(directoryPath);
    if (!await directory.exists()) {
      return BackupValidation(
        path: displayPath,
        errors: const ['备份文件夹不存在。'],
      );
    }
    final errors = <String>[];
    final warnings = <String>[];
    Map<String, dynamic>? manifest;
    var schemaVersion = 0;
    var documents = 0;
    var reviewAssets = 0;
    var bytes = 0;
    final manifestFile = File(p.join(directoryPath, manifestName));
    if (!await manifestFile.exists()) {
      return BackupValidation(
        path: displayPath,
        errors: const ['缺少 manifest.json。'],
      );
    }
    try {
      manifest = Map<String, dynamic>.from(
        jsonDecode(await manifestFile.readAsString()) as Map,
      );
    } catch (_) {
      return BackupValidation(
        path: displayPath,
        errors: const ['manifest.json 无法解析。'],
      );
    }
    final version = manifest['formatVersion'];
    if (version is! int || !supportedFormatVersions.contains(version)) {
      errors.add('备份格式版本不受支持。');
    }
    final database = manifest['database'];
    if (database is! Map) {
      errors.add('备份缺少数据库信息。');
    } else {
      final relDb = database['relativePath'] as String? ?? databaseName;
      final safeDbPath = _resolveWithinRoot(directoryPath, relDb);
      if (safeDbPath == null) {
        errors.add('数据库路径非法。');
      } else {
        final databaseFile = File(safeDbPath);
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
            final db = sqlite3.open(safeDbPath, mode: OpenMode.readOnly);
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
        final resolved = _resolveWithinRoot(directoryPath, relative);
        if (resolved == null) {
          errors.add('原件路径越界：$relative');
          continue;
        }
        final file = File(resolved);
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
    final assetsList = manifest['reviewAssets'];
    if (assetsList is List) {
      for (final value in assetsList) {
        if (value is! Map) continue;
        final relative = value['relativePath'] as String?;
        if (relative == null || value['missing'] == true) {
          warnings.add('清单中有复习图片缺失。');
          continue;
        }
        final resolved = _resolveWithinRoot(directoryPath, relative);
        if (resolved == null) {
          errors.add('复习图片路径越界：$relative');
          continue;
        }
        final file = File(resolved);
        if (!await file.exists()) {
          errors.add('缺少复习图片：$relative');
          continue;
        }
        reviewAssets++;
        bytes += await file.length();
        final hash = await _sha256(file);
        if (hash != value['sha256']) {
          errors.add('复习图片校验和不匹配：$relative');
        }
        if ((value['size'] as num?)?.toInt() != await file.length()) {
          errors.add('复习图片大小不匹配：$relative');
        }
      }
    }
    return BackupValidation(
      path: displayPath,
      manifest: manifest,
      schemaVersion: schemaVersion,
      documents: documents,
      reviewAssets: reviewAssets,
      bytes: bytes,
      errors: errors,
      warnings: warnings,
    );
  }

  static const List<String> _restoreManagedEntries = [
    'study.sqlite3',
    'study.sqlite3-wal',
    'study.sqlite3-shm',
    'documents',
    'review_assets',
    'cache',
    'imports',
  ];

  /// Validates and copies (or extracts if zip) the package into the app's
  /// restore staging area. Nothing in the live library changes until the next
  /// launch applies it.
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
      if (await File(packagePath).exists()) {
        await _extractZipSafely(packagePath, staging.path);
      } else {
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
          if (relative == null || value['missing'] == true) continue;
          final src = _resolveWithinRoot(packagePath, relative);
          final dst = _resolveWithinRoot(staging.path, relative);
          if (src == null || dst == null) {
            throw LibraryBackupException('备份原件路径非法：$relative');
          }
          await _copyFile(File(src), File(dst));
        }
        final assetsList = validation.manifest!['reviewAssets'];
        if (assetsList is List) {
          for (final value in assetsList) {
            if (value is! Map) continue;
            final relative = value['relativePath'] as String?;
            if (relative == null || value['missing'] == true) continue;
            final src = _resolveWithinRoot(packagePath, relative);
            final dst = _resolveWithinRoot(staging.path, relative);
            if (src == null || dst == null) {
              throw LibraryBackupException('备份复习图片路径非法：$relative');
            }
            await _copyFile(File(src), File(dst));
          }
        }
      }
      final staged = await _validateDirectory(
        staging.path,
        displayPath: staging.path,
      );
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
      for (final name in _restoreManagedEntries) {
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
        final safeSrc = _resolveWithinRoot(validation.path, relative);
        if (safeSrc == null) continue;
        final id = value['id'] as String;
        final extension = p.extension(relative);
        final target = File(
          p.join(documentsDirectory.path, id, 'original$extension'),
        );
        await target.parent.create(recursive: true);
        await _copyFile(File(safeSrc), target);
      }
      final reviewAssetsDirectory = Directory(
        p.join(library.path, reviewAssetsDirName),
      );
      final assetsList = validation.manifest!['reviewAssets'];
      if (assetsList is List && assetsList.isNotEmpty) {
        await reviewAssetsDirectory.create(recursive: true);
        for (final value in assetsList) {
          if (value is! Map) continue;
          final relative = value['relativePath'] as String?;
          if (relative == null || value['missing'] == true) continue;
          final safeSrc = _resolveWithinRoot(validation.path, relative);
          if (safeSrc == null) continue;
          final fileName = _safeAssetFileName(
            value['fileName'] as String? ?? p.basename(relative),
            fallbackId: value['itemId'] as String?,
          );
          final target = File(p.join(reviewAssetsDirectory.path, fileName));
          await target.parent.create(recursive: true);
          await _copyFile(File(safeSrc), target);
        }
      }
      _rebaseReviewAssetPaths(
        p.join(library.path, 'study.sqlite3'),
        reviewAssetsDirectory.path,
      );
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
        for (final name in _restoreManagedEntries) {
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
      for (final name in _restoreManagedEntries) {
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

  /// Resolves [relative] strictly under [root], rejecting drive-letter paths,
  /// leading slashes, empty/dotdot segments, and path traversal.
  static String? _resolveWithinRoot(String root, String relative) {
    final normalizedRaw = relative.replaceAll('\\', '/').trim();
    if (normalizedRaw.isEmpty ||
        normalizedRaw.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(normalizedRaw)) {
      return null;
    }
    final segments = normalizedRaw.split('/');
    for (final segment in segments) {
      if (segment.isEmpty || segment == '.' || segment == '..') {
        return null;
      }
    }
    final rootNormalized = p.normalize(p.absolute(root));
    final candidate = p.normalize(p.joinAll([rootNormalized, ...segments]));
    if (!p.isWithin(rootNormalized, candidate)) {
      return null;
    }
    return candidate;
  }

  /// Extracts a zip archive to [destinationDir] using streaming IO and
  /// zip-slip / symlink / decompression-bomb guards.
  static Future<void> _extractZipSafely(
    String zipPath,
    String destinationDir,
  ) async {
    final dest = Directory(destinationDir);
    await dest.create(recursive: true);
    final input = InputFileStream(zipPath);
    try {
      final archive = ZipDecoder().decodeStream(input, verify: true);
      var entryCount = 0;
      var totalUncompressed = 0;
      for (final entry in archive) {
        entryCount++;
        if (entryCount > _maxZipEntries) {
          throw const LibraryBackupException('备份压缩包条目数量过多，已拒绝解压。');
        }
        if (entry.isSymbolicLink || entry.isHardLink) {
          throw LibraryBackupException('备份压缩包包含不安全的链接条目：${entry.name}');
        }
        final cleanName = entry.name.replaceAll('\\', '/');
        final trimmed = cleanName.endsWith('/')
            ? cleanName.substring(0, cleanName.length - 1)
            : cleanName;
        if (trimmed.isEmpty) continue;
        final targetPath = _resolveWithinRoot(dest.path, trimmed);
        if (targetPath == null) {
          throw LibraryBackupException('备份压缩包包含非法路径：${entry.name}');
        }
        if (entry.isDirectory) {
          await Directory(targetPath).create(recursive: true);
          continue;
        }
        totalUncompressed += entry.size;
        if (totalUncompressed > _maxZipUncompressedBytes) {
          throw const LibraryBackupException('备份压缩包解压体积超过安全上限。');
        }
        final outFile = File(targetPath);
        await outFile.parent.create(recursive: true);
        final output = OutputFileStream(outFile.path);
        try {
          entry.writeContent(output, freeMemory: true);
        } finally {
          await output.close();
        }
        final actualSize = await outFile.length();
        totalUncompressed = totalUncompressed - entry.size + actualSize;
        if (totalUncompressed > _maxZipUncompressedBytes) {
          throw const LibraryBackupException('备份压缩包解压体积超过安全上限。');
        }
      }
    } on ArchiveException catch (error) {
      throw LibraryBackupException('备份压缩包损坏或格式无效：$error');
    } finally {
      await input.close();
    }
  }

  /// Rewrites stored `review_asset_refs.asset_path` and `review_items.data`
  /// `imagePath` references so assets moved across OSes or app containers
  /// resolve to [targetAssetsDir].
  static void _rebaseReviewAssetPaths(
    String databasePath,
    String targetAssetsDir,
  ) {
    final db = sqlite3.open(databasePath);
    try {
      final tables = db
          .select(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('review_asset_refs', 'review_items')",
          )
          .map((row) => row['name'] as String?)
          .whereType<String>()
          .toSet();

      String? resolveRebasedPath(String rawPath, {required String fallbackId}) {
        final parts = rawPath.split(RegExp(r'[/\\]')).where((e) => e.isNotEmpty);
        if (parts.isEmpty) return null;
        final fileName = _safeAssetFileName(parts.last, fallbackId: fallbackId);
        final candidate = File(p.join(targetAssetsDir, fileName));
        return candidate.existsSync() ? candidate.path : null;
      }

      if (tables.contains('review_asset_refs')) {
        final rows = db.select(
          "SELECT id, owner_id, asset_path FROM review_asset_refs WHERE asset_path IS NOT NULL AND TRIM(asset_path) != ''",
        );
        if (rows.isNotEmpty) {
          final update = db.prepare(
            'UPDATE review_asset_refs SET asset_path = ? WHERE id = ?',
          );
          try {
            for (final row in rows) {
              final id = row['id'] as String?;
              final ownerId = row['owner_id'] as String?;
              final rawPath = row['asset_path'] as String?;
              if (id == null || rawPath == null) continue;
              final rebased = resolveRebasedPath(
                rawPath,
                fallbackId: ownerId ?? id,
              );
              if (rebased != null) {
                update.execute([rebased, id]);
              }
            }
          } finally {
            update.close();
          }
        }
      }

      if (tables.contains('review_items')) {
        final rows = db.select(
          "SELECT id, data FROM review_items WHERE data IS NOT NULL AND TRIM(data) != ''",
        );
        if (rows.isNotEmpty) {
          final update = db.prepare(
            'UPDATE review_items SET data = ? WHERE id = ?',
          );
          try {
            for (final row in rows) {
              final id = row['id'] as String?;
              final rawJson = row['data'] as String?;
              if (id == null || rawJson == null) continue;
              final Object? decoded;
              try {
                decoded = jsonDecode(rawJson);
              } catch (_) {
                continue;
              }
              if (decoded is! Map<String, dynamic>) continue;
              final rawImage = decoded['imagePath'];
              if (rawImage is! String || rawImage.trim().isEmpty) continue;
              final rebased = resolveRebasedPath(rawImage, fallbackId: id);
              if (rebased != null && rebased != rawImage) {
                decoded['imagePath'] = rebased;
                update.execute([jsonEncode(decoded), id]);
              }
            }
          } finally {
            update.close();
          }
        }
      }
    } finally {
      db.close();
    }
  }
}


