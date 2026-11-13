import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../../../ui/theme/tokens.dart';
import '../../../ui/widgets/app_dialog.dart';
import '../../../ui/widgets/app_surfaces.dart';
import '../domain/schedule_validator.dart';
import '../models/local_date.dart';
import '../models/material_ref.dart';
import '../models/plan_availability.dart';
import '../models/schedule_time.dart';
import '../models/study_plan.dart';
import '../models/study_task.dart';
import '../schedule_controller.dart';
import 'plan_knowledge.dart';
import 'plan_materials.dart';

Future<void> showPlanManager(
  BuildContext context,
  ScheduleController controller, {
  Future<void> Function(MaterialRef material)? onOpenMaterial,
  MaterialPreparer? onPrepareMaterial,
}) => showAppDialog<void>(
  context: context,
  builder: (context) => _PlanManagerDialog(
    controller: controller,
    onOpenMaterial: onOpenMaterial,
    onPrepareMaterial: onPrepareMaterial,
  ),
);

class _PlanManagerDialog extends StatefulWidget {
  const _PlanManagerDialog({
    required this.controller,
    required this.onOpenMaterial,
    required this.onPrepareMaterial,
  });

  final ScheduleController controller;
  final Future<void> Function(MaterialRef material)? onOpenMaterial;
  final MaterialPreparer? onPrepareMaterial;

  @override
  State<_PlanManagerDialog> createState() => _PlanManagerDialogState();
}

class _PlanManagerDialogState extends State<_PlanManagerDialog> {
  bool _showArchived = false;
  String? _error;

  ScheduleController get c => widget.controller;

  @override
  Widget build(BuildContext context) {
    final plans = c.plans
        .where((plan) => _showArchived || plan.status != PlanStatus.archived)
        .toList();
    return AppDialog(
      title: '学习计划',
      subtitle: '管理目标、考试日与可用时间；所有计划共用同一日历。',
      maxWidth: 720,
      actions: [
        TextButton.icon(
          onPressed: () async {
            final saved = await showPlanEditor(context, c);
            if (saved != null && mounted) setState(() {});
          },
          icon: const QIcon(QIcons.add, size: IconSizes.sm),
          label: const Text('新建计划'),
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
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _showArchived,
            onChanged: (value) => setState(() => _showArchived = value),
            title: const Text('显示已归档计划'),
          ),
          if (plans.isEmpty)
            const EmptyState(
              icon: QIcons.plan,
              title: '还没有计划',
              message: '创建计划并设置考试日与可用时间，即可将任务排入日历。',
              compact: true,
            )
          else
            for (final plan in plans) ...[
              _PlanRow(
                plan: plan,
                controller: c,
                onOpenMaterial: widget.onOpenMaterial,
                onPrepareMaterial: widget.onPrepareMaterial,
                onChanged: () => setState(() {}),
                onError: (message) => setState(() => _error = message),
              ),
              const SizedBox(height: Space.sm),
            ],
        ],
      ),
    );
  }
}

class _PlanRow extends StatelessWidget {
  const _PlanRow({
    required this.plan,
    required this.controller,
    required this.onOpenMaterial,
    required this.onPrepareMaterial,
    required this.onChanged,
    required this.onError,
  });

