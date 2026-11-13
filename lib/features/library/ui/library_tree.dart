import 'dart:async';

import 'package:flutter/material.dart';

import '../../../ui/theme/tokens.dart';
import '../library_controller.dart';
import '../models/library_models.dart';
import 'import_actions.dart';
import 'library_dialogs.dart';
import 'library_style.dart';

/// Library navigation and the folder branch tree. The widget is shown inside
/// the global sidebar on desktop and inside a drawer on phones; the same tree,
/// dialogs and drag rules are used in both places.
class LibraryTree extends StatefulWidget {
  const LibraryTree({super.key, required this.controller, this.drawer = false});

  final LibraryController controller;
  final bool drawer;

  @override
  State<LibraryTree> createState() => _LibraryTreeState();
}

class _LibraryTreeState extends State<LibraryTree> {
  final Set<String> _hovered = {};

  LibraryController get c => widget.controller;

  Future<void> _newFolder({String? parentId}) async {
    final name = await showLibraryTextDialog(
      context,
      title: parentId == null ? '新建文件夹' : '新建子文件夹',
      subtitle: parentId == null ? '放在“全部资料”的根目录。' : c.folderPathName(parentId),
      label: '文件夹名称',
      hint: '例如：大三上、期末备考、教材',
      confirmLabel: '新建',
      maxLength: 80,
      validate: (value) {
        if (value.isEmpty) return '文件夹名称不能为空。';
        if (c.repository.folderNameExists(parentId, value)) {
          return '同一位置已经有名为「$value」的文件夹。';
        }
        return null;
      },
    );
    if (name == null) return;
    await c.createFolder(name: name, parentId: parentId);
  }

  Future<void> _rename(LibraryFolder folder) async {
    final name = await showLibraryTextDialog(
      context,
      title: '重命名文件夹',
      subtitle: c.folderPathName(folder.parentId, separator: ' / '),
      label: '文件夹名称',
      initial: folder.name,
      confirmLabel: '重命名',
      maxLength: 80,
      validate: (value) {
        if (value.isEmpty) return '文件夹名称不能为空。';
        if (value == folder.name) return '名称没有变化。';
        if (c.repository.folderNameExists(
          folder.parentId,
          value,
          exceptId: folder.id,
        )) {
          return '同一位置已经有名为「$value」的文件夹。';
        }
        return null;
      },
    );
    if (name != null) await c.renameFolder(folder.id, name);
  }

  Future<void> _move(LibraryFolder folder) async {
    final choice = await showFolderPickerDialog(
      context,
      controller: c,
      title: '移动文件夹',
      subtitle: folder.name,
      excludeFolderIds: c.descendantFolderIds(folder.id, includeSelf: true),
      confirmLabel: '移动',
    );
    if (choice == null || choice.cancelled) return;
    if (choice.folderId == folder.parentId) return;
    await c.moveNodes(folderIds: {folder.id}, targetFolderId: choice.folderId);
  }

  Future<void> _style(LibraryFolder folder) async {
    final draft = await showFolderStyleDialog(
      context,
      controller: c,
      folder: folder,
    );
    if (draft == null) return;
    await c.setFolderAppearance(
      folder.id,
      colorMode: draft.colorMode,
      colorValue: draft.colorValue,
      clearColor: draft.colorMode == FolderColorMode.inherit,
      icon: draft.icon,
      clearIcon: draft.icon == null,
      description: draft.description,
    );
  }

  Future<void> _export(LibraryFolder folder) async {
    final destination = await pickExportDirectory(context);
    if (destination == null) return;
    final report = await c.exportFolderTo(folder.id, destination);
    if (!mounted || report == null) return;
    await showExportReportDialog(context, report);
  }

