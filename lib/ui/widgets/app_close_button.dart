import 'package:flutter/material.dart';

/// Shared close affordance.
///
/// Dialog headers use the 44px default; smaller inline surfaces can pass a
/// compact size while keeping the same icon, tooltip and hit-target shape.
class AppCloseButton extends StatelessWidget {
  const AppCloseButton({
    super.key,
    this.tooltip = '关闭',
    this.onPressed,
    this.size = 44,
    this.iconSize = 24,
    this.color,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed ?? () => Navigator.of(context).maybePop(),
      constraints: BoxConstraints.tightFor(width: size, height: size),
      padding: EdgeInsets.zero,
      icon: Icon(Icons.close_rounded, size: iconSize, color: color),
    );
  }
}
