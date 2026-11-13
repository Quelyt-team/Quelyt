import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../data/schedule_repository.dart';
import '../domain/schedule_validator.dart';
import '../models/calendar_block.dart';
import '../models/local_date.dart';
import '../models/material_ref.dart';
import '../models/schedule_time.dart';
import '../models/study_task.dart';
import '../schedule_controller.dart';
import '../../../ui/theme/tokens.dart';
import '../../../ui/widgets/app_dialog.dart';
import '../../../ui/widgets/app_surfaces.dart';

Future<bool?> showTaskEditor(
  BuildContext context, {
  required ScheduleController controller,
  required LocalDate date,
  CalendarBlock? block,
}) => showAppDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (context) =>
      _TaskEditorDialog(controller: controller, date: date, block: block),
);

class _TaskEditorDialog extends StatefulWidget {
  const _TaskEditorDialog({
    required this.controller,
    required this.date,
    this.block,
  });

  final ScheduleController controller;
  final LocalDate date;
  final CalendarBlock? block;

  @override
  State<_TaskEditorDialog> createState() => _TaskEditorDialogState();
}

class _TaskEditorDialogState extends State<_TaskEditorDialog> {
  static const _uuid = Uuid();

  final _title = TextEditingController();
  final _subject = TextEditingController();
  final _completion = TextEditingController();
  final _notes = TextEditingController();
  final _knowledge = TextEditingController();
  final _pageStart = TextEditingController();
  final _pageEnd = TextEditingController();

  late LocalDate _date;
  late int _startMinute;
  late int _endMinute;
  late bool _locked;
  late bool _repeat;
  late Set<int> _weekdays;
  late LocalDate _repeatEnd;
  String? _planId;
  TaskActivity _activity = TaskActivity.practice;
  int _priority = 1;
  bool _busy = false;
  String? _materialDocumentId;
  bool _materialMissing = false;
  String _missingMaterialTitle = '';
  String? _error;
  RepeatEditScope _scope = RepeatEditScope.thisOnly;
  bool _saving = false;
  bool _showMore = false;

  StudyTask? get _existingTask {
    final block = widget.block;
    if (block == null || block.taskId == null) return null;
    return widget.controller.taskFor(block);
  }

  bool get _isEditing => widget.block != null;

  bool get _isSeries =>
      widget.block != null &&
      widget.block!.seriesId != null &&
      !widget.block!.detached;

  int get _minutes => _endMinute - _startMinute;

  @override
  void initState() {
    super.initState();
    final block = widget.block;
    _date = block?.date ?? widget.date;
    _startMinute = block?.startMinute ?? 19 * 60 + 30;
    _endMinute = block?.endMinute ?? 20 * 60 + 15;
    _locked = block?.locked ?? true;
    _showMore = block != null;
    _busy = block != null && !block.isStudy;
    _repeat = block?.seriesId != null && !block!.detached;
    _weekdays = (block?.seriesWeekdays.isNotEmpty ?? false)
        ? block!.seriesWeekdays.toSet()
        : {_date.weekday};
    _repeatEnd = block?.seriesEndDate ?? _date.addDays(28);
    final task = _existingTask;
    _planId = block?.planId ??
        widget.controller.planFilterId ??
        (widget.controller.activePlans.length == 1
            ? widget.controller.activePlans.single.id
            : null);
    if (task != null) {
      _title.text = task.title;
      _subject.text = task.subject;
      _completion.text = task.completionCondition;
      _notes.text = task.notes;
      _knowledge.text = task.knowledge;
      _activity = task.activity;
      _priority = task.priority;
      final material = task.material;
      final documents = widget.controller.store.getDocuments();
      if (material != null &&
          !material.missing &&
          documents.any(
            (document) =>
                document.id == material.documentId &&
                document.contentHash == material.documentHash,
          )) {
        _materialDocumentId = material.documentId;
        _pageStart.text = '${material.startPage}';
        _pageEnd.text = '${material.endPage}';
      } else if (material != null) {
        _materialMissing = true;
        _missingMaterialTitle = material.title;
        _pageStart.text = '${material.startPage}';
        _pageEnd.text = '${material.endPage}';
      }
    } else if (block != null) {
      _title.text = block.title;
    }
    _locked = block?.locked ?? true;
  }

