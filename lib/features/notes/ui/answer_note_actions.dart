import 'package:flutter/material.dart';

import '../../../core/models.dart';
import '../../../ui/icons/q_icons.dart';
import '../data/notes_repository.dart';
import '../models/note_models.dart';
import '../notes_controller.dart';

NoteSource noteEvidence(
  Evidence evidence, {
  String title = '',
  String? assetName,
}) => NoteSource(
  id: '',
  noteId: '',
  documentId: evidence.documentId,
  documentHash: evidence.documentHash,
  page: evidence.page,
  timeMs: evidence.timeMs,
  locatorLabel: evidence.locatorLabel,
  region: evidence.region,
  excerpt: evidence.text,
  sourceType: evidence.timeMs == null ? 'document' : 'video',
  title: title,
  assetName: assetName,
  createdAt: DateTime.now(),
);

class AnswerNoteActions extends StatelessWidget {
  const AnswerNoteActions({
    super.key,
    required this.draft,
    required this.repository,
    this.notes,
    this.onOpen,
  });

  final AnswerNoteDraft draft;
  final NotesRepository repository;
  final NotesController? notes;
  final ValueChanged<String>? onOpen;

  void save(BuildContext context, {Set<int>? sections, NoteRecord? target}) {
    try {
      final note =
          notes?.saveAnswer(
            draft,
            sections: sections,
            targetNoteId: target?.id,
            expectedRevision: target?.revision,
          ) ??
          repository.saveAnswer(
            draft,
            selected: sections,
            targetNoteId: target?.id,
            expectedRevision: target?.revision,
          );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已添加到「${note.displayTitle}」'),
          action: onOpen == null
              ? null
              : SnackBarAction(
                  label: '打开笔记',
                  onPressed: () => onOpen!(note.id),
                ),
        ),
      );
    } catch (error) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> append(
    BuildContext context, {
    String query = '',
    Set<int>? sections,
  }) async {
    final target = await showDialog<NoteRecord>(
      context: context,
      builder: (_) => _TargetNoteDialog(repository, query: query),
    );
    if (target != null && context.mounted) {
      save(context, sections: sections, target: target);
    }
  }

  Future<void> _pickSections(
    BuildContext context, {
    required bool appendToNote,
  }) async {
    final checked = <int>{};
    final selected = await showDialog<Set<int>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('选择要保存的段落'),
          content: SizedBox(
            width: 520,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: draft.sections.length,
              itemBuilder: (context, index) => CheckboxListTile(
                value: checked.contains(index),
                title: Text(
                  draft.sections[index].markdown,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
                onChanged: (value) => setState(() {
                  if (value == true) {
                    checked.add(index);
                  } else {
                    checked.remove(index);
                  }
                }),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: checked.isEmpty
                  ? null
                  : () => Navigator.pop(context, checked),
              child: Text(appendToNote ? '选择笔记' : '新建笔记'),
            ),
          ],
        ),
      ),
    );
    if (selected == null || !context.mounted) return;
    if (appendToNote) {
      await append(context, sections: selected);
    } else {
      save(context, sections: selected);
    }
  }

  @override
  Widget build(BuildContext context) => Wrap(
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      TextButton.icon(
        onPressed: () => save(context),
        icon: const QIcon(QIcons.notes, size: IconSizes.sm),
        label: const Text('添加到笔记'),
      ),
      PopupMenuButton<String>(
        tooltip: '更多笔记操作',
        onSelected: (value) async {
          if (value == 'append') {
            await append(context);
          } else {
            await _pickSections(context, appendToNote: value == 'append-parts');
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'append', child: Text('追加到已有笔记')),
          PopupMenuItem(value: 'new-parts', child: Text('选段新建笔记')),
          PopupMenuItem(value: 'append-parts', child: Text('选段追加到笔记')),
        ],
      ),
    ],
  );
}

String? noteCommandTarget(String text) =>
    RegExp(r'^(?:请)?把(?:刚才|上一条|上条)的?回答(?:添加|加|保存|追加)到[《「“](.+?)[》」”][。！!]?$')
        .firstMatch(text.trim())
        ?.group(1);

class _TargetNoteDialog extends StatefulWidget {
  const _TargetNoteDialog(this.repository, {required this.query});
  final NotesRepository repository;
  final String query;

  @override
  State<_TargetNoteDialog> createState() => _TargetNoteDialogState();
}

class _TargetNoteDialogState extends State<_TargetNoteDialog> {
  late final _filter = TextEditingController(text: widget.query);

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final results = widget.repository
        .list(scope: NotesScope.all)
        .where(
          (note) => note.displayTitle.toLowerCase().contains(
            _filter.text.trim().toLowerCase(),
          ),
        )
        .take(100)
        .toList();
    return AlertDialog(
      title: const Text('追加到已有笔记'),
      content: SizedBox(
        width: 500,
        height: 360,
        child: Column(
          children: [
            TextField(
              controller: _filter,
              decoration: const InputDecoration(labelText: '搜索笔记标题'),
              onChanged: (_) => setState(() {}),
            ),
            Expanded(
              child: results.isEmpty
                  ? const Center(child: Text('没有匹配的笔记'))
                  : ListView.builder(
                      itemCount: results.length,
                      itemBuilder: (context, index) {
                        final note = results[index];
                        return ListTile(
                          title: Text(note.displayTitle),
                          subtitle: Text(
                            note.updatedAt
                                .toLocal()
                                .toString()
                                .split('.')
                                .first,
                          ),
                          onTap: () => Navigator.pop(context, note),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}
