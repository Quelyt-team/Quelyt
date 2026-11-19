import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../../services/document_service.dart';
import '../../../services/platform_file_access.dart';
import '../../../ui/theme/tokens.dart';
import '../import/import_models.dart';
import '../library_controller.dart';
import 'library_dialogs.dart';
import 'library_style.dart';

const _importUuid = Uuid();

/// Drops can contain files and directories. Empty paths (for example a
/// macOS file promise without a readable copy) are skipped and reported by the
/// caller instead of being imported from an unstable temporary location.
List<String> droppedFilePaths(Iterable<DropItem> items) {
  final paths = <String>[];
  for (final item in items) {
    final path = item.path;
    if (path.isNotEmpty && !paths.contains(path)) paths.add(path);
  }
  return paths;
}

/// One import entry point for every surface (header button, library toolbar
/// and empty states) so file selection, duplicate handling and queue behaviour
/// cannot drift between them.
Future<void> pickAndImportFiles(
  BuildContext context,
  LibraryController library,
) async {
  try {
    final useStreamFallback = PlatformFileAccess.instance.isAndroid;
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: DocumentService.supportedExtensions
          .map((extension) => extension.substring(1)).toList(),
      withData: false,
      withReadStream: useStreamFallback,
      allowMultiple: true,
      dialogTitle: '选择要导入的资料',
    );
    if (result == null) return;
    final paths = <String>[];
    final skipped = <String>[];
    Directory? fallbackDir;
    for (final file in result.files) {
      final directPath = file.path;
      if (directPath != null && directPath.isNotEmpty) {
        paths.add(directPath);
        continue;
      }
      final stream = file.readStream;
      if (stream != null) {
        fallbackDir ??= Directory(
          p.join(
            (await getTemporaryDirectory()).path,
            'picker_inbox',
            _importUuid.v4(),
          ),
        );
        await fallbackDir.create(recursive: true);
        final safeName = _sanitizeFileName(file.name);
        final staged = await _uniqueFile(fallbackDir, safeName);
        final sink = staged.openWrite();
        try {
          await for (final chunk in stream) {
            sink.add(chunk);
          }
          await sink.flush();
          await sink.close();
          if (await staged.length() > 0) {
            paths.add(staged.path);
          } else {
            await staged.delete();
            skipped.add(file.name);
          }
        } catch (_) {
          await sink.close();
          if (await staged.exists()) await staged.delete();
          skipped.add(file.name);
        }
        continue;
      }
      skipped.add(file.name);
    }
    if (skipped.isNotEmpty && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '有 ${skipped.length} 项未能取得可读取内容（可能为远端占位或授权受限）：${skipped.take(3).join('、')}',
          ),
        ),
      );
    }
    if (paths.isEmpty) return;
    await library.importPaths(paths);
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('文件选择失败：$error')));
  }
}

