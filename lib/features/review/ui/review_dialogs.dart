import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../app_controller.dart';
import '../../../core/models.dart';
import '../../../services/ai_gateway.dart';
import '../../../ui/dialogs/app_dialogs.dart';
import '../../../ui/theme/tokens.dart';
import '../../../ui/widgets/app_dialog.dart';
import '../../../ui/widgets/app_surfaces.dart';
import '../../schedule/data/schedule_repository.dart';
import '../../schedule/models/local_date.dart';
import '../../schedule/models/study_plan.dart';
import '../models/review_models.dart';
import '../review_controller.dart';
import '../services/study_time.dart';

Future<ReviewItem?> showCreateOrEditReviewItemDialog(
  BuildContext context, {
  required StudyController study,
  ReviewItem? existing,
  String? initialObjective,
  String? initialPrompt,
  String? initialAnswer,
  String? initialHint,
  String? initialExplanation,
  ReviewItemKind initialKind = ReviewItemKind.concept,
  ReviewOrigin? origin,
  List<String> initialPlanIds = const [],
}) => showAppDialog<ReviewItem>(
  context: context,
  builder: (context) => _CreateOrEditReviewItemDialog(
    study: study,
    existing: existing,
    initialObjective: initialObjective,
    initialPrompt: initialPrompt,
    initialAnswer: initialAnswer,
    initialHint: initialHint,
    initialExplanation: initialExplanation,
    initialKind: initialKind,
    origin: origin,
    initialPlanIds: initialPlanIds,
  ),
);

class _CreateOrEditReviewItemDialog extends StatefulWidget {
  const _CreateOrEditReviewItemDialog({
    required this.study,
    this.existing,
    this.initialObjective,
    this.initialPrompt,
    this.initialAnswer,
    this.initialHint,
    this.initialExplanation,
    this.initialKind = ReviewItemKind.concept,
    this.origin,
    this.initialPlanIds = const [],
  });

  final StudyController study;
  final ReviewItem? existing;
  final String? initialObjective;
  final String? initialPrompt;
  final String? initialAnswer;
  final String? initialHint;
  final String? initialExplanation;
  final ReviewItemKind initialKind;
  final ReviewOrigin? origin;
  final List<String> initialPlanIds;

  @override
  State<_CreateOrEditReviewItemDialog> createState() =>
      _CreateOrEditReviewItemDialogState();
}

