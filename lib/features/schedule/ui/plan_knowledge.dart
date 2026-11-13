import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../../services/ai_types.dart';
import '../../../ui/theme/tokens.dart';
import '../../../ui/widgets/app_dialog.dart';
import '../../../ui/widgets/app_surfaces.dart';
import '../data/schedule_repository.dart';
import '../models/knowledge_item.dart';
import '../models/study_plan.dart';
import '../models/study_task.dart';
import '../schedule_controller.dart';
import '../services/knowledge_ai_client.dart';

Future<void> showPlanKnowledge(
  BuildContext context,
  ScheduleController controller,
  StudyPlan plan,
) => showAppDialog<void>(
  context: context,
  builder: (context) =>
      _PlanKnowledgeDialog(controller: controller, plan: plan),
);

class _PlanKnowledgeDialog extends StatefulWidget {
  const _PlanKnowledgeDialog({required this.controller, required this.plan});

  final ScheduleController controller;
  final StudyPlan plan;

  @override
  State<_PlanKnowledgeDialog> createState() => _PlanKnowledgeDialogState();
}

class _PlanKnowledgeDialogState extends State<_PlanKnowledgeDialog> {
  List<KnowledgeItem> _items = const [];
  String? _error;
  String? _notice;
  bool _generating = false;
  bool _loading = true;

  ScheduleController get c => widget.controller;
  ScheduleRepository get repository => c.repository;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    try {
      final items = repository.getKnowledgeItems(widget.plan.id);
      setState(() {
        _items = items;
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

  Future<void> _generate() async {
    if (_generating) return;
    setState(() => _error = null);
    PreparedKnowledgeRequest prepared;
    try {
      prepared = c.prepareKnowledge(widget.plan);
    } on AiFailure catch (error) {
      setState(() => _error = error.message);
      return;
    } catch (error) {
      setState(() => _error = '$error');
      return;
    }
    if (!mounted) return;
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: '提取知识点',
        subtitle: '发送前确认材料范围与模型。',
        maxWidth: 560,
        actions: [
          DialogActions.cancel(context),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认发送'),
          ),
        ],
        content: Text(
          prepared.previewSummary,
          style: context.texts.bodySmall!.copyWith(height: 1.6),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _generating = true;
      _notice = null;
    });
    try {
      final saved = await c.sendKnowledge(prepared);
      if (!mounted) return;
      _load();
      setState(
        () => _notice = '已生成并保存 ${saved.length} 个知识点。请核对来源、优先级和用时，'
            '再加入待安排任务。',
      );
    } on AiFailure catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = '生成失败：$error');
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _add() async {
    final item = await showAppDialog<KnowledgeItem>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _KnowledgeEditorDialog(
        plan: widget.plan,
        existing: _items,
      ),
    );
    if (item == null || !mounted) return;
    try {
      c.saveKnowledge(item);
      _load();
      setState(() => _notice = '已添加知识点。');
    } catch (error) {
      setState(() => _error = '$error');
    }
  }

