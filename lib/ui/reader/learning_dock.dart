import 'dart:ui';

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../theme/tokens.dart';

/// Floating study capsule for the reader.
///
/// Desktop and medium windows float a slim 46 px icon-only capsule (inspired
/// by Figma / Apple Freeform / Material 3 Expressive floating toolbars) over
/// the page margin so reading space stays uncluttered. Compact phone layouts
/// float a tight content-hugging horizontal capsule above the learning sheet.
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

  static const double _verticalPadding = 4;
  static const double _verticalSlot = 38;
  static const double _verticalGap = 4;
  static const double _verticalStep = _verticalSlot + _verticalGap;

  List<_DockEntry> _entries() {
    final (learnIcon, learnHint) = switch (kind) {
      DocumentKind.textbook => (QIcons.dockStudy, '教材学习'),
      DocumentKind.paper => (QIcons.paper, '论文精读'),
      DocumentKind.exercise => (QIcons.dockExercise, '试题工具'),
      DocumentKind.video => (QIcons.dockStudy, '视频学习'),
      DocumentKind.unspecified => (QIcons.dockStudy, '阅读学习'),
    };
    return [
      _DockEntry(
        icon: learnIcon,
        label: '学习',
        hint: learnHint,
        index: 0,
        count: 0,
      ),
      _DockEntry(
        icon: QIcons.dockQa,
        label: '问答',
        hint: replyCount > 0 ? '问答 · $replyCount 条' : '问答',
        index: 1,
        count: replyCount,
      ),
      _DockEntry(
        icon: QIcons.dockNotes,
        label: '笔记',
        hint: noteCount > 0 ? '笔记 · $noteCount 条' : '笔记',
        index: 2,
        count: noteCount,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final items = _entries();

    if (floating) {
      return vertical
          ? _buildFloatingVertical(context, c, items)
          : _FloatingHorizontalCapsule(
              items: items,
              selectedIndex: selectedIndex,
              onSelect: onSelect,
            );
    }

    return Container(
      width: vertical ? 56 : null,
      height: vertical ? null : 52,
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
                const SizedBox(height: 10),
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const SizedBox(height: _verticalGap),
                  _VerticalIconItem(
                    key: ValueKey('learning-dock-${items[i].index}'),
                    entry: items[i],
                    selected: selectedIndex == items[i].index,
                    showSelection: true,
                    onTap: () => onSelect(items[i].index),
                  ),
                ],
              ],
            )
          : Row(
              children: [
                for (final item in items)
                  Expanded(
                    child: _HorizontalPillItem(
                      key: ValueKey('learning-dock-${item.index}'),
                      entry: item,
                      selected: selectedIndex == item.index,
                      showSelection: true,
                      onTap: () => onSelect(item.index),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _buildFloatingVertical(
    BuildContext context,
    AppColors c,
    List<_DockEntry> items,
  ) {
    final totalHeight =
        items.length * _verticalSlot + (items.length - 1) * _verticalGap;
    return _CapsuleShell(
      padding: const EdgeInsets.all(_verticalPadding),
      child: SizedBox(
        width: _verticalSlot,
        height: totalHeight,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            if (selectedIndex != null)
              AnimatedPositioned(
                duration: context.motion(Motion.base),
                curve: Motion.curve,
                left: 0,
                top: selectedIndex! * _verticalStep,
                width: _verticalSlot,
                height: _verticalSlot,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: c.primary,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const SizedBox(height: _verticalGap),
                  _VerticalIconItem(
                    key: ValueKey('learning-dock-${items[i].index}'),
                    entry: items[i],
                    selected: selectedIndex == items[i].index,
                    showSelection: false,
                    onTap: () => onSelect(items[i].index),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DockEntry {
  const _DockEntry({
    required this.icon,
    required this.label,
    required this.hint,
    required this.index,
    required this.count,
  });

  final QIconData icon;
  final String label;
  final String hint;
  final int index;
  final int count;
}

class _CapsuleShell extends StatelessWidget {
  const _CapsuleShell({required this.padding, required this.child});

  final EdgeInsetsGeometry padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final dark = c.isDark;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.full),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? .34 : .09),
            blurRadius: 16,
            offset: const Offset(0, 5),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? .18 : .04),
            blurRadius: 3,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.full),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: c.surface.withValues(alpha: dark ? .88 : .92),
              borderRadius: BorderRadius.circular(Radii.full),
              border: Border.all(
                color: c.outlineStrong.withValues(alpha: dark ? .75 : .65),
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Content-hugging horizontal capsule for compact/phone viewports.
/// Measures the selected segment's exact rect so the sliding indicator wraps
/// tightly with zero wasted horizontal stretch.
class _FloatingHorizontalCapsule extends StatefulWidget {
  const _FloatingHorizontalCapsule({
    required this.items,
    required this.selectedIndex,
    required this.onSelect,
  });

  final List<_DockEntry> items;
  final int? selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  State<_FloatingHorizontalCapsule> createState() =>
      _FloatingHorizontalCapsuleState();
}

class _FloatingHorizontalCapsuleState
    extends State<_FloatingHorizontalCapsule> {
  final _stackKey = GlobalKey();
  late List<GlobalKey> _itemKeys;
  Rect? _indicatorRect;

  @override
  void initState() {
    super.initState();
    _itemKeys = List.generate(widget.items.length, (_) => GlobalKey());
  }

  @override
  void didUpdateWidget(covariant _FloatingHorizontalCapsule oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items.length != widget.items.length) {
      _itemKeys = List.generate(widget.items.length, (_) => GlobalKey());
      _indicatorRect = null;
    }
    if (widget.selectedIndex == null && _indicatorRect != null) {
      _indicatorRect = null;
    }
  }

  void _scheduleMeasure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final selected = widget.selectedIndex;
      if (selected == null || selected < 0 || selected >= _itemKeys.length) {
        if (_indicatorRect != null) setState(() => _indicatorRect = null);
        return;
      }
      final stack =
          _stackKey.currentContext?.findRenderObject() as RenderBox?;
      final segment =
          _itemKeys[selected].currentContext?.findRenderObject() as RenderBox?;
      if (stack == null ||
          segment == null ||
          !stack.hasSize ||
          !segment.hasSize) {
        return;
      }
      final topLeft = segment.localToGlobal(Offset.zero, ancestor: stack);
      final rect = topLeft & segment.size;
      if (rect != _indicatorRect) {
        setState(() => _indicatorRect = rect);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    _scheduleMeasure();
    final indicator = widget.selectedIndex != null ? _indicatorRect : null;
    return _CapsuleShell(
      padding: const EdgeInsets.all(3.5),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Stack(
          key: _stackKey,
          clipBehavior: Clip.none,
          children: [
            if (indicator != null)
              AnimatedPositioned(
                duration: context.motion(Motion.base),
                curve: Motion.curve,
                left: indicator.left,
                top: indicator.top,
                width: indicator.width,
                height: indicator.height,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: c.primary,
                    borderRadius: BorderRadius.circular(Radii.full),
                  ),
                ),
              ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < widget.items.length; i++) ...[
                  if (i > 0) const SizedBox(width: 2),
                  KeyedSubtree(
                    key: _itemKeys[i],
                    child: _HorizontalPillItem(
                      key: ValueKey('learning-dock-${widget.items[i].index}'),
                      entry: widget.items[i],
                      selected: widget.selectedIndex == widget.items[i].index,
                      showSelection: indicator == null,
                      onTap: () => widget.onSelect(widget.items[i].index),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _VerticalIconItem extends StatelessWidget {
  const _VerticalIconItem({
    super.key,
    required this.entry,
    required this.selected,
    required this.showSelection,
    required this.onTap,
  });

  final _DockEntry entry;
  final bool selected;
  final bool showSelection;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fg = selected ? c.onPrimary : c.inkMuted;
    return Semantics(
      button: true,
      selected: selected,
      label: entry.count > 0 ? '${entry.label}，${entry.count} 条' : entry.label,
      child: Tooltip(
        message: selected ? '收起${entry.label}面板' : entry.hint,
        waitDuration: const Duration(milliseconds: 350),
        preferBelow: false,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(Radii.full),
            hoverColor:
                selected ? Colors.transparent : c.tint.withValues(alpha: .75),
            child: AnimatedContainer(
              duration: context.motion(Motion.fast),
              curve: Motion.curveStandard,
              width: LearningDock._verticalSlot,
              height: LearningDock._verticalSlot,
              decoration: BoxDecoration(
                color: showSelection && selected
                    ? c.primary
                    : Colors.transparent,
                shape: BoxShape.circle,
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Center(
                    child: QIcon(
                      entry.icon,
                      size: 18,
                      color: fg,
                      active: selected,
                    ),
                  ),
                  if (entry.count > 0)
                    Positioned(
                      top: 1,
                      right: 1,
                      child: _MicroCornerBadge(
                        count: entry.count,
                        selected: selected,
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

class _HorizontalPillItem extends StatelessWidget {
  const _HorizontalPillItem({
    super.key,
    required this.entry,
    required this.selected,
    required this.showSelection,
    required this.onTap,
  });

  final _DockEntry entry;
  final bool selected;
  final bool showSelection;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fg = selected ? c.onPrimary : c.inkMuted;
    return Semantics(
      button: true,
      selected: selected,
      label: entry.count > 0 ? '${entry.label}，${entry.count} 条' : entry.label,
      child: Tooltip(
        message: selected ? '收起${entry.label}面板' : entry.hint,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(Radii.full),
            hoverColor:
                selected ? Colors.transparent : c.tint.withValues(alpha: .7),
            child: AnimatedContainer(
              duration: context.motion(Motion.fast),
              curve: Motion.curveStandard,
              constraints: const BoxConstraints(minHeight: 36),
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              decoration: BoxDecoration(
                color: showSelection && selected
                    ? c.primary
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(Radii.full),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  QIcon(
                    entry.icon,
                    size: 15,
                    color: fg,
                    active: selected,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    entry.label,
                    maxLines: 1,
                    style: context.texts.labelSmall!.copyWith(
                      fontSize: 12,
                      height: 1.15,
                      color: fg,
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                  if (entry.count > 0) ...[
                    const SizedBox(width: 4),
                    _InlineCountPill(count: entry.count, selected: selected),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MicroCornerBadge extends StatelessWidget {
  const _MicroCornerBadge({required this.count, required this.selected});

  final int count;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final text = count > 99 ? '99+' : '$count';
    return Container(
      constraints: const BoxConstraints(minWidth: 14, minHeight: 14),
      padding: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
        color: selected ? c.surface : c.primary,
        borderRadius: BorderRadius.circular(Radii.full),
        border: Border.all(
          color: selected ? c.primary : c.surface,
          width: 1.4,
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        text,
        style: context.texts.labelSmall!.copyWith(
          fontSize: 8.5,
          height: 1,
          letterSpacing: 0,
          color: selected ? c.ink : c.onPrimary,
          fontWeight: FontWeight.w700,
          fontFeatures: AppNumerals.tabular,
        ),
      ),
    );
  }
}

class _InlineCountPill extends StatelessWidget {
  const _InlineCountPill({required this.count, required this.selected});

  final int count;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final text = count > 99 ? '99+' : '$count';
    return Container(
      constraints: const BoxConstraints(minWidth: 16, minHeight: 15),
      padding: const EdgeInsets.symmetric(horizontal: 4.5, vertical: 0.5),
      decoration: BoxDecoration(
        color: selected ? c.onPrimary.withValues(alpha: .2) : c.tint,
        borderRadius: BorderRadius.circular(Radii.full),
      ),
      alignment: Alignment.center,
      child: Text(
        text,
        style: context.texts.labelSmall!.copyWith(
          fontSize: 9.5,
          height: 1.1,
          letterSpacing: 0,
          color: selected ? c.onPrimary : c.inkMuted,
          fontWeight: FontWeight.w600,
          fontFeatures: AppNumerals.tabular,
        ),
      ),
    );
  }
}
