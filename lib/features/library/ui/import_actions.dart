import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../ui/theme/tokens.dart';
import '../library_controller.dart';
import 'library_dialogs.dart';
import 'library_style.dart';

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
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf', 'png', 'jpg', 'jpeg'],
      withData: false,
      allowMultiple: true,
      dialogTitle: '选择要导入的资料',
    );
    if (result == null) return;
    final paths = [for (final file in result.files) ?file.path];
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
  try {
    final path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择要导入的文件夹',
    );
    if (path == null || !context.mounted) return;
    final scan = await library.queue.scanDirectory(path);
    if (!context.mounted) return;
    if (scan.files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            scan.unsupported.isEmpty
                ? '这个文件夹里没有可导入的文件。'
                : '这个文件夹里没有支持的格式；发现 ${scan.unsupported.length} 个不支持的文件。',
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
    if (!confirmed || !context.mounted) return;
    await library.queue.enqueueDirectory(
      path,
      scan: scan,
      targetFolderId: library.importTargetFolderId,
      keepStructure: true,
    );
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('文件夹扫描或导入失败：$error')));
  }
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