  final StudyPlan plan;
  final ScheduleController controller;
  final Future<void> Function(MaterialRef material)? onOpenMaterial;
  final MaterialPreparer? onPrepareMaterial;
  final VoidCallback onChanged;
  final ValueChanged<String> onError;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final archived = plan.status == PlanStatus.archived;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: c.outline),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      plan.title,
                      style: context.texts.bodyMedium!.copyWith(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${plan.subject.isEmpty ? '未分科目' : plan.subject} · ${plan.rangeLabel}'
                      '${plan.examDate == null ? '' : ' · 考试 ${plan.examDate!.shortLabel}'}'
                      ' · ${plan.mode.label}',
                      style: context.texts.bodySmall!.copyWith(fontSize: 12.5),
                    ),
                  ],
                ),
              ),
              AppBadge(label: plan.status.label),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: () async {
                  final saved = await showPlanEditor(
                    context,
                    controller,
                    plan: plan,
                  );
                  if (saved != null) onChanged();
                },
                child: const Text('编辑'),
              ),
              OutlinedButton(
                onPressed: () async {
                  await showAvailabilityDialog(context, controller, plan);
                  onChanged();
                },
                child: const Text('可用时间'),
              ),
              OutlinedButton(
                onPressed: () async {
                  await showPlanKnowledge(context, controller, plan);
                  onChanged();
                },
                child: const Text('知识点'),
              ),
              OutlinedButton(
                onPressed: () async {
                  await showPlanMaterials(
                    context,
                    controller,
                    plan,
                    onOpenMaterial: onOpenMaterial,
                    onPrepare: onPrepareMaterial,
                  );
                  onChanged();
                },
                child: const Text('材料'),
              ),
              OutlinedButton(
                onPressed: () async {
                  await showTaskPool(context, controller, plan);
                  onChanged();
                },
                child: const Text('待安排任务'),
              ),
              OutlinedButton(
                onPressed: () => controller.selectPlan(plan.id),
                child: const Text('在日历中筛选'),
              ),
              TextButton(
                onPressed: () async {
                  try {
                    controller.savePlan(
                      plan.copyWith(
                        status: archived ? PlanStatus.active : PlanStatus.archived,
                      ),
                    );
                    onChanged();
                  } catch (error) {
                    onError('$error');
                  }
                },
                child: Text(archived ? '恢复' : '归档'),
              ),
              TextButton(
                style: TextButton.styleFrom(foregroundColor: c.danger),
                onPressed: () async {
                  final confirmed = await showAppDialog<bool>(
                    context: context,
                    builder: (context) => AppDialog(
                      title: '删除计划？',
                      maxWidth: 420,
                      actions: [
                        DialogActions.cancel(context),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: c.danger,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('删除'),
                        ),
                      ],
                      content: Text(
                        '会删除「${plan.title}」的待安排任务与所有时间块；'
                        '教材、学习记录和问答不会被删除。',
                      ),
                    ),
                  );
                  if (confirmed != true) return;
                  try {
                    controller.deletePlan(plan.id);
                    onChanged();
                  } catch (error) {
                    onError('删除失败：$error');
                  }
                },
                child: const Text('删除'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

Future<StudyPlan?> showPlanEditor(
  BuildContext context,
  ScheduleController controller, {
  StudyPlan? plan,
}) => showAppDialog<StudyPlan>(
  context: context,
  barrierDismissible: false,
  builder: (context) =>
      _PlanEditorDialog(controller: controller, plan: plan),
);

class _PlanEditorDialog extends StatefulWidget {
  const _PlanEditorDialog({required this.controller, this.plan});

  final ScheduleController controller;
  final StudyPlan? plan;

  @override
  State<_PlanEditorDialog> createState() => _PlanEditorDialogState();
}

class _PlanEditorDialogState extends State<_PlanEditorDialog> {
  final _title = TextEditingController();
  final _subject = TextEditingController();
  final _goal = TextEditingController();
  late LocalDate _start;
  late LocalDate _end;
  LocalDate? _exam;
  late StudyMode _mode;
  String? _error;

  @override
  void initState() {
    super.initState();
    final plan = widget.plan;
    final today = widget.controller.today;
    _title.text = plan?.title ?? '';
    _subject.text = plan?.subject ?? '';
    _goal.text = plan?.goal ?? '';
    _start = plan?.startDate ?? today;
    _end = plan?.endDate ?? _start.addDays(30);
    _exam = plan?.examDate;
    _mode = plan?.mode ?? StudyMode.unknown;
  }

  @override
  void dispose() {
    _title.dispose();
    _subject.dispose();
    _goal.dispose();
    super.dispose();
  }

  Future<void> _pickDate({required bool start}) async {
    final initial = start ? _start : _end;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial.toDateTime(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: start ? '计划开始日期' : '计划结束日期',
    );
    if (picked == null || !mounted) return;
    setState(() {
      final date = LocalDate.fromDateTime(picked);
      if (start) {
        _start = date;
        if (_end < _start) _end = _start.addDays(30);
      } else {
        _end = date;
      }
    });
  }

  Future<void> _pickExam() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _exam?.toDateTime() ?? _end.toDateTime(),
      firstDate: _start.toDateTime(),
      lastDate: DateTime(2100),
      helpText: '考试日期',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _exam = LocalDate.fromDateTime(picked);
      final dayBefore = _exam!.addDays(-1);
      if (_end > dayBefore) _end = dayBefore;
      if (_end < _start) _end = _start;
    });
  }

  void _save() {
    try {
      if (_title.text.trim().isEmpty) {
        throw ScheduleValidationException('请填写计划名称。');
      }
      if (_end < _start) {
        throw ScheduleValidationException('计划结束日期不能早于开始日期。');
      }
      final existing = widget.plan;
      final saved = widget.controller.savePlan(
        StudyPlan(
          id: existing?.id ?? const Uuid().v4(),
          title: _title.text.trim(),
          subject: _subject.text.trim(),
          startDate: _start,
          endDate: _end,
          examDate: _exam,
          examMinute: existing?.examMinute,
          timezone: existing?.timezone ?? 'Asia/Shanghai',
          mode: _mode,
          goal: _goal.text.trim(),
          status: existing?.status ?? PlanStatus.active,
          revision: existing?.revision ?? 1,
          createdAt: existing?.createdAt,
        ),
      );
      Navigator.pop(context, saved);
    } on ScheduleValidationException catch (error) {
      setState(() => _error = error.message);
    } on ArgumentError catch (error) {
      setState(() => _error = '${error.message ?? error}');
    }
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    title: widget.plan == null ? '新建计划' : '编辑计划',
    subtitle: '结束日期是排期范围的最后一天；考试当天默认不安排学习。',
    maxWidth: 560,
    actions: [
      DialogActions.cancel(context),
      FilledButton(onPressed: _save, child: const Text('保存计划')),
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
        const DialogFieldLabel('计划名称'),
        TextField(
          key: const ValueKey('schedule-plan-title'),
          controller: _title,
          autofocus: true,
          decoration: const InputDecoration(hintText: '例如：期中数学备考'),
        ),
        const SizedBox(height: Space.md),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const DialogFieldLabel('科目'),
                  TextField(
                    controller: _subject,
                    decoration: const InputDecoration(hintText: '例如：数学'),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const DialogFieldLabel('学习模式'),
                  DropdownButtonFormField<StudyMode>(
                    initialValue: _mode,
                    items: [
                      for (final mode in StudyMode.values)
                        DropdownMenuItem(value: mode, child: Text(mode.label)),
                    ],
                    onChanged: (value) =>
                        setState(() => _mode = value ?? StudyMode.unknown),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: Space.md),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const DialogFieldLabel('开始日期'),
                  OutlinedButton(
                    onPressed: () => _pickDate(start: true),
                    child: Text(_start.longLabel),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const DialogFieldLabel('结束日期'),
                  OutlinedButton(
                    onPressed: () => _pickDate(start: false),
                    child: Text(_end.longLabel),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: Space.md),
        const DialogFieldLabel('考试日期（可选）'),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _pickExam,
                icon: const QIcon(QIcons.milestone, size: IconSizes.sm),
                label: Text(_exam == null ? '不设置考试日' : _exam!.longLabel),
              ),
            ),
            if (_exam != null) ...[
              const SizedBox(width: 8),
              IconButton(
                tooltip: '移除考试日期',
                onPressed: () => setState(() => _exam = null),
                icon: const QIcon(QIcons.close, size: IconSizes.md),
              ),
            ],
          ],
        ),
        const SizedBox(height: Space.md),
        const DialogFieldLabel('目标'),
        TextField(
          controller: _goal,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: '可选：希望达到的水平，以及哪些范围最重要',
          ),
        ),
      ],
    ),
  );
}

