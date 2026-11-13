import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../ui/theme/tokens.dart';
import '../../../ui/widgets/app_dialog.dart';
import '../../../ui/widgets/app_surfaces.dart';
import '../models/planning_models.dart';
import '../models/study_plan.dart';
import '../schedule_controller.dart';
import '../services/planning_ai_client.dart';

Future<void> showPlanningSheet(
  BuildContext context, {
  required ScheduleController controller,
  required VoidCallback onOpenSettings,
}) {
  controller.openPlanning();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    barrierColor: Colors.black.withValues(alpha: .18),
    backgroundColor: Colors.transparent,
    builder: (context) {
      final media = MediaQuery.of(context);
      final keyboard = media.viewInsets.bottom;
      final available = media.size.height - keyboard;
      final height = (available * .62).clamp(320.0, 520.0);
      return AnimatedPadding(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + keyboard),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: SizedBox(
              height: height,
              child: PlanningSheet(
                controller: controller,
                onOpenSettings: onOpenSettings,
              ),
            ),
          ),
        ),
      );
    },
  );
}

class PlanningSheet extends StatefulWidget {
  const PlanningSheet({
    super.key,
    required this.controller,
    required this.onOpenSettings,
    this.onClose,
    this.embedded = false,
  });

  final ScheduleController controller;
  final VoidCallback onOpenSettings;
  final VoidCallback? onClose;
  final bool embedded;

  @override
  State<PlanningSheet> createState() => _PlanningSheetState();
}

class _PlanningSheetState extends State<PlanningSheet> {
  final _input = TextEditingController();
  late final FocusNode _focus = FocusNode(onKeyEvent: _handleComposerKey);
  String? _error;

