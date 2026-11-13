import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../services/document_service.dart';
import 'theme/tokens.dart';
import 'widgets/app_close_button.dart';

/// The original page. Selection geometry is computed exactly as before:
/// normalized to the unrotated rendered page, unaffected by zoom, display
/// rotation or colour tone.
class PageSurface extends StatefulWidget {
  const PageSurface({
    super.key,
    required this.page,
    required this.selection,
    required this.highlight,
    required this.onSelect,
    this.pageLabel,
    this.filter,
    this.inverted = false,
    this.showHint = false,
    this.onDismissHint,
  });

  final RenderedPage page;
  final SourceRegion? selection;
  final SourceRegion? highlight;
  final ValueChanged<SourceRegion?> onSelect;
  final String? pageLabel;
  final ColorFilter? filter;
  final bool inverted;
  final bool showHint;
  final VoidCallback? onDismissHint;

  @override
  State<PageSurface> createState() => PageSurfaceState();
}

class PageSurfaceState extends State<PageSurface> {
  final _transform = TransformationController();
  bool _selecting = false;
  int _rotation = 0;
  Offset? _start;
  Size _viewport = Size.zero;
  Timer? _hintTimer;

  bool get selecting => _selecting;
  int get rotation => _rotation;

  @override
  void initState() {
    super.initState();
    _scheduleHint();
  }

