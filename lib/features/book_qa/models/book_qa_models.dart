import '../../../core/models.dart';
import '../../../services/ai_types.dart';

enum BookAskMode { wholeBookWeb, bookOnly, currentPage }

extension BookAskModeInfo on BookAskMode {
  String get label => switch (this) {
    BookAskMode.wholeBookWeb => '全书＋联网',
    BookAskMode.bookOnly => '仅依据教材',
    BookAskMode.currentPage => '只看当前页',
  };

  String get description => switch (this) {
    BookAskMode.wholeBookWeb => '检索整本教材，并联网补充教材没有展开的机理与资料。',
    BookAskMode.bookOnly => '只使用已解析的教材原文，不发送任何网络搜索。',
    BookAskMode.currentPage => '只取当前页及其相邻页，适合“这里”“这个公式”等指代问题。',
  };

  bool get allowsWeb => this == BookAskMode.wholeBookWeb;
}

enum AnswerStatus { answered, partial, needsClarification }

AnswerStatus answerStatusFromName(String? name) =>
    AnswerStatus.values.firstWhere(
      (value) => value.name == name,
      orElse: () => AnswerStatus.partial,
    );

extension AnswerStatusInfo on AnswerStatus {
  String get label => switch (this) {
    AnswerStatus.answered => '已回答',
    AnswerStatus.partial => '部分回答',
    AnswerStatus.needsClarification => '需要补充条件',
  };
}

/// How the network step actually ended. This is decided by the client from
/// real requests, never by the model's self-report.
enum WebLookupStatus { searched, cached, notNeeded, disabled, failed }

WebLookupStatus webLookupStatusFromName(String? name) =>
    WebLookupStatus.values.firstWhere(
      (value) => value.name == name,
      orElse: () => WebLookupStatus.notNeeded,
    );

extension WebLookupStatusInfo on WebLookupStatus {
  String get label => switch (this) {
    WebLookupStatus.searched => '已联网检索',
    WebLookupStatus.cached => '使用已缓存网页',
    WebLookupStatus.notNeeded => '本次无需联网',
    WebLookupStatus.disabled => '未联网',
    WebLookupStatus.failed => '联网未完成',
  };
}

/// The part of a question's factual basis that really came from the book.
class BookCoverage {
  const BookCoverage({
    required this.scope,
    required this.wholeBookSearched,
    required this.understandingComplete,
    required this.parsedPages,
    required this.totalPages,
    this.hitChapters = const [],
    this.gaps = const [],
    this.note = '',
  });

  final String scope;
  final bool wholeBookSearched;
  final bool understandingComplete;
  final int parsedPages;
  final int totalPages;
  final List<String> hitChapters;

  /// Human-readable gaps, for example “第 41–60 页（待识别）” or
  /// “第 8 章尚未整理”.
  final List<String> gaps;
  final String note;

  bool get allPagesParsed => parsedPages >= totalPages;
  bool get canClaimFullCheck =>
      wholeBookSearched && allPagesParsed && understandingComplete;

  String get summary {
    final buffer = StringBuffer(scope);
    if (hitChapters.isNotEmpty) {
      buffer.write(' · 命中${hitChapters.take(3).join('、')}');
    }
    if (gaps.isNotEmpty) {
      buffer.write(' · 缺口：${gaps.take(3).join('；')}');
    }
    return buffer.toString();
  }

  Map<String, dynamic> toJson() => {
    'scope': scope,
    'wholeBookSearched': wholeBookSearched,
    'understandingComplete': understandingComplete,
    'parsedPages': parsedPages,
    'totalPages': totalPages,
    'hitChapters': hitChapters,
    'gaps': gaps,
    'note': note,
  };

  factory BookCoverage.fromJson(Map<String, dynamic> json) => BookCoverage(
    scope: json['scope'] as String? ?? '',
    wholeBookSearched: json['wholeBookSearched'] as bool? ?? false,
    understandingComplete: json['understandingComplete'] as bool? ?? false,
    parsedPages: (json['parsedPages'] as num?)?.toInt() ?? 0,
    totalPages: (json['totalPages'] as num?)?.toInt() ?? 0,
    hitChapters: [
      for (final item in json['hitChapters'] as List? ?? const [])
        if (item is String) item,
    ],
    gaps: [
      for (final item in json['gaps'] as List? ?? const [])
        if (item is String) item,
    ],
    note: json['note'] as String? ?? '',
  );
}

/// A book citation. It keeps the exact excerpt and original-page region that
/// were sent, so a later OCR correction cannot silently change what was cited.
class BookCitation {
  const BookCitation({
    required this.id,
    required this.evidence,
    this.chapterTitle = '',
  });

