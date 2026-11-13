import '../../../core/models.dart';

/// Stable, language-tolerant key for matching a textbook term in a question.
///
/// It lowercases, removes whitespace and punctuation (including the full-width
/// variants produced by OCR) and keeps Han characters, Latin letters and
/// digits. Two spellings of the same term therefore share one key without
/// changing the term that is displayed to the user.
String normalizeBookTerm(String value) {
  final buffer = StringBuffer();
  for (final rune in value.toLowerCase().runes) {
    final character = String.fromCharCode(rune);
    if (RegExp(r'[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]')
            .hasMatch(character) ||
        RegExp(r'[a-z0-9]').hasMatch(character)) {
      buffer.write(character);
    }
  }
  return buffer.toString();
}

String formatBookPageRange(int start, int end) =>
    start == end ? '第 $start 页' : '第 $start–$end 页';

/// Compresses page numbers into readable sorted ranges, e.g. “第 3–5、9 页”.
/// Empty input means there is no gap to report.
String describeBookPageRanges(Iterable<int> pages) {
  final sorted = pages.toSet().toList()..sort();
  if (sorted.isEmpty) return '';
  final ranges = <String>[];
  var start = sorted.first;
  var previous = start;
  void flush() {
    ranges.add(start == previous ? '$start' : '$start–$previous');
  }

  for (final page in sorted.skip(1)) {
    if (page == previous + 1) {
      previous = page;
      continue;
    }
    flush();
    start = page;
    previous = page;
  }
  flush();
  return ranges.length == 1
      ? '第 ${ranges.single} 页'
      : '第 ${ranges.join('、')} 页';
}

enum BookJobStatus { idle, running, paused, complete, partial, failed }

BookJobStatus bookJobStatusFromName(String? name) =>
    BookJobStatus.values.firstWhere(
      (value) => value.name == name,
      orElse: () => BookJobStatus.idle,
    );

/// What the page-level extraction actually produced. A page with a text layer
/// but no usable characters is still a gap.
class PageParseReport {
  const PageParseReport({
    required this.totalPages,
    required this.readyPages,
    required this.skippedPages,
    required this.pendingPages,
    required this.needsOcrPages,
    required this.failedPages,
    required this.unparsedPageNumbers,
  });

  factory PageParseReport.fromPages(int totalPages, List<PageRecord> pages) {
    final byPage = {for (final page in pages) page.page: page};
    var ready = 0;
    var skipped = 0;
    var pending = 0;
    var needsOcr = 0;
    var failed = 0;
    final unparsed = <int>[];
    for (var page = 1; page <= totalPages; page++) {
      final record = byPage[page];
      if (record != null &&
          record.status == PageStatus.ready &&
          record.text.trim().isEmpty) {
        // An explicitly indexed empty page (cover, blank page) counts as
        // handled, not as a missing page. Document indexing never produces
        // this state on its own, so it requires a deliberate skip action.
        skipped++;
        continue;
      }
      final usable =
          record != null &&
          record.status == PageStatus.ready &&
          record.text.trim().isNotEmpty;
      if (usable) {
        ready++;
        continue;
      }
      unparsed.add(page);
      switch (record?.status) {
        case PageStatus.pending:
          pending++;
        case PageStatus.needsOcr:
          needsOcr++;
        case PageStatus.failed:
          failed++;
        case PageStatus.ready:
        case null:
          pending++;
      }
    }
    return PageParseReport(
      totalPages: totalPages,
      readyPages: ready,
      skippedPages: skipped,
      pendingPages: pending,
      needsOcrPages: needsOcr,
      failedPages: failed,
      unparsedPageNumbers: List.unmodifiable(unparsed),
    );
  }

  final int totalPages;
  final int readyPages;
  final int skippedPages;
  final int pendingPages;
  final int needsOcrPages;
  final int failedPages;
  final List<int> unparsedPageNumbers;

  bool get allParsed => readyPages + skippedPages == totalPages;
  String get gapLabel => unparsedPageNumbers.isEmpty
      ? ''
      : describeBookPageRanges(unparsedPageNumbers);
}

