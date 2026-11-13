import 'package:flutter/material.dart';

import '../../../ui/theme/tokens.dart';
import '../../../ui/widgets/app_dialog.dart';
import '../../../ui/widgets/app_surfaces.dart';
import '../models/calendar_block.dart';
import '../models/catch_up.dart';
import '../models/study_task.dart';
import '../schedule_controller.dart';

Future<void> showCatchUpDialog(
  BuildContext context,
  ScheduleController controller,
  StudyTask task,
  CalendarBlock block,
) => showAppDialog<void>(
  context: context,
  builder: (context) => _CatchUpDialog(
    controller: controller,
    task: task,
    block: block,
  ),
);

class _CatchUpDialog extends StatefulWidget {
  const _CatchUpDialog({
    required this.controller,
    required this.task,
    required this.block,
  });

  final ScheduleController controller;
  final StudyTask task;
  final CalendarBlock block;

  @override
  State<_CatchUpDialog> createState() => _CatchUpDialogState();
}

class _CatchUpDialogState extends State<_CatchUpDialog> {
  late final List<CatchUpSuggestion> _suggestions =
      widget.controller.suggestCatchUp(widget.task, widget.block);
  String? _error;

  void _apply(CatchUpSuggestion suggestion) {
    try {
      widget.controller.applyCatchUp(widget.task, suggestion);
      Navigator.pop(context);
    } catch (error) {
      setState(() => _error = '应用补课失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final remaining = (widget.block.minutes - widget.block.completedMinutes)
        .clamp(5, widget.block.minutes);
    return AppDialog(
      title: '补课建议',
      subtitle:
          '${widget.task.title} · 剩余 $remaining 分钟 · 仅推荐可用时间空档。',
      maxWidth: 560,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) ...[
            AppCallout(tone: CalloutTone.error, message: _error!),
            const SizedBox(height: Space.md),
          ],
          if (_suggestions.isEmpty)
            const EmptyState(
              icon: QIcons.missed,
              title: '没有可用的补课空档',
              message: '当前计划无可用时间或空档不足，请调整可用时间或手动改期。',
              compact: true,
            )
          else
            for (final suggestion in _suggestions) ...[
              Container(
                margin: const EdgeInsets.only(bottom: Space.sm),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: context.colors.surface,
                  border: Border.all(color: context.colors.outline),
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: Row(
                  children: [
                    const QIcon(QIcons.done, size: IconSizes.md),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        suggestion.timeLabel,
                        style: context.texts.bodySmall!.copyWith(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    FilledButton(
                      onPressed: () => _apply(suggestion),
                      child: const Text('应用'),
                    ),
                  ],
                ),
              ),
            ],
          Text(
            '应用后将新增一个锁定时间块，原逾期与历史记录保持不变。',
            style: context.texts.bodySmall!.copyWith(
              fontSize: 11.5,
              color: context.colors.inkMuted,
              height: 1.55,
            ),
          ),
        ],
      ),
    );
  }
}