  Future<void> _edit(KnowledgeItem item) async {
    final saved = await showAppDialog<KnowledgeItem>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _KnowledgeEditorDialog(
        plan: widget.plan,
        existing: _items,
        item: item,
      ),
    );
    if (saved == null || !mounted) return;
    try {
      c.saveKnowledge(saved);
      _load();
      setState(() => _notice = '已更新知识点。');
    } catch (error) {
      setState(() => _error = '$error');
    }
  }

  void _delete(KnowledgeItem item) {
    try {
      c.deleteKnowledge(item.id);
      _load();
      setState(
        () => _notice = '已删除知识点；已经加入待安排任务的条目仍会保留。',
      );
    } catch (error) {
      setState(() => _error = '删除失败：$error');
    }
  }

  void _createTask(KnowledgeItem item) {
    try {
      c.generateTaskFromKnowledge(item);
      _load();
      setState(() => _notice = '已加入待安排任务「${item.title}」，可在“待安排任务”里调整。');
    } catch (error) {
      setState(() => _error = '生成任务失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final itemsById = {for (final item in _items) item.id: item};
    return AppDialog(
      title: '知识点',
      subtitle: '${widget.plan.title} · 支持来源回查及优先级、前置关系调整。',
      maxWidth: 780,
      actions: [
        TextButton.icon(
          onPressed: _generating ? null : _generate,
          icon: _generating
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const QIcon(QIcons.ai, size: IconSizes.sm),
          label: Text(_generating ? '正在提取…' : '从材料生成'),
        ),
        TextButton.icon(
          onPressed: _generating ? null : _add,
          icon: const QIcon(QIcons.add, size: IconSizes.sm),
          label: const Text('手动添加'),
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
          if (!widget.controller.knowledgeEnabled)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: AppCallout(
                tone: CalloutTone.info,
                message: '未配置文本模型：可手动添加，或在设置中配置后再从材料提取。',
              ),
            ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_items.isEmpty)
            EmptyState(
              icon: QIcons.knowledge,
              title: '还没有知识点',
              message: '可从已解析材料自动提取，或手动添加知识点。',
              compact: true,
            )
          else
            for (final item in _items) ...[
              _KnowledgeCard(
                item: item,
                prerequisites: [
                  for (final id in item.prerequisiteIds)
                    if (itemsById[id] != null) itemsById[id]!.title,
                ],
                taskExists: item.taskId != null &&
                    repository.getTask(item.taskId!) != null,
                onEdit: () => _edit(item),
                onDelete: () => _delete(item),
                onCreateTask: () => _createTask(item),
              ),
              const SizedBox(height: Space.sm),
            ],
          const SizedBox(height: 4),
          Text(
            '生成任务为本地操作，可在待安排任务中调整用时与排期。',
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
}

class _KnowledgeCard extends StatelessWidget {
  const _KnowledgeCard({
    required this.item,
    required this.prerequisites,
    required this.taskExists,
    required this.onEdit,
    required this.onDelete,
    required this.onCreateTask,
  });

  final KnowledgeItem item;
  final List<String> prerequisites;
  final bool taskExists;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onCreateTask;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      key: ValueKey('knowledge-${item.id}'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.outline),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: context.texts.bodyMedium!.copyWith(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (item.objective.trim().isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        item.objective,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.texts.bodySmall!.copyWith(
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              AppBadge(label: item.priorityLabel, dense: true),
            ],
          ),
          const SizedBox(height: 7),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              AppBadge(label: item.activity.label, dense: true),
              AppBadge(label: '${item.minutes} 分钟', dense: true),
              if (item.sourcePageLabel != null)
                AppBadge(
                  label: '${item.documentTitle} · ${item.sourcePageLabel}',
                  dense: true,
                )
              else
                const AppBadge(label: '无材料来源', dense: true),
              if (item.taskId != null)
                AppBadge(
                  label: taskExists ? '已加入待安排任务' : '任务已删除',
                  tone: BadgeTone.green,
                  dense: true,
                ),
            ],
          ),
          if (prerequisites.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              '前置：${prerequisites.join('、')}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.texts.bodySmall!.copyWith(
                fontSize: 11.5,
                color: c.inkMuted,
              ),
            ),
          ],
          if (item.completionCondition.trim().isNotEmpty) ...[
            const SizedBox(height: 5),
            Text(
              '完成条件：${item.completionCondition}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.texts.bodySmall!.copyWith(
                fontSize: 11.5,
                color: c.inkMuted,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              OutlinedButton(
                onPressed: onEdit,
                child: const Text('编辑'),
              ),
              FilledButton(
                onPressed: taskExists ? null : onCreateTask,
                child: Text(taskExists ? '已在待安排任务' : '加入待安排任务'),
              ),
              TextButton(
                onPressed: onDelete,
                style: TextButton.styleFrom(foregroundColor: c.danger),
                child: const Text('删除'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _KnowledgeEditorDialog extends StatefulWidget {
  const _KnowledgeEditorDialog({
    required this.plan,
    required this.existing,
    this.item,
  });

  final StudyPlan plan;
  final List<KnowledgeItem> existing;
  final KnowledgeItem? item;

  @override
  State<_KnowledgeEditorDialog> createState() => _KnowledgeEditorDialogState();
}

class _KnowledgeEditorDialogState extends State<_KnowledgeEditorDialog> {
  static const _uuid = Uuid();
  late final TextEditingController _title;
  late final TextEditingController _objective;
  late final TextEditingController _minutes;
  late final TextEditingController _completion;
  late int _priority;
  late TaskActivity _activity;
  late Set<String> _prerequisites;
  String? _error;

  bool get _editing => widget.item != null;

  @override
  void initState() {
    super.initState();
    final item = widget.item;
    _title = TextEditingController(text: item?.title ?? '');
    _objective = TextEditingController(text: item?.objective ?? '');
    _minutes = TextEditingController(text: '${item?.minutes ?? 45}');
    _completion = TextEditingController(
      text: item?.completionCondition ?? '',
    );
    _priority = item?.priority ?? 1;
    _activity = item?.activity ?? TaskActivity.learn;
    _prerequisites = {...?item?.prerequisiteIds};
  }

  @override
  void dispose() {
    _title.dispose();
    _objective.dispose();
    _minutes.dispose();
    _completion.dispose();
    super.dispose();
  }

  void _save() {
    final title = _title.text.trim();
    final minutes = int.tryParse(_minutes.text.trim());
    if (title.isEmpty) {
      setState(() => _error = '请填写知识点标题。');
      return;
    }
    if (minutes == null || minutes < 5 || minutes > 240) {
      setState(() => _error = '预计用时需在 5–240 分钟之间。');
      return;
    }
    final item = widget.item;
    final saved = item == null
        ? KnowledgeItem(
            id: _uuid.v4(),
            planId: widget.plan.id,
            title: title,
            objective: _objective.text.trim(),
            priority: _priority,
            minutes: minutes,
            activity: _activity,
            completionCondition: _completion.text.trim(),
            prerequisiteIds: _prerequisites.toList(),
          )
        : item.copyWith(
            title: title,
            objective: _objective.text.trim(),
            priority: _priority,
            minutes: minutes,
            activity: _activity,
            completionCondition: _completion.text.trim(),
            prerequisiteIds: _prerequisites.toList(),
          );
    Navigator.pop(context, saved);
  }

  @override
  Widget build(BuildContext context) {
    final candidates = widget.existing
        .where((item) => item.id != widget.item?.id)
        .toList();
    return AppDialog(
      title: _editing ? '编辑知识点' : '新增知识点',
      maxWidth: 620,
      actions: [
        DialogActions.cancel(context),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) ...[
            AppCallout(tone: CalloutTone.error, message: _error!),
            const SizedBox(height: Space.md),
          ],
          const DialogFieldLabel('标题'),
          TextField(
            key: const ValueKey('knowledge-title'),
            controller: _title,
          ),
          const SizedBox(height: Space.md),
          const DialogFieldLabel('学习目标（可选）'),
          TextField(
            key: const ValueKey('knowledge-objective'),
            controller: _objective,
            maxLines: 3,
          ),
          const SizedBox(height: Space.md),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const DialogFieldLabel('优先级'),
                    DropdownButtonFormField<int>(
                      initialValue: _priority,
                      items: const [
                        DropdownMenuItem(value: 2, child: Text('重点')),
                        DropdownMenuItem(value: 1, child: Text('普通')),
                        DropdownMenuItem(value: 0, child: Text('可选')),
                      ],
                      onChanged: (value) {
                        if (value != null) setState(() => _priority = value);
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const DialogFieldLabel('预计分钟'),
                    TextField(
                      key: const ValueKey('knowledge-minutes'),
                      controller: _minutes,
                      keyboardType: TextInputType.number,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.md),
          const DialogFieldLabel('学习方式'),
          DropdownButtonFormField<TaskActivity>(
            initialValue: _activity,
            items: [
              for (final activity in TaskActivity.values)
                DropdownMenuItem(
                  value: activity,
                  child: Text(activity.label),
                ),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _activity = value);
            },
          ),
          const SizedBox(height: Space.md),
          const DialogFieldLabel('完成条件（可选）'),
          TextField(controller: _completion, maxLines: 2),
          if (candidates.isNotEmpty) ...[
            const SizedBox(height: Space.md),
            const DialogFieldLabel('前置知识点（可选）'),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final candidate in candidates)
                  FilterChip(
                    label: Text(candidate.title),
                    selected: _prerequisites.contains(candidate.id),
                    onSelected: (selected) {
                      setState(() {
                        if (selected) {
                          _prerequisites.add(candidate.id);
                        } else {
                          _prerequisites.remove(candidate.id);
                        }
                      });
                    },
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
