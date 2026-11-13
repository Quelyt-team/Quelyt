import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../ui/theme/tokens.dart';

/// Lightweight Markdown reading view used by the editor's 预览 / 分栏 mode.
/// The Markdown source stays canonical, and the preview covers headings,
/// task lists (interactive), multi-line `$$` math blocks, code blocks, quotes,
/// and inline spans.
class NoteMarkdownPreview extends StatelessWidget {
  const NoteMarkdownPreview({
    super.key,
    required this.text,
    this.onToggleCheckbox,
  });

  final String text;
  final ValueChanged<int>? onToggleCheckbox;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (text.trim().isEmpty) {
      return Text(
        '还没有正文。切回编辑，写下第一行。',
        style: context.texts.bodyMedium!.copyWith(
          fontSize: 14,
          color: colors.inkMuted,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: _blocks(context),
    );
  }

  List<Widget> _blocks(BuildContext context) {
    final colors = context.colors;
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    final result = <Widget>[];
    var index = 0;
    while (index < lines.length) {
      final line = lines[index];
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        result.add(const SizedBox(height: 12));
        index++;
        continue;
      }
      if (RegExp(r'^(-{3,}|\*{3,}|_{3,})$').hasMatch(trimmed)) {
        result.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Divider(height: 1, color: colors.outline),
          ),
        );
        index++;
        continue;
      }
      if (trimmed.startsWith(r'$$')) {
        final formula = <String>[];
        if (trimmed.length >= 4 && trimmed.endsWith(r'$$')) {
          final single = trimmed.substring(2, trimmed.length - 2).trim();
          if (single.isNotEmpty) formula.add(single);
          index++;
        } else {
          final first = trimmed.substring(2).trim();
          if (first.isNotEmpty) formula.add(first);
          index++;
          while (index < lines.length) {
            final current = lines[index].trim();
            if (current.endsWith(r'$$')) {
              final body = current.substring(0, current.length - 2).trim();
              if (body.isNotEmpty) formula.add(body);
              index++;
              break;
            }
            formula.add(lines[index]);
            index++;
          }
        }
        result.add(
          Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(vertical: 8),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: colors.surfaceRaised,
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: colors.outline),
            ),
            child: SelectableText(
              formula.isEmpty ? ' ' : formula.join('\n'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: 'Cambria Math',
                fontSize: 16,
                height: 1.6,
                fontStyle: FontStyle.italic,
                color: colors.ink,
              ),
            ),
          ),
        );
        continue;
      }
      if (trimmed.startsWith('```')) {
        final lang = trimmed.substring(3).trim();
        final buffer = <String>[];
        index++;
        while (index < lines.length && !lines[index].trim().startsWith('```')) {
          buffer.add(lines[index]);
          index++;
        }
        if (index < lines.length) index++;
        final code = buffer.join('\n');
        result.add(
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: colors.surfaceRaised,
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: colors.outline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (lang.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: colors.outline)),
                    ),
                    child: Row(
                      children: [
                        Text(
                          lang,
                          style: context.texts.bodySmall!.copyWith(
                            fontSize: 12,
                            color: colors.inkMuted,
                            fontFamily: 'Consolas',
                          ),
                        ),
                        const Spacer(),
                        InkWell(
                          onTap: () =>
                              Clipboard.setData(ClipboardData(text: code)),
                          borderRadius: BorderRadius.circular(Radii.sm),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 2,
                            ),
                            child: QIcon(
                              QIcons.copy,
                              size: 13,
                              color: colors.inkMuted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(
                    code,
                    style: TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 12.5,
                      height: 1.55,
                      color: colors.ink,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        continue;
      }
      final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(trimmed);
      if (heading != null) {
        final level = heading.group(1)!.length;
        final size = switch (level) {
          1 => 24.0,
          2 => 20.0,
          3 => 17.0,
          _ => 15.0,
        };
        result.add(
          Padding(
            padding: EdgeInsets.only(
              top: level <= 2 ? 10 : 6,
              bottom: 6,
            ),
            child: SelectableText.rich(
              TextSpan(
                style: context.texts.titleSmall!.copyWith(
                  fontSize: size,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                ),
                children: _inline(
                  heading.group(2)!,
                  context.texts.titleSmall!.copyWith(fontSize: size),
                  colors.primary,
                ),
              ),
            ),
          ),
        );
        index++;
        continue;
      }
      final checkbox = RegExp(
        r'^[-*]\s+\[([ xX])\]\s+(.*)$',
      ).firstMatch(trimmed);
      if (checkbox != null) {
        final checked = checkbox.group(1)!.toLowerCase() == 'x';
        final lineIndex = index;
        result.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: InkWell(
              onTap: onToggleCheckbox == null
                  ? null
                  : () => onToggleCheckbox!(lineIndex),
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: QIcon(
                        checked ? QIcons.check : QIcons.ring,
                        size: 14,
                        color: checked ? colors.primary : colors.inkMuted,
                        active: checked,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _inlineText(
                        context,
                        checkbox.group(2)!,
                        context.texts.bodyMedium!.copyWith(
                          fontSize: 14,
                          height: 1.7,
                          color: checked ? colors.inkMuted : colors.ink,
                          decoration: checked
                              ? TextDecoration.lineThrough
                              : TextDecoration.none,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        index++;
        continue;
      }
      final bullet = RegExp(r'^[-*]\s+(.*)$').firstMatch(trimmed);
      if (bullet != null) {
        result.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 4,
                  height: 4,
                  margin: const EdgeInsets.only(top: 10),
                  decoration: BoxDecoration(
                    color: colors.inkMuted,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _inlineText(
                    context,
                    bullet.group(1)!,
                    context.texts.bodyMedium!.copyWith(
                      fontSize: 14.5,
                      height: 1.75,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        index++;
        continue;
      }
      final ordered = RegExp(r'^(\d+)\.\s+(.*)$').firstMatch(trimmed);
      if (ordered != null) {
        result.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 22,
                  child: Text(
                    '${ordered.group(1)}.',
                    style: context.texts.bodyMedium!.copyWith(
                      fontSize: 14,
                      height: 1.75,
                      color: colors.inkMuted,
                    ),
                  ),
                ),
                Expanded(
                  child: _inlineText(
                    context,
                    ordered.group(2)!,
                    context.texts.bodyMedium!.copyWith(
                      fontSize: 14.5,
                      height: 1.75,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
        index++;
        continue;
      }
      if (trimmed.startsWith('>')) {
        final quote = <String>[];
        while (index < lines.length && lines[index].trim().startsWith('>')) {
          quote.add(lines[index].trim().replaceFirst(RegExp(r'^>\s?'), ''));
          index++;
        }
        result.add(
          Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(vertical: 6),
            padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: colors.primary, width: 2)),
            ),
            child: _inlineText(
              context,
              quote.join('\n'),
              context.texts.bodyMedium!.copyWith(
                fontSize: 14,
                height: 1.75,
                color: colors.inkMuted,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        );
        continue;
      }
      final paragraph = <String>[line];
      index++;
      while (index < lines.length) {
        final next = lines[index].trim();
        if (next.isEmpty ||
            next.startsWith('#') ||
            next.startsWith('>') ||
            next.startsWith('```') ||
            next.startsWith(r'$$') ||
            RegExp(r'^(-{3,}|\*{3,}|_{3,})$').hasMatch(next) ||
            RegExp(r'^[-*]\s+').hasMatch(next) ||
            RegExp(r'^\d+\.\s+').hasMatch(next)) {
          break;
        }
        paragraph.add(lines[index]);
        index++;
      }
      result.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: _inlineText(
            context,
            paragraph.join('\n'),
            context.texts.bodyMedium!.copyWith(
              fontSize: 14.5,
              height: 1.85,
            ),
          ),
        ),
      );
    }
    return result;
  }

  Widget _inlineText(BuildContext context, String value, TextStyle style) =>
      SelectableText.rich(
        TextSpan(
          style: style,
          children: _inline(value, style, context.colors.primary),
        ),
      );

  List<InlineSpan> _inline(String value, TextStyle style, Color accent) {
    final spans = <InlineSpan>[];
    final pattern = RegExp(
      r'(\*\*[^*]+\*\*|~~[^~]+~~|\*[^*]+\*|`[^`]+`|\$[^$]+\$|\[[^\]]+\]\([^)]+\))',
    );
    var start = 0;
    for (final match in pattern.allMatches(value)) {
      if (match.start > start) {
        spans.add(TextSpan(text: value.substring(start, match.start)));
      }
      final token = match.group(0)!;
      if (token.startsWith('**') && token.endsWith('**')) {
        spans.add(
          TextSpan(
            text: token.substring(2, token.length - 2),
            style: style.copyWith(fontWeight: FontWeight.w600),
          ),
        );
      } else if (token.startsWith('~~') && token.endsWith('~~')) {
        spans.add(
          TextSpan(
            text: token.substring(2, token.length - 2),
            style: style.copyWith(decoration: TextDecoration.lineThrough),
          ),
        );
      } else if (token.startsWith('*') && token.endsWith('*')) {
        spans.add(
          TextSpan(
            text: token.substring(1, token.length - 1),
            style: style.copyWith(fontStyle: FontStyle.italic),
          ),
        );
      } else if (token.startsWith('`') && token.endsWith('`')) {
        spans.add(
          TextSpan(
            text: token.substring(1, token.length - 1),
            style: style.copyWith(
              fontFamily: 'Consolas',
              color: accent,
              fontSize: (style.fontSize ?? 14) - 1,
            ),
          ),
        );
      } else if (token.startsWith(r'$') && token.endsWith(r'$')) {
        spans.add(
          TextSpan(
            text: token.substring(1, token.length - 1),
            style: style.copyWith(
              fontFamily: 'Cambria Math',
              fontStyle: FontStyle.italic,
              color: accent,
            ),
          ),
        );
      } else {
        final link = RegExp(r'^\[([^\]]+)\]\(([^)]+)\)$').firstMatch(token)!;
        spans.add(
          TextSpan(
            text: link.group(1),
            style: style.copyWith(
              color: accent,
              decoration: TextDecoration.underline,
            ),
          ),
        );
      }
      start = match.end;
    }
    if (start < value.length) {
      spans.add(TextSpan(text: value.substring(start)));
    }
    return spans;
  }
}