  @override
  void dispose() {
    _title.dispose();
    _subject.dispose();
    _completion.dispose();
    _notes.dispose();
    _knowledge.dispose();
    _pageStart.dispose();
    _pageEnd.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date.toDateTime(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: '选择日期',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _date = LocalDate.fromDateTime(picked);
      if (!_weekdays.contains(_date.weekday) && _repeat) {
        _weekdays = {..._weekdays, _date.weekday};
      }
    });
  }

  Future<void> _pickTime({required bool start}) async {
    final current = start ? _startMinute : _endMinute;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current ~/ 60, minute: current % 60),
      helpText: start ? '选择开始时间' : '选择结束时间',
    );
    if (picked == null || !mounted) return;
    setState(() {
      final minute = picked.hour * 60 + picked.minute;
      if (start) {
        _startMinute = minute;
        if (_endMinute <= _startMinute) {
          _endMinute = (_startMinute + 45).clamp(0, 24 * 60);
        }
      } else {
        _endMinute = minute;
      }
    });
  }

  Future<void> _pickRepeatEnd() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _repeatEnd.toDateTime(),
      firstDate: _date.toDateTime(),
      lastDate: DateTime(2100),
      helpText: '重复结束日期',
    );
    if (picked == null || !mounted) return;
    setState(() => _repeatEnd = LocalDate.fromDateTime(picked));
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final title = _title.text.trim();
      if (title.isEmpty) {
        throw ScheduleValidationException('请填写任务标题。');
      }
      if (_busy) {
        await _saveBusy(title);
      } else {
        await _saveStudy(title);
      }
      if (mounted) Navigator.pop(context, true);
    } on ScheduleValidationException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on ScheduleConflictException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on ArgumentError catch (error) {
      if (mounted) setState(() => _error = '参数不完整：${error.message ?? error}');
    } catch (error) {
      if (mounted) setState(() => _error = '保存失败：$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  MaterialRef? _material() {
    final documentId = _materialDocumentId;
    if (documentId == null) return null;
    final document = widget.controller.store.getDocument(documentId);
    if (document == null) {
      throw ScheduleValidationException('绑定的教材已删除，请重新选择或解除绑定。');
    }
    final start = int.tryParse(_pageStart.text.trim());
    final end = int.tryParse(_pageEnd.text.trim());
    if (start == null || end == null) {
      throw ScheduleValidationException('请填写教材的起止页码。');
    }
    if (start < 1 || end < start || end > document.pageCount) {
      throw ScheduleValidationException(
        '页码需在 1–${document.pageCount} 之间，且结束页不早于开始页。',
      );
    }
    return MaterialRef(
      documentId: document.id,
      documentHash: document.contentHash,
      title: document.title,
      startPage: start,
      endPage: end,
    );
  }

  Future<void> _saveStudy(String title) async {
    if (_endMinute <= _startMinute) {
      throw ScheduleValidationException('结束时间必须晚于开始时间。');
    }
    if (_minutes < 5 || _minutes > 600) {
      throw ScheduleValidationException('单个学习块需在 5–600 分钟之间。');
    }
    final material = _material();
    if (_planId != null &&
        widget.controller.plans.every((plan) => plan.id != _planId)) {
      _planId = null;
    }
    final task = StudyTask(
      id: _existingTask?.id ?? _uuid.v4(),
      title: title,
      subject: _subject.text.trim(),
      planId: _planId,
      activity: _activity,
      minutes: _minutes,
      priority: _priority,
      minChunkMinutes: _minutes < 15 ? _minutes : 15,
      knowledge: _knowledge.text.trim(),
      completionCondition: _completion.text.trim(),
      notes: _notes.text.trim(),
      material: material,
      createdAt: _existingTask?.createdAt,
    );
    final block = CalendarBlock(
      id: widget.block?.id ?? _uuid.v4(),
      title: title,
      taskId: task.id,
      planId: task.planId,
      date: _date,
      startMinute: _startMinute,
      endMinute: _endMinute,
      kind: BlockKind.study,
      state: BlockState.scheduled,
      locked: _locked,
    );
    if (_isEditing) {
      widget.controller.updateManual(
        task: task,
        block: block,
        scope: _scope,
        weekdays: _scope == RepeatEditScope.thisAndFuture
            ? _weekdays.toList()
            : null,
        repeatEnd: _scope == RepeatEditScope.thisAndFuture ? _repeatEnd : null,
      );
    } else {
      widget.controller.createManual(
        task: task,
        block: block,
        repeat: _repeat,
        weekdays: _weekdays.toList(),
        repeatEnd: _repeat ? _repeatEnd : null,
      );
    }
  }

  Future<void> _saveBusy(String title) async {
    if (_endMinute <= _startMinute) {
      throw ScheduleValidationException('结束时间必须晚于开始时间。');
    }
    final template = CalendarBlock(
      id: widget.block?.id ?? _uuid.v4(),
      title: title,
      date: _date,
      startMinute: _startMinute,
      endMinute: _endMinute,
      kind: BlockKind.busy,
      locked: true,
    );
    if (_isEditing) {
      widget.controller.updateBusy(
        template,
        scope: _scope,
        weekdays: _scope == RepeatEditScope.thisAndFuture
            ? _weekdays.toList()
            : null,
        repeatEnd: _scope == RepeatEditScope.thisAndFuture ? _repeatEnd : null,
      );
    } else {
      widget.controller.createBusy(
        template: template,
        repeat: _repeat,
        weekdays: _weekdays.toList(),
        repeatEnd: _repeat ? _repeatEnd : null,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final documents = widget.controller.store.getDocuments();
    final plans = widget.controller.activePlans;
    final showRepeat =
        !_isEditing ||
        (_isSeries && _scope == RepeatEditScope.thisAndFuture);
    return AppDialog(
      title: _isEditing ? '编辑安排' : '新增安排',
      subtitle: _isEditing
          ? '修改时间不会改变任务身份；已开始或已完成的记录不会被改写。'
          : '手动保存后即写入日历，离线可用。',
      maxWidth: 620,
      actions: [
        DialogActions.cancel(context),
        FilledButton.icon(
          onPressed: _saving ? null : _save,
          icon: _saving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const QIcon(QIcons.check, size: IconSizes.sm),
          label: Text(_saving ? '保存中' : '保存'),
        ),
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) ...[
            AppCallout(
              tone: CalloutTone.error,
              title: '还不能保存',
              message: _error!,
              onDismiss: () => setState(() => _error = null),
            ),
            const SizedBox(height: Space.md),
          ],
          if (_isSeries) ...[
            const DialogFieldLabel('修改范围'),
            AppSegmentedControl(
              segments: const [
                AppSegment(label: '仅这一次'),
                AppSegment(label: '这次及以后'),
              ],
              selectedIndex: _scope == RepeatEditScope.thisOnly ? 0 : 1,
              onChanged: (index) => setState(
                () => _scope = index == 0
                    ? RepeatEditScope.thisOnly
                    : RepeatEditScope.thisAndFuture,
              ),
            ),
            const SizedBox(height: Space.md),
          ],
          if (!_isEditing) ...[
            AppSegmentedControl(
              segments: const [
                AppSegment(label: '学习任务', icon: QIcons.textbook),
                AppSegment(label: '个人占用', icon: QIcons.missed),
              ],
              selectedIndex: _busy ? 1 : 0,
              onChanged: (index) => setState(() => _busy = index == 1),
            ),
            const SizedBox(height: Space.md),
          ],
          const DialogFieldLabel('标题'),
          TextField(
            key: const ValueKey('schedule-task-title'),
            controller: _title,
            autofocus: !_isEditing,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              hintText: _busy ? '例如：英语课' : '例如：二次函数练习',
            ),
          ),
          const SizedBox(height: Space.md),
          if (!_busy) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const DialogFieldLabel('所属计划'),
                      _Select<String?>(
                        value: plans.any((plan) => plan.id == _planId)
                            ? _planId
                            : null,
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('无计划'),
                          ),
                          for (final plan in plans)
                            DropdownMenuItem<String?>(
                              value: plan.id,
                              child: Text(
                                plan.subject.isEmpty
                                    ? plan.title
                                    : '${plan.subject} · ${plan.title}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (value) => setState(() => _planId = value),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const DialogFieldLabel('科目'),
                      TextField(
                        controller: _subject,
                        decoration: const InputDecoration(hintText: '可选'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.md),
          ],
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const DialogFieldLabel('日期'),
                    OutlinedButton.icon(
                      onPressed: _pickDate,
                      icon: const QIcon(QIcons.today, size: IconSizes.sm),
                      label: Text(
                        '${_date.shortLabel} 周${_date.weekdayLabel}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
                    DialogFieldLabel('时间（$_minutes 分钟）'),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => _pickTime(start: true),
                            child: Text(formatMinuteOfDay(_startMinute)),
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 6),
                          child: Text('–'),
                        ),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => _pickTime(start: false),
                            child: Text(formatMinuteOfDay(_endMinute)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.md),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const ValueKey('task-editor-more'),
              onPressed: () => setState(() => _showMore = !_showMore),
              icon: QIcon(
                _showMore ? QIcons.chevronUp : QIcons.chevronDown,
                size: IconSizes.md,
              ),
              label: Text(
                _showMore ? '收起学习内容与更多设置' : '展开学习内容、重复与更多设置',
              ),
            ),
          ),
          if (_showMore && !_busy) ...[
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const DialogFieldLabel('学习方式'),
                      _Select<TaskActivity>(
                        value: _activity,
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
                      _Select<int>(
                        value: _priority,
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
                hintText: '例如：独立完成 5 题，能说明每一步理由',
              ),
            ),
            const SizedBox(height: Space.md),
            const DialogFieldLabel('知识点'),
            TextField(
              controller: _knowledge,
              decoration: const InputDecoration(hintText: '可选'),
            ),
            const SizedBox(height: Space.md),
            if (_materialMissing) ...[
              AppCallout(
                tone: CalloutTone.warning,
                title: '教材已删除',
                message:
                    '原绑定「$_missingMaterialTitle」已不在书库。保存会解除这个绑定，'
                    '任务、日历与学习记录都会保留。',
              ),
              const SizedBox(height: Space.sm),
            ],
            const DialogFieldLabel('绑定教材（可选）'),
            _Select<String?>(
              value: documents.any((doc) => doc.id == _materialDocumentId)
                  ? _materialDocumentId
                  : null,
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('不绑定'),
                ),
                for (final document in documents)
                  DropdownMenuItem<String?>(
                    value: document.id,
                    child: Text(
                      '${document.title} · ${document.pageCount} 页',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (value) => setState(() {
                _materialDocumentId = value;
                _materialMissing = false;
                if (value != null) {
                  final document = documents.firstWhere(
                    (document) => document.id == value,
                  );
                  _pageStart.text = _pageStart.text.isEmpty
                      ? '${document.currentPage}'
                      : _pageStart.text;
                  _pageEnd.text = _pageEnd.text.isEmpty
                      ? '${document.currentPage}'
                      : _pageEnd.text;
                }
              }),
            ),
            if (_materialDocumentId != null) ...[
              const SizedBox(height: Space.sm),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _pageStart,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(hintText: '起始页'),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Text('–'),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _pageEnd,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(hintText: '结束页'),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: Space.md),
          ],
          if (_showMore) ...[
            const DialogFieldLabel('备注'),
          TextField(
            controller: _notes,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: '可选：材料、页码或今天希望完成到什么程度',
            ),
          ),
          const SizedBox(height: Space.sm),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _locked,
            onChanged: (value) => setState(() => _locked = value),
            title: Text(
              '锁定时间',
              style: context.texts.bodySmall!.copyWith(
                fontSize: 13,
                color: c.ink,
              ),
            ),
            subtitle: const Text('锁定后自动排期不会移动，仍可手动修改。'),
          ),
          if (showRepeat) ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _isEditing ? true : _repeat,
              onChanged: _isEditing
                  ? null
                  : (value) {
                      setState(() {
                        _repeat = value;
                        if (value && _repeatEnd < _date) {
                          _repeatEnd = _date.addDays(28);
                        }
                      });
                    },
              title: Text(
                '每周重复',
                style: context.texts.bodySmall!.copyWith(
                  fontSize: 13,
                  color: c.ink,
                ),
              ),
              subtitle: Text(
                _isEditing
                    ? '将按所选星期与结束日期重建后续安排，不改已完成历史。'
                    : '须填写结束日期（单次最多展开 366 天）。',
              ),
            ),
            if (_repeat || _isEditing) ...[
              const DialogFieldLabel('重复的星期'),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (var weekday = 1; weekday <= 7; weekday++)
                    FilterChip(
                      label: Text(
                        const ['一', '二', '三', '四', '五', '六', '日'][weekday - 1],
                      ),
                      selected: _weekdays.contains(weekday),
                      onSelected: (selected) => setState(() {
                        if (selected) {
                          _weekdays.add(weekday);
                        } else if (_weekdays.length > 1) {
                          _weekdays.remove(weekday);
                        }
                      }),
                    ),
                ],
              ),
              const SizedBox(height: Space.sm),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _pickRepeatEnd,
                  icon: const QIcon(QIcons.repeat, size: IconSizes.sm),
                  label: Text('结束于 ${_repeatEnd.shortLabel}'),
                ),
              ),
            ],
          ],
          ],
        ],
      ),
    );
  }
}

class _Select<T> extends StatelessWidget {
  const _Select({
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) => InputDecorator(
    decoration: const InputDecoration(
      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<T>(
        isExpanded: true,
        value: value,
        items: items,
        onChanged: onChanged,
        style: context.texts.bodySmall!.copyWith(
          fontSize: 13,
          color: context.colors.ink,
        ),
        icon: QIcon(
          QIcons.chevronDown,
          size: IconSizes.md,
          color: context.colors.inkMuted,
        ),
      ),
    ),
  );
}