  final String id;
  final Evidence evidence;
  final String chapterTitle;

  int get page => evidence.page;
  SourceRegion get region => evidence.region;

  Map<String, dynamic> toJson() => {
    'id': id,
    'evidence': evidence.toJson(),
    'chapterTitle': chapterTitle,
  };

  factory BookCitation.fromJson(Map<String, dynamic> json) => BookCitation(
    id: json['id'] as String,
    evidence: Evidence.fromJson(
      Map<String, dynamic>.from(json['evidence'] as Map),
    ),
    chapterTitle: json['chapterTitle'] as String? ?? '',
  );
}

/// A web source that was actually returned by a search or fetch request (or
/// served from the local cache, clearly marked).
class WebCitation {
  const WebCitation({
    required this.id,
    required this.title,
    required this.url,
    required this.excerpt,
    required this.fetchedAt,
    this.siteName = '',
    this.publishedAt,
    this.fullText = false,
    this.fromCache = false,
    this.searchQuery = '',
  });

  final String id;
  final String title;
  final String url;
  final String excerpt;
  final DateTime fetchedAt;
  final String siteName;
  final String? publishedAt;
  final bool fullText;
  final bool fromCache;
  final String searchQuery;

  String get host {
    final uri = Uri.tryParse(url);
    return uri == null ? '' : uri.host;
  }

  String get statusLabel {
    if (fromCache) return '缓存正文';
    return fullText ? '已读正文' : '仅摘要';
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'url': url,
    'excerpt': excerpt,
    'fetchedAt': fetchedAt.toIso8601String(),
    'siteName': siteName,
    'publishedAt': publishedAt,
    'fullText': fullText,
    'fromCache': fromCache,
    'searchQuery': searchQuery,
  };

  factory WebCitation.fromJson(Map<String, dynamic> json) => WebCitation(
    id: json['id'] as String,
    title: json['title'] as String? ?? '',
    url: json['url'] as String? ?? '',
    excerpt: json['excerpt'] as String? ?? '',
    fetchedAt: DateTime.parse(json['fetchedAt'] as String),
    siteName: json['siteName'] as String? ?? '',
    publishedAt: json['publishedAt'] as String?,
    fullText: json['fullText'] as bool? ?? false,
    fromCache: json['fromCache'] as bool? ?? false,
    searchQuery: json['searchQuery'] as String? ?? '',
  );
}

class BookAnswerBlock {
  const BookAnswerBlock({
    required this.text,
    this.bookCitationIds = const [],
    this.webCitationIds = const [],
    this.supplemental = false,
  });

  final String text;
  final List<String> bookCitationIds;
  final List<String> webCitationIds;

  /// True for reasoning or background that is neither a direct textbook
  /// conclusion nor a quoted external source.
  final bool supplemental;

  Map<String, dynamic> toJson() => {
    'text': text,
    'bookCitations': bookCitationIds,
    'webCitations': webCitationIds,
    'supplemental': supplemental,
  };

  factory BookAnswerBlock.fromJson(Map<String, dynamic> json) =>
      BookAnswerBlock(
        text: json['text'] as String? ?? '',
        bookCitationIds: [
          for (final item in json['bookCitations'] as List? ?? const [])
            if (item is String) item,
        ],
        webCitationIds: [
          for (final item in json['webCitations'] as List? ?? const [])
            if (item is String) item,
        ],
        supplemental: json['supplemental'] as bool? ?? false,
      );
}

enum BookQaStage {
  idle,
  retrievingBook,
  searchingWeb,
  readingWeb,
  composing,
  done,
}

extension BookQaStageInfo on BookQaStage {
  String get label => switch (this) {
    BookQaStage.idle => '',
    BookQaStage.retrievingBook => '查找教材',
    BookQaStage.searchingWeb => '检索网络',
    BookQaStage.readingWeb => '阅读来源',
    BookQaStage.composing => '整理回答',
    BookQaStage.done => '完成',
  };
}

class BookQaUsage {
  const BookQaUsage({
    this.answer,
    this.searchRequests = 0,
    this.fetchRequests = 0,
    this.cachedSources = 0,
  });

  final TokenUsage? answer;
  final int searchRequests;
  final int fetchRequests;
  final int cachedSources;

  int get totalTokens => answer?.totalTokens ?? 0;

  Map<String, dynamic> toJson() => {
    'answer': answer?.toJson(),
    'searchRequests': searchRequests,
    'fetchRequests': fetchRequests,
    'cachedSources': cachedSources,
  };

