import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/tokens.dart';

/// Single source of truth for the custom Windows caption.
///
/// The same numbers live in `windows/runner/win32_window.cpp`; keep them in
/// sync. Everything here is in logical pixels.
abstract final class AppChrome {
  /// Windows 11-style title bar: a compact 48px strip with 46x32 caption
  /// hover pills centred inside it. The hit target remains the full 48px.
  static const double titleBarHeight = 48;
  static const double captionButtonWidth = 46;
  static const double captionButtonHeight = 32;
  static const double captionButtonRadius = 4;
  static const int captionButtonCount = 3;
  static const double captionWidth = captionButtonWidth * captionButtonCount;
  static const double glyphBox = 10;
  static const double glyphStroke = 1.1;
}

/// Owns the single `quelyt/window` channel handler.
///
/// Header, reader and bootstrap controls all read the same maximized state, so
/// mounting/unmounting a control can no longer clear another control's handler.
class WindowState {
  WindowState._() {
    _channel.setMethodCallHandler(_onMessage);
  }

  static final WindowState instance = WindowState._();

  static const _channel = MethodChannel('quelyt/window');

  final ValueNotifier<bool> maximized = ValueNotifier<bool>(false);
  bool _refreshed = false;

  Future<void> refresh() async {
    if (!Platform.isWindows || _refreshed) return;
    _refreshed = true;
    try {
      final value = await _channel.invokeMethod<bool>('isMaximized');
      maximized.value = value ?? false;
    } catch (_) {
      // Widget tests and non-Windows hosts have no native channel.
    }
  }

  Future<void> _onMessage(MethodCall call) async {
    if (call.method == 'maximized' && call.arguments is bool) {
      maximized.value = call.arguments as bool;
    }
  }

  Future<void> toggleMaximize() async {
    try {
      final value = await _channel.invokeMethod<bool>('toggleMaximize');
      maximized.value = value ?? !maximized.value;
    } catch (_) {
      // Leave the last known state when the host is unavailable.
    }
  }

  void minimize() {
    _channel.invokeMethod<void>('minimize').catchError((_) {});
  }

  void close() {
    _channel.invokeMethod<void>('close').catchError((_) {});
  }

  void startDrag() {
    _channel.invokeMethod<void>('startDrag').catchError((_) {});
  }

  void startResize(String edge) {
    _channel.invokeMethod<void>('startResize', edge).catchError((_) {});
  }
}

enum CaptionGlyph { minimize, maximize, restore, close }

/// Windows-style caption buttons: a 46x48 hit target around a 46x32 hover
/// pill. Optional callbacks exist so widget tests can verify geometry and hit
/// areas without a native window.
class WindowCaptionControls extends StatefulWidget {
  const WindowCaptionControls({
    super.key,
    this.onMinimize,
    this.onMaximize,
    this.onClose,
  });

  final VoidCallback? onMinimize;
  final VoidCallback? onMaximize;
  final VoidCallback? onClose;

  @override
  State<WindowCaptionControls> createState() => _WindowCaptionControlsState();
}

class _WindowCaptionControlsState extends State<WindowCaptionControls> {
  @override
  void initState() {
    super.initState();
    WindowState.instance.refresh();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: WindowState.instance.maximized,
    builder: (context, maximized, _) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CaptionButton(
          key: const ValueKey('caption-minimize'),
          glyph: CaptionGlyph.minimize,
          label: '最小化',
          onTap: widget.onMinimize ?? WindowState.instance.minimize,
        ),
        _CaptionButton(
          key: const ValueKey('caption-maximize'),
          glyph: maximized ? CaptionGlyph.restore : CaptionGlyph.maximize,
          label: maximized ? '还原' : '最大化',
          onTap:
              widget.onMaximize ??
              () {
                WindowState.instance.toggleMaximize();
              },
        ),
        _CaptionButton(
          key: const ValueKey('caption-close'),
          glyph: CaptionGlyph.close,
          label: '关闭',
          close: true,
          onTap: widget.onClose ?? WindowState.instance.close,
        ),
      ],
    ),
  );
}

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    super.key,
    required this.glyph,
    required this.label,
    required this.onTap,
    this.close = false,
  });

  final CaptionGlyph glyph;
  final String label;
  final VoidCallback onTap;
  final bool close;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hovered = false;
  bool _pressed = false;

  Color _hoverColor(BuildContext context) {
    final dark = context.colors.isDark;
    if (widget.close) return const Color(0xFFC42B1C);
    return dark ? const Color(0xFF2D2D2D) : const Color(0xFFE9E9E9);
  }

  Color _pressedColor(BuildContext context) {
    final dark = context.colors.isDark;
    if (widget.close) return const Color(0xFFB22A1A);
    return dark ? const Color(0xFF3A3A3A) : const Color(0xFFDADADA);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final background = _pressed
        ? _pressedColor(context)
        : (_hovered ? _hoverColor(context) : Colors.transparent);
    final iconColor = widget.close && (_hovered || _pressed)
        ? Colors.white
        : c.ink;
    return Semantics(
      button: true,
      label: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() {
          _hovered = false;
          _pressed = false;
        }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapCancel: () => setState(() => _pressed = false),
          onTapUp: (_) => setState(() => _pressed = false),
          onTap: widget.onTap,
          child: SizedBox(
            width: AppChrome.captionButtonWidth,
            height: AppChrome.titleBarHeight,
            child: Center(
              child: AnimatedContainer(
                duration: context.motion(Motion.fast),
                curve: Motion.curveStandard,
                width: AppChrome.captionButtonWidth,
                height: AppChrome.captionButtonHeight,
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.circular(
                    AppChrome.captionButtonRadius,
                  ),
                ),
                alignment: Alignment.center,
                child: CustomPaint(
                  size: const Size(AppChrome.glyphBox, AppChrome.glyphBox),
                  painter: _CaptionGlyphPainter(
                    glyph: widget.glyph,
                    color: iconColor,
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

class _CaptionGlyphPainter extends CustomPainter {
  const _CaptionGlyphPainter({required this.glyph, required this.color});

  final CaptionGlyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = AppChrome.glyphStroke
      ..strokeCap = StrokeCap.square
      ..isAntiAlias = true;
    const inset = AppChrome.glyphStroke / 2;
    switch (glyph) {
      case CaptionGlyph.minimize:
        final y = size.height / 2;
        canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
        break;
      case CaptionGlyph.maximize:
        canvas.drawRect(
          Rect.fromLTWH(
            inset,
            inset,
            size.width - AppChrome.glyphStroke,
            size.height - AppChrome.glyphStroke,
          ),
          paint,
        );
        break;
      case CaptionGlyph.restore:
        final small = size.width - 3;
        canvas.drawRect(
          Rect.fromLTWH(0, size.height - small, small, small),
          paint,
        );
        canvas.drawRect(
          Rect.fromLTWH(size.width - small, 0, small, small),
          paint,
        );
        break;
      case CaptionGlyph.close:
        canvas.drawLine(const Offset(0, 0), Offset(size.width, size.height), paint);
        canvas.drawLine(Offset(size.width, 0), Offset(0, size.height), paint);
        break;
    }
  }

  @override
  bool shouldRepaint(_CaptionGlyphPainter oldDelegate) =>
      oldDelegate.glyph != glyph || oldDelegate.color != color;
}
