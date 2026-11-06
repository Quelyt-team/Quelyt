import 'dart:io';

import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import '../widgets/quelyt_mark.dart';
import 'app_chrome.dart';

/// Hosts the custom Windows caption above the Flutter route tree. Tests can
/// disable it; the real application enables it from main.dart.
class WindowFrame extends StatelessWidget {
  const WindowFrame({
    super.key,
    required this.child,
    this.enabled = false,
    this.showTitleBar = false,
  });

  final Widget child;
  final bool enabled;

  /// Kept for the bootstrap screen; the normal app renders its own unified
  /// header with the caption controls inside [StudyHome].
  final bool showTitleBar;

  @override
  Widget build(BuildContext context) {
    if (!enabled || !Platform.isWindows) return child;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (showTitleBar)
          Column(
            children: [
              const WindowTitleBar(),
              Expanded(child: child),
            ],
          )
        else
          child,
        const _WindowResizeFrame(),
      ],
    );
  }
}

/// The Flutter view covers the whole client area, so native edge hit-testing
/// never sees the frame. These six-pixel Flutter overlays hand resize gestures
/// back to the native non-client resize loop.
class _WindowResizeFrame extends StatelessWidget {
  const _WindowResizeFrame();

  @override
  Widget build(BuildContext context) => const ExcludeSemantics(
    child: Stack(
      children: [
        _ResizeHandle(
          edge: 'top',
          cursor: SystemMouseCursors.resizeUpDown,
          top: 0,
          left: 8,
          right: 8,
          height: 6,
        ),
        _ResizeHandle(
          edge: 'bottom',
          cursor: SystemMouseCursors.resizeUpDown,
          bottom: 0,
          left: 8,
          right: 8,
          height: 6,
        ),
        _ResizeHandle(
          edge: 'left',
          cursor: SystemMouseCursors.resizeLeftRight,
          left: 0,
          top: 8,
          bottom: 8,
          width: 6,
        ),
        _ResizeHandle(
          edge: 'right',
          cursor: SystemMouseCursors.resizeLeftRight,
          right: 0,
          top: 8,
          bottom: 8,
          width: 6,
        ),
        _ResizeHandle(
          edge: 'topLeft',
          cursor: SystemMouseCursors.resizeUpLeftDownRight,
          top: 0,
          left: 0,
          width: 8,
          height: 8,
        ),
        _ResizeHandle(
          edge: 'topRight',
          cursor: SystemMouseCursors.resizeUpRightDownLeft,
          top: 0,
          right: 0,
          width: 8,
          height: 8,
        ),
        _ResizeHandle(
          edge: 'bottomLeft',
          cursor: SystemMouseCursors.resizeUpRightDownLeft,
          bottom: 0,
          left: 0,
          width: 8,
          height: 8,
        ),
        _ResizeHandle(
          edge: 'bottomRight',
          cursor: SystemMouseCursors.resizeUpLeftDownRight,
          bottom: 0,
          right: 0,
          width: 8,
          height: 8,
        ),
      ],
    ),
  );
}

class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({
    required this.edge,
    required this.cursor,
    this.top,
    this.bottom,
    this.left,
    this.right,
    this.width,
    this.height,
  });

  final String edge;
  final MouseCursor cursor;
  final double? top;
  final double? bottom;
  final double? left;
  final double? right;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: top,
      bottom: bottom,
      left: left,
      right: right,
      width: width,
      height: height,
      child: MouseRegion(
        cursor: cursor,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) {
            WindowState.instance.startResize(edge);
          },
        ),
      ),
    );
  }
}

/// The caption used by the bootstrap error screen. The normal app draws window
/// controls inside its unified header instead.
class WindowTitleBar extends StatelessWidget {
  const WindowTitleBar({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: c.sidebar,
      child: SizedBox(
        height: AppChrome.titleBarHeight,
        child: Row(
          children: [
            Expanded(
              child: WindowDragRegion(
                child: Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: Row(
                    children: [
                      const QuelytMark(
                        size: 24,
                        tile: true,
                        semanticLabel: null,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Quelyt',
                        style: context.texts.labelMedium!.copyWith(
                          fontFamily: 'Manrope',
                          fontSize: 15.5,
                          letterSpacing: .1,
                          color: c.ink,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const WindowCaptionControls(),
          ],
        ),
      ),
    );
  }
}

/// Draggable title area that does not steal the double-click gesture.
///
/// Dragging starts only after a pan threshold; a pointer-down immediately
/// entering the native move loop used to swallow the second click.
class WindowDragRegion extends StatelessWidget {
  const WindowDragRegion({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.basic,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) {
        WindowState.instance.startDrag();
      },
      onDoubleTap: () {
        WindowState.instance.toggleMaximize();
      },
      child: child,
    ),
  );
}