  void _scheduleHint() {
    _hintTimer?.cancel();
    if (!widget.showHint || widget.onDismissHint == null) return;
    _hintTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) widget.onDismissHint?.call();
    });
  }

  @override
  void didUpdateWidget(PageSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.showHint && widget.showHint) _scheduleHint();
    if (!widget.showHint) _hintTimer?.cancel();
    if (!identical(oldWidget.page, widget.page)) {
      _transform.value = Matrix4.identity();
      _rotation = 0;
      _selecting = false;
      _start = null;
    }
  }

  @override
  void dispose() {
    _hintTimer?.cancel();
    _transform.dispose();
    super.dispose();
  }

  void fit() => _transform.value = Matrix4.identity();

  void rotate() {
    setState(() {
      _rotation = (_rotation + 1) % 4;
      _transform.value = Matrix4.identity();
    });
  }

  void setSelecting(bool value) {
    if (_selecting == value) return;
    setState(() => _selecting = value);
  }

  void toggleSelecting() => setSelecting(!_selecting);

  void clearSelection() => widget.onSelect(null);

  /// Zooms around the centre of the visible stage and keeps the selection
  /// geometry untouched.
  void zoomBy(double factor) {
    if (_viewport.isEmpty) return;
    final current = _transform.value.getMaxScaleOnAxis();
    final next = (current * factor).clamp(.8, 6.0);
    final tx = _viewport.width / 2 * (1 - next);
    final ty = _viewport.height / 2 * (1 - next);
    _transform.value = Matrix4.identity()
      ..setEntry(0, 0, next)
      ..setEntry(0, 3, tx)
      ..setEntry(1, 1, next)
      ..setEntry(1, 3, ty);
  }

  void _select(Offset point, Size size) {
    if (_start == null) return;
    final left =
        math.min(_start!.dx, point.dx).clamp(0.0, size.width) / size.width;
    final top =
        math.min(_start!.dy, point.dy).clamp(0.0, size.height) / size.height;
    final right =
        math.max(_start!.dx, point.dx).clamp(0.0, size.width) / size.width;
    final bottom =
        math.max(_start!.dy, point.dy).clamp(0.0, size.height) / size.height;
    if (right - left > .003 && bottom - top > .003) {
      widget.onSelect(SourceRegion(left, top, right, bottom));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final selectionInk = widget.inverted
        ? Colors.white
        : const Color(0xFF171717);
    return Stack(
      children: [
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: LayoutBuilder(
              builder: (context, constraints) {
                _viewport = Size(constraints.maxWidth, constraints.maxHeight);
                final ratio = widget.page.width / widget.page.height;
                final maxWidth = math.max(1.0, constraints.maxWidth - 32);
                final maxHeight = math.max(1.0, constraints.maxHeight);
                final width = _rotation.isEven
                    ? math.min(maxWidth, maxHeight * ratio)
                    : math.min(maxHeight, maxWidth * ratio);
                final size = Size(width, width / ratio);
                return InteractiveViewer(
                  transformationController: _transform,
                  panEnabled: !_selecting,
                  scaleEnabled: !_selecting,
                  minScale: .8,
                  maxScale: 6,
                  boundaryMargin: const EdgeInsets.all(100),
                  child: Center(
                    child: Semantics(
                      image: true,
                      label: widget.pageLabel ?? '原页',
                      hint: _selecting ? '拖动框选原文或图表' : '可缩放与平移',
                      child: RotatedBox(
                        quarterTurns: _rotation,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanStart: !_selecting
                              ? null
                              : (details) {
                                  _start = details.localPosition;
                                  widget.onSelect(null);
                                },
                          onPanUpdate: !_selecting
                              ? null
                              : (details) =>
                                    _select(details.localPosition, size),
                          onPanEnd: !_selecting ? null : (_) => _start = null,
                          child: MouseRegion(
                            cursor: _selecting
                                ? SystemMouseCursors.precise
                                : SystemMouseCursors.grab,
                            child: AnimatedContainer(
                              duration: context.motion(Motion.base),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                border: Border.all(color: c.outlineStrong),
                                boxShadow: AppShadow.paper,
                              ),
                              child: SizedBox(
                                width: size.width,
                                height: size.height,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    ColoredBox(
                                      color: Colors.white,
                                      child: AnimatedSwitcher(
                                        duration: context.motion(Motion.base),
                                        switchInCurve: Curves.easeOut,
                                        child: _pageImage(),
                                      ),
                                    ),
                                    if (widget.highlight != null)
                                      _region(
                                        widget.highlight!,
                                        c.ink,
                                        c.ink.withValues(alpha: .12),
                                      ),
                                    if (widget.selection != null)
                                      _region(
                                        widget.selection!,
                                        selectionInk,
                                        selectionInk.withValues(alpha: .04),
                                        anchors: true,
                                      ),
                                    if (_selecting)
                                      IgnorePointer(
                                        child: DecoratedBox(
                                          decoration: BoxDecoration(
                                            border: Border.all(
                                              color: selectionInk.withValues(
                                                alpha: .45,
                                              ),
                                            ),
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
              },
            ),
          ),
        ),
        if (widget.showHint)
          Positioned(
            left: Space.lg,
            right: Space.lg,
            top: Space.md,
            child: Center(child: _HintChip(onClose: widget.onDismissHint)),
          ),
        Positioned(
          left: Space.lg,
          right: Space.lg,
          bottom: Space.md,
          child: Center(child: _toolbar(MediaQuery.sizeOf(context).width)),
        ),
      ],
    );
  }

  Widget _pageImage() {
    final image = Image.memory(
      widget.page.bytes,
      key: ValueKey<int>(widget.page.bytes.hashCode),
      fit: BoxFit.fill,
      gaplessPlayback: true,
      filterQuality: FilterQuality.high,
    );
    final filter = widget.filter;
    return filter == null
        ? image
        : ColorFiltered(colorFilter: filter, child: image);
  }

  Widget _toolbar(double screenWidth) {
    final c = context.colors;
    final compact = screenWidth < 520;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
      decoration: BoxDecoration(
        color: c.surfaceRaised.withValues(alpha: .96),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: c.outline),
        boxShadow: AppShadow.e1,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ToolAction(
            icon: QIcons.region,
            label: '框选',
            tooltip: _selecting ? '退出框选（Ctrl+Shift+S）' : '框选原文（Ctrl+Shift+S）',
            active: _selecting,
            showLabel: !compact,
            onTap: toggleSelecting,
          ),
          _ToolDivider(),
          _ToolAction(
            icon: QIcons.fit,
            label: '适应',
            tooltip: '适应窗口（Ctrl+0）',
            showLabel: !compact,
            onTap: fit,
          ),
          _ToolAction(
            icon: QIcons.rotate,
            label: '旋转',
            tooltip: '旋转显示（Ctrl+R）',
            showLabel: !compact,
            onTap: rotate,
          ),
          if (widget.selection != null) ...[
            _ToolDivider(),
            _ToolAction(
              icon: QIcons.clear,
              label: '清除选区',
              tooltip: '清除选区（Esc）',
              showLabel: !compact,
              onTap: clearSelection,
            ),
          ],
        ],
      ),
    );
  }

  Widget _region(
    SourceRegion region,
    Color border,
    Color fill, {
    bool anchors = false,
  }) => Positioned.fill(
    child: LayoutBuilder(
      builder: (context, c) => Stack(
        children: [
          Positioned(
            left: c.maxWidth * region.left,
            top: c.maxHeight * region.top,
            width: c.maxWidth * region.width,
            height: c.maxHeight * region.height,
            child: Stack(
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: fill,
                      border: Border.all(color: border, width: 1.5),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                if (anchors)
                  for (final alignment in [
                    Alignment.topLeft,
                    Alignment.topRight,
                    Alignment.bottomLeft,
                    Alignment.bottomRight,
                  ])
                    Align(
                      alignment: alignment,
                      child: Container(width: 6, height: 6, color: border),
                    ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _ToolAction extends StatelessWidget {
  const _ToolAction({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.showLabel = true,
  });

  final QIconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final foreground = active ? c.onPrimary : c.ink;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        toggled: active,
        label: label,
        child: Material(
          color: active ? c.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            hoverColor: active ? Colors.transparent : c.tint,
            splashColor: c.primary.withValues(alpha: .10),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: showLabel ? 12 : 9,
                vertical: 6,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  QIcon(icon, size: IconSizes.sm, color: foreground),
                  if (showLabel) ...[
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: context.texts.bodySmall!.copyWith(
                        fontSize: 13,
                        color: foreground,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
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

class _ToolDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: 16,
    margin: const EdgeInsets.symmetric(horizontal: 4),
    color: context.colors.outline,
  );
}

class _HintChip extends StatelessWidget {
  const _HintChip({this.onClose});

  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final mobile = MediaQuery.sizeOf(context).width < 600;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        borderRadius: BorderRadius.circular(Radii.full),
        border: Border.all(color: c.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          QIcon(QIcons.mouse, size: IconSizes.sm, color: c.inkMuted),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              mobile ? '双指缩放 · 拖动平移' : '滚轮缩放 · 拖动平移',
              style: context.texts.bodySmall!.copyWith(fontSize: 12),
            ),
          ),
          if (onClose != null) ...[
            const SizedBox(width: 4),
            AppCloseButton(
              tooltip: '不再显示',
              onPressed: onClose,
              iconSize: IconSizes.sm,
            ),
          ],
        ],
      ),
    );
  }
}