  Future<void> _saveSmartFolder() async {
    final suggested = c.query.trim().isNotEmpty ? c.query.trim() : '筛选资料';
    final name = await showLibraryTextDialog(
      context,
      title: '保存为智能文件夹',
      subtitle: '保存当前搜索与筛选，结果随资料自动更新。',
      label: '名称',
      initial: suggested,
      hint: '例如：未读且考试重点',
      confirmLabel: '保存',
      maxLength: 60,
    );
    if (name != null) await c.saveCurrentAsSmartFolder(name);
  }

  Future<void> _renameSmartFolder(SmartFolder folder) async {
    final name = await showLibraryTextDialog(
      context,
      title: '重命名智能文件夹',
      label: '名称',
      initial: folder.name,
      confirmLabel: '重命名',
      maxLength: 60,
    );
    if (name != null) await c.renameSmartFolder(folder.id, name);
  }

  Future<void> _deleteSmartFolder(SmartFolder folder) async {
    final confirmed = await showLibraryConfirmDialog(
      context,
      title: '删除智能文件夹？',
      subtitle: folder.name,
      message: '仅删除检索条件，不删除任何资料。',
      confirmLabel: '删除',
      danger: true,
    );
    if (confirmed) await c.deleteSmartFolder(folder.id);
  }

  Future<void> _trash(LibraryFolder folder) async {
    final ids = c.descendantFolderIds(folder.id, includeSelf: true);
    final entries = c.repository.activeEntriesInFolders(ids);
    final documents = entries
        .where((entry) => !entry.isShortcut)
        .map((entry) => entry.documentId)
        .toSet();
    final shortcuts = entries.where((entry) => entry.isShortcut).length;
    final confirmed = await showTrashImpactDialog(
      context,
      title: '移入回收站？',
      targetLabel: folder.name,
      entries: entries.length,
      folders: ids.length,
      documents: documents.length,
      shortcuts: shortcuts,
    );
    if (confirmed) await c.trashFolder(folder.id);
  }

  Future<void> _dissolve(LibraryFolder folder) async {
    final confirmed = await showLibraryConfirmDialog(
      context,
      title: '解散文件夹？',
      subtitle: folder.name,
      message: '直属内容将上移一层，资料本身不受影响。',
      confirmLabel: '解散',
    );
    if (confirmed) await c.dissolveFolder(folder.id);
  }

