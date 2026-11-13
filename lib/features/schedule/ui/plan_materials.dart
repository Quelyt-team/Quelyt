import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../../core/models.dart';
import '../../../ui/theme/tokens.dart';
import '../../../ui/widgets/app_dialog.dart';
import '../../../ui/widgets/app_surfaces.dart';
import '../data/schedule_repository.dart';
import '../domain/schedule_validator.dart';
import '../models/material_ref.dart';
import '../models/plan_source.dart';
import '../models/study_plan.dart';
import '../schedule_controller.dart';

typedef MaterialPreparer =
    Future<MaterialPreparationResult> Function(PlanSource source);

Future<void> showPlanMaterials(
  BuildContext context,
  ScheduleController controller,
  StudyPlan plan, {
  Future<void> Function(MaterialRef material)? onOpenMaterial,
  MaterialPreparer? onPrepare,
}) => showAppDialog<void>(
  context: context,
  builder: (context) => _PlanMaterialsDialog(
    controller: controller,
    plan: plan,
    onOpenMaterial: onOpenMaterial,
    onPrepare: onPrepare,
  ),
);

class _PlanMaterialsDialog extends StatefulWidget {
  const _PlanMaterialsDialog({
    required this.controller,
    required this.plan,
    required this.onOpenMaterial,
    required this.onPrepare,
  });

  final ScheduleController controller;
  final StudyPlan plan;
  final Future<void> Function(MaterialRef material)? onOpenMaterial;
  final MaterialPreparer? onPrepare;

  @override
  State<_PlanMaterialsDialog> createState() => _PlanMaterialsDialogState();
}

class _PlanMaterialsDialogState extends State<_PlanMaterialsDialog> {
  List<PlanSource> _sources = const [];
  final Map<String, MaterialCoverage> _coverage = {};
  String? _error;
  String? _notice;
  bool _loading = true;
  String? _preparingId;

