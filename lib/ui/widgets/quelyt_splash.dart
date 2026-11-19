import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../shell/app_chrome.dart';
import '../shell/window_title_bar.dart';
import '../theme/tokens.dart';

/// A pure, lively icon-only startup animation (~860ms) shared by Windows and
/// Android.
///
/// Choreography (zero text, pure geometric motion):
/// 1. Spring Lift & Folio Draw (0–340ms): The obsidian squircle tile springs up
///    with a gentle tilt (`-4.5° -> 0°`) while the front book folio traces its
///    rounded perimeter.
/// 2. Page Fan-Out & Ribbon Drop (140–560ms): The stepped back-page fans out
///    from behind the front page with an elastic arc; the swallowtail citation
///    bookmark drops from the top spine with ribbon overshoot and a subtle
///    ripple ring as the bottom evidence stroke glides across.
/// 3. Diagonal Sheen & Dissolve (560–860ms): A soft specular sheen sweeps
///    across the tile before the mark floats into the live workspace.
class QuelytSplashOverlay extends StatefulWidget {
  const QuelytSplashOverlay({
    super.key,
    required this.child,
    this.enabled = true,
    this.showWindowChrome = false,
  });

  final Widget child;
  final bool enabled;
  final bool showWindowChrome;

  @override
  State<QuelytSplashOverlay> createState() => _QuelytSplashOverlayState();
}

