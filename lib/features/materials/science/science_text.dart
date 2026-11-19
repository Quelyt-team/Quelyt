import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'formula_engine.dart';
import 'science_markup.dart';

class ScientificFormula extends StatelessWidget {
  const ScientificFormula({
    super.key,
    required this.latex,
    required this.style,
    this.display = false,
  });

  final String latex;
  final TextStyle style;
  final bool display;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(style.fontSize ?? 14);
    final color =
        style.color ??
        DefaultTextStyle.of(context).style.color ??
        Theme.of(context).colorScheme.onSurface;
    return FutureBuilder<FormulaGraphic?>(
      future: FormulaEngine.shared.render(latex, display: display),
      builder: (context, snapshot) {
        final formula = snapshot.data;
        if (formula == null) {
          return Tooltip(
            message: snapshot.connectionState == ConnectionState.done
                ? '无法排版，长按复制原始 TeX'
                : '正在排版',
            child: GestureDetector(
              onLongPress: () => Clipboard.setData(ClipboardData(text: latex)),
              child: Text(latex, style: style),
            ),
          );
        }
        final em = scale * .5;
        final height = formula.heightEx * em;
        final width = formula.widthEx * em;
        final baseline = (height - formula.depthEx * em).clamp(0.0, height);
        return LayoutBuilder(
          builder: (context, limits) {
            final maxWidth = limits.hasBoundedWidth
                ? limits.maxWidth
                : MediaQuery.sizeOf(context).width - 64;
            return SizedBox(
              width: math.min(width, math.max(1, maxWidth)),
              height: height,
              child: Baseline(
                baseline: baseline,
                baselineType: TextBaseline.alphabetic,
                child: GestureDetector(
                  onLongPress: () =>
                      Clipboard.setData(ClipboardData(text: latex)),
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SvgPicture.string(
                      formula.svg,
                      width: width,
                      height: height,
                      semanticsLabel: latex,
                      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// Shared by answers and note previews. A caller can supply its existing
/// Markdown span styling for portions outside of a formula.
class ScienceText extends StatelessWidget {
  const ScienceText(this.text, {super.key, this.style, this.plainSpans});

  final String text;
  final TextStyle? style;
  final List<InlineSpan> Function(String)? plainSpans;

  @override
  Widget build(BuildContext context) {
    final current = style ?? DefaultTextStyle.of(context).style;
    final formulas = parseFormulas(text);
    if (formulas.isEmpty) {
      return plainSpans == null
          ? SelectableText(text, style: current)
          : SelectableText.rich(
              TextSpan(style: current, children: plainSpans!(text)),
            );
    }
    final spans = <InlineSpan>[];
    List<InlineSpan> format(String value) =>
        plainSpans?.call(value) ?? [TextSpan(text: value)];
    var offset = 0;
    for (final formula in formulas) {
      spans.addAll(format(text.substring(offset, formula.start)));
      if (formula.display &&
          formula.start > 0 &&
          text[formula.start - 1] != '\n') {
        spans.add(const TextSpan(text: '\n'));
      }
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: ScientificFormula(
            latex: formula.latex,
            style: current,
            display: formula.display,
          ),
        ),
      );
      if (formula.display &&
          formula.end < text.length &&
          text[formula.end] != '\n') {
        spans.add(const TextSpan(text: '\n'));
      }
      offset = formula.end;
    }
    spans.addAll(format(text.substring(offset)));
    return SelectionArea(
      child: Text.rich(TextSpan(style: current, children: spans)),
    );
  }
}
