import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../theme/tokens.dart';

/// Floating study capsule for the reader.
///
/// Desktop and medium windows place a vertical capsule over the page canvas;
/// the phone layout uses a short horizontal capsule above the sheet. Labels
/// stay centred in their slot; counts sit in the top-right corner.
class LearningDock extends StatelessWidget {
  const LearningDock({
    super.key,
    required this.kind,
    required this.selectedIndex,
    required this.replyCount,
    required this.noteCount,
    required this.onSelect,
    this.vertical = true,
    this.floating = false,
  });

  final DocumentKind kind;
  final int? selectedIndex;
  final int replyCount;
  final int noteCount;
  final ValueChanged<int> onSelect;
  final bool vertical;
  final bool floating;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final learnIcon = kind == DocumentKind.textbook
        ? Icons.menu_book_outlined
        : Icons.article_outlined;
    final items = [
      (learnIcon, '学习', 0, 0),
      (Icons.forum_outlined, '问答', 1, replyCount),
      (Icons.edit_note_outlined, '笔记', 2, noteCount),
    ];

    if (floating) {
      final content = vertical
          ? Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final item in items)
                  _VerticalDockItem(
                    key: ValueKey('learning-dock-${item.$3}'),
                    icon: item.$1,
                    label: item.$2,
                    selected: selectedIndex == item.$3,
                    count: item.$4,
                    onTap: () => onSelect(item.$3),
                  ),
              ],
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final item in items)
                  SizedBox(
                    width: 72,
                    height: 44,
                    child: _HorizontalDockItem(
                      key: ValueKey('learning-dock-${item.$3}'),
                      icon: item.$1,
                      label: item.$2,
                      selected: selectedIndex == item.$3,
                      count: item.$4,
                      onTap: () => onSelect(item.$3),
                    ),
                  ),
              ],
            );
      return Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: c.outline),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: .10),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: content,
      );
    }

    return Container(
      width: vertical ? 64 : null,
      height: vertical ? null : 56,
      decoration: BoxDecoration(
        color: vertical ? c.sidebar : c.surface,
        border: Border(
          right: vertical ? BorderSide(color: c.outline) : BorderSide.none,
          top: vertical ? BorderSide.none : BorderSide(color: c.outline),
        ),
      ),
      child: vertical
          ? Column(
              children: [
                const SizedBox(height: 12),
                for (final item in items)
                  _VerticalDockItem(
                    key: ValueKey('learning-dock-${item.$3}'),
                    icon: item.$1,
                    label: item.$2,
                    selected: selectedIndex == item.$3,
                    count: item.$4,
                    onTap: () => onSelect(item.$3),
                  ),
              ],
            )
          : Row(
              children: [
                for (final item in items)
                  Expanded(
                    child: _HorizontalDockItem(
                      key: ValueKey('learning-dock-${item.$3}'),
                      icon: item.$1,
                      label: item.$2,
                      selected: selectedIndex == item.$3,
                      count: item.$4,
                      onTap: () => onSelect(item.$3),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _VerticalDockItem extends StatelessWidget {
  const _VerticalDockItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.count,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fg = selected ? c.ink : c.inkMuted;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: Tooltip(
          message: selected ? '收起$label面板' : '打开$label面板',
          waitDuration: const Duration(milliseconds: 500),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(999),
              hoverColor: c.tint.withValues(alpha: .55),
              child: SizedBox(
                width: 48,
                height: 56,
                child: Center(
                  child: AnimatedContainer(
                    duration: context.motion(Motion.fast),
                    curve: Motion.curveStandard,
                    width: 48,
                    height: 56,
                    decoration: BoxDecoration(
                      color: selected ? c.tint : Colors.transparent,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: selected ? c.outline : Colors.transparent,
                      ),
                    ),
                    child: Stack(
                      children: [
                        Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(icon, size: 19, color: fg),
                              const SizedBox(height: 3),
                              Text(
                                label,
                                textAlign: TextAlign.center,
                                style: context.texts.labelSmall!.copyWith(
                                  fontSize: 10.5,
                                  height: 1.1,
                                  color: fg,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (count > 0)
                          Positioned(
                            top: 3,
                            right: 5,
                            child: Text(
                              '$count',
                              style: context.texts.labelSmall!.copyWith(
                                fontSize: 9,
                                height: 1,
                                letterSpacing: 0,
                                color: c.inkMuted,
                                fontFeatures: AppNumerals.tabular,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HorizontalDockItem extends StatelessWidget {
  const _HorizontalDockItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.count,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fg = selected ? c.ink : c.inkMuted;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Tooltip(
        message: selected ? '收起$label面板' : '打开$label面板',
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(999),
            hoverColor: c.tint.withValues(alpha: .55),
            child: AnimatedContainer(
              duration: context.motion(Motion.fast),
              curve: Motion.curveStandard,
              margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              decoration: BoxDecoration(
                color: selected ? c.tint : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: selected ? c.outline : Colors.transparent,
                ),
              ),
              child: Stack(
                children: [
                  Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, size: 18, color: fg),
                        const SizedBox(width: 6),
                        Text(
                          label,
                          style: context.texts.labelSmall!.copyWith(
                            fontSize: 12,
                            color: fg,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (count > 0)
                    Positioned(
                      top: 3,
                      right: 5,
                      child: Text(
                        '$count',
                        style: context.texts.labelSmall!.copyWith(
                          fontSize: 9,
                          height: 1,
                          letterSpacing: 0,
                          color: c.inkMuted,
                          fontFeatures: AppNumerals.tabular,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
