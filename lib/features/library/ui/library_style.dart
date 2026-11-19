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

Color? folderColorValue(int? value) => value == null ? null : Color(value);

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

/// Normalizes a format string or falls back to the extension of [originalName]
/// / [filePath] when a legacy record has an empty `format` column.
String resolveFormatExtension(
  String format, {
  String? originalName,
  String? filePath,
}) {
  String clean(String raw) {
    final trimmed = raw.trim().toLowerCase();
    return trimmed.startsWith('.') ? trimmed.substring(1) : trimmed;
  }

  final direct = clean(format);
  if (direct.isNotEmpty) return direct;

  String extFromPath(String? path) {
    if (path == null || path.isEmpty) return '';
    final normalized = path.replaceAll('\\', '/');
    final name = normalized.split('/').last;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    return clean(name.substring(dot + 1));
  }

  final fromOriginal = extFromPath(originalName);
  if (fromOriginal.isNotEmpty) return fromOriginal;
  return extFromPath(filePath);
}

String documentFormat(DocumentRecord document) => resolveFormatExtension(
  document.format,
  originalName: document.originalName,
  filePath: document.filePath,
);

QIconData documentIcon(String format) => switch (resolveFormatExtension(format)) {
  'pdf' => QIcons.filePdf,
  'doc' || 'docx' => QIcons.fileWord,
  'png' || 'jpg' || 'jpeg' => QIcons.fileImage,
  'ppt' || 'pptx' => QIcons.fileSlides,
  'mp4' || 'webm' || 'mkv' => QIcons.fileVideo,
  _ => QIcons.fileGeneric,
};

String formatLabel(String format) {
  final ext = resolveFormatExtension(format);
  if (ext.isEmpty) return '文件';
  if (ext == 'jpeg') return 'JPG';
  return ext.toUpperCase();
}

@immutable
class DocumentFormatVisual {
  const DocumentFormatVisual({
    required this.icon,
    required this.label,
    required this.ink,
    required this.background,
    required this.border,
  });

  final QIconData icon;
  final String label;
  final Color ink;
  final Color background;
  final Color border;
}

DocumentFormatVisual documentFormatVisual(
  BuildContext context,
  String format, {
  String? originalName,
  String? filePath,
}) {
  final colors = context.colors;
  final dark = colors.isDark;
  final ext = resolveFormatExtension(
    format,
    originalName: originalName,
    filePath: filePath,
  );
  final label = formatLabel(ext);
  return switch (ext) {
    'pdf' => DocumentFormatVisual(
      icon: QIcons.filePdf,
      label: label,
      ink: dark ? const Color(0xFFF87171) : const Color(0xFFC81E1E),
      background: dark ? const Color(0xFF2A1515) : const Color(0xFFFEF2F2),
      border: dark ? const Color(0xFF5C2323) : const Color(0xFFFECACA),
    ),
    'doc' || 'docx' => DocumentFormatVisual(
      icon: QIcons.fileWord,
      label: label,
      ink: dark ? const Color(0xFF60A5FA) : const Color(0xFF1D4ED8),
      background: dark ? const Color(0xFF142038) : const Color(0xFFEFF6FF),
      border: dark ? const Color(0xFF274170) : const Color(0xFFBFDBFE),
    ),
    'ppt' || 'pptx' => DocumentFormatVisual(
      icon: QIcons.fileSlides,
      label: label,
      ink: dark ? const Color(0xFFFB923C) : const Color(0xFFC2410C),
      background: dark ? const Color(0xFF2B1B10) : const Color(0xFFFFF7ED),
      border: dark ? const Color(0xFF5C3419) : const Color(0xFFFED7AA),
    ),
    'png' => DocumentFormatVisual(
      icon: QIcons.fileImage,
      label: label,
      ink: dark ? const Color(0xFF2DD4BF) : const Color(0xFF0F766E),
      background: dark ? const Color(0xFF0F2624) : const Color(0xFFF0FDFA),
      border: dark ? const Color(0xFF1E4D47) : const Color(0xFF99F6E4),
    ),
    'jpg' || 'jpeg' => DocumentFormatVisual(
      icon: QIcons.fileImage,
      label: label,
      ink: dark ? const Color(0xFF4ADE80) : const Color(0xFF15803D),
      background: dark ? const Color(0xFF102618) : const Color(0xFFF0FDF4),
      border: dark ? const Color(0xFF1E4D2B) : const Color(0xFFBBF7D0),
    ),
    'mp4' => DocumentFormatVisual(
      icon: QIcons.fileVideo,
      label: label,
      ink: dark ? const Color(0xFFA78BFA) : const Color(0xFF6D28D9),
      background: dark ? const Color(0xFF201833) : const Color(0xFFF5F3FF),
      border: dark ? const Color(0xFF413066) : const Color(0xFFDDD6FE),
    ),
    'webm' => DocumentFormatVisual(
      icon: QIcons.fileVideo,
      label: label,
      ink: dark ? const Color(0xFF38BDF8) : const Color(0xFF0369A1),
      background: dark ? const Color(0xFF102330) : const Color(0xFFF0F9FF),
      border: dark ? const Color(0xFF1D4660) : const Color(0xFFBAE6FD),
    ),
    'mkv' => DocumentFormatVisual(
      icon: QIcons.fileVideo,
      label: label,
      ink: dark ? const Color(0xFFE879F9) : const Color(0xFFA21CAF),
      background: dark ? const Color(0xFF2B1530) : const Color(0xFFFDF4FF),
      border: dark ? const Color(0xFF572461) : const Color(0xFFF5D0FE),
    ),
    _ => DocumentFormatVisual(
      icon: QIcons.fileGeneric,
      label: label,
      ink: colors.inkMuted,
      background: colors.surfaceRaised,
      border: colors.outline,
    ),
  };
}

