import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Quelyt's Layered-Folio & Citation-Anchor brand mark:
/// - A stepped back-page contour (secondary monochrome graphite/silver)
///   representing the local corpus of textbooks and papers;
/// - A crisp vertical book folio frame (primary obsidian/white ink)
///   representing the active original page;
/// - A solid swallowtail citation bookmark dropping from the top spine, paired
///   with a horizontal evidence line at the base ("every understanding anchored
///   to original evidence").
///
/// Rendered as pure vector geometry via [QuelytMarkPainter] so it adapts
/// automatically to light/dark themes, switches to the heavier optical variant
/// at small sizes (`<= 24 px`), and supports monochrome (error screens) and
/// watermark (empty states) modes without loading bitmaps.
class QuelytMark extends StatelessWidget {
  const QuelytMark({
    super.key,
    this.size = 28,
    this.semanticLabel = 'Quelyt',
    this.compact,
    this.monochrome = false,
    this.watermark = false,
    this.tile = false,
  });

  final double size;
  final String? semanticLabel;
  final bool? compact;
  final bool monochrome;
  final bool watermark;
  final bool tile;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final useCompact = compact ?? (size <= 24);
    final (Color inkColor, Color secondaryColor) = _resolveColors(c);
    final child = CustomPaint(
      size: Size.square(size),
      painter: QuelytMarkPainter(
        ink: inkColor,
        brand: secondaryColor,
        compact: useCompact,
        tile: tile,
        tileBackground: const Color(0xFF18181B),
        tileOutline: c.isDark ? const Color(0xFF3F3F46) : null,
      ),
    );
    if (semanticLabel == null) {
      return ExcludeSemantics(child: child);
    }
    return Semantics(
      image: true,
      label: semanticLabel,
      child: ExcludeSemantics(child: child),
    );
  }

  (Color, Color) _resolveColors(AppColors c) {
    if (tile) {
      return (
        Colors.white,
        monochrome ? Colors.white : const Color(0xFFA1A1AA),
      );
    }
    if (watermark) {
      return c.isDark
          ? (
              const Color(0xFF3F3F46),
              monochrome ? const Color(0xFF3F3F46) : const Color(0xFF27272A),
            )
          : (
              const Color(0xFFD4D4D8),
              monochrome ? const Color(0xFFD4D4D8) : const Color(0xFFE4E4E7),
            );
    }
    final ink = c.isDark ? Colors.white : c.ink;
    final secondary = monochrome ? ink : c.brand;
    return (ink, secondary);
  }
}

/// Primary brand lockup: the Layered-Folio & Citation-Anchor mark on the left,
/// followed by `Quelyt` in Manrope SemiBold converted to vector outlines.
class QuelytWordmark extends StatelessWidget {
  const QuelytWordmark({
    super.key,
    this.height = 38,
    this.semanticLabel = 'Quelyt',
    this.monochrome = false,
  });

  final double height;
  final String? semanticLabel;
  final bool monochrome;

  static const double _viewWidth = 760;
  static const double _viewHeight = 232;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final ink = c.isDark ? Colors.white : c.ink;
    final secondary = monochrome ? ink : c.brand;
    final text = c.ink;
    final width = height * (_viewWidth / _viewHeight);
    final compactMark = height <= 44;
    final child = CustomPaint(
      size: Size(width, height),
      painter: QuelytWordmarkPainter(
        ink: ink,
        brand: secondary,
        text: text,
        compactMark: compactMark,
      ),
    );
    if (semanticLabel == null) {
      return ExcludeSemantics(child: child);
    }
    return Semantics(
      image: true,
      label: semanticLabel,
      child: ExcludeSemantics(child: child),
    );
  }
}

class QuelytMarkPainter extends CustomPainter {
  const QuelytMarkPainter({
    required this.ink,
    required this.brand,
    this.compact = false,
    this.tile = false,
    this.tileBackground = const Color(0xFF18181B),
    this.tileOutline,
  });

  final Color ink;
  final Color brand;
  final bool compact;
  final bool tile;
  final Color tileBackground;
  final Color? tileOutline;

