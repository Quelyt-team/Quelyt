import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Material-inspired responsive width buckets used across desktop, tablet, and phone.
enum AppWindowSizeClass { compact, medium, expanded }

/// Shared responsive layout breakpoints and touch-target helpers.
class AdaptiveLayout {
  const AdaptiveLayout._();

  static const double compactWidthBreakpoint = 600;
  static const double expandedWidthBreakpoint = 840;
  static const double compactHeightBreakpoint = 500;

  static AppWindowSizeClass sizeClassForWidth(double width) {
    if (width < compactWidthBreakpoint) return AppWindowSizeClass.compact;
    if (width < expandedWidthBreakpoint) return AppWindowSizeClass.medium;
    return AppWindowSizeClass.expanded;
  }

  static AppWindowSizeClass sizeClassOf(BuildContext context) =>
      sizeClassForWidth(MediaQuery.sizeOf(context).width);

  static bool isCompactWidth(double width) => width < compactWidthBreakpoint;

  static bool isCompactHeight(double height) =>
      height < compactHeightBreakpoint;

  static bool isCompactHeightContext(BuildContext context) =>
      isCompactHeight(MediaQuery.sizeOf(context).height);

  static bool get isTouchFirstPlatform =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  static double minTouchTarget(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return (isTouchFirstPlatform || width < expandedWidthBreakpoint)
        ? 48.0
        : 34.0;
  }
}
