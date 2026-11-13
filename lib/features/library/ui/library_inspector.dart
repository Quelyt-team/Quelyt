import 'package:flutter/material.dart';

import '../../../core/models.dart';
import '../../../ui/theme/tokens.dart';
import '../../../ui/widgets/app_surfaces.dart';
import '../../notes/data/notes_repository.dart';
import '../library_controller.dart';
import '../models/library_models.dart';
import '../services/library_thumbnail_service.dart';
import 'library_style.dart';
import 'library_thumbnail.dart';

/// Right-hand supporting pane in the Library workspace when no specific
/// document is selected. Instead of an empty placeholder, it presents the
/// current folder/scope overview, statistics, tag filters, and quick actions.
class LibraryOverviewInspector extends StatelessWidget {
  const LibraryOverviewInspector({
    super.key,
    required this.controller,
    required this.onNewFolder,
    required this.onImportFiles,
    this.onEditFolderNote,
  });

  final LibraryController controller;
  final VoidCallback onNewFolder;
  final VoidCallback onImportFiles;
  final VoidCallback? onEditFolderNote;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final folder = controller.currentFolder;
    final scope = controller.view.scope;
    final scopeLabel = switch (scope) {
      LibraryScope.recent => '最近打开',
      LibraryScope.unfiled => '未归档',
      LibraryScope.starred => '星标',
      LibraryScope.trash => '回收站',
      LibraryScope.smart => controller.activeSmartFolder?.name ?? '智能文件夹',
      _ => '全部资料',
    };
    final title = folder != null ? folder.name : scopeLabel;
    final folderColor = folder == null
        ? colors.primary
        : folderInk(context, effectiveFolderColor(controller, folder.id));
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
      children: [
        Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: colors.surfaceRaised,
                borderRadius: BorderRadius.circular(Radii.md),
                border: Border.all(color: colors.outline),
              ),
              child: Center(
                child: QIcon(
                  folder != null ? QIcons.folderOpen : QIcons.library,
                  size: IconSizes.md,
                  color: folderColor,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.titleSmall!.copyWith(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    folder != null
                        ? (controller.folderPathName(folder.id))
                        : '书库视图概览',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.bodySmall!.copyWith(
                      fontSize: 12,
                      color: colors.inkMuted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (folder != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colors.surfaceRaised,
              borderRadius: BorderRadius.circular(Radii.md),
              border: Border.all(color: colors.outline),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    folder.description.trim().isEmpty
                        ? '添加文件夹备注，记录本学科或专题的学习重点。'
                        : folder.description,
                    style: context.texts.bodySmall!.copyWith(
                      fontSize: 12,
                      height: 1.45,
                      color: folder.description.trim().isEmpty
                          ? colors.inkMuted
                          : colors.ink,
                    ),
                  ),
                ),
                if (onEditFolderNote != null)
                  IconButton(
                    tooltip: '编辑文件夹备注',
                    onPressed: onEditFolderNote,
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 26,
                      minHeight: 26,
                    ),
                    padding: EdgeInsets.zero,
                    icon: QIcon(QIcons.edit, size: 13, color: colors.inkMuted),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 16),
        Text(
          '统计概览',
          style: context.texts.bodySmall!.copyWith(
            fontSize: 12,
            color: colors.inkMuted,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _statTile(
                context,
                label: '当前列表',
                value: '${controller.items.length}',
                unit: '份资料',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _statTile(
                context,
                label: '子文件夹',
                value: '${controller.childFolders.length}',
                unit: '个目录',
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _statTile(
                context,
                label: '星标收藏',
                value: '${controller.counts.starred}',
                unit: '份星标',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _statTile(
                context,
                label: '整库资料',
                value: '${controller.counts.all}',
                unit: '份原件',
              ),
            ),
          ],
        ),
        if (controller.tags.isNotEmpty) ...[
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: Text(
                  '按标签筛选',
                  style: context.texts.bodySmall!.copyWith(
                    fontSize: 12,
                    color: colors.inkMuted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (controller.filter.tagIds.isNotEmpty)
                InkWell(
                  onTap: () => controller.setFilter(
                    controller.filter.copyWith(tagIds: const {}),
                  ),
                  child: Text(
                    '清除',
                    style: context.texts.bodySmall!.copyWith(
                      fontSize: 12,
                      color: colors.primary,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final tag in controller.tags)
                FilterChip(
                  visualDensity: VisualDensity.compact,
                  label: Text(
                    tag.name,
                    style: const TextStyle(fontSize: 12),
                  ),
                  selected: controller.filter.tagIds.contains(tag.id),
                  onSelected: (selected) {
                    final next = {...controller.filter.tagIds};
                    if (selected) {
                      next.add(tag.id);
                    } else {
                      next.remove(tag.id);
                    }
                    controller.setFilter(
                      controller.filter.copyWith(tagIds: next),
                    );
                  },
                ),
            ],
          ),
        ],
        const SizedBox(height: 18),
        Text(
          '快捷操作',
          style: context.texts.bodySmall!.copyWith(
            fontSize: 12,
            color: colors.inkMuted,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: onImportFiles,
          icon: const QIcon(QIcons.add, size: IconSizes.sm),
          label: const Text('导入资料到此视图'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: onNewFolder,
          icon: const QIcon(QIcons.folder, size: IconSizes.sm),
          label: Text(folder == null ? '新建文件夹' : '新建子文件夹'),
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colors.surfaceRaised,
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              QIcon(QIcons.info, size: IconSizes.sm, color: colors.inkMuted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '点击列表中的任意资料，查看进度、标签、学习方式与关联笔记。',
                  style: context.texts.bodySmall!.copyWith(
                    fontSize: 12,
                    height: 1.45,
                    color: colors.inkMuted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _statTile(
    BuildContext context, {
    required String label,
    required String value,
    required String unit,
  }) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: colors.surfaceRaised,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: colors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: context.texts.bodySmall!.copyWith(
              fontSize: 12,
              color: colors.inkMuted,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: context.texts.titleSmall!.copyWith(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  fontFeatures: AppNumerals.tabular,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                unit,
                style: context.texts.bodySmall!.copyWith(
                  fontSize: 12,
                  color: colors.inkMuted,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Zotero 7-style collapsible Inspector for a selected [LibraryItem].
class LibraryItemInspector extends StatefulWidget {
  const LibraryItemInspector({
    super.key,
    required this.item,
    required this.controller,
    required this.thumbnails,
    required this.onOpen,
    required this.onRename,
    required this.onTags,
    required this.onStar,
    required this.onDelete,
    required this.onMove,
    required this.onLocate,
    required this.onShortcut,
    required this.onExport,
    required this.onLearningMode,
    this.onOpenNote,
    this.onCreateNote,
  });

  final LibraryItem item;
  final LibraryController controller;
  final LibraryThumbnailService thumbnails;
  final VoidCallback onOpen;
  final VoidCallback onRename;
  final VoidCallback onTags;
  final VoidCallback onStar;
  final VoidCallback onDelete;
  final VoidCallback onMove;
  final VoidCallback onLocate;
  final VoidCallback onShortcut;
  final VoidCallback onExport;
  final ValueChanged<DocumentKind> onLearningMode;
  final ValueChanged<String>? onOpenNote;
  final ValueChanged<DocumentRecord>? onCreateNote;

  @override
  State<LibraryItemInspector> createState() => _LibraryItemInspectorState();
}

class _LibraryItemInspectorState extends State<LibraryItemInspector> {
  bool _metaExpanded = true;
  bool _tagsExpanded = true;
  bool _notesExpanded = true;
  bool _actionsExpanded = true;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final item = widget.item;
    final controller = widget.controller;
    final document = item.document;
    final tags = [
      for (final tag in controller.tags)
        if ((controller.tagIdsByDocument[document.id] ?? const {}).contains(
          tag.id,
        ))
          tag,
    ];
    final progress = controller.progressFor(document.id);
    final notesRepo = NotesRepository(controller.store);
    final linkedNotes = notesRepo.notesReferencing(document.id, limit: 8);
    final questionCounts = notesRepo.openQuestionCounts(
      linkedNotes.map((n) => n.id),
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
      children: [
        Center(
          child: SizedBox(
            width: 88,
            height: 112,
            child: DocumentCoverImage(
              document: document,
              thumbnails: widget.thumbnails,
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(
          item.displayName,
          style: context.texts.titleSmall!.copyWith(
            fontSize: 15,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${formatLabel(document.format)} · ${formatSize(document.sizeBytes)}'
          ' · ${document.pageCount} 页',
          style: context.texts.bodySmall!.copyWith(
            fontSize: 12,
            color: colors.inkMuted,
          ),
        ),
        if (!item.available) ...[
          const SizedBox(height: 10),
          const AppCallout(
            tone: CalloutTone.warning,
            message: '此资料在回收站中，恢复后可继续阅读。',
          ),
        ],
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: widget.onOpen,
                icon: const QIcon(QIcons.play, size: IconSizes.sm),
                label: const Text('阅读'),
              ),
            ),
            const SizedBox(width: 6),
            if (widget.onCreateNote != null)
              IconButton(
                tooltip: '新建关联笔记',
                onPressed: () => widget.onCreateNote!(document),
                icon: QIcon(
                  QIcons.notes,
                  size: IconSizes.md,
                  color: colors.inkMuted,
                ),
              ),
            IconButton(
              tooltip: document.starred ? '取消星标' : '加星标',
              onPressed: widget.onStar,
              icon: QIcon(
                QIcons.star,
                size: IconSizes.md,
                color: document.starred ? colors.primary : colors.inkMuted,
                active: document.starred,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _sectionHeader(
          context,
          title: '基本信息与位置',
          expanded: _metaExpanded,
          onToggle: () => setState(() => _metaExpanded = !_metaExpanded),
        ),
        if (_metaExpanded) ...[
          const SizedBox(height: 4),
          _DetailRow(
            label: '文件夹位置',
            value: controller.folderPathName(item.entry.folderId).isEmpty
                ? '未归档'
                : controller.folderPathName(item.entry.folderId),
            action: item.isShortcut
                ? TextButton(
                    onPressed: widget.onLocate,
                    child: const Text('定位原资料'),
                  )
                : null,
          ),
          _DetailRow(
            label: '阅读进度',
            value: progress.hasPages
                ? '第 ${document.currentPage} / ${document.pageCount} 页'
                : '第 ${document.currentPage} / ${document.pageCount} 页 · 待处理',
          ),
          _DetailRow(label: '导入日期', value: dateLabel(document.addedAt)),
          _DetailRow(label: '最近打开', value: openedLabel(document.lastOpenedAt)),
          _DetailRow(
            label: '原始文件名',
            value: document.originalName.isEmpty ? '—' : document.originalName,
          ),
        ],
        const SizedBox(height: 10),
        _sectionHeader(
          context,
          title: '标签与学习方式',
          expanded: _tagsExpanded,
          onToggle: () => setState(() => _tagsExpanded = !_tagsExpanded),
        ),
        if (_tagsExpanded) ...[
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final tag in tags) AppBadge(label: tag.name, dense: true),
              ActionChip(
                avatar: QIcon(QIcons.add, size: 12, color: colors.inkMuted),
                label: Text(
                  tags.isEmpty ? '加标签' : '编辑',
                  style: const TextStyle(fontSize: 12),
                ),
                onPressed: widget.onTags,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '学习方式',
            style: context.texts.bodySmall!.copyWith(
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final mode in DocumentKind.values)
                ChoiceChip(
                  label: Text(
                    mode.label,
                    style: const TextStyle(fontSize: 12),
                  ),
                  selected: document.kind == mode,
                  onSelected: (_) => widget.onLearningMode(mode),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '切换学习方式不清空笔记与问答记录。',
            style: context.texts.bodySmall!.copyWith(
              fontSize: 12,
              color: colors.inkMuted,
            ),
          ),
        ],
        const SizedBox(height: 10),
        _sectionHeader(
          context,
          title: '关联笔记 (${linkedNotes.length})',
          expanded: _notesExpanded,
          onToggle: () => setState(() => _notesExpanded = !_notesExpanded),
        ),
        if (_notesExpanded) ...[
          const SizedBox(height: 6),
          if (linkedNotes.isEmpty)
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: colors.surfaceRaised,
                borderRadius: BorderRadius.circular(Radii.md),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '暂无关联笔记，可在阅读时摘录或新建。',
                      style: context.texts.bodySmall!.copyWith(
                        fontSize: 12,
                        color: colors.inkMuted,
                      ),
                    ),
                  ),
                  if (widget.onCreateNote != null)
                    TextButton(
                      onPressed: () => widget.onCreateNote!(document),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 26),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        visualDensity: VisualDensity.compact,
                      ),
                      child: const Text('新建', style: TextStyle(fontSize: 12)),
                    ),
                ],
              ),
            )
          else
            for (final note in linkedNotes)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: InkWell(
                  onTap: widget.onOpenNote == null
                      ? null
                      : () => widget.onOpenNote!(note.id),
                  borderRadius: BorderRadius.circular(Radii.md),
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: colors.surfaceRaised,
                      borderRadius: BorderRadius.circular(Radii.md),
                      border: Border.all(color: colors.outline),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const QIcon(QIcons.notes, size: 13),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                note.displayTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: context.texts.bodySmall!.copyWith(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: colors.ink,
                                ),
                              ),
                            ),
                            if ((questionCounts[note.id] ?? 0) > 0)
                              AppBadge(
                                label: '${questionCounts[note.id]} 待解决',
                                dense: true,
                              ),
                          ],
                        ),
                        if (note.plainText.isNotEmpty) ...[
                          const SizedBox(height: 3),
                          Text(
                            note.plainText,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: context.texts.bodySmall!.copyWith(
                              fontSize: 12,
                              color: colors.inkMuted,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
        ],
        const SizedBox(height: 10),
        _sectionHeader(
          context,
          title: '资料操作',
          expanded: _actionsExpanded,
          onToggle: () => setState(() => _actionsExpanded = !_actionsExpanded),
        ),
        if (_actionsExpanded) ...[
          const SizedBox(height: 4),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: QIcon(
              QIcons.edit,
              size: IconSizes.sm,
              color: colors.inkMuted,
            ),
            title: const Text('重命名', style: TextStyle(fontSize: 13)),
            onTap: widget.onRename,
          ),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: QIcon(
              QIcons.move,
              size: IconSizes.sm,
              color: colors.inkMuted,
            ),
            title: const Text('移动到…', style: TextStyle(fontSize: 13)),
            onTap: widget.onMove,
          ),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: QIcon(
              QIcons.shortcut,
              size: IconSizes.sm,
              color: colors.inkMuted,
            ),
            title: const Text('创建快捷方式到…', style: TextStyle(fontSize: 13)),
            onTap: widget.onShortcut,
          ),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: QIcon(
              QIcons.download,
              size: IconSizes.sm,
              color: colors.inkMuted,
            ),
            title: const Text('导出原件…', style: TextStyle(fontSize: 13)),
            onTap: widget.onExport,
          ),
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: QIcon(
              QIcons.trash,
              size: IconSizes.sm,
              color: colors.danger,
            ),
            title: Text(
              item.isShortcut ? '删除此快捷方式' : '移入回收站',
              style: TextStyle(fontSize: 13, color: colors.danger),
            ),
            onTap: widget.onDelete,
          ),
        ],
      ],
    );
  }

  Widget _sectionHeader(
    BuildContext context, {
    required String title,
    required bool expanded,
    required VoidCallback onToggle,
  }) {
    final colors = context.colors;
    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(Radii.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            QIcon(
              expanded ? QIcons.chevronDown : QIcons.chevronRight,
              size: 13,
              color: colors.inkMuted,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                title,
                style: context.texts.bodySmall!.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
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

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value, this.action});

  final String label;
  final String value;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: context.texts.bodySmall!.copyWith(
                fontSize: 12,
                color: colors.inkMuted,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: context.texts.bodySmall!.copyWith(fontSize: 12),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}