class _CreateOrEditReviewItemDialogState
    extends State<_CreateOrEditReviewItemDialog> {
  static const _uuid = Uuid();
  late final TextEditingController _objective;
  late final TextEditingController _prompt;
  late final TextEditingController _answer;
  late final TextEditingController _hint;
  late final TextEditingController _explanation;
  late final TextEditingController _steps;
  late final TextEditingController _blanks;

  late ReviewItemKind _kind;
  late List<ReviewOcclusionRect> _rects;
  String? _imagePath;
  bool _typoPreserveSchedule = true;
  bool _createNewSuccessor = false;
  String? _error;
  bool _saving = false;
  Offset? _dragStart;
  Offset? _dragCurrent;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _kind = e?.kind ?? widget.initialKind;
    _objective = TextEditingController(
      text: e?.objective ?? widget.initialObjective ?? '',
    );
    _prompt = TextEditingController(
      text: e?.prompt ?? widget.initialPrompt ?? '',
    );
    _answer = TextEditingController(
      text: e?.answer ?? widget.initialAnswer ?? '',
    );
    _hint = TextEditingController(text: e?.hint ?? widget.initialHint ?? '');
    _explanation = TextEditingController(
      text: e?.explanation ?? widget.initialExplanation ?? '',
    );
    _steps = TextEditingController(text: (e?.steps ?? const []).join('\n'));
    _blanks = TextEditingController(
      text: (e?.blankAnswers ?? const []).join('；'),
    );
    _rects = List<ReviewOcclusionRect>.from(e?.occlusionRects ?? const []);
    _imagePath = e?.imagePath;
  }

  @override
  void dispose() {
    _objective.dispose();
    _prompt.dispose();
    _answer.dispose();
    _hint.dispose();
    _explanation.dispose();
    _steps.dispose();
    _blanks.dispose();
    super.dispose();
  }

  Future<void> _pickOcclusionImage() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      dialogTitle: '选择要制作图片遮挡的图片',
    );
    final srcPath = result?.files.singleOrNull?.path;
    if (srcPath == null || srcPath.isEmpty) return;
    final srcFile = File(srcPath);
    if (!await srcFile.exists()) return;
    final assetsDir = Directory(
      p.join(widget.study.documents.directory.path, 'review_assets'),
    );
    await assetsDir.create(recursive: true);
    final ext = p.extension(srcPath).toLowerCase();
    final destPath = p.join(assetsDir.path, '${_uuid.v4()}$ext');
    await srcFile.copy(destPath);
    if (!mounted) return;
    setState(() {
      _imagePath = destPath;
      _error = null;
    });
  }

  List<String> _resolveBlankAnswers(String promptText, String blanksText) {
    final explicit = blanksText
        .split(RegExp(r'[；;\n]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (explicit.isNotEmpty) return explicit;
    final regex = RegExp(r'\{\{(.+?)\}\}');
    return [
      for (final match in regex.allMatches(promptText))
        if ((match.group(1) ?? '').trim().isNotEmpty) match.group(1)!.trim(),
    ];
  }

  void _save() {
    if (_saving) return;
    final prompt = _prompt.text.trim();
    if (prompt.isEmpty) {
      setState(() => _error = '请填写题目或回忆提示。');
      return;
    }
    if (_kind == ReviewItemKind.occlusion &&
        (_imagePath == null || _rects.isEmpty)) {
      setState(() => _error = '图片遮挡题需要选择图片并在图上框选至少一处遮挡区域。');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final objective = _objective.text.trim();
      final blankAnswers = _kind == ReviewItemKind.blank
          ? _resolveBlankAnswers(prompt, _blanks.text)
          : const <String>[];
      var answer = _answer.text.trim();
      if (answer.isEmpty && blankAnswers.isNotEmpty) {
        answer = blankAnswers.join(' / ');
      }
      final steps = _steps.text
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      final hint = _hint.text.trim();
      final explanation = _explanation.text.trim();

      if (_isEditing) {
        final updated = widget.study.reviewRepository.updateItemContent(
          itemId: widget.existing!.id,
          objective: objective,
          prompt: prompt,
          answer: answer,
          steps: steps,
          hint: hint,
          explanation: explanation,
          preserveScheduleOnTypo: _typoPreserveSchedule,
          createNewSuccessorOnSubstantiveChange: _createNewSuccessor,
        );
        widget.study.reviewController.refresh();
        Navigator.pop(context, updated);
        return;
      }

      final created = widget.study.reviewController.createManualItem(
        kind: _kind,
        objective: objective,
        prompt: prompt,
        answer: answer,
        steps: steps,
        hint: hint,
        explanation: explanation,
        blankAnswers: blankAnswers,
        imagePath: _imagePath,
        occlusionRects: _rects,
        origin: widget.origin,
        planIds: widget.initialPlanIds,
      );
      Navigator.pop(context, created);
    } catch (e) {
      setState(() {
        _saving = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppDialog(
      title: _isEditing ? '编辑复习题' : '新建复习题',
      subtitle: _isEditing
          ? '支持勘误保留原间隔，或拆出新版本重学。'
          : '支持概念、{{填空}}、遮挡与推导题，本地保存。',
      icon: _isEditing ? QIcons.edit : QIcons.add,
      maxWidth: 640,
      actions: [
        DialogActions.cancel(context),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_isEditing ? '保存修改' : '加入复习'),
        ),
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) ...[
            AppCallout(tone: CalloutTone.error, message: _error!),
            const SizedBox(height: Space.md),
          ],
          if (!_isEditing) ...[
            Text('题型', style: context.texts.labelLarge),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final kind in ReviewItemKind.values)
                  ChoiceChip(
                    label: Text(kind.label),
                    selected: _kind == kind,
                    onSelected: (_) => setState(() => _kind = kind),
                  ),
              ],
            ),
            const SizedBox(height: Space.md),
          ],
          TextField(
            controller: _objective,
            decoration: const InputDecoration(
              labelText: '所属学习目标 / 章节主题（可选）',
              hintText: '例如：极限存在准则 / 牛顿-莱布尼茨公式',
            ),
          ),
          const SizedBox(height: Space.md),
          TextField(
            controller: _prompt,
            maxLines: 3,
            decoration: InputDecoration(
              labelText: _kind == ReviewItemKind.blank
                  ? '题干（用 {{答案}} 标记挖空）'
                  : '题干 / 回忆提示',
              hintText: _kind == ReviewItemKind.blank
                  ? '例如：夹逼准则要求两边极限 {{存在}} 且 {{相等}}。'
                  : '简述需要独立回忆的核心问题或条件',
            ),
          ),
          if (_kind == ReviewItemKind.blank) ...[
            const SizedBox(height: Space.md),
            TextField(
              controller: _blanks,
              decoration: const InputDecoration(
                labelText: '标准答案（分号分隔；留空自动提取 {{...}}）',
                hintText: '存在；相等',
              ),
            ),
          ],
          if (_kind == ReviewItemKind.occlusion) ...[
            const SizedBox(height: Space.md),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _pickOcclusionImage,
                  icon: const QIcon(QIcons.region, size: IconSizes.sm),
                  label: Text(_imagePath == null ? '选择图片' : '更换图片'),
                ),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: Text(
                    _rects.isEmpty
                        ? '在图上拖拽框选遮挡区域。'
                        : '已选 ${_rects.length} 处遮挡（点击可移除）',
                    style: context.texts.bodySmall,
                  ),
                ),
              ],
            ),
            if (_imagePath != null && File(_imagePath!).existsSync()) ...[
              const SizedBox(height: Space.sm),
              LayoutBuilder(
                builder: (context, constraints) {
                  final boxW = constraints.maxWidth;
                  final boxH = 220.0;
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(Radii.sm),
                    child: SizedBox(
                      width: boxW,
                      height: boxH,
                      child: GestureDetector(
                        onPanStart: (details) => setState(() {
                          _dragStart = details.localPosition;
                          _dragCurrent = details.localPosition;
                        }),
                        onPanUpdate: (details) => setState(() {
                          _dragCurrent = details.localPosition;
                        }),
                        onPanEnd: (_) {
                          final a = _dragStart;
                          final b = _dragCurrent;
                          if (a != null && b != null) {
                            final left =
                                (a.dx < b.dx ? a.dx : b.dx).clamp(0.0, boxW) /
                                boxW;
                            final top =
                                (a.dy < b.dy ? a.dy : b.dy).clamp(0.0, boxH) /
                                boxH;
                            final right =
                                (a.dx > b.dx ? a.dx : b.dx).clamp(0.0, boxW) /
                                boxW;
                            final bottom =
                                (a.dy > b.dy ? a.dy : b.dy).clamp(0.0, boxH) /
                                boxH;
                            if ((right - left) > 0.03 &&
                                (bottom - top) > 0.03) {
                              _rects.add(
                                ReviewOcclusionRect(
                                  id: _uuid.v4(),
                                  left: left,
                                  top: top,
                                  width: right - left,
                                  height: bottom - top,
                                ),
                              );
                            }
                          }
                          setState(() {
                            _dragStart = null;
                            _dragCurrent = null;
                          });
                        },
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.file(
                              File(_imagePath!),
                              fit: BoxFit.contain,
                            ),
                            for (var i = 0; i < _rects.length; i++)
                              Positioned(
                                left: _rects[i].left * boxW,
                                top: _rects[i].top * boxH,
                                width: _rects[i].width * boxW,
                                height: _rects[i].height * boxH,
                                child: GestureDetector(
                                  onTap: () =>
                                      setState(() => _rects.removeAt(i)),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: c.primary.withValues(alpha: 0.78),
                                      border: Border.all(
                                        color: c.onPrimary,
                                        width: 1.5,
                                      ),
                                    ),
                                    alignment: Alignment.center,
                                    child: Text(
                                      '遮挡 ${i + 1} ×',
                                      style: context.texts.labelSmall!.copyWith(
                                        color: c.onPrimary,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            if (_dragStart != null && _dragCurrent != null)
                              Positioned(
                                left: _dragStart!.dx < _dragCurrent!.dx
                                    ? _dragStart!.dx
                                    : _dragCurrent!.dx,
                                top: _dragStart!.dy < _dragCurrent!.dy
                                    ? _dragStart!.dy
                                    : _dragCurrent!.dy,
                                width: (_dragStart!.dx - _dragCurrent!.dx).abs(),
                                height:
                                    (_dragStart!.dy - _dragCurrent!.dy).abs(),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: c.blue.withValues(alpha: 0.35),
                                    border: Border.all(color: c.blue, width: 2),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ],
          const SizedBox(height: Space.md),
          TextField(
            controller: _answer,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: '参考答案 / 核心要点',
              hintText: '填写需要对照核验的关键结论',
            ),
          ),
          if (_kind == ReviewItemKind.problem ||
              _kind == ReviewItemKind.application) ...[
            const SizedBox(height: Space.md),
            TextField(
              controller: _steps,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '分步检查要点（每行一步）',
                hintText: '步骤 1：验证初始条件\n步骤 2：推导递推关系',
              ),
            ),
          ],
          const SizedBox(height: Space.md),
          TextField(
            controller: _hint,
            decoration: const InputDecoration(
              labelText: '助记提示（可选，答题时点击显示）',
            ),
          ),
          const SizedBox(height: Space.md),
          TextField(
            controller: _explanation,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: '解析与出处补充（可选）',
            ),
          ),
          if (_isEditing) ...[
            const SizedBox(height: Space.md),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('仅勘误文本（保留现有间隔）'),
              subtitle: const Text('关闭则拆出新版本并重新调度。'),
              value: _typoPreserveSchedule,
              onChanged: (v) => setState(() {
                _typoPreserveSchedule = v;
                if (v) _createNewSuccessor = false;
              }),
            ),
            if (!_typoPreserveSchedule)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('归档旧卡并新建独立复习卡'),
                value: _createNewSuccessor,
                onChanged: (v) =>
                    setState(() => _createNewSuccessor = v ?? false),
              ),
          ],
        ],
      ),
    );
  }
}

