import 'package:flutter/material.dart';

import '../../../ui/theme/tokens.dart';
import '../models/note_models.dart';
import '../notes_controller.dart';

/// Supporting pane for a note's textbook sources and open questions.
/// Can be rendered inside the collapsible right drawer on desktop or inline at
/// the bottom of the editor on compact viewports.
class NoteContextPane extends StatelessWidget {
  const NoteContextPane({
    super.key,
    required this.controller,
    required this.onAddQuestion,
    this.onOpenSource,
    this.onCollapse,
    this.sidebarStyle = true,
  });

  final NotesController controller;
  final VoidCallback onAddQuestion;
  final ValueChanged<NoteSource>? onOpenSource;
  final VoidCallback? onCollapse;
  final bool sidebarStyle;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (sidebarStyle) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  '来源与问题',
                  style: context.texts.bodySmall!.copyWith(
                    fontSize: 12,
                    color: colors.inkMuted,
                    fontWeight: FontWeight.w600,
                    letterSpacing: .5,
                  ),
                ),
              ),
              if (onCollapse != null)
                IconButton(
                  tooltip: '收起来源与问题',
                  onPressed: onCollapse,
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                  padding: EdgeInsets.zero,
                  icon: QIcon(
                    QIcons.chevronRight,
                    size: IconSizes.sm,
                    color: colors.inkMuted,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
        ],
        _sourcesCard(context),
        const SizedBox(height: 14),
        _questionsCard(context),
      ],
    );
    if (!sidebarStyle) return content;
    return ColoredBox(
      color: colors.sidebar,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 16, 32),
        children: [content],
      ),
    );
  }

  Widget _sourcesCard(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: colors.surfaceRaised,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: colors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const QIcon(QIcons.anchor, size: 13),
              const SizedBox(width: 6),
              Text(
                '来源（${controller.selectedSources.length}）',
                style: context.texts.bodySmall!.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (controller.selectedSources.isEmpty)
            Text(
              '从阅读器记笔记时会自动保存资料、页码和选区。',
              style: context.texts.bodySmall!.copyWith(
                fontSize: 12,
                color: colors.inkMuted,
              ),
            )
          else
            for (final source in controller.selectedSources)
              Container(
                margin: const EdgeInsets.only(top: 6),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: BorderRadius.circular(Radii.sm),
                  border: Border.all(color: colors.outline),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${source.title.isEmpty ? '资料' : source.title}'
                            '${source.page == null ? '' : ' · 第 ${source.page} 页'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: context.texts.bodySmall!.copyWith(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (source.excerpt.trim().isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Text(
                              source.excerpt,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: context.texts.bodySmall!.copyWith(
                                fontSize: 12,
                                height: 1.45,
                                color: colors.inkMuted,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (source.documentId != null)
                      IconButton(
                        tooltip: '回到原文',
                        onPressed: () => onOpenSource?.call(source),
                        icon: const QIcon(QIcons.external, size: IconSizes.sm),
                        visualDensity: VisualDensity.compact,
                        constraints: const BoxConstraints(
                          minWidth: 28,
                          minHeight: 28,
                        ),
                        padding: EdgeInsets.zero,
                      ),
                    IconButton(
                      tooltip: '移除来源记录',
                      onPressed: () => controller.deleteSource(source),
                      icon: const QIcon(QIcons.close, size: IconSizes.sm),
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      padding: EdgeInsets.zero,
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }

  Widget _questionsCard(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: colors.surfaceRaised,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: colors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const QIcon(QIcons.qa, size: 13),
              const SizedBox(width: 6),
              Text(
                '待解决问题',
                style: context.texts.bodySmall!.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed:
                    controller.selected == null ||
                        controller.selected!.isTrashed
                    ? null
                    : onAddQuestion,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 28),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact,
                ),
                icon: const QIcon(QIcons.add, size: 12),
                label: const Text('添加', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          if (controller.selectedQuestions.isEmpty)
            Text(
              '记下问题不会自动标记为已掌握。',
              style: context.texts.bodySmall!.copyWith(
                fontSize: 12,
                color: colors.inkMuted,
              ),
            )
          else
            for (final question in controller.selectedQuestions)
              Material(
                color: Colors.transparent,
                child: CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: question.status == NoteQuestionStatus.resolved,
                  onChanged: (_) => controller.toggleQuestion(question),
                  title: Text(
                    question.text,
                    style: context.texts.bodySmall!.copyWith(
                      fontSize: 12,
                      color: question.isOpen ? colors.ink : colors.inkMuted,
                      decoration: question.isOpen
                          ? TextDecoration.none
                          : TextDecoration.lineThrough,
                    ),
                  ),
                  secondary: IconButton(
                    tooltip: '删除问题',
                    onPressed: () => controller.deleteQuestion(question),
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 26,
                      minHeight: 26,
                    ),
                    padding: EdgeInsets.zero,
                    icon: const QIcon(QIcons.close, size: 12),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}
