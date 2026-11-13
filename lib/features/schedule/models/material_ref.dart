import '../../../../core/models.dart';

/// A durable reference from a task to one document version and page range.
/// The hash prevents opening a different file that happens to reuse an id.
class MaterialRef {
  MaterialRef({
    required this.documentId,
    required this.documentHash,
    required this.title,
    required this.startPage,
    required this.endPage,
    this.missing = false,
  }) {
    if (documentId.isEmpty || documentHash.isEmpty) {
      throw ArgumentError('Material needs a document and version.');
    }
    if (startPage < 1 || endPage < startPage) {
      throw ArgumentError('Material page range is invalid.');
    }
  }

  final String documentId;
  final String documentHash;
  final String title;
  final int startPage;
  final int endPage;

  /// True after the referenced document was deleted. The task keeps its page
  /// range and history, but the calendar shows "资料已删除" instead of a dead
  /// clickable link.
  final bool missing;

  String get rangeLabel => startPage == endPage
      ? '第 $startPage 页'
      : '第 $startPage–$endPage 页';

  bool matches(DocumentRecord document) =>
      !missing &&
      document.id == documentId &&
      document.contentHash == documentHash;

  Map<String, dynamic> toJson() => {
    'documentId': documentId,
    'documentHash': documentHash,
    'title': title,
    'startPage': startPage,
    'endPage': endPage,
    'missing': missing,
  };

  factory MaterialRef.fromJson(Map<String, dynamic> json) => MaterialRef(
    documentId: json['documentId'] as String,
    documentHash: json['documentHash'] as String,
    title: json['title'] as String,
    startPage: (json['startPage'] as num).toInt(),
    endPage: (json['endPage'] as num).toInt(),
    missing: json['missing'] as bool? ?? false,
  );
}