Future<List<ReviewItem>> showGenerateReviewDraftDialog(
  BuildContext context, {
  required StudyController study,
  DocumentRecord? initialDocument,
  String initialObjective = '',
  int? initialPage,
  String initialNoteText = '',
  String? noteId,
  int? noteRevision,
}) async {
  final result = await showAppDialog<List<ReviewItem>>(
    context: context,
    builder: (context) => _GenerateDraftDialog(
      study: study,
      initialDocument: initialDocument,
      initialObjective: initialObjective,
      initialPage: initialPage,
      initialNoteText: initialNoteText,
      noteId: noteId,
      noteRevision: noteRevision,
    ),
  );
  return result ?? const [];
}

class _GenerateDraftDialog extends StatefulWidget {
  const _GenerateDraftDialog({
    required this.study,
    this.initialDocument,
    required this.initialObjective,
    this.initialPage,
    required this.initialNoteText,
    this.noteId,
    this.noteRevision,
  });

  final StudyController study;
  final DocumentRecord? initialDocument;
  final String initialObjective;
  final int? initialPage;
  final String initialNoteText;
  final String? noteId;
  final int? noteRevision;

  @override
  State<_GenerateDraftDialog> createState() => _GenerateDraftDialogState();
}

class _GenerateDraftDialogState extends State<_GenerateDraftDialog> {
  late final TextEditingController _objective;
  late ReviewItemKind _kind = ReviewItemKind.concept;
  int _count = 3;
  bool _generating = false;
  String? _error;
  List<AiQuestionDraft> _drafts = const [];
  final Set<int> _selectedIndices = {};

