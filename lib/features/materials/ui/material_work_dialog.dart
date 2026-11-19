import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app_controller.dart';
import '../../../core/models.dart';
import '../../../ui/icons/q_icons.dart';
import '../../notes/models/note_models.dart';
import '../../notes/notes_controller.dart';
import '../../notes/ui/answer_note_actions.dart';
import '../../notes/ui/note_markdown_preview.dart';
import '../material_work.dart';
import '../material_work_templates.dart';

Future<List<MaterialResult>?> showMaterialWork(
  BuildContext context,
  StudyController study,
  PreparedMaterialWork request,
) async {
  try {
    if (!context.mounted) return null;
    return await showDialog<List<MaterialResult>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _WorkDialog(study, request),
    );
  } finally {
    await request.close();
  }
}

class _WorkDialog extends StatefulWidget {
  const _WorkDialog(this.study, this.request);
  final StudyController study;
  final PreparedMaterialWork request;

  @override
  State<_WorkDialog> createState() => _WorkDialogState();
}

class _WorkDialogState extends State<_WorkDialog> {
  late final _budget = TextEditingController(
    text: widget.request.estimatedTokens.toString(),
  );
  MaterialProgress? _progress;
  List<MaterialResult>? _completed;
  String? _error;
  bool _running = false;
  bool _pause = false;