  static void paintMark(
    Canvas canvas, {
    required Color ink,
    required Color brand,
    required bool compact,
  }) {
    final backStrokeWidth = compact ? 42.0 : 38.0;
    final frontStrokeWidth = compact ? 50.0 : 46.0;

    final backPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = backStrokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = brand
      ..isAntiAlias = true;

    // 1. Concentric offset back-page contour (secondary monochrome tone)
    final backPage = Path()
      ..moveTo(164, 56)
      ..lineTo(394, 56)
      ..arcToPoint(
        const Offset(448, 110),
        radius: const Radius.circular(54),
        clockwise: true,
      )
      ..lineTo(448, 356);
    canvas.drawPath(backPage, backPaint);

    // 2. Front book folio frame (primary ink)
    final frontPage = RRect.fromLTRBR(
      76,
      108,
      392,
      448,
      const Radius.circular(54),
    );
    canvas.drawRRect(
      frontPage,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = frontStrokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = ink
        ..isAntiAlias = true,
    );

    // 3. Solid swallowtail citation bookmark dropping from top spine
    final bookmark = Path()
      ..moveTo(234, 108)
      ..lineTo(326, 108)
      ..lineTo(326, 282)
      ..lineTo(280, 244)
      ..lineTo(234, 282)
      ..close();
    canvas.drawPath(
      bookmark,
      Paint()
        ..style = PaintingStyle.fill
        ..color = ink
        ..isAntiAlias = true,
    );

    // 4. Bottom citation evidence bar (secondary monochrome tone)
    canvas.drawLine(
      const Offset(144, 366),
      const Offset(268, 366),
      backPaint,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.shortestSide / 512.0);
    if (tile) {
      final rect = RRect.fromRectAndRadius(
        const Rect.fromLTWH(0, 0, 512, 512),
        const Radius.circular(114),
      );
      canvas.drawRRect(
        rect,
        Paint()
          ..color = tileBackground
          ..isAntiAlias = true,
      );
      if (tileOutline != null) {
        final borderRect = RRect.fromRectAndRadius(
          const Rect.fromLTWH(4, 4, 504, 504),
          const Radius.circular(110),
        );
        canvas.drawRRect(
          borderRect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 8
            ..color = tileOutline!
            ..isAntiAlias = true,
        );
      }
      final s = compact ? 0.78 : 0.75;
      canvas.translate(256, 256);
      canvas.scale(s);
      canvas.translate(-256, -256);
    }
    paintMark(canvas, ink: ink, brand: brand, compact: compact);
    canvas.restore();
  }

  @override
  bool shouldRepaint(QuelytMarkPainter oldDelegate) =>
      oldDelegate.ink != ink ||
      oldDelegate.brand != brand ||
      oldDelegate.compact != compact ||
      oldDelegate.tile != tile ||
      oldDelegate.tileBackground != tileBackground ||
      oldDelegate.tileOutline != tileOutline;
}

class QuelytWordmarkPainter extends CustomPainter {
  const QuelytWordmarkPainter({
    required this.ink,
    required this.brand,
    required this.text,
    this.compactMark = false,
  });

  final Color ink;
  final Color brand;
  final Color text;
  final bool compactMark;

  static final Path _quelytPath = _buildManropeQuelytPath();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(
      size.width / QuelytWordmark._viewWidth,
      size.height / QuelytWordmark._viewHeight,
    );

    // Draw the Layered-Folio & Citation-Anchor emblem on the left
    canvas.save();
    canvas.translate(-8.0, 26.0);
    canvas.scale(0.35);
    QuelytMarkPainter.paintMark(
      canvas,
      ink: ink,
      brand: brand,
      compact: compactMark,
    );
    canvas.restore();

    // Draw full "Quelyt" in Manrope SemiBold vector outlines on the right
    canvas.save();
    canvas.translate(-16.0, -422.02);
    canvas.scale(2.3421);
    canvas.drawPath(
      _quelytPath,
      Paint()
        ..style = PaintingStyle.fill
        ..color = text
        ..isAntiAlias = true,
    );
    canvas.restore();