  factory BookQaUsage.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const BookQaUsage();
    return BookQaUsage(
      answer: json['answer'] is Map
          ? TokenUsage.fromJson(
              Map<String, dynamic>.from(json['answer'] as Map),
            )
          : null,
      searchRequests: (json['searchRequests'] as num?)?.toInt() ?? 0,
      fetchRequests: (json['fetchRequests'] as num?)?.toInt() ?? 0,
      cachedSources: (json['cachedSources'] as num?)?.toInt() ?? 0,
    );
  }
}

class BookQaAnswer {
  BookQaAnswer({
    required this.answerStatus,
    required List<BookAnswerBlock> blocks,
    required this.coverage,
    required this.webStatus,
    required List<BookCitation> bookSources,
    required List<WebCitation> webSources,
    required this.usage,
    required this.model,
    required this.provider,
    required this.requestId,
    this.webNote = '',
    List<String> missingInformation = const [],
    List<String> rejectedCitationIds = const [],
    List<String> searchQueries = const [],
    DateTime? createdAt,
  }) : blocks = List.unmodifiable(blocks),
       bookSources = List.unmodifiable(bookSources),
       webSources = List.unmodifiable(webSources),
       missingInformation = List.unmodifiable(missingInformation),
       rejectedCitationIds = List.unmodifiable(rejectedCitationIds),
       searchQueries = List.unmodifiable(searchQueries),
       createdAt = createdAt ?? DateTime.now();

  final AnswerStatus answerStatus;
  final List<BookAnswerBlock> blocks;
  final BookCoverage coverage;
  final WebLookupStatus webStatus;
  final List<BookCitation> bookSources;
  final List<WebCitation> webSources;
  final BookQaUsage usage;
  final String model;
  final String provider;
  final String requestId;
  final String webNote;
  final List<String> missingInformation;
  final List<String> rejectedCitationIds;
  final List<String> searchQueries;
  final DateTime createdAt;

  String get plainText => blocks.map((block) => block.text).join('\n\n');
  bool get requiresVerification => rejectedCitationIds.isNotEmpty;

  BookQaAnswer copyWith({
    AnswerStatus? answerStatus,
    List<BookAnswerBlock>? blocks,
    BookCoverage? coverage,
    WebLookupStatus? webStatus,
    List<BookCitation>? bookSources,
    List<WebCitation>? webSources,
    BookQaUsage? usage,
    String? webNote,
    List<String>? missingInformation,
    List<String>? rejectedCitationIds,
    List<String>? searchQueries,
  }) => BookQaAnswer(
    answerStatus: answerStatus ?? this.answerStatus,
    blocks: blocks ?? this.blocks,
    coverage: coverage ?? this.coverage,
    webStatus: webStatus ?? this.webStatus,
    bookSources: bookSources ?? this.bookSources,
    webSources: webSources ?? this.webSources,
    usage: usage ?? this.usage,
    model: model,
    provider: provider,
    requestId: requestId,
    webNote: webNote ?? this.webNote,
    missingInformation: missingInformation ?? this.missingInformation,
    rejectedCitationIds: rejectedCitationIds ?? this.rejectedCitationIds,
    searchQueries: searchQueries ?? this.searchQueries,
    createdAt: createdAt,
  );

  Map<String, dynamic> toJson() => {
    'answerStatus': answerStatus.name,
    'blocks': blocks.map((block) => block.toJson()).toList(),
    'coverage': coverage.toJson(),
    'webStatus': webStatus.name,
    'bookSources': bookSources.map((source) => source.toJson()).toList(),
    'webSources': webSources.map((source) => source.toJson()).toList(),
    'usage': usage.toJson(),
    'model': model,
    'provider': provider,
    'requestId': requestId,
    'webNote': webNote,
    'missingInformation': missingInformation,
    'rejectedCitationIds': rejectedCitationIds,
    'searchQueries': searchQueries,
    'createdAt': createdAt.toIso8601String(),
  };

