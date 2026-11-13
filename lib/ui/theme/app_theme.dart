import 'package:flutter/material.dart';

import 'tokens.dart';

const _fontFamily = 'Manrope';

const _fallbackFonts = <String>[
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'PingFang SC',
  'Noto Sans SC',
  'Noto Sans CJK SC',
  'Noto Sans CJK',
  'Source Han Sans SC',
  'Segoe UI',
  'Roboto',
  'sans-serif',
];

/// Builds the single theme used by every page, dialog and snackbar.
///
/// Component specifics live here once rather than in page code.
ThemeData buildAppTheme(Brightness brightness) {
  final c = brightness == Brightness.dark ? AppColors.dark : AppColors.light;
  final scheme =
      ColorScheme.fromSeed(
        seedColor: c.primary,
        brightness: brightness,
      ).copyWith(
        primary: c.primary,
        onPrimary: c.onPrimary,
        primaryContainer: c.tint,
        onPrimaryContainer: c.ink,
        secondary: c.warm,
        onSecondary: brightness == Brightness.dark
            ? const Color(0xFF2A1F0A)
            : Colors.white,
        secondaryContainer: c.warmTint,
        onSecondaryContainer: c.ink,
        error: c.danger,
        onError: brightness == Brightness.dark
            ? const Color(0xFF3A1410)
            : Colors.white,
        errorContainer: c.dangerTint,
        onErrorContainer: c.ink,
        surface: c.surface,
        onSurface: c.ink,
        onSurfaceVariant: c.inkMuted,
        surfaceContainerLowest: c.canvas,
        surfaceContainerLow: c.surface,
        surfaceContainer: c.surfaceRaised,
        surfaceContainerHigh: c.tint,
        surfaceContainerHighest: c.tint,
        outline: c.outlineStrong,
        outlineVariant: c.outline,
        shadow: Colors.black,
        scrim: Colors.black,
        inverseSurface: c.ink,
        onInverseSurface: c.canvas,
        inversePrimary: c.primary,
        surfaceTint: Colors.transparent,
      );

  final text = _textTheme(c);
  final overlay = _overlay(c);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    // A quiet flat ripple matches the monochrome chrome. It also avoids the
    // Impeller sparkle shader, which is unavailable in headless widget tests.
    splashFactory: InkRipple.splashFactory,
    colorScheme: scheme,
    extensions: [c],
    scaffoldBackgroundColor: c.canvas,
    canvasColor: c.canvas,
    cardColor: c.surface,
    shadowColor: Colors.black,
    dividerColor: c.outline,
    hoverColor: c.tint,
    focusColor: c.primary.withValues(alpha: .12),
    highlightColor: c.primary.withValues(alpha: .10),
    splashColor: c.primary.withValues(alpha: .10),
    textTheme: text,
    primaryTextTheme: text.apply(bodyColor: c.onPrimary),
    iconTheme: IconThemeData(color: c.inkMuted, size: IconSizes.md),
    fontFamilyFallback: _fallbackFonts,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    appBarTheme: AppBarTheme(
      backgroundColor: c.surface,
      foregroundColor: c.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      toolbarHeight: 52,
      titleTextStyle: text.titleMedium,
      iconTheme: IconThemeData(color: c.inkMuted, size: IconSizes.md),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 56,
      elevation: 0,
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: c.tint,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => text.labelMedium!.copyWith(
          color: states.contains(WidgetState.selected) ? c.primary : c.inkMuted,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w500,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: IconSizes.md,
          color: states.contains(WidgetState.selected) ? c.primary : c.inkMuted,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: c.sidebar,
      elevation: 0,
      useIndicator: true,
      indicatorColor: c.tint,
      indicatorShape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      selectedIconTheme: IconThemeData(color: c.primary, size: IconSizes.md),
      unselectedIconTheme: IconThemeData(color: c.inkMuted, size: IconSizes.md),
      selectedLabelTextStyle: text.labelMedium!.copyWith(color: c.primary),
      unselectedLabelTextStyle: text.labelMedium!.copyWith(color: c.inkMuted),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.isDark ? const Color(0xFF161618) : c.surface,
      isDense: true,
      floatingLabelBehavior: FloatingLabelBehavior.never,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: _inputBorder(c.outlineStrong),
      enabledBorder: _inputBorder(c.outlineStrong),
      disabledBorder: _inputBorder(c.outline.withValues(alpha: .7)),
      focusedBorder: _inputBorder(c.primary),
      errorBorder: _inputBorder(c.danger),
      focusedErrorBorder: _inputBorder(c.danger),
      labelStyle: text.bodySmall!.copyWith(color: c.inkMuted),
      floatingLabelStyle: text.bodySmall!.copyWith(color: c.inkMuted),
      hintStyle: text.bodySmall!.copyWith(color: c.inkMuted),
      helperStyle: text.bodySmall!.copyWith(color: c.inkMuted),
      helperMaxLines: 3,
      errorStyle: text.bodySmall!.copyWith(color: c.danger),
      errorMaxLines: 3,
      counterStyle: text.bodySmall!.copyWith(
        color: c.inkMuted,
        fontFeatures: AppNumerals.tabular,
      ),
      suffixIconColor: c.inkMuted,
      prefixIconColor: c.inkMuted,
      iconColor: c.inkMuted,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        backgroundColor: _filledBackground(c),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.disabled) ? c.inkMuted : c.onPrimary,
        ),
        overlayColor: _filledOverlay(c),
        elevation: const WidgetStatePropertyAll(0),
        minimumSize: const WidgetStatePropertyAll(Size(0, 38)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.sm)),
        ),
        textStyle: WidgetStatePropertyAll(text.labelLarge),
        iconSize: const WidgetStatePropertyAll(16),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStatePropertyAll(c.primary),
        overlayColor: overlay,
        minimumSize: const WidgetStatePropertyAll(Size(0, 38)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.sm)),
        ),
        side: WidgetStatePropertyAll(BorderSide(color: c.outlineStrong)),
        textStyle: WidgetStatePropertyAll(text.labelLarge),
        iconSize: const WidgetStatePropertyAll(16),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStatePropertyAll(c.primary),
        overlayColor: overlay,
        minimumSize: const WidgetStatePropertyAll(Size(0, 36)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.sm)),
        ),
        textStyle: WidgetStatePropertyAll(text.labelLarge),
        iconSize: const WidgetStatePropertyAll(IconSizes.sm),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(40, 40)),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(8)),
        iconSize: const WidgetStatePropertyAll(IconSizes.md),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? c.inkMuted.withValues(alpha: .45)
              : c.inkMuted,
        ),
        overlayColor: overlay,
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.sm)),
        ),
      ),
    ),
    cardTheme: CardThemeData(
      color: c.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        side: BorderSide(color: c.outline),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: c.surface,
      selectedColor: c.tint,
      disabledColor: c.surface,
      surfaceTintColor: Colors.transparent,
      side: BorderSide(color: c.outlineStrong),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      labelStyle: text.bodySmall!.copyWith(color: c.ink),
      secondaryLabelStyle: text.bodySmall!.copyWith(
        color: c.primary,
        fontWeight: FontWeight.w600,
      ),
      checkmarkColor: c.primary,
      showCheckmark: true,
      elevation: 0,
      pressElevation: 0,
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: c.primary,
      unselectedLabelColor: c.inkMuted,
      labelStyle: text.labelLarge!.copyWith(fontWeight: FontWeight.w600),
      unselectedLabelStyle: text.labelLarge!.copyWith(
        fontWeight: FontWeight.w500,
      ),
      indicatorColor: c.primary,
      indicatorSize: TabBarIndicatorSize.tab,
      indicator: UnderlineTabIndicator(
        borderSide: BorderSide(color: c.primary, width: 3),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
      ),
      dividerColor: c.outline,
      dividerHeight: 1,
      overlayColor: WidgetStatePropertyAll(c.tint),
      splashFactory: NoSplash.splashFactory,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? c.primary : c.ink,
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? c.tint : c.surfaceRaised,
        ),
        overlayColor: overlay,
        side: WidgetStateProperty.resolveWith(
          (states) => BorderSide(
            color: states.contains(WidgetState.selected)
                ? c.primary
                : c.outlineStrong,
            width: states.contains(WidgetState.selected) ? 1.5 : 1,
          ),
        ),
        minimumSize: const WidgetStatePropertyAll(Size(0, 34)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.sm)),
        ),
        textStyle: WidgetStatePropertyAll(text.bodySmall),
        iconSize: const WidgetStatePropertyAll(16),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: c.outline),
      ),
      titleTextStyle: text.bodyMedium!.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
      contentTextStyle: text.bodyMedium!.copyWith(height: 1.7),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      clipBehavior: Clip.antiAlias,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.ink,
      contentTextStyle: text.bodySmall!.copyWith(color: c.canvas, fontSize: 13),
      actionTextColor: brightness == Brightness.dark
          ? AppColors.light.brand
          : AppColors.dark.brand,
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 350),
      showDuration: const Duration(seconds: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      textStyle: text.bodySmall!.copyWith(color: c.ink, fontSize: 12),
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: c.outlineStrong),
        boxShadow: AppShadow.e2,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.surfaceRaised,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        side: BorderSide(color: c.outline),
      ),
      textStyle: text.bodySmall!.copyWith(fontSize: 13, color: c.ink),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: c.inkMuted,
      textColor: c.ink,
      titleTextStyle: text.bodySmall!.copyWith(fontSize: 13, color: c.ink),
      subtitleTextStyle: text.bodySmall,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      side: BorderSide(color: c.outlineStrong, width: 1.5),
      fillColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? c.primary
            : Colors.transparent,
      ),
      checkColor: WidgetStatePropertyAll(c.onPrimary),
      overlayColor: WidgetStatePropertyAll(c.tint),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? c.primary : c.outlineStrong,
      ),
    ),
    dividerTheme: DividerThemeData(color: c.outline, thickness: 1, space: 1),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(Radii.full),
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.hovered)
            ? c.outlineStrong
            : c.outlineStrong.withValues(alpha: .7),
      ),
      trackColor: const WidgetStatePropertyAll(Colors.transparent),
      crossAxisMargin: 2,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.primary,
      linearTrackColor: c.tint,
      circularTrackColor: c.tint,
      linearMinHeight: 4,
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.primary,
      selectionColor: c.primary.withValues(alpha: .22),
      selectionHandleColor: c.primary,
    ),
    bannerTheme: MaterialBannerThemeData(
      backgroundColor: c.dangerTint,
      surfaceTintColor: Colors.transparent,
      contentTextStyle: text.bodySmall!.copyWith(color: c.ink),
      elevation: 0,
      dividerColor: Colors.transparent,
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
      },
    ),
  );
}

