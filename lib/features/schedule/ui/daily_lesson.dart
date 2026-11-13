import 'dart:async';

import 'package:flutter/material.dart';

import '../../../services/ai_types.dart';
import '../../../ui/theme/tokens.dart';
import '../../../ui/widgets/app_dialog.dart';
import '../../../ui/widgets/app_surfaces.dart';
import '../models/daily_lesson.dart';
import '../models/study_task.dart';
import '../schedule_controller.dart';
import '../services/lesson_ai_client.dart';

Future<void> showDailyLesson(
  BuildContext context,
  ScheduleController controller,
  StudyTask task, {
  String? blockId,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (context) => _DailyLessonDialog(
      controller: controller,
      task: task,
      blockId: blockId,
      pageMode: true,
    ),
  ),
);

class _DailyLessonDialog extends StatefulWidget {
  const _DailyLessonDialog({
    required this.controller,
    required this.task,
    this.blockId,
    this.pageMode = false,
  });

  final ScheduleController controller;
  final StudyTask task;
  final String? blockId;
  final bool pageMode;

  @override
  State<_DailyLessonDialog> createState() => _DailyLessonDialogState();
}

class _DailyLessonDialogState extends State<_DailyLessonDialog> {
  late DailyLesson? _lesson = widget.controller.lessonForTask(widget.task.id);
  final _answers = <String, TextEditingController>{};
  final _revealed = <String>{};
  final _drafts = <String, LessonDraft>{};
  final _scroll = ScrollController();
  late final TextEditingController _minutes = TextEditingController(
    text: '${widget.task.minutes}',
  );
  Timer? _saveTimer;
  int _generation = 0;
  String? _error;
  String? _notice;
  bool _generating = false;