  ScheduleController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  KeyEventResult _handleComposerKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isMetaPressed &&
        (!_input.value.composing.isValid ||
            _input.value.composing.isCollapsed)) {
      _send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || c.planningSending) return;
    setState(() => _error = null);
    try {
      final prepared = c.preparePlanning(text);
      if (!mounted) return;
      final confirmed = await showPlanningPreview(context, prepared);
      if (confirmed != true || !mounted) return;
      _input.clear();
      await c.sendPreparedPlanning(prepared);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _apply(PlanningMessage message) async {
    final confirmed = await showPlanningProposal(
      context,
      controller: c,
      message: message,
    );
    if (confirmed != true || !mounted) return;
    try {
      final plan = c.applyPlanningProposal(message);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已应用「${plan.title}」的计划设置')),
      );
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  void _fill(String text) {
    _input.text = text;
    _input.selection = TextSelection.collapsed(offset: text.length);
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      key: const ValueKey('planning-sheet'),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(Radii.lg + 2),
        border: Border.all(color: colors.outlineStrong),
        boxShadow: AppShadow.e2,
      ),
      clipBehavior: Clip.antiAlias,
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final messages = widget.controller.planningMessages;
          final showPendingBubble = c.planningSending;
          final showEmpty = messages.isEmpty && !showPendingBubble;
          return Column(
            children: [
              if (!widget.embedded) _dragHandle(colors),
              _header(context),
              Divider(height: 1, color: colors.outline),
              Expanded(
                child: AnimatedSwitcher(
                  duration: context.motion(Motion.base),
                  switchInCurve: Motion.curve,
                  switchOutCurve: Curves.easeIn,
                  layoutBuilder: (current, previous) => Stack(
                    fit: StackFit.expand,
                    children: [
                      ...previous,
                      ?current,
                    ],
                  ),
                  child: showEmpty
                      ? KeyedSubtree(
                          key: const ValueKey('planning-empty'),
                          child: _empty(context),
                        )
                      : ListView.builder(
                          key: const ValueKey('planning-messages'),
                          reverse: true,
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                          itemCount:
                              messages.length + (showPendingBubble ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (showPendingBubble && index == 0) {
                              return _PendingThinkingBubble(
                                scopeLabel: c.planningScopeLabel,
                              );
                            }
                            final msgIdx = showPendingBubble ? index - 1 : index;
                            final message =
                                messages[messages.length - 1 - msgIdx];
                            return _MessageBubble(
                              key: ValueKey(message.id),
                              message: message,
                              existingPlan: widget.controller.planById(
                                message.proposal?.planId,
                              ),
                              onApply: () => _apply(message),
                              onFill: _fill,
                              onOpenSettings: widget.onOpenSettings,
                            );
                          },
                        ),
                ),
              ),
              if (_error != null || c.planningError != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: AppCallout(
                    tone: CalloutTone.error,
                    message: _error ?? c.planningError!,
                    action: (c.planningError?.contains('Key') ?? false) ||
                            (c.planningError?.contains('设置') ?? false)
                        ? TextButton(
                            onPressed: widget.onOpenSettings,
                            child: const Text('打开模型服务设置'),
                          )
                        : null,
                    onDismiss: () {
                      setState(() => _error = null);
                      widget.controller.clearPlanningError();
                    },
                  ),
                ),
              _composer(context),
            ],
          );
        },
      ),
    );
  }

  Widget _dragHandle(AppColors colors) => Center(
    child: Container(
      width: 38,
      height: 4,
      margin: const EdgeInsets.only(top: 8, bottom: 2),
      decoration: BoxDecoration(
        color: colors.outlineStrong,
        borderRadius: BorderRadius.circular(Radii.full),
      ),
    ),
  );

  Widget _header(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, widget.embedded ? 12 : 8, 8, 10),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: colors.tint,
              borderRadius: BorderRadius.circular(Radii.sm),
            ),
            alignment: Alignment.center,
            child: QIcon(
              QIcons.ai,
              size: IconSizes.sm,
              color: colors.ink,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'AI 排课',
                      style: context.texts.titleSmall!.copyWith(fontSize: 15),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: AppBadge(
                        label: c.planningScopeLabel,
                        dense: true,
                      ),
                    ),
                  ],
                ),
                if (c.planningSending) ...[
                  const SizedBox(height: 2),
                  Text(
                    '正在生成可审阅草案…',
                    style: context.texts.bodySmall!.copyWith(
                      fontSize: 11.5,
                      color: colors.primary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          TextButton(
            onPressed: c.planningSending
                ? null
                : widget.controller.startNewPlanningConversation,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            ),
            child: const Text('新对话'),
          ),
          IconButton(
            tooltip: '模型服务设置',
            onPressed: widget.onOpenSettings,
            visualDensity: VisualDensity.compact,
            icon: const QIcon(QIcons.settings, size: IconSizes.md),
          ),
          IconButton(
            tooltip: '关闭排期对话',
            onPressed: widget.onClose ?? () => Navigator.maybePop(context),
            visualDensity: VisualDensity.compact,
            icon: const QIcon(QIcons.close, size: IconSizes.md),
          ),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final c = context.colors;
    if (widget.embedded) {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
        child: Column(
          children: [
            Text(
              '输入考试目标与可用时间，生成可审阅草案',
              textAlign: TextAlign.center,
              style: context.texts.titleSmall,
            ),
            const SizedBox(height: 6),
            Text(
              '信息不足时会集中补问；不直接写入日历或编造页码。',
              textAlign: TextAlign.center,
              style: context.texts.bodySmall!.copyWith(height: 1.5),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              alignment: WrapAlignment.center,
              children: [
                for (final example in const [
                  '这个月 29 号要考数学',
                  '每周一至五 19:30–21:00',
                  '每天最多一小时',
                ])
                  ActionChip(
                    label: Text(example),
                    onPressed: () => _fill(example),
                  ),
              ],
            ),
          ],
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          QIcon(QIcons.ai, size: IconSizes.lg, color: c.inkMuted),
          const SizedBox(height: 10),
          Text(
            '说明目标与空闲时段，生成计划草案',
            textAlign: TextAlign.center,
            style: context.texts.titleSmall,
          ),
          const SizedBox(height: 6),
          Text(
            '如考试日、科目、每周可用时间；生成后须确认才写入。',
            textAlign: TextAlign.center,
            style: context.texts.bodySmall!.copyWith(height: 1.6),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              for (final example in const [
                '这个月 29 号要考数学，帮我排备考计划',
                '每周一至五 19:30–21:00 可以学习',
                '每天最多一小时，周末不排',
              ])
                ActionChip(
                  label: Text(example),
                  onPressed: () => _fill(example),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _composer(BuildContext context) {
    final colors = context.colors;
    final focused = _focus.hasFocus;
    final bottomInset = widget.embedded
        ? 0.0
        : MediaQuery.viewInsetsOf(context).bottom;
    return Container(
      padding: EdgeInsets.fromLTRB(14, 10, 14, 10 + bottomInset),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.outline)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedContainer(
            duration: context.motion(Motion.fast),
            curve: Motion.curveStandard,
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
            decoration: BoxDecoration(
              color: colors.sidebar,
              borderRadius: BorderRadius.circular(Radii.md + 2),
              border: Border.all(
                color: focused ? colors.primary : colors.outlineStrong,
                width: focused ? 1.5 : 1,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('planning-input'),
                    controller: _input,
                    focusNode: _focus,
                    minLines: 1,
                    maxLines: 4,
                    enabled: !c.planningSending,
                    textInputAction: TextInputAction.newline,
                    style: context.texts.bodyMedium!.copyWith(fontSize: 13.5),
                    decoration: InputDecoration(
                      isDense: true,
                      filled: false,
                      fillColor: Colors.transparent,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 6),
                      hintText: '例如：11 月 29 日数学考试，周一到周五晚 19:30–21:00 有空',
                      hintStyle: context.texts.bodySmall!.copyWith(
                        fontSize: 13,
                        color: colors.inkMuted,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                AnimatedSwitcher(
                  duration: context.motion(Motion.fast),
                  switchInCurve: Motion.curve,
                  switchOutCurve: Curves.easeIn,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale: Tween<double>(
                        begin: .96,
                        end: 1,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: c.planningSending
                      ? OutlinedButton.icon(
                          key: const ValueKey('planning-cancel'),
                          onPressed: c.cancelPlanningSend,
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            minimumSize: const Size(0, 34),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                          ),
                          icon: const QIcon(QIcons.stop, size: IconSizes.sm),
                          label: const Text('取消'),
                        )
                      : FilledButton.icon(
                          key: const ValueKey('planning-send'),
                          onPressed: _send,
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            minimumSize: const Size(0, 34),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                          ),
                          icon: const QIcon(QIcons.send, size: IconSizes.sm),
                          label: const Text('发送'),
                        ),
                ),
              ],
            ),
          ),
          if (widget.embedded) ...[
            const SizedBox(height: 5),
            Row(
              children: [
                Text(
                  'Enter 发送 · Shift+Enter 换行 · 发送前会先预览上下文',
                  style: context.texts.bodySmall!.copyWith(
                    fontSize: 11,
                    color: colors.inkMuted,
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

Future<bool?> showPlanningPreview(
  BuildContext context,
  PreparedPlanningRequest request,
) => showAppDialog<bool>(
  context: context,
  builder: (context) => AppDialog(
    title: '发送排期请求',
    subtitle: '仅发送本消息、作用域与近期对话；不发送教材原文或其他计划。',
    maxWidth: 620,
    actions: [
      DialogActions.cancel(context),
      FilledButton(
        key: const ValueKey('planning-confirm-send'),
        onPressed: () => Navigator.pop(context, true),
        child: const Text('确认发送'),
      ),
    ],
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const DialogFieldLabel('消息'),
        Text(
          request.message,
          style: context.texts.bodyMedium!.copyWith(height: 1.65),
        ),
        const SizedBox(height: Space.md),
        const DialogFieldLabel('本次上下文'),
        Text(
          request.contextSummary,
          style: context.texts.bodySmall!.copyWith(height: 1.6),
        ),
        const SizedBox(height: Space.md),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            AppBadge(label: request.settings.provider),
            AppBadge(label: request.model),
            const AppBadge(label: '不自动重试'),
          ],
        ),
      ],
    ),
  ),
);

Future<bool?> showPlanningProposal(
  BuildContext context, {
  required ScheduleController controller,
  required PlanningMessage message,
}) {
  final proposal = message.proposal!;
  final existing = controller.planById(proposal.planId);
  final lines = proposal.summaryLines(existing);
  return showAppDialog<bool>(
    context: context,
    builder: (context) => AppDialog(
      title: existing == null ? '应用新计划设置' : '更新计划设置',
      subtitle: '确认后写入本机计划与可用时间，不改日历时间块或已完成记录。',
      maxWidth: 620,
      actions: [
        DialogActions.cancel(context),
        FilledButton(
          key: const ValueKey('planning-apply'),
          onPressed: message.applied
              ? null
              : () => Navigator.pop(context, true),
          child: Text(message.applied ? '已应用' : '应用设置'),
        ),
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Text(
                '· $line',
                style: context.texts.bodySmall!.copyWith(
                  fontSize: 13,
                  color: context.colors.ink,
                  height: 1.55,
                ),
              ),
            ),
          if (proposal.unsupported.isNotEmpty) ...[
            const SizedBox(height: Space.md),
            const AppCallout(
              tone: CalloutTone.warning,
              message: '未覆盖项请在后续步骤绑定材料或知识点。',
            ),
          ],
        ],
      ),
    ),
  );
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    super.key,
    required this.message,
    required this.existingPlan,
    required this.onApply,
    required this.onFill,
    required this.onOpenSettings,
  });

  final PlanningMessage message;
  final StudyPlan? existingPlan;
  final VoidCallback onApply;
  final ValueChanged<String> onFill;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final user = message.role == PlanningRole.user;
    final alignment = user ? Alignment.centerRight : Alignment.centerLeft;
    return Align(
      alignment: alignment,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 620),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
        decoration: BoxDecoration(
          color: user ? c.tint : c.surfaceRaised,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(
            color: message.failed ? c.danger.withValues(alpha: .35) : c.outline,
          ),
        ),
        child: Column(
          crossAxisAlignment: user
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!user) ...[
                  AppBadge(label: message.kind.label, dense: true),
                  const SizedBox(width: 6),
                ],
                Text(
                  _time(message.createdAt),
                  style: context.texts.bodySmall!.copyWith(fontSize: 11),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Text(
              message.text,
              style: context.texts.bodySmall!.copyWith(
                fontSize: 13.5,
                color: c.ink,
                height: 1.6,
              ),
            ),
            if (message.missingMaterial.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final item in message.missingMaterial)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    '缺少：$item',
                    style: context.texts.bodySmall!.copyWith(
                      fontSize: 12,
                      color: c.danger,
                    ),
                  ),
                ),
            ],
            if (message.questions.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final question in message.questions) ...[
                Text(
                  '${question.question}${question.options.isEmpty ? '' : '（可点选）'}',
                  style: context.texts.bodySmall!.copyWith(
                    fontSize: 12.5,
                    color: c.ink,
                  ),
                ),
                if (question.options.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final option in question.options)
                        ActionChip(
                          label: Text(option),
                          onPressed: () => onFill(option),
                        ),
                    ],
                  ),
                ],
              ],
            ],
            if (message.proposal != null) ...[
              const SizedBox(height: 9),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(Radii.sm),
                  border: Border.all(color: c.outline),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final line in message.proposal!.summaryLines(
                      existingPlan,
                    ))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Text(
                          line,
                          style: context.texts.bodySmall!.copyWith(
                            fontSize: 12,
                            color: c.ink,
                          ),
                        ),
                      ),
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        onPressed: message.applied ? null : onApply,
                        child: Text(
                          message.applied ? '已应用' : '查看并应用设置',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (message.failed) ...[
              const SizedBox(height: 6),
              TextButton.icon(
                onPressed: onOpenSettings,
                icon: const QIcon(QIcons.settings, size: IconSizes.sm),
                label: const Text('打开模型服务设置'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _time(DateTime value) =>
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}';
}

class _PendingThinkingBubble extends StatelessWidget {
  const _PendingThinkingBubble({required this.scopeLabel});

  final String scopeLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 460),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
        decoration: BoxDecoration(
          color: c.surfaceRaised,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: c.outline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                '正在结合「$scopeLabel」整理可审阅草案…',
                style: context.texts.bodySmall!.copyWith(
                  fontSize: 13,
                  color: c.inkMuted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
