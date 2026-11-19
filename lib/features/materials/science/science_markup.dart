/// Offsets refer to the canonical Markdown string. Code and escaped
/// delimiters stay literal and exports can preserve the original TeX.
class FormulaSpan {
  const FormulaSpan(this.start, this.end, this.latex, {required this.display});

  final int start;
  final int end;
  final String latex;
  final bool display;
}

List<FormulaSpan> parseFormulas(String source) {
  final spans = <FormulaSpan>[];
  var i = 0;
  while (i < source.length) {
    if (source.codeUnitAt(i) == 96 && !_escaped(source, i)) {
      var end = i + 1;
      while (end < source.length && source.codeUnitAt(end) == 96) {
        end++;
      }
      final fence = source.substring(i, end);
      final closing = source.indexOf(fence, end);
      i = closing >= 0 ? closing + fence.length : source.length;
      continue;
    }
    // Markdown permits tilde fences as well as backticks.
    if ((i == 0 || source.codeUnitAt(i - 1) == 10) &&
        source.startsWith('~~~', i)) {
      final closing = source.indexOf('\n~~~', i + 3);
      if (closing < 0) break;
      final newline = source.indexOf('\n', closing + 1);
      i = newline < 0 ? source.length : newline + 1;
      continue;
    }
    if (_escaped(source, i)) {
      i++;
      continue;
    }
    final String open;
    final String close;
    final bool display;
    if (source.startsWith(r'$$', i)) {
      open = close = r'$$';
      display = true;
    } else if (source.startsWith(r'\[', i)) {
      open = r'\[';
      close = r'\]';
      display = true;
    } else if (source.startsWith(r'\(', i)) {
      open = r'\(';
      close = r'\)';
      display = false;
    } else if (source.startsWith(r'$', i)) {
      open = close = r'$';
      display = false;
    } else {
      i++;
      continue;
    }
    final contentStart = i + open.length;
    var finish = source.indexOf(close, contentStart);
    while (finish >= 0 && _escaped(source, finish)) {
      finish = source.indexOf(close, finish + close.length);
    }
    if (finish >= 0 && finish > contentStart) {
      final value = source.substring(contentStart, finish);
      final inlineDollar = open == r'$';
      final currency =
          inlineDollar &&
          RegExp(r'^\d[\d,.]*(?:\s|$)').hasMatch(value) &&
          !RegExp(r'[=^_+*/{}\\]').hasMatch(value);
      if (value.trim().isNotEmpty &&
          (display || !value.contains('\n')) &&
          (!inlineDollar || value == value.trim()) &&
          !currency) {
        spans.add(
          FormulaSpan(i, finish + close.length, value.trim(), display: display),
        );
        i = finish + close.length;
        continue;
      }
    }
    i += open.length;
  }
  return spans;
}

bool _escaped(String source, int index) {
  var count = 0;
  for (var i = index - 1; i >= 0 && source.codeUnitAt(i) == 92; i--) {
    count++;
  }
  return count.isOdd;
}