  @override
  void initState() {
    super.initState();
    _objective = TextEditingController(text: widget.initialObjective);
  }

  @override
  void dispose() {
    _objective.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final objective = _objective.text.trim();
    if (objective.isEmpty) {
      setState(() => _error = '先填写一个明确的知识点或学习目标。');
      return;
    }
    setState(() {
      _generating = true;
      _error = null;
    });
    try {
      final doc = widget.initialDocument ?? widget.study.current;
      final evidenceList = <AiEvidence>[];
      final byPage = <int, AiEvidence>{};
      if (doc != null) {
        final page = widget.initialPage ?? widget.study.page;
        final pages = widget.study.store.getPages(doc.id);
        for (final pRec in pages) {
          if (pRec.page >= page - 1 && pRec.page <= page + 2) {
            final text = pRec.text.trim();
            if (text.isNotEmpty) {
              final ev = AiEvidence(
                id: 'draft-${doc.id}-p${pRec.page}',
                documentId: doc.id,
                documentHash: doc.contentHash,
                page: pRec.page,
                text: text,
              );
              evidenceList.add(ev);
              byPage[pRec.page] = ev;
            }
          }
        }
      }
      final prepared = widget.study.reviewAi.prepareQuestionDrafts(
        settings: widget.study.settings,
        objective: objective,
        kind: _kind,
        count: _count,
        evidence: evidenceList,
        sourceNoteText: widget.initialNoteText,
      );
      if (!mounted) return;
      final action = await showRequestPreview(
        context,
        request: prepared,
        wholePage: true,
      );
      if (action != 'send' || !mounted) {
        setState(() => _generating = false);
        return;
      }
      final response = await widget.study.gateway.send(prepared);
      if (!mounted) return;
      final parsed = widget.study.reviewAi.parseAndValidateDrafts(
        response.answer,
        evidenceByPage: byPage,
      );
      setState(() {
        _generating = false;
        _drafts = parsed;
        _selectedIndices
          ..clear()
          ..addAll(List.generate(parsed.length, (i) => i));
        if (parsed.isEmpty) {
          _error = 'AI 返回结果未包含可用题目草案，可调整提示后重试或改用手动建题。';
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _generating = false;
          _error = '$e';
        });
      }
    }
  }

