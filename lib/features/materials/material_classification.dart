import '../../core/models.dart';

/// Suggestions may be replaced before the reader chooses a mode. Metadata or
/// one ambiguous word alone is deliberately insufficient.
DocumentKind? suggestPageMode(String firstPageText) {
  final text = firstPageText.trim();
  if (text.isEmpty) return null;
  final paperMarkers = [
    RegExp(r'\b10\.\d{4,9}/\S+', caseSensitive: false),
    RegExp(r'(?:^|\n)\s*(?:abstract|摘\s*要)\b', caseSensitive: false),
    RegExp(r'keywords|关键词|corresponding author', caseSensitive: false),
    RegExp(r'journal|conference|vol\.\s*\d+|\bISSN\b', caseSensitive: false),
  ];
  if (paperMarkers.where((pattern) => pattern.hasMatch(text)).length >= 2) {
    return DocumentKind.paper;
  }
  final numbered = RegExp(
    r'(?:^|\n)\s*(?:第\s*\d+\s*题|[Qq](?:uestion)?\s*\d+|\d{1,3}[.)、．])\s*\S',
  ).allMatches(text).length;
  final assignment = RegExp(
    r'试[题卷]|练习题|作业|选择题|填空题|习题|\b(?:exam|homework|problem set)\b',
    caseSensitive: false,
  ).hasMatch(text);
  if (numbered >= 2 || (numbered >= 1 && assignment)) {
    return DocumentKind.exercise;
  }
  if (RegExp(
    r'第[一二三四五六七八九十\d]+章|\bchapter\s+\d+|目\s*录',
    caseSensitive: false,
  ).hasMatch(text)) {
    return DocumentKind.textbook;
  }
  return null;
}
