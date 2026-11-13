import 'package:flutter/widgets.dart';

/// How a [QShape] is filled.
enum QFill {
  /// Stroke only (the default for the Folio Line icon family).
  none,

  /// Always filled, e.g. status dots and the solid citation bookmark.
  solid,

  /// Filled only when the icon is rendered in its active (selected) weight.
  /// Used for the signature part of an icon, mostly the swallowtail bookmark.
  active,
}

/// One geometric primitive on the 24 x 24 Folio Line grid.
///
/// Primitives are `const` so whole icon definitions can be compile-time
/// constants and keep the `const Icon(...)` ergonomics at call sites.
@immutable
sealed class QShape {
  const QShape({this.fill = QFill.none});

  final QFill fill;

  static final Expando<Path> _cache = Expando<Path>('QShape.path');

  /// The resolved path in 24-unit grid coordinates (cached per instance).
  Path get path => _cache[this] ??= _build();

  Path _build();
}

/// An SVG path (`d` attribute) on the 24-unit grid.
final class QPath extends QShape {
  const QPath(this.d, {super.fill});

  final String d;

  @override
  Path _build() => parseSvgPathData(d);
}

/// A circle on the 24-unit grid.
final class QCircle extends QShape {
  const QCircle(this.cx, this.cy, this.r, {super.fill});

  final double cx;
  final double cy;
  final double r;

  @override
  Path _build() =>
      Path()..addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r));
}

/// A (rounded) rectangle on the 24-unit grid.
final class QRect extends QShape {
  const QRect(this.x, this.y, this.w, this.h, {this.r = 0, super.fill});

  final double x;
  final double y;
  final double w;
  final double h;
  final double r;

  @override
  Path _build() => Path()
    ..addRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(x, y, w, h), Radius.circular(r)),
    );
}

/// A straight segment on the 24-unit grid.
final class QLine extends QShape {
  const QLine(this.x1, this.y1, this.x2, this.y2) : super();

  final double x1;
  final double y1;
  final double x2;
  final double y2;

  @override
  Path _build() => Path()
    ..moveTo(x1, y1)
    ..lineTo(x2, y2);
}

/// A Folio Line icon: a named list of primitives on a 24 x 24 grid.
///
/// Drawing rules: 2-unit padding around a 20 x 20 live area, round caps and
/// joins, 2.5-unit outer radii, and a swallowtail bookmark as the signature
/// part that fills in the active weight.
@immutable
class QIconData {
  const QIconData(this.name, this.shapes);

  /// Stable identifier, used by the icon contact sheet and tests.
  final String name;
  final List<QShape> shapes;

  /// Whether this icon has a distinct active (selected) weight.
  bool get hasActiveWeight => shapes.any((s) => s.fill == QFill.active);

  @override
  String toString() => 'QIconData($name)';
}

/// Fixed icon sizes. Arbitrary sizes such as 15, 17 or 19 px are not used.
abstract final class IconSizes {
  /// Inline with body copy, table rows, chips and dense lists.
  static const double sm = 16;

  /// Default: toolbars, icon buttons, sidebar navigation and tabs.
  static const double md = 20;

  /// Mobile navigation and dialog titles.
  static const double lg = 24;

  /// Empty-state illustrations.
  static const double xl = 40;
}

/// Renders a [QIconData] using the ambient [IconTheme], mirroring [Icon].
///
/// The stroke is optically corrected: it stays close to 1.5 logical pixels
/// at every size rather than thinning out at 16 px and bloating at 40 px.
class QIcon extends StatelessWidget {
  const QIcon(
    this.icon, {
    super.key,
    this.size,
    this.color,
    this.semanticLabel,
    this.active = false,
  });

  final QIconData? icon;
  final double? size;
  final Color? color;
  final String? semanticLabel;

  /// Render the active weight (signature part filled), e.g. selected nav.
  final bool active;

  /// Logical stroke width for a rendered icon size.
  static double strokeFor(double size) =>
      (0.9 + size * 0.03).clamp(1.25, 2.0).toDouble();

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final resolvedSize = size ?? theme.size ?? IconSizes.lg;
    var resolvedColor = color ?? theme.color ?? const Color(0xFF000000);
    final opacity = theme.opacity ?? 1.0;
    if (opacity != 1.0) {
      resolvedColor = resolvedColor.withValues(alpha: resolvedColor.a * opacity);
    }
    Widget child = SizedBox.square(dimension: resolvedSize);
    final data = icon;
    if (data != null) {
      child = CustomPaint(
        size: Size.square(resolvedSize),
        painter: QIconPainter(
          icon: data,
          color: resolvedColor,
          active: active,
          strokeWidth: strokeFor(resolvedSize),
        ),
      );
    }
    if (semanticLabel == null) {
      return ExcludeSemantics(child: child);
    }
    return Semantics(label: semanticLabel, child: ExcludeSemantics(child: child));
  }
}

