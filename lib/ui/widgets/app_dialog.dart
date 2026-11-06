import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'app_close_button.dart';

/// Consistent dialog frame: 12px corners, compact padding, one primary action.
///
/// Uses the router's built-in focus trap, Escape dismissal and scoped route
/// semantics; pages only supply content and actions.
class AppDialog extends StatelessWidget {
  const AppDialog({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
    this.subtitle,
    this.icon,
    this.accent,
    this.maxWidth = 420,
    this.headerExtra,
    this.contentPadding = const EdgeInsets.fromLTRB(16, 12, 16, 16),
    this.closeTooltip = '关闭',
    this.titleStyle,
    this.scrollContent = true,
    this.showHeader = true,
  });

  final String title;
  final String? subtitle;
  final Widget content;
  final List<Widget> actions;
  final IconData? icon;
  final AppAccent? accent;
  final double maxWidth;
  final Widget? headerExtra;
  final EdgeInsetsGeometry contentPadding;
  final String closeTooltip;
  final TextStyle? titleStyle;

  /// When false the content owns its scrolling (for example a result list).
  final bool scrollContent;

  /// Spotlight-style dialogs can hide the conventional title/close header.
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: math.min(maxWidth, screen.width - 32),
          maxHeight: screen.height - 40,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showHeader)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Semantics(
                            header: true,
                            child: Text(
                              title,
                              style:
                                  titleStyle ??
                                  context.texts.bodyMedium!.copyWith(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ),
                          if (subtitle != null) ...[
                            const SizedBox(height: 3),
                            Text(
                              subtitle!,
                              style: context.texts.bodySmall!.copyWith(
                                height: 1.5,
                              ),
                            ),
                          ],
                          if (headerExtra != null) ...[
                            const SizedBox(height: Space.sm),
                            headerExtra!,
                          ],
                        ],
                      ),
                    ),
                    AppCloseButton(
                      tooltip: closeTooltip,
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
              ),
            Flexible(
              child: scrollContent
                  ? SingleChildScrollView(
                      padding: contentPadding,
                      child: content,
                    )
                  : Padding(padding: contentPadding, child: content),
            ),
            if (actions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: Space.sm,
                  runSpacing: Space.sm,
                  children: actions,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) => showDialog<T>(
  context: context,
  barrierDismissible: barrierDismissible,
  barrierColor: Colors.black.withValues(alpha: .42),
  builder: builder,
);

class DialogFieldLabel extends StatelessWidget {
  const DialogFieldLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: context.texts.bodySmall!.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: context.colors.ink,
      ),
    ),
  );
}

class DialogBodyText extends StatelessWidget {
  const DialogBodyText(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: context.texts.bodyMedium!.copyWith(height: 1.7));
}

class DialogActions {
  const DialogActions._();

  static Widget cancel(BuildContext context, {String label = '取消'}) =>
      TextButton(
        onPressed: () => Navigator.of(context).maybePop(),
        child: Text(label),
      );
}