Future<void> showAvailabilityDialog(
  BuildContext context,
  ScheduleController controller,
  StudyPlan plan,
) => showAppDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (context) =>
      _AvailabilityDialog(controller: controller, plan: plan),
);

class _AvailabilityDialog extends StatefulWidget {
  const _AvailabilityDialog({required this.controller, required this.plan});

  final ScheduleController controller;
  final StudyPlan plan;

  @override
  State<_AvailabilityDialog> createState() => _AvailabilityDialogState();
}

class _AvailabilityDialogState extends State<_AvailabilityDialog> {
  final _dailyCap = TextEditingController();
  late List<({bool enabled, int start, int end})> _week;
  late int _buffer;
  late int _maxDays;
  late int _breakMinutes;
  late int _unitMinutes;
  late List<AvailabilityException> _exceptions;
  bool _wasSaved = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final saved = widget.controller.availabilityFor(widget.plan.id);
    final value = saved ?? PlanAvailability.suggestion(widget.plan.id);
    _wasSaved = saved != null;
    _exceptions = [...value.exceptions];
    _dailyCap.text = '${value.dailyCapMinutes}';
    _buffer = value.bufferPercent;
    _maxDays = value.maxStudyDaysPerWeek.clamp(1, 7);
    _breakMinutes = value.breakMinutes;
    _unitMinutes = value.unitMinutes;
    _week = [
      for (var weekday = 1; weekday <= 7; weekday++)
        () {
          final slots = value.weekly
              .where((slot) => slot.weekday == weekday && slot.isValid)
              .toList();
          if (slots.isEmpty) {
            return (
              enabled: false,
              start: 19 * 60 + 30,
              end: 21 * 60,
            );
          }
          slots.sort((a, b) => a.startMinute.compareTo(b.startMinute));
          return (
            enabled: true,
            start: slots.first.startMinute,
            end: slots
                .map((slot) => slot.endMinute)
                .reduce((a, b) => a > b ? a : b),
          );
        }(),
    ];
  }

  @override
  void dispose() {
    _dailyCap.dispose();
    super.dispose();
  }

  Future<void> _pickTime(int weekday, {required bool start}) async {
    final rule = _week[weekday - 1];
    final current = start ? rule.start : rule.end;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current ~/ 60, minute: current % 60),
      helpText: '周${const ['一', '二', '三', '四', '五', '六', '日'][weekday - 1]}'
          '${start ? '开始' : '结束'}时间',
    );
    if (picked == null || !mounted) return;
    final minute = picked.hour * 60 + picked.minute;
    setState(() {
      _week[weekday - 1] = (
        enabled: true,
        start: start ? minute : rule.start,
        end: start ? rule.end : minute,
      );
    });
  }

  void _save() {
    try {
      final dailyCap = int.tryParse(_dailyCap.text.trim());
      if (dailyCap == null) {
        throw ScheduleValidationException('每日上限需填写整数分钟。');
      }
      final weekly = <WeeklySlot>[];
      for (var weekday = 1; weekday <= 7; weekday++) {
        final rule = _week[weekday - 1];
        if (!rule.enabled) continue;
        if (rule.end <= rule.start) {
          throw ScheduleValidationException(
            '周${const ['一', '二', '三', '四', '五', '六', '日'][weekday - 1]} 的结束时间必须晚于开始时间。',
          );
        }
        weekly.add(
          WeeklySlot(
            weekday: weekday,
            startMinute: rule.start,
            endMinute: rule.end,
          ),
        );
      }
      final value = PlanAvailability(
        planId: widget.plan.id,
        weekly: weekly,
        exceptions: _exceptions,
        dailyCapMinutes: dailyCap,
        bufferPercent: _buffer,
        maxStudyDaysPerWeek: _maxDays,
        breakMinutes: _breakMinutes,
        unitMinutes: _unitMinutes,
      );
      final problems = value.validate();
      if (problems.isNotEmpty) {
        throw ScheduleValidationException(problems.join('\n'));
      }
      widget.controller.saveAvailability(value);
      Navigator.pop(context);
    } on ScheduleValidationException catch (error) {
      setState(() => _error = error.message);
    } catch (error) {
      setState(() => _error = '保存失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    const labels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return AppDialog(
      title: '可用时间',
      subtitle: '仅使用已保存的时段；不自动占用周末或考试当天。',
      maxWidth: 640,
      actions: [
        DialogActions.cancel(context),
        FilledButton(onPressed: _save, child: const Text('保存可用时间')),
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
          if (!_wasSaved) ...[
            const AppCallout(
              tone: CalloutTone.info,
              title: '默认建议，尚未生效',
              message: '当前为工作日 19:30–21:00 建议时段，保存后生效。',
            ),
            const SizedBox(height: Space.md),
          ],
          for (var weekday = 1; weekday <= 7; weekday++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  SizedBox(
                    width: 96,
                    child: CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _week[weekday - 1].enabled,
                      onChanged: (value) => setState(() {
                        final rule = _week[weekday - 1];
                        _week[weekday - 1] = (
                          enabled: value ?? false,
                          start: rule.start,
                          end: rule.end,
                        );
                      }),
                      title: Text(labels[weekday - 1]),
                    ),
                  ),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _week[weekday - 1].enabled
                          ? () => _pickTime(weekday, start: true)
                          : null,
                      child: Text(formatMinuteOfDay(_week[weekday - 1].start)),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child: Text('–'),
                  ),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _week[weekday - 1].enabled
                          ? () => _pickTime(weekday, start: false)
                          : null,
                      child: Text(formatMinuteOfDay(_week[weekday - 1].end)),
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 24),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const DialogFieldLabel('每日上限（分钟）'),
                    TextField(
                      controller: _dailyCap,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const DialogFieldLabel('机动比例'),
                    DropdownButtonFormField<int>(
                      initialValue: _buffer,
                      items: [
                        for (final value in [0, 10, 15, 20, 25, 30])
                          DropdownMenuItem(
                            value: value,
                            child: Text('$value%'),
                          ),
                      ],
                      onChanged: (value) =>
                          setState(() => _buffer = value ?? 15),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.md),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const DialogFieldLabel('每周最多学习几天'),
                    DropdownButtonFormField<int>(
                      initialValue: _maxDays,
                      items: [
                        for (var value = 1; value <= 7; value++)
                          DropdownMenuItem(
                            value: value,
                            child: Text('$value 天'),
                          ),
                      ],
                      onChanged: (value) =>
                          setState(() => _maxDays = value ?? 5),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const DialogFieldLabel('块间休息'),
                    DropdownButtonFormField<int>(
                      initialValue: _breakMinutes,
                      items: [
                        for (final value in [0, 5, 10, 15])
                          DropdownMenuItem(
                            value: value,
                            child: Text('$value 分钟'),
                          ),
                      ],
                      onChanged: (value) =>
                          setState(() => _breakMinutes = value ?? 5),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const DialogFieldLabel('学习单元'),
                    DropdownButtonFormField<int>(
                      initialValue: _unitMinutes,
                      items: [
                        for (final value in [15, 20, 25, 30, 45, 60])
                          DropdownMenuItem(
                            value: value,
                            child: Text('$value 分钟'),
                          ),
                      ],
                      onChanged: (value) =>
                          setState(() => _unitMinutes = value ?? 25),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.md),
          Text(
            '单日例外（休息日、临时调整）在日详情右上角设置。'
            '${_exceptions.isEmpty ? '目前没有单日例外。' : '目前有 ${_exceptions.length} 个单日例外。'}',
            style: context.texts.bodySmall!.copyWith(color: c.inkMuted),
          ),
        ],
      ),
    );
  }
}

