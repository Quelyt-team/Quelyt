import 'package:flutter/material.dart';

import '../../../app_controller.dart';
import '../../../core/models.dart';
import '../../../services/document_service.dart';
import '../../../ui/theme/tokens.dart';
import '../../../ui/widgets/app_surfaces.dart';
import '../../notes/models/note_models.dart';
import '../../notes/notes_controller.dart';
import '../../notes/ui/answer_note_actions.dart';
import '../../review/models/review_models.dart';
import '../../review/ui/review_dialogs.dart';
import '../material_work.dart';
import '../science/solution_pdf.dart';
import 'material_work_dialog.dart';

/// Dedicated study-tab workspace when a document is in [DocumentKind.exercise]
/// mode. Keeps single-question crop solving, page-range / full-assignment
/// solving, error-notebook archiving, review creation and solution PDF export
/// directly reachable on both desktop and Android.
class ExerciseStudyPanel extends StatefulWidget {
  const ExerciseStudyPanel({
    super.key,
    required this.study,
    required this.document,
    required this.onJump,
    this.notesController,
    this.onOpenNoteInWorkspace,
    this.sourceEntryId,
    this.onOpenMaterialTools,
  });

  final StudyController study;
  final DocumentRecord document;
  final Future<void> Function(Evidence) onJump;
  final NotesController? notesController;
  final ValueChanged<String>? onOpenNoteInWorkspace;
  final String? sourceEntryId;
  final VoidCallback? onOpenMaterialTools;

  @override
  State<ExerciseStudyPanel> createState() => _ExerciseStudyPanelState();
}

class _ExerciseStudyPanelState extends State<ExerciseStudyPanel> {
  late final TextEditingController _start;
  late final TextEditingController _end;
  final _instruction = TextEditingController();

  String? _documentId;
  bool _busy = false;
  bool _retryUnknown = false;
  String? _notice;
  CalloutTone _noticeTone = CalloutTone.info;
  List<MaterialResult>? _lastBatch;
  bool _knownComplete = false;
  DocumentRecord? _export;

  StudyController get study => widget.study;
  DocumentRecord get doc => widget.document;
  MaterialWork get work => study.materialWork;

  @override
  void initState() {
    super.initState();
    final page = study.page.clamp(1, doc.pageCount).toString();
    _start = TextEditingController(text: page);
    _end = TextEditingController(text: page);
    _documentId = doc.id;
  }

