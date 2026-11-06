import 'package:flutter/material.dart';

import '../../app_controller.dart';
import '../../core/models.dart';
import '../dialogs/app_dialogs.dart';
import '../theme/tokens.dart';
import '../widgets/app_surfaces.dart';
import '../widgets/quelyt_mark.dart';

class LibraryPage extends StatefulWidget {
  const LibraryPage({
    super.key,
    required this.controller,
    required this.onImportKind,
    required this.query,
    required this.onClearSearch,
  });

  final StudyController controller;
  final ValueChanged<DocumentKind> onImportKind;
  final String query;
  final VoidCallback onClearSearch;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  int _filter = 0;

  StudyController get c => widget.controller;

  List<DocumentRecord> get _documents {
    final q = widget.query.trim().toLowerCase();
    return c.library
        .where(
          (doc) =>
              (_filter == 0 ||
                  (_filter == 1
                      ? doc.kind == DocumentKind.textbook
                      : doc.kind == DocumentKind.paper)) &&
              (q.isEmpty || doc.title.toLowerCase().contains(q)),
        )
        .toList();
  }

  void _clearFilters() {
    setState(() => _filter = 0);
    widget.onClearSearch();
  }

  void _toast(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _delete(DocumentRecord doc) async {
    final confirmed = await showDeleteDocumentDialog(context, title: doc.title);
    if (!confirmed) return;
    try {
      await c.deleteDocument(doc);
      if (mounted) _toast('已删除「${doc.title}」。');
    } catch (error) {
      if (mounted) _toast('删除失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final padding = width >= 760 ? 24.0 : 16.0;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(padding, 18, padding, 32),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: c.library.isEmpty
                  ? _EmptyLibrary(onImportKind: widget.onImportKind)
                  : _content(width),
            ),
          ),
        );
      },
    );
  }

  Widget _content(double width) {
    final docs = _documents;
    final textbooks = c.library
        .where((doc) => doc.kind == DocumentKind.textbook)
        .length;
    final papers = c.library.length - textbooks;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            AppSegmentedControl(
              segmentMinWidth: 88,
              segments: [
                AppSegment(label: '全部', count: c.library.length),
                AppSegment(label: '教材', count: textbooks),
                AppSegment(label: '论文', count: papers),
              ],
              selectedIndex: _filter,
              onChanged: (index) => setState(() => _filter = index),
            ),
            const Spacer(),
            if (width >= 600 && docs.length != c.library.length)
              Text(
                '${docs.length} 项结果',
                style: context.texts.bodySmall!.copyWith(fontSize: 12.5),
              ),
          ],
        ),
        const SizedBox(height: 14),
        if (docs.isEmpty)
          _NoResults(onClear: _clearFilters)
        else
          _DocumentList(
            documents: docs,
            notesFor: (doc) => c.store.getNotes(doc.id).length,
            onOpen: c.open,
            onDelete: _delete,
          ),
      ],
    );
  }
}

class _DocumentList extends StatelessWidget {
  const _DocumentList({
    required this.documents,
    required this.notesFor,
    required this.onOpen,
    required this.onDelete,
  });

  final List<DocumentRecord> documents;
  final int Function(DocumentRecord) notesFor;
  final ValueChanged<DocumentRecord> onOpen;
  final ValueChanged<DocumentRecord> onDelete;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      children: [
        _DocumentListHeader(),
        for (var index = 0; index < documents.length; index++) ...[
          _DocumentRow(
            key: ValueKey('library-document-${documents[index].id}'),
            document: documents[index],
            notes: notesFor(documents[index]),
            onOpen: () => onOpen(documents[index]),
            onDelete: () => onDelete(documents[index]),
          ),
          if (index < documents.length - 1)
            Divider(height: 1, color: c.outline),
        ],
      ],
    );
  }
}

class _DocumentListHeader extends StatelessWidget {
  const _DocumentListHeader();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final style = context.texts.bodySmall!.copyWith(
      fontSize: 12.5,
      color: c.inkMuted,
      fontWeight: FontWeight.w600,
      height: 1.2,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 760;
        final recent = constraints.maxWidth >= 900;
        return Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: c.outline)),
          ),
          child: Row(
            children: [
              const SizedBox(width: 28),
              Expanded(child: Text('资料', style: style)),
              if (wide) ...[
                SizedBox(width: 84, child: Text('类型', style: style)),
                SizedBox(width: 64, child: Text('笔记', style: style)),
              ],
              if (recent)
                SizedBox(width: 110, child: Text('最近打开', style: style)),
              SizedBox(
                width: 116,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('进度', style: style),
                ),
              ),
              const SizedBox(width: 32),
            ],
          ),
        );
      },
    );
  }
}