Future<void> showTaskPool(
  BuildContext context,
  ScheduleController controller,
  StudyPlan plan,
) => showAppDialog<void>(
  context: context,
  builder: (context) => _TaskPoolDialog(controller: controller, plan: plan),
);

class _TaskPoolDialog extends StatefulWidget {
  const _TaskPoolDialog({required this.controller, required this.plan});

  final ScheduleController controller;
  final StudyPlan plan;

  @override
  State<_TaskPoolDialog> createState() => _TaskPoolDialogState();
}

class _TaskPoolDialogState extends State<_TaskPoolDialog> {
  String? _error;

  ScheduleController get c => widget.controller;

  @override
  Widget build(BuildContext context) {
    final tasks = c.repository.getTasks(planId: widget.plan.id);
    final blocks = c.repository.getBlocks(planId: widget.plan.id);
    final counts = <String, int>{};
    for (final block in blocks) {
      if (block.taskId == null) continue;
      counts[block.taskId!] = (counts[block.taskId!] ?? 0) + 1;
    }
    return AppDialog(
      title: '待安排任务',
      subtitle: '自动排期将按「${widget.plan.title}」可用时间分配时段并生成草案。',
      maxWidth: 640,
      actions: [
        TextButton.icon(
          onPressed: () async {
            final saved = await showTaskPoolEditor(context, c, widget.plan);
            if (saved != null && mounted) setState(() {});
          },
          icon: const QIcon(QIcons.add, size: IconSizes.sm),
          label: const Text('新增任务'),
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
          if (tasks.isEmpty)
            const EmptyState(
              icon: QIcons.addTask,
              title: '还没有待安排任务',
              message: '填写学习内容与预计用时，再由排课器分配时段。',
              compact: true,
            )
          else
            for (final task in tasks)
              _TaskPoolRow(
                task: task,
                blockCount: counts[task.id] ?? 0,
                onEdit: () async {
                  final saved = await showTaskPoolEditor(
                    context,
                    c,
                    widget.plan,
                    task: task,
                  );
                  if (saved != null && mounted) setState(() {});
                },
                onDelete: () async {
                  if ((counts[task.id] ?? 0) > 0) {
                    setState(() => _error = '这个任务已有日历时间块，请先在日历里删除对应安排。');
                    return;
                  }
                  final confirmed = await showAppDialog<bool>(
                    context: context,
                    builder: (context) => AppDialog(
                      title: '删除待安排任务？',
                      maxWidth: 380,
                      actions: [
                        DialogActions.cancel(context),
                        FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('删除'),
                        ),
                      ],
                      content: Text('「${task.title}」将从待安排列表移除。'),
                    ),
                  );
                  if (confirmed != true) return;
                  c.deleteTask(task.id);
                  if (mounted) setState(() {});
                },
              ),
        ],
      ),
    );
  }
}

