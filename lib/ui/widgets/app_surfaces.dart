import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';
import 'app_close_button.dart';

/// A flat bordered surface with a real focus ring. Hover uses a quiet tint
/// rather than lift/shadow so lists stay visually stable, like a workbench.
class AppCard extends StatefulWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Space.lg),
    this.onTap,
    this.onLongPress,
    this.background,
    this.borderColor,
    this.radius = Radii.md,
    this.elevated = true,
    this.semanticLabel,
    this.tooltip,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Color? background;
  final Color? borderColor;
  final double radius;

  /// Kept for call-site compatibility; surfaces no longer lift on hover.
  final bool elevated;
  final String? semanticLabel;
  final String? tooltip;

  @override
  State<AppCard> createState() => _AppCardState();
}

class _AppCardState extends State<AppCard> {
  bool _hovered = false;
  bool _focused = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final interactive = widget.onTap != null;
    final border = _focused
        ? c.primary
        : (_hovered && interactive
              ? c.primary.withValues(alpha: .35)
              : widget.borderColor ?? c.outline);

    Widget surface = AnimatedContainer(
      duration: context.motion(Motion.fast),
      curve: Motion.curveStandard,
      decoration: BoxDecoration(
        color:
            widget.background ??
            (_hovered && interactive
                ? c.tint.withValues(alpha: .45)
                : c.surface),
        borderRadius: BorderRadius.circular(widget.radius),
        border: Border.all(color: border, width: _focused ? 2 : 1),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(widget.radius),
        clipBehavior: Clip.antiAlias,
        child: interactive
            ? InkWell(
                onTap: widget.onTap,
                onLongPress: widget.onLongPress,
                onHover: (value) => setState(() => _hovered = value),
                onHighlightChanged: (value) => setState(() => _pressed = value),
                onFocusChange: (value) => setState(() => _focused = value),
                mouseCursor: SystemMouseCursors.click,
                hoverColor: Colors.transparent,
                focusColor: Colors.transparent,
                splashColor: c.primary.withValues(alpha: .05),
                customBorder: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(widget.radius),
                ),
                child: Padding(padding: widget.padding, child: widget.child),
              )
            : Padding(padding: widget.padding, child: widget.child),
      ),
    );

    if (widget.tooltip != null && !interactive) {
      surface = Tooltip(message: widget.tooltip!, child: surface);
    }
    if (widget.semanticLabel != null) {
      surface = Semantics(
        container: true,
        button: interactive,
        label: widget.semanticLabel,
        child: surface,
      );
    }
    if (interactive) {
      surface = AnimatedScale(
        scale: _pressed ? 0.992 : 1.0,
        duration: context.motion(const Duration(milliseconds: 90)),
        curve: Motion.curve,
        child: surface,
      );
    }
    return surface;
  }
}

/// Functional icon. The Codex shell is strictly monochrome; colour is reserved
/// for the Page-Q brand mark and destructive/error states.
class AccentIcon extends StatelessWidget {
  const AccentIcon({
    super.key,
    required this.icon,
    required this.accent,
    this.size = 30,
    this.iconSize = IconSizes.sm,
    this.radius = Radii.sm,
    this.background,
  });

  final QIconData icon;
  final AppAccent accent;
  final double size;
  final double iconSize;
  final double radius;
  final Color? background;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: Center(
      child: QIcon(icon, size: iconSize, color: context.colors.inkMuted),
    ),
  );
}

enum BadgeTone { neutral, primary, blue, green, violet, warm, danger }

class AppBadge extends StatelessWidget {
  const AppBadge({
    super.key,
    required this.label,
    this.tone = BadgeTone.neutral,
    this.icon,
    this.dense = false,
  });

  final String label;
  final BadgeTone tone;
  final QIconData? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (background, foreground) = switch (tone) {
      BadgeTone.danger => (c.dangerTint, c.danger),
      _ => (c.tint, c.inkMuted),
    };
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 8 : 10,
        vertical: dense ? 2.5 : 3.5,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            QIcon(icon, size: IconSizes.sm, color: foreground),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: context.texts.bodySmall!.copyWith(
              color: foreground,
              fontSize: dense ? 12 : 12.5,
              fontWeight: FontWeight.w600,
              height: 1.3,
              fontFeatures: AppNumerals.tabular,
            ),
          ),
        ],
      ),
    );
  }
}

enum CalloutTone { info, success, warning, error }