  void _acceptSelected() {
    final created = <ReviewItem>[];
    final doc = widget.initialDocument ?? widget.study.current;
    for (var i = 0; i < _drafts.length; i++) {
      if (!_selectedIndices.contains(i)) continue;
      final d = _drafts[i];
      if (!d.isValid) continue;
      final sourcePage = d.sourcePage ?? widget.initialPage;
      final origin = ReviewOrigin(
        id: '',
        itemId: '',
        originKey:
            'draft:${widget.noteId ?? doc?.id ?? 'manual'}:p${sourcePage ?? 0}:${const Uuid().v4()}',
        sourceType: widget.noteId != null
            ? 'note'
            : (d.sourceDocumentId != null ? 'document' : 'manual'),
        documentId: d.sourceDocumentId ?? doc?.id,
        documentHash: d.sourceDocumentHash.isNotEmpty
            ? d.sourceDocumentHash
            : (doc?.contentHash ?? ''),
        documentTitle: doc?.title ?? '',
        page: sourcePage,
        noteId: widget.noteId,
        noteRevision: widget.noteRevision,
        snapshotText: d.sourceExcerpt,
        sourceAvailable: true,
      );
      created.add(
        widget.study.reviewController.createManualItem(
          kind: d.kind,
          objective: d.objective.isEmpty ? _objective.text.trim() : d.objective,
          prompt: d.prompt,
          answer: d.answer,
          hint: d.hint,
          explanation: d.explanation,
          steps: d.steps,
          origin: origin,
        ),
      );
    }
    Navigator.pop(context, created);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppDialog(
      title: 'AI 生成复习题草案',
      subtitle: '生成前先确认内容，勾选审核后才加入复习池。',
      icon: QIcons.ai,
      accent: c.violetAccent,
      maxWidth: 660,
      actions: [
        DialogActions.cancel(context),
        if (_drafts.isEmpty)
          FilledButton.icon(
            onPressed: _generating ? null : _generate,
            icon: const QIcon(QIcons.ai, size: IconSizes.sm),
            label: Text(_generating ? '生成中…' : '预览并生成'),
          )
        else ...[
          OutlinedButton(
            onPressed: _generating ? null : _generate,
            child: const Text('重新生成'),
          ),
          FilledButton(
            onPressed: _selectedIndices.isEmpty ? null : _acceptSelected,
            child: Text('加入选中题目 (${_selectedIndices.length})'),
          ),
        ],
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) ...[
            AppCallout(tone: CalloutTone.warning, message: _error!),
            const SizedBox(height: Space.md),
          ],
          TextField(
            controller: _objective,
            decoration: const InputDecoration(
              labelText: '学习目标 / 核心知识点',
              hintText: '输入希望围绕出题的概念或公式主题',
            ),
          ),
          const SizedBox(height: Space.md),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('题型：', style: context.texts.bodySmall),
              for (final k in ReviewItemKind.values)
                ChoiceChip(
                  label: Text(k.label),
                  selected: _kind == k,
                  onSelected: (_) => setState(() => _kind = k),
                ),
              const SizedBox(width: 8),
              DropdownButton<int>(
                value: _count,
                items: const [
                  DropdownMenuItem(value: 1, child: Text('1 题')),
                  DropdownMenuItem(value: 2, child: Text('2 题')),
                  DropdownMenuItem(value: 3, child: Text('3 题')),
                  DropdownMenuItem(value: 5, child: Text('5 题')),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _count = v);
                },
              ),
            ],
          ),
          if (_drafts.isNotEmpty) ...[
            const SizedBox(height: Space.lg),
            Text('生成的草案（勾选并确认）：', style: context.texts.titleSmall),
            const SizedBox(height: Space.sm),
            for (var i = 0; i < _drafts.length; i++) ...[
              _DraftPreviewTile(
                draft: _drafts[i],
                selected: _selectedIndices.contains(i),
                onToggle: _drafts[i].isValid
                    ? (checked) => setState(() {
                        if (checked) {
                          _selectedIndices.add(i);
                        } else {
                          _selectedIndices.remove(i);
                        }
                      })
                    : null,
              ),
              const SizedBox(height: Space.sm),
            ],
          ],
        ],
      ),
    );
  }
}

