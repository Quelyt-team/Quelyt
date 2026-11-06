/// Search preprocessing shared by the FTS5 index and query builder.
///
/// Chinese is indexed as individual characters and adjacent character pairs,
/// so queries such as “熵” and “动量” work without an online tokenizer.
abstract final class SearchIndex {
  static final _parts = RegExp(
    r'[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]+|[A-Za-z0-9_]+',
  );

  static bool _isHan(String text) {
    final code = text.codeUnitAt(0);
    return code >= 0x3400 && code <= 0x9fff || code >= 0xf900 && code <= 0xfaff;
  }

  static List<String> tokens(String text) {
    final result = <String>[];
    for (final match in _parts.allMatches(text.toLowerCase())) {
      final part = match.group(0)!;
      if (_isHan(part)) {
        final chars = part.runes.map(String.fromCharCode).toList();
        result.addAll(chars);
        for (var i = 0; i + 1 < chars.length; i++) {
          result.add('${chars[i]}${chars[i + 1]}');
        }
      } else {
        result.add(part);
      }
    }
    return result;
  }

  static String indexText(String text) => tokens(text).join(' ');

  /// Treats input as literal words, never as user-supplied FTS syntax.
  /// Adjacent Han pairs are required together; a one-character query stays
  /// searchable. Separate user terms are ORed for useful retrieval in prose.
  static String matchQuery(String query) {
    final groups = <String>[];
    for (final match in _parts.allMatches(query.toLowerCase())) {
      final part = match.group(0)!;
      if (_isHan(part) && part.length > 1) {
        final chars = part.runes.map(String.fromCharCode).toList();
        final pairs = <String>[];
        for (var i = 0; i + 1 < chars.length; i++) {
          pairs.add('"${chars[i]}${chars[i + 1]}"');
        }
        groups.add('(${pairs.join(' AND ')})');
      } else {
        groups.add('"$part"');
      }
    }
    return groups.toSet().join(' OR ');
  }
}
