import 'package:flutter/material.dart';

import '../library_controller.dart';
import '../models/library_models.dart';
import '../../../core/models.dart';
import '../../../ui/theme/tokens.dart';

/// Muted folder palette. Colours decorate the icon, branch line and a small
/// emphasis only; body copy keeps the theme ink so a folder colour never
/// becomes the only signal.
const List<int> folderPalette = <int>[
  0xFF2563EB, // blue
  0xFF0891B2, // cyan
  0xFF0D9488, // teal
  0xFF16A34A, // green
  0xFF65A30D, // lime
  0xFFCA8A04, // amber
  0xFFEA580C, // orange
  0xFFDC2626, // red
  0xFFDB2777, // pink
  0xFF9333EA, // purple
  0xFF6366F1, // indigo
  0xFF57534E, // stone
];

Color? folderColorValue(int? value) =>
    value == null ? null : Color(value);

/// Resolves inherited colour by walking ancestors. The state, not the copied
/// value, decides inheritance, so a later parent change still reaches children
/// that never set their own colour.
int? effectiveFolderColor(LibraryController controller, String? folderId) {
  var current = controller.folderById(folderId);
  final seen = <String>{};
  while (current != null && seen.add(current.id)) {
    if (current.colorMode == FolderColorMode.custom &&
        current.colorValue != null) {
      return current.colorValue;
    }
    current = controller.folderById(current.parentId);
  }
  return null;
}

Color folderInk(BuildContext context, int? value) {
  final colors = context.colors;
  return value == null ? colors.inkMuted : Color(value);
}

QIconData documentIcon(String format) => switch (format.toLowerCase()) {
  'pdf' => QIcons.paper,
  'png' || 'jpg' || 'jpeg' => QIcons.region,
  _ => QIcons.paper,
};

String formatLabel(String format) =>
    format.isEmpty ? '文件' : format.toUpperCase();

String formatSize(int bytes) {
  if (bytes <= 0) return '大小未知';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

String processingLabel(DocumentRecord document, LibraryController controller) {
  switch (document.lifecycle) {
    case DocumentLifecycle.trashed:
      return '在回收站';
    case DocumentLifecycle.purging:
      return '清理中';
    case DocumentLifecycle.active:
      break;
  }
  final progress = controller.progressFor(document.id);
  if (!progress.hasPages) return '待处理';
  if (progress.ready == 0) return '待识别';
  if (!progress.complete) {
    return '识别中 \u00b7 ${progress.ready}/${progress.total}';
  }
  return '可阅读';
}

String openedLabel(DateTime value) {
  final now = DateTime.now();
  final local = value.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final difference = today.difference(day).inDays;
  if (difference == 0) {
    return '今天 ${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
  if (difference == 1) return '昨天';
  if (local.year == now.year) return '${local.month}月${local.day}日';
  return '${local.year}.${local.month}.${local.day}';
}

String dateLabel(DateTime value) {
  final local = value.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')} '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}

/// A drag payload that only identifies stable ids. The drop target re-reads the
/// database before writing, so a stale drag cannot resurrect a deleted item.
@immutable
class LibraryDragPayload {
  const LibraryDragPayload({
    this.folderIds = const {},
    this.entryIds = const {},
    required this.label,
  });

  final Set<String> folderIds;
  final Set<String> entryIds;
  final String label;

  bool get isEmpty => folderIds.isEmpty && entryIds.isEmpty;
  bool get isNotEmpty => !isEmpty;
}

class LibraryDragFeedback extends StatelessWidget {
  const LibraryDragFeedback({super.key, required this.label, required this.icon});

  final String label;
  final QIconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      elevation: 6,
      color: colors.surfaceRaised,
      borderRadius: BorderRadius.circular(Radii.md),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: colors.outlineStrong),
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            QIcon(icon, size: IconSizes.sm, color: colors.inkMuted),
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.texts.bodySmall!.copyWith(
                  fontSize: 12.5,
                  color: colors.ink,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