  @override
  void initState() {
    super.initState();
    _loadDrafts();
    _syncAnswers();
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreScroll());
  }

  void _restoreScroll() {
    final lesson = _lesson;
    if (!mounted || lesson == null || !_scroll.hasClients) return;
    final raw = widget.controller.store.getSetting(
      'schedule.lessonScroll.${lesson.id}',
    );
    final offset = double.tryParse(raw ?? '');
    if (offset != null && offset > 0) {
      _scroll.jumpTo(offset.clamp(0, _scroll.position.maxScrollExtent));
    }
  }

  void _saveScroll() {
    final lesson = _lesson;
    if (lesson == null || !_scroll.hasClients) return;
    widget.controller.store.setSetting(
      'schedule.lessonScroll.${lesson.id}',
      '${_scroll.offset}',
    );
  }

  void _loadDrafts() {
    final lesson = _lesson;
    if (lesson == null) return;
    _drafts.addAll(
      widget.controller.repository.getLessonDrafts(lesson.id),
    );
    for (final draft in _drafts.values) {
      if (draft.revealed) _revealed.add(draft.exerciseId);
    }
  }

  void _syncAnswers() {
    for (final exercise in _lesson?.exercises ?? const <LessonExercise>[]) {
      final controller = _answers.putIfAbsent(
        exercise.id,
        TextEditingController.new,
      );
      final draft = _drafts[exercise.id];
      if (draft != null && controller.text.isEmpty) {
        controller.text = draft.answer;
      }
    }
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 350), _persistDrafts);
  }

  void _persistDrafts() {
    final lesson = _lesson;
    if (lesson == null) return;
    for (final exercise in lesson.exercises) {
      final previous = _drafts[exercise.id];
      _drafts[exercise.id] = LessonDraft(
        exerciseId: exercise.id,
        answer: _answers[exercise.id]?.text ?? previous?.answer ?? '',
        revealed: _revealed.contains(exercise.id),
        selfCheck: previous?.selfCheck ?? '',
      );
    }
    widget.controller.repository.saveLessonDrafts(lesson.id, _drafts);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _saveScroll();
    _persistDrafts();
    _scroll.dispose();
    _minutes.dispose();
    for (final controller in _answers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _recordSelfCheck(LessonExercise exercise, bool correct) {
    final lesson = _lesson;
    if (lesson == null) return;
    final minutes = int.tryParse(_minutes.text.trim());
    if (minutes == null || minutes < 1 || minutes > 600) {
      setState(() => _error = '实际用时需在 1–600 分钟之间。');
      return;
    }
    final answer = _answers[exercise.id]?.text.trim() ?? '';
    if (answer.isEmpty) {
      setState(() => _error = '先写下你的答案，再记录自评。');
      return;
    }
    try {
      widget.controller.repository.saveLessonAttemptRecord(
        lessonId: lesson.id,
        taskId: widget.task.id,
        exerciseId: exercise.id,
        answer: answer,
        correct: correct,
        minutes: minutes,
        blockId: widget.blockId,
      );
      _drafts[exercise.id] = LessonDraft(
        exerciseId: exercise.id,
        answer: answer,
        revealed: true,
        selfCheck: correct ? 'correct' : 'review',
      );
      widget.controller.repository.saveLessonDrafts(lesson.id, _drafts);
      setState(
        () => _notice = correct
            ? '已记录这次作答与自评（正确）。'
            : '已记录这次作答，并标记为需要复习。',
      );
    } catch (error) {
      setState(() => _error = '记录失败：$error');
    }
  }

  Future<void> _generate() async {
    if (_generating) return;
    setState(() => _error = null);
    PreparedLessonRequest prepared;
    try {
      prepared = widget.controller.prepareLesson(widget.task);
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
        title: '生成今日课程',
        subtitle: '发送前确认材料范围与模型。',
        maxWidth: 560,
        actions: [
          DialogActions.cancel(context),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认生成'),
          ),
        ],
        content: Text(
          prepared.previewSummary,
          style: context.texts.bodySmall!.copyWith(height: 1.6),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _generating = true);
    final generation = ++_generation;
    try {
      final lesson = await widget.controller.sendLesson(
        prepared,
        isCancelled: () => generation != _generation,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _lesson = lesson;
        _generating = false;
      });
      _loadDrafts();
      _syncAnswers();
      WidgetsBinding.instance.addPostFrameCallback((_) => _restoreScroll());
    } on AiFailure catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _generating = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '生成失败：$error';
          _generating = false;
        });
      }
    }
  }

  void _cancelGeneration() {
    _generation++;
    setState(() {
      _generating = false;
      _notice = '已取消生成；晚到的课程结果不会保存。';
    });
  }

  @override
  Widget build(BuildContext context) {
    final lesson = _lesson;
    final actions = _actions(context);
    if (widget.pageMode) {
      return Scaffold(
        backgroundColor: context.colors.canvas,
        appBar: AppBar(
          leading: IconButton(
            tooltip: '返回',
            onPressed: () => Navigator.maybePop(context),
            icon: const QIcon(QIcons.back, size: IconSizes.md),
          ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '今日课程',
                style: context.texts.titleSmall!.copyWith(fontSize: 16),
              ),
              Text(
                '${widget.task.title} · 返回日程后仍保留本次日期',
                style: context.texts.bodySmall!.copyWith(fontSize: 11.5),
              ),
            ],
          ),
          toolbarHeight: 58,
        ),
        body: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 860),
              child: _body(context, lesson),
            ),
          ),
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                for (var index = 0; index < actions.length; index++) ...[
                  if (index > 0) const SizedBox(width: 8),
                  actions[index],
                ],
              ],
            ),
          ),
        ),
      );
    }
    return AppDialog(
      title: '今日课程',
      subtitle:
          '${widget.task.title} · ${widget.task.minutes} 分钟${lesson?.sourceRangeLabel == null ? '' : ' · ${lesson!.sourceRangeLabel}'}',
      maxWidth: 820,
      actions: actions,
      content: _body(context, lesson),
    );
  }

  List<Widget> _actions(BuildContext context) => [
    if (_generating)
      TextButton(
        onPressed: _cancelGeneration,
        child: const Text('取消生成'),
      )
    else
      TextButton.icon(
        onPressed: _generate,
        icon: const QIcon(QIcons.ai, size: IconSizes.sm),
        label: const Text('生成今日课程'),
      ),
    if (widget.pageMode)
      FilledButton(
        onPressed: () => Navigator.maybePop(context),
        child: const Text('返回日程'),
      )
    else
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('完成'),
      ),
  ];

  Widget _body(BuildContext context, DailyLesson? lesson) =>
      Column(
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
              tone: CalloutTone.success,
              message: _notice!,
              onDismiss: () => setState(() => _notice = null),
            ),
            const SizedBox(height: Space.md),
          ],
          if (lesson == null)
            EmptyState(
              icon: QIcons.textbook,
              title: '还没有生成课程',
              message: '按绑定页段的已解析文本生成课程，生成前可确认模型与范围。',
              compact: true,
              action: FilledButton.icon(
                onPressed: _generating ? null : _generate,
                icon: const QIcon(QIcons.ai, size: IconSizes.sm),
                label: const Text('生成今日课程'),
              ),
            )
          else ...[
            Text(
              lesson.title,
              style: context.texts.titleSmall!.copyWith(fontSize: 16),
            ),
            const SizedBox(height: 4),
            Text(
              lesson.objective,
              style: context.texts.bodySmall!.copyWith(height: 1.6),
            ),
            const SizedBox(height: Space.md),
            for (final section in lesson.sections) ...[
              _SectionCard(section: section),
              const SizedBox(height: Space.sm),
            ],
            const SizedBox(height: Space.sm),
            Row(
              children: [
                Text(
                  '练习',
                  style: context.texts.titleSmall!.copyWith(fontSize: 14),
                ),
                const Spacer(),
                SizedBox(
                  width: 64,
                  child: TextField(
                    key: const ValueKey('lesson-actual-minutes'),
                    controller: _minutes,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: '实际分钟',
                      isDense: true,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            for (final exercise in lesson.exercises) ...[
              _ExerciseCard(
                exercise: exercise,
                answer: _answers[exercise.id]!,
                revealed: _revealed.contains(exercise.id),
                selfCheck: _drafts[exercise.id]?.selfCheck ?? '',
                onChanged: _scheduleSave,
                onReveal: () {
                  setState(() => _revealed.add(exercise.id));
                  _persistDrafts();
                },
                onCorrect: () => _recordSelfCheck(exercise, true),
                onReview: () => _recordSelfCheck(exercise, false),
              ),
              const SizedBox(height: Space.sm),
            ],
            Text(
              '请先独立作答再核对答案；任务完成与实际用时请在日历记录。',
              style: context.texts.bodySmall!.copyWith(
                fontSize: 11.5,
                color: context.colors.inkMuted,
                height: 1.55,
              ),
            ),
          ],
        ],
      );
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.section});

  final LessonSection section;

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
                  section.title,
                  style: context.texts.bodyMedium!.copyWith(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (section.sourcePage != null)
                AppBadge(label: '第 ${section.sourcePage} 页', dense: true),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            section.body,
            style: context.texts.bodySmall!.copyWith(height: 1.65),
          ),
        ],
      ),
    );
  }
}