class _QuelytSplashOverlayState extends State<QuelytSplashOverlay>
    with SingleTickerProviderStateMixin {
  static const _totalDuration = Duration(milliseconds: 860);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _totalDuration,
  );
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    if (!widget.enabled) {
      _dismissed = true;
      return;
    }
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) {
        setState(() => _dismissed = true);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _dismissed) return;
      if (context.reduceMotion) {
        setState(() => _dismissed = true);
        return;
      }
      unawaited(_controller.forward());
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _skipToReveal() {
    if (_dismissed || !_controller.isAnimating) return;
    if (_controller.value < 0.70) {
      unawaited(
        _controller.animateTo(
          1.0,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_dismissed || !widget.enabled) {
      return widget.child;
    }
    final c = context.colors;
    final hasDesktopChrome =
        widget.showWindowChrome && AppChrome.isDesktopWindowChromeSupported;

    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final t = _controller.value;
            final exitProgress = const Interval(
              0.70,
              1.0,
              curve: Curves.easeInOutCubic,
            ).transform(t);
            final overlayOpacity = (1.0 - exitProgress).clamp(0.0, 1.0);
            if (overlayOpacity <= 0.001) {
              return const SizedBox.shrink();
            }

            // Agile spring entry + bookmark landing micro-recoil + float exit
            final entrySpring = const Interval(
              0.0,
              0.42,
              curve: Curves.easeOutBack,
            ).transform(t);
            final snapBump = math.sin(
              const Interval(
                    0.34,
                    0.58,
                    curve: Curves.easeInOutSine,
                  ).transform(t) *
                  math.pi,
            );
            final tileScale =
                (0.72 + 0.28 * entrySpring) +
                (snapBump * 0.032) +
                (exitProgress * 0.05);

            final tiltProgress = const Interval(
              0.0,
              0.46,
              curve: Curves.easeOutBack,
            ).transform(t);
            final tileAngle = (1.0 - tiltProgress) * -0.085;

            final liftProgress = const Interval(
              0.0,
              0.40,
              curve: Curves.easeOutCubic,
            ).transform(t);
            final tileOffsetY =
                (1.0 - liftProgress) * 16.0 -
                (snapBump * 2.5) -
                (exitProgress * 6.0);

            final tileOpacity = const Interval(
              0.0,
              0.16,
              curve: Curves.easeOut,
            ).transform(t);

            // Outer ripple ring triggered when the bookmark snaps in
            final rippleProgress = const Interval(
              0.24,
              0.68,
              curve: Curves.easeOutQuart,
            ).transform(t);
            final rippleScale = 0.86 + rippleProgress * 0.52;
            final rippleAlpha =
                (1.0 - rippleProgress) * (c.isDark ? 0.26 : 0.14);

            // Inner vector layer timings
            final folioProgress = const Interval(
              0.04,
              0.42,
              curve: Curves.easeOutQuart,
            ).transform(t);
            final backPageProgress = const Interval(
              0.14,
              0.52,
              curve: Curves.easeOutBack,
            ).transform(t);
            final bookmarkProgress = const Interval(
              0.20,
              0.58,
              curve: Curves.easeOutBack,
            ).transform(t);
            final barProgress = const Interval(
              0.32,
              0.64,
              curve: Curves.easeOutCubic,
            ).transform(t);
            final sheenProgress = const Interval(
              0.30,
              0.74,
              curve: Curves.easeInOutCubic,
            ).transform(t);

            return IgnorePointer(
              ignoring: t >= 0.66,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _skipToReveal,
                child: Opacity(
                  opacity: overlayOpacity,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: c.canvas,
                      gradient: RadialGradient(
                        center: Alignment.center,
                        radius: 0.75,
                        colors: [
                          c.isDark
                              ? const Color(0xFF1C1C21)
                              : const Color(0xFFF5F5F7),
                          c.canvas,
                        ],
                      ),
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Center(
                          child: SizedBox(
                            width: 140,
                            height: 140,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                if (rippleAlpha > 0.005)
                                  Transform.scale(
                                    scale: rippleScale,
                                    child: Container(
                                      width: 92,
                                      height: 92,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(24),
                                        border: Border.all(
                                          color: c.ink.withValues(
                                            alpha: rippleAlpha,
                                          ),
                                          width: 1.4,
                                        ),
                                      ),
                                    ),
                                  ),
                                Opacity(
                                  opacity: tileOpacity,
                                  child: Transform.translate(
                                    offset: Offset(0, tileOffsetY),
                                    child: Transform.rotate(
                                      angle: tileAngle,
                                      child: Transform.scale(
                                        scale: tileScale,
                                        child: Container(
                                          width: 92,
                                          height: 92,
                                          decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(
                                              21,
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: Colors.black.withValues(
                                                  alpha: c.isDark ? 0.48 : 0.16,
                                                ),
                                                blurRadius: 28,
                                                offset: const Offset(0, 12),
                                              ),
                                              BoxShadow(
                                                color: Colors.black.withValues(
                                                  alpha: c.isDark ? 0.24 : 0.06,
                                                ),
                                                blurRadius: 6,
                                                offset: const Offset(0, 2),
                                              ),
                                            ],
                                          ),
                                          child: CustomPaint(
                                            size: const Size.square(92),
                                            painter: _AnimatedQuelytMarkPainter(
                                              folioProgress: folioProgress,
                                              backPageProgress:
                                                  backPageProgress,
                                              bookmarkProgress:
                                                  bookmarkProgress,
                                              barProgress: barProgress,
                                              sheenProgress: sheenProgress,
                                              isDark: c.isDark,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (hasDesktopChrome && Platform.isWindows)
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            height: AppChrome.titleBarHeight,
                            child: Row(
                              children: const [
                                Expanded(
                                  child: WindowDragRegion(
                                    child: SizedBox.expand(),
                                  ),
                                ),
                                WindowCaptionControls(),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _AnimatedQuelytMarkPainter extends CustomPainter {
  const _AnimatedQuelytMarkPainter({
    required this.folioProgress,
    required this.backPageProgress,
    required this.bookmarkProgress,
    required this.barProgress,
    required this.sheenProgress,
    required this.isDark,
  });

  final double folioProgress;
  final double backPageProgress;
  final double bookmarkProgress;
  final double barProgress;
  final double sheenProgress;
  final bool isDark;

  static void _drawPartialPath(Canvas canvas, Path path, Paint paint, double t) {
    final clamped = t.clamp(0.0, 1.0);
    if (clamped <= 0.0) return;
    if (clamped >= 0.999) {
      canvas.drawPath(path, paint);
      return;
    }
    for (final metric in path.computeMetrics()) {
      final extract = metric.extractPath(0, metric.length * clamped);
      canvas.drawPath(extract, paint);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.shortestSide / 512.0);

    // 0. Rounded obsidian squircle tile
    final tileRect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(0, 0, 512, 512),
      const Radius.circular(114),
    );
    canvas.drawRRect(
      tileRect,
      Paint()
        ..color = const Color(0xFF18181B)
        ..isAntiAlias = true,
    );

    canvas.save();
    canvas.clipRRect(tileRect);

    // Inner scale for mark geometry
    canvas.save();
    canvas.translate(256, 256);
    canvas.scale(0.75);
    canvas.translate(-256, -256);

    final backPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 38.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = const Color(0xFFA1A1AA)
      ..isAntiAlias = true;

    final frontPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 46.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = Colors.white
      ..isAntiAlias = true;

    // 1. Stepped back-page contour fanning out with spring rotation & offset
    if (backPageProgress > 0.0) {
      canvas.save();
      final delta = 1.0 - backPageProgress;
      canvas.translate(164, 356);
      canvas.rotate(-delta * 0.11);
      canvas.translate(-164 - delta * 26.0, -356 + delta * 26.0);
      final backPage = Path()
        ..moveTo(164, 56)
        ..lineTo(394, 56)
        ..arcToPoint(
          const Offset(448, 110),
          radius: const Radius.circular(54),
          clockwise: true,
        )
        ..lineTo(448, 356);
      _drawPartialPath(
        canvas,
        backPage,
        backPaint,
        backPageProgress.clamp(0.0, 1.0),
      );
      canvas.restore();
    }

    // 2. Front book folio frame tracing smoothly from top spine
    if (folioProgress > 0.0) {
      canvas.save();
      final folioScale = 0.92 + 0.08 * folioProgress.clamp(0.0, 1.0);
      canvas.translate(234, 278);
      canvas.scale(folioScale);
      canvas.translate(-234, -278);
      final frontRRect = RRect.fromLTRBR(
        76,
        108,
        392,
        448,
        const Radius.circular(54),
      );
      final frontPath = Path()..addRRect(frontRRect);
      _drawPartialPath(canvas, frontPath, frontPaint, folioProgress);
      canvas.restore();
    }

    // 3. Swallowtail citation bookmark dropping with ribbon stretch & snap
    if (bookmarkProgress > 0.0) {
      final drop = bookmarkProgress.clamp(0.0, 1.14);
      final bottomY = 108.0 + (282.0 - 108.0) * drop;
      // Notch lags slightly then snaps up for a lively ribbon feel
      final notchFactor = math.pow(drop.clamp(0.0, 1.0), 1.15).toDouble();
      final notchY = 108.0 + (244.0 - 108.0) * notchFactor;
      final bookmark = Path()
        ..moveTo(234, 108)
        ..lineTo(326, 108)
        ..lineTo(326, bottomY)
        ..lineTo(280, notchY)
        ..lineTo(234, bottomY)
        ..close();
      canvas.drawPath(
        bookmark,
        Paint()
          ..style = PaintingStyle.fill
          ..color = Colors.white
          ..isAntiAlias = true,
      );
    }

    // 4. Bottom citation evidence bar gliding across
    if (barProgress > 0.0) {
      final clampedBar = barProgress.clamp(0.0, 1.0);
      final endX = 144.0 + (268.0 - 144.0) * clampedBar;
      canvas.drawLine(const Offset(144, 366), Offset(endX, 366), backPaint);
    }

    canvas.restore();

    // 5. Subtle diagonal specular sheen sweeping across the tile
    if (sheenProgress > 0.0 && sheenProgress < 1.0) {
      final sheenCenter = -260.0 + sheenProgress * 1040.0;
      final sheenRect = const Rect.fromLTWH(0, 0, 512, 512);
      final sheenPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.0),
            Colors.white.withValues(alpha: 0.09),
            Colors.white.withValues(alpha: 0.0),
          ],
          stops: const [0.35, 0.50, 0.65],
          transform: _SlideGradientTransform(Offset(sheenCenter - 256, 0)),
        ).createShader(sheenRect);
      canvas.drawRect(sheenRect, sheenPaint);
    }

    canvas.restore();

    // Outer subtle rim border
    final borderRect = RRect.fromRectAndRadius(
      const Rect.fromLTWH(4, 4, 504, 504),
      const Radius.circular(110),
    );
    canvas.drawRRect(
      borderRect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..color = isDark ? const Color(0xFF3F3F46) : const Color(0xFF27272A)
        ..isAntiAlias = true,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(_AnimatedQuelytMarkPainter oldDelegate) =>
      oldDelegate.folioProgress != folioProgress ||
      oldDelegate.backPageProgress != backPageProgress ||
      oldDelegate.bookmarkProgress != bookmarkProgress ||
      oldDelegate.barProgress != barProgress ||
      oldDelegate.sheenProgress != sheenProgress ||
      oldDelegate.isDark != isDark;
}

class _SlideGradientTransform extends GradientTransform {
  const _SlideGradientTransform(this.offset);

  final Offset offset;

  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(offset.dx, offset.dy, 0.0);
}
