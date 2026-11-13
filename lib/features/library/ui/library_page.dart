import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app_controller.dart';
import '../../../core/models.dart';
import '../../../ui/shell/app_shell.dart';
import '../../../ui/theme/tokens.dart';
import '../../../ui/widgets/app_surfaces.dart';
import '../import/import_models.dart';
import '../library_controller.dart';
import '../models/library_models.dart';
import 'import_actions.dart';
import '../services/library_thumbnail_service.dart';
import 'library_dialogs.dart';
import 'library_inspector.dart';
import 'library_style.dart';
import 'library_thumbnail.dart';

/// The library workspace: folder tree, breadcrumb, results, details, selection
/// bar and the import queue. File management state lives in
/// [LibraryController]; opening a document stays with [StudyController].
class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.study,
    required this.library,
    required this.query,
    required this.onClearSearch,
    required this.onOpenDocument,
    this.onOpenNote,
    this.onCreateNoteForDocument,
    this.searchController,
    this.onSearchChanged,
    this.sidebarCollapsed = false,
    this.onToggleSidebar,
    this.onOpenSettings,
    this.showSidebarToggle = false,
    this.showWindowChrome = false,
    this.topBanner,
  });

  final StudyController study;
  final LibraryController library;
  final String query;
  final VoidCallback onClearSearch;
  final Future<void> Function(DocumentRecord document) onOpenDocument;
  final ValueChanged<String>? onOpenNote;
  final ValueChanged<DocumentRecord>? onCreateNoteForDocument;
  final TextEditingController? searchController;
  final ValueChanged<String>? onSearchChanged;
  final bool sidebarCollapsed;
  final VoidCallback? onToggleSidebar;
  final VoidCallback? onOpenSettings;
  final bool showSidebarToggle;
  final bool showWindowChrome;
  final Widget? topBanner;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  final _focus = FocusNode(debugLabel: 'library-page');
  final _scrollController = ScrollController();
  Timer? _searchDebounce;
  LibraryDragPayload? _clipboard;
  String _lastQuery = '';
  bool _externalDragActive = false;
  bool _inlineSearchOpen = false;
  late final LibraryThumbnailService _thumbnails;

  LibraryController get c => widget.library;

  @override
  void initState() {
    super.initState();
    _thumbnails = LibraryThumbnailService(documents: widget.library.documents);
    _lastQuery = widget.query;
    if (widget.query.trim().isNotEmpty) {
      scheduleMicrotask(() {
        if (mounted) c.setQuery(widget.query);
      });
    }
  }

  @override
  void didUpdateWidget(LibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.query != _lastQuery) {
      _lastQuery = widget.query;
      _searchDebounce?.cancel();
      if (widget.query.trim().isEmpty) {
        // Clearing a search is an explicit reset; apply it immediately instead
        // of waiting out the typing debounce.
        scheduleMicrotask(() {
          if (mounted) c.setQuery('');
        });
      } else {
        _searchDebounce = Timer(const Duration(milliseconds: 180), () {
          if (mounted) c.setQuery(widget.query);
        });
      }
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _scrollController.dispose();
    _focus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Keyboard
  // ---------------------------------------------------------------------------

  bool get _editingText {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    return context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _editingText) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final control = keyboard.isControlPressed;
    final shift = keyboard.isShiftPressed;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (c.hasSelection) {
        c.clearSelection();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.arrowUp) {
      final visible = c.items;
      if (visible.isEmpty) return KeyEventResult.ignored;
      final selected = c.selectedItems;
      final currentId = selected.isEmpty ? null : selected.last.entry.id;
      final currentIndex = currentId == null
          ? -1
          : visible.indexWhere((i) => i.entry.id == currentId);
      final delta =
          event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1;
      final nextIndex = currentIndex < 0
          ? 0
          : (currentIndex + delta).clamp(0, visible.length - 1);
      c.selectEntry(
        visible[nextIndex].entry.id,
        range: shift,
      );
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      final items = c.selectedItems;
      if (items.length == 1) {
        _open(items.first);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.f2) {
      final items = c.selectedItems;
      if (items.length == 1) _rename(items.first);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.delete) {
      _trashSelection();
      return KeyEventResult.handled;
    }
    if (control && event.logicalKey == LogicalKeyboardKey.keyA) {
      c.selectAllVisible();
      return KeyEventResult.handled;
    }
    if (control && shift && event.logicalKey == LogicalKeyboardKey.keyN) {
      _newFolder();
      return KeyEventResult.handled;
    }
    if (control && event.logicalKey == LogicalKeyboardKey.keyZ) {
      c.undoLast();
      return KeyEventResult.handled;
    }
    if (control && event.logicalKey == LogicalKeyboardKey.keyX) {
      _clipboard = _selectionPayload();
      return KeyEventResult.handled;
    }
    if (control && event.logicalKey == LogicalKeyboardKey.keyC) {
      _clipboard = _selectionPayload();
      return KeyEventResult.handled;
    }
    if (control && event.logicalKey == LogicalKeyboardKey.keyV) {
      final clipboard = _clipboard;
      if (clipboard == null || c.isTrashView) return KeyEventResult.handled;
      c.moveNodes(
        folderIds: clipboard.folderIds,
        entryIds: clipboard.entryIds,
        targetFolderId: c.currentFolder?.id,
      );
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  LibraryDragPayload? _selectionPayload() {
    if (!c.hasSelection) return null;
    return LibraryDragPayload(
      folderIds: c.selectedFolders,
      entryIds: c.selectedEntries,
      label: '${c.selectionCount} 项',
    );
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<void> _open(LibraryItem item) async {
    if (!item.available) {
      final ok = await showLibraryConfirmDialog(
        context,
        title: '资料在回收站',
        subtitle: item.displayName,
        message: '恢复这份资料后才能继续阅读。要在回收站中恢复它吗？',
        confirmLabel: '查看回收站',
      );
      if (ok) c.showTrash();
      return;
    }
    await widget.onOpenDocument(item.document);
  }

  Future<void> _newFolder({String? parentId}) async {
    final id = parentId ?? c.currentFolder?.id;
    final name = await showLibraryTextDialog(
      context,
      title: id == null ? '新建文件夹' : '新建子文件夹',
      label: '文件夹名称',
      hint: '例如：大三上、高分子化学、期末备考',
      confirmLabel: '新建',
      maxLength: 80,
      validate: (value) {
        if (value.isEmpty) return '文件夹名称不能为空。';
        if (c.repository.folderNameExists(id, value)) {
          return '同一位置已经有名为「$value」的文件夹。';
        }
        return null;
      },
    );
    if (name != null) await c.createFolder(name: name, parentId: id);
  }

  Future<void> _rename(LibraryItem item) async {
    final name = await showLibraryTextDialog(
      context,
      title: item.isShortcut ? '重命名快捷方式' : '重命名资料',
      subtitle: item.isShortcut
          ? '只改变这个入口的名称，原资料不受影响。'
          : '只改变显示名，不改文件格式，也不改你磁盘上的原文件。',
      label: '名称',
      initial: item.displayName,
      confirmLabel: '重命名',
      maxLength: 200,
    );
    if (name != null) await c.renameItem(item, name);
  }

  Future<void> _moveSelection() async {
    if (!c.hasSelection) return;
    final excluded = <String>{};
    for (final id in c.selectedFolders) {
      excluded.addAll(c.descendantFolderIds(id, includeSelf: true));
    }
    final choice = await showFolderPickerDialog(
      context,
      controller: c,
      title: '移动到',
      subtitle: '${c.selectionCount} 项',
      excludeFolderIds: excluded,
    );
    if (choice == null || choice.cancelled) return;
    await c.moveNodes(
      folderIds: c.selectedFolders,
      entryIds: c.selectedEntries,
      targetFolderId: choice.folderId,
    );
  }

  Future<void> _createShortcut(LibraryItem item) async {
    final choice = await showFolderPickerDialog(
      context,
      controller: c,
      title: '创建快捷方式到',
      subtitle: item.displayName,
      confirmLabel: '添加快捷方式',
    );
    if (choice == null || choice.cancelled) return;
    await c.createShortcut(item.document.id, folderId: choice.folderId);
  }

  Future<void> _tagSelection() async {
    final items = c.allSelectedItems;
    if (items.isEmpty) return;
    final documents = {for (final item in items) item.document.id};
    if (documents.length == 1) {
      final document = items.first.document;
      final tags = await showTagPickerDialog(
        context,
        controller: c,
        document: document,
      );
      if (tags != null) await c.assignTags(document.id, tags);
      return;
    }
    final first = items.first.document;
    final tags = await showTagPickerDialog(
      context,
      controller: c,
      document: first,
    );
    if (tags == null) return;
    for (final id in documents) {
      final current = {
        ...?c.tagIdsByDocument[id],
      };
      await c.assignTags(id, {...current, ...tags});
    }
  }

  Future<void> _toggleStarSelection() async {
    final items = c.allSelectedItems;
    final documents = {
      for (final item in items) item.document.id: item.document,
    };
    if (documents.isEmpty) return;
    final allStarred = documents.values.every((document) => document.starred);
    for (final document in documents.values) {
      if (document.starred != !allStarred) {
        await c.toggleStar(document.id);
      }
    }
  }

  Future<void> _trashSelection() async {
    if (!c.hasSelection) return;
    final entries = c.allSelectedItems;
    final documents = entries.map((item) => item.document.id).toSet();
    final shortcuts = entries.where((item) => item.isShortcut).length;
    final folders = c.selectedFolders.length;
    if (folders == 1 && entries.isEmpty) {
      final folder = c.folderById(c.selectedFolders.first);
      if (folder != null) {
        final ids = c.descendantFolderIds(folder.id, includeSelf: true);
        final folderEntries = c.repository.activeEntriesInFolders(ids);
        final confirmed = await showTrashImpactDialog(
          context,
          title: '移入回收站？',
          targetLabel: folder.name,
          entries: folderEntries.length,
          folders: ids.length,
          documents: folderEntries
              .where((entry) => !entry.isShortcut)
              .map((entry) => entry.documentId)
              .toSet()
              .length,
          shortcuts: folderEntries.where((entry) => entry.isShortcut).length,
        );
        if (confirmed) await c.trashFolder(folder.id);
        return;
      }
    }
    final confirmed = await showTrashImpactDialog(
      context,
      title: '移入回收站？',
      targetLabel: '已选择 ${c.selectionCount} 项',
      entries: entries.length,
      folders: folders,
      documents: documents.length,
      shortcuts: shortcuts,
    );
    if (confirmed) await c.trashSelection();
  }

  Future<void> _deleteEntry(LibraryItem item) async {
    if (item.isShortcut) {
      final confirmed = await showLibraryConfirmDialog(
        context,
        title: '删除这个快捷方式？',
        subtitle: item.displayName,
        message: '只删除这个入口；原资料、笔记和其他入口都不受影响。',
        confirmLabel: '删除快捷方式',
      );
      if (confirmed) await c.removeEntry(item.entry.id);
      return;
    }
    final confirmed = await showLibraryConfirmDialog(
      context,
      title: '移入回收站？',
      subtitle: item.displayName,
      message: '资料会移入回收站，可以恢复。外部原文件不会被删除。',
      confirmLabel: '移入回收站',
    );
    if (confirmed) await c.trashDocument(item.document.id);
  }

  Future<void> _pickFiles() => pickAndImportFiles(context, c);

  Future<void> _pickFolder() => pickAndImportFolder(context, c);

  Future<void> _showFilterSheet() async {
    final formats = <String>{
      for (final document in c.store.getDocuments())
        if (document.format.isNotEmpty) document.format.toLowerCase(),
    }.toList()..sort();
    final result = await showModalBottomSheet<LibraryFilter>(
      context: context,
      showDragHandle: true,
      builder: (context) => _FilterSheet(
        initial: c.filter,
        formats: formats,
        tags: c.tags,
      ),
    );
    if (result != null) c.setFilter(result);
  }

  bool _noticeOffersUndo(String notice) =>
      notice.startsWith('已移动') ||
      notice.startsWith('已移入回收站') ||
      notice.startsWith('已删除这个快捷方式') ||
      notice.contains('重命名为');

  void _showPendingMessages() {
    final error = c.takeError();
    final notice = c.takeNotice();
    if (error == null && notice == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      if (error != null) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(error),
            backgroundColor: context.colors.danger,
          ),
        );
      } else if (notice != null) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(notice),
            action: c.undo == null || !_noticeOffersUndo(notice)
                ? null
                : SnackBarAction(
                    label: '撤销',
                    onPressed: () => c.undoLast(),
                  ),
          ),
        );
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final content = Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: AnimatedBuilder(
        animation: c,
        builder: (context, _) {
          _showPendingMessages();
          return LayoutBuilder(
            builder: (context, constraints) {
              final maxWidth = constraints.maxWidth;
              final compact = maxWidth < 760;
              final isPhoneShell = !widget.showSidebarToggle;
              final sidebarOpen = widget.showSidebarToggle && !widget.sidebarCollapsed;
              final chromeReserved =
                  (widget.showWindowChrome ? 138.0 : 0.0) +
                  (!sidebarOpen ? 108.0 : 0.0);
              final innerWidth = (maxWidth - chromeReserved).clamp(0.0, maxWidth);
              final useInlineSearchBar = isPhoneShell || innerWidth < 430;
              final showInlineSearch =
                  widget.searchController != null &&
                  useInlineSearchBar &&
                  (_inlineSearchOpen || widget.query.trim().isNotEmpty);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _unifiedHeader(
                    context,
                    innerWidth: innerWidth,
                    isPhoneShell: isPhoneShell,
                    useInlineSearchBar: useInlineSearchBar,
                  ),
                  AnimatedSize(
                    duration: context.motion(Motion.fast),
                    curve: Motion.curve,
                    alignment: Alignment.topCenter,
                    child: showInlineSearch
                        ? _inlineSearchBar()
                        : const SizedBox.shrink(),
                  ),
                  if (widget.topBanner != null) widget.topBanner!,
                  if (c.activeSmartFolder != null) _smartBanner(compact),
                  if (!c.filter.isEmpty && c.activeSmartFolder == null)
                    _activeFilterBar(compact),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: context.motion(Motion.base),
                      switchInCurve: Motion.curve,
                      switchOutCurve: Curves.easeIn,
                      layoutBuilder: (currentChild, previousChildren) => Stack(
                        fit: StackFit.expand,
                        children: [...previousChildren, ?currentChild],
                      ),
                      child: c.isTrashView
                          ? KeyedSubtree(
                              key: const ValueKey('library-trash'),
                              child: _trashView(compact),
                            )
                          : Row(
                              key: const ValueKey('library-results'),
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(
                                  child: Stack(
                                    children: [
                                      Positioned.fill(child: _results(compact)),
                                      Positioned(
                                        left: 16,
                                        right: 16,
                                        bottom: 16,
                                        child: IgnorePointer(
                                          ignoring: !c.hasSelection,
                                          child: LayoutBuilder(
                                            builder: (context, dockBox) => Align(
                                              alignment: Alignment.bottomCenter,
                                              child: AnimatedSwitcher(
                                                duration: context.motion(
                                                  Motion.base,
                                                ),
                                                switchInCurve: Motion.curve,
                                                switchOutCurve: Curves.easeIn,
                                                transitionBuilder:
                                                    (child, animation) {
                                                      final curved =
                                                          CurvedAnimation(
                                                            parent: animation,
                                                            curve: Motion.curve,
                                                          );
                                                      return FadeTransition(
                                                        opacity: curved,
                                                        child: SlideTransition(
                                                          position: Tween<Offset>(
                                                            begin: const Offset(
                                                              0,
                                                              0.18,
                                                            ),
                                                            end: Offset.zero,
                                                          ).animate(curved),
                                                          child: ScaleTransition(
                                                            scale:
                                                                Tween<double>(
                                                                  begin: 0.96,
                                                                  end: 1.0,
                                                                ).animate(
                                                                  curved,
                                                                ),
                                                            child: child,
                                                          ),
                                                        ),
                                                      );
                                                    },
                                                child: c.hasSelection
                                                    ? _selectionBar(
                                                        compact ||
                                                            dockBox.maxWidth <
                                                                560,
                                                      )
                                                    : const SizedBox.shrink(
                                                        key: ValueKey(
                                                          'selection-bar-empty',
                                                        ),
                                                      ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                AnimatedSwitcher(
                                  duration: context.motion(Motion.base),
                                  switchInCurve: Motion.curve,
                                  switchOutCurve: Curves.easeIn,
                                  layoutBuilder:
                                      (currentChild, previousChildren) => Stack(
                                        fit: StackFit.passthrough,
                                        alignment: Alignment.centerRight,
                                        children: [
                                          ...previousChildren,
                                          ?currentChild,
                                        ],
                                      ),
                                  transitionBuilder: (child, animation) {
                                    final curved = CurvedAnimation(
                                      parent: animation,
                                      curve: Motion.curve,
                                    );
                                    return FadeTransition(
                                      opacity: curved,
                                      child: SizeTransition(
                                        axis: Axis.horizontal,
                                        sizeFactor: curved,
                                        alignment: Alignment.centerRight,
                                        child: child,
                                      ),
                                    );
                                  },
                                  child: (!compact && c.view.showDetails)
                                      ? KeyedSubtree(
                                          key: const ValueKey(
                                            'library-details',
                                          ),
                                          child: _detailsPanel(),
                                        )
                                      : const SizedBox.shrink(
                                          key: ValueKey('library-no-details'),
                                        ),
                                ),
                              ],
                            ),
                    ),
                  ),
                  AnimatedSize(
                    duration: context.motion(Motion.fast),
                    curve: Motion.curve,
                    alignment: Alignment.bottomCenter,
                    child: c.queue.batches.isNotEmpty
                        ? _queueBar(compact)
                        : const SizedBox.shrink(),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
    return Stack(
      children: [
        Positioned.fill(
          child: DropTarget(
            enable: c.canImport,
            onDragEntered: (_) {
              if (!_externalDragActive) {
                setState(() => _externalDragActive = true);
              }
            },
            onDragExited: (_) {
              if (_externalDragActive) {
                setState(() => _externalDragActive = false);
              }
            },
            onDragDone: _handleExternalDrop,
            child: content,
          ),
        ),
        if (_externalDragActive && c.canImport)
          Positioned(
            left: 16,
            right: 16,
            top: 12,
            child: IgnorePointer(
              child: _ExternalDropHint(target: c.importTargetLabel),
            ),
          ),
      ],
    );
  }

  void _handleExternalDrop(DropDoneDetails details) {
    if (_externalDragActive && mounted) {
      setState(() => _externalDragActive = false);
    }
    final paths = droppedFilePaths(details.files);
    if (paths.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('拖入的项目没有可读取的本地路径；请改用“选择文件/文件夹”。'),
        ),
      );
      return;
    }
    unawaited(c.importPaths(paths));
  }

  Future<void> _saveSmartFolder() async {
    if (!c.hasSearchConditions || c.activeSmartFolder != null) return;
    final suggested = c.query.trim().isNotEmpty
        ? c.query.trim()
        : '筛选资料';
    final name = await showLibraryTextDialog(
      context,
      title: '保存为智能文件夹',
      subtitle: '保存当前搜索词与筛选条件；不复制资料，结果会随资料更新。',
      label: '名称',
      initial: suggested,
      hint: '例如：未读且考试重点',
      confirmLabel: '保存',
      maxLength: 60,
    );
    if (name == null || !mounted) return;
    await c.saveCurrentAsSmartFolder(name);
  }

  Widget _smartBanner(bool compact) {
    final folder = c.activeSmartFolder;
    if (folder == null) return const SizedBox.shrink();
    final colors = context.colors;
    return Container(
      padding: EdgeInsets.fromLTRB(compact ? 12 : 20, 6, compact ? 4 : 12, 6),
      decoration: BoxDecoration(
        color: colors.tint.withValues(alpha: .55),
        border: Border(bottom: BorderSide(color: colors.outline)),
      ),
      child: Row(
        children: [
          QIcon(QIcons.filter, size: IconSizes.sm, color: colors.inkMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '智能文件夹 · ${folder.name} · ${folder.conditionLabel}（自动更新，不可拖入）',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.texts.bodySmall!.copyWith(fontSize: 12),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 28),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              textStyle: const TextStyle(fontSize: 12),
            ),
            onPressed: c.clearSmartFolder,
            child: const Text('退出'),
          ),
        ],
      ),
    );
  }

  Widget _activeFilterBar(bool compact) {
    final filter = c.filter;
    if (filter.isEmpty || c.activeSmartFolder != null) {
      return const SizedBox.shrink();
    }
    final colors = context.colors;
    final chips = <Widget>[];
    if (filter.starredOnly) {
      chips.add(
        _filterChip(
          label: '仅星标',
          onDeleted: () => c.setFilter(filter.copyWith(starredOnly: false)),
        ),
      );
    }
    if (filter.unreadOnly) {
      chips.add(
        _filterChip(
          label: '仅未读',
          onDeleted: () => c.setFilter(filter.copyWith(unreadOnly: false)),
        ),
      );
    }
    if (filter.processingOnly) {
      chips.add(
        _filterChip(
          label: '待处理',
          onDeleted: () => c.setFilter(filter.copyWith(processingOnly: false)),
        ),
      );
    }
    for (final format in filter.formats) {
      chips.add(
        _filterChip(
          label: '格式: ${formatLabel(format)}',
          onDeleted: () => c.setFilter(filter.toggleFormat(format)),
        ),
      );
    }
    for (final tagId in filter.tagIds) {
      final tagName = c.tags
          .where((tag) => tag.id == tagId)
          .map((tag) => tag.name)
          .firstOrNull;
      if (tagName == null) continue;
      chips.add(
        _filterChip(
          label: '标签: $tagName',
          onDeleted: () => c.setFilter(filter.toggleTag(tagId)),
        ),
      );
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.fromLTRB(compact ? 12 : 20, 6, compact ? 8 : 14, 6),
      decoration: BoxDecoration(
        color: colors.surfaceRaised.withValues(alpha: .75),
        border: Border(bottom: BorderSide(color: colors.outline)),
      ),
      child: Row(
        children: [
          QIcon(QIcons.filter, size: 13, color: colors.inkMuted),
          const SizedBox(width: 6),
          Text(
            '当前筛选：',
            style: context.texts.bodySmall!.copyWith(
              fontSize: 12,
              color: colors.inkMuted,
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < chips.length; i++) ...[
                    if (i > 0) const SizedBox(width: 6),
                    chips[i],
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 26),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              textStyle: const TextStyle(fontSize: 12),
            ),
            onPressed: () => c.setFilter(const LibraryFilter()),
            child: const Text('清空筛选'),
          ),
        ],
      ),
    );
  }

  Widget _filterChip({required String label, required VoidCallback onDeleted}) {
    final colors = context.colors;
    return Container(
      height: 24,
      padding: const EdgeInsets.only(left: 8, right: 4),
      decoration: BoxDecoration(
        color: colors.tint,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: colors.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: context.texts.bodySmall!.copyWith(
              fontSize: 12,
              color: colors.ink,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 4),
          InkWell(
            onTap: onDeleted,
            borderRadius: BorderRadius.circular(Radii.sm),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: QIcon(QIcons.close, size: 12, color: colors.inkMuted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _unifiedHeader(
    BuildContext context, {
    required double innerWidth,
    required bool isPhoneShell,
    required bool useInlineSearchBar,
  }) {
    final colors = context.colors;
    final hasSearchConditions =
        c.hasSearchConditions && c.activeSmartFolder == null;
    final showScopeInBar =
        !useInlineSearchBar &&
        c.query.trim().isNotEmpty &&
        c.activeSmartFolder == null;
    final collapseSecondary = !isPhoneShell && innerWidth < 580;
    final compactImport = isPhoneShell || innerWidth < 500;
    final searchWidth = innerWidth >= 860
        ? 208.0
        : innerWidth >= 680
        ? 176.0
        : innerWidth >= 560
        ? 148.0
        : 124.0;

    final trailing = <Widget>[];
    if (isPhoneShell) {
      if (widget.searchController != null) {
        trailing.add(
          _headerIconButton(
            tooltip: '搜索',
            onPressed: () {
              setState(() => _inlineSearchOpen = !_inlineSearchOpen);
            },
            icon: QIcon(
              QIcons.search,
              size: IconSizes.md,
              color: (_inlineSearchOpen || widget.query.isNotEmpty)
                  ? colors.primary
                  : colors.inkMuted,
            ),
          ),
        );
        trailing.add(const SizedBox(width: 2));
      }
      trailing.add(_importButton(compact: true));
      trailing.add(const SizedBox(width: 2));
      trailing.add(
        _moreToolsMenu(
          tooltip: '更多',
          includeSortAndFilter: true,
          includePrimaryTools: true,
          includeSmartSave: hasSearchConditions,
        ),
      );
    } else {
      if (widget.searchController != null) {
        if (useInlineSearchBar) {
          trailing.add(
            _headerIconButton(
              tooltip: '搜索',
              onPressed: () {
                setState(() => _inlineSearchOpen = !_inlineSearchOpen);
              },
              icon: QIcon(
                QIcons.search,
                size: IconSizes.md,
                color: (_inlineSearchOpen || widget.query.isNotEmpty)
                    ? colors.primary
                    : colors.inkMuted,
              ),
            ),
          );
          trailing.add(const SizedBox(width: 2));
        } else {
          trailing.add(
            _LibrarySearchField(
              width: searchWidth,
              controller: widget.searchController!,
              onChanged: widget.onSearchChanged ?? (_) {},
              onClear: widget.onClearSearch,
            ),
          );
          if (showScopeInBar) {
            trailing.add(const SizedBox(width: 6));
            trailing.add(_scopeButton());
          }
        }
      }
      if (hasSearchConditions && !useInlineSearchBar) {
        trailing.add(const SizedBox(width: 6));
        if (innerWidth >= 700) {
          trailing.add(_saveSmartFolderPill());
        } else {
          trailing.add(
            _headerIconButton(
              tooltip: '保存为智能文件夹',
              onPressed: _saveSmartFolder,
              icon: QIcon(QIcons.star, size: IconSizes.sm, color: colors.ink),
            ),
          );
        }
      }
      trailing.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Container(width: 1, height: 16, color: colors.outline),
        ),
      );
      if (!collapseSecondary) {
        trailing.add(
          _headerIconButton(
            tooltip: '新建文件夹（Ctrl+Shift+N）',
            onPressed: c.isTrashView ? null : _newFolder,
            icon: const QIcon(QIcons.folder, size: IconSizes.md),
          ),
        );
      }
      trailing.add(_sortButton());
      trailing.add(_filterButton());
      if (!collapseSecondary) {
        if (c.view.layout == LibraryLayout.list) {
          trailing.add(_columnsButton());
        }
        trailing.add(
          _headerIconButton(
            tooltip: c.view.layout == LibraryLayout.list ? '切换为网格' : '切换为列表',
            onPressed: () => c.setLayout(
              c.view.layout == LibraryLayout.list
                  ? LibraryLayout.grid
                  : LibraryLayout.list,
            ),
            icon: QIcon(
              c.view.layout == LibraryLayout.list ? QIcons.grid : QIcons.list,
              size: IconSizes.md,
            ),
          ),
        );
        trailing.add(
          _headerIconButton(
            tooltip: c.view.showDetails ? '收起详情' : '显示详情',
            onPressed: c.toggleDetails,
            icon: QIcon(
              QIcons.info,
              size: IconSizes.md,
              color: c.view.showDetails ? colors.primary : colors.inkMuted,
              active: c.view.showDetails,
            ),
          ),
        );
      } else {
        trailing.add(
          _moreToolsMenu(
            tooltip: '更多工具',
            includeSortAndFilter: false,
            includePrimaryTools: true,
            includeSmartSave: hasSearchConditions && useInlineSearchBar,
          ),
        );
      }
      if (c.canImport) {
        trailing.add(const SizedBox(width: 6));
        trailing.add(_importButton(compact: compactImport));
      }
    }

    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.35,
      child: UnifiedHeader(
        title: '书库',
        subtitle: '',
        sidebarCollapsed: widget.sidebarCollapsed,
        onToggleSidebar: widget.onToggleSidebar ?? () {},
        onOpenSettings: widget.onOpenSettings,
        showSidebarToggle: widget.showSidebarToggle,
        showSubtitle: false,
        showWindowChrome: widget.showWindowChrome,
        compact: isPhoneShell,
        leading: isPhoneShell
            ? Builder(
                builder: (context) => _headerIconButton(
                  tooltip: '文件夹',
                  onPressed: () => Scaffold.of(context).openDrawer(),
                  icon: const QIcon(QIcons.folderOpen, size: IconSizes.md),
                ),
              )
            : null,
        titleContent: _headerBreadcrumb(
          isPhoneShell: isPhoneShell,
          showCount: !isPhoneShell && innerWidth >= 540,
        ),
        trailing: trailing,
      ),
    );
  }

  Widget _headerIconButton({
    required String tooltip,
    required VoidCallback? onPressed,
    required Widget icon,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
      padding: EdgeInsets.zero,
      icon: icon,
    );
  }

  Widget _saveSmartFolderPill() {
    final colors = context.colors;
    return Tooltip(
      message: '保存为智能文件夹',
      child: InkWell(
        onTap: _saveSmartFolder,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: colors.tint,
            borderRadius: BorderRadius.circular(Radii.sm),
            border: Border.all(color: colors.outlineStrong),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              QIcon(QIcons.star, size: 13, color: colors.ink),
              const SizedBox(width: 5),
              Text(
                '存为智能文件夹',
                style: context.texts.bodySmall!.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: colors.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _columnsButton() {
    return PopupMenuButton<String>(
      tooltip: '显示列',
      padding: EdgeInsets.zero,
      onSelected: c.toggleColumn,
      itemBuilder: (context) => [
        CheckedPopupMenuItem(
          value: 'tags',
          checked: c.view.columns.tags,
          child: const Text('标签'),
        ),
        CheckedPopupMenuItem(
          value: 'format',
          checked: c.view.columns.format,
          child: const Text('格式'),
        ),
        CheckedPopupMenuItem(
          value: 'status',
          checked: c.view.columns.status,
          child: const Text('状态'),
        ),
        CheckedPopupMenuItem(
          value: 'progress',
          checked: c.view.columns.progress,
          child: const Text('阅读进度'),
        ),
      ],
      child: const SizedBox(
        width: 30,
        height: 30,
        child: Center(child: QIcon(QIcons.columns, size: IconSizes.md)),
      ),
    );
  }

  Widget _moreToolsMenu({
    required String tooltip,
    required bool includeSortAndFilter,
    required bool includePrimaryTools,
    required bool includeSmartSave,
  }) {
    return PopupMenuButton<String>(
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      onSelected: (value) {
        switch (value) {
          case 'folder':
            _newFolder();
          case 'smart':
            _saveSmartFolder();
          case 'sort':
            _showSortSheet();
          case 'filter':
            _showFilterSheet();
          case 'layout':
            c.setLayout(
              c.view.layout == LibraryLayout.list
                  ? LibraryLayout.grid
                  : LibraryLayout.list,
            );
          case 'details':
            c.toggleDetails();
        }
      },
      itemBuilder: (context) => [
        if (includePrimaryTools && !c.isTrashView)
          const PopupMenuItem(value: 'folder', child: Text('新建文件夹')),
        if (includeSmartSave)
          const PopupMenuItem(value: 'smart', child: Text('保存为智能文件夹')),
        if (includeSortAndFilter) ...[
          const PopupMenuItem(value: 'sort', child: Text('排序…')),
          const PopupMenuItem(value: 'filter', child: Text('筛选…')),
        ],
        if (includePrimaryTools) ...[
          const PopupMenuItem(value: 'layout', child: Text('切换列表或网格')),
          PopupMenuItem(
            value: 'details',
            child: Text(c.view.showDetails ? '收起详情' : '显示详情'),
          ),
        ],
      ],
      child: const SizedBox(
        width: 30,
        height: 30,
        child: Center(child: QIcon(QIcons.more, size: IconSizes.md)),
      ),
    );
  }

  Widget _inlineSearchBar() {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.outline)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _LibrarySearchField(
              width: double.infinity,
              controller: widget.searchController!,
              onChanged: widget.onSearchChanged ?? (_) {},
              onClear: () {
                widget.onClearSearch();
                setState(() => _inlineSearchOpen = false);
              },
            ),
          ),
          if (c.query.trim().isNotEmpty && c.activeSmartFolder == null) ...[
            const SizedBox(width: 6),
            _scopeButton(),
          ],
          if (c.hasSearchConditions && c.activeSmartFolder == null) ...[
            const SizedBox(width: 6),
            _headerIconButton(
              tooltip: '保存为智能文件夹',
              onPressed: _saveSmartFolder,
              icon: QIcon(QIcons.star, size: IconSizes.sm, color: colors.ink),
            ),
          ],
        ],
      ),
    );
  }

  Widget _headerBreadcrumb({
    required bool isPhoneShell,
    required bool showCount,
  }) {
    final colors = context.colors;
    final scope = c.view.scope;
    final scopeLabel = switch (scope) {
      LibraryScope.recent => '最近打开',
      LibraryScope.unfiled => '未归档',
      LibraryScope.starred => '星标',
      LibraryScope.trash => '回收站',
      LibraryScope.smart => c.activeSmartFolder?.name ?? '智能文件夹',
      _ => '全部资料',
    };

    if (isPhoneShell) {
      final activeLabel = scope == LibraryScope.folder && c.breadcrumb.isNotEmpty
          ? c.breadcrumb.last.name
          : scopeLabel;
      if (scope == LibraryScope.all) {
        return Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '书库',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.texts.bodyMedium!.copyWith(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              height: 1.25,
              color: colors.ink,
            ),
          ),
        );
      }
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _titleRootLink(compact: true, onTap: () => c.showAll()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5),
            child: Text(
              '/',
              style: context.texts.bodySmall!.copyWith(
                fontSize: 12,
                color: colors.inkMuted.withValues(alpha: 0.6),
              ),
            ),
          ),
          Flexible(
            child: Text(
              activeLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.texts.bodyMedium!.copyWith(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                color: colors.ink,
              ),
            ),
          ),
        ],
      );
    }

    final crumbs = <Widget>[
      _titleRootLink(
        compact: false,
        onTap: scope == LibraryScope.all ? null : () => c.showAll(),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Text(
          '/',
          style: context.texts.bodySmall!.copyWith(
            fontSize: 13,
            color: colors.inkMuted.withValues(alpha: 0.55),
          ),
        ),
      ),
    ];

    if (scope == LibraryScope.folder) {
      crumbs.add(_crumb('全部资料', () => c.showAll()));
      for (var i = 0; i < c.breadcrumb.length; i++) {
        final folder = c.breadcrumb[i];
        final isLast = i == c.breadcrumb.length - 1;
        crumbs.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: QIcon(
              QIcons.chevronRight,
              size: 10,
              color: colors.inkMuted,
            ),
          ),
        );
        crumbs.add(
          _FolderCrumbTarget(
            controller: c,
            folderId: folder.id,
            child: _crumb(
              folder.name,
              isLast ? null : () => c.openFolder(folder.id),
            ),
          ),
        );
      }
    } else if (scope == LibraryScope.all) {
      crumbs.add(_crumb('全部资料', null, activeOpacity: 0.82));
    } else {
      crumbs.add(_crumb(scopeLabel, null));
    }

    if (showCount) {
      final folderCount = c.childFolders.length;
      crumbs.add(const SizedBox(width: 8));
      crumbs.add(
        Text(
          scope == LibraryScope.folder
              ? '${c.items.length} 份资料'
                    '${folderCount > 0 ? ' · $folderCount 个文件夹' : ''}'
              : '${c.items.length} 项',
          style: context.texts.bodySmall!.copyWith(
            fontSize: 12,
            color: colors.inkMuted,
            fontFeatures: AppNumerals.tabular,
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(mainAxisSize: MainAxisSize.min, children: crumbs),
    );
  }

  Widget _titleRootLink({required bool compact, VoidCallback? onTap}) {
    final colors = context.colors;
    final style = context.texts.bodyMedium!.copyWith(
      fontSize: compact ? 15 : 16.5,
      fontWeight: FontWeight.w600,
      height: 1.25,
      color: onTap == null ? colors.ink : colors.inkMuted,
    );
    if (onTap == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text('书库', style: style),
      );
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Text('书库', style: style),
      ),
    );
  }

  Widget _crumb(
    String label,
    VoidCallback? onTap, {
    double activeOpacity = 1.0,
  }) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        child: Text(
          label,
          style: context.texts.bodyMedium!.copyWith(
            fontSize: 13.5,
            fontWeight: onTap == null ? FontWeight.w600 : FontWeight.w400,
            color: onTap == null
                ? colors.ink.withValues(alpha: activeOpacity)
                : colors.inkMuted,
          ),
        ),
      ),
    );
  }

  Widget _scopeButton() {
    final colors = context.colors;
    return PopupMenuButton<LibrarySearchScope>(
      tooltip: '搜索范围',
      padding: EdgeInsets.zero,
      onSelected: c.setSearchScope,
      itemBuilder: (context) => [
        for (final scope in LibrarySearchScope.values)
          CheckedPopupMenuItem(
            value: scope,
            checked: c.searchScope == scope,
            child: Text(scope.label),
          ),
      ],
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          border: Border.all(color: colors.outlineStrong),
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            QIcon(
              c.searchScope == LibrarySearchScope.all
                  ? QIcons.library
                  : QIcons.folderOpen,
              size: 12,
              color: colors.inkMuted,
            ),
            const SizedBox(width: 5),
            Text(
              c.searchScope.label,
              style: context.texts.bodySmall!.copyWith(fontSize: 11.5),
            ),
            QIcon(
              QIcons.chevronDown,
              size: 10,
              color: colors.inkMuted,
            ),
          ],
        ),
      ),
    );
  }

  Widget _sortButton() {
    return PopupMenuButton<String>(
      tooltip: '排序',
      padding: EdgeInsets.zero,
      onSelected: (value) {
        if (value == 'direction') {
          c.toggleSortDirection();
          return;
        }
        c.setSort(LibrarySortField.values.byName(value));
      },
      itemBuilder: (context) => [
        for (final field in LibrarySortField.values)
          CheckedPopupMenuItem(
            value: field.name,
            checked: c.view.sortField == field,
            child: Text(field.label),
          ),
        const PopupMenuDivider(),
        CheckedPopupMenuItem(
          value: 'direction',
          checked: false,
          child: Text(c.view.ascending ? '升序（点击改为降序）' : '降序（点击改为升序）'),
        ),
      ],
      child: const SizedBox(
        width: 30,
        height: 30,
        child: Center(child: QIcon(QIcons.sort, size: IconSizes.md)),
      ),
    );
  }

  Widget _filterButton() {
    final count = c.filter.activeCount;
    return _headerIconButton(
      tooltip: '筛选',
      onPressed: _showFilterSheet,
      icon: Badge(
        isLabelVisible: count > 0,
        label: Text('$count'),
        child: const QIcon(QIcons.filter, size: IconSizes.md),
      ),
    );
  }

  Widget _importButton({required bool compact}) {
    if (!c.canImport) {
      return const SizedBox.shrink();
    }
    final colors = context.colors;
    return PopupMenuButton<String>(
      tooltip: '导入到 ${c.importTargetLabel}',
      onSelected: (value) {
        if (value == 'files') {
          _pickFiles();
        } else if (value == 'folder') {
          _pickFolder();
        } else if (value == 'queue') {
          showImportQueueDialog(context, controller: c);
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'files',
          child: Row(
            children: [
              const QIcon(QIcons.page, size: IconSizes.sm),
              const SizedBox(width: 8),
              const Text('选择文件'),
            ],
          ),
        ),
        const PopupMenuItem(
          value: 'folder',
          child: Row(
            children: [
              QIcon(QIcons.folderOpen, size: IconSizes.sm),
              SizedBox(width: 8),
              Text('选择文件夹'),
            ],
          ),
        ),
        if (c.queue.batches.isNotEmpty)
          const PopupMenuItem(
            value: 'queue',
            child: Row(
              children: [
                QIcon(QIcons.download, size: IconSizes.sm),
                SizedBox(width: 8),
                Text('查看导入队列'),
              ],
            ),
          ),
      ],
      child: Container(
        width: compact ? 30 : null,
        height: compact ? 30 : 32,
        padding: compact
            ? EdgeInsets.zero
            : const EdgeInsets.symmetric(horizontal: 11),
        alignment: compact ? Alignment.center : null,
        decoration: BoxDecoration(
          color: colors.primary,
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            QIcon(QIcons.add, size: IconSizes.sm, color: colors.onPrimary),
            if (!compact) ...[
              const SizedBox(width: 5),
              Text(
                '导入',
                style: context.texts.bodySmall!.copyWith(
                  fontSize: 12.5,
                  color: colors.onPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Results
  // ---------------------------------------------------------------------------

  Widget _results(bool compact) {
    final items = c.items;
    final childFolders = _visibleFolders();
    final hits = c.fullTextHits;
    if (c.counts.all == 0 && c.folders.isEmpty && c.query.trim().isEmpty) {
      return _emptyLibrary(compact);
    }
    if (c.activeSmartFolder != null &&
        items.isEmpty &&
        hits.isEmpty) {
      return Center(
        child: EmptyState(
          compact: true,
          icon: QIcons.filter,
          title: '这个智能文件夹暂时没有匹配的资料',
          message: '保存的是查询条件，结果会随资料更新。',
          action: TextButton(
            onPressed: c.clearSmartFolder,
            child: const Text('退出智能文件夹'),
          ),
        ),
      );
    }
    if (items.isEmpty &&
        childFolders.isEmpty &&
        hits.isEmpty &&
        c.query.trim().isEmpty) {
      return _emptyFolder(compact);
    }
    if (items.isEmpty &&
        childFolders.isEmpty &&
        hits.isEmpty &&
        c.query.trim().isNotEmpty) {
      return Center(
        child: EmptyState(
          compact: true,
          icon: QIcons.searchEmpty,
          title: '没有匹配结果',
          message: '可以换一个词，或切换搜索范围。',
          action: TextButton(
            onPressed: () {
              widget.onClearSearch();
              c.setQuery('');
            },
            child: const Text('清除搜索'),
          ),
        ),
      );
    }
    final showFolderTiles = childFolders.isNotEmpty;
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        if (showFolderTiles)
          SliverToBoxAdapter(
            child: _folderSection(childFolders, compact),
          ),
        if (items.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(compact ? 12 : 20, 12, 16, 6),
              child: Row(
                children: [
                  Text(
                    c.query.trim().isEmpty ? '资料' : '资料 · ${items.length}',
                    style: context.texts.bodySmall!.copyWith(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  if (c.view.sortField == LibrarySortField.manual)
                    Text(
                      '可拖动排序',
                      style: context.texts.bodySmall!.copyWith(fontSize: 11),
                    ),
                ],
              ),
            ),
          ),
        if (items.isNotEmpty &&
            c.view.layout == LibraryLayout.list &&
            !compact)
          SliverToBoxAdapter(child: _listHeader()),
        if (items.isNotEmpty)
          c.view.layout == LibraryLayout.list
              ? SliverList.builder(
                  itemCount: items.length,
                  itemBuilder: (context, index) =>
                      _listRow(items[index], compact),
                )
              : SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 10 : 16,
                    4,
                    compact ? 10 : 16,
                    16,
                  ),
                  sliver: SliverGrid.builder(
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: compact ? 170 : 210,
                      mainAxisExtent: compact ? 116 : 136,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 10,
                    ),
                    itemCount: items.length,
                    itemBuilder: (context, index) =>
                        _gridCard(items[index], compact),
                  ),
                ),
        if (hits.isNotEmpty) _fullTextSection(hits, compact),
        SliverToBoxAdapter(
          child: SizedBox(height: c.hasSelection ? 84 : 28),
        ),
      ],
    );
  }

  List<LibraryFolder> _visibleFolders() {
    if (c.isTrashView) return const [];
    if (c.query.trim().isNotEmpty) return const [];
    if (c.view.scope == LibraryScope.all) return c.childrenOf(null);
    if (c.view.scope == LibraryScope.folder) return c.childFolders;
    if (c.view.scope == LibraryScope.unfiled) return c.childrenOf(null);
    return const [];
  }

  Future<void> _editFolderStyle(LibraryFolder folder) async {
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

  Widget _folderSection(List<LibraryFolder> folders, bool compact) {
    return Padding(
      padding: EdgeInsets.fromLTRB(compact ? 10 : 16, 12, compact ? 10 : 16, 2),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final folder in folders)
            _FolderTile(
              key: ValueKey('folder-tile-${folder.id}'),
              controller: c,
              folder: folder,
              count: c.counts.forFolder(folder.id),
              colorValue: effectiveFolderColor(c, folder.id),
              onOpen: () => c.openFolder(folder.id),
              onStyle: () => _editFolderStyle(folder),
            ),
          if (c.view.scope == LibraryScope.folder)
            _NewFolderTile(onTap: () => _newFolder()),
        ],
      ),
    );
  }

  Widget _fullTextSection(List<LibrarySearchHit> hits, bool compact) {
    final colors = context.colors;
    final incomplete = hits.any((hit) {
      final progress = c.progressFor(hit.document.id);
      return progress.hasPages && !progress.complete;
    });
    return SliverList.builder(
      itemCount: hits.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: EdgeInsets.fromLTRB(compact ? 12 : 20, 20, 16, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '正文片段 · ${hits.length}',
                  style: context.texts.bodySmall!.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (incomplete)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      '部分页面尚未完成 OCR，正文搜索结果可能不完整。',
                      style: context.texts.bodySmall!.copyWith(
                        fontSize: 11,
                        color: colors.inkMuted,
                        height: 1.45,
                      ),
                    ),
                  ),
              ],
            ),
          );
        }
        final hit = hits[index - 1];
        return InkWell(
          onTap: () async {
            await widget.onOpenDocument(hit.document);
            if (hit.page != null) await widget.study.goToPage(hit.page!);
          },
          child: Container(
            padding: EdgeInsets.fromLTRB(compact ? 12 : 20, 10, 16, 10),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: colors.outline)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    AppBadge(label: '第 ${hit.page ?? 1} 页', dense: true),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        hit.document.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.texts.bodySmall!.copyWith(
                          fontSize: 12,
                          color: colors.inkMuted,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  hit.snippet ?? '',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.bodyMedium!.copyWith(
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _listHeader() {
    final columns = c.view.columns;
    final colors = context.colors;
    TextStyle style({bool active = false}) =>
        context.texts.bodySmall!.copyWith(
          fontSize: 12,
          color: active ? colors.ink : colors.inkMuted,
          fontWeight: active ? FontWeight.w600 : FontWeight.w500,
        );

    Widget sortableHeader(String label, LibrarySortField field) {
      final active = c.view.sortField == field;
      return InkWell(
        onTap: () {
          if (active) {
            c.toggleSortDirection();
          } else {
            c.setSort(field);
          }
        },
        borderRadius: BorderRadius.circular(Radii.sm),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style(active: active),
                ),
              ),
              if (active) ...[
                const SizedBox(width: 4),
                QIcon(
                  c.view.ascending ? QIcons.chevronUp : QIcons.chevronDown,
                  size: 11,
                  color: colors.ink,
                ),
              ],
            ],
          ),
        ),
      );
    }

    return Container(
      height: 30,
      padding: const EdgeInsets.only(left: 18, right: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.outline)),
      ),
      child: Row(
        children: [
          const SizedBox(width: 24),
          const SizedBox(width: 28),
          const SizedBox(width: 10),
          Expanded(
            flex: 5,
            child: Align(
              alignment: Alignment.centerLeft,
              child: sortableHeader('名称', LibrarySortField.name),
            ),
          ),
          if (columns.tags)
            Expanded(flex: 3, child: Text('标签', style: style())),
          if (columns.format)
            SizedBox(
              width: 72,
              child: Align(
                alignment: Alignment.centerLeft,
                child: sortableHeader('格式', LibrarySortField.format),
              ),
            ),
          if (columns.status)
            SizedBox(width: 110, child: Text('状态', style: style())),
          if (columns.progress)
            SizedBox(
              width: 92,
              child: Align(
                alignment: Alignment.centerLeft,
                child: sortableHeader('阅读进度', LibrarySortField.openedAt),
              ),
            ),
          const SizedBox(width: 30),
        ],
      ),
    );
  }

  Widget _listRow(LibraryItem item, bool compact) {
    final payload = LibraryDragPayload(
      entryIds: c.isEntrySelected(item.entry.id)
          ? c.selectedEntries
          : {item.entry.id},
      label: c.isEntrySelected(item.entry.id)
          ? '${c.selectionCount} 项'
          : item.displayName,
    );
    final row = _LibraryListRow(
      key: ValueKey('library-document-${item.entry.id}'),
      item: item,
      controller: c,
      compact: compact,
      selected: c.isEntrySelected(item.entry.id),
      dragPayload: payload,
      onTap: () {
        final keyboard = HardwareKeyboard.instance;
        c.selectEntry(
          item.entry.id,
          toggle: keyboard.isControlPressed || keyboard.isMetaPressed,
          range: keyboard.isShiftPressed,
        );
        if (compact) _open(item);
      },
      onOpen: () => _open(item),
      onLongPress: compact
          ? () => c.selectEntry(item.entry.id, toggle: true)
          : null,
      onMenu: (action) => _handleItemMenu(item, action),
    );
    if (c.view.sortField != LibrarySortField.manual) return row;
    return DragTarget<LibraryDragPayload>(
      onWillAcceptWithDetails: (details) =>
          details.data.entryIds.isNotEmpty &&
          !details.data.entryIds.contains(item.entry.id),
      onAcceptWithDetails: (details) => c.reorderEntry(
        details.data.entryIds.first,
        beforeEntryId: item.entry.id,
      ),
      builder: (context, candidates, rejected) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (candidates.isNotEmpty)
            Container(height: 2, color: context.colors.primary),
          row,
        ],
      ),
    );
  }

  Widget _gridCard(LibraryItem item, bool compact) {
    return _LibraryGridCard(
      key: ValueKey('library-grid-${item.entry.id}'),
      item: item,
      controller: c,
      thumbnails: _thumbnails,
      compact: compact,
      selected: c.isEntrySelected(item.entry.id),
      onTap: () {
        final keyboard = HardwareKeyboard.instance;
        c.selectEntry(
          item.entry.id,
          toggle: keyboard.isControlPressed || keyboard.isMetaPressed,
          range: keyboard.isShiftPressed,
        );
        if (compact) _open(item);
      },
      onOpen: () => _open(item),
      onLongPress: compact
          ? () => c.selectEntry(item.entry.id, toggle: true)
          : null,
      onMenu: (action) => _handleItemMenu(item, action),
    );
  }

  Future<void> _exportSelection() async {
    if (!c.hasSelection && c.detailItem != null) {
      c.selectEntry(c.detailItem!.entry.id);
    }
    if (!c.hasSelection) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('先选择要导出的资料或文件夹。')),
      );
      return;
    }
    final destination = await pickExportDirectory(context);
    if (destination == null) return;
    final report = await c.exportSelection(destination);
    if (report != null && mounted) {
      await showExportReportDialog(context, report);
    }
  }

  Future<void> _handleItemMenu(LibraryItem item, String action) async {
    switch (action) {
      case 'open':
        await _open(item);
      case 'rename':
        await _rename(item);
      case 'move':
        c.selectEntry(item.entry.id);
        await _moveSelection();
      case 'shortcut':
        await _createShortcut(item);
      case 'star':
        await c.toggleStar(item.document.id);
      case 'tags':
        final tags = await showTagPickerDialog(
          context,
          controller: c,
          document: item.document,
        );
        if (tags != null) await c.assignTags(item.document.id, tags);
      case 'locate':
        c.locateDocument(item.document.id);
      case 'export':
        c.selectEntry(item.entry.id);
        await _exportSelection();
      case 'delete':
        await _deleteEntry(item);
      case 'details':
        c.showDetail(item.entry.id);
    }
  }

  // ---------------------------------------------------------------------------
  // Selection bar
  // ---------------------------------------------------------------------------

  Widget _selectionBar(bool compact) {
    final colors = context.colors;
    final actions = <Widget>[];
    void iconAction(
      String tooltip,
      VoidCallback onTap, {
      required QIconData icon,
      bool danger = false,
    }) {
      actions.add(
        IconButton(
          tooltip: tooltip,
          onPressed: onTap,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
          padding: EdgeInsets.zero,
          icon: QIcon(
            icon,
            size: IconSizes.sm,
            color: danger ? colors.danger : colors.ink,
          ),
        ),
      );
    }

    void textAction(
      String label,
      VoidCallback onTap, {
      required QIconData icon,
      bool danger = false,
    }) {
      actions.add(
        TextButton.icon(
          onPressed: onTap,
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            minimumSize: const Size(0, 34),
          ),
          icon: QIcon(
            icon,
            size: IconSizes.sm,
            color: danger ? colors.danger : colors.ink,
          ),
          label: Text(
            label,
            style: TextStyle(color: danger ? colors.danger : colors.ink),
          ),
        ),
      );
    }

    if (compact) {
      iconAction('移动到', _moveSelection, icon: QIcons.move);
      iconAction('加标签', _tagSelection, icon: QIcons.tag);
      iconAction('星标', _toggleStarSelection, icon: QIcons.star);
      iconAction('导出', _exportSelection, icon: QIcons.download);
      iconAction(
        '移入回收站',
        _trashSelection,
        icon: QIcons.trash,
        danger: true,
      );
    } else {
      textAction('移动到', _moveSelection, icon: QIcons.move);
      textAction('加标签', _tagSelection, icon: QIcons.tag);
      textAction('星标', _toggleStarSelection, icon: QIcons.star);
      textAction('导出', _exportSelection, icon: QIcons.download);
      textAction(
        '移入回收站',
        _trashSelection,
        icon: QIcons.trash,
        danger: true,
      );
    }
    return Container(
      key: const ValueKey('library-selection-bar'),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: colors.outlineStrong),
        boxShadow: AppShadow.e2,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 8 : 10,
            vertical: 6,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: colors.tint,
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: Text(
                  '已选择 ${c.selectionCount} 项',
                  style: context.texts.bodySmall!.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colors.ink,
                    fontFeatures: AppNumerals.tabular,
                  ),
                ),
              ),
              Container(
                width: 1,
                height: 18,
                margin: const EdgeInsets.symmetric(horizontal: 6),
                color: colors.outline,
              ),
              ...actions,
              Container(
                width: 1,
                height: 18,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                color: colors.outline,
              ),
              IconButton(
                tooltip: '取消选择（Esc）',
                onPressed: c.clearSelection,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                padding: EdgeInsets.zero,
                icon: const QIcon(QIcons.close, size: IconSizes.sm),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Details
  // ---------------------------------------------------------------------------

  Widget _detailsPanel() {
    final colors = context.colors;
    final item = c.detailItem;
    return SizedBox(
      width: 304,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: colors.outline)),
        ),
        child: Padding(
          padding: const EdgeInsets.only(left: 1),
          child: Material(
            color: colors.surface,
            child: item == null
                ? LibraryOverviewInspector(
                    controller: c,
                    onNewFolder: _newFolder,
                    onImportFiles: _pickFiles,
                    onEditFolderNote: c.currentFolder == null
                        ? null
                        : () => _editFolderStyle(c.currentFolder!),
                  )
                : LibraryItemInspector(
                    item: item,
                    controller: c,
                    thumbnails: _thumbnails,
                    onOpen: () => _open(item),
                    onRename: () => _rename(item),
                    onTags: () => _handleItemMenu(item, 'tags'),
                    onStar: () => c.toggleStar(item.document.id),
                    onDelete: () => _deleteEntry(item),
                    onMove: () {
                      c.selectEntry(item.entry.id);
                      _moveSelection();
                    },
                    onLocate: () => c.locateDocument(item.document.id),
                    onShortcut: () => _createShortcut(item),
                    onExport: () {
                      c.selectEntry(item.entry.id);
                      _exportSelection();
                    },
                    onLearningMode: (mode) =>
                        c.setLearningMode(item.document.id, mode),
                    onOpenNote: widget.onOpenNote,
                    onCreateNote: widget.onCreateNoteForDocument,
                  ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Queue and trash
  // ---------------------------------------------------------------------------

  String _queueTargetLabel(ImportBatch batch) {
    final name = c.folderPathName(batch.targetFolderId);
    return name.isEmpty ? '未归档' : name;
  }

  Future<void> _openLatestImport() async {
    for (final batch in c.queue.batches) {
      for (final item in batch.items.reversed) {
        final id = item.documentId;
        if (id == null) continue;
        final document = c.store.getDocument(id);
        if (document == null || !document.isActive) continue;
        await widget.onOpenDocument(document);
        return;
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('这批导入没有可打开的新资料。')),
    );
  }

  Widget _queueBar(bool compact) {
    final colors = context.colors;
    final queue = c.queue;
    final latest = queue.latest;
    final active = queue.busy;
    final target = latest == null ? '未归档' : _queueTargetLabel(latest);
    final text = active
        ? '导入中 → $target：${latest?.finished ?? 0}/${latest?.total ?? 0}'
            '${(latest?.existing ?? 0) > 0 ? ' · 已存在 ${latest!.existing}' : ''}'
            '${(latest?.failed ?? 0) > 0 ? ' · 失败 ${latest!.failed}' : ''}'
        : '导入到 → $target：新 ${queue.importedCount} · 已存在 '
            '${queue.existingCount}'
            '${queue.failedCount > 0 ? ' · 失败 ${queue.failedCount}' : ''}';
    return Container(
      height: 38,
      padding: const EdgeInsets.only(left: 16, right: 8),
      decoration: BoxDecoration(
        color: colors.surfaceRaised,
        border: Border(top: BorderSide(color: colors.outline)),
      ),
      child: Row(
        children: [
          if (active)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            QIcon(QIcons.success, size: IconSizes.sm, color: colors.inkMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.texts.bodySmall!.copyWith(
                fontSize: 12,
                color: colors.ink,
                fontFeatures: AppNumerals.tabular,
              ),
            ),
          ),
          TextButton(
            onPressed: () => showImportQueueDialog(context, controller: c),
            child: const Text('查看队列'),
          ),
          if (!active)
            TextButton(
              onPressed: _openLatestImport,
              child: const Text('打开'),
            ),
          if (!active)
            IconButton(
              tooltip: '清理导入记录',
              onPressed: queue.clearFinished,
              visualDensity: VisualDensity.compact,
              icon: const QIcon(QIcons.close, size: IconSizes.sm),
            ),
        ],
      ),
    );
  }

  Widget _trashView(bool compact) {
    final batches = c.trashBatches;
    final query = c.query.trim().toLowerCase();
    final filtered = query.isEmpty
        ? batches
        : batches
              .where(
                (batch) =>
                    batch.label.toLowerCase().contains(query) ||
                    c
                        .trashItemsFor(batch.id)
                        .any(
                          (item) =>
                              item.displayName.toLowerCase().contains(query),
                        ),
              )
              .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(compact ? 12 : 20, 10, compact ? 8 : 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '回收站 · 可随时恢复',
                  style: context.texts.bodySmall!.copyWith(
                    fontSize: 12,
                    color: context.colors.inkMuted,
                  ),
                ),
              ),
              if (batches.isNotEmpty)
                TextButton(
                  onPressed: () async {
                    final confirmed = await showLibraryConfirmDialog(
                      context,
                      title: '清空回收站？',
                      message: '回收站内的资料、笔记与会话将被永久删除且不可撤销；'
                          '外部原文件与独立学习记录不受影响。',
                      confirmLabel: '永久清空',
                      danger: true,
                    );
                    if (confirmed) await c.emptyTrash();
                  },
                  child: Text(
                    '清空回收站',
                    style: TextStyle(color: context.colors.danger),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: EmptyState(
                    compact: true,
                    icon: QIcons.trash,
                    title: query.isEmpty ? '回收站是空的' : '没有匹配的回收站项目',
                    message: query.isEmpty
                        ? '删除的资料会先放在这里。'
                        : '换一个词试试。',
                  ),
                )
              : ListView.builder(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 10 : 18,
                    4,
                    compact ? 10 : 18,
                    24,
                  ),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) => _TrashBatchCard(
                    key: ValueKey('trash-${filtered[index].id}'),
                    batch: filtered[index],
                    controller: c,
                  ),
                ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Empty states
  // ---------------------------------------------------------------------------

  Widget _emptyLibrary(bool compact) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              QIcon(
                QIcons.library,
                size: 40,
                color: context.colors.inkMuted,
              ),
              const SizedBox(height: 14),
              Text('书库为空', style: context.texts.headlineSmall),
              const SizedBox(height: 6),
              Text(
                '拖入 PDF 或图片，或从本地选择文件/文件夹。',
                textAlign: TextAlign.center,
                style: context.texts.bodySmall!.copyWith(height: 1.6),
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: _pickFiles,
                    icon: const QIcon(QIcons.add, size: IconSizes.sm),
                    label: const Text('选择文件'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _pickFolder,
                    icon: const QIcon(QIcons.folderOpen, size: IconSizes.sm),
                    label: const Text('选择文件夹'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _newFolder,
                    icon: const QIcon(QIcons.folder, size: IconSizes.sm),
                    label: const Text('新建文件夹'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'PDF · JPG · PNG',
                style: context.texts.bodySmall!.copyWith(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyFolder(bool compact) {
    return Center(
      child: EmptyState(
        compact: true,
        icon: QIcons.folderOpen,
        title: '这里还是空的',
        message: '拖入资料，或导入文件 / 新建子文件夹。',
        action: Wrap(
          spacing: 8,
          children: [
            TextButton(onPressed: _pickFiles, child: const Text('导入文件')),
            TextButton(onPressed: _pickFolder, child: const Text('导入文件夹')),
            TextButton(
              onPressed: () => _newFolder(),
              child: const Text('新建子文件夹'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showSortSheet() async {
    final field = await showModalBottomSheet<LibrarySortField>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final value in LibrarySortField.values)
              ListTile(
                title: Text(value.label),
                trailing: c.view.sortField == value
                    ? const QIcon(QIcons.check, size: IconSizes.sm)
                    : null,
                onTap: () => Navigator.pop(context, value),
              ),
          ],
        ),
      ),
    );
    if (field != null) c.setSort(field);
  }
}

// -----------------------------------------------------------------------------
// Toolbar subwidgets
// -----------------------------------------------------------------------------

class _FolderCrumbTarget extends StatelessWidget {
  const _FolderCrumbTarget({
    required this.controller,
    required this.folderId,
    required this.child,
  });

  final LibraryController controller;
  final String folderId;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DragTarget<LibraryDragPayload>(
      onWillAcceptWithDetails: (details) {
        if (details.data.isEmpty) return false;
        for (final id in details.data.folderIds) {
          if (id == folderId ||
              controller.descendantFolderIds(id).contains(
                folderId,
              )) {
            return false;
          }
        }
        return true;
      },
      onAcceptWithDetails: (details) =>
          controller.moveNodes(
            folderIds: details.data.folderIds,
            entryIds: details.data.entryIds,
            targetFolderId: folderId,
          ),
      builder: (context, candidates, rejected) => Container(
        decoration: candidates.isEmpty
            ? null
            : BoxDecoration(
                color: context.colors.tint,
                borderRadius: BorderRadius.circular(6),
              ),
        child: child,
      ),
    );
  }
}

class _FolderTile extends StatefulWidget {
  const _FolderTile({
    super.key,
    required this.controller,
    required this.folder,
    required this.count,
    required this.onOpen,
    required this.onStyle,
    this.colorValue,
  });

  final LibraryController controller;
  final LibraryFolder folder;
  final int count;
  final int? colorValue;
  final VoidCallback onOpen;
  final VoidCallback onStyle;

  @override
  State<_FolderTile> createState() => _FolderTileState();
}

class _FolderTileState extends State<_FolderTile> {
  bool _hovered = false;
  bool _highlight = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final color = folderInk(context, widget.colorValue);
    final card = Semantics(
      button: true,
      label: '${widget.folder.name}，${widget.count} 项',
      child: InkWell(
        onTap: widget.onOpen,
        onDoubleTap: widget.onOpen,
        onHover: (value) => setState(() => _hovered = value),
        borderRadius: BorderRadius.circular(Radii.md),
        hoverColor: Colors.transparent,
        child: Container(
          width: 176,
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: _highlight
                ? colors.tint
                : _hovered
                ? colors.surfaceRaised
                : colors.surface,
            border: Border.all(
              color: _highlight || _hovered ? colors.outlineStrong : colors.outline,
            ),
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          child: Row(
            children: [
              if (widget.folder.icon?.isNotEmpty == true)
                Text(widget.folder.icon!, style: const TextStyle(fontSize: 15))
              else
                QIcon(QIcons.folder, size: IconSizes.md, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.folder.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.bodyMedium!.copyWith(fontSize: 13),
                ),
              ),
              if (widget.count > 0)
                Text(
                  '${widget.count}',
                  style: context.texts.bodySmall!.copyWith(
                    fontSize: 12,
                    color: colors.inkMuted,
                    fontFeatures: AppNumerals.tabular,
                  ),
                ),
              if (_hovered)
                IconButton(
                  tooltip: '文件夹外观',
                  onPressed: widget.onStyle,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 24,
                    minHeight: 24,
                  ),
                  padding: EdgeInsets.zero,
                  icon: QIcon(
                    QIcons.palette,
                    size: 15,
                    color: colors.inkMuted,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    return DragTarget<LibraryDragPayload>(
      onWillAcceptWithDetails: (details) => details.data.isNotEmpty,
      onMove: (details) {
        if (!_highlight) setState(() => _highlight = true);
      },
      onLeave: (_) {
        if (_highlight) setState(() => _highlight = false);
      },
      onAcceptWithDetails: (details) {
        setState(() => _highlight = false);
        widget.controller.moveNodes(
          folderIds: details.data.folderIds,
          entryIds: details.data.entryIds,
          targetFolderId: widget.folder.id,
        );
      },
      builder: (context, candidates, rejected) => card,
    );
  }
}

class _NewFolderTile extends StatelessWidget {
  const _NewFolderTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.md),
      child: Container(
        width: 140,
        height: 48,
        decoration: BoxDecoration(
          border: Border.all(color: colors.outlineStrong),
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            QIcon(QIcons.add, size: IconSizes.sm, color: colors.inkMuted),
            const SizedBox(width: 6),
            Text(
              '新建文件夹',
              style: context.texts.bodySmall!.copyWith(fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// List row
// -----------------------------------------------------------------------------

class _LibraryListRow extends StatefulWidget {
  const _LibraryListRow({
    super.key,
    required this.item,
    required this.controller,
    required this.compact,
    required this.selected,
    required this.dragPayload,
    required this.onTap,
    required this.onOpen,
    this.onLongPress,
    required this.onMenu,
  });

  final LibraryItem item;
  final LibraryController controller;
  final bool compact;
  final bool selected;
  final LibraryDragPayload dragPayload;
  final VoidCallback? onLongPress;
  final VoidCallback onTap;
  final VoidCallback onOpen;
  final ValueChanged<String> onMenu;

  @override
  State<_LibraryListRow> createState() => _LibraryListRowState();
}

class _LibraryListRowState extends State<_LibraryListRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final item = widget.item;
    final document = item.document;
    final tags = [
      for (final tag in widget.controller.tags)
        if ((widget.controller.tagIdsByDocument[document.id] ?? const {})
            .contains(tag.id))
          tag,
    ];
    final columns = widget.controller.view.columns;
    final progress = widget.controller.progressFor(document.id);
    final percent = document.pageCount <= 0
        ? 0
        : (document.currentPage / document.pageCount * 100).round();
    final showCheckbox =
        !widget.compact &&
        (_hovered || widget.selected || widget.controller.hasSelection);
    final content = Row(
      children: [
        if (!widget.compact)
          SizedBox(
            width: 24,
            child: showCheckbox
                ? Center(
                    child: InkWell(
                      onTap: () => widget.controller.selectEntry(
                        item.entry.id,
                        toggle: true,
                      ),
                      borderRadius: BorderRadius.circular(4),
                      child: Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          color: widget.selected
                              ? colors.primary
                              : colors.surface,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: widget.selected
                                ? colors.primary
                                : colors.outlineStrong,
                          ),
                        ),
                        child: widget.selected
                            ? Center(
                                child: QIcon(
                                  QIcons.check,
                                  size: 11,
                                  color: colors.onPrimary,
                                ),
                              )
                            : null,
                      ),
                    ),
                  )
                : null,
          ),
        _formatGlyph(document, isShortcut: item.isShortcut),
        const SizedBox(width: 10),
        Expanded(
          flex: 5,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      item.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.texts.bodyMedium!.copyWith(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w500,
                        color: item.available ? colors.ink : colors.inkMuted,
                      ),
                    ),
                  ),
                  if (document.starred) ...[
                    const SizedBox(width: 5),
                    QIcon(
                      QIcons.star,
                      size: 12,
                      color: colors.inkMuted,
                      active: true,
                    ),
                  ],
                ],
              ),
              if (!widget.compact)
                Text(
                  _subtitle(item),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.bodySmall!.copyWith(fontSize: 12),
                ),
            ],
          ),
        ),
        if (!widget.compact && columns.tags)
          Expanded(
            flex: 3,
            child: tags.isEmpty
                ? Text(
                    '—',
                    style: context.texts.bodySmall!.copyWith(
                      fontSize: 12,
                      color: colors.inkMuted,
                    ),
                  )
                : Wrap(
                    spacing: 4,
                    children: [
                      for (final tag in tags.take(2))
                        AppBadge(label: tag.name, dense: true),
                      if (tags.length > 2)
                        AppBadge(label: '+${tags.length - 2}', dense: true),
                    ],
                  ),
          ),
        if (!widget.compact && columns.format)
          SizedBox(
            width: 72,
            child: Text(
              formatLabel(document.format),
              style: context.texts.bodySmall!.copyWith(
                fontSize: 12,
                color: colors.inkMuted,
              ),
            ),
          ),
        if (widget.compact || columns.status)
          SizedBox(
            width: widget.compact ? 72 : 110,
            child: Text(
              processingLabel(document, widget.controller),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.texts.bodySmall!.copyWith(
                fontSize: 12,
                color: document.isTrashed ? colors.danger : colors.inkMuted,
              ),
            ),
          ),
        if (!widget.compact && columns.progress)
          SizedBox(
            width: 92,
            child: Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: progress.hasPages ? progress.ratio : percent / 100,
                      minHeight: 3,
                      backgroundColor: colors.tint,
                      color: colors.ink,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '$percent%',
                  style: context.texts.bodySmall!.copyWith(
                    fontSize: 12,
                    color: colors.inkMuted,
                    fontFeatures: AppNumerals.tabular,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    return GestureDetector(
      onDoubleTap: widget.onOpen,
      onSecondaryTapDown: (details) =>
          _showItemContextMenu(context, details.globalPosition, widget.onMenu),
      child: InkWell(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        onHover: (value) => setState(() => _hovered = value),
        hoverColor: Colors.transparent,
        child: Container(
          height: widget.compact ? 52 : 54,
          padding: EdgeInsets.only(
            left: widget.compact ? 10 : 18,
            right: widget.compact ? 4 : 12,
          ),
          decoration: BoxDecoration(
            color: widget.selected
                ? colors.tint
                : _hovered
                ? colors.surfaceRaised
                : Colors.transparent,
            border: Border(bottom: BorderSide(color: colors.outline)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Draggable<LibraryDragPayload>(
                  data: widget.dragPayload,
                  feedback: LibraryDragFeedback(
                    label: widget.dragPayload.label,
                    icon: QIcons.page,
                  ),
                  childWhenDragging: Opacity(opacity: .4, child: content),
                  child: content,
                ),
              ),
              _ItemMenu(onSelected: widget.onMenu),
            ],
          ),
        ),
      ),
    );
  }

  String _subtitle(LibraryItem item) {
    if (item.isShortcut && !item.available) return '原资料在回收站';
    final folder = widget.controller.folderPathName(item.entry.folderId);
    if (folder.isEmpty) {
      return item.document.originalName.isEmpty
          ? '未归档'
          : '未归档 · ${item.document.originalName}';
    }
    return folder;
  }

  Widget _formatGlyph(DocumentRecord document, {required bool isShortcut}) {
    final colors = context.colors;
    return SizedBox(
      width: 28,
      height: 28,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: colors.surfaceRaised,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Center(
              child: QIcon(
                documentIcon(document.format),
                size: 15,
                color: colors.inkMuted,
              ),
            ),
          ),
          if (isShortcut)
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

class _LibraryGridCard extends StatefulWidget {
  const _LibraryGridCard({
    super.key,
    required this.item,
    required this.controller,
    required this.thumbnails,
    required this.compact,
    required this.selected,
    required this.onTap,
    required this.onOpen,
    this.onLongPress,
    required this.onMenu,
  });

  final LibraryItem item;
  final LibraryController controller;
  final LibraryThumbnailService thumbnails;
  final bool compact;
  final bool selected;
  final VoidCallback? onLongPress;
  final VoidCallback onTap;
  final VoidCallback onOpen;
  final ValueChanged<String> onMenu;

  @override
  State<_LibraryGridCard> createState() => _LibraryGridCardState();
}

class _LibraryGridCardState extends State<_LibraryGridCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final item = widget.item;
    final document = item.document;
    return GestureDetector(
      onDoubleTap: widget.onOpen,
      onSecondaryTapDown: (details) =>
          _showItemContextMenu(context, details.globalPosition, widget.onMenu),
      child: InkWell(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        onHover: (value) => setState(() => _hovered = value),
        borderRadius: BorderRadius.circular(Radii.md),
        hoverColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: widget.selected ? colors.tint : colors.surface,
            border: Border.all(
              color: widget.selected || _hovered
                  ? colors.outlineStrong
                  : colors.outline,
            ),
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  DocumentCoverImage(
                    document: document,
                    thumbnails: widget.thumbnails,
                    width: 34,
                    height: widget.compact ? 34 : 44,
                    iconSize: 17,
                  ),
                  const Spacer(),
                  if (item.isShortcut)
                    const QIcon(QIcons.shortcut, size: 13),
                  if (document.starred)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: QIcon(
                        QIcons.star,
                        size: 13,
                        color: colors.inkMuted,
                        active: true,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: Text(
                  item.displayName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.bodyMedium!.copyWith(
                    fontSize: 12.5,
                    height: 1.35,
                    color: item.available ? colors.ink : colors.inkMuted,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Text(
                    formatLabel(document.format),
                    style: context.texts.bodySmall!.copyWith(
                      fontSize: 12,
                      color: colors.inkMuted,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${document.currentPage}/${document.pageCount}',
                    style: context.texts.bodySmall!.copyWith(
                      fontSize: 12,
                      color: colors.inkMuted,
                      fontFeatures: AppNumerals.tabular,
                    ),
                  ),
                  _ItemMenu(onSelected: widget.onMenu, dense: true),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _showItemContextMenu(
  BuildContext context,
  Offset globalPosition,
  ValueChanged<String> onSelected,
) async {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
  final size = overlay?.size ?? const Size(1200, 800);
  final action = await showMenu<String>(
    context: context,
    position: RelativeRect.fromLTRB(
      globalPosition.dx,
      globalPosition.dy,
      size.width - globalPosition.dx,
      size.height - globalPosition.dy,
    ),
    items: _ItemMenu.menuItems,
  );
  if (action != null) onSelected(action);
}

class _ItemMenu extends StatelessWidget {
  const _ItemMenu({required this.onSelected, this.dense = false});

  final ValueChanged<String> onSelected;
  final bool dense;

  static const List<PopupMenuEntry<String>> menuItems = [
    PopupMenuItem(value: 'open', child: Text('阅读')),
    PopupMenuItem(value: 'details', child: Text('查看详情')),
    PopupMenuDivider(),
    PopupMenuItem(value: 'rename', child: Text('重命名')),
    PopupMenuItem(value: 'move', child: Text('移动到…')),
    PopupMenuItem(value: 'shortcut', child: Text('创建快捷方式到…')),
    PopupMenuItem(value: 'export', child: Text('导出原件…')),
    PopupMenuItem(value: 'tags', child: Text('标签…')),
    PopupMenuItem(value: 'star', child: Text('切换星标')),
    PopupMenuItem(value: 'locate', child: Text('在文件夹中定位')),
    PopupMenuDivider(),
    PopupMenuItem(value: 'delete', child: Text('移入回收站')),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SizedBox(
      width: dense ? 22 : 30,
      height: dense ? 22 : 30,
      child: PopupMenuButton<String>(
        tooltip: '资料操作',
        padding: EdgeInsets.zero,
        constraints: BoxConstraints(
          minWidth: dense ? 22 : 30,
          minHeight: dense ? 22 : 30,
        ),
        icon: QIcon(
          QIcons.more,
          size: dense ? 13 : IconSizes.md,
          color: colors.inkMuted,
        ),
        onSelected: onSelected,
        itemBuilder: (context) => menuItems,
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Trash
// -----------------------------------------------------------------------------

class _TrashBatchCard extends StatelessWidget {
  const _TrashBatchCard({
    super.key,
    required this.batch,
    required this.controller,
  });

  final DeletionBatch batch;
  final LibraryController controller;

  Future<void> _restoreTo(BuildContext context, LibraryItem item) async {
    final choice = await showFolderPickerDialog(
      context,
      controller: controller,
      title: '恢复到哪里',
      subtitle: item.displayName,
      confirmLabel: '恢复到这里',
    );
    if (choice == null || choice.cancelled || !context.mounted) return;
    await controller.restoreEntry(
      item.entry.id,
      destinationFolderId: choice.folderId,
    );
  }

  Future<void> _purge(BuildContext context, LibraryItem item) async {
    if (item.isShortcut && item.document.isActive) {
      final confirmed = await showLibraryConfirmDialog(
        context,
        title: '永久删除这个快捷方式？',
        subtitle: item.displayName,
        message: '只删除这个入口；原资料、笔记和其他入口都不受影响。',
        confirmLabel: '永久删除',
        danger: true,
      );
      if (confirmed) await controller.purgeEntry(item.entry.id);
      return;
    }
    final impact = controller.repository.purgeImpactForDocuments([
      item.document.id,
    ]);
    if (!context.mounted) return;
    final confirmed = await showPurgeImpactDialog(
      context,
      label: item.displayName,
      impact: impact,
    );
    if (confirmed) await controller.purgeEntry(item.entry.id);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final items = controller.trashItemsFor(batch.id);
    final folders = controller.trashFoldersFor(batch.id);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.outline),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
            child: Row(
              children: [
                QIcon(
                  batch.kind == 'folder' ? QIcons.folder : QIcons.trash,
                  size: IconSizes.md,
                  color: colors.inkMuted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        batch.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.texts.bodyMedium!.copyWith(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '${dateLabel(batch.createdAt)} · ${items.length} 份资料'
                        '${folders.isNotEmpty ? ' · ${folders.length} 个文件夹' : ''}',
                        style: context.texts.bodySmall!.copyWith(fontSize: 11),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () => controller.restoreBatch(batch.id),
                  child: const Text('恢复'),
                ),
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: colors.danger),
                  onPressed: () async {
                    final impact = await controller.impactForBatch(batch.id);
                    if (!context.mounted) return;
                    final confirmed = await showPurgeImpactDialog(
                      context,
                      label: batch.label,
                      impact: impact,
                    );
                    if (confirmed) await controller.purgeBatch(batch.id);
                  },
                  child: const Text('永久删除'),
                ),
              ],
            ),
          ),
          for (final folder in folders.take(6))
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 3, 16, 3),
              child: Row(
                children: [
                  QIcon(
                    QIcons.folder,
                    size: 13,
                    color: colors.inkMuted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      folder.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.texts.bodySmall!.copyWith(fontSize: 12),
                    ),
                  ),
                  Text(
                    '文件夹',
                    style: context.texts.bodySmall!.copyWith(fontSize: 11),
                  ),
                ],
              ),
            ),
          for (final item in items.take(6))
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 5, 8, 5),
              child: Row(
                children: [
                  QIcon(
                    documentIcon(item.document.format),
                    size: 13,
                    color: colors.inkMuted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      item.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.texts.bodySmall!.copyWith(fontSize: 12),
                    ),
                  ),
                  Text(
                    controller.folderPathName(item.entry.folderId).isEmpty
                        ? '未归档'
                        : controller.folderPathName(item.entry.folderId),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.bodySmall!.copyWith(fontSize: 11),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 28),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      textStyle: const TextStyle(fontSize: 11.5),
                    ),
                    onPressed: () => controller.restoreEntry(item.entry.id),
                    child: const Text('恢复'),
                  ),
                  SizedBox(
                    width: 26,
                    height: 26,
                    child: PopupMenuButton<String>(
                      tooltip: '这一项的更多操作',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 26,
                        minHeight: 26,
                      ),
                      icon: QIcon(
                        QIcons.more,
                        size: 14,
                        color: colors.inkMuted,
                      ),
                      onSelected: (value) => value == 'to'
                          ? _restoreTo(context, item)
                          : _purge(context, item),
                      itemBuilder: (context) => const [
                        PopupMenuItem(value: 'to', child: Text('恢复到…')),
                        PopupMenuItem(value: 'purge', child: Text('永久删除')),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          if (items.length + folders.length > 6)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 2, 16, 10),
              child: Text(
                '还有 ${items.length + folders.length - 6} 项',
                style: context.texts.bodySmall!.copyWith(fontSize: 11),
              ),
            )
          else
            const SizedBox(height: 6),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Filter sheet
// -----------------------------------------------------------------------------

class _FilterSheet extends StatefulWidget {
  const _FilterSheet({
    required this.initial,
    required this.formats,
    required this.tags,
  });

  final LibraryFilter initial;
  final List<String> formats;
  final List<LibraryTag> tags;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late LibraryFilter _filter = widget.initial;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '筛选',
                    style: context.texts.titleSmall!.copyWith(fontSize: 15),
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      Navigator.pop(context, const LibraryFilter()),
                  child: const Text('清除'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (widget.formats.isNotEmpty) ...[
              Text(
                '文件格式',
                style: context.texts.bodySmall!.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                children: [
                  for (final format in widget.formats)
                    FilterChip(
                      label: Text(format.toUpperCase()),
                      selected: _filter.formats.contains(format),
                      onSelected: (_) => setState(() {
                        _filter = _filter.toggleFormat(format);
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            if (widget.tags.isNotEmpty) ...[
              Text(
                '标签',
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
                  for (final tag in widget.tags)
                    FilterChip(
                      label: Text(tag.name),
                      selected: _filter.tagIds.contains(tag.id),
                      onSelected: (_) => setState(() {
                        _filter = _filter.toggleTag(tag.id);
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            Text(
              '状态',
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
                FilterChip(
                  label: const Text('仅星标'),
                  selected: _filter.starredOnly,
                  onSelected: (value) => setState(() {
                    _filter = _filter.copyWith(starredOnly: value);
                  }),
                ),
                FilterChip(
                  label: const Text('仅待处理'),
                  selected: _filter.processingOnly,
                  onSelected: (value) => setState(() {
                    _filter = _filter.copyWith(processingOnly: value);
                  }),
                ),
                FilterChip(
                  label: const Text('仅未读'),
                  selected: _filter.unreadOnly,
                  onSelected: (value) => setState(() {
                    _filter = _filter.copyWith(unreadOnly: value);
                  }),
                ),
              ],
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: () => Navigator.pop(context, _filter),
              child: const Text('应用筛选'),
            ),
            const SizedBox(height: 6),
            Text(
              '筛选不会移动资料；只影响当前看到的列表。',
              textAlign: TextAlign.center,
              style: context.texts.bodySmall!.copyWith(
                fontSize: 11,
                color: colors.inkMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Visible confirmation before an operating-system drop commits anything.
/// The target is the current real folder, or "未归档" for smart/global views.
class _ExternalDropHint extends StatelessWidget {
  const _ExternalDropHint({required this.target});

  final String target;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: colors.outlineStrong),
        boxShadow: AppShadow.e2,
      ),
      child: Row(
        children: [
          QIcon(QIcons.download, size: IconSizes.md, color: colors.ink),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '松开以导入到「$target」',
                  style: context.texts.bodyMedium!.copyWith(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '文件将复制到 Quelyt，保留目录结构并跳过不支持格式。',
                  style: context.texts.bodySmall!.copyWith(fontSize: 11.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact 32px search input embedded in the unified Library header.
class _LibrarySearchField extends StatefulWidget {
  const _LibrarySearchField({
    required this.width,
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  final double width;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  State<_LibrarySearchField> createState() => _LibrarySearchFieldState();
}

class _LibrarySearchFieldState extends State<_LibrarySearchField> {
  final _focus = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _focus.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (mounted) setState(() => _focused = _focus.hasFocus);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      width: widget.width,
      height: 32,
      child: AnimatedContainer(
        duration: context.motion(Motion.fast),
        curve: Motion.curve,
        decoration: BoxDecoration(
          color: c.sidebar,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: _focused ? c.outlineStrong : c.outline,
          ),
        ),
        child: Row(
          children: [
            const SizedBox(width: 9),
            QIcon(QIcons.search, size: 14, color: c.inkMuted),
            const SizedBox(width: 6),
            Expanded(
              child: TextField(
                controller: widget.controller,
                focusNode: _focus,
                onChanged: widget.onChanged,
                textAlignVertical: TextAlignVertical.center,
                style: context.texts.bodySmall!.copyWith(
                  color: c.ink,
                  fontSize: 13,
                  height: 1.2,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  filled: false,
                  fillColor: Colors.transparent,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  hintText: '搜索资料、标签或正文',
                  hintStyle: context.texts.bodySmall!.copyWith(
                    color: c.inkMuted,
                    fontSize: 13,
                  ),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: widget.controller,
              builder: (context, value, _) {
                if (value.text.isEmpty) {
                  return const SizedBox(width: 6);
                }
                return IconButton(
                  tooltip: '清除搜索',
                  onPressed: widget.onClear,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 26,
                    minHeight: 26,
                  ),
                  padding: EdgeInsets.zero,
                  icon: QIcon(QIcons.close, size: 14, color: c.inkMuted),
                );
              },
            ),
            const SizedBox(width: 2),
          ],
        ),
      ),
    );
  }
}