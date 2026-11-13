import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../ui/theme/tokens.dart';
import '../../../ui/widgets/app_dialog.dart';
import '../../../ui/widgets/app_surfaces.dart';
import '../data/schedule_repository.dart';
import '../domain/schedule_validator.dart';
import '../models/calendar_block.dart';
import '../models/knowledge_item.dart';
import '../models/learning_record.dart';
import '../models/local_date.dart';
import '../models/material_ref.dart';
import '../models/plan_source.dart';
import '../models/schedule_time.dart';
import '../models/study_plan.dart';
import '../models/study_task.dart';
import '../schedule_controller.dart';
import 'catch_up_dialog.dart';
import 'daily_lesson.dart';
import 'draft_dialog.dart';
import 'plan_manager.dart';
import 'planning_sheet.dart';
import 'task_editor.dart';

enum _MenuAction { plans, availability, autoSchedule, undo, toggleRest }

enum DateJumpMode { year, month, day }

enum _JumpNumericMode { relative, ymd }

enum _JumpUnit {
  day('天'),
  week('周'),
  month('月'),
  year('年');

  const _JumpUnit(this.label);
  final String label;
}

enum _BlockAction {
  partial,
  skip,
  edit,
  lock,
  unlock,
  delete,
  openMaterial,
  lesson,
  catchUp,
}

class SchedulePage extends StatelessWidget {
  const SchedulePage({
    super.key,
    required this.controller,
    required this.onOpenMaterial,
    required this.onOpenTaskMaterial,
    required this.onOpenSettings,
    this.onPrepareMaterial,
  });