class _ExerciseCard extends StatelessWidget {
  const _ExerciseCard({
    required this.exercise,
    required this.answer,
    required this.revealed,
    required this.selfCheck,
    required this.onChanged,
    required this.onReveal,
    required this.onCorrect,
    required this.onReview,
  });

  final LessonExercise exercise;
  final TextEditingController answer;
  final bool revealed;
  final String selfCheck;
  final VoidCallback onChanged;
  final VoidCallback onReveal;
  final VoidCallback onCorrect;
  final VoidCallback onReview;

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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  exercise.prompt,
                  style: context.texts.bodySmall!.copyWith(
                    fontSize: 13,
                    height: 1.6,
                  ),
                ),
              ),
              if (exercise.sourcePage != null)
                AppBadge(label: '第 ${exercise.sourcePage} 页', dense: true),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            key: ValueKey('lesson-answer-${exercise.id}'),
            controller: answer,
            minLines: 2,
            maxLines: 5,
            onChanged: (_) => onChanged(),
            decoration: const InputDecoration(
              hintText: '先写下你的答案，再展开参考解答',
            ),
          ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: onReveal,
              child: Text(revealed ? '参考解答' : '展开答案与解答'),
            ),
          ),
          if (revealed) ...[
            Text(
              '答案：${exercise.answer}',
              style: context.texts.bodySmall!.copyWith(
                color: c.ink,
                fontWeight: FontWeight.w600,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              exercise.solution,
              style: context.texts.bodySmall!.copyWith(height: 1.65),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                OutlinedButton(
                  onPressed: onCorrect,
                  child: Text(selfCheck == 'correct' ? '已记录：答对' : '我答对了'),
                ),
                TextButton(
                  onPressed: onReview,
                  child: Text(
                    selfCheck == 'review' ? '已记录：需要复习' : '需要复习',
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