  @override
  Widget build(BuildContext context) {
    final tree = c.folderTree;
    return LibraryTreeScope(
      controller: c,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          widget.drawer ? 12 : 0,
          4,
          widget.drawer ? 12 : 0,
          12,
        ),
        children: [
        _ViewRow(
          icon: QIcons.library,
          label: '全部资料',
          count: c.counts.all,
          selected: c.view.scope == LibraryScope.all,
          onTap: c.showAll,
        ),
        _ViewRow(
          icon: QIcons.today,
          label: '最近打开',
          selected: c.view.scope == LibraryScope.recent,
          onTap: c.showRecent,
        ),
        _ViewRow(
          icon: QIcons.folderOpen,
          label: '未归档',
          count: c.counts.unfiled,
          selected: c.view.scope == LibraryScope.unfiled,
          onTap: c.showUnfiled,
        ),
        _ViewRow(
          icon: QIcons.star,
          label: '星标',
          count: c.counts.starred,
          selected: c.view.scope == LibraryScope.starred,
          onTap: c.showStarred,
        ),
        _ViewRow(
          icon: QIcons.trash,
          label: '回收站',
          count: c.counts.trash,
          selected: c.isTrashView,
          onTap: c.showTrash,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          child: Divider(height: 1, color: context.colors.outline),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  tree.isEmpty ? '文件夹' : '文件夹 (${c.folders.length})',
                  style: context.texts.bodySmall!.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: context.colors.inkMuted,
                  ),
                ),
              ),
              Tooltip(
                message: '新建文件夹',
                child: IconButton(
                  onPressed: () => _newFolder(),
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const QIcon(QIcons.add, size: IconSizes.sm),
                ),
              ),
              if (tree.isNotEmpty)
                Tooltip(
                  message: '展开或收起全部',
                  child: PopupMenuButton<String>(
                    tooltip: '展开或收起全部',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                    icon: const QIcon(QIcons.more, size: IconSizes.sm),
                    onSelected: (value) {
                      switch (value) {
                        case 'expand':
                          c.expandAll();
                        case 'collapse':
                          c.collapseAll();
                        case 'branches':
                          c.toggleBranchLines();
                      }
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(value: 'expand', child: Text('展开全部')),
                      const PopupMenuItem(
                        value: 'collapse',
                        child: Text('收起全部'),
                      ),
                      PopupMenuItem(
                        value: 'branches',
                        child: Text(
                          c.view.showBranchLines ? '隐藏分支线' : '显示分支线',
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        if (tree.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _newFolder(),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                ),
                icon: const QIcon(QIcons.add, size: IconSizes.sm),
                label: const Text('新建第一个文件夹'),
              ),
            ),
          )
        else
          for (final node in tree) ..._buildNode(node),
        if (c.smartFolders.isNotEmpty || c.hasSearchConditions) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '智能文件夹',
                    style: context.texts.bodySmall!.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: context.colors.inkMuted,
                    ),
                  ),
                ),
                if (c.hasSearchConditions)
                  Tooltip(
                    message: '保存当前搜索与筛选',
                    child: IconButton(
                      onPressed: _saveSmartFolder,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const QIcon(QIcons.filter, size: IconSizes.sm),
                    ),
                  ),
              ],
            ),
          ),
          for (final smart in c.smartFolders)
            _SmartFolderRow(
              key: ValueKey('smart-${smart.id}'),
              folder: smart,
              selected: c.activeSmartFolder?.id == smart.id,
              onTap: () => c.showSmartFolder(smart.id),
              onRename: () => _renameSmartFolder(smart),
              onDelete: () => _deleteSmartFolder(smart),
            ),
        ],
      ],
      ),
    );
  }

  List<Widget> _buildNode(LibraryFolderNode node) {
    final folder = node.folder;
    final expanded = c.expandedFolders.contains(folder.id);
    final children = node.children;
    final rows = <Widget>[
      if (c.view.sortField == LibrarySortField.manual)
        _FolderInsertionLine(before: folder, depth: node.depth),
      _FolderRow(
        key: ValueKey('folder-${folder.id}'),
        folder: folder,
        depth: node.depth,
        showBranches: c.view.showBranchLines,
        count: c.counts.forFolder(folder.id),
        selected: c.isFolderSelected(folder.id) ||
            (c.view.scope == LibraryScope.folder && c.view.folderId == folder.id),
        hovered: _hovered.contains(folder.id),
        hasChildren: children.isNotEmpty,
        expanded: expanded,
        colorValue: effectiveFolderColor(c, folder.id),
        onTap: () => c.openFolder(folder.id),
        onToggle: () => c.toggleExpanded(folder.id),
        onHover: (value) => setState(() {
          if (value) {
            _hovered.add(folder.id);
          } else {
            _hovered.remove(folder.id);
          }
        }),
        onNewSubfolder: () => _newFolder(parentId: folder.id),
        onRename: () => _rename(folder),
        onMove: () => _move(folder),
        onMoveUp: () => c.shiftFolder(folder.id, -1),
        onMoveDown: () => c.shiftFolder(folder.id, 1),
        onMakeManual: () => c.setSort(LibrarySortField.manual),
        canReorder: c.view.sortField == LibrarySortField.manual,
        onExport: () => _export(folder),
        onStyle: () => _style(folder),
        onDelete: () => _trash(folder),
        onDissolve: () => _dissolve(folder),
        onDragEnter: () => _scheduleExpand(folder.id, expanded),
        onDragLeave: _cancelExpand,
      ),
    ];
    if (expanded) {
      for (final child in children) {
        rows.addAll(_buildNode(child));
      }
    }
    return rows;
  }

  Timer? _expandTimer;

  void _scheduleExpand(String folderId, bool expanded) {
    _cancelExpand();
    if (expanded) return;
    _expandTimer = Timer(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      if (!c.expandedFolders.contains(folderId)) {
        c.toggleExpanded(folderId);
      }
    });
  }

  void _cancelExpand() {
    _expandTimer?.cancel();
    _expandTimer = null;
  }

  @override
  void dispose() {
    _cancelExpand();
    super.dispose();
  }
}