TextTheme _textTheme(AppColors c) {
  final family = _fontFamily;
  TextStyle style(
    double size,
    double height,
    FontWeight weight, {
    Color? color,
    double spacing = 0,
  }) => TextStyle(
    fontFamily: family,
    fontSize: size,
    height: height,
    fontWeight: weight,
    color: color ?? c.ink,
    letterSpacing: spacing,
    fontFamilyFallback: _fallbackFonts,
  );

  return TextTheme(
    displayLarge: style(32, 1.28, FontWeight.w600),
    displayMedium: style(28, 1.32, FontWeight.w600),
    displaySmall: style(26, 1.35, FontWeight.w600),
    headlineLarge: style(26, 1.35, FontWeight.w600),
    headlineMedium: style(24, 1.38, FontWeight.w600),
    headlineSmall: style(20, 1.42, FontWeight.w600),
    titleLarge: style(19, 1.4, FontWeight.w600),
    titleMedium: style(16, 1.45, FontWeight.w600),
    titleSmall: style(15, 1.45, FontWeight.w600),
    bodyLarge: style(15, 1.72, FontWeight.w400),
    bodyMedium: style(14.5, 1.7, FontWeight.w400),
    bodySmall: style(13, 1.55, FontWeight.w400, color: c.inkMuted),
    labelLarge: style(13.5, 1.25, FontWeight.w600),
    labelMedium: style(12.5, 1.25, FontWeight.w600, color: c.inkMuted),
    labelSmall: style(
      12,
      1.35,
      FontWeight.w600,
      color: c.inkMuted,
      spacing: 1.0,
    ),
  );
}