  @override
  void dispose() {
    _pause = true;
    _budget.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final request = widget.request;
    final amount = int.tryParse(_budget.text);
    if (amount == null || amount <= 0 || amount > request.estimatedTokens) {
      setState(() => _error = '请输入 1 到 ${request.estimatedTokens} 之间的本次估算上限。');
      return;
    }
    setState(() {
      _running = true;
      _error = null;
    });
    request.approve();
    try {
      final results = await widget.study.runMaterialWork(
        request,
        budget: amount,
        paused: () => _pause,
        onProgress: (value) {
          if (mounted) {
            setState(() => _progress = value);
          }
        },
      );
      if (mounted) setState(() => _completed = results);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _completed = request.cached;
        });
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    final current = _progress;
    final done = _completed;
    final preview = !_running && done == null;
    final destination = request.destination.toString();
    final billing = request.billingUnit;
    return PopScope(
      canPop: !_running,
      child: AlertDialog(
        title: Text('${request.action.label}${preview ? ' · 发送预览' : ''}'),
        content: SizedBox(
          width: 680,
          height: math.max(
            200,
            math.min(
              560,
              (MediaQuery.sizeOf(context).height -
                      MediaQuery.viewInsetsOf(context).bottom) *
                  .57,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${request.translation?.label ?? request.settings.provider} · ${request.model}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (preview) ...[
                SelectableText(destination),
                Text(
                  '${request.units.length} 项待发送 · ${request.cached.length} 项从本机复用',
                ),
                if (request.units.isNotEmpty) ...[
                  TextField(
                    controller: _budget,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: '本次预算（估算$billing）',
                      helperText: request.translation == null
                          ? '含图片、输入与预留输出。每项开始前核对余额。'
                          : '按实际发送的字符估算。每项开始前核对余额。',
                    ),
                  ),
                  if (request.translation == null)
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text('本任务的发送指令'),
                      children: [
                        SelectableText(materialInstructions(request.action)),
                      ],
                    ),
                ],
              ],
              if (current != null) ...[
                const SizedBox(height: 10),
                LinearProgressIndicator(
                  value: current.total == 0 ? 1 : current.done / current.total,
                ),
                Text('${current.message} · ${current.done} / ${current.total}'),
                Text(
                  '实耗 ${current.spent} $billing · 估算 ${current.estimated} · 剩余 ${math.max(0, current.budget - current.spent - current.estimated)}',
                ),
              ],
              const SizedBox(height: 8),
              Expanded(
                child: ListView.builder(
                  itemCount:
                      request.gaps.length +
                      (preview ? request.units.length : done?.length ?? 0),
                  itemBuilder: (context, index) {
                    if (index < request.gaps.length) {
                      return ListTile(
                        leading: const QIcon(QIcons.info),
                        title: Text(request.gaps[index]),
                      );
                    }
                    final position = index - request.gaps.length;
                    if (!preview) {
                      final result = done![position];
                      return ListTile(
                        title: Text(result.label),
                        subtitle: Text(
                          result.issue ??
                              (result.billedCharacters != null
                                  ? '${result.billedCharacters} 字符'
                                  : result.usage == null
                                  ? '服务未返回用量 · 估算 ${result.reserved} ${result.billingUnit}'
                                  : '${result.usage!.totalTokens} token'),
                        ),
                        leading: QIcon(
                          result.needsVerification
                              ? QIcons.verify
                              : result.hasResult
                              ? QIcons.success
                              : QIcons.error,
                        ),
                      );
                    }
                    final unit = request.units[position];
                    final image = unit.image;
                    return ExpansionTile(
                      initiallyExpanded: request.units.length == 1,
                      title: Text(
                        unit.label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '输入估算 ${unit.inputBudget} $billing'
                        '${request.outputReserve > 0 ? ' · 预留输出 ${request.outputReserve}' : ''}',
                      ),
                      expandedCrossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (image != null) ...[
                          Text(image.label),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 270),
                            child: Image.file(image.file, fit: BoxFit.contain),
                          ),
                          SelectableText(
                            'SHA-256 ${image.digest}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                        SelectableText(unit.requestText),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (_running)
            TextButton(
              onPressed: _pause ? null : () => setState(() => _pause = true),
              child: Text(_pause ? '正在完成当前项' : '暂停后续项'),
            )
          else if (preview && request.units.isNotEmpty) ...[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(onPressed: _run, child: const Text('确认并开始')),
          ] else
            FilledButton(
              onPressed: () => Navigator.pop(context, done ?? request.cached),
              child: const Text('查看结果'),
            ),
        ],
      ),
    );
  }
}

typedef MaterialJump = Future<void> Function(Evidence);

class MaterialResultView extends StatelessWidget {
  const MaterialResultView({
    super.key,
    required this.study,
    required this.document,
    required this.action,
    required this.result,
    required this.onJump,
    this.notes,
    this.openNote,
    this.onEdit,
    this.onArchive,
    this.onReview,
  });

  final StudyController study;
  final DocumentRecord document;
  final MaterialAction action;
  final MaterialResult result;
  final MaterialJump onJump;
  final NotesController? notes;
  final ValueChanged<String>? openNote;
  final VoidCallback? onEdit;
  final VoidCallback? onArchive;
  final VoidCallback? onReview;

  @override
  Widget build(BuildContext context) {
    final slot = result.data['translationSlot'];
    final edit = slot is String
        ? study.materialWork.readState(document, slot)
        : action == MaterialAction.recognition
        ? study.materialWork.readState(
            document,
            'recognitionEdit:${result.key}',
          )
        : null;
    final text = edit is String ? edit : result.text;
    final first = result.sources.firstOrNull;
    return Card.outlined(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(result.label, style: Theme.of(context).textTheme.titleSmall),
            if (result.issue != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Text(result.issue!),
              ),
            if (action == MaterialAction.translation && first != null)
              LayoutBuilder(
                builder: (context, size) {
                  final original = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('原文'),
                      NoteMarkdownPreview(text: first.text),
                    ],
                  );
                  final translated = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(edit is String ? '译文 · 已修订' : '译文'),
                      if (text.isNotEmpty) NoteMarkdownPreview(text: text),
                    ],
                  );
                  return size.maxWidth >= 560
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: original),
                            const SizedBox(width: 18),
                            Expanded(child: translated),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [original, const Divider(), translated],
                        );
                },
              )
            else if (action == MaterialAction.outline &&
                result.data['nodes'] is List)
              _Outline(result: result, onJump: onJump)
            else if (text.isNotEmpty)
              NoteMarkdownPreview(text: text),
            if (result.sources.isNotEmpty && action != MaterialAction.outline)
              Wrap(
                spacing: 6,
                children: [
                  for (final source in result.sources.take(
                    action == MaterialAction.recognition ? 12 : 4,
                  ))
                    ActionChip(
                      label: Text(source.locatorLabel ?? '第 ${source.page} 页'),
                      onPressed: () => onJump(source),
                    ),
                ],
              ),
            Wrap(
              spacing: 6,
              children: [
                if (onEdit != null && result.hasResult)
                  TextButton(onPressed: onEdit, child: const Text('人工修订')),
                if (onArchive != null && result.hasResult)
                  TextButton(onPressed: onArchive, child: const Text('收为错题')),
                if (onReview != null && result.hasResult)
                  TextButton(onPressed: onReview, child: const Text('加入复习')),
                if (result.hasResult &&
                    text.isNotEmpty &&
                    action != MaterialAction.recognition)
                  AnswerNoteActions(
                    repository: study.noteRepository,
                    notes: notes,
                    onOpen: openNote,
                    draft: AnswerNoteDraft(
                      answerId: 'material:${result.key}',
                      question: result.label,
                      documentId: document.id,
                      sections: [
                        AnswerNoteSection(
                          text,
                          sources: [
                            for (final source in result.sources)
                              noteEvidence(source, title: document.title),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Outline extends StatelessWidget {
  const _Outline({required this.result, required this.onJump});
  final MaterialResult result;
  final MaterialJump onJump;

  @override
  Widget build(BuildContext context) {
    final nodes = (result.data['nodes'] as List).map(materialJson).toList();
    Widget entry(Map<String, dynamic> node, int depth) {
      final children = nodes.where(
        (current) => current['parent'] == node['id'],
      );
      return Padding(
        padding: EdgeInsets.only(left: depth == 0 ? 0 : 9),
        child: ExpansionTile(
          initiallyExpanded: depth < 2,
          title: Text(node['title'] as String),
          children: [
            if ((node['summary'] as String).isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: NoteMarkdownPreview(text: node['summary'] as String),
              ),
            Wrap(
              spacing: 6,
              children: [
                for (final index in (node['refs'] as List).whereType<int>())
                  if (index >= 0 && index < result.sources.length)
                    ActionChip(
                      label: Text('第 ${result.sources[index].page} 页'),
                      onPressed: () => onJump(result.sources[index]),
                    ),
              ],
            ),
            for (final child in children) entry(child, depth + 1),
          ],
        ),
      );
    }

    return entry(nodes.singleWhere((node) => node['parent'] == ''), 0);
  }
}