class _DraftPreviewTile extends StatelessWidget {
  const _DraftPreviewTile({
    required this.draft,
    required this.selected,
    required this.onToggle,
  });

  final AiQuestionDraft draft;
  final bool selected;
  final ValueChanged<bool>? onToggle;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      padding: const EdgeInsets.all(Space.md),
      background: draft.isValid ? c.surface : c.dangerTint,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Checkbox(
                value: draft.isValid && selected,
                onChanged: onToggle == null
                    ? null
                    : (v) => onToggle!(v ?? false),
              ),
              AppBadge(label: draft.kind.label, dense: true),
              if (draft.sourcePage != null) ...[
                const SizedBox(width: 6),
                AppBadge(
                  label: '第 ${draft.sourcePage} 页',
                  tone: BadgeTone.blue,
                  dense: true,
                ),
              ],
              if (!draft.isValid) ...[
                const SizedBox(width: 6),
                AppBadge(
                  label: draft.validationErrors.join('；'),
                  tone: BadgeTone.danger,
                  dense: true,
                ),
              ],
            ],
          ),
          Text(
            draft.prompt,
            style: context.texts.bodyMedium!.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text('参考答案：${draft.answer}', style: context.texts.bodySmall),
        ],
      ),
    );
  }
}

Future<bool> showCandidateAcceptDialog(
  BuildContext context, {
  required ReviewController controller,
  required ReviewCandidate candidate,
}) async {
  final saved = await showAppDialog<bool>(
    context: context,
    builder: (context) => _CandidateAcceptDialog(
      controller: controller,
      candidate: candidate,
    ),
  );
  return saved == true;
}

class _CandidateAcceptDialog extends StatefulWidget {
  const _CandidateAcceptDialog({
    required this.controller,
    required this.candidate,
  });

  final ReviewController controller;
  final ReviewCandidate candidate;

  @override
  State<_CandidateAcceptDialog> createState() => _CandidateAcceptDialogState();
}

class _CandidateAcceptDialogState extends State<_CandidateAcceptDialog> {
  late final TextEditingController _objective;
  late final TextEditingController _prompt;
  late final TextEditingController _answer;
  late ReviewItemKind _kind;

  @override
  void initState() {
    super.initState();
    _objective = TextEditingController(text: widget.candidate.title);
    _prompt = TextEditingController(text: widget.candidate.prompt);
    _answer = TextEditingController(text: widget.candidate.answer);
    _kind = widget.candidate.kind;
  }

  @override
  void dispose() {
    _objective.dispose();
    _prompt.dispose();
    _answer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    title: '编辑并加入正式复习',
    subtitle: '可先精炼题干与答案，再加入复习队列。',
    icon: QIcons.review,
    maxWidth: 560,
    actions: [
      DialogActions.cancel(context),
      FilledButton(
        onPressed: () {
          widget.controller.repository.acceptCandidate(
            widget.candidate.id,
            objective: _objective.text.trim(),
            prompt: _prompt.text.trim(),
            answer: _answer.text.trim(),
            kind: _kind,
          );
          widget.controller.refresh();
          Navigator.pop(context, true);
        },
        child: const Text('确认加入复习'),
      ),
    ],
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final k in ReviewItemKind.values)
              ChoiceChip(
                label: Text(k.label),
                selected: _kind == k,
                onSelected: (_) => setState(() => _kind = k),
              ),
          ],
        ),
        const SizedBox(height: Space.md),
        TextField(
          controller: _objective,
          decoration: const InputDecoration(labelText: '学习目标 / 标题'),
        ),
        const SizedBox(height: Space.md),
        TextField(
          controller: _prompt,
          maxLines: 3,
          decoration: const InputDecoration(labelText: '题干'),
        ),
        const SizedBox(height: Space.md),
        TextField(
          controller: _answer,
          maxLines: 3,
          decoration: const InputDecoration(labelText: '参考答案'),
        ),
      ],
    ),
  );
}

Future<bool> showResolveCheckDialog(
  BuildContext context, {
  required ReviewController controller,
  required ReviewCheck check,
}) async {
  final saved = await showAppDialog<bool>(
    context: context,
    builder: (context) => _ResolveCheckDialog(
      controller: controller,
      check: check,
    ),
  );
  return saved == true;
}

