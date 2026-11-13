import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app_controller.dart';
import '../../../ui/theme/tokens.dart';
import '../../../ui/widgets/app_dialog.dart';
import '../../../ui/widgets/app_surfaces.dart';
import '../../review/models/review_models.dart';
import '../../review/ui/review_dialogs.dart';
import '../models/note_models.dart';
import '../notes_controller.dart';
import 'note_context_drawer.dart';
import 'note_markdown_preview.dart';
import 'notes_sidebar_tree.dart';

/// Global notes workspace. The same note object is created from the reader and
/// edited here; a 700 ms debounce only controls disk writes, never the text in
/// the field.
class NotesPage extends StatefulWidget {
  const NotesPage({
    super.key,
    required this.controller,
    this.study,
    this.onOpenSource,
    this.showSidebar = true,
  });

  final NotesController controller;
  final StudyController? study;
  final ValueChanged<NoteSource>? onOpenSource;

  /// Whether to render [NotesSidebarTree] inside [NotesPage] on wide screens.
  /// When [StudyHome] already mounts [NotesSidebarTree] inside the global
  /// `AppSidebar`, it passes `showSidebar: false` to avoid a double sidebar.
  final bool showSidebar;

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> with WidgetsBindingObserver {
  final _title = TextEditingController();
  final _body = TextEditingController();
  final _bodyFocus = FocusNode();
  String? _editingId;
  bool _preview = false;
  bool _splitView = false;
  bool _showContextDrawer = true;

  NotesController get notes => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncEditor();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    notes.flushNow();
    _title.dispose();
    _body.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      notes.flushNow();
    }
  }

  void _togglePreviewCheckbox(int lineIndex) {
    final lines = _body.text.split('\n');
    if (lineIndex < 0 || lineIndex >= lines.length) return;
    final line = lines[lineIndex];
    if (line.contains('[ ]')) {
      lines[lineIndex] = line.replaceFirst('[ ]', '[x]');
    } else if (line.toLowerCase().contains('[x]')) {
      lines[lineIndex] = line.replaceFirst(
        RegExp(r'\[x\]', caseSensitive: false),
        '[ ]',
      );
    } else {
      return;
    }
    _body.text = lines.join('\n');
    notes.editBody(_body.text);
  }

  void _syncEditor() {
    final note = notes.selected;
    if (note == null) {
      _editingId = null;
      if (_title.text.isNotEmpty) _title.clear();
      if (_body.text.isNotEmpty) _body.clear();
      return;
    }
    if (_editingId == note.id) return;
    _editingId = note.id;
    _title.value = TextEditingValue(
      text: note.title,
      selection: TextSelection.collapsed(offset: note.title.length),
    );
    _body.value = TextEditingValue(
      text: note.body,
      selection: TextSelection.collapsed(offset: note.body.length),
    );
  }

  void _checkMessages() {
    final notice = notes.notice;
    final error = notes.error;
    if (notice == null && error == null) return;
    final canUndo = notes.canUndoTrash && notice != null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      notes.clearMessages();
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(error ?? notice!),
          action: canUndo
              ? SnackBarAction(
                  label: '撤销',
                  onPressed: notes.undoLastTrash,
                )
              : null,
        ),
      );
    });
  }

  Future<void> _toast(String message) async {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: notes,
      builder: (context, _) {
        _syncEditor();
        _checkMessages();
        return LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 840;
            if (compact) {
              return notes.selected == null
                  ? ColoredBox(
                      color: context.colors.sidebar,
                      child: NotesSidebarTree(controller: notes),
                    )
                  : _editor(context, compact: true);
            }
            final editorChild = notes.selected == null
                ? _emptyEditor(context)
                : _editor(context, compact: false);
            if (!widget.showSidebar) {
              return editorChild;
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 288,
                  child: ColoredBox(
                    color: context.colors.sidebar,
                    child: NotesSidebarTree(controller: notes),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(child: editorChild),
              ],
            );
          },
        );
      },
    );
  }

  Widget _emptyEditor(BuildContext context) => Center(
    child: EmptyState(
      compact: true,
      icon: QIcons.notes,
      title: '选择或新建一篇笔记',
      message: '笔记独立保存；原文摘录仅作核对，不改动原书。',
      action: TextButton(onPressed: _newNote, child: const Text('新建笔记')),
    ),
  );

  Widget _editor(BuildContext context, {required bool compact}) {
    final note = notes.selected;
    if (note == null) return _emptyEditor(context);
    final colors = context.colors;
    final trashed = note.isTrashed;
    final horizontal = compact ? 14.0 : 32.0;
    final contextCount =
        notes.selectedSources.length +
        notes.selectedQuestions.where((q) => q.isOpen).length;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyB, control: true): () {
          if (!trashed) _wrap('**', '**');
        },
        const SingleActivator(LogicalKeyboardKey.keyI, control: true): () {
          if (!trashed) _wrap('*', '*');
        },
        const SingleActivator(LogicalKeyboardKey.keyE, control: true): () {
          setState(() => _preview = !_preview);
        },
        const SingleActivator(LogicalKeyboardKey.keyS, control: true):
            notes.saveNow,
      },
      child: Container(
        color: colors.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 8 : 24,
                compact ? 8 : 20,
                compact ? 6 : 20,
                0,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (compact)
                    _smallIconButton(
                      context,
                      QIcons.back,
                      '返回列表',
                      notes.closeSelected,
                    ),
                  Expanded(
                    child: TextField(
                      controller: _title,
                      readOnly: trashed,
                      style: context.texts.titleSmall!.copyWith(
                        fontSize: compact ? 20 : 24,
                        height: 1.25,
                        fontWeight: FontWeight.w600,
                      ),
                      decoration: InputDecoration(
                        hintText: '未命名笔记',
                        hintStyle: context.texts.titleSmall!.copyWith(
                          fontSize: compact ? 20 : 24,
                          color: colors.inkMuted,
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                      ),
                      onChanged: notes.editTitle,
                    ),
                  ),
                  const SizedBox(width: 4),
                  _smallIconButton(
                    context,
                    QIcons.star,
                    note.starred ? '取消星标' : '星标',
                    notes.toggleStar,
                    color: note.starred ? colors.primary : colors.inkMuted,
                  ),
                  if (!compact)
                    Tooltip(
                      message: _showContextDrawer ? '收起来源与问题栏' : '展开来源与问题栏',
                      child: InkWell(
                        onTap: () => setState(
                          () => _showContextDrawer = !_showContextDrawer,
                        ),
                        borderRadius: BorderRadius.circular(Radii.sm),
                        child: Container(
                          height: 28,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          decoration: BoxDecoration(
                            color: _showContextDrawer
                                ? colors.tint
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(Radii.sm),
                            border: Border.all(
                              color: _showContextDrawer
                                  ? colors.outlineStrong
                                  : colors.outline,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              QIcon(
                                QIcons.anchor,
                                size: 13,
                                color: _showContextDrawer
                                    ? colors.ink
                                    : colors.inkMuted,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                contextCount > 0
                                    ? '来源与问题 ($contextCount)'
                                    : '来源与问题',
                                style: context.texts.bodySmall!.copyWith(
                                  fontSize: 12,
                                  color: _showContextDrawer
                                      ? colors.ink
                                      : colors.inkMuted,
                                  fontWeight: _showContextDrawer
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  PopupMenuButton<String>(
                    tooltip: '更多',
                    padding: EdgeInsets.zero,
                    icon: QIcon(
                      QIcons.more,
                      size: IconSizes.sm,
                      color: colors.inkMuted,
                    ),
                    onSelected: (value) {
                      switch (value) {
                        case 'review':
                          final s = widget.study;
                          if (s != null) {
                            final openQ = notes.selectedQuestions
                                .where((q) => q.isOpen)
                                .map((q) => q.text)
                                .toList();
                            final firstSource =
                                notes.selectedSources.firstOrNull;
                            showCreateOrEditReviewItemDialog(
                              context,
                              study: s,
                              initialObjective: note.title,
                              initialPrompt: openQ.isNotEmpty
                                  ? openQ.first
                                  : '回忆「${note.title.trim().isEmpty ? '本节笔记' : note.title.trim()}」的核心结论与依据',
                              initialAnswer: note.body.trim(),
                              origin: ReviewOrigin(
                                id: '',
                                itemId: '',
                                originKey: 'note:${note.id}',
                                sourceType: 'note',
                                documentId: firstSource?.documentId,
                                documentHash: firstSource?.documentHash ?? '',
                                documentTitle: '',
                                page: firstSource?.page,
                                noteId: note.id,
                                noteRevision: note.revision,
                                snapshotText: note.body.trim(),
                              ),
                            );
                          }
                        case 'history':
                          _history();
                        case 'copy':
                          _copyMarkdown();
                        case 'delete':
                          _delete();
                        case 'purge':
                          _purge();
                      }
                    },
                    itemBuilder: (context) => [
                      if (widget.study != null)
                        const PopupMenuItem(
                          value: 'review',
                          child: Text('制作为复习题'),
                        ),
                      const PopupMenuItem(
                        value: 'history',
                        child: Text('历史版本'),
                      ),
                      const PopupMenuItem(
                        value: 'copy',
                        child: Text('复制 Markdown'),
                      ),
                      if (trashed)
                        const PopupMenuItem(
                          value: 'purge',
                          child: Text('永久删除'),
                        )
                      else
                        const PopupMenuItem(
                          value: 'delete',
                          child: Text('移入回收站'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 14 : 28,
                4,
                compact ? 14 : 24,
                0,
              ),
              child: Row(
                children: [
                  _folderMenu(context, note),
                  const SizedBox(width: 6),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final tag in notes.tags)
                            if (notes.selectedTagIds.contains(tag.id))
                              Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: _metaChip(context, tag.name),
                              ),
                          TextButton.icon(
                            onPressed: trashed ? null : _editTags,
                            style: TextButton.styleFrom(
                              minimumSize: const Size(0, 28),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                            icon: const QIcon(QIcons.tag, size: 12),
                            label: const Text(
                              '标签',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _saveIndicator(context),
                ],
              ),
            ),
            if (trashed)
              Padding(
                padding: EdgeInsets.fromLTRB(horizontal, 12, horizontal, 0),
                child: AppCallout(
                  tone: CalloutTone.warning,
                  title: '这篇笔记在回收站',
                  message: '正文、来源与标签已保留，恢复后回到原目录。',
                  action: Wrap(
                    children: [
                      TextButton(
                        onPressed: notes.restoreSelected,
                        child: const Text('恢复'),
                      ),
                      TextButton(
                        onPressed: _purge,
                        child: const Text('永久删除'),
                      ),
                    ],
                  ),
                ),
              ),
            if (!trashed)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  compact ? 14 : 28,
                  12,
                  compact ? 14 : 24,
                  0,
                ),
                child: _toolbar(context, compact: compact),
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, bodyConstraints) {
                  final sideContext =
                      !compact &&
                      _showContextDrawer &&
                      bodyConstraints.maxWidth >= 680;
                  final canSplit =
                      !compact && _splitView && bodyConstraints.maxWidth >= 720;
                  final editorPane = ListView(
                    padding: EdgeInsets.fromLTRB(
                      horizontal,
                      compact ? 12 : 18,
                      horizontal,
                      compact ? 28 : 44,
                    ),
                    children: [
                      AnimatedSwitcher(
                        duration: context.motion(Motion.fast),
                        switchInCurve: Motion.curve,
                        switchOutCurve: Curves.easeIn,
                        child: (_preview && !canSplit)
                            ? KeyedSubtree(
                                key: const ValueKey('note-preview'),
                                child: NoteMarkdownPreview(
                                  text: notes.draftBody,
                                  onToggleCheckbox: _togglePreviewCheckbox,
                                ),
                              )
                            : TextField(
                                key: const ValueKey('note-edit'),
                                controller: _body,
                                focusNode: _bodyFocus,
                                readOnly: trashed,
                                keyboardType: TextInputType.multiline,
                                minLines: sideContext ? 14 : 4,
                                maxLines: null,
                                style: context.texts.bodyMedium!.copyWith(
                                  fontSize: 14.5,
                                  height: 1.85,
                                ),
                                decoration: InputDecoration(
                                  hintText:
                                      '写下你的理解…\n支持 Markdown：# 标题、- 列表、- [ ] 待办、\$x^2\$ 公式',
                                  hintStyle: context.texts.bodyMedium!.copyWith(
                                    fontSize: 14.5,
                                    height: 1.85,
                                    color: colors.inkMuted,
                                  ),
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  filled: false,
                                  isDense: true,
                                  contentPadding: EdgeInsets.zero,
                                ),
                                onChanged: notes.editBody,
                              ),
                      ),
                      if (!sideContext) ...[
                        const SizedBox(height: 28),
                        NoteContextPane(
                          controller: notes,
                          onAddQuestion: _addQuestion,
                          onOpenSource: widget.onOpenSource,
                          sidebarStyle: false,
                        ),
                      ],
                    ],
                  );
                  final mainContent = canSplit
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: editorPane),
                            const VerticalDivider(width: 1),
                            Expanded(
                              child: ListView(
                                padding: EdgeInsets.fromLTRB(
                                  24,
                                  18,
                                  24,
                                  44,
                                ),
                                children: [
                                  NoteMarkdownPreview(
                                    text: notes.draftBody,
                                    onToggleCheckbox: _togglePreviewCheckbox,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        )
                      : editorPane;
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: mainContent),
                      AnimatedSwitcher(
                        duration: context.motion(Motion.base),
                        switchInCurve: Motion.curve,
                        switchOutCurve: Curves.easeIn,
                        layoutBuilder: (currentChild, previousChildren) =>
                            Stack(
                              fit: StackFit.passthrough,
                              alignment: Alignment.centerRight,
                              children: [...previousChildren, ?currentChild],
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
                        child: sideContext
                            ? Row(
                                key: const ValueKey('note-context-drawer'),
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const VerticalDivider(width: 1),
                                  SizedBox(
                                    width: 288,
                                    child: NoteContextPane(
                                      controller: notes,
                                      onAddQuestion: _addQuestion,
                                      onOpenSource: widget.onOpenSource,
                                      onCollapse: () => setState(
                                        () => _showContextDrawer = false,
                                      ),
                                    ),
                                  ),
                                ],
                              )
                            : const SizedBox.shrink(
                                key: ValueKey('note-context-closed'),
                              ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metaChip(BuildContext context, String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: context.colors.tint,
      borderRadius: BorderRadius.circular(Radii.sm),
    ),
    child: Text(
      label,
      style: context.texts.bodySmall!.copyWith(fontSize: 12),
    ),
  );

  Widget _saveIndicator(BuildContext context) {
    final colors = context.colors;
    final failed = notes.saveState == 'error';
    final saving = notes.saveState == 'saving' || notes.dirty;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: failed
                ? colors.danger
                : saving
                ? colors.inkMuted
                : colors.primary,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          failed
              ? '保存失败'
              : saving
              ? '保存中…'
              : '已保存',
          style: context.texts.bodySmall!.copyWith(
            fontSize: 12,
            color: failed ? colors.danger : colors.inkMuted,
          ),
        ),
      ],
    );
  }

  Widget _toolbar(BuildContext context, {bool compact = false}) {
    final colors = context.colors;
    Widget textBtn(String label, String tooltip, VoidCallback action) =>
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: Tooltip(
            message: tooltip,
            child: InkWell(
              onTap: action,
              borderRadius: BorderRadius.circular(Radii.sm),
              child: Container(
                constraints: const BoxConstraints(minWidth: 30),
                height: 28,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                alignment: Alignment.center,
                child: Text(
                  label,
                  style: context.texts.bodySmall!.copyWith(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colors.ink,
                  ),
                ),
              ),
            ),
          ),
        );
    Widget iconBtn(QIconData icon, String tooltip, VoidCallback action) =>
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: Tooltip(
            message: tooltip,
            child: InkWell(
              onTap: action,
              borderRadius: BorderRadius.circular(Radii.sm),
              child: SizedBox(
                width: 30,
                height: 28,
                child: Center(
                  child: QIcon(icon, size: 14, color: colors.ink),
                ),
              ),
            ),
          ),
        );
    Widget divider() => Container(
      width: 1,
      height: 16,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: colors.outline,
    );
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: colors.surfaceRaised,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: colors.outline),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  textBtn('H1', '一级标题', () => _prefixLines('# ')),
                  textBtn('H2', '二级标题', () => _prefixLines('## ')),
                  textBtn('H3', '三级标题', () => _prefixLines('### ')),
                  divider(),
                  textBtn('B', '粗体（Ctrl+B）', () => _wrap('**', '**')),
                  textBtn('I', '斜体（Ctrl+I）', () => _wrap('*', '*')),
                  iconBtn(QIcons.list, '无序列表', () => _prefixLines('- ')),
                  iconBtn(QIcons.check, '待办清单', () => _prefixLines('- [ ] ')),
                  iconBtn(QIcons.anchor, '引用块', () => _prefixLines('> ')),
                  divider(),
                  textBtn('</>', '代码块', () => _wrap('\n```\n', '\n```\n')),
                  textBtn('∑', '数学公式块', () => _wrap('\n\$\$\n', '\n\$\$\n')),
                  iconBtn(
                    QIcons.link,
                    '插入链接',
                    () => _wrap('[', '](https://)'),
                  ),
                ],
              ),
            ),
          ),
          if (!compact) ...[
            const SizedBox(width: 4),
            TextButton(
              onPressed: () => setState(() {
                _splitView = !_splitView;
                if (_splitView) _preview = false;
              }),
              style: TextButton.styleFrom(
                minimumSize: const Size(44, 28),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                backgroundColor: _splitView ? colors.tint : Colors.transparent,
                visualDensity: VisualDensity.compact,
              ),
              child: Text(
                '分栏',
                style: context.texts.bodySmall!.copyWith(
                  fontSize: 12,
                  fontWeight: _splitView ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ],
          const SizedBox(width: 4),
          TextButton(
            onPressed: () => setState(() {
              _preview = !_preview;
              if (_preview) _splitView = false;
            }),
            style: TextButton.styleFrom(
              minimumSize: const Size(44, 28),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              backgroundColor: _preview ? colors.tint : Colors.transparent,
              visualDensity: VisualDensity.compact,
            ),
            child: Text(
              _preview ? '编辑' : '预览',
              style: context.texts.bodySmall!.copyWith(
                fontSize: 12,
                fontWeight: _preview ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _wrap(String before, String after) {
    final value = _body.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : value.text.length;
    final selected = value.text.substring(start, end);
    final replaced = '$before$selected$after';
    _body.value = TextEditingValue(
      text: value.text.replaceRange(start, end, replaced),
      selection: TextSelection.collapsed(offset: start + replaced.length),
    );
    notes.editBody(_body.text);
    _bodyFocus.requestFocus();
  }

  void _prefixLines(String prefix) {
    final value = _body.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final lineStart = value.text.lastIndexOf('\n', start - 1) + 1;
    final updated = value.text.replaceRange(lineStart, lineStart, prefix);
    _body.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: start + prefix.length),
    );
    notes.editBody(_body.text);
    _bodyFocus.requestFocus();
  }

  Widget _folderMenu(BuildContext context, NoteRecord note) {
    final current = notes.selectedEntry?.folderId;
    return PopupMenuButton<String>(
      tooltip: '移动到文件夹',
      onSelected: (value) => notes.moveToFolder(value.isEmpty ? null : value),
      itemBuilder: (context) => [
        const PopupMenuItem(value: '', child: Text('未归档')),
        for (final folder in notes.folders)
          PopupMenuItem(
            value: folder.id,
            child: Text(notes.folderPath(folder.id)),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: context.colors.surfaceRaised,
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(color: context.colors.outline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const QIcon(QIcons.folder, size: 13),
            const SizedBox(width: 5),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Text(
                notes.folderPath(current),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.texts.bodySmall!.copyWith(fontSize: 12),
              ),
            ),
            const SizedBox(width: 4),
            const QIcon(QIcons.chevronDown, size: 11),
          ],
        ),
      ),
    );
  }

  Future<void> _newNote({String body = ''}) async {
    final note = notes.createNote(
      folderId: notes.scope == NotesScope.folder ? notes.scopeFolderId : null,
      body: body,
    );
    if (note == null) return;
    await Future<void>.delayed(Duration.zero);
    if (mounted) _bodyFocus.requestFocus();
  }

  Future<void> _addQuestion() async {
    final text = await _promptText(
      title: '添加待解决问题',
      label: '问题',
      lines: 3,
    );
    if (text == null || text.trim().isEmpty) return;
    notes.addQuestion(text);
  }

  Future<void> _editTags() async {
    final selected = {...notes.selectedTagIds};
    final result = await showAppDialog<Set<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AppDialog(
          title: '笔记标签',
          subtitle: '标签与资料库共用。',
          icon: QIcons.tag,
          maxWidth: 480,
          actions: [
            DialogActions.cancel(context),
            FilledButton(
              onPressed: () => Navigator.pop(context, selected),
              child: const Text('保存'),
            ),
          ],
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (notes.tags.isEmpty)
                const Text('还没有标签。')
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final tag in notes.tags)
                      FilterChip(
                        label: Text(tag.name),
                        selected: selected.contains(tag.id),
                        onSelected: (value) => setDialogState(() {
                          if (value) {
                            selected.add(tag.id);
                          } else {
                            selected.remove(tag.id);
                          }
                        }),
                      ),
                  ],
                ),
              const SizedBox(height: Space.md),
              OutlinedButton.icon(
                onPressed: () async {
                  final name = await _promptText(
                    title: '新建标签',
                    label: '标签名称',
                  );
                  if (name == null || name.trim().isEmpty) return;
                  final tag = notes.createTag(name.trim());
                  setDialogState(() => selected.add(tag.id));
                },
                icon: const QIcon(QIcons.add, size: 12),
                label: const Text('新建标签'),
              ),
            ],
          ),
        ),
      ),
    );
    if (result != null) notes.setTags(result);
  }

  Future<void> _history() async {
    final revisions = notes.revisions();
    if (revisions.isEmpty) {
      await _toast('还没有历史版本。');
      return;
    }
    await showAppDialog<void>(
      context: context,
      builder: (context) => AppDialog(
        title: '历史版本',
        subtitle: '恢复会生成一个新版本，不抹掉当前内容。',
        icon: QIcons.restore,
        maxWidth: 560,
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
        content: SizedBox(
          height: 360,
          child: ListView.builder(
            itemCount: revisions.length,
            itemBuilder: (context, index) {
              final revision = revisions[index];
              return ListTile(
                dense: true,
                title: Text(
                  revision.title.trim().isEmpty ? '未命名笔记' : revision.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '${_dateTime(revision.createdAt)} · ${revision.reason}',
                ),
                trailing: TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    setState(() => _editingId = null);
                    notes.restoreRevision(revision);
                  },
                  child: const Text('恢复'),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _copyMarkdown() async {
    final note = notes.selected;
    if (note == null) return;
    await Clipboard.setData(
      ClipboardData(
        text: notes.repository.markdown(note, notes.selectedSources),
      ),
    );
    await _toast('Markdown 已复制。');
  }

  Future<void> _purge() async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: '永久删除这篇笔记？',
        icon: QIcons.trash,
        maxWidth: 440,
        actions: [
          DialogActions.cancel(context),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('永久删除'),
          ),
        ],
        content: const DialogBodyText('正文、问题、来源与历史版本将永久删除，不可撤销。'),
      ),
    );
    if (confirmed == true) notes.purgeSelected();
  }

  Future<void> _delete() async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: '移入回收站？',
        icon: QIcons.trash,
        maxWidth: 440,
        actions: [
          DialogActions.cancel(context),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('移入回收站'),
          ),
        ],
        content: const DialogBodyText('正文、来源与标签均保留，可随时恢复。'),
      ),
    );
    if (confirmed == true) notes.trashSelected();
  }

  Future<String?> _promptText({
    required String title,
    required String label,
    int lines = 1,
  }) async {
    final controller = TextEditingController();
    final result = await showAppDialog<String>(
      context: context,
      builder: (context) => AppDialog(
        title: title,
        maxWidth: 420,
        actions: [
          DialogActions.cancel(context),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: lines,
          maxLines: lines == 1 ? 1 : 5,
          decoration: InputDecoration(labelText: label),
        ),
      ),
    );
    controller.dispose();
    return result;
  }

  Widget _smallIconButton(
    BuildContext context,
    QIconData icon,
    String tooltip,
    VoidCallback action, {
    Color? color,
  }) => IconButton(
    tooltip: tooltip,
    onPressed: action,
    icon: QIcon(icon, size: IconSizes.sm, color: color),
    visualDensity: VisualDensity.compact,
    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
    padding: EdgeInsets.zero,
  );

  String _dateTime(DateTime value) =>
      '${value.year}-${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')} '
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';
}