class _TaskPoolRow extends StatelessWidget {
  const _TaskPoolRow({
    required this.task,
    required this.blockCount,
    required this.onEdit,
    required this.onDelete,
  });

  final StudyTask task;
  final int blockCount;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.outline)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.title,
                  style: context.texts.bodyMedium!.copyWith(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${task.activity.label} · ${task.minutes} 分钟 · ${task.priorityLabel}'
                  '${blockCount > 0 ? ' · 已排 $blockCount 块' : ''}',
                  style: context.texts.bodySmall!.copyWith(fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '编辑待安排任务',
            onPressed: onEdit,
            icon: const QIcon(QIcons.edit, size: IconSizes.sm),
          ),
          IconButton(
            tooltip: blockCount > 0 ? '已在日历中，不能直接删除' : '删除待安排任务',
            onPressed: blockCount > 0 ? null : onDelete,
            icon: const QIcon(QIcons.delete, size: IconSizes.sm),
          ),
        ],
      ),
    );
  }
}

Future<StudyTask?> showTaskPoolEditor(
  BuildContext context,
  ScheduleController controller,
  StudyPlan plan, {
  StudyTask? task,
}) => showAppDialog<StudyTask>(
  context: context,
  barrierDismissible: false,
  builder: (context) => _TaskPoolEditorDialog(
    controller: controller,
    plan: plan,
    task: task,
  ),
);