WidgetStateProperty<Color?> _overlay(AppColors c) =>
    WidgetStateProperty.resolveWith((states) {
      if (states.contains(WidgetState.pressed)) {
        return c.primary.withValues(alpha: .16);
      }
      if (states.contains(WidgetState.hovered)) return c.tint;
      if (states.contains(WidgetState.focused)) {
        return c.primary.withValues(alpha: .12);
      }
      return null;
    });

WidgetStateProperty<Color?> _filledOverlay(AppColors c) =>
    WidgetStateProperty.resolveWith((states) {
      if (c.isDark) {
        if (states.contains(WidgetState.pressed)) {
          return Colors.black.withValues(alpha: .08);
        }
        if (states.contains(WidgetState.hovered)) {
          return Colors.black.withValues(alpha: .03);
        }
        if (states.contains(WidgetState.focused)) {
          return Colors.black.withValues(alpha: .08);
        }
        return null;
      }
      if (states.contains(WidgetState.pressed)) {
        return Colors.black.withValues(alpha: .10);
      }
      if (states.contains(WidgetState.hovered)) {
        return Colors.white.withValues(alpha: .04);
      }
      if (states.contains(WidgetState.focused)) {
        return Colors.white.withValues(alpha: .10);
      }
      return null;
    });

WidgetStateProperty<Color?> _filledBackground(
  AppColors c,
) => WidgetStateProperty.resolveWith((states) {
  if (states.contains(WidgetState.disabled)) {
    return c.tint;
  }
  if (c.isDark) {
    if (states.contains(WidgetState.pressed)) {
      return Color.alphaBlend(Colors.black.withValues(alpha: .12), c.primary);
    }
    if (states.contains(WidgetState.hovered)) {
      return Color.alphaBlend(Colors.black.withValues(alpha: .06), c.primary);
    }
    return c.primary;
  }
  if (states.contains(WidgetState.pressed)) {
    return Color.alphaBlend(Colors.black.withValues(alpha: .12), c.primary);
  }
  if (states.contains(WidgetState.hovered)) {
    return Color.alphaBlend(Colors.white.withValues(alpha: .08), c.primary);
  }
  return c.primary;
});

OutlineInputBorder _inputBorder(Color color, {double width = 1}) =>
    OutlineInputBorder(
      borderRadius: BorderRadius.circular(Radii.sm),
      borderSide: BorderSide(color: color, width: width),
    );

ThemeData get lightTheme => buildAppTheme(Brightness.light);
ThemeData get darkTheme => buildAppTheme(Brightness.dark);