/// In-page message. One callout per problem, with an explicit way out.
class AppCallout extends StatelessWidget {
  const AppCallout({
    super.key,
    required this.message,
    this.tone = CalloutTone.info,
    this.title,
    this.action,
    this.onDismiss,
    this.icon,
  });

  final String message;
  final CalloutTone tone;
  final String? title;
  final Widget? action;
  final VoidCallback? onDismiss;
  final QIconData? icon;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (accent, background, resolvedIcon) = switch (tone) {
      CalloutTone.info => (
        c.inkMuted,
        c.surfaceRaised,
        QIcons.info,
      ),
      CalloutTone.success => (
        c.inkMuted,
        c.surfaceRaised,
        QIcons.success,
      ),
      CalloutTone.warning => (
        c.inkMuted,
        c.surfaceRaised,
        QIcons.error,
      ),
      CalloutTone.error => (
        c.danger,
        c.dangerTint,
        QIcons.warning,
      ),
    };
    return Semantics(
      container: true,
      liveRegion: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.md),
        child: ColoredBox(
          color: background,
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 2, child: ColoredBox(color: accent)),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: QIcon(
                            icon ?? resolvedIcon,
                            size: IconSizes.sm,
                            color: accent,
                          ),
                        ),
                        const SizedBox(width: Space.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (title != null) ...[
                                Text(
                                  title!,
                                  style: context.texts.bodyMedium!.copyWith(
                                    color: c.ink,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 2),
                              ],
                              Text(
                                message,
                                style: context.texts.bodySmall!.copyWith(
                                  color: c.ink,
                                  fontSize: 13,
                                  height: 1.55,
                                ),
                              ),
                              if (action != null) ...[
                                const SizedBox(height: Space.sm),
                                action!,
                              ],
                            ],
                          ),
                        ),
                        if (onDismiss != null)
                          AppCloseButton(
                            tooltip: '关闭提示',
                            onPressed: onDismiss,
                            size: 36,
                            iconSize: IconSizes.md,
                            color: accent,
                          ),
                      ],
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

/// Compact trust marker used instead of repeating privacy paragraphs.
class TrustNote extends StatelessWidget {
  const TrustNote(
    this.text, {
    super.key,
    this.icon = QIcons.local,
    this.emphasize = false,
  });

  final String text;
  final QIconData icon;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: QIcon(icon, size: IconSizes.sm, color: c.green),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            style: context.texts.bodySmall!.copyWith(
              color: emphasize ? c.ink : c.inkMuted,
              height: 1.55,
            ),
          ),
        ),
      ],
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    this.compact = false,
    this.accent,
  });

  final QIconData icon;
  final String title;
  final String message;
  final Widget? action;
  final bool compact;
  final AppAccent? accent;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final a = accent ?? c.neutralAccent;
    return Semantics(
      container: true,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: Space.xl,
          vertical: compact ? Space.lg : Space.xl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: IconSizes.xl,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    right: 1,
                    top: 1,
                    width: 32,
                    height: 32,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(Radii.md),
                        border: Border.all(color: c.outlineStrong, width: 1.5),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    bottom: 0,
                    width: 34,
                    height: 34,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: a.tint,
                        borderRadius: BorderRadius.circular(Radii.md),
                        border: Border.all(color: c.outline),
                      ),
                      child: Center(
                        child: QIcon(
                          icon,
                          size: IconSizes.md,
                          color: a.color,
                          active: true,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: compact ? Space.md : Space.lg),
            Text(
              title,
              textAlign: TextAlign.center,
              style: context.texts.titleMedium,
            ),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: context.texts.bodyMedium!.copyWith(
                  color: c.inkMuted,
                  height: 1.65,
                ),
              ),
            ),
            if (action != null) ...[const SizedBox(height: Space.lg), action!],
          ],
        ),
      ),
    );
  }
}

/// Compact inline metric used in a toolbar/meta row instead of a full card.
class MetaStat extends StatelessWidget {
  const MetaStat({
    super.key,
    required this.icon,
    required this.value,
    required this.label,
    required this.accent,
  });

  final QIconData icon;
  final String value;
  final String label;
  final AppAccent accent;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        QIcon(icon, size: IconSizes.sm, color: accent.color),
        const SizedBox(width: 6),
        Text(
          value,
          style: context.texts.bodySmall!.copyWith(
            color: c.ink,
            fontWeight: FontWeight.w600,
            fontFeatures: AppNumerals.tabular,
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: context.texts.bodySmall),
      ],
    );
  }
}

class StatBlock extends StatelessWidget {
  const StatBlock({
    super.key,
    required this.icon,
    required this.value,
    required this.label,
  });

