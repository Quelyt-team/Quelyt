import 'dart:math' as math;

import 'models.dart';

/// Keeps related cells and punctuation together. Also used when querying
/// indexes built by older versions, which stored each PDF word separately.
class PageEvidenceLayout {
  PageEvidenceLayout(Iterable<Evidence> input) {
    final sorted = input.toList()..sort((a, b) => _y(a).compareTo(_y(b)));
    final rows = <List<Evidence>>[];
    for (final fragment in sorted) {
      if (rows.isEmpty || !_sameLine(rows.last.first, fragment)) {
        rows.add([fragment]);
      } else {
        rows.last.add(fragment);
      }
    }
    for (final row in rows) {
      row.sort((a, b) => a.region.left.compareTo(b.region.left));
      final groups = <List<Evidence>>[[]];
      for (final item in row) {
        final group = groups.last;
        if (group.isNotEmpty &&
            item.region.left - group.last.region.right > .065) {
          groups.add([]);
        }
        groups.last.add(item);
      }
      final cells = groups.map(_merge).toList();
      // Widely separated, short cells are one table row. Two long cells are
      // usually prose columns and keep their own reading order and bounds.
      final joinedCells =
          cells.length > 1 &&
          cells.every((cell) => cell.text.length <= 56) &&
          cells.any((cell) => RegExp(r'\d').hasMatch(cell.text));
      if (joinedCells) {
        _add(row, _merge(cells, separator: ' | '));
      } else {
        for (var i = 0; i < cells.length; i++) {
          _add(groups[i], cells[i]);
        }
      }
    }
  }

  final List<Evidence> lines = [];
  final Map<String, int> _lineById = {};

  void _add(List<Evidence> members, Evidence line) {
    for (final member in members) {
      _lineById[member.id] = lines.length;
    }
    lines.add(line);
  }

  Evidence contextFor(Evidence hit) {
    final index = _lineById[hit.id];
    if (index == null) return hit;
    final line = lines[index];
    if (!RegExp(r'\d').hasMatch(line.text)) return line;
    for (var i = index - 1; i >= math.max(0, index - 5); i--) {
      final candidate = lines[i];
      if (line.region.top - candidate.region.bottom > .15) break;
      final tableTitle = RegExp(
        r'^(?:table\b|表\s*[0-9一二三四五六七八九]|表格)',
        caseSensitive: false,
      );
      if (!tableTitle.hasMatch(candidate.text) ||
          candidate.region.left > line.region.right) {
        continue;
      }
      final context = lines
          .sublist(i, index + 1)
          .where(
            (row) =>
                row.region.left <= line.region.right + .03 &&
                row.region.right >= line.region.left - .03,
          );
      return line.copyWith(
        text: context.map((row) => row.text).join('\n'),
        region: context.fold<SourceRegion>(
          line.region,
          (bounds, row) => bounds.union(row.region),
        ),
      );
    }
    return line;
  }

  static double _y(Evidence entry) =>
      (entry.region.top + entry.region.bottom) / 2;

  static bool _sameLine(Evidence a, Evidence b) {
    if (a.origin != b.origin ||
        a.origin == EvidenceOrigin.manual ||
        a.origin == EvidenceOrigin.vision ||
        a.text.contains('\n') ||
        b.text.contains('\n')) {
      return false;
    }
    final overlap =
        math.min(a.region.bottom, b.region.bottom) -
        math.max(a.region.top, b.region.top);
    return overlap > math.min(a.region.height, b.region.height) * .46 &&
        (_y(a) - _y(b)).abs() < math.max(a.region.height, b.region.height) * .6;
  }

  static Evidence _merge(List<Evidence> items, {String separator = ' '}) {
    if (items.length == 1) return items.single;
    final buffer = StringBuffer(items.first.text.trim());
    var previous = items.first;
    var region = previous.region;
    for (final item in items.skip(1)) {
      final text = item.text.trim();
      final gap = item.region.left - previous.region.right;
      final punctuation = RegExp(r'^[,.;:!?%）。，；：、！？]').hasMatch(text);
      final bothHan =
          RegExp(r'[\u3400-\u9fff]$').hasMatch(previous.text) &&
          RegExp(r'^[\u3400-\u9fff]').hasMatch(text);
      final attached = punctuation || bothHan || gap < -.003;
      buffer.write(attached && separator == ' ' ? '' : separator);
      buffer.write(text);
      region = region.union(item.region);
      previous = item;
    }
    return items.first.copyWith(text: buffer.toString(), region: region);
  }
}