  @override
  void didUpdateWidget(covariant ExerciseStudyPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_documentId != doc.id) {
      _documentId = doc.id;
      final page = study.page.clamp(1, doc.pageCount).toString();
      _start.text = page;
      _end.text = page;
      _instruction.clear();
      _notice = null;
      _lastBatch = null;
      _knownComplete = false;
      _export = null;
      _retryUnknown = false;
    }
  }

  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    _instruction.dispose();
    super.dispose();
  }

  (int, int) _range() {
    final first = int.tryParse(_start.text.trim());
    final last = int.tryParse(_end.text.trim());
    if (first == null ||
        last == null ||
        first < 1 ||
        first > last ||
        last > doc.pageCount) {
      throw FormatException('请输入 1 至 ${doc.pageCount} 之间的有效页段。');
    }
    return (first, last);
  }

  Future<void> _execute(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() {
          _notice = error is StateError
              ? error.message
              : error is FormatException
              ? error.message
              : '$error';
          _noticeTone = CalloutTone.warning;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<List<MaterialResult>?> _run(PreparedMaterialWork prepared) async {
    if (!mounted) {
      await prepared.close();
      return null;
    }
    final result = await showMaterialWork(context, study, prepared);
    if (result == null || !mounted) return result;
    setState(() {
      _lastBatch = result;
      _knownComplete =
          prepared.gaps.isEmpty &&
          result.length == prepared.units.length + prepared.cached.length &&
          result.isNotEmpty &&
          result.every((item) => item.state == 'ready');
      if (prepared.gaps.isNotEmpty) {
        _notice = prepared.gaps.take(5).join('\n');
        _noticeTone = CalloutTone.warning;
      } else if (result.length <
          prepared.units.length + prepared.cached.length) {
        _notice = '部分题目已完成，可用同一范围继续缺项。';
        _noticeTone = CalloutTone.info;
      }
    });
    return result;
  }

  Future<void> _solve({bool selection = false, bool command = false}) =>
      _execute(() async {
        final input = _instruction.text.trim();
        final PreparedMaterialWork prepared;
        if (selection) {
          final region = study.selection;
          final raster = study.raster;
          if (region == null || raster == null) {
            throw StateError('请先在原页点击“框选”框出一道完整题目。');
          }
          final image = await cropPage(raster, region);
          prepared = await work.preparePictureQuestion(
            document: doc,
            settings: study.settings,
            question: input.isEmpty ? '请解这道题，给出步骤、答案和核对结果。' : input,
            png: image,
            region: region,
            page: study.page,
            retryUnknown: _retryUnknown,
          );
        } else {
          final (first, last) = command ? (1, doc.pageCount) : _range();
          final questions = work.exerciseQuestions(doc, first, last);
          final numbered = questions
              .expand((q) => q.sources.map((source) => source.page))
              .toSet();
          prepared = work.prepareExercises(
            doc,
            study.settings,
            questions,
            gaps: [
              if (questions.isEmpty)
                '第 $first–$last 页未检测到明确题号。扫描件请先在原页框选单题求解，或在材料工具中先做 AI 识别。',
              for (var page = first; page <= last; page++)
                if (questions.isNotEmpty && !numbered.contains(page))
                  '第 $page 页没有可关联的题目，请核对是否缺页或跨页。',
            ],
            instruction: input,
            retryUnknown: _retryUnknown,
          );
        }
        final results = await _run(prepared);
        if (results == null || !mounted || !command) return;
        if (input.contains('错题')) {
          final selected = parseRequestedQuestionNumbers(input);
          var count = 0;
          for (final result in results) {
            if (result.hasResult &&
                selected.contains(result.data['number']?.toString())) {
              _archive(result, quiet: true);
              count++;
            }
          }
          if (mounted) {
            setState(() {
              _notice = count > 0
                  ? '已归档 $count 道指定错题到笔记。'
                  : '未找到与指令匹配的题号，可在下方解答卡片中点击“收为错题”。';
              _noticeTone = count > 0 ? CalloutTone.success : CalloutTone.info;
            });
          }
        }
        if (input.toLowerCase().contains('pdf') && _knownComplete) {
          await _writePdf(results, partial: false);
        }
      });

  void _archive(MaterialResult result, {bool quiet = false}) {
    final number = result.data['number']?.toString() ?? '';
    final label = number.isEmpty ? result.label : '第 $number 题';
    final knowledge = (result.data['knowledge'] as List?)?.join('、') ?? '';
    final draft = AnswerNoteDraft(
      answerId: result.key,
      documentId: doc.id,
      question: '${doc.title} · $label',
      label: '错题本',
      sections: [
        AnswerNoteSection(
          '**我的原答** 待补\n\n**错因** 待补'
          '${knowledge.isEmpty ? '' : '\n\n**知识点** $knowledge'}\n\n${result.text}',
          sources: [
            for (final source in result.sources)
              noteEvidence(source, title: doc.title),
          ],
        ),
      ],
    );
    final operation =
        'wrong:${doc.contentHash}:${number.isEmpty ? result.sources.firstOrNull?.id : number}';
    final note =
        widget.notesController?.saveAnswer(draft, operationKey: operation) ??
        study.noteRepository.saveAnswer(draft, operationKey: operation);
    if (quiet || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('已收入错题笔记'),
        action: widget.onOpenNoteInWorkspace == null
            ? null
            : SnackBarAction(
                label: '打开笔记',
                onPressed: () => widget.onOpenNoteInWorkspace!(note.id),
              ),
      ),
    );
  }

  void _addReviewItem(MaterialResult item) {
    final source = item.sources.firstOrNull;
    showCreateOrEditReviewItemDialog(
      context,
      study: study,
      initialObjective: doc.title,
      initialPrompt: item.label,
      initialAnswer: item.text,
      origin: ReviewOrigin(
        id: '',
        itemId: '',
        originKey: 'exercise:${item.key}',
        sourceType: 'document',
        documentId: doc.id,
        documentHash: doc.contentHash,
        documentTitle: doc.title,
        page: source?.page ?? 1,
        snapshotText: item.text,
      ),
    );
  }

  Future<void> _writePdf(
    List<MaterialResult> results, {
    required bool partial,
  }) async {
    final sorted = [...results]
      ..sort((a, b) {
        final aPage = a.sources.firstOrNull?.page ?? 0;
        final bPage = b.sources.firstOrNull?.page ?? 0;
        if (aPage != bPage) return aPage.compareTo(bPage);
        final aNum = int.tryParse(a.data['number']?.toString() ?? '') ?? 0;
        final bNum = int.tryParse(b.data['number']?.toString() ?? '') ?? 0;
        return aNum.compareTo(bNum);
      });
    final pdf = await SolutionPdf(study.documents).save(
      doc,
      sorted,
      entryId: widget.sourceEntryId,
      partial: partial,
    );
    if (mounted) {
      setState(() {
        _export = pdf;
        _notice = '解答 PDF 已保存到原资料所在位置。';
        _noticeTone = CalloutTone.success;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final pages = study.store.getPages(doc.id);
    final readyPages = pages.where((p) => p.status == PageStatus.ready).length;
    final currentPage = study.page.clamp(1, doc.pageCount);
    final pageQuestions = work.exerciseQuestions(doc, currentPage, currentPage);
    final results = work.results(doc, MaterialAction.exercise);
    final solvedCount = results.where((r) => r.state == 'ready').length;
    final verifyCount = results.where((r) => r.state == 'verify').length;
    final failedCount = results
        .where((r) => r.state == 'failed' || r.state == 'unknown')
        .length;
    final output =
        _lastBatch?.where((item) => item.hasResult).toList() ??
        results.where((item) => item.hasResult).toList();
    final hasSelection = study.selection != null;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      children: [
        // 1. Overview & status card
        Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          decoration: BoxDecoration(
            color: c.sidebar,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.outline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  AccentIcon(
                    icon: QIcons.review,
                    accent: c.blueAccent,
                    size: 26,
                    iconSize: IconSizes.sm,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('试题进度', style: context.texts.titleSmall),
                  ),
                  AppBadge(label: '已解 $solvedCount', dense: true),
                  if (verifyCount > 0) ...[
                    const SizedBox(width: 5),
                    AppBadge(
                      label: '待核对 $verifyCount',
                      tone: BadgeTone.warm,
                      dense: true,
                    ),
                  ],
                  if (failedCount > 0) ...[
                    const SizedBox(width: 5),
                    AppBadge(
                      label: '失败 $failedCount',
                      tone: BadgeTone.danger,
                      dense: true,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '本地可读 $readyPages / ${doc.pageCount} 页 · 第 $currentPage 页检测到 ${pageQuestions.length} 道题',
                style: context.texts.bodySmall!.copyWith(
                  fontSize: 12.5,
                  fontFeatures: AppNumerals.tabular,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: QIcon(
                      hasSelection ? QIcons.success : QIcons.region,
                      size: IconSizes.sm,
                      color: hasSelection ? c.primary : c.inkMuted,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      hasSelection
                          ? '已框选第 $currentPage 页区域，可直接点击“框选求解”。'
                          : '扫描件或复杂图形题可先点击页面底部“框选”，框出单题直接求解。',
                      style: context.texts.bodySmall!.copyWith(
                        fontSize: 12.5,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: Space.md),

        // 2. Solving controls card
        Container(
          padding: const EdgeInsets.symmetric(vertical: Space.md),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: c.outline)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  AccentIcon(
                    icon: QIcons.ai,
                    accent: c.violetAccent,
                    size: 26,
                    iconSize: IconSizes.sm,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('求解与整理', style: context.texts.titleSmall),
                  ),
                  if (widget.onOpenMaterialTools != null)
                    TextButton.icon(
                      onPressed: _busy ? null : widget.onOpenMaterialTools,
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 32),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        textStyle: context.texts.bodySmall!.copyWith(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      icon: const QIcon(QIcons.ocr, size: IconSizes.sm),
                      label: const Text('AI 识别'),
                    ),
                ],
              ),
              const SizedBox(height: Space.sm),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _start,
                      enabled: !_busy,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '起始页',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _end,
                      enabled: !_busy,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: '结束页（共 ${doc.pageCount}）',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () {
                                final p = currentPage.toString();
                                _start.text = p;
                                _end.text = p;
                              },
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 28),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('本页'),
                      ),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () {
                                _start.text = '1';
                                _end.text = '${doc.pageCount}';
                              },
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 28),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('全卷'),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: _instruction,
                enabled: !_busy,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '解题要求或指令（可选）',
                  hintText: '例如：解完这份作业，把第 3、7 题收进错题本，生成解答 PDF',
                  isDense: true,
                ),
              ),
              const SizedBox(height: Space.md),
              if (_busy) ...[
                const LinearProgressIndicator(minHeight: 2),
                const SizedBox(height: Space.sm),
              ],
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (hasSelection)
                    FilledButton.icon(
                      onPressed: _busy || study.raster == null
                          ? null
                          : () => _solve(selection: true),
                      icon: const QIcon(QIcons.region, size: IconSizes.sm),
                      label: const Text('框选求解'),
                    )
                  else
                    FilledButton.icon(
                      onPressed: _busy ? null : () => _solve(),
                      icon: const QIcon(QIcons.ai, size: IconSizes.sm),
                      label: const Text('解答页段'),
                    ),
                  if (hasSelection)
                    OutlinedButton(
                      onPressed: _busy ? null : () => _solve(),
                      child: const Text('解答页段'),
                    )
                  else
                    OutlinedButton.icon(
                      onPressed: null,
                      icon: const QIcon(QIcons.region, size: IconSizes.sm),
                      label: const Text('框选求解'),
                    ),
                  OutlinedButton(
                    onPressed: _busy ? null : () => _solve(command: true),
                    child: const Text('处理整份作业'),
                  ),
                  if (output.isNotEmpty)
                    OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _execute(
                              () =>
                                  _writePdf(output, partial: !_knownComplete),
                            ),
                      icon: const QIcon(QIcons.download, size: IconSizes.sm),
                      label: Text(_knownComplete ? '生成解答 PDF' : '保存部分解答 PDF'),
                    ),
                ],
              ),
              if (results.any((item) => item.state == 'unknown')) ...[
                const SizedBox(height: Space.xs),
                CheckboxListTile(
                  value: _retryUnknown,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  onChanged: _busy
                      ? null
                      : (value) =>
                          setState(() => _retryUnknown = value == true),
                  title: const Text('已核对账单，允许重试受理状态未知的项'),
                ),
              ],
              if (_notice != null) ...[
                const SizedBox(height: Space.sm),
                AppCallout(
                  tone: _noticeTone,
                  message: _notice!,
                  onDismiss: () => setState(() => _notice = null),
                ),
              ],
              if (_export case final pdf?) ...[
                const SizedBox(height: Space.sm),
                AppCallout(
                  tone: CalloutTone.success,
                  title: '解答 PDF 已生成',
                  message: pdf.title,
                  action: FilledButton.tonal(
                    onPressed: () => study.open(pdf),
                    child: const Text('打开解答 PDF'),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: Space.md),

        // 3. Solved results list
        Row(
          children: [
            Text(
              '已解答题目',
              style: context.texts.titleSmall,
            ),
            const SizedBox(width: 6),
            Text(
              '${results.length}',
              style: context.texts.bodySmall!.copyWith(
                fontFeatures: AppNumerals.tabular,
              ),
            ),
          ],
        ),
        const SizedBox(height: Space.sm),
        if (results.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: Space.md),
            child: EmptyState(
              compact: true,
              icon: QIcons.review,
              title: '还没有试题解答',
              message: '在原页框选一道题即可直接求解，或点击“解答页段 / 处理整份作业”批量解答。',
            ),
          )
        else
          for (final result in results.take(200)) ...[
            MaterialResultView(
              study: study,
              document: doc,
              action: MaterialAction.exercise,
              result: result,
              onJump: widget.onJump,
              notes: widget.notesController,
              openNote: widget.onOpenNoteInWorkspace,
              onArchive: () => _execute(() async => _archive(result)),
              onReview: () => _addReviewItem(result),
            ),
            const SizedBox(height: Space.sm),
          ],
      ],
    );
  }
}