class _TaskPoolEditorDialog extends StatefulWidget {
  const _TaskPoolEditorDialog({
    required this.controller,
    required this.plan,
    this.task,
  });

  final ScheduleController controller;
  final StudyPlan plan;
  final StudyTask? task;

  @override
  State<_TaskPoolEditorDialog> createState() => _TaskPoolEditorDialogState();
}

class _TaskPoolEditorDialogState extends State<_TaskPoolEditorDialog> {
  final _title = TextEditingController();
  final _minutes = TextEditingController(text: '45');
  final _completion = TextEditingController();
  late TaskActivity _activity;
  late int _priority;
  String? _error;

  @override
  void initState() {
    super.initState();
    final task = widget.task;
    _title.text = task?.title ?? '';
    _minutes.text = '${task?.minutes ?? 45}';
    _completion.text = task?.completionCondition ?? '';
    _activity = task?.activity ?? TaskActivity.practice;
    _priority = task?.priority ?? 1;
  }

  @override
  void dispose() {
    _title.dispose();
    _minutes.dispose();
    _completion.dispose();
    super.dispose();
  }

  void _save() {
    try {
      if (_title.text.trim().isEmpty) {
        throw ScheduleValidationException('请填写任务标题。');
      }
      final minutes = int.tryParse(_minutes.text.trim());
      if (minutes == null || minutes < 5 || minutes > 600) {
        throw ScheduleValidationException('预计用时需在 5–600 分钟之间。');
      }
      final existing = widget.task;
      final saved = widget.controller.saveTask(
        StudyTask(
          id: existing?.id ?? const Uuid().v4(),
          title: _title.text.trim(),
          subject: widget.plan.subject,
          planId: widget.plan.id,
          activity: _activity,
          minutes: minutes,
          priority: _priority,
          minChunkMinutes: minutes < 15 ? minutes : 15,
          completionCondition: _completion.text.trim(),
          status: existing?.status ?? TaskStatus.notStarted,
          createdAt: existing?.createdAt,
        ),
      );
      Navigator.pop(context, saved);
    } on ScheduleValidationException catch (error) {
      setState(() => _error = error.message);
    } on ArgumentError catch (error) {
      setState(() => _error = '${error.message ?? error}');
    }
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    title: widget.task == null ? '新增待安排任务' : '编辑待安排任务',
    maxWidth: 500,
    actions: [
      DialogActions.cancel(context),
      FilledButton(onPressed: _save, child: const Text('保存任务')),
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
        const DialogFieldLabel('要学什么'),
        TextField(
          controller: _title,
          autofocus: true,
          decoration: const InputDecoration(hintText: '例如：二次函数的顶点式练习'),
        ),
        const SizedBox(height: Space.md),
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const DialogFieldLabel('预计用时（分钟）'),
                  TextField(
                    controller: _minutes,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  ),
                ],
              ),
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
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
                    onChanged: (value) => setState(
                      () => _activity = value ?? TaskActivity.practice,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Space.md),
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
                    onChanged: (value) =>
                        setState(() => _priority = value ?? 1),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: Space.md),
        const DialogFieldLabel('完成条件'),
        TextField(
          controller: _completion,
          minLines: 1,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: '例如：独立完成 5 题，能说出每一步理由',
          ),
        ),
      ],
    ),
  );
}