class _ViewRow extends StatefulWidget {
  const _ViewRow({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
  });

  final QIconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? count;

  @override
  State<_ViewRow> createState() => _ViewRowState();
}

class _ViewRowState extends State<_ViewRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
      child: Semantics(
        button: true,
        selected: widget.selected,
        child: InkWell(
          onTap: widget.onTap,
          onHover: (value) => setState(() => _hovered = value),
          borderRadius: BorderRadius.circular(Radii.md),
          hoverColor: Colors.transparent,
          child: AnimatedContainer(
            duration: context.motion(Motion.fast),
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: widget.selected
                  ? colors.tint
                  : _hovered
                  ? colors.tint.withValues(alpha: .5)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Row(
              children: [
                QIcon(
                  widget.icon,
                  size: IconSizes.md,
                  color: widget.selected ? colors.ink : colors.inkMuted,
                  active: widget.selected,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.bodyMedium!.copyWith(
                      fontSize: 13,
                      color: widget.selected ? colors.ink : colors.inkMuted,
                      fontWeight: widget.selected
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                ),
                if ((widget.count ?? 0) > 0)
                  Text(
                    '${widget.count}',
                    style: context.texts.bodySmall!.copyWith(
                      fontSize: 11.5,
                      color: colors.inkMuted,
                      fontFeatures: AppNumerals.tabular,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FolderRow extends StatefulWidget {
  const _FolderRow({
    super.key,
    required this.folder,
    required this.depth,
    required this.showBranches,
    required this.count,
    required this.selected,
    required this.hovered,
    required this.hasChildren,
    required this.expanded,
    required this.onTap,
    required this.onToggle,
    required this.onHover,
    required this.onNewSubfolder,
    required this.onRename,
    required this.onMove,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onMakeManual,
    required this.canReorder,
    required this.onExport,
    required this.onStyle,
    required this.onDelete,
    required this.onDissolve,
    required this.onDragEnter,
    required this.onDragLeave,
    this.colorValue,
  });

  final LibraryFolder folder;
  final int depth;
  final bool showBranches;
  final int count;
  final bool selected;
  final bool hovered;
  final bool hasChildren;
  final bool expanded;
  final int? colorValue;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final ValueChanged<bool> onHover;
  final VoidCallback onNewSubfolder;
  final VoidCallback onRename;
  final VoidCallback onMove;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final VoidCallback onMakeManual;
  final bool canReorder;
  final VoidCallback onExport;
  final VoidCallback onStyle;
  final VoidCallback onDelete;
  final VoidCallback onDissolve;
  final VoidCallback onDragEnter;
  final VoidCallback onDragLeave;

  @override
  State<_FolderRow> createState() => _FolderRowState();
}

class _FolderRowState extends State<_FolderRow> {
  bool _highlight = false;

  bool _accepts(LibraryDragPayload payload) {
    if (payload.isEmpty) return false;
    for (final folderId in payload.folderIds) {
      if (folderId == widget.folder.id) return false;
      if (LibraryTreeScope.of(context).descendantFolderIds(folderId).contains(
        widget.folder.id,
      )) {
        return false;
      }
    }
    return true;
  }

  LibraryController get widgetController => LibraryTreeScope.of(context);

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final iconColor = folderInk(context, widget.colorValue);
    return DragTarget<LibraryDragPayload>(
      onWillAcceptWithDetails: (details) => _accepts(details.data),
      onMove: (details) {
        if (_highlight) return;
        setState(() => _highlight = true);
        widget.onDragEnter();
      },
      onLeave: (_) {
        widget.onDragLeave();
        if (_highlight) setState(() => _highlight = false);
      },
      onAcceptWithDetails: (details) {
        widget.onDragLeave();
        setState(() => _highlight = false);
        widgetController.moveNodes(
          folderIds: details.data.folderIds,
          entryIds: details.data.entryIds,
          targetFolderId: widget.folder.id,
        );
      },
      builder: (context, candidates, rejected) {
        final row = Semantics(
          button: true,
          selected: widget.selected,
          label: '${widget.folder.name}，${widget.count} 项',
          child: InkWell(
            onTap: widget.onTap,
            onHover: widget.onHover,
            hoverColor: Colors.transparent,
            borderRadius: BorderRadius.circular(Radii.md),
            child: Container(
              height: 34,
              margin: const EdgeInsets.only(left: 12, right: 12),
              padding: const EdgeInsets.only(left: 2, right: 4),
              decoration: BoxDecoration(
                color: _highlight
                    ? colors.tint
                    : widget.selected
                    ? colors.tint
                    : widget.hovered
                    ? colors.tint.withValues(alpha: .45)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(Radii.md),
              ),
              child: Row(
                children: [
                  if (widget.depth > 0 && widget.showBranches)
                    SizedBox(
                      width: widget.depth * 14.0,
                      height: 34,
                      child: CustomPaint(
                        painter: _TreeBranchPainter(
                          depth: widget.depth,
                          color: colors.outlineStrong,
                        ),
                      ),
                    ),
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: widget.hasChildren
                        ? InkWell(
                            onTap: widget.onToggle,
                            borderRadius: BorderRadius.circular(4),
                            child: QIcon(
                              widget.expanded
                                  ? QIcons.chevronDown
                                  : QIcons.chevronRight,
                              size: 12,
                              color: colors.inkMuted,
                            ),
                          )
                        : null,
                  ),
                  if (widget.folder.icon?.isNotEmpty == true)
                    SizedBox(
                      width: 20,
                      child: Text(
                        widget.folder.icon!,
                        maxLines: 1,
                        style: const TextStyle(fontSize: 13),
                      ),
                    )
                  else
                    QIcon(
                      widget.expanded ? QIcons.folderOpen : QIcons.folder,
                      size: IconSizes.sm,
                      color: iconColor,
                      active: widget.selected,
                    ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      widget.folder.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.texts.bodyMedium!.copyWith(
                        fontSize: 12.8,
                        color: colors.ink,
                        fontWeight: widget.selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (widget.count > 0)
                    Text(
                      '${widget.count}',
                      style: context.texts.bodySmall!.copyWith(
                        fontSize: 11,
                        color: colors.inkMuted,
                        fontFeatures: AppNumerals.tabular,
                      ),
                    ),
                  if (widget.hovered || widget.selected)
                    _FolderMenu(
                      onNewSubfolder: widget.onNewSubfolder,
                      onRename: widget.onRename,
                      onMove: widget.onMove,
                      onMoveUp: widget.onMoveUp,
                      onMoveDown: widget.onMoveDown,
                      onMakeManual: widget.onMakeManual,
                      canReorder: widget.canReorder,
                      onExport: widget.onExport,
                      onStyle: widget.onStyle,
                      onDelete: widget.onDelete,
                      onDissolve: widget.onDissolve,
                    )
                  else
                    const SizedBox(width: 24),
                ],
              ),
            ),
          ),
        );
        return Draggable<LibraryDragPayload>(
          data: LibraryDragPayload(
            folderIds: {widget.folder.id},
            label: widget.folder.name,
          ),
          feedback: LibraryDragFeedback(
            label: widget.folder.name,
            icon: QIcons.folder,
          ),
          childWhenDragging: Opacity(opacity: .4, child: row),
          child: row,
        );
      },
    );
  }
}

class _FolderMenu extends StatelessWidget {
  const _FolderMenu({
    required this.onNewSubfolder,
    required this.onRename,
    required this.onMove,
    required this.onMoveUp,
    required this.onMoveDown,
    required this.onMakeManual,
    required this.canReorder,
    required this.onExport,
    required this.onStyle,
    required this.onDelete,
    required this.onDissolve,
  });

  final VoidCallback onNewSubfolder;
  final VoidCallback onRename;
  final VoidCallback onMove;
  final VoidCallback onMoveUp;
  final VoidCallback onMoveDown;
  final VoidCallback onMakeManual;
  final bool canReorder;
  final VoidCallback onExport;
  final VoidCallback onStyle;
  final VoidCallback onDelete;
  final VoidCallback onDissolve;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SizedBox(
      width: 24,
      height: 24,
      child: PopupMenuButton<String>(
        tooltip: '文件夹操作',
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
        icon: QIcon(QIcons.more, size: IconSizes.sm, color: colors.inkMuted),
        onSelected: (value) => switch (value) {
          'new' => onNewSubfolder(),
          'rename' => onRename(),
          'move' => onMove(),
          'up' => onMoveUp(),
          'down' => onMoveDown(),
          'manual' => onMakeManual(),
          'export' => onExport(),
          'style' => onStyle(),
          'delete' => onDelete(),
          'dissolve' => onDissolve(),
          _ => null,
        },
        itemBuilder: (context) => [
          const PopupMenuItem(value: 'new', child: Text('新建子文件夹')),
          const PopupMenuItem(value: 'rename', child: Text('重命名')),
          const PopupMenuItem(value: 'move', child: Text('移动到…')),
          const PopupMenuItem(value: 'export', child: Text('导出文件夹…')),
          if (canReorder) ...[
            const PopupMenuItem(value: 'up', child: Text('上移')),
            const PopupMenuItem(value: 'down', child: Text('下移')),
          ] else
            const PopupMenuItem(value: 'manual', child: Text('改为手动顺序')),
          const PopupMenuItem(value: 'style', child: Text('颜色与图标…')),
          const PopupMenuDivider(),
          const PopupMenuItem(value: 'dissolve', child: Text('解散文件夹并保留资料')),
          const PopupMenuItem(value: 'delete', child: Text('移入回收站')),
        ],
      ),
    );
  }
}

class _SmartFolderRow extends StatefulWidget {
  const _SmartFolderRow({
    super.key,
    required this.folder,
    required this.selected,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final SmartFolder folder;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  State<_SmartFolderRow> createState() => _SmartFolderRowState();
}

class _SmartFolderRowState extends State<_SmartFolderRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final selected = widget.selected;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
      child: Semantics(
        button: true,
        selected: selected,
        label: '智能文件夹 ${widget.folder.name}',
        child: InkWell(
          onTap: widget.onTap,
          onHover: (value) => setState(() => _hovered = value),
          borderRadius: BorderRadius.circular(Radii.md),
          hoverColor: Colors.transparent,
          child: AnimatedContainer(
            duration: context.motion(Motion.fast),
            height: 40,
            padding: const EdgeInsets.only(left: 10, right: 2),
            decoration: BoxDecoration(
              color: selected
                  ? colors.tint
                  : _hovered
                  ? colors.tint.withValues(alpha: .45)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Row(
              children: [
                QIcon(
                  QIcons.filter,
                  size: IconSizes.sm,
                  color: selected ? colors.ink : colors.inkMuted,
                  active: selected,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.folder.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.texts.bodyMedium!.copyWith(
                          fontSize: 12.5,
                          color: selected ? colors.ink : colors.inkMuted,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                      Text(
                        widget.folder.conditionLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.texts.bodySmall!.copyWith(
                          fontSize: 10.5,
                          color: colors.inkMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_hovered || selected)
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: PopupMenuButton<String>(
                      tooltip: '智能文件夹操作',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 24,
                        minHeight: 24,
                      ),
                      icon: QIcon(
                        QIcons.more,
                        size: IconSizes.sm,
                        color: colors.inkMuted,
                      ),
                      onSelected: (value) => value == 'rename'
                          ? widget.onRename()
                          : widget.onDelete(),
                      itemBuilder: (context) => const [
                        PopupMenuItem(value: 'rename', child: Text('重命名')),
                        PopupMenuItem(value: 'delete', child: Text('删除条件')),
                      ],
                    ),
                  )
                else
                  const SizedBox(width: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Makes the controller available to the folder row's drag callbacks without
/// threading it through every small widget.
class LibraryTreeScope extends InheritedWidget {  const LibraryTreeScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final LibraryController controller;

  static LibraryController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<LibraryTreeScope>();
    assert(scope != null, 'LibraryTreeScope is missing');
    return scope!.controller;
  }

  @override
  bool updateShouldNotify(LibraryTreeScope oldWidget) =>
      oldWidget.controller != controller;
}


/// The thin insertion line between sibling folders. Dropping here reorders the
/// dragged folder inside the same parent; dropping on the row centre still
/// moves it into the folder. Name/date sorting disables reordering because the
/// visible order would immediately contradict the stored manual order.
class _FolderInsertionLine extends StatefulWidget {
  const _FolderInsertionLine({required this.before, required this.depth});

  final LibraryFolder before;
  final int depth;

  @override
  State<_FolderInsertionLine> createState() => _FolderInsertionLineState();
}

class _FolderInsertionLineState extends State<_FolderInsertionLine> {
  bool _accepts(LibraryController controller, LibraryDragPayload payload) {
    if (controller.view.sortField != LibrarySortField.manual ||
        payload.folderIds.length != 1 ||
        payload.entryIds.isNotEmpty) {
      return false;
    }
    final dragged = controller.folderById(payload.folderIds.first);
    final target = controller.folderById(widget.before.id);
    return dragged != null &&
        target != null &&
        dragged.id != target.id &&
        dragged.parentId == target.parentId;
  }

  @override
  Widget build(BuildContext context) {
    final controller = LibraryTreeScope.of(context);
    final colors = context.colors;
    return DragTarget<LibraryDragPayload>(
      onWillAcceptWithDetails: (details) => _accepts(controller, details.data),
      onAcceptWithDetails: (details) {
        controller.reorderFolder(
          details.data.folderIds.first,
          beforeFolderId: widget.before.id,
        );
      },
      builder: (context, candidates, rejected) => Container(
        height: 6,
        margin: EdgeInsets.only(
          left: 24 + widget.depth * 14.0,
          right: 12,
        ),
        alignment: Alignment.centerLeft,
        child: AnimatedContainer(
          duration: context.motion(Motion.fast),
          height: candidates.isEmpty ? 0 : 2,
          decoration: BoxDecoration(
            color: colors.primary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}
/// Vertical guide lines for the folder branch tree. Each row reserves the
/// indentation width and paints one faint line per ancestor depth plus a short
/// horizontal tick into the current row.
class _TreeBranchPainter extends CustomPainter {
  const _TreeBranchPainter({required this.depth, required this.color});

  final int depth;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (depth <= 0) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (var level = 0; level < depth; level++) {
      final x = level * 14.0 + 7;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    final tickX = (depth - 1) * 14.0 + 7;
    final centerY = size.height / 2;
    canvas.drawLine(
      Offset(tickX, centerY),
      Offset(depth * 14.0, centerY),
      paint,
    );
  }

  @override
  bool shouldRepaint(_TreeBranchPainter oldDelegate) =>
      oldDelegate.depth != depth || oldDelegate.color != color;
}