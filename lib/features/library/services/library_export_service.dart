import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/models.dart';
import '../models/library_models.dart';

class LibraryExportReport {
  const LibraryExportReport({
    this.exported = 0,
    this.bytes = 0,
    this.skippedShortcuts = 0,
    this.failures = const [],
    this.renamed = const [],
    this.createdFolders = 0,
    this.destination,
  });

  final int exported;
  final int bytes;
  final int skippedShortcuts;
  final List<String> failures;
  final List<String> renamed;
  final int createdFolders;
  final String? destination;

  bool get ok => failures.isEmpty;

  String get summary {
    final parts = <String>[
      '导出 $exported 份原件',
      if (bytes > 0) _size(bytes),
      if (createdFolders > 0) '$createdFolders 个文件夹',
    ];
    if (renamed.isNotEmpty) parts.add('${renamed.length} 个名称已调整');
    if (skippedShortcuts > 0) parts.add('$skippedShortcuts 个快捷方式未复制');
    if (failures.isNotEmpty) parts.add('${failures.length} 项失败');
    return parts.join(' · ');
  }

  static String _size(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(0)} KB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Exports managed originals to a user-chosen directory.
///
/// Export is one-way for this version: it copies bytes and creates folders, but
/// never writes into the app's managed directory and never deletes a source.
/// Whole-library backup and restore are separate operations.
class LibraryExportService {
  const LibraryExportService();

  static const _reservedWindowsNames = {
    'CON',
    'PRN',
    'AUX',
    'NUL',
    'COM1',
    'COM2',
    'COM3',
    'COM4',
    'COM5',
    'COM6',
    'COM7',
    'COM8',
    'COM9',
    'LPT1',
    'LPT2',
    'LPT3',
    'LPT4',
    'LPT5',
    'LPT6',
    'LPT7',
    'LPT8',
    'LPT9',
  };

  /// Copies each unique document once into [destination]. Entries marked as
  /// shortcuts are not copied a second time; the report says how many were
  /// skipped so the user is never led to believe several folders were written.
  Future<LibraryExportReport> exportDocuments(
    List<LibraryItem> items,
    String destination,
  ) => _export(items, destination, folderDirectories: const {});

  /// Mirrors a folder subtree. [folders] are the folders to create (the root and
  /// its descendants); items place their displayed name inside their entry
  /// folder. Shortcut entries remain references and are reported, not copied
  /// twice.
  Future<LibraryExportReport> exportFolderTree({
    required LibraryFolder root,
    required List<LibraryFolder> folders,
    required List<LibraryItem> items,
    required String destination,
  }) async {
    final rootDirectory = Directory(p.join(destination, _safeName(root.name)));
    if (!await rootDirectory.exists()) {
      await rootDirectory.create(recursive: true);
    }
    final directories = <String, Directory>{root.id: rootDirectory};
    final created = <String>{root.id};
    var count = 0;
    // Parent ids sort before children in the controller's list; a stable loop
    // creates each directory once even for deep trees.
    for (final folder in folders) {
      if (folder.id == root.id) continue;
      final parent = directories[folder.parentId];
      if (parent == null) continue;
      final directory = Directory(p.join(parent.path, _safeName(folder.name)));
      if (!await directory.exists()) {
        await directory.create(recursive: true);
        created.add(folder.id);
        count++;
      }
      directories[folder.id] = directory;
    }
    final report = await _export(
      items,
      destination,
      folderDirectories: directories,
      rootFolderId: root.id,
      extraCreatedFolders: count,
    );
    return report;
  }

  Future<LibraryExportReport> _export(
    List<LibraryItem> items,
    String destination, {
    required Map<String, Directory> folderDirectories,
    String? rootFolderId,
    int extraCreatedFolders = 0,
  }) async {
    final destinationDirectory = Directory(destination);
    if (!await destinationDirectory.exists()) {
      throw FileSystemException('导出位置不存在', destination);
    }
    final usedNames = <String, Set<String>>{};
    final exportedIds = <String>{};
    final failures = <String>[];
    final renamed = <String>[];
    var exported = 0;
    var bytes = 0;
    var skippedShortcuts = 0;

    for (final item in items) {
      if (item.isShortcut) {
        skippedShortcuts++;
        continue;
      }
      if (!exportedIds.add(item.document.id)) continue;
      final source = File(item.document.filePath);
      if (!await source.exists()) {
        failures.add('${item.displayName}：托管原件缺失');
        continue;
      }
      Directory targetDirectory;
      if (folderDirectories.isNotEmpty) {
        targetDirectory =
            folderDirectories[item.entry.folderId] ??
            (rootFolderId == null
                ? destinationDirectory
                : folderDirectories[rootFolderId] ?? destinationDirectory);
      } else {
        targetDirectory = destinationDirectory;
      }
      final extension = _extensionOf(item.document);
      final base = _safeName(item.displayName);
      final key = targetDirectory.path.toLowerCase();
      final names = usedNames.putIfAbsent(key, () => <String>{});
      var candidate = base;
      var counter = 2;
      while (true) {
        final taken = names.contains(candidate.toLowerCase()) ||
            await File(
              p.join(targetDirectory.path, '$candidate$extension'),
            ).exists();
        if (!taken) break;
        candidate = '$base ($counter)';
        counter++;
        if (counter > 9999) {
          failures.add('${item.displayName}：无法生成不冲突的文件名');
          candidate = '';
          break;
        }
      }
      if (candidate.isEmpty) continue;
      if (candidate != base) {
        renamed.add('$base$extension → $candidate$extension');
      }
      names.add(candidate.toLowerCase());
      final target = File(p.join(targetDirectory.path, '$candidate$extension'));
      try {
        await _copyStreaming(source, target);
        exported++;
        bytes += await target.length();
      } catch (error) {
        failures.add('${item.displayName}：$error');
        if (await target.exists()) {
          try {
            await target.delete();
          } catch (_) {
            /* Leave a partial file visible rather than hiding the failure. */
          }
        }
      }
    }
    return LibraryExportReport(
      exported: exported,
      bytes: bytes,
      skippedShortcuts: skippedShortcuts,
      failures: failures,
      renamed: renamed,
      createdFolders: extraCreatedFolders,
      destination: destination,
    );
  }

  Future<void> _copyStreaming(File source, File target) async {
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

  String _extensionOf(DocumentRecord document) {
    var extension = p.extension(document.filePath).toLowerCase();
    if (extension.isEmpty && document.format.isNotEmpty) {
      extension = '.${document.format.toLowerCase()}';
    }
    return extension;
  }

  static String _safeName(String value) {
    var name = value
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    name = name.replaceAll(RegExp(r'[. ]+$'), '');
    if (name.isEmpty) name = '资料';
    final stem = name.split('.').first.toUpperCase();
    if (_reservedWindowsNames.contains(stem)) name = '${name}_';
    if (name.length > 120) name = name.substring(0, 120);
    return name;
  }
}