  final ScheduleController controller;
  final Future<void> Function(MaterialRef material) onOpenMaterial;
  final Future<void> Function(StudyTask task, MaterialRef material)
  onOpenTaskMaterial;
  final VoidCallback onOpenSettings;
  final Future<MaterialPreparationResult> Function(PlanSource source)?
  onPrepareMaterial;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final c = controller;
      return LayoutBuilder(
        key: const ValueKey('schedule-page'),
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 980;
          final content = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Toolbar(
                controller: c,
                wide: wide,
                onAdd: () => _addTask(context),
                onMenu: (action) => _handleMenu(context, action),
              ),
              Expanded(
                child: c.viewMode == ScheduleViewMode.path
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _ScheduleViewBar(controller: c, wide: wide),
                          Expanded(
                            child: _LearningPathView(
                              controller: c,
                              onStartLesson: (task) => showDailyLesson(
                                context,
                                c,
                                task,
                              ),
                            ),
                          ),
                        ],
                      )
                    : wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: LayoutBuilder(
                              builder: (context, stackBox) {
                                final sheetHeight = (stackBox.maxHeight * .62)
                                    .clamp(360.0, 520.0);
                                return Stack(
                                  children: [
                                    Positioned.fill(
                                      child: SingleChildScrollView(
                                        padding: const EdgeInsets.fromLTRB(
                                          24,
                                          4,
                                          24,
                                          84,
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            _ScheduleViewBar(
                                              controller: c,
                                              wide: true,
                                            ),
                                            Center(
                                              child: ConstrainedBox(
                                                constraints:
                                                    const BoxConstraints(
                                                      maxWidth: 760,
                                                    ),
                                                child:
                                                    c.calendarMode ==
                                                        CalendarDisplayMode.list
                                                    ? _AgendaList(controller: c)
                                                    : _calendarTransition(
                                                        context,
                                                        c,
                                                      ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    Positioned(
                                      left: 24,
                                      right: 24,
                                      bottom: 16,
                                      child: IgnorePointer(
                                        ignoring: c.planningOpen,
                                        child: Center(
                                          child: ConstrainedBox(
                                            constraints: const BoxConstraints(
                                              maxWidth: 760,
                                            ),
                                            child: AnimatedSwitcher(
                                              duration: context.motion(
                                                Motion.fast,
                                              ),
                                              switchInCurve: Motion.curve,
                                              switchOutCurve: Curves.easeIn,
                                              transitionBuilder:
                                                  (child, animation) =>
                                                      FadeTransition(
                                                        opacity: animation,
                                                        child: SlideTransition(
                                                          position:
                                                              Tween<Offset>(
                                                                begin:
                                                                    const Offset(
                                                                      0,
                                                                      .08,
                                                                    ),
                                                                end:
                                                                    Offset.zero,
                                                              ).animate(
                                                                animation,
                                                              ),
                                                          child: child,
                                                        ),
                                                      ),
                                              child: !c.planningOpen
                                                  ? _CalendarPlanningBar(
                                                      key: const ValueKey(
                                                        'planning-bar-dock',
                                                      ),
                                                      controller: c,
                                                      onOpen: () => c
                                                          .openPlanningPanel(),
                                                    )
                                                  : const SizedBox.shrink(
                                                      key: ValueKey(
                                                        'planning-bar-hidden',
                                                      ),
                                                    ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    Positioned.fill(
                                      child: IgnorePointer(
                                        ignoring: !c.planningOpen,
                                        child: AnimatedOpacity(
                                          opacity: c.planningOpen ? 1 : 0,
                                          duration: context.motion(Motion.base),
                                          curve: Motion.curve,
                                          child: GestureDetector(
                                            onTap: c.closePlanningPanel,
                                            child: Container(
                                              color: Colors.black.withValues(
                                                alpha: .08,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    Positioned(
                                      left: 24,
                                      right: 24,
                                      bottom: 16,
                                      height: sheetHeight,
                                      child: IgnorePointer(
                                        ignoring: !c.planningOpen,
                                        child: Center(
                                          child: ConstrainedBox(
                                            constraints: const BoxConstraints(
                                              maxWidth: 760,
                                            ),
                                            child: SizedBox(
                                              width: double.infinity,
                                              child: AnimatedSwitcher(
                                                duration: context.motion(
                                                  Motion.base,
                                                ),
                                                switchInCurve: Motion.curve,
                                                switchOutCurve:
                                                    Curves.easeInCubic,
                                                transitionBuilder:
                                                    (child, animation) {
                                                      final curved =
                                                          CurvedAnimation(
                                                            parent: animation,
                                                            curve: Motion.curve,
                                                            reverseCurve: Curves
                                                                .easeInCubic,
                                                          );
                                                      return FadeTransition(
                                                        opacity: curved,
                                                        child: SlideTransition(
                                                          position: Tween<Offset>(
                                                            begin: const Offset(
                                                              0,
                                                              .05,
                                                            ),
                                                            end: Offset.zero,
                                                          ).animate(curved),
                                                          child: ScaleTransition(
                                                            scale:
                                                                Tween<double>(
                                                                  begin: .98,
                                                                  end: 1,
                                                                ).animate(
                                                                  curved,
                                                                ),
                                                            child: child,
                                                          ),
                                                        ),
                                                      );
                                                    },
                                                child: c.planningOpen
                                                    ? PlanningSheet(
                                                        key: const ValueKey(
                                                          'planning-dialog',
                                                        ),
                                                        controller: c,
                                                        onOpenSettings:
                                                            onOpenSettings,
                                                        onClose: c
                                                            .closePlanningPanel,
                                                        embedded: true,
                                                      )
                                                    : const SizedBox.shrink(
                                                        key: ValueKey(
                                                          'planning-closed',
                                                        ),
                                                      ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ),
                          AnimatedContainer(
                            key: const ValueKey('day-panel'),
                            duration: context.motion(Motion.slow),
                            curve: Motion.curve,
                            width: c.dayPanelOpen ? 400 : 0,
                            clipBehavior: Clip.hardEdge,
                            decoration: const BoxDecoration(
                              color: Colors.transparent,
                            ),
                            child: OverflowBox(
                              alignment: Alignment.centerLeft,
                              minWidth: 400,
                              maxWidth: 400,
                              child: Container(
                                width: 400,
                                decoration: BoxDecoration(
                                  color: context.colors.surface,
                                  border: Border(
                                    left: BorderSide(
                                      color: context.colors.outline,
                                    ),
                                  ),
                                ),
                                child: _DayPanel(
                                  controller: c,
                                  wide: true,
                                  onOpenMaterial: onOpenMaterial,
                                  onAdd: () => _addTask(context),
                                  onMenu: (action) =>
                                      _handleMenu(context, action),
                                  onBlockAction: (block, action) =>
                                      _handleBlockAction(context, block, action),
                                  onCollapse: c.toggleDayPanel,
                                ),
                              ),
                            ),
                          ),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _ScheduleViewBar(controller: c, wide: false),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: c.calendarMode == CalendarDisplayMode.list
                                ? SizedBox(
                                    height: 420,
                                    child: SingleChildScrollView(
                                      child: _AgendaList(controller: c),
                                    ),
                                  )
                                : _calendarTransition(context, c),
                          ),
                          const SizedBox(height: 8),
                          Expanded(
                            child: _DayPanel(
                              controller: c,
                              wide: false,
                              onOpenMaterial: onOpenMaterial,
                              onAdd: () => _addTask(context),
                              onMenu: (action) => _handleMenu(context, action),
                              onBlockAction: (block, action) =>
                                  _handleBlockAction(context, block, action),
                            ),
                          ),
                        ],
                      ),
              ),
              if (!wide)
                _PlanningBar(
                  controller: c,
                  onOpen: () => showPlanningSheet(
                    context,
                    controller: c,
                    onOpenSettings: onOpenSettings,
                  ),
                ),
            ],
          );
          return content;
        },
      );
    },
  );

  Widget _calendarTransition(
    BuildContext context,
    ScheduleController c,
  ) {
    return AnimatedSwitcher(
      duration: context.motion(Motion.base),
      switchInCurve: Motion.curve,
      switchOutCurve: Curves.easeInCubic,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topCenter,
        fit: StackFit.passthrough,
        children: [
          ...previous,
          ?current,
        ],
      ),
      transitionBuilder: (child, animation) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Motion.curve,
          reverseCurve: Curves.easeInCubic,
        );
        final direction = c.monthDirection == 0 ? 1 : c.monthDirection;
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: Offset(.025 * direction, 0),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
        );
      },
      child: KeyedSubtree(
        key: ValueKey('calendar-${c.visibleMonth.iso}'),
        child: _CalendarGrid(
          controller: c,
          month: c.visibleMonth,
        ),
      ),
    );
  }

  Future<void> _toast(BuildContext context, String text) async {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _addTask(BuildContext context) async {
    final saved = await showTaskEditor(
      context,
      controller: controller,
      date: controller.selectedDate,
    );
    if (saved == true && context.mounted) {
      await _toast(context, '已写入日历');
    }
  }

  Future<StudyPlan?> _pickPlan(BuildContext context) async {
    if (controller.selectedPlan != null) return controller.selectedPlan;
    final active = controller.activePlans;
    if (active.isEmpty) {
      await _toast(context, '先建立学习计划，再使用自动排期。');
      return null;
    }
    if (active.length == 1) return active.single;
    return showAppDialog<StudyPlan>(
      context: context,
      builder: (context) => AppDialog(
        title: '选择计划',
        subtitle: '自动排期、可用时间与单日休息均作用于所选计划。',
        maxWidth: 420,
        actions: const [],
        content: Column(
          children: [
            for (final plan in active)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(plan.title),
                subtitle: Text(
                  '${plan.subject.isEmpty ? '未分科目' : plan.subject} · ${plan.rangeLabel}',
                ),
                trailing: const QIcon(QIcons.chevronRight, size: IconSizes.md),
                onTap: () => Navigator.pop(context, plan),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleMenu(BuildContext context, _MenuAction action) async {
    switch (action) {
      case _MenuAction.plans:
        await showPlanManager(
          context,
          controller,
          onOpenMaterial: onOpenMaterial,
          onPrepareMaterial: onPrepareMaterial,
        );
      case _MenuAction.availability:
        final plan = await _pickPlan(context);
        if (plan != null && context.mounted) {
          await showAvailabilityDialog(context, controller, plan);
        }
      case _MenuAction.autoSchedule:
        final plan = await _pickPlan(context);
        if (plan != null && context.mounted) {
          await _autoSchedule(context, plan);
        }
      case _MenuAction.undo:
        await _undo(context);
      case _MenuAction.toggleRest:
        final plan = await _pickPlan(context);
        if (plan == null || !context.mounted) return;
        if (controller.planFilterId != plan.id) {
          controller.selectPlan(plan.id);
        }
        final date = controller.selectedDate;
        final rest = controller.isRestDay(date);
        try {
          controller.setRestDay(date, rest: !rest);
          if (context.mounted) {
            await _toast(context, rest ? '已恢复每周安排' : '已设为休息日');
          }
        } catch (error) {
          if (context.mounted) await _toast(context, '$error');
        }
    }
  }

  Future<void> _autoSchedule(BuildContext context, StudyPlan plan) async {
    if (controller.availabilityFor(plan.id) == null) {
      await showAvailabilityDialog(context, controller, plan);
      if (!context.mounted) return;
      if (controller.availabilityFor(plan.id) == null) return;
    }
    try {
      final draft = controller.buildDraft(plan.id);
      if (!context.mounted) return;
      final revision = await showScheduleDraftDialog(
        context,
        controller: controller,
        draft: draft,
      );
      if (revision == null || !context.mounted) return;
      if (draft.addedBlocks.isNotEmpty) {
        controller.selectDate(draft.addedBlocks.first.date);
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('排期已应用'),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () {
              try {
                controller.undoLast();
              } catch (_) {
                // The menu also explains why an undo is no longer safe.
              }
            },
          ),
        ),
      );
    } on ScheduleValidationException catch (error) {
      await _toast(context, error.message);
    } on ScheduleConflictException catch (error) {
      await _toast(context, error.message);
    } catch (error) {
      await _toast(context, '生成排期失败：$error');
    }
  }

  Future<void> _undo(BuildContext context) async {
    final revision = controller.latestUndoableRevision;
    if (revision == null) {
      await _toast(context, '没有可撤销的排期。');
      return;
    }
    if (!controller.canUndoLatest) {
      await _toast(context, '之后已有新的日程修改，不能直接撤销这次排期。');
      return;
    }
    try {
      controller.undoLast();
      if (context.mounted) await _toast(context, '已撤销这次排期');
    } catch (error) {
      if (context.mounted) await _toast(context, '$error');
    }
  }

  Future<void> _handleBlockAction(
    BuildContext context,
    CalendarBlock block,
    _BlockAction action,
  ) async {
    final task = controller.taskFor(block);
    switch (action) {
      case _BlockAction.partial:
        await _partial(context, block);
      case _BlockAction.skip:
        await _skip(context, block);
      case _BlockAction.edit:
        final saved = await showTaskEditor(
          context,
          controller: controller,
          date: block.date,
          block: block,
        );
        if (saved == true && context.mounted) {
          await _toast(context, '安排已更新');
        }
      case _BlockAction.lock:
      case _BlockAction.unlock:
        try {
          controller.setBlockLocked(
            block,
            locked: action == _BlockAction.lock,
          );
          if (context.mounted) {
            await _toast(
              context,
              action == _BlockAction.lock ? '已锁定时间' : '已解除锁定',
            );
          }
        } catch (error) {
          if (context.mounted) await _toast(context, '$error');
        }
      case _BlockAction.delete:
        await _delete(context, block);
      case _BlockAction.openMaterial:
        final material = task?.material;
        if (material == null || task == null) {
          await _toast(context, '这个任务还没有绑定教材。');
          return;
        }
        await onOpenTaskMaterial(task, material);
      case _BlockAction.lesson:
        final lessonTask = task;
        if (lessonTask == null) {
          await _toast(context, '这个时间块没有关联学习任务。');
          return;
        }
        await showDailyLesson(
          context,
          controller,
          lessonTask,
          blockId: block.id,
        );
      case _BlockAction.catchUp:
        final catchUpTask = task;
        if (catchUpTask == null) {
          await _toast(context, '这个时间块没有关联学习任务。');
          return;
        }
        await showCatchUpDialog(context, controller, catchUpTask, block);
    }
  }

  Future<void> _partial(BuildContext context, CalendarBlock block) async {
    final result = await showAppDialog<({int minutes, String note})>(
      context: context,
      builder: (context) => _PartialDialog(block: block),
    );
    if (result == null || !context.mounted) return;
    try {
      controller.markBlock(
        block: block,
        fact: LearningFact.partial,
        completedMinutes: result.minutes,
        note: result.note,
      );
      if (context.mounted) {
        await _toast(context, '已记录 ${result.minutes} 分钟');
      }
    } catch (error) {
      if (context.mounted) await _toast(context, '$error');
    }
  }

  Future<void> _skip(BuildContext context, CalendarBlock block) async {
    final note = await showAppDialog<String>(
      context: context,
      builder: (context) => _SkipDialog(block: block),
    );
    if (note == null || !context.mounted) return;
    try {
      controller.markBlock(
        block: block,
        fact: LearningFact.skipped,
        note: note,
      );
      if (context.mounted) await _toast(context, '已标记跳过');
    } catch (error) {
      if (context.mounted) await _toast(context, '$error');
    }
  }

  Future<void> _delete(BuildContext context, CalendarBlock block) async {
    try {
      var thisAndFuture = false;
      if (block.seriesId != null && !block.detached && block.isStudy) {
        final scope = await showAppDialog<RepeatEditScope>(
          context: context,
          builder: (context) => AppDialog(
            title: '删除重复安排',
            subtitle: '已完成或已开始的历史块不会被删除。',
            maxWidth: 420,
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              OutlinedButton(
                onPressed: () =>
                    Navigator.pop(context, RepeatEditScope.thisOnly),
                child: const Text('仅这一次'),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.pop(context, RepeatEditScope.thisAndFuture),
                child: const Text('这次及以后'),
              ),
            ],
            content: Text(
              '「${controller.taskFor(block)?.title ?? block.title}」',
            ),
          ),
        );
        if (scope == null) return;
        thisAndFuture = scope == RepeatEditScope.thisAndFuture;
      } else {
        final confirmed = await showAppDialog<bool>(
          context: context,
          builder: (context) => AppDialog(
            title: '删除这个时间块？',
            maxWidth: 380,
            actions: [
              DialogActions.cancel(context),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('删除'),
              ),
            ],
            content: const Text('仅删除此安排，保留任务草稿与学习记录。'),
          ),
        );
        if (confirmed != true) return;
      }
      controller.deleteOccurrence(block, thisAndFuture: thisAndFuture);
      if (context.mounted) await _toast(context, '已删除');
    } catch (error) {
      if (context.mounted) await _toast(context, '$error');
    }
  }
}

LocalDate addMonthsClamped(LocalDate base, int deltaMonths) {
  final totalMonths = (base.year * 12 + (base.month - 1) + deltaMonths).clamp(
    1900 * 12,
    2200 * 12 + 11,
  );
  final targetYear = totalMonths ~/ 12;
  final targetMonth = (totalMonths % 12) + 1;
  final maxDay = LocalDate(targetYear, targetMonth, 1).daysInMonth;
  return LocalDate(targetYear, targetMonth, math.min(base.day, maxDay));
}

LocalDate? parseScheduleJumpInput(String raw, LocalDate anchor) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  switch (text) {
    case '今天':
      return anchor;
    case '明天':
      return anchor.addDays(1);
    case '后天':
      return anchor.addDays(2);
    case '昨天':
      return anchor.addDays(-1);
    case '前天':
      return anchor.addDays(-2);
  }

  LocalDate? tryDate(int y, int m, int d) {
    if (y < 1900 || y > 2200) return null;
    try {
      return LocalDate(y, m, d);
    } catch (_) {
      return null;
    }
  }

  final fullSep = RegExp(
    r'^(\d{4})\s*[-/.年]\s*(\d{1,2})\s*[-/.月]\s*(\d{1,2})\s*日?$',
  ).firstMatch(text);
  if (fullSep != null) {
    return tryDate(
      int.parse(fullSep.group(1)!),
      int.parse(fullSep.group(2)!),
      int.parse(fullSep.group(3)!),
    );
  }

  final compact8 = RegExp(r'^(\d{4})(\d{2})(\d{2})$').firstMatch(text);
  if (compact8 != null) {
    return tryDate(
      int.parse(compact8.group(1)!),
      int.parse(compact8.group(2)!),
      int.parse(compact8.group(3)!),
    );
  }

  final yearMonth = RegExp(
    r'^(\d{4})\s*[-/.年]\s*(\d{1,2})\s*月?$',
  ).firstMatch(text);
  if (yearMonth != null) {
    return tryDate(
      int.parse(yearMonth.group(1)!),
      int.parse(yearMonth.group(2)!),
      1,
    );
  }

  final compact6 = RegExp(r'^(\d{4})(\d{2})$').firstMatch(text);
  if (compact6 != null) {
    final m = int.parse(compact6.group(2)!);
    if (m >= 1 && m <= 12) {
      return tryDate(int.parse(compact6.group(1)!), m, 1);
    }
  }

  final monthDay = RegExp(
    r'^(\d{1,2})\s*[-/.月]\s*(\d{1,2})\s*日?$',
  ).firstMatch(text);
  if (monthDay != null) {
    return tryDate(
      anchor.year,
      int.parse(monthDay.group(1)!),
      int.parse(monthDay.group(2)!),
    );
  }

  final offsetDaysOnly = RegExp(r'^([+-]?)\s*(\d{1,4})$').firstMatch(text);
  if (offsetDaysOnly != null) {
    final sign = offsetDaysOnly.group(1) == '-' ? -1 : 1;
    final days = int.parse(offsetDaysOnly.group(2)!) * sign;
    final target = anchor.addDays(days);
    return target.year >= 1900 && target.year <= 2200 ? target : null;
  }

  final relUnit = RegExp(
    r'^([+-]?)\s*(\d{1,4})\s*(天|日|周|星期|个月|月|年|d|w|m|y)\s*(前|后)?$',
    caseSensitive: false,
  ).firstMatch(text);
  if (relUnit != null) {
    final prefixSign = relUnit.group(1);
    final suffixDir = relUnit.group(4);
    final sign = (prefixSign == '-' || suffixDir == '前') ? -1 : 1;
    final n = int.parse(relUnit.group(2)!) * sign;
    final unit = relUnit.group(3)!.toLowerCase();
    final LocalDate target;
    switch (unit) {
      case '天':
      case '日':
      case 'd':
        target = anchor.addDays(n.clamp(-36500, 36500));
      case '周':
      case '星期':
      case 'w':
        target = anchor.addDays((n * 7).clamp(-36500, 36500));
      case '个月':
      case '月':
      case 'm':
        target = addMonthsClamped(anchor, n);
      case '年':
      case 'y':
        target = addMonthsClamped(anchor, n * 12);
      default:
        return null;
    }
    return target.year >= 1900 && target.year <= 2200 ? target : null;
  }

  return null;
}

Future<void> showJumpDialog(
  BuildContext context,
  ScheduleController controller,
) {
  return showAppDialog<void>(
    context: context,
    builder: (context) => _JumpDialog(controller: controller),
  );
}

class _JumpDialog extends StatefulWidget {
  const _JumpDialog({required this.controller});

  final ScheduleController controller;

  @override
  State<_JumpDialog> createState() => _JumpDialogState();
}

class _JumpDialogState extends State<_JumpDialog> {
  final _textCtrl = TextEditingController();
  late final _amountCtrl = TextEditingController(text: '$_amount');
  String? _textError;
  _JumpNumericMode _numericMode = _JumpNumericMode.relative;
  int _amount = 7;
  _JumpUnit _unit = _JumpUnit.day;
  bool _forward = true;
  bool _fromSelected = false;

  late int _pickYear = widget.controller.selectedDate.year.clamp(1900, 2200);
  late int _pickMonth = widget.controller.selectedDate.month;
  late int _pickDay = widget.controller.selectedDate.day;

  @override
  void dispose() {
    _textCtrl.dispose();
    _amountCtrl.dispose();
    super.dispose();
  }

  LocalDate get _today => widget.controller.today;

  LocalDate get _anchor =>
      _fromSelected ? widget.controller.selectedDate : _today;

  LocalDate? get _parsedTextTarget =>
      parseScheduleJumpInput(_textCtrl.text, _anchor);

  LocalDate get _relativeTarget {
    final signed = _forward ? _amount : -_amount;
    final LocalDate target;
    switch (_unit) {
      case _JumpUnit.day:
        target = _anchor.addDays(signed.clamp(-36500, 36500));
      case _JumpUnit.week:
        target = _anchor.addDays((signed * 7).clamp(-36500, 36500));
      case _JumpUnit.month:
        target = addMonthsClamped(_anchor, signed);
      case _JumpUnit.year:
        target = addMonthsClamped(_anchor, signed * 12);
    }
    if (target.year < 1900) return LocalDate(1900, 1, 1);
    if (target.year > 2200) return LocalDate(2200, 12, 31);
    return target;
  }

  LocalDate get _ymdTarget {
    final maxDay = LocalDate(_pickYear, _pickMonth, 1).daysInMonth;
    return LocalDate(_pickYear, _pickMonth, math.min(_pickDay, maxDay));
  }

  LocalDate get _activeNumericTarget =>
      _numericMode == _JumpNumericMode.relative ? _relativeTarget : _ymdTarget;

  String _deltaDescription(LocalDate target) {
    final diff = target.differenceInDays(_today);
    if (diff == 0) return '今天';
    if (diff > 0) return '距今天还有 $diff 天';
    return '距今天已过去 ${-diff} 天';
  }

  void _setAmount(int value) {
    final clamped = value.clamp(1, 9999);
    setState(() {
      _amount = clamped;
      _amountCtrl.text = '$clamped';
      _amountCtrl.selection = TextSelection.collapsed(
        offset: _amountCtrl.text.length,
      );
    });
  }

  void _setYmd({int? year, int? month, int? day}) {
    setState(() {
      final y = (year ?? _pickYear).clamp(1900, 2200);
      final m = (month ?? _pickMonth).clamp(1, 12);
      final maxD = LocalDate(y, m, 1).daysInMonth;
      final d = (day ?? _pickDay).clamp(1, maxD);
      _pickYear = y;
      _pickMonth = m;
      _pickDay = d;
    });
  }

  void _jumpTo(LocalDate target) {
    widget.controller.selectDate(target);
    Navigator.maybePop(context);
  }

  void _submitText() {
    final target = _parsedTextTarget;
    if (target == null) {
      setState(() => _textError = '支持 2027-05-20、20270520、+7、3周、2月 等格式');
      return;
    }
    _jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final today = _today;
    final tomorrow = today.addDays(1);
    final nextMonday = today.addDays(8 - today.weekday);
    final nextMonth = LocalDate(
      today.month == 12 ? today.year + 1 : today.year,
      today.month == 12 ? 1 : today.month + 1,
      1,
    );
    final nextExam = widget.controller.nextExamOnOrAfter(today);
    final nextUpcoming = widget.controller.nextUpcomingBlockDate(today);
    final typedPreview = _textCtrl.text.trim().isEmpty
        ? null
        : _parsedTextTarget;
    final numericTarget = _activeNumericTarget;

    return AppDialog(
      title: '跳转日期',
      subtitle: '可输入日期或偏移天数，也可直接选数字决定跳转到什么时候',
      maxWidth: 440,
      actions: [
        TextButton(
          onPressed: () {
            Navigator.maybePop(context);
            showMonthPicker(
              context,
              widget.controller,
              initialMode: DateJumpMode.day,
            );
          },
          child: const Text('月历选日…'),
        ),
        DialogActions.cancel(context),
      ],
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('jump-dialog-input'),
                  controller: _textCtrl,
                  autofocus: true,
                  onSubmitted: (_) => _submitText(),
                  onChanged: (_) => setState(() => _textError = null),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '输入 2027-05-20、+7、3周、2月…',
                    errorText: _textError,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey('jump-dialog-input-submit'),
                onPressed: _submitText,
                child: const Text('直达'),
              ),
            ],
          ),
          if (typedPreview != null) ...[
            const SizedBox(height: 6),
            Text(
              '将跳转：${typedPreview.longLabel}（${_deltaDescription(typedPreview)}）',
              style: context.texts.bodySmall!.copyWith(
                fontSize: 12,
                color: c.primary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ActionChip(
                label: Text('今天（${today.shortLabel}）'),
                onPressed: () {
                  widget.controller.goToday();
                  Navigator.maybePop(context);
                },
              ),
              ActionChip(
                label: Text('明天（${tomorrow.shortLabel}）'),
                onPressed: () => _jumpTo(tomorrow),
              ),
              ActionChip(
                label: Text('下周一（${nextMonday.shortLabel}）'),
                onPressed: () => _jumpTo(nextMonday),
              ),
              ActionChip(
                label: Text('下个月（${nextMonth.monthLabel}）'),
                onPressed: () {
                  widget.controller.selectMonth(nextMonth);
                  Navigator.maybePop(context);
                },
              ),
              if (nextExam?.examDate != null)
                ActionChip(
                  label: Text(
                    '最近考试：${nextExam!.subject.isEmpty ? nextExam.title : nextExam.subject}（${nextExam.examDate!.shortLabel}）',
                  ),
                  onPressed: () => _jumpTo(nextExam.examDate!),
                ),
              if (nextUpcoming != null)
                ActionChip(
                  label: Text('下一场安排（${nextUpcoming.shortLabel}）'),
                  onPressed: () => _jumpTo(nextUpcoming),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Divider(height: 1, color: c.outline),
          const SizedBox(height: 12),
          AppSegmentedControl(
            key: const ValueKey('jump-numeric-mode'),
            expand: true,
            dense: true,
            segments: const [
              AppSegment(label: '按数字推算'),
              AppSegment(label: '年/月/日'),
            ],
            selectedIndex: _numericMode.index,
            onChanged: (index) => setState(
              () => _numericMode = _JumpNumericMode.values[index],
            ),
          ),
          const SizedBox(height: 12),
          if (_numericMode == _JumpNumericMode.relative) ...[
            _buildRelativeSection(context),
          ] else ...[
            _buildYmdSection(context),
          ],
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: c.sidebar,
              borderRadius: BorderRadius.circular(Radii.md),
              border: Border.all(color: c.outline),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        numericTarget.longLabel,
                        key: const ValueKey('jump-numeric-preview'),
                        style: context.texts.bodyMedium!.copyWith(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _deltaDescription(numericTarget),
                        style: context.texts.bodySmall!.copyWith(
                          fontSize: 11.5,
                          color: c.inkMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: const ValueKey('jump-numeric-submit'),
                  onPressed: () => _jumpTo(numericTarget),
                  child: const Text('跳转到该日'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRelativeSection(BuildContext context) {
    final c = context.colors;
    const presets = [1, 3, 5, 7, 14, 30, 60, 90];
    final showAnchorSwitch = widget.controller.selectedDate != _today;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Container(
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(Radii.sm),
                border: Border.all(color: c.outlineStrong),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    key: const ValueKey('jump-amount-dec'),
                    tooltip: '减少数量',
                    onPressed: _amount > 1
                        ? () => _setAmount(_amount - 1)
                        : null,
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 34,
                    ),
                    padding: EdgeInsets.zero,
                    icon: const QIcon(QIcons.chevronLeft, size: IconSizes.md),
                  ),
                  SizedBox(
                    width: 62,
                    child: TextField(
                      key: const ValueKey('jump-amount-input'),
                      controller: _amountCtrl,
                      textAlign: TextAlign.center,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      style: context.texts.bodyMedium!.copyWith(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        fontFeatures: AppNumerals.tabular,
                      ),
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 8,
                        ),
                      ),
                      onChanged: (raw) {
                        final parsed = int.tryParse(raw);
                        if (parsed != null && parsed >= 1) {
                          setState(() => _amount = parsed.clamp(1, 9999));
                        }
                      },
                      onSubmitted: (_) => _jumpTo(_relativeTarget),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('jump-amount-inc'),
                    tooltip: '增加数量',
                    onPressed: _amount < 9999
                        ? () => _setAmount(_amount + 1)
                        : null,
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 34,
                    ),
                    padding: EdgeInsets.zero,
                    icon: const QIcon(QIcons.chevronRight, size: IconSizes.md),
                  ),
                ],
              ),
            ),
            Wrap(
              spacing: 4,
              children: [
                for (final unit in _JumpUnit.values)
                  ChoiceChip(
                    key: ValueKey('jump-unit-${unit.name}'),
                    label: Text(unit.label),
                    selected: _unit == unit,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => setState(() => _unit = unit),
                  ),
              ],
            ),
            Wrap(
              spacing: 4,
              children: [
                ChoiceChip(
                  key: const ValueKey('jump-dir-after'),
                  label: const Text('后'),
                  selected: _forward,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => setState(() => _forward = true),
                ),
                ChoiceChip(
                  key: const ValueKey('jump-dir-before'),
                  label: const Text('前'),
                  selected: !_forward,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => setState(() => _forward = false),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '常用数字：',
              style: context.texts.bodySmall!.copyWith(
                fontSize: 11.5,
                color: c.inkMuted,
              ),
            ),
            for (final n in presets)
              ChoiceChip(
                key: ValueKey('jump-preset-$n'),
                label: Text('$n'),
                selected: _amount == n,
                visualDensity: VisualDensity.compact,
                onSelected: (_) => _setAmount(n),
              ),
          ],
        ),
        if (showAnchorSwitch) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '起算基准：',
                style: context.texts.bodySmall!.copyWith(
                  fontSize: 11.5,
                  color: c.inkMuted,
                ),
              ),
              ChoiceChip(
                label: Text('今天（${_today.shortLabel}）'),
                selected: !_fromSelected,
                visualDensity: VisualDensity.compact,
                onSelected: (_) => setState(() => _fromSelected = false),
              ),
              ChoiceChip(
                label: Text(
                  '当前选中（${widget.controller.selectedDate.shortLabel}）',
                ),
                selected: _fromSelected,
                visualDensity: VisualDensity.compact,
                onSelected: (_) => setState(() => _fromSelected = true),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildYmdSection(BuildContext context) {
    final minYear = math.min(_today.year - 5, _pickYear).clamp(1900, 2200);
    final maxYear = math.max(_today.year + 15, _pickYear).clamp(1900, 2200);
    final years = [for (var y = minYear; y <= maxYear; y++) y];
    final daysInMonth = LocalDate(_pickYear, _pickMonth, 1).daysInMonth;
    final months = [for (var m = 1; m <= 12; m++) m];
    final days = [for (var d = 1; d <= daysInMonth; d++) d];

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _JumpNumberRow(
          fieldId: 'year',
          label: '年份',
          value: _pickYear,
          values: years,
          formatValue: (y) => '$y 年',
          canDec: _pickYear > 1900,
          canInc: _pickYear < 2200,
          onStep: (delta) => _setYmd(year: _pickYear + delta),
          onSelected: (y) => _setYmd(year: y),
        ),
        const SizedBox(height: 8),
        _JumpNumberRow(
          fieldId: 'month',
          label: '月份',
          value: _pickMonth,
          values: months,
          formatValue: (m) => '$m 月',
          canDec: _pickMonth > 1,
          canInc: _pickMonth < 12,
          onStep: (delta) => _setYmd(month: _pickMonth + delta),
          onSelected: (m) => _setYmd(month: m),
        ),
        const SizedBox(height: 8),
        _JumpNumberRow(
          fieldId: 'day',
          label: '日期',
          value: math.min(_pickDay, daysInMonth),
          values: days,
          formatValue: (d) => '$d 日',
          canDec: _pickDay > 1,
          canInc: _pickDay < daysInMonth,
          onStep: (delta) => _setYmd(day: _pickDay + delta),
          onSelected: (d) => _setYmd(day: d),
        ),
      ],
    );
  }
}

class _JumpNumberRow extends StatelessWidget {
  const _JumpNumberRow({
    required this.fieldId,
    required this.label,
    required this.value,
    required this.values,
    required this.formatValue,
    required this.canDec,
    required this.canInc,
    required this.onStep,
    required this.onSelected,
  });

  final String fieldId;
  final String label;
  final int value;
  final List<int> values;
  final String Function(int) formatValue;
  final bool canDec;
  final bool canInc;
  final ValueChanged<int> onStep;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        SizedBox(
          width: 44,
          child: Text(
            label,
            style: context.texts.bodySmall!.copyWith(
              fontSize: 12.5,
              color: c.inkMuted,
            ),
          ),
        ),
        Expanded(
          child: Container(
            height: 36,
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: c.outlineStrong),
            ),
            child: Row(
              children: [
                IconButton(
                  key: ValueKey('jump-$fieldId-dec'),
                  tooltip: '减一',
                  onPressed: canDec ? () => onStep(-1) : null,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 34,
                    minHeight: 34,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const QIcon(QIcons.chevronLeft, size: IconSizes.md),
                ),
                Expanded(
                  child: Center(
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        key: ValueKey('jump-$fieldId-dropdown'),
                        value: value,
                        isDense: true,
                        alignment: Alignment.center,
                        icon: QIcon(
                          QIcons.chevronDown,
                          size: IconSizes.sm,
                          color: c.inkMuted,
                        ),
                        style: context.texts.bodyMedium!.copyWith(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: c.ink,
                          fontFeatures: AppNumerals.tabular,
                        ),
                        items: [
                          for (final item in values)
                            DropdownMenuItem<int>(
                              value: item,
                              child: Text(formatValue(item)),
                            ),
                        ],
                        onChanged: (next) {
                          if (next != null) onSelected(next);
                        },
                      ),
                    ),
                  ),
                ),
                IconButton(
                  key: ValueKey('jump-$fieldId-inc'),
                  tooltip: '加一',
                  onPressed: canInc ? () => onStep(1) : null,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 34,
                    minHeight: 34,
                  ),
                  padding: EdgeInsets.zero,
                  icon: const QIcon(QIcons.chevronRight, size: IconSizes.md),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

Future<void> showMonthPicker(
  BuildContext context,
  ScheduleController controller, {
  DateJumpMode initialMode = DateJumpMode.month,
}) {
  return showAppDialog<void>(
    context: context,
    builder: (context) => _MonthPickerDialog(
      controller: controller,
      initialMode: initialMode,
    ),
  );
}

class _MonthPickerDialog extends StatefulWidget {
  const _MonthPickerDialog({
    required this.controller,
    this.initialMode = DateJumpMode.month,
  });

  final ScheduleController controller;
  final DateJumpMode initialMode;

  @override
  State<_MonthPickerDialog> createState() => _MonthPickerDialogState();
}

class _MonthPickerDialogState extends State<_MonthPickerDialog> {
  late DateJumpMode _mode = widget.initialMode;
  late int _year = widget.initialMode == DateJumpMode.day
      ? widget.controller.selectedDate.year
      : widget.controller.visibleMonth.year;
  late int _month = widget.initialMode == DateJumpMode.day
      ? widget.controller.selectedDate.month
      : widget.controller.visibleMonth.month;
  int _direction = 0;
  final _jumpInput = TextEditingController();
  String? _jumpError;

  @override
  void dispose() {
    _jumpInput.dispose();
    super.dispose();
  }

  int get _decadeStart => (((_year - 1900) ~/ 12) * 12 + 1900).clamp(1900, 2188);

  void _shiftYear(int delta) {
    setState(() {
      _year = (_year + delta).clamp(1900, 2200);
      _direction = delta.sign;
    });
  }

  void _shiftMonth(int delta) {
    final target = LocalDate(
      _year,
      _month,
      delta > 0 ? LocalDate(_year, _month, 1).daysInMonth : 1,
    ).addDays(delta > 0 ? 1 : -1);
    setState(() {
      _year = target.year.clamp(1900, 2200);
      _month = target.month;
      _direction = delta.sign;
    });
  }

  void _selectYear(int year) {
    setState(() {
      _year = year.clamp(1900, 2200);
      _direction = 1;
      _mode = DateJumpMode.month;
    });
  }

  void _selectMonth(int month) {
    widget.controller.selectMonth(LocalDate(_year, month, 1));
    Navigator.maybePop(context);
  }

  void _selectDay(int day) {
    widget.controller.selectDate(LocalDate(_year, _month, day));
    Navigator.maybePop(context);
  }

  void _jumpTo(LocalDate date) {
    widget.controller.selectDate(date);
    Navigator.maybePop(context);
  }

  void _goToday() {
    widget.controller.goToday();
    Navigator.maybePop(context);
  }

  void _submitTypedDate() {
    final parsed = parseScheduleJumpInput(
      _jumpInput.text,
      widget.controller.today,
    );
    if (parsed == null) {
      setState(() => _jumpError = '格式如 2027-05-20、+7 或 2周');
      return;
    }
    setState(() => _jumpError = null);
    _jumpTo(parsed);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final duration = context.motion(Motion.base);
    final today = widget.controller.today;
    final nextExam = widget.controller.nextExamOnOrAfter(today);
    final title = switch (_mode) {
      DateJumpMode.year => '选择年份',
      DateJumpMode.month => '选择月份',
      DateJumpMode.day => '选择日期',
    };
    final subtitle = switch (_mode) {
      DateJumpMode.year => '按 12 年浏览，点选年份后选月或选日',
      DateJumpMode.month => '点年份可跨年选择，点月份立即跳转',
      DateJumpMode.day => '点选具体某日，或下方快捷/输入直达',
    };

    return AppDialog(
      title: title,
      subtitle: subtitle,
      maxWidth: 420,
      actions: [
        TextButton(onPressed: _goToday, child: const Text('回到今天')),
        DialogActions.cancel(context),
      ],
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: AppSegmentedControl(
              key: const ValueKey('date-jump-mode'),
              expand: false,
              segmentMinWidth: 76,
              segments: const [
                AppSegment(label: '年份'),
                AppSegment(label: '月份'),
                AppSegment(label: '某日'),
              ],
              selectedIndex: _mode.index,
              onChanged: (index) => setState(() {
                _mode = DateJumpMode.values[index];
                _direction = 0;
              }),
            ),
          ),
          const SizedBox(height: 12),
          AnimatedSwitcher(
            duration: duration,
            switchInCurve: Motion.curve,
            switchOutCurve: Curves.easeIn,
            transitionBuilder: (child, animation) {
              final curved = CurvedAnimation(
                parent: animation,
                curve: Motion.curve,
              );
              return FadeTransition(
                opacity: curved,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: Offset(.025 * _direction, 0),
                    end: Offset.zero,
                  ).animate(curved),
                  child: child,
                ),
              );
            },
            child: KeyedSubtree(
              key: ValueKey('picker-${_mode.name}-$_year-$_month'),
              child: switch (_mode) {
                DateJumpMode.year => _buildYearBody(context, today),
                DateJumpMode.month => _buildMonthBody(context, today),
                DateJumpMode.day => _buildDayBody(context, today),
              },
            ),
          ),
          const SizedBox(height: 12),
          Divider(height: 1, color: c.outline),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ActionChip(
                label: const Text('今天'),
                onPressed: _goToday,
              ),
              ActionChip(
                label: const Text('明天'),
                onPressed: () => _jumpTo(today.addDays(1)),
              ),
              ActionChip(
                label: const Text('下周一'),
                onPressed: () => _jumpTo(today.addDays(8 - today.weekday)),
              ),
              if (nextExam?.examDate != null)
                ActionChip(
                  label: Text('考试日 ${nextExam!.examDate!.shortLabel}'),
                  onPressed: () => _jumpTo(nextExam.examDate!),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('date-jump-input'),
                  controller: _jumpInput,
                  onSubmitted: (_) => _submitTypedDate(),
                  onChanged: (_) {
                    if (_jumpError != null) setState(() => _jumpError = null);
                  },
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '输入 2027-05-20、+7 或 2周',
                    errorText: _jumpError,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey('date-jump-submit'),
                onPressed: _submitTypedDate,
                child: const Text('直达'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildYearBody(BuildContext context, LocalDate today) {
    final start = _decadeStart;
    final end = math.min(start + 11, 2200);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: '上 12 年',
              onPressed: start > 1900 ? () => _shiftYear(-12) : null,
              visualDensity: VisualDensity.compact,
              icon: const QIcon(QIcons.chevronLeft, size: IconSizes.md),
            ),
            Expanded(
              child: Text(
                '$start – $end 年',
                textAlign: TextAlign.center,
                style: context.texts.titleSmall!.copyWith(fontSize: 15),
              ),
            ),
            IconButton(
              tooltip: '下 12 年',
              onPressed: end < 2200 ? () => _shiftYear(12) : null,
              visualDensity: VisualDensity.compact,
              icon: const QIcon(QIcons.chevronRight, size: IconSizes.md),
            ),
          ],
        ),
        const SizedBox(height: 6),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 2.25,
          children: [
            for (var y = start; y <= end; y++)
              _PickerTile(
                key: ValueKey('year-option-$y'),
                label: '$y 年',
                selected: widget.controller.visibleMonth.year == y || _year == y,
                today: today.year == y,
                onTap: () => _selectYear(y),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildMonthBody(BuildContext context, LocalDate today) {
    final c = context.colors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: '上一年',
              onPressed: _year > 1900 ? () => _shiftYear(-1) : null,
              visualDensity: VisualDensity.compact,
              icon: const QIcon(QIcons.chevronLeft, size: IconSizes.md),
            ),
            Expanded(
              child: Center(
                child: InkWell(
                  onTap: () => setState(() => _mode = DateJumpMode.year),
                  borderRadius: BorderRadius.circular(Radii.sm),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$_year 年',
                          style: context.texts.titleSmall!.copyWith(
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(width: 2),
                        QIcon(
                          QIcons.chevronDown,
                          size: IconSizes.sm,
                          color: c.inkMuted,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: '下一年',
              onPressed: _year < 2200 ? () => _shiftYear(1) : null,
              visualDensity: VisualDensity.compact,
              icon: const QIcon(QIcons.chevronRight, size: IconSizes.md),
            ),
          ],
        ),
        const SizedBox(height: 6),
        GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: 2.25,
          children: [
            for (var month = 1; month <= 12; month++)
              _PickerTile(
                key: ValueKey('month-option-$month'),
                label: '$month 月',
                selected:
                    widget.controller.visibleMonth.year == _year &&
                    widget.controller.visibleMonth.month == month,
                today: today.year == _year && today.month == month,
                onTap: () => _selectMonth(month),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildDayBody(BuildContext context, LocalDate today) {
    final c = context.colors;
    final first = LocalDate(_year, _month, 1);
    final leadingBlanks = first.weekday - 1;
    final daysInMonth = first.daysInMonth;
    final selected = widget.controller.selectedDate;
    final activeDays = <int>{
      for (final block in widget.controller.repository.getBlocks(
        start: first,
        end: first.lastOfMonth,
      ))
        if (widget.controller.isBlockVisible(block)) block.date.day,
    };
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    final totalSlots = ((leadingBlanks + daysInMonth + 6) ~/ 7) * 7;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: '上个月',
              onPressed: () => _shiftMonth(-1),
              visualDensity: VisualDensity.compact,
              icon: const QIcon(QIcons.chevronLeft, size: IconSizes.md),
            ),
            Expanded(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  InkWell(
                    onTap: () => setState(() => _mode = DateJumpMode.year),
                    borderRadius: BorderRadius.circular(Radii.sm),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 4,
                      ),
                      child: Text(
                        '$_year 年',
                        style: context.texts.titleSmall!.copyWith(fontSize: 14),
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: () => setState(() => _mode = DateJumpMode.month),
                    borderRadius: BorderRadius.circular(Radii.sm),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 4,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '$_month 月',
                            style: context.texts.titleSmall!.copyWith(
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(width: 2),
                          QIcon(
                            QIcons.chevronDown,
                            size: IconSizes.sm,
                            color: c.inkMuted,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '下个月',
              onPressed: () => _shiftMonth(1),
              visualDensity: VisualDensity.compact,
              icon: const QIcon(QIcons.chevronRight, size: IconSizes.md),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            for (final w in weekdays)
              Expanded(
                child: Center(
                  child: Text(
                    w,
                    style: context.texts.bodySmall!.copyWith(
                      fontSize: 11,
                      color: c.inkMuted,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: totalSlots,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 7,
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
            childAspectRatio: 1.08,
          ),
          itemBuilder: (context, index) {
            final day = index - leadingBlanks + 1;
            if (day < 1 || day > daysInMonth) {
              return const SizedBox.shrink();
            }
            final cellDate = LocalDate(_year, _month, day);
            final isSelected = selected == cellDate;
            final isToday = today == cellDate;
            final hasBlock = activeDays.contains(day);
            return Material(
              color: isSelected
                  ? c.primary
                  : (isToday ? c.tint : Colors.transparent),
              borderRadius: BorderRadius.circular(Radii.sm),
              child: InkWell(
                key: ValueKey('day-picker-day-$day'),
                onTap: () => _selectDay(day),
                borderRadius: BorderRadius.circular(Radii.sm),
                hoverColor: c.tint.withValues(alpha: .65),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(Radii.sm),
                    border: Border.all(
                      color: isSelected
                          ? Colors.transparent
                          : (isToday
                                ? c.primary.withValues(alpha: .45)
                                : Colors.transparent),
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        '$day',
                        style: context.texts.bodySmall!.copyWith(
                          fontSize: 12.5,
                          color: isSelected ? c.onPrimary : c.ink,
                          fontWeight: isSelected || isToday
                              ? FontWeight.w700
                              : FontWeight.w500,
                          fontFeatures: AppNumerals.tabular,
                        ),
                      ),
                      if (hasBlock)
                        Container(
                          width: 4,
                          height: 4,
                          margin: const EdgeInsets.only(top: 1),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: isSelected ? c.onPrimary : c.primary,
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
    );
  }
}

class _PickerTile extends StatelessWidget {
  const _PickerTile({
    super.key,
    required this.label,
    required this.selected,
    required this.today,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool today;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: selected ? c.primary : (today ? c.tint : c.surface),
      borderRadius: BorderRadius.circular(Radii.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.sm),
        hoverColor: c.tint.withValues(alpha: .55),
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.sm),
            border: Border.all(
              color: selected
                  ? Colors.transparent
                  : (today ? c.primary.withValues(alpha: .35) : c.outline),
            ),
          ),
          child: Text(
            label,
            style: context.texts.bodySmall!.copyWith(
              fontSize: 13,
              color: selected ? c.onPrimary : c.ink,
              fontWeight: selected || today
                  ? FontWeight.w600
                  : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _ScheduleViewBar extends StatelessWidget {
  const _ScheduleViewBar({required this.controller, required this.wide});

  final ScheduleController controller;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 360;
    if (narrow && !wide) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.fromLTRB(wide ? 24 : 16, 0, wide ? 24 : 16, 8),
      child: Wrap(
        spacing: 10,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          AppSegmentedControl(
            key: const ValueKey('schedule-view-switch'),
            expand: false,
            segmentMinWidth: 88,
            segments: const [
              AppSegment(label: '日历'),
              AppSegment(label: '学习路径'),
            ],
            selectedIndex: controller.viewMode == ScheduleViewMode.calendar
                ? 0
                : 1,
            onChanged: (index) => controller.setViewMode(
              index == 1
                  ? ScheduleViewMode.path
                  : ScheduleViewMode.calendar,
            ),
          ),
          if (controller.viewMode == ScheduleViewMode.calendar)
            AppSegmentedControl(
              key: const ValueKey('calendar-mode-switch'),
              expand: false,
              segmentMinWidth: 68,
              segments: const [
                AppSegment(label: '月'),
                AppSegment(label: '列表'),
              ],
              selectedIndex:
                  controller.calendarMode == CalendarDisplayMode.month ? 0 : 1,
              onChanged: (index) => controller.setCalendarMode(
                index == 1
                    ? CalendarDisplayMode.list
                    : CalendarDisplayMode.month,
              ),
            ),
          if (controller.viewMode == ScheduleViewMode.calendar)
            PopupMenuButton<CalendarLayer>(
              key: const ValueKey('calendar-layer-filter'),
              tooltip: '显示内容',
              onSelected: controller.toggleLayer,
              itemBuilder: (context) => [
                for (final layer in CalendarLayer.values)
                  CheckedPopupMenuItem(
                    value: layer,
                    checked: controller.isLayerVisible(layer),
                    child: Text(layer.label),
                  ),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const QIcon(QIcons.visible, size: IconSizes.sm),
                    const SizedBox(width: 4),
                    Text(
                      '显示内容',
                      style: context.texts.bodySmall!.copyWith(fontSize: 12.5),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _AgendaList extends StatelessWidget {
  const _AgendaList({required this.controller});

  final ScheduleController controller;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final start = controller.selectedDate;
    final end = start.addDays(13);
    final blocks = controller.repository
        .getBlocks(start: start, end: end)
        .where(controller.isBlockVisible)
        .toList();
    final grouped = <LocalDate, List<CalendarBlock>>{};
    for (final block in blocks) {
      grouped.putIfAbsent(block.date, () => []).add(block);
    }
    final dates = [for (var i = 0; i < 14; i++) start.addDays(i)];
    return ListView(
      key: const ValueKey('schedule-agenda-list'),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (final date in dates)
          if (grouped[date] != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: c.surface,
                  border: Border.all(color: c.outline),
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    InkWell(
                      onTap: () => controller.selectDate(date),
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          date.longLabel,
                          style: context.texts.bodySmall!.copyWith(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    for (final block in grouped[date]!)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 86,
                              child: Text(
                                '${formatMinuteOfDay(block.startMinute)}–'
                                '${formatMinuteOfDay(block.endMinute)}',
                                style: context.texts.bodySmall!.copyWith(
                                  fontSize: 11.5,
                                  fontFeatures: AppNumerals.tabular,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                block.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: context.texts.bodySmall!.copyWith(
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                            if (block.isStudy)
                              AppBadge(
                                label: block.state.name,
                                dense: true,
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
        if (grouped.isEmpty)
          const Padding(
            padding: EdgeInsets.all(20),
            child: EmptyState(
              icon: QIcons.plan,
              title: '未来 14 天还没有安排',
              message: '可以回到月历选日期，或使用底部 AI 排课建立计划。',
              compact: true,
            ),
          ),
      ],
    );
  }
}

class _LearningPathView extends StatelessWidget {
  const _LearningPathView({
    required this.controller,
    required this.onStartLesson,
  });

  final ScheduleController controller;
  final Future<void> Function(StudyTask task) onStartLesson;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final plan = controller.selectedPlan;
    if (plan == null) {
      return ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            '选择计划查看学习路径',
            style: context.texts.titleSmall!.copyWith(fontSize: 15),
          ),
          const SizedBox(height: 8),
          for (final item in controller.activePlans) ...[
            Card(
              color: c.surface,
              child: ListTile(
                title: Text(item.title),
                subtitle: Text(item.rangeLabel),
                trailing: const QIcon(QIcons.chevronRight, size: IconSizes.md),
                onTap: () => controller.selectPlan(item.id),
              ),
            ),
          ],
          if (controller.activePlans.isEmpty)
            const EmptyState(
              icon: QIcons.route,
              title: '还没有计划',
              message: '先建立计划，再查看知识点与学习路径。',
              compact: true,
            ),
        ],
      );
    }
    final items = controller.repository.getKnowledgeItems(plan.id);
    final tasks = controller.repository.getTasks(planId: plan.id);
    final tasksById = {for (final task in tasks) task.id: task};
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          plan.title,
          style: context.texts.titleSmall!.copyWith(fontSize: 16),
        ),
        const SizedBox(height: 4),
        Text(
          '${plan.rangeLabel} · ${items.length} 个知识点 · 按优先级和前置顺序展示',
          style: context.texts.bodySmall!.copyWith(fontSize: 12),
        ),
        const SizedBox(height: 12),
        if (items.isEmpty)
          const EmptyState(
            icon: QIcons.knowledge,
            title: '还没有知识点',
            message: '从计划材料生成知识点后，这里会形成学习路径。',
            compact: true,
          )
        else
          for (var index = 0; index < items.length; index++) ...[
            _PathItemCard(
              item: items[index],
              task: items[index].taskId == null
                  ? null
                  : tasksById[items[index].taskId!],
              onBuildTask: () =>
                  controller.generateTaskFromKnowledge(items[index]),
              onStart: onStartLesson,
            ),
            const SizedBox(height: 8),
          ],
      ],
    );
  }
}

class _PathItemCard extends StatelessWidget {
  const _PathItemCard({
    required this.item,
    required this.task,
    required this.onBuildTask,
    required this.onStart,
  });

  final KnowledgeItem item;
  final StudyTask? task;
  final VoidCallback onBuildTask;
  final Future<void> Function(StudyTask task) onStart;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
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
            children: [
              Expanded(
                child: Text(
                  item.title,
                  style: context.texts.bodyMedium!.copyWith(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              AppBadge(label: item.priorityLabel, dense: true),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            [
              item.sourcePageLabel == null
                  ? '无材料来源'
                  : '${item.documentTitle} · ${item.sourcePageLabel}',
              '${item.minutes} 分钟',
            ].join(' · '),
            style: context.texts.bodySmall!.copyWith(fontSize: 11.5),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (task == null)
                FilledButton(
                  onPressed: onBuildTask,
                  child: const Text('建立任务'),
                )
              else
                FilledButton(
                  onPressed: () => onStart(task!),
                  child: const Text('开始学习'),
                ),
              const SizedBox(width: 8),
              Text(
                task == null ? '尚未建立任务' : '已加入待安排任务',
                style: context.texts.bodySmall!.copyWith(fontSize: 11.5),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.controller,
    required this.wide,
    required this.onAdd,
    required this.onMenu,
  });

  final ScheduleController controller;
  final bool wide;
  final VoidCallback onAdd;
  final ValueChanged<_MenuAction> onMenu;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final today = controller.today;
    final awayFromToday =
        controller.selectedDate != today ||
        controller.visibleMonth != today.firstOfMonth;

    final quickJump = Tooltip(
      message: '输入或按数字跳转日期',
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: InkWell(
          key: const ValueKey('schedule-quick-jump'),
          borderRadius: BorderRadius.circular(Radii.sm),
          onTap: () => showJumpDialog(context, controller),
          child: wide
              ? Container(
                  height: 30,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(Radii.sm),
                    border: Border.all(color: c.outlineStrong),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      QIcon(QIcons.route, size: IconSizes.sm, color: c.inkMuted),
                      const SizedBox(width: 4),
                      Text(
                        '跳转',
                        style: context.texts.bodySmall!.copyWith(
                          fontSize: 12.5,
                          color: c.ink,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                )
              : SizedBox(
                  width: 28,
                  height: 30,
                  child: Center(
                    child: QIcon(
                      QIcons.route,
                      size: IconSizes.sm,
                      color: c.inkMuted,
                    ),
                  ),
                ),
        ),
      ),
    );

    final monthNav = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: '上个月',
          onPressed: () => controller.shiftMonth(-1),
          visualDensity: VisualDensity.compact,
          constraints: BoxConstraints(
            minWidth: wide ? 32 : 26,
            minHeight: 32,
          ),
          padding: EdgeInsets.zero,
          icon: const QIcon(QIcons.chevronLeft, size: IconSizes.md),
        ),
        SizedBox(
          width: wide ? 128 : 76,
          child: Tooltip(
            message: '选择年 / 月 / 日',
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                key: const ValueKey('month-picker'),
                borderRadius: BorderRadius.circular(Radii.sm),
                onTap: () => showMonthPicker(context, controller),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(
                          controller.visibleMonth.monthLabel,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.texts.bodyMedium!.copyWith(
                            fontSize: wide ? 15.5 : 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      QIcon(
                        QIcons.chevronDown,
                        size: wide ? IconSizes.md : IconSizes.sm,
                        color: c.inkMuted,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: '下个月',
          onPressed: () => controller.shiftMonth(1),
          visualDensity: VisualDensity.compact,
          constraints: BoxConstraints(
            minWidth: wide ? 32 : 26,
            minHeight: 32,
          ),
          padding: EdgeInsets.zero,
          icon: const QIcon(QIcons.chevronRight, size: IconSizes.md),
        ),
        if (wide) ...[
          const SizedBox(width: 4),
          Tooltip(
            message: '选择具体某日',
            child: Material(
              color: c.sidebar,
              borderRadius: BorderRadius.circular(Radii.sm),
              child: InkWell(
                key: const ValueKey('day-picker'),
                onTap: () => showMonthPicker(
                  context,
                  controller,
                  initialMode: DateJumpMode.day,
                ),
                borderRadius: BorderRadius.circular(Radii.sm),
                child: Container(
                  height: 30,
                  padding: const EdgeInsets.symmetric(horizontal: 9),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(Radii.sm),
                    border: Border.all(color: c.outline),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      QIcon(
                        QIcons.schedule,
                        size: IconSizes.sm,
                        color: c.inkMuted,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        controller.selectedDate.shortLabel,
                        style: context.texts.bodySmall!.copyWith(
                          fontSize: 12.5,
                          color: c.ink,
                          fontWeight: FontWeight.w500,
                          fontFeatures: AppNumerals.tabular,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
        const SizedBox(width: 4),
        TextButton(
          key: const ValueKey('schedule-today-btn'),
          onPressed: controller.goToday,
          style: TextButton.styleFrom(
            padding: EdgeInsets.symmetric(
              horizontal: wide ? 9 : 4,
              vertical: 4,
            ),
            minimumSize: const Size(0, 30),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (awayFromToday) ...[
                Container(
                  width: 6,
                  height: 6,
                  margin: const EdgeInsets.only(right: 4),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: c.primary,
                  ),
                ),
              ],
              const Text('今天'),
            ],
          ),
        ),
        const SizedBox(width: 2),
        quickJump,
      ],
    );
    final planFilter = Container(
      height: 36,
      constraints: BoxConstraints(maxWidth: wide ? 230 : double.infinity),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border.all(color: c.outlineStrong),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          isExpanded: true,
          value: controller.planFilterId,
          icon: QIcon(
            QIcons.chevronDown,
            size: IconSizes.md,
            color: c.inkMuted,
          ),
          style: context.texts.bodySmall!.copyWith(
            fontSize: 13,
            color: c.ink,
          ),
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('全部计划'),
            ),
            for (final plan in controller.activePlans)
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
          onChanged: controller.selectPlan,
        ),
      ),
    );
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FilledButton.icon(
          key: const ValueKey('schedule-add'),
          onPressed: onAdd,
          icon: const QIcon(QIcons.add, size: IconSizes.sm),
          label: const Text('新增'),
        ),
        const SizedBox(width: 6),
        PopupMenuButton<_MenuAction>(
          tooltip: '日程操作',
          onSelected: onMenu,
          icon: const QIcon(QIcons.more, size: IconSizes.md),
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: _MenuAction.plans,
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: QIcon(QIcons.plan, size: IconSizes.md),
                title: Text('管理计划'),
              ),
            ),
            const PopupMenuItem(
              value: _MenuAction.availability,
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: QIcon(QIcons.duration, size: IconSizes.md),
                title: Text('可用时间'),
              ),
            ),
            const PopupMenuItem(
              value: _MenuAction.autoSchedule,
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: QIcon(QIcons.ai, size: IconSizes.md),
                title: Text('自动排期'),
              ),
            ),
            PopupMenuItem(
              value: _MenuAction.undo,
              enabled: controller.canUndoLatest,
              child: const ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: QIcon(QIcons.undo, size: IconSizes.md),
                title: Text('撤销上次排期'),
              ),
            ),
          ],
        ),
      ],
    );
    if (wide) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 10),
        child: Row(
          children: [
            monthNav,
            const Spacer(),
            planFilter,
            const SizedBox(width: 10),
            actions,
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: monthNav,
                ),
              ),
              IconButton(
                key: const ValueKey('schedule-add'),
                tooltip: '新增安排',
                onPressed: onAdd,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                padding: EdgeInsets.zero,
                icon: const QIcon(QIcons.add, size: IconSizes.md),
              ),
              SizedBox(
                width: 34,
                height: 34,
                child: PopupMenuButton<_MenuAction>(
                  tooltip: '日程操作',
                  onSelected: onMenu,
                  padding: EdgeInsets.zero,
                  style: IconButton.styleFrom(
                    minimumSize: const Size(34, 34),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: const QIcon(QIcons.more, size: IconSizes.md),
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      value: _MenuAction.plans,
                      child: Text('管理计划'),
                    ),
                    const PopupMenuItem(
                      value: _MenuAction.availability,
                      child: Text('可用时间'),
                    ),
                    const PopupMenuItem(
                      value: _MenuAction.autoSchedule,
                      child: Text('自动排期'),
                    ),
                    PopupMenuItem(
                      value: _MenuAction.undo,
                      enabled: controller.canUndoLatest,
                      child: const Text('撤销上次排期'),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 2),
            child: Row(
              children: [
                Expanded(child: planFilter),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CalendarGrid extends StatelessWidget {
  const _CalendarGrid({required this.controller, required this.month});

  final ScheduleController controller;
  final LocalDate month;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth.clamp(0.0, 760.0);
        final shortViewport = MediaQuery.sizeOf(context).height < 720;
        final cellHeight = ((available / 7) * 0.92).clamp(
          shortViewport ? 36.0 : 44.0,
          shortViewport ? 62.0 : 88.0,
        );
        final start = month.gridStart;
        final rows = <Widget>[];
        for (var week = 0; week < 6; week++) {
          rows.add(
            SizedBox(
              height: cellHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var day = 0; day < 7; day++)
                    Expanded(
                      child: _DayCell(
                        date: start.addDays(week * 7 + day),
                        controller: controller,
                        month: month,
                        height: cellHeight,
                      ),
                    ),
                ],
              ),
            ),
          );
        }
        return Container(
          decoration: BoxDecoration(
            border: Border.all(color: c.outline),
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              Container(
                height: 28,
                color: c.sidebar,
                child: Row(
                  children: [
                    for (final label in weekdays)
                      Expanded(
                        child: Center(
                          child: Text(
                            label,
                            style: context.texts.bodySmall!.copyWith(
                              fontSize: 11.5,
                              color: c.inkMuted,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              for (var index = 0; index < rows.length; index++) ...[
                if (index > 0) Divider(height: 1, color: c.outline),
                rows[index],
              ],
            ],
          ),
        );
      },
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.date,
    required this.controller,
    required this.month,
    required this.height,
  });

  final LocalDate date;
  final ScheduleController controller;
  final LocalDate month;
  final double height;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final summary = controller.summaryFor(date);
    final selected = date == controller.selectedDate;
    final today = date == controller.today;
    final inMonth = date.year == month.year && date.month == month.month;
    final compact = height < 58;
    final semantics = StringBuffer(date.longLabel);
    if (summary.hasExam) semantics.write('，考试');
    if (summary.isRest) semantics.write('，休息日');
    if (summary.count > 0) {
      semantics.write('，${summary.count} 项安排，${summary.minutes} 分钟');
    }
    return Semantics(
      button: true,
      selected: selected,
      label: semantics.toString(),
      child: Tooltip(
        message: semantics.toString(),
        waitDuration: const Duration(milliseconds: 500),
        child: InkWell(
          key: ValueKey('schedule-day-${date.iso}'),
          onTap: () => controller.selectDate(date),
          hoverColor: c.tint.withValues(alpha: .45),
          child: AnimatedContainer(
            duration: context.motion(Motion.fast),
            curve: Motion.curveStandard,
            padding: EdgeInsets.fromLTRB(compact ? 4 : 6, 3, 3, 3),
            decoration: BoxDecoration(
              color: selected
                  ? c.tint
                  : (today ? c.tint.withValues(alpha: .45) : c.surface),
              border: Border(
                left: BorderSide(
                  color: selected ? c.primary : Colors.transparent,
                  width: 2,
                ),
                top: BorderSide(
                  color: today ? c.outlineStrong : Colors.transparent,
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text(
                      '${date.day}',
                      style: context.texts.bodySmall!.copyWith(
                        fontSize: compact ? 12 : 13.5,
                        color: inMonth
                            ? (selected ? c.ink : c.ink)
                            : c.inkMuted.withValues(alpha: .5),
                        fontWeight: selected || today
                            ? FontWeight.w700
                            : FontWeight.w500,
                        fontFeatures: AppNumerals.tabular,
                      ),
                    ),
                    const Spacer(),
                    if (summary.hasExam)
                      _CellMarker(label: '考', emphasized: true),
                    if (summary.isRest) _CellMarker(label: '休'),
                  ],
                ),
                const Spacer(),
                if (summary.count > 0) ...[
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${summary.count}项 ${summary.minutes}′',
                      style: context.texts.bodySmall!.copyWith(
                        fontSize: compact ? 9 : 10.5,
                        color: inMonth ? c.inkMuted : c.inkMuted.withValues(alpha: .4),
                        height: 1.1,
                        fontFeatures: AppNumerals.tabular,
                      ),
                    ),
                  ),
                  if (compact && summary.completedCount > 0)
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '完成 ${summary.completedCount}/${summary.count}',
                        style: context.texts.bodySmall!.copyWith(
                          fontSize: 8,
                          color: inMonth ? c.inkMuted : c.inkMuted.withValues(alpha: .4),
                          height: 1.1,
                          fontFeatures: AppNumerals.tabular,
                        ),
                      ),
                    ),
                  if (!compact) ...[
                    const SizedBox(height: 3),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: summary.minutes == 0
                            ? 0
                            : summary.completedMinutes / summary.minutes,
                        minHeight: 2,
                        backgroundColor: c.outline,
                      ),
                    ),
                  ],
                ] else if (summary.isOverdue)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: c.danger,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CellMarker extends StatelessWidget {
  const _CellMarker({required this.label, this.emphasized = false});

  final String label;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      margin: const EdgeInsets.only(left: 2),
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
      decoration: BoxDecoration(
        color: emphasized ? c.dangerTint : c.surfaceRaised,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: context.texts.bodySmall!.copyWith(
          fontSize: 8.5,
          height: 1,
          color: emphasized ? c.danger : c.inkMuted,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _DayPanel extends StatelessWidget {
  const _DayPanel({
    required this.controller,
    required this.wide,
    required this.onOpenMaterial,
    required this.onAdd,
    required this.onMenu,
    required this.onBlockAction,
    this.onCollapse,
  });

  final ScheduleController controller;
  final bool wide;
  final Future<void> Function(MaterialRef material) onOpenMaterial;
  final VoidCallback onAdd;
  final ValueChanged<_MenuAction> onMenu;
  final void Function(CalendarBlock, _BlockAction) onBlockAction;
  final VoidCallback? onCollapse;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final date = controller.selectedDate;
    final blocks = controller.dayBlocks;
    final summary = controller.summaryFor(date);
    final exams = controller.examPlansFor(date);
    final plan = controller.selectedPlan;
    final nextExam = controller.nextExamOnOrAfter(date);
    final distance = nextExam == null
        ? null
        : nextExam.examDate == date
        ? '今天考试'
        : '距${nextExam.subject.isEmpty ? '' : nextExam.subject}考试 '
              '${nextExam.examDate!.differenceInDays(date)} 天';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 10, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Tooltip(
                            message: '选择某日',
                            child: InkWell(
                              onTap: () => showMonthPicker(
                                context,
                                controller,
                                initialMode: DateJumpMode.day,
                              ),
                              borderRadius: BorderRadius.circular(Radii.sm),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 2,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Flexible(
                                      child: Text(
                                        date.longLabel,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: context.texts.titleSmall!
                                            .copyWith(fontSize: 15.5),
                                      ),
                                    ),
                                    const SizedBox(width: 3),
                                    QIcon(
                                      QIcons.chevronDown,
                                      size: IconSizes.sm,
                                      color: c.inkMuted,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '前一天',
                          onPressed: () => controller.shiftDay(-1),
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(
                            minWidth: 26,
                            minHeight: 26,
                          ),
                          padding: EdgeInsets.zero,
                          icon: const QIcon(
                            QIcons.chevronLeft,
                            size: IconSizes.sm,
                          ),
                        ),
                        IconButton(
                          tooltip: '后一天',
                          onPressed: () => controller.shiftDay(1),
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(
                            minWidth: 26,
                            minHeight: 26,
                          ),
                          padding: EdgeInsets.zero,
                          icon: const QIcon(
                            QIcons.chevronRight,
                            size: IconSizes.sm,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        AppBadge(
                          label: summary.isRest
                              ? '休息日'
                              : '${summary.count} 项 · ${summary.minutes} 分钟',
                          dense: true,
                        ),
                        if (summary.completedMinutes > 0)
                          AppBadge(
                            label: '已完成 ${summary.completedMinutes} 分钟',
                            dense: true,
                          ),
                        if (plan != null)
                          AppBadge(label: plan.title, dense: true),
                        if (distance != null)
                          AppBadge(
                            label: distance,
                            tone: exams.isNotEmpty && distance == '今天考试'
                                ? BadgeTone.danger
                                : BadgeTone.neutral,
                            dense: true,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '新增这一天',
                onPressed: onAdd,
                icon: const QIcon(QIcons.add, size: IconSizes.md),
              ),
              PopupMenuButton<_MenuAction>(
                tooltip: '这一天',
                onSelected: onMenu,
                icon: const QIcon(QIcons.more, size: IconSizes.md),
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: _MenuAction.toggleRest,
                    child: Text(
                      controller.isRestDay(controller.selectedDate)
                          ? '恢复每周安排'
                          : '设为休息日',
                    ),
                  ),
                  const PopupMenuItem(
                    value: _MenuAction.plans,
                    child: Text('管理计划'),
                  ),
                  const PopupMenuItem(
                    value: _MenuAction.availability,
                    child: Text('可用时间'),
                  ),
                  PopupMenuItem(
                    value: _MenuAction.autoSchedule,
                    enabled: controller.activePlans.isNotEmpty,
                    child: const Text('自动排期'),
                  ),
                  PopupMenuItem(
                    value: _MenuAction.undo,
                    enabled: controller.canUndoLatest,
                    child: const Text('撤销上次排期'),
                  ),
                ],
              ),
              if (onCollapse != null)
                IconButton(
                  tooltip: '收起日详情',
                  onPressed: onCollapse,
                  icon: const QIcon(
                    QIcons.sidebar,
                    size: IconSizes.md,
                  ),
                ),
            ],
          ),
        ),
        if (exams.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: AppCallout(
              tone: CalloutTone.warning,
              icon: QIcons.milestone,
              title: '考试日',
              message: exams
                  .map(
                    (plan) =>
                        '${plan.subject.isEmpty ? plan.title : plan.subject} · ${plan.title}',
                  )
                  .join('；'),
            ),
          ),
        if (summary.isRest)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: AppCallout(
              tone: CalloutTone.info,
              icon: QIcons.rest,
              title: '休息日',
              message: '这个日期在所选计划中被标记为休息；自动排期不会占用它。',
            ),
          ),
        if (summary.count > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: summary.minutes == 0
                    ? 0
                    : summary.completedMinutes / summary.minutes,
                minHeight: 3,
                backgroundColor: c.tint,
              ),
            ),
          ),
        Expanded(
          child: blocks.isEmpty
              ? Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: EmptyState(
                      icon: QIcons.done,
                      title: summary.isRest ? '今天休息' : '当天暂无安排',
                      message: summary.isRest
                          ? '如需排课，可在右上角恢复每周安排。'
                          : '可新增学习任务或个人占用。',
                      compact: true,
                      action: summary.isRest
                          ? null
                          : OutlinedButton.icon(
                              onPressed: onAdd,
                              icon: const QIcon(QIcons.add, size: IconSizes.sm),
                              label: const Text('新增安排'),
                            ),
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  itemCount: blocks.length,
                  itemBuilder: (context, index) {
                    final block = blocks[index];
                    return _BlockTile(
                      controller: controller,
                      block: block,
                      onAction: (action) => onBlockAction(block, action),
                    );
                  },
                ),
        ),
        if (wide)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                QIcon(
                  QIcons.ai,
                  size: IconSizes.sm,
                  color: c.inkMuted.withValues(alpha: .7),
                ),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    'AI 排课仅写入计划设置；点击任务卡片即可开始学习。',
                    style: context.texts.bodySmall!.copyWith(
                      fontSize: 11.5,
                      color: c.inkMuted.withValues(alpha: .8),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

}

class _BlockTile extends StatelessWidget {
  const _BlockTile({
    required this.controller,
    required this.block,
    required this.onAction,
  });

  final ScheduleController controller;
  final CalendarBlock block;
  final ValueChanged<_BlockAction> onAction;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final task = controller.taskFor(block);
    final plan = controller.planFor(block);
    final material = task?.material;
    final title = task?.title ?? block.title;
    final overdue = block.isOverdue(controller.now);
    final completed = block.state == BlockState.completed;
    final partial = block.completedMinutes > 0 && !completed;
    return AnimatedContainer(
      duration: context.motion(Motion.fast),
      curve: Motion.curveStandard,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 10, 6, 10),
      decoration: BoxDecoration(
        color: completed ? c.surfaceRaised : c.surface,
        border: Border.all(
          color: overdue ? c.danger.withValues(alpha: .45) : c.outline,
        ),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 54,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  formatMinuteOfDay(block.startMinute),
                  style: context.texts.bodySmall!.copyWith(
                    fontSize: 12.5,
                    color: c.ink,
                    fontWeight: FontWeight.w600,
                    fontFeatures: AppNumerals.tabular,
                  ),
                ),
                Text(
                  formatMinuteOfDay(block.endMinute),
                  style: context.texts.bodySmall!.copyWith(
                    fontSize: 11.5,
                    fontFeatures: AppNumerals.tabular,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${block.minutes}′',
                  style: context.texts.bodySmall!.copyWith(
                    fontSize: 11,
                    fontFeatures: AppNumerals.tabular,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        title.isEmpty ? '未命名任务' : title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.texts.bodyMedium!.copyWith(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          decoration: completed
                              ? TextDecoration.lineThrough
                              : null,
                          color: completed ? c.inkMuted : c.ink,
                        ),
                      ),
                    ),
                    if (overdue)
                      const AppBadge(
                        label: '逾期',
                        tone: BadgeTone.danger,
                        dense: true,
                      ),
                  ],
                ),
                const SizedBox(height: 3),
                Wrap(
                  spacing: 6,
                  runSpacing: 3,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (!block.isStudy)
                      const AppBadge(label: '个人占用', dense: true)
                    else if (task != null)
                      AppBadge(label: task.activity.label, dense: true),
                    if (plan != null) AppBadge(label: plan.title, dense: true),
                    if (task != null && task.subject.isNotEmpty)
                      AppBadge(label: task.subject, dense: true),
                    if (block.locked && block.isStudy)
                      const AppBadge(
                        label: '已锁定',
                        icon: QIcons.lock,
                        dense: true,
                      ),
                    if (material?.missing == true)
                      const AppBadge(
                        label: '教材已删除',
                        tone: BadgeTone.danger,
                        dense: true,
                      ),
                    if (block.isStudy) _stateBadge(block),
                  ],
                ),
                if (task?.completionCondition.isNotEmpty ?? false) ...[
                  const SizedBox(height: 5),
                  Text(
                    task!.completionCondition,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.bodySmall!.copyWith(fontSize: 12.5),
                  ),
                ],
                if (partial) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: block.progress,
                            minHeight: 3,
                            backgroundColor: c.tint,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${block.completedMinutes}/${block.minutes} 分钟',
                        style: context.texts.bodySmall!.copyWith(
                          fontSize: 11.5,
                          fontFeatures: AppNumerals.tabular,
                        ),
                      ),
                    ],
                  ),
                ],
                if (completed && block.completedAt != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '完成于 ${formatMinuteOfDay(block.completedAt!.hour * 60 + block.completedAt!.minute)}',
                    style: context.texts.bodySmall!.copyWith(fontSize: 11.5),
                  ),
                ],
                if (block.state == BlockState.skipped) ...[
                  const SizedBox(height: 4),
                  Text(
                    block.skippedReason.isEmpty
                        ? '已跳过'
                        : '跳过原因：${block.skippedReason}',
                    style: context.texts.bodySmall!.copyWith(fontSize: 12),
                  ),
                ],
                if (task != null &&
                    block.isStudy &&
                    block.state != BlockState.completed &&
                    material != null) ...[
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      key: ValueKey('start-lesson-${block.id}'),
                      onPressed: () => onAction(_BlockAction.lesson),
                      icon: const QIcon(QIcons.play, size: IconSizes.sm),
                      label: Text(
                        partial || block.state == BlockState.inProgress
                            ? '继续学习'
                            : controller.lessonForTask(task.id) == null
                            ? '准备课程'
                            : '开始学习',
                      ),
                    ),
                  ),
                ],
                if (material != null) ...[
                  const SizedBox(height: 4),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(0, 30),
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: material.missing
                        ? null
                        : () => onAction(_BlockAction.openMaterial),
                    icon: QIcon(
                      material.missing ? QIcons.unlink : QIcons.textbook,
                      size: IconSizes.sm,
                    ),
                    label: Text(
                      material.missing
                          ? '教材已删除 · ${material.rangeLabel}'
                          : '打开教材 · ${material.rangeLabel}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (block.isOpen && block.isStudy)
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: const Size(0, 30),
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => _complete(context),
                  child: Text(
                    partial ? '完成余下' : '完成',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
                PopupMenuButton<_BlockAction>(
                  tooltip: '安排操作',
                  onSelected: onAction,
                  padding: EdgeInsets.zero,
                  icon: const QIcon(QIcons.more, size: IconSizes.md),
                  itemBuilder: (context) => [
                    if (block.isStudy) ...[
                      PopupMenuItem(
                        value: partial ? _BlockAction.partial : _BlockAction.partial,
                        child: Text(partial ? '继续记录部分完成' : '记录部分完成'),
                      ),
                      const PopupMenuItem(
                        value: _BlockAction.skip,
                        child: Text('跳过并填写原因'),
                      ),
                    ],
                    const PopupMenuItem(
                      value: _BlockAction.edit,
                      child: Text('编辑时间与内容'),
                    ),
                    if (block.isStudy)
                      const PopupMenuItem(
                        value: _BlockAction.lesson,
                        child: Text('今日课程'),
                      ),
                    if (block.isStudy && block.state != BlockState.completed)
                      const PopupMenuItem(
                        value: _BlockAction.catchUp,
                        child: Text('补课建议'),
                      ),
                    if (block.isStudy)
                      PopupMenuItem(
                        value: block.locked
                            ? _BlockAction.unlock
                            : _BlockAction.lock,
                        child: Text(block.locked ? '解除锁定' : '锁定时间'),
                      ),
                    const PopupMenuItem(
                      value: _BlockAction.delete,
                      child: Text('删除'),
                    ),
                  ],
                ),
              ],
            )
          else if (block.isOpen)
            PopupMenuButton<_BlockAction>(
              tooltip: '安排操作',
              onSelected: onAction,
              padding: EdgeInsets.zero,
              icon: const QIcon(QIcons.more, size: IconSizes.md),
              itemBuilder: (context) => [
                if (block.isStudy)
                  const PopupMenuItem(
                    value: _BlockAction.partial,
                    child: Text('记录部分完成'),
                  ),
                const PopupMenuItem(
                  value: _BlockAction.edit,
                  child: Text('编辑时间与内容'),
                ),
                const PopupMenuItem(
                  value: _BlockAction.delete,
                  child: Text('删除'),
                ),
              ],
            )
          else
            const SizedBox(width: 8),
        ],
      ),
    );
  }

  Future<void> _complete(BuildContext context) async {
    try {
      controller.markBlock(
        block: block,
        fact: LearningFact.completed,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已记完成')));
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  Widget _stateBadge(CalendarBlock block) {
    if (block.state == BlockState.completed) {
      return const AppBadge(
        label: '已完成',
        icon: QIcons.check,
        dense: true,
      );
    }
    if (block.state == BlockState.skipped) {
      return const AppBadge(label: '已跳过', dense: true);
    }
    if (block.state == BlockState.inProgress) {
      return const AppBadge(
        label: '部分完成',
        icon: QIcons.catchUp,
        dense: true,
      );
    }
    if (block.state == BlockState.scheduled) {
      return const AppBadge(label: '未开始', dense: true);
    }
    return const SizedBox.shrink();
  }
}

class _CalendarPlanningBar extends StatelessWidget {
  const _CalendarPlanningBar({
    super.key,
    required this.controller,
    required this.onOpen,
  });

  final ScheduleController controller;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final messages = controller.planningMessages;
    final last = messages.isEmpty ? null : messages.last;
    final pending = last != null && last.proposal != null && !last.applied;
    final text = controller.planningSending
        ? '正在整理排期草案…'
        : pending
        ? '草案待确认：${last.text}'
        : last != null
        ? last.text
        : '问 AI 排课：输入考试日期、科目与可用时段…';
    return Container(
      key: const ValueKey('planning-bar'),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(
          color: pending ? c.primary.withValues(alpha: .5) : c.outlineStrong,
        ),
        boxShadow: AppShadow.e2,
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onOpen,
          hoverColor: c.tint.withValues(alpha: .35),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: pending ? c.primary.withValues(alpha: .12) : c.tint,
                    borderRadius: BorderRadius.circular(Radii.sm),
                  ),
                  alignment: Alignment.center,
                  child: QIcon(
                    QIcons.ai,
                    size: IconSizes.sm,
                    color: pending ? c.primary : c.ink,
                  ),
                ),
                const SizedBox(width: 10),
                AppBadge(label: controller.planningScopeLabel, dense: true),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text.replaceAll('\n', ' ').trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.bodySmall!.copyWith(
                      fontSize: 13,
                      color: pending ? c.ink : c.inkMuted,
                      fontWeight: pending ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (controller.planningSending) ...[
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 4),
                  TextButton(
                    onPressed: controller.cancelPlanningSend,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Text('取消'),
                  ),
                ] else if (pending) ...[
                  FilledButton(
                    onPressed: onOpen,
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      minimumSize: const Size(0, 30),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                    ),
                    child: const Text('查看草案'),
                  ),
                ] else ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: c.tint,
                      borderRadius: BorderRadius.circular(Radii.sm),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'AI 排课',
                          style: context.texts.bodySmall!.copyWith(
                            fontSize: 12,
                            color: c.ink,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(width: 4),
                        QIcon(
                          QIcons.chevronUp,
                          size: IconSizes.sm,
                          color: c.inkMuted,
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlanningBar extends StatelessWidget {
  const _PlanningBar({required this.controller, required this.onOpen});

  final ScheduleController controller;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final messages = controller.planningMessages;
    final last = messages.isEmpty ? null : messages.last;
    final pending =
        last != null && last.proposal != null && !last.applied;
    final String preview;
    if (controller.planningSending) {
      preview = '正在整理排期草案…';
    } else if (pending) {
      preview = '草案待确认：${last.text}';
    } else if (last != null) {
      preview = last.text;
    } else {
      preview = '问 AI 排课：考试日期、科目、可用时间';
    }
    final clipped = preview.replaceAll('\n', ' ').trim();
    return Material(
      key: const ValueKey('planning-bar'),
      color: c.surface,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: c.outline)),
        ),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: Row(
              children: [
                Expanded(
                  child: Material(
                    color: c.sidebar,
                    borderRadius: BorderRadius.circular(Radii.lg),
                    child: InkWell(
                      onTap: onOpen,
                      borderRadius: BorderRadius.circular(Radii.lg),
                      hoverColor: c.tint.withValues(alpha: .45),
                      child: Container(
                        height: 42,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(Radii.lg),
                          border: Border.all(
                            color: pending
                                ? c.primary.withValues(alpha: .5)
                                : c.outlineStrong,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 24,
                              height: 24,
                              decoration: BoxDecoration(
                                color: pending
                                    ? c.primary.withValues(alpha: .12)
                                    : c.tint,
                                borderRadius: BorderRadius.circular(Radii.sm),
                              ),
                              alignment: Alignment.center,
                              child: QIcon(
                                QIcons.ai,
                                size: 14,
                                color: pending ? c.primary : c.ink,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                clipped.isEmpty
                                    ? '问 AI 排课：考试日期、科目、可用时间'
                                    : clipped,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: context.texts.bodySmall!.copyWith(
                                  fontSize: 12.5,
                                  color: pending ? c.ink : c.inkMuted,
                                  fontWeight: pending
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            QIcon(
                              QIcons.chevronUp,
                              size: IconSizes.sm,
                              color: c.inkMuted,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (controller.planningSending) ...[
                  const SizedBox(width: 8),
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  TextButton(
                    onPressed: controller.cancelPlanningSend,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Text('取消'),
                  ),
                ] else if (pending) ...[
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: onOpen,
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Text('查看草案'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PartialDialog extends StatefulWidget {
  const _PartialDialog({required this.block});

  final CalendarBlock block;

  @override
  State<_PartialDialog> createState() => _PartialDialogState();
}

class _PartialDialogState extends State<_PartialDialog> {
  late final _minutes = TextEditingController(
    text: '${widget.block.completedMinutes > 0 ? widget.block.completedMinutes : widget.block.minutes ~/ 2}',
  );
  final _note = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _minutes.dispose();
    _note.dispose();
    super.dispose();
  }

  void _submit() {
    final value = int.tryParse(_minutes.text.trim());
    if (value == null || value < 1 || value >= widget.block.minutes) {
      setState(
        () => _error = '请输入 1–${widget.block.minutes - 1} 分钟',
      );
      return;
    }
    if (value < widget.block.completedMinutes) {
      setState(
        () => _error = '已记录 ${widget.block.completedMinutes} 分钟，不能减少。',
      );
      return;
    }
    Navigator.pop(context, (minutes: value, note: _note.text.trim()));
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    title: '记录部分完成',
    subtitle: '计划 ${widget.block.minutes} 分钟；请填写实际学习时长。',
    maxWidth: 420,
    actions: [
      DialogActions.cancel(context),
      FilledButton(onPressed: _submit, child: const Text('保存记录')),
    ],
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const DialogFieldLabel('已累计学习（分钟）'),
        TextField(
          controller: _minutes,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(errorText: _error),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
        ),
        const SizedBox(height: Space.md),
        const DialogFieldLabel('备注（可选）'),
        TextField(
          controller: _note,
          minLines: 1,
          maxLines: 3,
          decoration: const InputDecoration(hintText: '例如：做到第三题，今天没时间了'),
        ),
      ],
    ),
  );
}

class _SkipDialog extends StatefulWidget {
  const _SkipDialog({required this.block});

  final CalendarBlock block;

  @override
  State<_SkipDialog> createState() => _SkipDialogState();
}

class _SkipDialogState extends State<_SkipDialog> {
  final _reason = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  void _submit() {
    if (_reason.text.trim().isEmpty) {
      setState(() => _error = '请填写跳过原因，方便之后调整计划。');
      return;
    }
    Navigator.pop(context, _reason.text.trim());
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    title: '跳过这次安排',
    subtitle: '跳过不记为完成，后续可在补课草案中重新安排。',
    maxWidth: 420,
    actions: [
      DialogActions.cancel(context),
      FilledButton(onPressed: _submit, child: const Text('标记跳过')),
    ],
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const DialogFieldLabel('原因'),
        TextField(
          controller: _reason,
          autofocus: true,
          minLines: 2,
          maxLines: 4,
          decoration: InputDecoration(
            hintText: '例如：临时有事，今天只完成了前一半',
            errorText: _error,
          ),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
        ),
      ],
    ),
  );
}