class _ResolveCheckDialog extends StatefulWidget {
  const _ResolveCheckDialog({
    required this.controller,
    required this.check,
  });

  final ReviewController controller;
  final ReviewCheck check;

  @override
  State<_ResolveCheckDialog> createState() => _ResolveCheckDialogState();
}

class _ResolveCheckDialogState extends State<_ResolveCheckDialog> {
  final _note = TextEditingController();
  final _updatedAnswer = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    _updatedAnswer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final chk = widget.check;
    return AppDialog(
      title: '核对争议 / 反馈',
      subtitle: '${chk.targetType.label} · ${chk.reason}',
      icon: QIcons.verify,
      maxWidth: 560,
      actions: [
        DialogActions.cancel(context),
        OutlinedButton(
          onPressed: () {
            widget.controller.resolveCheck(
              chk.id,
              status: ReviewCheckStatus.dismissed,
              resolutionNote: _note.text.trim(),
            );
            Navigator.pop(context, true);
          },
          child: const Text('确认无需修改'),
        ),
        FilledButton(
          onPressed: () {
            final ans = _updatedAnswer.text.trim();
            widget.controller.resolveCheck(
              chk.id,
              status: ReviewCheckStatus.resolved,
              resolutionNote: _note.text.trim(),
              updatedAnswer: ans.isEmpty ? null : ans,
            );
            Navigator.pop(context, true);
          },
          child: const Text('完成核对'),
        ),
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (chk.question.isNotEmpty) ...[
            Text('关联题目', style: context.texts.labelMedium),
            const SizedBox(height: 4),
            SelectableText(chk.question, style: context.texts.bodyMedium),
            const SizedBox(height: Space.sm),
          ],
          if (chk.answer.isNotEmpty) ...[
            Text('作答内容', style: context.texts.labelMedium),
            const SizedBox(height: 4),
            SelectableText(chk.answer, style: context.texts.bodySmall),
            const SizedBox(height: Space.sm),
          ],
          if (chk.feedback.isNotEmpty) ...[
            Text('待核对评语', style: context.texts.labelMedium),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(Space.sm),
              decoration: BoxDecoration(
                color: c.warmTint,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: SelectableText(
                chk.feedback,
                style: context.texts.bodySmall,
              ),
            ),
            const SizedBox(height: Space.md),
          ],
          if (chk.itemId != null) ...[
            TextField(
              controller: _updatedAnswer,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: '顺便修订参考答案（可选，保留复习间隔）',
              ),
            ),
            const SizedBox(height: Space.md),
          ],
          TextField(
            controller: _note,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: '核对结论说明（可选）',
              hintText: '例如：已回看教材第 42 页确认边界条件正确',
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> showScheduleReviewBatchDialog(
  BuildContext context, {
  required StudyController study,
}) async {
  final plans = ScheduleRepository(study.store)
      .getPlans()
      .where((p) => p.status == PlanStatus.active)
      .toList();
  if (plans.isEmpty) {
    await showAppDialog<void>(
      context: context,
      builder: (context) => AppDialog(
        title: '暂无进行中的学习计划',
        icon: QIcons.schedule,
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
        content: const DialogBodyText(
          '请先在「计划」页启用一份学习计划。',
        ),
      ),
    );
    return;
  }

  await showAppDialog<void>(
    context: context,
    builder: (context) => _ScheduleReviewBatchDialog(study: study, plans: plans),
  );
}

class _ScheduleReviewBatchDialog extends StatefulWidget {
  const _ScheduleReviewBatchDialog({required this.study, required this.plans});
  final StudyController study;
  final List<StudyPlan> plans;

  @override
  State<_ScheduleReviewBatchDialog> createState() =>
      _ScheduleReviewBatchDialogState();
}

class _ScheduleReviewBatchDialogState
    extends State<_ScheduleReviewBatchDialog> {
  late String _planId = widget.plans.first.id;
  late LocalDate _date = StudyTimeHelper.studyDate(
    DateTime.now().toUtc(),
    timezone: widget.study.reviewRepository.getStudyTimezone(),
  );
  int _hour = 19;

  @override
  Widget build(BuildContext context) {
    final c = widget.study.reviewController;
    return AppDialog(
      title: '把复习批次安排到日程',
      subtitle: '占用约 ${c.budgetMinutes} 分钟时段，不改单卡到期日。',
      icon: QIcons.schedule,
      maxWidth: 460,
      actions: [
        DialogActions.cancel(context),
        FilledButton(
          onPressed: () {
            c.scheduleBatchToCalendar(
              planId: _planId,
              date: _date,
              startMinute: _hour * 60,
            );
            Navigator.pop(context);
          },
          child: const Text('确认排期'),
        ),
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String>(
            initialValue: _planId,
            decoration: const InputDecoration(labelText: '关联学习计划'),
            items: [
              for (final plan in widget.plans)
                DropdownMenuItem(value: plan.id, child: Text(plan.title)),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _planId = v);
            },
          ),
          const SizedBox(height: Space.md),
          DropdownButtonFormField<int>(
            initialValue: _hour,
            decoration: const InputDecoration(labelText: '开始时段'),
            items: [
              for (final h in [8, 10, 14, 16, 19, 20, 21])
                DropdownMenuItem(value: h, child: Text('$h:00')),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _hour = v);
            },
          ),
          const SizedBox(height: Space.md),
          Wrap(
            spacing: 6,
            children: [
              ChoiceChip(
                label: Text('今天 (${_date.iso})'),
                selected: true,
                onSelected: (_) {},
              ),
              ActionChip(
                label: const Text('改为明天'),
                onPressed: () => setState(() => _date = _date.addDays(1)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

Future<void> showExportImportReviewDialog(
  BuildContext context, {
  required StudyController study,
}) => showAppDialog<void>(
  context: context,
  builder: (context) => _ExportImportReviewDialog(study: study),
);

class _ExportImportReviewDialog extends StatefulWidget {
  const _ExportImportReviewDialog({required this.study});
  final StudyController study;

  @override
  State<_ExportImportReviewDialog> createState() =>
      _ExportImportReviewDialogState();
}

class _ExportImportReviewDialogState extends State<_ExportImportReviewDialog> {
  String? _status;

  Future<void> _saveFile(String content, String suggestedName) async {
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '导出复习数据',
      fileName: suggestedName,
    );
    if (path == null || path.isEmpty) return;
    await File(path).writeAsString(content);
    if (mounted) {
      setState(() => _status = '已保存到：$path');
    }
  }

  Future<void> _importJsonFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
      dialogTitle: '选择导出的复习 JSON 包',
    );
    final filePath = result?.files.singleOrNull?.path;
    if (filePath == null || filePath.isEmpty) return;
    try {
      final raw = await File(filePath).readAsString();
      final count = widget.study.reviewRepository.importFullPackageJson(raw);
      widget.study.reviewController.refresh();
      if (mounted) {
        setState(() => _status = '已无损导入 $count 道复习项及调度历史。');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _status = '导入失败：$e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final repo = widget.study.reviewRepository;
    return AppDialog(
      title: '导出与备份复习记录',
      subtitle: '支持 Markdown/CSV 错题汇总，及无损 JSON 全量备份。',
      icon: QIcons.download,
      maxWidth: 560,
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_status != null) ...[
            AppCallout(tone: CalloutTone.info, message: _status!),
            const SizedBox(height: Space.md),
          ],
          Wrap(
            spacing: Space.sm,
            runSpacing: Space.sm,
            children: [
              OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: repo.exportMarkdownReport()),
                  );
                  if (mounted) {
                    setState(() => _status = '已复制 Markdown 复盘报告到剪贴板。');
                  }
                },
                icon: const QIcon(QIcons.copy, size: IconSizes.sm),
                label: const Text('复制 Markdown 报告'),
              ),
              OutlinedButton.icon(
                onPressed: () =>
                    _saveFile(repo.exportMarkdownReport(), 'quelyt_review.md'),
                icon: const QIcon(QIcons.download, size: IconSizes.sm),
                label: const Text('导出 Markdown'),
              ),
              OutlinedButton.icon(
                onPressed: () => _saveFile(repo.exportCsv(), 'quelyt_review.csv'),
                icon: const QIcon(QIcons.download, size: IconSizes.sm),
                label: const Text('导出 CSV'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => _saveFile(
                  repo.exportFullPackageJson(),
                  'quelyt_review_package.json',
                ),
                icon: const QIcon(QIcons.download, size: IconSizes.sm),
                label: const Text('全量 JSON 备份'),
              ),
              OutlinedButton.icon(
                onPressed: _importJsonFile,
                icon: const QIcon(QIcons.restore, size: IconSizes.sm),
                label: const Text('从 JSON 恢复/导入'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
