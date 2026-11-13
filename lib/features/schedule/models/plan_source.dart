import 'material_ref.dart';

/// Why a plan cites a document. The purpose is user-facing metadata; it does
/// not change how the local scheduler treats the material.
enum MaterialPurpose { textbook, syllabus, pastPaper, practice, notes }

extension MaterialPurposeLabel on MaterialPurpose {
  String get label => switch (this) {
    MaterialPurpose.textbook => '教材',
    MaterialPurpose.syllabus => '考纲',
    MaterialPurpose.pastPaper => '真题',
    MaterialPurpose.practice => '练习册',
    MaterialPurpose.notes => '笔记',
  };
}

/// A plan-level material binding: one document version and a physical page
/// range. Chapter labels are optional because many PDFs have no reliable
/// outline; the physical range is always the durable reference.
class PlanSource {
  PlanSource({
    required this.id,
    required this.planId,
    required this.documentId,
    required this.documentHash,
    required this.documentTitle,
    required this.purpose,
    required this.startPage,
    required this.endPage,
    this.chapter = '',
    this.revision = 1,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? createdAt ?? DateTime.now() {
    if (id.isEmpty || planId.isEmpty) {
      throw ArgumentError('Material source needs a plan and an id.');
    }
    if (documentId.isEmpty || documentHash.isEmpty) {
      throw ArgumentError('Material source needs a document version.');
    }
    if (startPage < 1 || endPage < startPage) {
      throw ArgumentError('Material source page range is invalid.');
    }
  }

  final String id;
  final String planId;
  final String documentId;
  final String documentHash;
  final String documentTitle;
  final MaterialPurpose purpose;
  final int startPage;
  final int endPage;
  final String chapter;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;

  int get pageCount => endPage - startPage + 1;

  String get rangeLabel => startPage == endPage
      ? '第 $startPage 页'
      : '第 $startPage–$endPage 页';

  String get label => chapter.trim().isEmpty
      ? '${purpose.label} · $rangeLabel'
      : '$chapter · ${purpose.label} · $rangeLabel';

  MaterialRef get materialRef => MaterialRef(
    documentId: documentId,
    documentHash: documentHash,
    title: documentTitle,
    startPage: startPage,
    endPage: endPage,
  );

  PlanSource copyWith({
    String? id,
    String? planId,
    String? documentId,
    String? documentHash,
    String? documentTitle,
    MaterialPurpose? purpose,
    int? startPage,
    int? endPage,
    String? chapter,
    int? revision,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => PlanSource(
    id: id ?? this.id,
    planId: planId ?? this.planId,
    documentId: documentId ?? this.documentId,
    documentHash: documentHash ?? this.documentHash,
    documentTitle: documentTitle ?? this.documentTitle,
    purpose: purpose ?? this.purpose,
    startPage: startPage ?? this.startPage,
    endPage: endPage ?? this.endPage,
    chapter: chapter ?? this.chapter,
    revision: revision ?? this.revision,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'planId': planId,
    'documentId': documentId,
    'documentHash': documentHash,
    'documentTitle': documentTitle,
    'purpose': purpose.name,
    'startPage': startPage,
    'endPage': endPage,
    'chapter': chapter,
    'revision': revision,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory PlanSource.fromJson(Map<String, dynamic> json) => PlanSource(
    id: json['id'] as String,
    planId: json['planId'] as String,
    documentId: json['documentId'] as String,
    documentHash: json['documentHash'] as String,
    documentTitle: json['documentTitle'] as String? ?? '',
    purpose: MaterialPurpose.values.byName(
      json['purpose'] as String? ?? 'textbook',
    ),
    startPage: (json['startPage'] as num).toInt(),
    endPage: (json['endPage'] as num).toInt(),
    chapter: json['chapter'] as String? ?? '',
    revision: (json['revision'] as num?)?.toInt() ?? 1,
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );
}

/// Read-only coverage computed from the imported page rows. A page is ready
/// only after text or OCR has been committed; imported-but-unread pages are
/// pending, not claimed as covered.
class MaterialCoverage {
  const MaterialCoverage({
    required this.totalPages,
    this.readyPages = 0,
    this.needsOcrPages = 0,
    this.pendingPages = 0,
    this.failedPages = 0,
    this.missingPages = 0,
    this.documentExists = true,
    this.versionMatches = true,
  });

  final int totalPages;
  final int readyPages;
  final int needsOcrPages;
  final int pendingPages;
  final int failedPages;
  final int missingPages;
  final bool documentExists;
  final bool versionMatches;

  int get attentionPages =>
      needsOcrPages + pendingPages + failedPages + missingPages;

  bool get allReady =>
      documentExists &&
      versionMatches &&
      totalPages > 0 &&
      readyPages == totalPages;

  double get progress =>
      totalPages <= 0 ? 0 : (readyPages / totalPages).clamp(0.0, 1.0);

  String get summary {
    if (!documentExists) return '资料已删除';
    if (!versionMatches) return '资料版本已改变';
    if (readyPages == totalPages && totalPages > 0) {
      return '已解析 $readyPages/$totalPages 页';
    }
    final parts = <String>['已解析 $readyPages/$totalPages 页'];
    if (needsOcrPages > 0) parts.add('$needsOcrPages 页待识别');
    if (pendingPages > 0) parts.add('$pendingPages 页待处理');
    if (failedPages > 0) parts.add('$failedPages 页失败');
    if (missingPages > 0) parts.add('$missingPages 页缺少记录');
    return parts.join(' · ');
  }
}

class MaterialPreparationResult {
  const MaterialPreparationResult({
    required this.coverage,
    this.processed = 0,
    this.message = '',
  });

  final MaterialCoverage coverage;
  final int processed;
  final String message;
}