class QIconPainter extends CustomPainter {
  const QIconPainter({
    required this.icon,
    required this.color,
    required this.strokeWidth,
    this.active = false,
  });

  final QIconData icon;
  final Color color;
  final double strokeWidth;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 24.0;
    canvas.save();
    canvas.translate(
      (size.width - 24.0 * scale) / 2,
      (size.height - 24.0 * scale) / 2,
    );
    canvas.scale(scale);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth / scale
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color
      ..isAntiAlias = true;
    final fill = Paint()
      ..style = PaintingStyle.fill
      ..color = color
      ..isAntiAlias = true;
    for (final shape in icon.shapes) {
      final path = shape.path;
      if (shape.fill == QFill.solid ||
          (shape.fill == QFill.active && active)) {
        canvas.drawPath(path, fill);
      }
      canvas.drawPath(path, stroke);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(QIconPainter oldDelegate) =>
      oldDelegate.icon != icon ||
      oldDelegate.color != color ||
      oldDelegate.strokeWidth != strokeWidth ||
      oldDelegate.active != active;
}

final RegExp _svgToken = RegExp(
  r'[MmLlHhVvCcSsQqTtAaZz]|[-+]?(?:\d*\.\d+|\d+\.?)(?:[eE][-+]?\d+)?',
);

/// Parses the subset of SVG path data used by the icon set
/// (M, L, H, V, C, S, Q, T, A, Z in absolute and relative forms).
Path parseSvgPathData(String d) {
  final tokens = _svgToken.allMatches(d).map((m) => m.group(0)!).toList();
  final path = Path();
  var i = 0;
  var cmd = '';
  var x = 0.0, y = 0.0; // current point
  var sx = 0.0, sy = 0.0; // subpath start
  double? cx2, cy2; // last cubic control point
  double? qx, qy; // last quadratic control point

  bool isCommand(String t) => RegExp(r'^[A-Za-z]$').hasMatch(t);
  double next() => double.parse(tokens[i++]);

  while (i < tokens.length) {
    if (isCommand(tokens[i])) {
      cmd = tokens[i++];
    } else if (cmd.isEmpty) {
      throw FormatException('Path data must start with a command', d);
    }
    final rel = cmd == cmd.toLowerCase();
    final ox = rel ? x : 0.0, oy = rel ? y : 0.0;
    var keepCubic = false, keepQuad = false;
    switch (cmd.toUpperCase()) {
      case 'M':
        x = ox + next();
        y = oy + next();
        path.moveTo(x, y);
        sx = x;
        sy = y;
        // Subsequent pairs are implicit line-to commands.
        cmd = rel ? 'l' : 'L';
      case 'L':
        x = ox + next();
        y = oy + next();
        path.lineTo(x, y);
      case 'H':
        x = ox + next();
        path.lineTo(x, y);
      case 'V':
        y = oy + next();
        path.lineTo(x, y);
      case 'C':
        final x1 = ox + next(), y1 = oy + next();
        final x2 = ox + next(), y2 = oy + next();
        x = ox + next();
        y = oy + next();
        path.cubicTo(x1, y1, x2, y2, x, y);
        cx2 = x2;
        cy2 = y2;
        keepCubic = true;
      case 'S':
        final x1 = cx2 != null ? 2 * x - cx2 : x;
        final y1 = cy2 != null ? 2 * y - cy2 : y;
        final x2 = ox + next(), y2 = oy + next();
        x = ox + next();
        y = oy + next();
        path.cubicTo(x1, y1, x2, y2, x, y);
        cx2 = x2;
        cy2 = y2;
        keepCubic = true;
      case 'Q':
        final x1 = ox + next(), y1 = oy + next();
        x = ox + next();
        y = oy + next();
        path.quadraticBezierTo(x1, y1, x, y);
        qx = x1;
        qy = y1;
        keepQuad = true;
      case 'T':
        final x1 = qx != null ? 2 * x - qx : x;
        final y1 = qy != null ? 2 * y - qy : y;
        x = ox + next();
        y = oy + next();
        path.quadraticBezierTo(x1, y1, x, y);
        qx = x1;
        qy = y1;
        keepQuad = true;
      case 'A':
        final rx = next(), ry = next(), rotation = next();
        final largeArc = next() != 0, sweep = next() != 0;
        x = ox + next();
        y = oy + next();
        path.arcToPoint(
          Offset(x, y),
          radius: Radius.elliptical(rx, ry),
          rotation: rotation,
          largeArc: largeArc,
          clockwise: sweep,
        );
      case 'Z':
        path.close();
        x = sx;
        y = sy;
        // Z takes no arguments; a stray number afterwards is malformed.
        cmd = '';
      default:
        throw FormatException('Unsupported path command $cmd', d);
    }
    if (!keepCubic) {
      cx2 = null;
      cy2 = null;
    }
    if (!keepQuad) {
      qx = null;
      qy = null;
    }
  }
  return path;
}
