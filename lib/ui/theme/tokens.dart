import 'package:flutter/material.dart';

/// Design tokens for Quelyt.
///
/// The interface follows a white, paper-like neutral system in the spirit of
/// Zotero: near-white chrome, white cards, hairline grey borders, charcoal
/// actions and a single red brand accent. Accent hues are reserved for small
/// icon chips and state, never for large surfaces.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.canvas,
    required this.surface,
    required this.surfaceRaised,
    required this.sidebar,
    required this.tint,
    required this.outline,
    required this.outlineStrong,
    required this.ink,
    required this.inkMuted,
    required this.primary,
    required this.onPrimary,
    required this.brand,
    required this.blue,
    required this.blueTint,
    required this.green,
    required this.greenTint,
    required this.violet,
    required this.violetTint,
    required this.warm,
    required this.warmTint,
    required this.danger,
    required this.dangerTint,
    required this.pageStage,
  });

  /// Application background.
  final Color canvas;

  /// Cards, top bar and panel base.
  final Color surface;

  /// Inputs, popovers, dialogs.
  final Color surfaceRaised;

  /// Navigation sidebar.
  final Color sidebar;

  /// Banners, selected fills, badge backgrounds.
  final Color tint;

  /// Hairline borders and dividers.
  final Color outline;

  /// Interactive outlines (inputs and secondary buttons).
  final Color outlineStrong;

  /// Body copy and headings.
  final Color ink;

  /// Secondary copy. Both palettes keep this at WCAG AA (>= 4.5:1).
  final Color inkMuted;

  /// Actions, selection, links and focus. Charcoal rather than a brand hue so
  /// the interface stays quiet; red is reserved for brand and danger.
  final Color primary;

  /// Copy on primary.
  final Color onPrimary;

  /// Secondary monochrome brand tone (graphite in light mode, silver-zinc in
  /// dark mode) used for the layered folio & citation anchor mark.
  final Color brand;

  /// Reading, textbooks and the current document.
  final Color blue;

  /// Reading accent surface.
  final Color blueTint;

  /// Recall, completed work and healthy status.
  final Color green;

  /// Recall accent surface.
  final Color greenTint;

  /// Questions, AI surfaces and the settings section.
  final Color violet;

  /// Question/AI accent surface.
  final Color violetTint;

  /// Paper documents, notes and warnings.
  final Color warm;

  /// Warm callout background.
  final Color warmTint;

  /// Destructive actions and errors.
  final Color danger;

  /// Error callout background.
  final Color dangerTint;

  /// Reader backdrop, slightly deeper than [canvas] so the page floats.
  final Color pageStage;

  static const light = AppColors(
    canvas: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFF4F4F5),
    sidebar: Color(0xFFF9F9F9),
    tint: Color(0xFFECECEE),
    outline: Color(0xFFEAEAEA),
    outlineStrong: Color(0xFFD4D4D8),
    ink: Color(0xFF0D0D0D),
    inkMuted: Color(0xFF65656D),
    primary: Color(0xFF171717),
    onPrimary: Color(0xFFFFFFFF),
    brand: Color(0xFF52525B),
    blue: Color(0xFF52525B),
    blueTint: Color(0xFFF4F4F5),
    green: Color(0xFF52525B),
    greenTint: Color(0xFFF4F4F5),
    violet: Color(0xFF52525B),
    violetTint: Color(0xFFF4F4F5),
    warm: Color(0xFF52525B),
    warmTint: Color(0xFFF4F4F5),
    danger: Color(0xFFC81E1E),
    dangerTint: Color(0xFFFEF2F2),
    pageStage: Color(0xFFF0F0F2),
  );

  static const dark = AppColors(
    canvas: Color(0xFF121212),
    surface: Color(0xFF121212),
    surfaceRaised: Color(0xFF1A1A1A),
    sidebar: Color(0xFF171717),
    tint: Color(0xFF262626),
    outline: Color(0xFF262626),
    outlineStrong: Color(0xFF3F3F46),
    ink: Color(0xFFECECEC),
    inkMuted: Color(0xFFA1A1AA),
    primary: Color(0xFFECECEC),
    onPrimary: Color(0xFF121212),
    brand: Color(0xFFA1A1AA),
    blue: Color(0xFFA1A1AA),
    blueTint: Color(0xFF1E1E1E),
    green: Color(0xFFA1A1AA),
    greenTint: Color(0xFF1E1E1E),
    violet: Color(0xFFA1A1AA),
    violetTint: Color(0xFF1E1E1E),
    warm: Color(0xFFA1A1AA),
    warmTint: Color(0xFF1E1E1E),
    danger: Color(0xFFF87171),
    dangerTint: Color(0xFF2A1515),
    pageStage: Color(0xFF0A0A0A),
  );

  bool get isDark => canvas.computeLuminance() < .2;

  @override
  AppColors copyWith({
    Color? canvas,
    Color? surface,
    Color? surfaceRaised,
    Color? sidebar,
    Color? tint,
    Color? outline,
    Color? outlineStrong,
    Color? ink,
    Color? inkMuted,
    Color? primary,
    Color? onPrimary,
    Color? brand,
    Color? blue,
    Color? blueTint,
    Color? green,
    Color? greenTint,
    Color? violet,
    Color? violetTint,
    Color? warm,
    Color? warmTint,
    Color? danger,
    Color? dangerTint,
    Color? pageStage,
  }) => AppColors(
    canvas: canvas ?? this.canvas,
    surface: surface ?? this.surface,
    surfaceRaised: surfaceRaised ?? this.surfaceRaised,
    sidebar: sidebar ?? this.sidebar,
    tint: tint ?? this.tint,
    outline: outline ?? this.outline,
    outlineStrong: outlineStrong ?? this.outlineStrong,
    ink: ink ?? this.ink,
    inkMuted: inkMuted ?? this.inkMuted,
    primary: primary ?? this.primary,
    onPrimary: onPrimary ?? this.onPrimary,
    brand: brand ?? this.brand,
    blue: blue ?? this.blue,
    blueTint: blueTint ?? this.blueTint,
    green: green ?? this.green,
    greenTint: greenTint ?? this.greenTint,
    violet: violet ?? this.violet,
    violetTint: violetTint ?? this.violetTint,
    warm: warm ?? this.warm,
    warmTint: warmTint ?? this.warmTint,
    danger: danger ?? this.danger,
    dangerTint: dangerTint ?? this.dangerTint,
    pageStage: pageStage ?? this.pageStage,
  );

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    return AppColors(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t)!,
      sidebar: Color.lerp(sidebar, other.sidebar, t)!,
      tint: Color.lerp(tint, other.tint, t)!,
      outline: Color.lerp(outline, other.outline, t)!,
      outlineStrong: Color.lerp(outlineStrong, other.outlineStrong, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      inkMuted: Color.lerp(inkMuted, other.inkMuted, t)!,
      primary: Color.lerp(primary, other.primary, t)!,
      onPrimary: Color.lerp(onPrimary, other.onPrimary, t)!,
      brand: Color.lerp(brand, other.brand, t)!,
      blue: Color.lerp(blue, other.blue, t)!,
      blueTint: Color.lerp(blueTint, other.blueTint, t)!,
      green: Color.lerp(green, other.green, t)!,
      greenTint: Color.lerp(greenTint, other.greenTint, t)!,
      violet: Color.lerp(violet, other.violet, t)!,
      violetTint: Color.lerp(violetTint, other.violetTint, t)!,
      warm: Color.lerp(warm, other.warm, t)!,
      warmTint: Color.lerp(warmTint, other.warmTint, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      dangerTint: Color.lerp(dangerTint, other.dangerTint, t)!,
      pageStage: Color.lerp(pageStage, other.pageStage, t)!,
    );
  }
}