  ScheduleRepository get repository => widget.controller.repository;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    try {
      final sources = repository.getPlanSources(widget.plan.id);
      final coverage = <String, MaterialCoverage>{
        for (final source in sources) source.id: repository.coverageFor(source),
      };
      setState(() {
        _sources = sources;
        _coverage
          ..clear()
          ..addAll(coverage);
        _loading = false;
        _error = null;
      });
    } catch (error) {
      setState(() {
        _loading = false;
        _error = '$error';
      });
    }
  }

  Future<void> _add() async {
    final documents = widget.controller.store.getDocuments();
    if (documents.isEmpty) {
      setState(() => _error = '书库还没有资料，请先在书库导入教材或试卷。');
      return;
    }
    final source = await showAppDialog<PlanSource>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _AddPlanSourceDialog(
        plan: widget.plan,
        documents: documents,
      ),
    );
    if (source == null || !mounted) return;
    try {
      repository.savePlanSource(source);
      _load();
      setState(() => _notice = '已绑定「${source.documentTitle}」的 ${source.rangeLabel}。');
    } on ScheduleValidationException catch (error) {
      setState(() => _error = error.message);
    } catch (error) {
      setState(() => _error = '绑定失败：$error');
    }
  }

  Future<void> _remove(PlanSource source) async {
    try {
      repository.deletePlanSource(source.id);
      _load();
      setState(() => _notice = '已解除「${source.documentTitle}」的材料引用。');
    } catch (error) {
      setState(() => _error = '解除失败：$error');
    }
  }

  Future<void> _prepare(PlanSource source) async {
    final prepare = widget.onPrepare;
    if (prepare == null || _preparingId != null) return;
    setState(() {
      _preparingId = source.id;
      _error = null;
      _notice = null;
    });
    try {
      final result = await prepare(source);
      if (!mounted) return;
      _load();
      setState(() {
        _notice = result.message.isEmpty
            ? '已处理 ${result.processed} 页。${result.coverage.summary}'
            : result.message;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '补齐材料失败：$error');
    } finally {
      if (mounted) setState(() => _preparingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppDialog(
      title: '教材与材料',
      subtitle: '${widget.plan.title} · 仅已解析页用于知识提取与课程生成。',
      maxWidth: 760,
      actions: [
        TextButton.icon(
          onPressed: _add,
          icon: const QIcon(QIcons.add, size: IconSizes.sm),
          label: const Text('添加材料'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) ...[
            AppCallout(
              tone: CalloutTone.error,
              message: _error!,
              onDismiss: () => setState(() => _error = null),
            ),
            const SizedBox(height: Space.md),
          ],
          if (_notice != null) ...[
            AppCallout(
              tone: CalloutTone.info,
              message: _notice!,
              onDismiss: () => setState(() => _notice = null),
            ),
            const SizedBox(height: Space.md),
          ],
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_sources.isEmpty)
            EmptyState(
              icon: QIcons.textbook,
              title: '还没有绑定材料',
              message: '可先建立时间框架；生成知识点或课程前，再绑定教材/考纲页段。',
              compact: true,
              action: FilledButton.icon(
                onPressed: _add,
                icon: const QIcon(QIcons.add, size: IconSizes.sm),
                label: const Text('添加材料'),
              ),
            )
          else
            for (final source in _sources) ...[
              _sourceCard(context, source, _coverage[source.id]),
              const SizedBox(height: Space.sm),
            ],
          const SizedBox(height: 4),
          Text(
            '删除资料会移除此处引用，日程任务仍保留原名称与页段。',
            style: context.texts.bodySmall!.copyWith(
              fontSize: 11.5,
              color: c.inkMuted,
              height: 1.55,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sourceCard(
    BuildContext context,
    PlanSource source,
    MaterialCoverage? coverage,
  ) {
    final c = context.colors;
    final missing = coverage == null ||
        !coverage.documentExists ||
        !coverage.versionMatches;
    final preparing = _preparingId == source.id;
    return Container(
      key: ValueKey('plan-source-${source.id}'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(
          color: missing ? c.danger.withValues(alpha: .4) : c.outline,
        ),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              QIcon(
                QIcons.page,
                size: IconSizes.md,
                color: missing ? c.danger : c.inkMuted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      source.documentTitle,
                      style: context.texts.bodyMedium!.copyWith(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      source.label,
                      style: context.texts.bodySmall!.copyWith(
                        fontSize: 12,
                        color: c.inkMuted,
                      ),
                    ),
                  ],
                ),
              ),
              AppBadge(
                label: coverage?.allReady == true ? '已就绪' : '待补齐',
                tone: coverage?.allReady == true
                    ? BadgeTone.green
                    : BadgeTone.neutral,
                dense: true,
              ),
            ],
          ),
          if (coverage != null) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: coverage.progress,
                minHeight: 3,
                backgroundColor: c.tint,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              coverage.summary,
              style: context.texts.bodySmall!.copyWith(
                fontSize: 11.5,
                color: missing ? c.danger : c.inkMuted,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (widget.onOpenMaterial != null)
                OutlinedButton.icon(
                  onPressed: missing
                      ? null
                      : () => widget.onOpenMaterial!(source.materialRef),
                  icon: const QIcon(QIcons.external, size: IconSizes.sm),
                  label: const Text('打开原文'),
                ),
              if (widget.onPrepare != null && (coverage?.attentionPages ?? 0) > 0)
                FilledButton.icon(
                  key: ValueKey('prepare-source-${source.id}'),
                  onPressed: preparing || missing
                      ? null
                      : () => _prepare(source),
                  icon: preparing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const QIcon(QIcons.ocr, size: IconSizes.sm),
                  label: Text(
                    preparing
                        ? '正在补齐…'
                        : '补齐 ${coverage?.attentionPages ?? 0} 页',
                  ),
                ),
              TextButton(
                onPressed: preparing ? null : () => _remove(source),
                style: TextButton.styleFrom(foregroundColor: c.danger),
                child: const Text('移除'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AddPlanSourceDialog extends StatefulWidget {
  const _AddPlanSourceDialog({
    required this.plan,
    required this.documents,
  });

  final StudyPlan plan;
  final List<DocumentRecord> documents;

  @override
  State<_AddPlanSourceDialog> createState() => _AddPlanSourceDialogState();
}

class _AddPlanSourceDialogState extends State<_AddPlanSourceDialog> {
  static const _uuid = Uuid();
  late String _documentId = widget.documents.first.id;
  MaterialPurpose _purpose = MaterialPurpose.textbook;
  final _chapter = TextEditingController();
  final _start = TextEditingController();
  final _end = TextEditingController();
  String? _error;

  DocumentRecord get _document =>
      widget.documents.firstWhere((doc) => doc.id == _documentId);

  @override
  void initState() {
    super.initState();
    _start.text = '1';
    _end.text = '${widget.documents.first.pageCount}';
  }

  @override
  void dispose() {
    _chapter.dispose();
    _start.dispose();
    _end.dispose();
    super.dispose();
  }

  void _selectDocument(String? value) {
    if (value == null) return;
    setState(() {
      _documentId = value;
      _start.text = '1';
      _end.text = '${_document.pageCount}';
    });
  }

  void _save() {
    final start = int.tryParse(_start.text.trim());
    final end = int.tryParse(_end.text.trim());
    if (start == null || end == null) {
      setState(() => _error = '请填写起止页码。');
      return;
    }
    if (start < 1 || end < start || end > _document.pageCount) {
      setState(
        () => _error =
            '页码需在 1–${_document.pageCount} 之间，且结束页不早于开始页。',
      );
      return;
    }
    Navigator.pop(
      context,
      PlanSource(
        id: _uuid.v4(),
        planId: widget.plan.id,
        documentId: _document.id,
        documentHash: _document.contentHash,
        documentTitle: _document.title,
        purpose: _purpose,
        startPage: start,
        endPage: end,
        chapter: _chapter.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppDialog(
      title: '添加材料',
      subtitle: '选择书库资料、用途和物理页段。章节名可选。',
      maxWidth: 520,
      actions: [
        DialogActions.cancel(context),
        FilledButton(onPressed: _save, child: const Text('绑定')),
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) ...[
            AppCallout(
              tone: CalloutTone.error,
              message: _error!,
              onDismiss: () => setState(() => _error = null),
            ),
            const SizedBox(height: Space.md),
          ],
          const DialogFieldLabel('资料'),
          DropdownButtonFormField<String>(
            initialValue: _documentId,
            isExpanded: true,
            decoration: const InputDecoration(),
            items: [
              for (final document in widget.documents)
                DropdownMenuItem(
                  value: document.id,
                  child: Text(
                    '${document.title} · ${document.pageCount} 页',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: _selectDocument,
          ),
          const SizedBox(height: Space.md),
          const DialogFieldLabel('用途'),
          DropdownButtonFormField<MaterialPurpose>(
            initialValue: _purpose,
            decoration: const InputDecoration(),
            items: [
              for (final purpose in MaterialPurpose.values)
                DropdownMenuItem(
                  value: purpose,
                  child: Text(purpose.label),
                ),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _purpose = value);
            },
          ),
          const SizedBox(height: Space.md),
          const DialogFieldLabel('章节名（可选）'),
          TextField(
            controller: _chapter,
            decoration: const InputDecoration(hintText: '例如：第三章 函数'),
          ),
          const SizedBox(height: Space.md),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const DialogFieldLabel('起始页'),
                    TextField(
                      controller: _start,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const DialogFieldLabel('结束页'),
                    TextField(
                      controller: _end,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