/// Scans a directory first and shows what will be imported, where, and which
/// files are unsupported. Nothing is created until the user confirms.
Future<void> pickAndImportFolder(
  BuildContext context,
  LibraryController library,
) async {
  String? androidStagingDir;
  try {
    String? sourcePath;
    DirectoryScan scan;
    if (PlatformFileAccess.instance.capabilities.safTree) {
      final picked = await PlatformFileAccess.instance.pickDirectoryAndStage();
      if (picked == null || !context.mounted) return;
      androidStagingDir = picked.stagingDirectory;
      sourcePath = picked.stagingDirectory;
      scan = _scanFromPickedTree(picked);
    } else {
      final path = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择要导入的文件夹',
      );
      if (path == null || !context.mounted) return;
      sourcePath = path;
      scan = await library.queue.scanDirectory(path);
    }
    if (!context.mounted) return;
    if (scan.files.isEmpty) {
      if (androidStagingDir != null) {
        await PlatformFileAccess.instance.cleanupStagedDirectory(
          androidStagingDir,
        );
      }
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            scan.unsupported.isEmpty && scan.unreadable.isEmpty
                ? '这个文件夹里没有可导入的文件。'
                : '没有可导入的学习资料'
                      '${scan.unsupported.isNotEmpty ? '（不支持 ${scan.unsupported.length} 个）' : ''}'
                      '${scan.unreadable.isNotEmpty ? '（无法读取 ${scan.unreadable.length} 项）' : ''}。',
          ),
        ),
      );
      return;
    }
    final confirmed = await showLibraryConfirmDialog(
      context,
      title: '导入文件夹？',
      subtitle: scan.rootName,
      message:
          '将 ${scan.files.length} 个文件复制到“${library.importTargetLabel}”下的新文件夹，'
          '保留目录结构；外部原件保持不变。',
      confirmLabel: '开始导入',
      details: [
        _ScanRow(label: '可导入', value: '${scan.files.length} 个'),
        _ScanRow(label: '总大小', value: formatSize(scan.totalBytes)),
        if (scan.unsupported.isNotEmpty)
          _ScanRow(
            label: '不支持（只列清单）',
            value: '${scan.unsupported.length} 个',
          ),
        if (scan.unreadable.isNotEmpty)
          _ScanRow(label: '无法读取', value: '${scan.unreadable.length} 项'),
        if (scan.truncated)
          const _ScanRow(label: '扫描范围', value: '已到数量上限，只导入已发现文件'),
      ],
    );
    if (!confirmed || !context.mounted) {
      if (androidStagingDir != null) {
        await PlatformFileAccess.instance.cleanupStagedDirectory(
          androidStagingDir,
        );
      }
      return;
    }
    await library.queue.enqueueDirectory(
      sourcePath,
      scan: scan,
      targetFolderId: library.importTargetFolderId,
      keepStructure: true,
    );
  } catch (error) {
    if (androidStagingDir != null) {
      await PlatformFileAccess.instance.cleanupStagedDirectory(
        androidStagingDir,
      );
    }
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('文件夹扫描或导入失败：$error')));
  }
}

DirectoryScan _scanFromPickedTree(PlatformPickedTree picked) {
  final files = <ScannedFile>[];
  for (final file in picked.files) {
    final relDir = p.posix.dirname(file.relativePath);
    files.add(
      ScannedFile(
        path: file.path,
        name: file.name,
        extension: p.extension(file.name).toLowerCase(),
        sizeBytes: file.sizeBytes,
        relativeDirectory: relDir == '.' ? '' : relDir,
      ),
    );
  }
  final unsupported = <ScannedFile>[
    for (final rel in picked.unsupported)
      ScannedFile(
        path: rel,
        name: p.posix.basename(rel),
        extension: p.extension(rel).toLowerCase(),
        sizeBytes: 0,
        relativeDirectory: p.posix.dirname(rel) == '.'
            ? ''
            : p.posix.dirname(rel),
      ),
  ];
  return DirectoryScan(
    rootName: picked.rootName,
    files: files,
    unsupported: unsupported,
    unreadable: picked.unreadable,
    truncated: picked.truncated,
  );
}

Future<String?> pickExportDirectory(BuildContext context) async {
  try {
    return await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择导出位置',
    );
  } catch (error) {
    if (!context.mounted) return null;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('选择导出位置失败：$error')));
    return null;
  }
}

String _sanitizeFileName(String raw) {
  final cleaned = raw.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').trim();
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
    return 'imported_${_importUuid.v4().substring(0, 8)}';
  }
  return DocumentService.supportedExtensions.contains(
        p.extension(cleaned).toLowerCase(),
      )
      ? cleaned
      : cleaned;
}

Future<File> _uniqueFile(Directory parent, String name) async {
  var candidate = File(p.join(parent.path, name));
  if (!await candidate.exists()) return candidate;
  final stem = p.basenameWithoutExtension(name);
  final ext = p.extension(name);
  var i = 2;
  while (await candidate.exists()) {
    candidate = File(p.join(parent.path, '${stem}_$i$ext'));
    i++;
  }
  return candidate;
}

class _ScanRow extends StatelessWidget {
  const _ScanRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: colors.surfaceRaised,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: context.texts.bodySmall!.copyWith(fontSize: 12.5),
            ),
          ),
          Text(
            value,
            style: context.texts.bodySmall!.copyWith(
              fontSize: 12.5,
              color: colors.ink,
              fontFeatures: AppNumerals.tabular,
            ),
          ),
        ],
      ),
    );
  }
}