/// Square tinted file-format tile used in library rows, trash, and import queue.
class DocumentFormatIcon extends StatelessWidget {
  const DocumentFormatIcon({
    super.key,
    required this.format,
    this.originalName,
    this.filePath,
    this.size = 30,
    this.iconSize = 16,
    this.isShortcut = false,
  });

  factory DocumentFormatIcon.forDocument(
    DocumentRecord document, {
    Key? key,
    double size = 30,
    double iconSize = 16,
    bool isShortcut = false,
  }) => DocumentFormatIcon(
    key: key,
    format: document.format,
    originalName: document.originalName,
    filePath: document.filePath,
    size: size,
    iconSize: iconSize,
    isShortcut: isShortcut,
  );

  final String format;
  final String? originalName;
  final String? filePath;
  final double size;
  final double iconSize;
  final bool isShortcut;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final visual = documentFormatVisual(
      context,
      format,
      originalName: originalName,
      filePath: filePath,
    );
    final radius = (size * .24).clamp(5.0, 10.0).toDouble();
    final tile = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: visual.background,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: visual.border),
      ),
      child: Center(
        child: QIcon(
          visual.icon,
          size: iconSize,
          color: visual.ink,
          active: visual.icon == QIcons.fileVideo,
        ),
      ),
    );
    if (!isShortcut) return tile;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          tile,
          Positioned(
            right: -2,
            bottom: -2,
            child: Tooltip(
              message: '快捷方式：共享原资料',
              child: Container(
                width: 13,
                height: 13,
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: colors.outline),
                ),
                child: Center(
                  child: QIcon(
                    QIcons.shortcut,
                    size: 9,
                    color: colors.inkMuted,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact format pill (e.g. PDF / PPTX / PNG / MP4) with matching format tint.
class DocumentFormatTag extends StatelessWidget {
  const DocumentFormatTag({
    super.key,
    required this.format,
    this.originalName,
    this.filePath,
    this.compact = false,
  });

  factory DocumentFormatTag.forDocument(
    DocumentRecord document, {
    Key? key,
    bool compact = false,
  }) => DocumentFormatTag(
    key: key,
    format: document.format,
    originalName: document.originalName,
    filePath: document.filePath,
    compact: compact,
  );

  final String format;
  final String? originalName;
  final String? filePath;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final visual = documentFormatVisual(
      context,
      format,
      originalName: originalName,
      filePath: filePath,
    );
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 5.5 : 7,
        vertical: compact ? 1.5 : 2,
      ),
      decoration: BoxDecoration(
        color: visual.background,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: visual.border),
      ),
      child: Text(
        visual.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: context.texts.labelSmall!.copyWith(
          fontSize: compact ? 10 : 11,
          height: 1.2,
          letterSpacing: 0.2,
          color: visual.ink,
          fontWeight: FontWeight.w600,
          fontFeatures: AppNumerals.tabular,
        ),
      ),
    );
  }
}

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
  if (document.isVideo) return '视频';
  if (document.conversionIssue != null) return '待转换';
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
  const LibraryDragFeedback({
    super.key,
    required this.label,
    required this.icon,
  });

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