  final QIconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final iconBox = Container(
      width: narrow ? 26 : 34,
      height: narrow ? 26 : 34,
      decoration: BoxDecoration(
        color: c.tint,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Center(
        child: QIcon(
          icon,
          size: narrow ? IconSizes.sm : IconSizes.md,
          color: c.primary,
        ),
      ),
    );
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: narrow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    iconBox,
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.texts.titleLarge!.copyWith(
                          fontSize: 19,
                          fontFeatures: AppNumerals.tabular,
                          height: 1.2,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.bodySmall!.copyWith(
                    fontSize: 11.5,
                    height: 1.35,
                  ),
                ),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                iconBox,
                const SizedBox(width: 10),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.texts.titleLarge!.copyWith(
                          fontFeatures: AppNumerals.tabular,
                          height: 1.2,
                        ),
                      ),
                      Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.texts.bodySmall!.copyWith(height: 1.4),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.trailing,
    this.accent,
  });

  final String title;
  final String? subtitle;
  final QIconData? icon;
  final Widget? trailing;
  final AppAccent? accent;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final a = accent ?? c.neutralAccent;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          AccentIcon(icon: icon!, accent: a, size: 28, iconSize: IconSizes.sm),
          const SizedBox(width: Space.md),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: context.texts.titleSmall),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  style: context.texts.bodySmall!.copyWith(height: 1.5),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: Space.sm), trailing!],
      ],
    );
  }
}

class AppSegment {
  const AppSegment({required this.label, this.icon, this.count});

  final String label;
  final QIconData? icon;
  final int? count;
}

/// A quiet segmented control shared by filters, view switchers and presets.
class AppSegmentedControl extends StatefulWidget {
  const AppSegmentedControl({
    super.key,
    required this.segments,
    required this.selectedIndex,
    required this.onChanged,
    this.expand = false,
    this.dense = false,
    this.segmentMinWidth = 0,
  });

  final List<AppSegment> segments;
  final int selectedIndex;
  final ValueChanged<int> onChanged;
  final bool expand;
  final bool dense;
  final double segmentMinWidth;

  @override
  State<AppSegmentedControl> createState() => _AppSegmentedControlState();
}

class _AppSegmentedControlState extends State<AppSegmentedControl> {
  final _stackKey = GlobalKey();
  late List<GlobalKey> _segmentKeys;
  Rect? _indicatorRect;

  @override
  void initState() {
    super.initState();
    _segmentKeys = List.generate(widget.segments.length, (_) => GlobalKey());
  }

  @override
  void didUpdateWidget(covariant AppSegmentedControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.segments.length != widget.segments.length) {
      _segmentKeys = List.generate(widget.segments.length, (_) => GlobalKey());
      _indicatorRect = null;
    }
  }

  void _scheduleMeasure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final selected = widget.selectedIndex;
      if (selected < 0 || selected >= _segmentKeys.length) return;
      final stack =
          _stackKey.currentContext?.findRenderObject() as RenderBox?;
      final segment =
          _segmentKeys[selected].currentContext?.findRenderObject()
              as RenderBox?;
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
    final dark = c.isDark;
    final hasCountSlot = widget.segments.any((segment) => segment.count != null);
    final children = <Widget>[];
    for (var index = 0; index < widget.segments.length; index++) {
      final segment = widget.segments[index];
      final selected = index == widget.selectedIndex;
      final content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (segment.icon != null) ...[
            QIcon(
              segment.icon,
              size: IconSizes.sm,
              color: selected ? c.ink : c.inkMuted,
              active: selected,
            ),
            const SizedBox(width: 6),
          ],
          Text(
            segment.label,
            maxLines: 1,
            style: context.texts.bodySmall!.copyWith(
              fontSize: widget.dense ? 13 : 13.5,
              color: selected ? c.ink : c.inkMuted,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              height: 1.2,
            ),
          ),
          if (hasCountSlot) ...[
            const SizedBox(width: 5),
            SizedBox(
              width: 22,
              child: Align(
                alignment: Alignment.centerRight,
                child: Text(
                  segment.count == null ? '' : '${segment.count}',
                  style: context.texts.bodySmall!.copyWith(
                    fontSize: widget.dense ? 12 : 12.5,
                    color: c.inkMuted,
                    fontFeatures: AppNumerals.tabular,
                    height: 1.2,
                  ),
                ),
              ),
            ),
          ],
        ],
      );
      final button = Semantics(
        button: true,
        selected: selected,
        label: segment.label,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: widget.segmentMinWidth),
          child: InkWell(
            key: _segmentKeys[index],
            onTap: () => widget.onChanged(index),
            borderRadius: BorderRadius.circular(6),
            hoverColor: c.tint.withValues(alpha: dark ? .18 : .35),
            child: DecoratedBox(
              decoration: selected && _indicatorRect == null
                  ? BoxDecoration(
                      color: dark ? const Color(0xFF2C2C30) : c.surface,
                      borderRadius: BorderRadius.circular(6),
                      border: dark
                          ? Border.all(color: const Color(0xFF3F3F46))
                          : null,
                      boxShadow: dark ? null : AppShadow.e1,
                    )
                  : const BoxDecoration(),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: widget.dense ? 10 : 14,
                  vertical: widget.dense ? 6 : 7,
                ),
                child: FittedBox(fit: BoxFit.scaleDown, child: content),
              ),
            ),
          ),
        ),
      );
      children.add(
        widget.expand
            ? Expanded(child: Center(child: button))
            : Padding(
                padding: EdgeInsets.only(
                  right: index == widget.segments.length - 1 ? 0 : 2,
                ),
                child: button,
              ),
      );
    }
    _scheduleMeasure();
    final indicator = _indicatorRect;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF18181B) : c.tint,
        borderRadius: BorderRadius.circular(8),
        border: dark ? Border.all(color: c.outline) : null,
      ),
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
                  color: dark ? const Color(0xFF2C2C30) : c.surface,
                  borderRadius: BorderRadius.circular(6),
                  border: dark
                      ? Border.all(color: const Color(0xFF3F3F46))
                      : null,
                  boxShadow: dark ? null : AppShadow.e1,
                ),
              ),
            ),
          Row(
            mainAxisSize: widget.expand
                ? MainAxisSize.max
                : MainAxisSize.min,
            children: children,
          ),
        ],
      ),
    );
  }
}

