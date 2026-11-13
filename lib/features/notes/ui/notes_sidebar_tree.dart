import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../ui/theme/tokens.dart';
import '../../../ui/widgets/app_dialog.dart';
import '../../../ui/widgets/app_surfaces.dart';
import '../../library/models/library_models.dart';
import '../models/note_models.dart';
import '../notes_controller.dart';

/// Unified single left sidebar for the Notes workspace.
///
/// Merges scope/folder/tag filtering and the searchable note list into one
/// calm, structured panel so the Notes view never displays two sidebars side
/// by side.
class NotesSidebarTree extends StatefulWidget {
  const NotesSidebarTree({
    super.key,
    required this.controller,
    this.drawer = false,
  });

  final NotesController controller;
  final bool drawer;

  @override
  State<NotesSidebarTree> createState() => _NotesSidebarTreeState();
}

class _NotesSidebarTreeState extends State<NotesSidebarTree> {
  final _search = TextEditingController();
  final _listFocus = FocusNode(debugLabel: 'notes-unified-sidebar');
  final _expanded = <String>{};
  bool _foldersExpanded = true;

  NotesController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _search.text = c.query;
  }

  @override
  void dispose() {
    _search.dispose();
    _listFocus.dispose();
    super.dispose();
  }

  void _syncSearch() {
    if (_search.text != c.query) {
      _search.value = TextEditingValue(
        text: c.query,
        selection: TextSelection.collapsed(offset: c.query.length),
      );
    }
  }

  KeyEventResult _onListKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final items = c.notes;
    if (items.isEmpty) return KeyEventResult.ignored;
    final currentIndex = c.selected == null
        ? -1
        : items.indexWhere((n) => n.id == c.selected!.id);
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      final next = (currentIndex + 1).clamp(0, items.length - 1);
      c.select(items[next].id);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      final prev = (currentIndex <= 0 ? 0 : currentIndex - 1).clamp(
        0,
        items.length - 1,
      );
      c.select(items[prev].id);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        _syncSearch();
        final colors = context.colors;
        final activeTag = c.tagFilter == null
            ? null
            : c.tags.where((t) => t.id == c.tagFilter).firstOrNull;
        return Focus(
          focusNode: _listFocus,
          onKeyEvent: _onListKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. Search + Sort + New Note
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 34,
                        child: TextField(
                          controller: _search,
                          style: context.texts.bodySmall!.copyWith(
                            fontSize: 12.5,
                          ),
                          decoration: InputDecoration(
                            hintText: '搜索笔记…',
                            prefixIcon: const Padding(
                              padding: EdgeInsets.only(left: 9, right: 4),
                              child: QIcon(QIcons.search, size: IconSizes.sm),
                            ),
                            prefixIconConstraints: const BoxConstraints(
                              minWidth: 30,
                              minHeight: 30,
                            ),
                            suffixIcon: _search.text.isNotEmpty
                                ? IconButton(
                                    tooltip: '清除搜索',
                                    onPressed: () {
                                      _search.clear();
                                      c.setQuery('');
                                    },
                                    icon: const QIcon(QIcons.close, size: 12),
                                    visualDensity: VisualDensity.compact,
                                    padding: EdgeInsets.zero,
                                  )
                                : null,
                            suffixIconConstraints: const BoxConstraints(
                              minWidth: 26,
                              minHeight: 26,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 6,
                            ),
                            isDense: true,
                            filled: true,
                            fillColor: colors.surfaceRaised,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(Radii.md),
                              borderSide: BorderSide(color: colors.outline),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(Radii.md),
                              borderSide: BorderSide(color: colors.outline),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(Radii.md),
                              borderSide: BorderSide(
                                color: colors.outlineStrong,
                              ),
                            ),
                          ),
                          onChanged: c.setQuery,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    _sortMenu(context),
                    const SizedBox(width: 4),
                    _newNoteButton(context),
                  ],
                ),
              ),

              // 2. Compact Scope Strip
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                child: Row(
                  children: [
                    _scopeChip(
                      context,
                      label: '全部',
                      count: c.counts.all,
                      selected: c.scope == NotesScope.all,
                      onTap: () => c.setScope(NotesScope.all),
                    ),
                    const SizedBox(width: 4),
                    _scopeChip(
                      context,
                      label: '星标',
                      count: c.counts.starred,
                      selected: c.scope == NotesScope.starred,
                      onTap: () => c.setScope(NotesScope.starred),
                    ),
                    const SizedBox(width: 4),
                    _scopeChip(
                      context,
                      label: '待解决',
                      count: c.counts.openQuestions,
                      selected: c.scope == NotesScope.openQuestions,
                      onTap: () => c.setScope(NotesScope.openQuestions),
                    ),
                    const Spacer(),
                    _moreScopesMenu(context),
                  ],
                ),
              ),

              // 3. Active secondary scope or tag banner (only when active)
              if (c.scope == NotesScope.recent ||
                  c.scope == NotesScope.related ||
                  c.scope == NotesScope.unfiled ||
                  c.scope == NotesScope.trash ||
                  activeTag != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (c.scope == NotesScope.recent ||
                          c.scope == NotesScope.related ||
                          c.scope == NotesScope.unfiled ||
                          c.scope == NotesScope.trash)
                        _activeFilterPill(
                          context,
                          icon: switch (c.scope) {
                            NotesScope.recent => QIcons.today,
                            NotesScope.related => QIcons.anchor,
                            NotesScope.unfiled => QIcons.folder,
                            NotesScope.trash => QIcons.trash,
                            _ => QIcons.notes,
                          },
                          label: c.scope.label,
                          onClear: () => c.setScope(NotesScope.all),
                        ),
                      if (activeTag != null)
                        _activeFilterPill(
                          context,
                          icon: QIcons.tag,
                          label: activeTag.name,
                          onClear: () => c.setTagFilter(null),
                        ),
                      if (c.scope == NotesScope.trash && c.notes.isNotEmpty)
                        InkWell(
                          onTap: () => _confirmEmptyTrash(context),
                          borderRadius: BorderRadius.circular(Radii.sm),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 2,
                            ),
                            child: Text(
                              '清空回收站',
                              style: context.texts.bodySmall!.copyWith(
                                fontSize: 12,
                                color: colors.danger,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),

              // 4. Collapsible Folder Section
              _foldersSection(context),

              Divider(height: 1, color: colors.outline),

              // 5. Note List
              Expanded(
                child: c.notes.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: EmptyState(
                            compact: true,
                            icon: QIcons.notes,
                            title: c.query.isNotEmpty ? '没有匹配的笔记' : '暂无笔记',
                            message: c.query.isNotEmpty
                                ? '换一个关键词，或切换筛选范围。'
                                : '写下你的理解，或从阅读器摘录原文。',
                            action: c.scope == NotesScope.trash
                                ? null
                                : FilledButton.icon(
                                    onPressed: () {
                                      c.createNote();
                                      if (widget.drawer &&
                                          Navigator.canPop(context)) {
                                        Navigator.pop(context);
                                      }
                                    },
                                    icon: const QIcon(
                                      QIcons.add,
                                      size: IconSizes.sm,
                                    ),
                                    label: const Text('新建笔记'),
                                  ),
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(10, 6, 10, 16),
                        itemCount: c.notes.length,
                        itemBuilder: (context, index) {
                          final note = c.notes[index];
                          final summary =
                              c.summaries[note.id] ?? const NoteListSummary();
                          final selected = c.selected?.id == note.id;
                          final folder = summary.folderId == null
                              ? null
                              : c.folders
                                    .where((f) => f.id == summary.folderId)
                                    .firstOrNull;
                          return _UnifiedNoteTile(
                            key: ValueKey('note-row-${note.id}'),
                            note: note,
                            summary: summary,
                            folder: folder,
                            selected: selected,
                            onTap: () {
                              _listFocus.requestFocus();
                              c.select(note.id);
                              if (widget.drawer && Navigator.canPop(context)) {
                                Navigator.pop(context);
                              }
                            },
                            onSecondaryTapDown: (details) =>
                                _showNoteContextMenu(
                                  context,
                                  note,
                                  details.globalPosition,
                                ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _scopeChip(
    BuildContext context, {
    required String label,
    required int count,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.sm),
      child: Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: selected ? colors.tint : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: context.texts.bodySmall!.copyWith(
                fontSize: 12,
                color: selected ? colors.ink : colors.inkMuted,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
            if (count > 0) ...[
              const SizedBox(width: 4),
              Text(
                '$count',
                style: context.texts.bodySmall!.copyWith(
                  fontSize: 12,
                  color: selected ? colors.ink : colors.inkMuted,
                  fontFeatures: AppNumerals.tabular,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _moreScopesMenu(BuildContext context) {
    final colors = context.colors;
    final secondaryActive =
        c.scope == NotesScope.recent ||
        c.scope == NotesScope.related ||
        c.scope == NotesScope.unfiled ||
        c.scope == NotesScope.trash ||
        c.tagFilter != null;
    return PopupMenuButton<String>(
      tooltip: '更多范围与标签筛选',
      padding: EdgeInsets.zero,
      onSelected: (value) {
        if (value.startsWith('scope:')) {
          final name = value.substring('scope:'.length);
          final scope = NotesScope.values.firstWhere((s) => s.name == name);
          c.setScope(scope);
        } else if (value.startsWith('tag:')) {
          final tagId = value.substring('tag:'.length);
          c.setTagFilter(c.tagFilter == tagId ? null : tagId);
        } else if (value == 'clear_tag') {
          c.setTagFilter(null);
        }
      },
      itemBuilder: (context) => [
        CheckedPopupMenuItem(
          value: 'scope:${NotesScope.recent.name}',
          checked: c.scope == NotesScope.recent,
          child: const Text('最近编辑'),
        ),
        CheckedPopupMenuItem(
          value: 'scope:${NotesScope.related.name}',
          checked: c.scope == NotesScope.related,
          child: Text('关联资料 (${c.counts.related})'),
        ),
        CheckedPopupMenuItem(
          value: 'scope:${NotesScope.unfiled.name}',
          checked: c.scope == NotesScope.unfiled,
          child: Text('未归档 (${c.counts.unfiled})'),
        ),
        CheckedPopupMenuItem(
          value: 'scope:${NotesScope.trash.name}',
          checked: c.scope == NotesScope.trash,
          child: Text('回收站 (${c.counts.trash})'),
        ),
        if (c.tags.isNotEmpty) ...[
          const PopupMenuDivider(),
          for (final tag in c.tags)
            CheckedPopupMenuItem(
              value: 'tag:${tag.id}',
              checked: c.tagFilter == tag.id,
              child: Text('#${tag.name}'),
            ),
        ],
      ],
      child: Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 7),
        decoration: BoxDecoration(
          color: secondaryActive ? colors.tint : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            QIcon(
              QIcons.filter,
              size: 12,
              color: secondaryActive ? colors.ink : colors.inkMuted,
            ),
            const SizedBox(width: 3),
            Text(
              '筛选',
              style: context.texts.bodySmall!.copyWith(
                fontSize: 12,
                color: secondaryActive ? colors.ink : colors.inkMuted,
                fontWeight: secondaryActive ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _activeFilterPill(
    BuildContext context, {
    required QIconData icon,
    required String label,
    required VoidCallback onClear,
  }) {
    final colors = context.colors;
    return Container(
      height: 24,
      padding: const EdgeInsets.only(left: 7, right: 4),
      decoration: BoxDecoration(
        color: colors.tint,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: colors.outlineStrong),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          QIcon(icon, size: 12, color: colors.ink),
          const SizedBox(width: 4),
          Text(
            label,
            style: context.texts.bodySmall!.copyWith(
              fontSize: 12,
              color: colors.ink,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 4),
          InkWell(
            onTap: onClear,
            borderRadius: BorderRadius.circular(Radii.sm),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: QIcon(QIcons.close, size: 11, color: colors.inkMuted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _foldersSection(BuildContext context) {
    final colors = context.colors;
    final hasFolders = c.folders.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: hasFolders
                      ? () => setState(
                          () => _foldersExpanded = !_foldersExpanded,
                        )
                      : () => _newFolder(),
                  borderRadius: BorderRadius.circular(Radii.sm),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        QIcon(
                          _foldersExpanded && hasFolders
                              ? QIcons.chevronDown
                              : QIcons.chevronRight,
                          size: 11,
                          color: colors.inkMuted,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          hasFolders ? '文件夹 (${c.folders.length})' : '文件夹',
                          style: context.texts.bodySmall!.copyWith(
                            fontSize: 12,
                            color: colors.inkMuted,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (c.scope == NotesScope.folder)
                InkWell(
                  onTap: () => c.setScope(NotesScope.all),
                  borderRadius: BorderRadius.circular(Radii.sm),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    child: Text(
                      '显示全部',
                      style: context.texts.bodySmall!.copyWith(
                        fontSize: 12,
                        color: colors.primary,
                      ),
                    ),
                  ),
                ),
              Tooltip(
                message: '新建文件夹',
                child: InkWell(
                  onTap: () => _newFolder(),
                  borderRadius: BorderRadius.circular(Radii.sm),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: QIcon(QIcons.add, size: 13, color: colors.inkMuted),
                  ),
                ),
              ),
            ],
          ),
          if (_foldersExpanded && hasFolders)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 132),
              child: SingleChildScrollView(
                child: _folderNodes(context, null, 0),
              ),
            ),
        ],
      ),
    );
  }

  Widget _folderNodes(BuildContext context, String? parentId, int depth) {
    final children = c.childrenOf(parentId);
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final folder in children) ...[
          _folderRow(context, folder, depth),
          if (_expanded.contains(folder.id))
            _folderNodes(context, folder.id, depth + 1),
        ],
      ],
    );
  }

  Widget _folderRow(BuildContext context, LibraryFolder folder, int depth) {
    final colors = context.colors;
    final selected =
        c.scope == NotesScope.folder && c.scopeFolderId == folder.id;
    final hasChildren = c.childrenOf(folder.id).isNotEmpty;
    final count = c.noteCountForFolder(folder.id);
    final color = folder.colorValue == null
        ? colors.inkMuted
        : Color(folder.colorValue!);
    return GestureDetector(
      onSecondaryTapDown: (details) =>
          _showFolderContextMenu(context, folder, details.globalPosition),
      child: InkWell(
        onTap: () {
          if (selected) {
            c.setScope(NotesScope.all);
          } else {
            c.openFolder(folder.id);
          }
        },
        borderRadius: BorderRadius.circular(Radii.sm),
        child: Container(
          margin: const EdgeInsets.only(bottom: 1),
          padding: EdgeInsets.fromLTRB(4 + depth * 12.0, 4, 6, 4),
          decoration: BoxDecoration(
            color: selected ? colors.tint : Colors.transparent,
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                child: hasChildren
                    ? InkWell(
                        onTap: () => setState(() {
                          if (!_expanded.remove(folder.id)) {
                            _expanded.add(folder.id);
                          }
                        }),
                        child: QIcon(
                          _expanded.contains(folder.id)
                              ? QIcons.chevronDown
                              : QIcons.chevronRight,
                          size: 11,
                          color: colors.inkMuted,
                        ),
                      )
                    : null,
              ),
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  folder.icon?.isNotEmpty == true
                      ? '${folder.icon} ${folder.name}'
                      : folder.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.bodySmall!.copyWith(
                    fontSize: 12,
                    color: selected ? colors.ink : colors.inkMuted,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              if (count > 0)
                Text(
                  '$count',
                  style: context.texts.bodySmall!.copyWith(
                    fontSize: 12,
                    color: colors.inkMuted,
                    fontFeatures: AppNumerals.tabular,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sortMenu(BuildContext context) {
    final colors = context.colors;
    return PopupMenuButton<String>(
      tooltip: '排序方式',
      padding: EdgeInsets.zero,
      onSelected: (value) {
        if (value == 'direction') {
          c.toggleSortAsc();
          return;
        }
        final sort = NotesSortBy.values.firstWhere((s) => s.name == value);
        c.setSortBy(sort);
      },
      itemBuilder: (context) => [
        for (final sort in NotesSortBy.values)
          CheckedPopupMenuItem<String>(
            value: sort.name,
            checked: c.sortBy == sort,
            child: Text(sort.label),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'direction',
          child: Text(c.sortAsc ? '当前：升序（点击改为降序）' : '当前：降序（点击改为升序）'),
        ),
      ],
      child: Container(
        width: 32,
        height: 34,
        decoration: BoxDecoration(
          color: colors.surfaceRaised,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: colors.outline),
        ),
        child: Center(
          child: QIcon(QIcons.sort, size: IconSizes.sm, color: colors.inkMuted),
        ),
      ),
    );
  }

  Widget _newNoteButton(BuildContext context) {
    final colors = context.colors;
    return GestureDetector(
      onSecondaryTapDown: (details) =>
          _showTemplateMenu(context, details.globalPosition),
      child: Tooltip(
        message: '新建笔记（右键从模板新建）',
        child: InkWell(
          onTap: () {
            c.createNote();
            if (widget.drawer && Navigator.canPop(context)) {
              Navigator.pop(context);
            }
          },
          borderRadius: BorderRadius.circular(Radii.md),
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: colors.primary,
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Center(
              child: QIcon(
                QIcons.add,
                size: IconSizes.sm,
                color: colors.onPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showTemplateMenu(
    BuildContext context,
    Offset globalPosition,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final size = overlay?.size ?? const Size(1200, 800);
    final selected = await showMenu<NoteTemplate>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        size.width - globalPosition.dx,
        size.height - globalPosition.dy,
      ),
      items: [
        for (final template in noteTemplates)
          PopupMenuItem(
            value: template,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  template.name,
                  style: context.texts.bodyMedium!.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  template.hint,
                  style: context.texts.bodySmall!.copyWith(
                    fontSize: 12,
                    color: context.colors.inkMuted,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    if (selected != null) {
      c.createNote(body: selected.body);
      if (widget.drawer && context.mounted && Navigator.canPop(context)) {
        Navigator.pop(context);
      }
    }
  }

  Future<void> _showFolderContextMenu(
    BuildContext context,
    LibraryFolder folder,
    Offset globalPosition,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final size = overlay?.size ?? const Size(1200, 800);
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        size.width - globalPosition.dx,
        size.height - globalPosition.dy,
      ),
      items: const [
        PopupMenuItem(value: 'new_note', child: Text('在此新建笔记')),
        PopupMenuItem(value: 'new_subfolder', child: Text('新建子文件夹')),
      ],
    );
    if (!context.mounted || action == null) return;
    if (action == 'new_note') {
      c.openFolder(folder.id);
      c.createNote(folderId: folder.id);
      if (widget.drawer && Navigator.canPop(context)) {
        Navigator.pop(context);
      }
    } else if (action == 'new_subfolder') {
      await _newFolder(parentId: folder.id);
    }
  }

  Future<void> _showNoteContextMenu(
    BuildContext context,
    NoteRecord note,
    Offset globalPosition,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final size = overlay?.size ?? const Size(1200, 800);
    final isTrashed = note.isTrashed;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        size.width - globalPosition.dx,
        size.height - globalPosition.dy,
      ),
      items: isTrashed
          ? const [
              PopupMenuItem(value: 'restore', child: Text('恢复笔记')),
              PopupMenuItem(value: 'purge', child: Text('永久删除')),
            ]
          : [
              PopupMenuItem(
                value: 'star',
                child: Text(note.starred ? '取消星标' : '加星标'),
              ),
              const PopupMenuItem(value: 'move', child: Text('移动到文件夹…')),
              const PopupMenuItem(value: 'copy', child: Text('复制 Markdown')),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'trash', child: Text('移入回收站')),
            ],
    );
    if (!context.mounted || action == null) return;
    switch (action) {
      case 'star':
        c.select(note.id);
        c.toggleStar();
      case 'move':
        c.select(note.id);
        await _pickFolderForSelected(context);
      case 'copy':
        final text = note.title.trim().isEmpty
            ? note.body
            : '# ${note.title}\n\n${note.body}';
        await Clipboard.setData(ClipboardData(text: text));
      case 'trash':
        c.trashNote(note.id);
      case 'restore':
        c.restoreNote(note.id);
      case 'purge':
        c.purgeNote(note.id);
    }
  }

  Future<void> _pickFolderForSelected(BuildContext context) async {
    final currentFolderId = c.selectedEntry?.folderId;
    await showAppDialog<void>(
      context: context,
      builder: (context) => AppDialog(
        title: '移动到文件夹',
        subtitle: '与书库共用同一套文件夹结构。',
        maxWidth: 400,
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320),
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                dense: true,
                title: const Text('未归档'),
                trailing: currentFolderId == null
                    ? const QIcon(QIcons.check, size: IconSizes.sm)
                    : null,
                onTap: () {
                  c.moveToFolder(null);
                  Navigator.pop(context);
                },
              ),
              for (final folder in c.folders)
                ListTile(
                  dense: true,
                  title: Text(folder.name),
                  trailing: currentFolderId == folder.id
                      ? const QIcon(QIcons.check, size: IconSizes.sm)
                      : null,
                  onTap: () {
                    c.moveToFolder(folder.id);
                    Navigator.pop(context);
                  },
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmEmptyTrash(BuildContext context) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: '清空回收站？',
        icon: QIcons.trash,
        maxWidth: 400,
        content: DialogBodyText('回收站中的 ${c.notes.length} 篇笔记将被永久删除，无法恢复。'),
        actions: [
          DialogActions.cancel(context),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.colors.danger,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('永久清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      c.emptyTrash();
    }
  }

  Future<void> _newFolder({String? parentId}) async {
    final text = TextEditingController();
    final created = await showAppDialog<String>(
      context: context,
      builder: (context) => AppDialog(
        title: parentId == null ? '新建文件夹' : '新建子文件夹',
        subtitle: '笔记与书库共用同一套文件夹。',
        maxWidth: 400,
        content: TextField(
          controller: text,
          autofocus: true,
          decoration: const InputDecoration(hintText: '文件夹名称'),
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          DialogActions.cancel(context),
          FilledButton(
            onPressed: () => Navigator.pop(context, text.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    text.dispose();
    if (created != null && created.isNotEmpty) {
      final folder = c.createFolder(created, parentId: parentId);
      if (parentId != null) {
        setState(() => _expanded.add(parentId));
      }
      c.openFolder(folder.id);
    }
  }
}

class _UnifiedNoteTile extends StatefulWidget {
  const _UnifiedNoteTile({
    super.key,
    required this.note,
    required this.summary,
    required this.folder,
    required this.selected,
    required this.onTap,
    required this.onSecondaryTapDown,
  });

  final NoteRecord note;
  final NoteListSummary summary;
  final LibraryFolder? folder;
  final bool selected;
  final VoidCallback onTap;
  final GestureTapDownCallback onSecondaryTapDown;

  @override
  State<_UnifiedNoteTile> createState() => _UnifiedNoteTileState();
}

class _UnifiedNoteTileState extends State<_UnifiedNoteTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final note = widget.note;
    final summary = widget.summary;
    final preview = note.plainText;
    final sourceLabel = summary.sourceLabel;
    final metaParts = <String>[
      if (widget.folder != null) widget.folder!.name,
      ?sourceLabel,
      if (summary.openQuestions > 0) '${summary.openQuestions} 待解决',
    ];
    return GestureDetector(
      onSecondaryTapDown: widget.onSecondaryTapDown,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(Radii.md),
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
              decoration: BoxDecoration(
                color: widget.selected
                    ? colors.tint
                    : (_hovered
                          ? colors.tint.withValues(alpha: .5)
                          : Colors.transparent),
                borderRadius: BorderRadius.circular(Radii.md),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          note.displayTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.texts.bodyMedium!.copyWith(
                            fontSize: 13,
                            fontWeight: widget.selected
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: colors.ink,
                          ),
                        ),
                      ),
                      if (note.starred) ...[
                        const SizedBox(width: 4),
                        QIcon(
                          QIcons.star,
                          size: 12,
                          color: colors.inkMuted,
                          active: true,
                        ),
                      ],
                      const SizedBox(width: 6),
                      Text(
                        _shortTime(note.updatedAt),
                        style: context.texts.bodySmall!.copyWith(
                          fontSize: 12,
                          color: colors.inkMuted,
                          fontFeatures: AppNumerals.tabular,
                        ),
                      ),
                    ],
                  ),
                  if (preview.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.texts.bodySmall!.copyWith(
                        fontSize: 12,
                        color: colors.inkMuted,
                        height: 1.35,
                      ),
                    ),
                  ],
                  if (metaParts.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (widget.folder != null) ...[
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: widget.folder!.colorValue != null
                                  ? Color(widget.folder!.colorValue!)
                                  : colors.primary,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 5),
                        ],
                        Expanded(
                          child: Text(
                            metaParts.join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.texts.bodySmall!.copyWith(
                              fontSize: 12,
                              color: summary.openQuestions > 0
                                  ? colors.primary
                                  : colors.inkMuted,
                              fontWeight: summary.openQuestions > 0
                                  ? FontWeight.w500
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _shortTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 2) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes}分前';
    if (diff.inHours < 24) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    return '${time.month}/${time.day}';
  }
}