class _DocumentRow extends StatefulWidget {
  const _DocumentRow({
    super.key,
    required this.document,
    required this.notes,
    required this.onOpen,
    required this.onDelete,
  });

  final DocumentRecord document;
  final int notes;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  @override
  State<_DocumentRow> createState() => _DocumentRowState();
}

class _DocumentRowState extends State<_DocumentRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final doc = widget.document;
    final textbook = doc.kind == DocumentKind.textbook;
    final ratio = (doc.currentPage / doc.pageCount).clamp(0.0, 1.0);
    final percent = (ratio * 100).round();
    return Semantics(
      button: true,
      label: '${doc.title}，${textbook ? '教材' : '论文'}，$percent%',
      child: InkWell(
        onTap: widget.onOpen,
        onHover: (value) => setState(() => _hovered = value),
        hoverColor: Colors.transparent,
        child: Container(
          height: 58,
          color: _hovered ? c.sidebar : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 760;
              final recent = constraints.maxWidth >= 900;
              return Row(
                children: [
                  Icon(
                    textbook
                        ? Icons.menu_book_outlined
                        : Icons.article_outlined,
                    size: 18,
                    color: c.inkMuted,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      doc.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.texts.bodyMedium!.copyWith(
                        fontSize: 14.5,
                        color: c.ink,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (wide) ...[
                    SizedBox(
                      width: 84,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: c.surfaceRaised,
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: Text(
                            textbook ? '教材' : '论文',
                            style: context.texts.bodySmall!.copyWith(
                              fontSize: 12,
                              color: c.inkMuted,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 64,
                      child: Text(
                        widget.notes == 0 ? '—' : '${widget.notes}',
                        style: context.texts.bodySmall!.copyWith(
                          fontSize: 13,
                          color: widget.notes == 0
                              ? c.inkMuted.withValues(alpha: .5)
                              : null,
                          fontFeatures: AppNumerals.tabular,
                        ),
                      ),
                    ),
                  ],
                  if (recent)
                    SizedBox(
                      width: 110,
                      child: Text(
                        _openedLabel(doc.lastOpenedAt),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.texts.bodySmall!.copyWith(
                          fontSize: 13,
                          fontFeatures: AppNumerals.tabular,
                        ),
                      ),
                    ),
                  SizedBox(
                    width: 116,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 56,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: ratio,
                              minHeight: 4,
                              backgroundColor: c.tint,
                              color: c.ink,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 42,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerRight,
                            child: Text(
                              '$percent%',
                              maxLines: 1,
                              softWrap: false,
                              style: context.texts.bodySmall!.copyWith(
                                fontSize: 12.5,
                                color: c.inkMuted,
                                fontFeatures: AppNumerals.tabular,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: PopupMenuButton<String>(
                      tooltip: '资料操作',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                      icon: Icon(
                        Icons.more_horiz_rounded,
                        size: 18,
                        color: c.inkMuted,
                      ),
                      onSelected: (value) {
                        if (value == 'delete') widget.onDelete();
                      },
                      itemBuilder: (context) => [
                        PopupMenuItem(
                          value: 'delete',
                          child: Row(
                            children: [
                              Icon(
                                Icons.delete_outline_rounded,
                                size: 16,
                                color: c.danger,
                              ),
                              const SizedBox(width: 8),
                              Text('删除资料', style: TextStyle(color: c.danger)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _NoResults extends StatelessWidget {
  const _NoResults({required this.onClear});

  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off_rounded, size: 24, color: c.inkMuted),
            const SizedBox(height: 10),
            Text('没有匹配结果', style: context.texts.bodyMedium),
            const SizedBox(height: 4),
            TextButton(onPressed: onClear, child: const Text('清除筛选')),
          ],
        ),
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.onImportKind});

  final ValueChanged<DocumentKind> onImportKind;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 72),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const QuelytMark(size: 40, watermark: true, semanticLabel: null),
              const SizedBox(height: 16),
              Text('书库为空', style: context.texts.headlineSmall),
              const SizedBox(height: 4),
              Text('导入第一份资料开始阅读。', style: context.texts.bodySmall),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => onImportKind(DocumentKind.textbook),
                    icon: const Icon(Icons.menu_book_outlined, size: 15),
                    label: const Text('教材自学'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () => onImportKind(DocumentKind.paper),
                    icon: const Icon(Icons.article_outlined, size: 15),
                    label: const Text('论文精读'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text('PDF · JPG · PNG', style: context.texts.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

String _openedLabel(DateTime value) {
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