class AppChoiceChip extends StatelessWidget {
  const AppChoiceChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
    this.icon,
    this.count,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool> onSelected;
  final QIconData? icon;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ChoiceChip(
      selected: selected,
      onSelected: onSelected,
      showCheckmark: false,
      avatar: icon == null
          ? null
          : QIcon(
              icon,
              size: IconSizes.sm,
              color: selected ? c.primary : c.inkMuted,
              active: selected,
            ),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          if (count != null) ...[
            const SizedBox(width: 5),
            Text(
              '$count',
              style: TextStyle(
                fontFeatures: AppNumerals.tabular,
                color: selected ? c.primary : c.inkMuted,
              ),
            ),
          ],
        ],
      ),
      labelStyle: context.texts.bodySmall!.copyWith(
        fontSize: 12.5,
        color: selected ? c.primary : c.ink,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
      ),
      selectedColor: c.tint,
      backgroundColor: c.surface,
      side: BorderSide(
        color: selected ? c.primary.withValues(alpha: .55) : c.outlineStrong,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    );
  }
}

/// Small keyboard hint rendered next to a label.
class KeyHint extends StatelessWidget {
  const KeyHint(this.keys, {super.key});

  final String keys;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: c.canvas,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.outline),
      ),
      child: Text(
        keys,
        style: context.texts.labelSmall!.copyWith(
          fontSize: 10,
          letterSpacing: 0,
          color: c.inkMuted,
          fontFamily: 'Manrope',
          fontFeatures: AppNumerals.tabular,
        ),
      ),
    );
  }
}

/// Fades and nudges content when the active page changes. The child must be
/// keyed with the page identity.
class SectionSwitcher extends StatelessWidget {
  const SectionSwitcher({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: context.motion(Motion.base),
    switchInCurve: Motion.curve,
    switchOutCurve: Curves.easeIn,
    layoutBuilder: (currentChild, previousChildren) => Stack(
      fit: StackFit.expand,
      alignment: Alignment.topLeft,
      children: [...previousChildren, ?currentChild],
    ),
    transitionBuilder: (child, animation) => FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, .012),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: animation, curve: Motion.curve)),
        child: child,
      ),
    ),
    child: child,
  );
}

class SkeletonBlock extends StatelessWidget {
  const SkeletonBlock({
    super.key,
    this.width,
    required this.height,
    this.radius = Radii.sm,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: c.tint,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// Keyboard activation for custom tappable surfaces that are not buttons.
class TapShortcuts extends StatelessWidget {
  const TapShortcuts({super.key, required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.enter): onTap,
      const SingleActivator(LogicalKeyboardKey.space): onTap,
    },
    child: child,
  );
}
