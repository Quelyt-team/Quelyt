import 'package:flutter/material.dart';

import '../../../ui/theme/tokens.dart';
import '../../../ui/widgets/app_dialog.dart';
import '../../../ui/widgets/app_surfaces.dart';
import '../data/schedule_repository.dart';
import '../domain/schedule_validator.dart';
import '../models/calendar_block.dart';
import '../models/local_date.dart';
import '../models/schedule_draft.dart';
import '../models/schedule_revision.dart';
import '../models/schedule_time.dart';
import '../schedule_controller.dart';

Future<ScheduleRevision?> showScheduleDraftDialog(
  BuildContext context, {
  required ScheduleController controller,
  required ScheduleDraft draft,
}) => showAppDialog<ScheduleRevision>(
  context: context,
  barrierDismissible: false,
  builder: (context) =>
      _ScheduleDraftDialog(controller: controller, draft: draft),
);

class _ScheduleDraftDialog extends StatefulWidget {
  const _ScheduleDraftDialog({required this.controller, required this.draft});

  final ScheduleController controller;
  final ScheduleDraft draft;

  @override
  State<_ScheduleDraftDialog> createState() => _ScheduleDraftDialogState();
}

class _ScheduleDraftDialogState extends State<_ScheduleDraftDialog> {
  String? _error;
  bool _applying = false;

  ScheduleDraft get draft => widget.draft;

  Future<void> _apply() async {
    setState(() {
      _applying = true;
      _error = null;
    });
    try {
      final revision = widget.controller.applyDraft(draft);
      if (mounted) Navigator.pop(context, revision);
    } on ScheduleConflictException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } on ScheduleValidationException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (error) {
      if (mounted) setState(() => _error = '应用失败：$error');
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final byDate = <LocalDate, List<CalendarBlock>>{};
    for (final block in draft.addedBlocks) {
      byDate.putIfAbsent(block.date, () => []).add(block);
    }
    final dates = byDate.keys.toList()..sort();
    final shown = <(_Date, CalendarBlock)>[
      for (final date in dates)
        for (final block in byDate[date]!
          ..sort((a, b) => a.startMinute.compareTo(b.startMinute)))
          (_Date(date), block),
    ];
    return AppDialog(
      title: '排期草案',
      subtitle: '${draft.planTitle} · ${draft.rangeStart.shortLabel}–${draft.rangeEnd.shortLabel}'
          ' · 应用前不会改动正式日历。',
      maxWidth: 760,
      actions: [
        DialogActions.cancel(context),
        FilledButton.icon(
          onPressed: _applying || draft.isEmpty ? null : _apply,
          icon: _applying
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const QIcon(QIcons.done, size: IconSizes.sm),
          label: Text(_applying ? '应用中' : '应用计划'),
        ),
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) ...[
            AppCallout(
              tone: CalloutTone.error,
              message: _error!,
              title: '草案已过期',
              onDismiss: () => setState(() => _error = null),
            ),
            const SizedBox(height: Space.md),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _Metric(
                icon: QIcons.duration,
                label: '可用',
                value: formatDuration(draft.availableMinutes),
              ),
              _Metric(
                icon: QIcons.done,
                label: '安排',
                value: formatDuration(draft.scheduledMinutes),
              ),
              _Metric(
                icon: QIcons.pause,
                label: '机动/上限',
                value: formatDuration(draft.bufferMinutes),
              ),
              _Metric(
                icon: QIcons.error,
                label: '未排入',
                value: draft.unplaced.isEmpty
                    ? '0 项'
                    : '${draft.unplaced.length} 项',
              ),
            ],
          ),
          if (draft.warnings.isNotEmpty) ...[
            const SizedBox(height: Space.md),
            for (final warning in draft.warnings)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: AppCallout(
                  tone: CalloutTone.warning,
                  message: warning,
                ),
              ),
          ],
          if (draft.removedBlocks.isNotEmpty) ...[
            const SizedBox(height: Space.sm),
            Text(
              '会移动 ${draft.removedBlocks.length} 个未开始的时间块。',
              style: context.texts.bodySmall!.copyWith(fontSize: 12.5),
            ),
          ],
          if (draft.addedBlocks.isNotEmpty) ...[
            const SizedBox(height: Space.md),
            const SectionHeader(title: '新增时间块'),
            const SizedBox(height: Space.sm),
            for (final item in shown.take(48))
              _DraftRow(date: item.$1.value, block: item.$2),
            if (shown.length > 48)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '还有 ${shown.length - 48} 个时间块未在预览中展开。',
                  style: context.texts.bodySmall,
                ),
              ),
          ],
          if (draft.unplaced.isNotEmpty) ...[
            const SizedBox(height: Space.md),
            const SectionHeader(title: '没有排入的任务'),
            const SizedBox(height: Space.sm),
            for (final task in draft.unplaced)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        task.title,
                        style: context.texts.bodySmall!.copyWith(
                          color: c.ink,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    Text(
                      '${task.remainingMinutes} 分钟 · ${task.reason}',
                      style: context.texts.bodySmall!.copyWith(fontSize: 12),
                    ),
                  ],
                ),
              ),
          ],
          if (draft.assumptions.isNotEmpty) ...[
            const SizedBox(height: Space.md),
            Text('采用的假设', style: context.texts.titleSmall),
            const SizedBox(height: 4),
            for (final assumption in draft.assumptions)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  '· $assumption',
                  style: context.texts.bodySmall!.copyWith(fontSize: 12.5),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _Date {
  const _Date(this.value);
  final LocalDate value;
}

class _DraftRow extends StatelessWidget {
  const _DraftRow({required this.date, required this.block});

  final LocalDate date;
  final CalendarBlock block;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.outline)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(
              date.shortLabel,
              style: context.texts.bodySmall!.copyWith(
                fontSize: 12.5,
                color: c.ink,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          SizedBox(
            width: 105,
            child: Text(
              block.timeLabel,
              style: context.texts.bodySmall!.copyWith(
                fontSize: 12.5,
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
                fontSize: 13,
                color: c.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.icon,
    required this.label,
    required this.value,
  });

  final QIconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: c.tint,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          QIcon(icon, size: IconSizes.sm, color: c.inkMuted),
          const SizedBox(width: 6),
          Text(
            '$label $value',
            style: context.texts.bodySmall!.copyWith(
              fontSize: 12.5,
              color: c.ink,
              fontFeatures: AppNumerals.tabular,
            ),
          ),
        ],
      ),
    );
  }
}