    canvas.restore();
  }

  @override
  bool shouldRepaint(QuelytWordmarkPainter oldDelegate) =>
      oldDelegate.ink != ink ||
      oldDelegate.brand != brand ||
      oldDelegate.text != text ||
      oldDelegate.compactMark != compactMark;
}

Path _buildManropeQuelytPath() {
  return Path()
    // Capital 'Q'
    ..moveTo(136.33, 257.11)
    ..lineTo(121.05, 241.91)
    ..lineTo(126.14, 236.82)
    ..lineTo(141.34, 252.02)
    ..close()
    ..moveTo(116.26, 257.14)
    ..quadraticBezierTo(108.07, 257.14, 102.29, 253.54)
    ..quadraticBezierTo(96.5, 249.95, 93.45, 243.52)
    ..quadraticBezierTo(90.4, 237.1, 90.4, 228.64)
    ..quadraticBezierTo(90.4, 220.18, 93.45, 213.76)
    ..quadraticBezierTo(96.5, 207.33, 102.29, 203.74)
    ..quadraticBezierTo(108.07, 200.14, 116.26, 200.14)
    ..quadraticBezierTo(124.46, 200.14, 130.24, 203.74)
    ..quadraticBezierTo(136.02, 207.33, 139.08, 213.76)
    ..quadraticBezierTo(142.13, 220.18, 142.13, 228.64)
    ..quadraticBezierTo(142.13, 237.1, 139.08, 243.52)
    ..quadraticBezierTo(136.02, 249.95, 130.24, 253.54)
    ..quadraticBezierTo(124.46, 257.14, 120.36, 257.14)
    ..close()
    ..moveTo(116.26, 249.59)
    ..quadraticBezierTo(122.08, 249.64, 125.95, 247.01)
    ..quadraticBezierTo(129.82, 244.38, 131.76, 239.65)
    ..quadraticBezierTo(133.69, 234.91, 133.69, 228.64)
    ..quadraticBezierTo(133.69, 222.37, 131.76, 217.68)
    ..quadraticBezierTo(129.82, 212.98, 125.95, 210.36)
    ..quadraticBezierTo(122.08, 207.74, 116.26, 207.69)
    ..quadraticBezierTo(110.45, 207.64, 106.59, 210.26)
    ..quadraticBezierTo(102.74, 212.88, 100.8, 217.63)
    ..quadraticBezierTo(98.86, 222.37, 98.83, 228.64)
    ..quadraticBezierTo(98.81, 234.91, 100.75, 239.6)
    ..quadraticBezierTo(102.69, 244.28, 106.57, 246.91)
    ..quadraticBezierTo(110.45, 249.54, 113.36, 249.57)
    ..close()
    // 'u'
    ..moveTo(165.51, 257.11)
    ..quadraticBezierTo(161.25, 257.11, 158.36, 255.73)
    ..quadraticBezierTo(155.46, 254.35, 153.66, 252.13)
    ..quadraticBezierTo(151.85, 249.91, 150.9, 247.3)
    ..quadraticBezierTo(149.95, 244.69, 149.61, 242.17)
    ..quadraticBezierTo(149.27, 239.66, 149.27, 237.76)
    ..lineTo(149.27, 214.96)
    ..lineTo(157.33, 214.96)
    ..lineTo(157.33, 235.13)
    ..quadraticBezierTo(157.33, 237.52, 157.72, 240.05)
    ..quadraticBezierTo(158.12, 242.59, 159.24, 244.76)
    ..quadraticBezierTo(160.35, 246.93, 162.39, 248.26)
    ..quadraticBezierTo(164.42, 249.59, 167.69, 249.59)
    ..quadraticBezierTo(169.83, 249.59, 171.72, 248.88)
    ..quadraticBezierTo(173.61, 248.16, 175.05, 246.6)
    ..quadraticBezierTo(176.48, 245.04, 177.3, 242.5)
    ..quadraticBezierTo(178.12, 239.95, 178.12, 236.32)
    ..lineTo(183.06, 238.17)
    ..quadraticBezierTo(183.06, 243.75, 180.97, 248.03)
    ..quadraticBezierTo(178.88, 252.3, 174.96, 254.71)
    ..quadraticBezierTo(171.04, 257.11, 168.28, 257.11)
    ..close()
    ..moveTo(179.06, 256)
    ..lineTo(179.06, 244.14)
    ..lineTo(178.12, 244.14)
    ..lineTo(178.12, 214.96)
    ..lineTo(186.13, 214.96)
    ..lineTo(186.13, 256)
    ..close()
    // 'e'
    ..moveTo(215.28, 257.14)
    ..quadraticBezierTo(209.14, 257.14, 204.54, 254.45)
    ..quadraticBezierTo(199.93, 251.77, 197.36, 246.97)
    ..quadraticBezierTo(194.79, 242.17, 194.79, 235.83)
    ..quadraticBezierTo(194.79, 229.11, 197.32, 224.17)
    ..quadraticBezierTo(199.84, 219.23, 204.36, 216.52)
    ..quadraticBezierTo(208.87, 213.82, 214.88, 213.82)
    ..quadraticBezierTo(221.15, 213.82, 225.56, 216.73)
    ..quadraticBezierTo(229.96, 219.65, 232.15, 225)
    ..quadraticBezierTo(234.33, 230.36, 233.9, 237.71)
    ..lineTo(225.95, 237.71)
    ..lineTo(225.95, 234.82)
    ..quadraticBezierTo(225.87, 227.69, 223.23, 224.28)
    ..quadraticBezierTo(220.59, 220.86, 215.18, 220.86)
    ..quadraticBezierTo(209.23, 220.86, 206.23, 224.62)
    ..quadraticBezierTo(203.23, 228.37, 203.23, 235.48)
    ..quadraticBezierTo(203.23, 242.23, 206.23, 245.94)
    ..quadraticBezierTo(209.23, 249.64, 214.88, 249.64)
    ..quadraticBezierTo(218.6, 249.64, 221.33, 247.96)
    ..quadraticBezierTo(224.05, 246.27, 225.57, 243.11)
    ..lineTo(233.35, 245.59)
    ..quadraticBezierTo(230.97, 251.09, 226.1, 254.11)
    ..quadraticBezierTo(221.24, 257.14, 218.26, 257.14)
    ..close()
    ..moveTo(200.64, 237.71)
    ..lineTo(200.64, 231.53)
    ..lineTo(229.93, 231.53)
    ..lineTo(229.93, 237.71)
    ..close()
    // 'l'
    ..moveTo(243.45, 256)
    ..lineTo(243.45, 200.14)
    ..lineTo(251.41, 200.14)
    ..lineTo(251.41, 256)
    ..close()
    // 'y'
    ..moveTo(268.65, 274.24)
    ..lineTo(276.58, 252.61)
    ..lineTo(276.71, 258.99)
    ..lineTo(258.8, 214.96)
    ..lineTo(267.11, 214.96)
    ..lineTo(280.48, 248.96)
    ..lineTo(278.05, 248.96)
    ..lineTo(290.82, 214.96)
    ..lineTo(298.85, 214.96)
    ..lineTo(276.23, 274.24)
    ..close()
    // 't'
    ..moveTo(328.59, 256)
    ..quadraticBezierTo(324.72, 256.76, 321, 256.64)
    ..quadraticBezierTo(317.28, 256.52, 314.35, 255.2)
    ..quadraticBezierTo(311.42, 253.87, 309.92, 251.01)
    ..quadraticBezierTo(308.6, 248.46, 308.51, 245.84)
    ..quadraticBezierTo(308.42, 243.21, 308.42, 239.86)
    ..lineTo(308.42, 203.56)
    ..lineTo(316.38, 203.56)
    ..lineTo(316.38, 239.46)
    ..quadraticBezierTo(316.38, 241.94, 316.43, 243.76)
    ..quadraticBezierTo(316.49, 245.59, 317.21, 246.83)
    ..quadraticBezierTo(318.58, 249.19, 321.57, 249.52)
    ..quadraticBezierTo(324.56, 249.86, 328.59, 249.26)
    ..close()
    ..moveTo(300.54, 221.34)
    ..lineTo(300.54, 214.96)
    ..lineTo(328.59, 214.96)
    ..lineTo(328.59, 221.34)
    ..close();
}