  factory BookQaAnswer.fromJson(Map<String, dynamic> json) => BookQaAnswer(
    answerStatus: answerStatusFromName(json['answerStatus'] as String?),
    blocks: [
      for (final item in json['blocks'] as List? ?? const [])
        if (item is Map)
          BookAnswerBlock.fromJson(Map<String, dynamic>.from(item)),
    ],
    coverage: BookCoverage.fromJson(
      Map<String, dynamic>.from(json['coverage'] as Map? ?? const {}),
    ),
    webStatus: webLookupStatusFromName(json['webStatus'] as String?),
    bookSources: [
      for (final item in json['bookSources'] as List? ?? const [])
        if (item is Map) BookCitation.fromJson(Map<String, dynamic>.from(item)),
    ],
    webSources: [
      for (final item in json['webSources'] as List? ?? const [])
        if (item is Map) WebCitation.fromJson(Map<String, dynamic>.from(item)),
    ],
    usage: BookQaUsage.fromJson(
      json['usage'] is Map
          ? Map<String, dynamic>.from(json['usage'] as Map)
          : null,
    ),
    model: json['model'] as String? ?? '',
    provider: json['provider'] as String? ?? '',
    requestId: json['requestId'] as String? ?? '',
    webNote: json['webNote'] as String? ?? '',
    missingInformation: [
      for (final item in json['missingInformation'] as List? ?? const [])
        if (item is String) item,
    ],
    rejectedCitationIds: [
      for (final item in json['rejectedCitationIds'] as List? ?? const [])
        if (item is String) item,
    ],
    searchQueries: [
      for (final item in json['searchQueries'] as List? ?? const [])
        if (item is String) item,
    ],
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}

/// A page whose text was actually retrieved from the web, kept locally so the
/// same source can be reused without another billable fetch.
class WebCacheEntry {
  const WebCacheEntry({
    required this.url,
    required this.title,
    required this.content,
    required this.fetchedAt,
    this.siteName = '',
    this.publishedAt,
  });

  final String url;
  final String title;
  final String content;
  final DateTime fetchedAt;
  final String siteName;
  final String? publishedAt;

  Map<String, dynamic> toJson() => {
    'url': url,
    'title': title,
    'content': content,
    'fetchedAt': fetchedAt.toIso8601String(),
    'siteName': siteName,
    'publishedAt': publishedAt,
  };

  factory WebCacheEntry.fromJson(Map<String, dynamic> json) => WebCacheEntry(
    url: json['url'] as String,
    title: json['title'] as String? ?? '',
    content: json['content'] as String? ?? '',
    fetchedAt: DateTime.parse(json['fetchedAt'] as String),
    siteName: json['siteName'] as String? ?? '',
    publishedAt: json['publishedAt'] as String?,
  );
}

class BookConversation {
  const BookConversation({
    required this.id,
    required this.documentId,
    required this.documentHash,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String documentId;
  final String documentHash;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;

  BookConversation copyWith({String? title, DateTime? updatedAt}) =>
      BookConversation(
        id: id,
        documentId: documentId,
        documentHash: documentHash,
        title: title ?? this.title,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'documentId': documentId,
    'documentHash': documentHash,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory BookConversation.fromJson(Map<String, dynamic> json) =>
      BookConversation(
        id: json['id'] as String,
        documentId: json['documentId'] as String,
        documentHash: json['documentHash'] as String,
        title: json['title'] as String? ?? '',
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
      );
}

class BookQaTurn {
  const BookQaTurn({
    required this.id,
    required this.conversationId,
    required this.sequence,
    required this.question,
    required this.askedAt,
    this.mode = BookAskMode.wholeBookWeb,
    this.answer,
    this.failure,
    this.cancelled = false,
  });

  final String id;
  final String conversationId;
  final int sequence;
  final String question;
  final DateTime askedAt;
  final BookAskMode mode;
  final BookQaAnswer? answer;
  final String? failure;
  final bool cancelled;

  bool get pending => answer == null && failure == null && !cancelled;
  int get answerSequence => sequence + 1;

  Map<String, dynamic> toQuestionJson() => {
    'question': question,
    'askedAt': askedAt.toIso8601String(),
    'mode': mode.name,
  };

  factory BookQaTurn.fromQuestionJson({
    required String id,
    required String conversationId,
    required int sequence,
    required Map<String, dynamic> json,
  }) => BookQaTurn(
    id: id,
    conversationId: conversationId,
    sequence: sequence,
    question: json['question'] as String? ?? '',
    askedAt: DateTime.parse(json['askedAt'] as String),
    mode: BookAskMode.values.firstWhere(
      (value) => value.name == json['mode'],
      orElse: () => BookAskMode.wholeBookWeb,
    ),
  );

  BookQaTurn withAnswer(BookQaAnswer value) => BookQaTurn(
    id: id,
    conversationId: conversationId,
    sequence: sequence,
    question: question,
    askedAt: askedAt,
    mode: mode,
    answer: value,
  );

  BookQaTurn withFailure(String message) => BookQaTurn(
    id: id,
    conversationId: conversationId,
    sequence: sequence,
    question: question,
    askedAt: askedAt,
    mode: mode,
    failure: message,
  );

  BookQaTurn withCancelled() => BookQaTurn(
    id: id,
    conversationId: conversationId,
    sequence: sequence,
    question: question,
    askedAt: askedAt,
    mode: mode,
    cancelled: true,
  );
}