class BookChapter {
  BookChapter({
    required this.id,
    required this.documentId,
    required this.documentHash,
    required this.ordinal,
    required this.title,
    required this.startPage,
    required this.endPage,
    this.generated = false,
    this.revision = 1,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  final String id;
  final String documentId;
  final String documentHash;
  final int ordinal;
  final String title;
  final int startPage;
  final int endPage;

  /// True when no reliable table of contents was found and the chapter was
  /// derived from page ranges. The UI must not present it as the real TOC.
  final bool generated;
  final int revision;
  final DateTime updatedAt;

  String get rangeLabel => formatBookPageRange(startPage, endPage);

  Map<String, dynamic> toJson() => {
    'id': id,
    'documentId': documentId,
    'documentHash': documentHash,
    'ordinal': ordinal,
    'title': title,
    'startPage': startPage,
    'endPage': endPage,
    'generated': generated,
    'revision': revision,
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory BookChapter.fromJson(Map<String, dynamic> json) => BookChapter(
    id: json['id'] as String,
    documentId: json['documentId'] as String,
    documentHash: json['documentHash'] as String,
    ordinal: (json['ordinal'] as num).toInt(),
    title: json['title'] as String,
    startPage: (json['startPage'] as num).toInt(),
    endPage: (json['endPage'] as num).toInt(),
    generated: json['generated'] as bool? ?? false,
    revision: (json['revision'] as num?)?.toInt() ?? 1,
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );
}

class BookTermInsight {
  const BookTermInsight({
    required this.term,
    this.englishAlias = '',
    this.symbol = '',
    this.definition = '',
    this.pages = const [],
  });

  final String term;
  final String englishAlias;
  final String symbol;
  final String definition;
  final List<int> pages;

  Map<String, dynamic> toJson() => {
    'term': term,
    'englishAlias': englishAlias,
    'symbol': symbol,
    'definition': definition,
    'pages': pages,
  };

  factory BookTermInsight.fromJson(Map<String, dynamic> json) =>
      BookTermInsight(
        term: json['term'] as String? ?? '',
        englishAlias: json['englishAlias'] as String? ?? '',
        symbol: json['symbol'] as String? ?? '',
        definition: json['definition'] as String? ?? '',
        pages: [
          for (final page in json['pages'] as List? ?? const [])
            if (page is num) page.toInt(),
        ],
      );
}

class BookChunkInsight {
  const BookChunkInsight({
    required this.summary,
    this.definitions = const [],
    this.conclusions = const [],
    this.conditions = const [],
    this.typicalProblems = const [],
    this.terms = const [],
  });

  final String summary;
  final List<String> definitions;
  final List<String> conclusions;
  final List<String> conditions;
  final List<String> typicalProblems;
  final List<BookTermInsight> terms;

  Map<String, dynamic> toJson() => {
    'summary': summary,
    'definitions': definitions,
    'conclusions': conclusions,
    'conditions': conditions,
    'typicalProblems': typicalProblems,
    'terms': terms.map((term) => term.toJson()).toList(),
  };

  factory BookChunkInsight.fromJson(Map<String, dynamic> json) =>
      BookChunkInsight(
        summary: json['summary'] as String? ?? '',
        definitions: [
          for (final item in json['definitions'] as List? ?? const [])
            if (item is String) item,
        ],
        conclusions: [
          for (final item in json['conclusions'] as List? ?? const [])
            if (item is String) item,
        ],
        conditions: [
          for (final item in json['conditions'] as List? ?? const [])
            if (item is String) item,
        ],
        typicalProblems: [
          for (final item in json['typicalProblems'] as List? ?? const [])
            if (item is String) item,
        ],
        terms: [
          for (final item in json['terms'] as List? ?? const [])
            if (item is Map)
              BookTermInsight.fromJson(Map<String, dynamic>.from(item)),
        ],
      );
}

enum BookChunkStatus { pending, ready, failed, skipped }

BookChunkStatus bookChunkStatusFromName(String? name) =>
    BookChunkStatus.values.firstWhere(
      (value) => value.name == name,
      orElse: () => BookChunkStatus.pending,
    );

class BookChunk {
  const BookChunk({
    required this.id,
    required this.documentId,
    required this.documentHash,
    required this.chapterId,
    required this.ordinal,
    required this.startPage,
    required this.endPage,
    this.status = BookChunkStatus.pending,
    this.insight,
    this.error,
    this.truncated = false,
    this.sourceDigest = '',
    this.sourceCharacters = 0,
    this.revision = 1,
    this.updatedAt,
  });

  final String id;
  final String documentId;
  final String documentHash;
  final String? chapterId;
  final int ordinal;
  final int startPage;
  final int endPage;
  final BookChunkStatus status;
  final BookChunkInsight? insight;
  final String? error;

  /// True when the source page text exceeded the per-request limit and only a
  /// marked head was sent. The chunk still points at the full page range.
  final bool truncated;

  /// Digest of the page text this result was built from, used to invalidate
  /// only affected chunks after OCR correction or manual editing.
  final String sourceDigest;
  final int sourceCharacters;
  final int revision;
  final DateTime? updatedAt;

  BookChunk copyWith({
    BookChunkStatus? status,
    BookChunkInsight? insight,
    String? error,
    bool clearError = false,
    bool? truncated,
    String? sourceDigest,
    int? sourceCharacters,
    int? revision,
    DateTime? updatedAt,
  }) => BookChunk(
    id: id,
    documentId: documentId,
    documentHash: documentHash,
    chapterId: chapterId,
    ordinal: ordinal,
    startPage: startPage,
    endPage: endPage,
    status: status ?? this.status,
    insight: insight ?? this.insight,
    error: clearError ? null : error ?? this.error,
    truncated: truncated ?? this.truncated,
    sourceDigest: sourceDigest ?? this.sourceDigest,
    sourceCharacters: sourceCharacters ?? this.sourceCharacters,
    revision: revision ?? this.revision,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'documentId': documentId,
    'documentHash': documentHash,
    'chapterId': chapterId,
    'ordinal': ordinal,
    'startPage': startPage,
    'endPage': endPage,
    'status': status.name,
    'insight': insight?.toJson(),
    'error': error,
    'truncated': truncated,
    'sourceDigest': sourceDigest,
    'sourceCharacters': sourceCharacters,
    'revision': revision,
    'updatedAt': updatedAt?.toIso8601String(),
  };

  factory BookChunk.fromJson(Map<String, dynamic> json) => BookChunk(
    id: json['id'] as String,
    documentId: json['documentId'] as String,
    documentHash: json['documentHash'] as String,
    chapterId: json['chapterId'] as String?,
    ordinal: (json['ordinal'] as num).toInt(),
    startPage: (json['startPage'] as num).toInt(),
    endPage: (json['endPage'] as num).toInt(),
    status: bookChunkStatusFromName(json['status'] as String?),
    insight: json['insight'] is Map
        ? BookChunkInsight.fromJson(
            Map<String, dynamic>.from(json['insight'] as Map),
          )
        : null,
    error: json['error'] as String?,
    truncated: json['truncated'] as bool? ?? false,
    sourceDigest: json['sourceDigest'] as String? ?? '',
    sourceCharacters: (json['sourceCharacters'] as num?)?.toInt() ?? 0,
    revision: (json['revision'] as num?)?.toInt() ?? 1,
    updatedAt: json['updatedAt'] == null
        ? null
        : DateTime.parse(json['updatedAt'] as String),
  );
}

class BookKnowledgePoint {
  const BookKnowledgePoint({
    required this.id,
    required this.documentId,
    required this.documentHash,
    required this.chapterId,
    required this.term,
    required this.termNorm,
    required this.startPage,
    required this.endPage,
    this.englishAlias = '',
    this.symbol = '',
    this.definition = '',
    this.aliases = const [],
    this.relatedTerms = const [],
    this.prerequisiteTerms = const [],
    this.verified = false,
    this.revision = 1,
    this.updatedAt,
  });

  final String id;
  final String documentId;
  final String documentHash;
  final String? chapterId;
  final String term;
  final String termNorm;
  final int startPage;
  final int endPage;
  final String englishAlias;
  final String symbol;
  final String definition;

  /// Alternative spellings the model saw in the book or produced (for example
  /// “键接”, “头尾连接”, “head-to-tail”). Used for whole-book recall.
  final List<String> aliases;
  final List<String> relatedTerms;
  final List<String> prerequisiteTerms;

  /// False when the model could not tie the relationship to a page. It stays
  /// searchable but the UI does not present it as verified knowledge.
  final bool verified;
  final int revision;
  final DateTime? updatedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'documentId': documentId,
    'documentHash': documentHash,
    'chapterId': chapterId,
    'term': term,
    'termNorm': termNorm,
    'startPage': startPage,
    'endPage': endPage,
    'englishAlias': englishAlias,
    'symbol': symbol,
    'definition': definition,
    'aliases': aliases,
    'relatedTerms': relatedTerms,
    'prerequisiteTerms': prerequisiteTerms,
    'verified': verified,
    'revision': revision,
    'updatedAt': updatedAt?.toIso8601String(),
  };

  factory BookKnowledgePoint.fromJson(Map<String, dynamic> json) =>
      BookKnowledgePoint(
        id: json['id'] as String,
        documentId: json['documentId'] as String,
        documentHash: json['documentHash'] as String,
        chapterId: json['chapterId'] as String?,
        term: json['term'] as String? ?? '',
        termNorm: json['termNorm'] as String? ?? '',
        startPage: (json['startPage'] as num?)?.toInt() ?? 1,
        endPage: (json['endPage'] as num?)?.toInt() ?? 1,
        englishAlias: json['englishAlias'] as String? ?? '',
        symbol: json['symbol'] as String? ?? '',
        definition: json['definition'] as String? ?? '',
        aliases: [
          for (final item in json['aliases'] as List? ?? const [])
            if (item is String) item,
        ],
        relatedTerms: [
          for (final item in json['relatedTerms'] as List? ?? const [])
            if (item is String) item,
        ],
        prerequisiteTerms: [
          for (final item in json['prerequisiteTerms'] as List? ?? const [])
            if (item is String) item,
        ],
        verified: json['verified'] as bool? ?? false,
        revision: (json['revision'] as num?)?.toInt() ?? 1,
        updatedAt: json['updatedAt'] == null
            ? null
            : DateTime.parse(json['updatedAt'] as String),
      );

  BookKnowledgePoint copyWith({
    String? chapterId,
    int? startPage,
    int? endPage,
    String? englishAlias,
    String? symbol,
    String? definition,
    List<String>? aliases,
    List<String>? relatedTerms,
    List<String>? prerequisiteTerms,
    bool? verified,
    int? revision,
    DateTime? updatedAt,
  }) => BookKnowledgePoint(
    id: id,
    documentId: documentId,
    documentHash: documentHash,
    chapterId: chapterId ?? this.chapterId,
    term: term,
    termNorm: termNorm,
    startPage: startPage ?? this.startPage,
    endPage: endPage ?? this.endPage,
    englishAlias: englishAlias ?? this.englishAlias,
    symbol: symbol ?? this.symbol,
    definition: definition ?? this.definition,
    aliases: aliases ?? this.aliases,
    relatedTerms: relatedTerms ?? this.relatedTerms,
    prerequisiteTerms: prerequisiteTerms ?? this.prerequisiteTerms,
    verified: verified ?? this.verified,
    revision: revision ?? this.revision,
    updatedAt: updatedAt ?? this.updatedAt,
  );
}

class BookOverview {
  const BookOverview({
    required this.subject,
    required this.conventions,
    this.chapterRelations = const [],
    this.themes = const [],
    this.unfinished = const [],
    this.generatedAt,
  });

  /// The subject scope and definitional conventions the book follows.
  final String subject;
  final String conventions;
  final List<String> chapterRelations;
  final List<String> themes;

  /// Chapters or topics that were still unprocessed when the overview was
  /// generated. The UI must show these instead of claiming full coverage.
  final List<String> unfinished;
  final DateTime? generatedAt;

  bool get isEmpty =>
      subject.trim().isEmpty &&
      conventions.trim().isEmpty &&
      chapterRelations.isEmpty &&
      themes.isEmpty;

  Map<String, dynamic> toJson() => {
    'subject': subject,
    'conventions': conventions,
    'chapterRelations': chapterRelations,
    'themes': themes,
    'unfinished': unfinished,
    'generatedAt': generatedAt?.toIso8601String(),
  };

  factory BookOverview.fromJson(Map<String, dynamic> json) => BookOverview(
    subject: json['subject'] as String? ?? '',
    conventions: json['conventions'] as String? ?? '',
    chapterRelations: [
      for (final item in json['chapterRelations'] as List? ?? const [])
        if (item is String) item,
    ],
    themes: [
      for (final item in json['themes'] as List? ?? const [])
        if (item is String) item,
    ],
    unfinished: [
      for (final item in json['unfinished'] as List? ?? const [])
        if (item is String) item,
    ],
    generatedAt: json['generatedAt'] == null
        ? null
        : DateTime.parse(json['generatedAt'] as String),
  );
}

class BookUnderstandingJob {
  const BookUnderstandingJob({
    required this.documentId,
    required this.documentHash,
    required this.status,
    this.overview,
    this.error,
    this.revision = 1,
    this.updatedAt,
    this.startedAt,
    this.finishedAt,
  });

  final String documentId;
  final String documentHash;
  final BookJobStatus status;
  final BookOverview? overview;
  final String? error;
  final int revision;
  final DateTime? updatedAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  Map<String, dynamic> toJson() => {
    'documentId': documentId,
    'documentHash': documentHash,
    'status': status.name,
    'overview': overview?.toJson(),
    'error': error,
    'revision': revision,
    'updatedAt': updatedAt?.toIso8601String(),
    'startedAt': startedAt?.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
  };

  factory BookUnderstandingJob.fromJson(Map<String, dynamic> json) =>
      BookUnderstandingJob(
        documentId: json['documentId'] as String,
        documentHash: json['documentHash'] as String,
        status: bookJobStatusFromName(json['status'] as String?),
        overview: json['overview'] is Map
            ? BookOverview.fromJson(
                Map<String, dynamic>.from(json['overview'] as Map),
              )
            : null,
        error: json['error'] as String?,
        revision: (json['revision'] as num?)?.toInt() ?? 1,
        updatedAt: json['updatedAt'] == null
            ? null
            : DateTime.parse(json['updatedAt'] as String),
        startedAt: json['startedAt'] == null
            ? null
            : DateTime.parse(json['startedAt'] as String),
        finishedAt: json['finishedAt'] == null
            ? null
            : DateTime.parse(json['finishedAt'] as String),
      );
}

/// Combined view used by the UI and by answer-coverage checks.
class UnderstandingProgress {
  const UnderstandingProgress({
    required this.pages,
    required this.status,
    required this.chapterCount,
    required this.chunkTotal,
    required this.chunkReady,
    required this.chunkFailed,
    this.overview,
    this.error,
  });

  final PageParseReport pages;
  final BookJobStatus status;
  final int chapterCount;
  final int chunkTotal;
  final int chunkReady;
  final int chunkFailed;
  final BookOverview? overview;
  final String? error;

  bool get hasWork => chunkTotal > 0 || chapterCount > 0;
  bool get chunksComplete => chunkTotal > 0 && chunkReady == chunkTotal;
  bool get complete =>
      status == BookJobStatus.complete &&
      chunkFailed == 0 &&
      chunksComplete &&
      pages.allParsed &&
      overview != null &&
      chunkTotal > 0;
  bool get running =>
      status == BookJobStatus.running || status == BookJobStatus.paused;

  String get label {
    if (status == BookJobStatus.running) {
      return chunkTotal == 0 ? '正在建立教材理解' : '正在整理 $chunkReady/$chunkTotal 块';
    }
    if (complete) return '全书已建立理解';
    if (status == BookJobStatus.failed) return '教材理解未完成';
    if (chunkTotal == 0) return '尚未建立教材理解';
    if (chunkReady == 0) return '教材理解待开始';
    return '已整理 $chunkReady/$chunkTotal 块 · 部分章节待处理';
  }

  /// Sentence used in a request preview and in the answer footer. It never
  /// upgrades a partial index to “the whole book was read”.
  String get coverageNote {
    final buffer = StringBuffer(
      '页面文字 ${pages.readyPages}/${pages.totalPages} 页可用',
    );
    if (pages.skippedPages > 0) {
      buffer.write('（已跳过 ${pages.skippedPages} 页空白）');
    }
    if (chunkTotal > 0) {
      buffer.write('；知识整理 $chunkReady/$chunkTotal 块');
      if (overview == null && chunkReady == chunkTotal && chunkTotal > 0) {
        buffer.write('；全书概览待生成');
      }
    } else {
      buffer.write('；尚未建立章节与知识点索引');
    }
    if (!pages.allParsed) {
      buffer.write('；未解析：${pages.gapLabel}');
    }
    if (!complete) {
      buffer.write('。未完成部分不能被说成书中没有。');
    }
    return buffer.toString();
  }
}