/// A small pair of icon ink and its tinted chip surface. Accents are used at
/// 16–32px only; they should not become large backgrounds or button fills.
@immutable
class AppAccent {
  const AppAccent({required this.color, required this.tint});

  final Color color;
  final Color tint;
}

extension AppColorsAccents on AppColors {
  AppAccent get blueAccent => AppAccent(color: blue, tint: blueTint);
  AppAccent get greenAccent => AppAccent(color: green, tint: greenTint);
  AppAccent get violetAccent => AppAccent(color: violet, tint: violetTint);
  AppAccent get warmAccent => AppAccent(color: warm, tint: warmTint);
  AppAccent get neutralAccent => AppAccent(color: inkMuted, tint: tint);
}

/// 4 · 8 · 12 · 16 · 24 · 32 · 48.
abstract final class Space {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
}

abstract final class Radii {
  static const double sm = 6;
  static const double md = 8;
  static const double lg = 12;
  static const double full = 999;
}

abstract final class Motion {
  static const fast = Duration(milliseconds: 120);
  static const base = Duration(milliseconds: 200);
  static const slow = Duration(milliseconds: 260);
  static const curve = Curves.easeOutCubic;
  static const curveStandard = Curves.easeOut;
}

abstract final class AppShadow {
  /// Hover elevation.
  static const e1 = <BoxShadow>[
    BoxShadow(color: Color(0x14000000), blurRadius: 12, offset: Offset(0, 4)),
    BoxShadow(color: Color(0x0A000000), blurRadius: 2, offset: Offset(0, 1)),
  ];

  /// Floating toolbars, popovers and dialogs.
  static const e2 = <BoxShadow>[
    BoxShadow(color: Color(0x24000000), blurRadius: 24, offset: Offset(0, 8)),
  ];

  /// A sheet of paper on the reading stage.
  static const paper = <BoxShadow>[
    BoxShadow(color: Color(0x1A000000), blurRadius: 24, offset: Offset(0, 8)),
    BoxShadow(color: Color(0x0D000000), blurRadius: 3, offset: Offset(0, 1)),
  ];
}

abstract final class AppNumerals {
  static const tabular = <FontFeature>[FontFeature.tabularFigures()];

  /// Page numbers, counters and statistics stay column-aligned.
  static TextStyle tabularStyle(TextStyle style) =>
      style.copyWith(fontFeatures: tabular);
}

extension AppThemeContext on BuildContext {
  AppColors get colors {
    final colors = Theme.of(this).extension<AppColors>();
    assert(colors != null, 'AppColors is missing from ThemeData.extensions');
    return colors ?? AppColors.light;
  }

  TextTheme get texts => Theme.of(this).textTheme;

  /// Respects the platform "reduce motion" setting. Decorative animation is
  /// collapsed to zero duration, never merely shortened.
  Duration motion(Duration duration) =>
      MediaQuery.maybeDisableAnimationsOf(this) ?? false
      ? Duration.zero
      : duration;

  bool get reduceMotion => MediaQuery.maybeDisableAnimationsOf(this) ?? false;
}
