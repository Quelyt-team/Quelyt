/// The learner's chosen study mode, not a required classification.
///
/// Import never asks for this value: [unspecified] is a first-class state that
/// opens the general reading-and-Q&A path. Textbook self-study and paper close
/// reading are opt-in switches inside the reader. The name and stored values
/// stay compatible with the v0.1 library, where only textbook and paper
/// existed.
enum DocumentKind { unspecified, textbook, paper }

extension DocumentKindX on DocumentKind {
  String get label => switch (this) {
    DocumentKind.textbook => '教材自学',
    DocumentKind.paper => '论文精读',
    DocumentKind.unspecified => '阅读与问答',
  };

  bool get isSpecified => this != DocumentKind.unspecified;

  /// Unknown or missing legacy values degrade to the general path instead of
  /// silently becoming "paper", which the old binary branch implied.
  static DocumentKind parse(Object? value) =>
      DocumentKind.values.asNameMap()[value as String? ?? ''] ??
      DocumentKind.unspecified;
}

/// Where a document is in its local lifecycle. Search, AI requests, plans and
/// ordinary lists only read [active]; history may read the other states with an
/// explicit explanation.
enum DocumentLifecycle {
  active,
  trashed,
  purging;

  static DocumentLifecycle parse(Object? value) =>
      DocumentLifecycle.values.asNameMap()[value as String? ?? ''] ?? active;
}

enum EvidenceOrigin { text, ocr, manual }

enum PageStatus { pending, ready, needsOcr, failed }

/// A rectangle in the original page, normalized to [0, 1], with a top-left
/// origin. It is independent of viewport zoom and display rotation.
class SourceRegion {
  const SourceRegion(this.left, this.top, this.right, this.bottom)
    : assert(left >= 0 && left < right && right <= 1),
      assert(top >= 0 && top < bottom && bottom <= 1);

  static const fullPage = SourceRegion(0, 0, 1, 1);
  final double left;
  final double top;
  final double right;
  final double bottom;

  double get width => right - left;
  double get height => bottom - top;
  bool get isValid =>
      left.isFinite &&
      top.isFinite &&
      right.isFinite &&
      bottom.isFinite &&
      left >= 0 &&
      top >= 0 &&
      right <= 1 &&
      bottom <= 1 &&
      right > left &&
      bottom > top;

  bool intersects(SourceRegion other) =>
      left < other.right &&
      right > other.left &&
      top < other.bottom &&
      bottom > other.top;

  SourceRegion rotateClockwise() =>
      SourceRegion(1 - bottom, left, 1 - top, right);

  SourceRegion copyWith({
    double? left,
    double? top,
    double? right,
    double? bottom,
  }) => SourceRegion(
    left ?? this.left,
    top ?? this.top,
    right ?? this.right,
    bottom ?? this.bottom,
  );

  Map<String, dynamic> toJson() => {
    'left': left,
    'top': top,
    'right': right,
    'bottom': bottom,
  };

  factory SourceRegion.fromJson(Map<String, dynamic> json) {
    final region = SourceRegion(
      (json['left'] as num).toDouble(),
      (json['top'] as num).toDouble(),
      (json['right'] as num).toDouble(),
      (json['bottom'] as num).toDouble(),
    );
    if (!region.isValid) {
      throw const FormatException('Invalid source region');
    }
    return region;
  }

  @override
  bool operator ==(Object other) =>
      other is SourceRegion &&
      left == other.left &&
      top == other.top &&
      right == other.right &&
      bottom == other.bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);
}

DateTime _date(dynamic value) => DateTime.parse(value as String);
Map<String, dynamic> _map(dynamic value) =>
    Map<String, dynamic>.from(value as Map);

class DocumentRecord {
  DocumentRecord({
    required this.id,
    required this.title,
    required this.kind,
    required this.filePath,
    required this.contentHash,
    this.pageCount = 1,
    this.currentPage = 1,
    this.originalName = '',
    this.format = '',
    this.sizeBytes = 0,
    this.lifecycle = DocumentLifecycle.active,
    this.lifecycleVersion = 1,
    this.starred = false,
    this.deletedBatch,
    this.trashedAt,
    DateTime? createdAt,
    DateTime? addedAt,
    DateTime? lastOpenedAt,
  }) : createdAt = createdAt ?? addedAt ?? DateTime.now(),
       addedAt = addedAt ?? createdAt ?? DateTime.now(),
       lastOpenedAt = lastOpenedAt ?? createdAt ?? DateTime.now();

  final String id;
  final String title;

  /// Legacy storage column, reinterpreted as the learning-mode preference.
  final DocumentKind kind;
  final String filePath;
  final String contentHash;
  final int pageCount;
  final int currentPage;

  /// The name the user's file had on their own disk. Renaming the display title
  /// never rewrites this and never touches the external file.
  final String originalName;

  /// File format without the leading dot, e.g. `pdf`, `png`.
  final String format;
  final int sizeBytes;
  final DocumentLifecycle lifecycle;

  /// Bumped on every lifecycle transition. Background work captures it and
  /// refuses to write results produced for an older state.
  final int lifecycleVersion;
  final bool starred;
  final String? deletedBatch;
  final DateTime? trashedAt;
  final DateTime createdAt;
  final DateTime addedAt;
  final DateTime lastOpenedAt;

  bool get isActive => lifecycle == DocumentLifecycle.active;
  bool get isTrashed => lifecycle == DocumentLifecycle.trashed;
  bool get isPurging => lifecycle == DocumentLifecycle.purging;

  DocumentRecord copyWith({
    String? id,
    String? title,
    DocumentKind? kind,
    String? filePath,
    String? contentHash,
    int? pageCount,
    int? currentPage,
    String? originalName,
    String? format,
    int? sizeBytes,
    DocumentLifecycle? lifecycle,
    int? lifecycleVersion,
    bool? starred,
    String? deletedBatch,
    bool clearDeletedBatch = false,
    DateTime? trashedAt,
    bool clearTrashedAt = false,
    DateTime? createdAt,
    DateTime? addedAt,
    DateTime? lastOpenedAt,
  }) => DocumentRecord(
    id: id ?? this.id,
    title: title ?? this.title,
    kind: kind ?? this.kind,
    filePath: filePath ?? this.filePath,
    contentHash: contentHash ?? this.contentHash,
    pageCount: pageCount ?? this.pageCount,
    currentPage: currentPage ?? this.currentPage,
    originalName: originalName ?? this.originalName,
    format: format ?? this.format,
    sizeBytes: sizeBytes ?? this.sizeBytes,
    lifecycle: lifecycle ?? this.lifecycle,
    lifecycleVersion: lifecycleVersion ?? this.lifecycleVersion,
    starred: starred ?? this.starred,
    deletedBatch: clearDeletedBatch
        ? null
        : deletedBatch ?? this.deletedBatch,
    trashedAt: clearTrashedAt ? null : trashedAt ?? this.trashedAt,
    createdAt: createdAt ?? this.createdAt,
    addedAt: addedAt ?? this.addedAt,
    lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'kind': kind.name,
    'filePath': filePath,
    'contentHash': contentHash,
    'pageCount': pageCount,
    'currentPage': currentPage,
    'originalName': originalName,
    'format': format,
    'sizeBytes': sizeBytes,
    'lifecycle': lifecycle.name,
    'lifecycleVersion': lifecycleVersion,
    'starred': starred,
    'deletedBatch': deletedBatch,
    'trashedAt': trashedAt?.toIso8601String(),
    'createdAt': createdAt.toIso8601String(),
    'addedAt': addedAt.toIso8601String(),
    'lastOpenedAt': lastOpenedAt.toIso8601String(),
  };

  factory DocumentRecord.fromJson(Map<String, dynamic> json) => DocumentRecord(
    id: json['id'] as String,
    title: json['title'] as String,
    kind: DocumentKindX.parse(json['kind']),
    filePath: json['filePath'] as String,
    contentHash: json['contentHash'] as String,
    pageCount: json['pageCount'] as int,
    currentPage: json['currentPage'] as int,
    originalName: json['originalName'] as String? ?? '',
    format: json['format'] as String? ?? '',
    sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
    lifecycle: DocumentLifecycle.parse(json['lifecycle']),
    lifecycleVersion: (json['lifecycleVersion'] as num?)?.toInt() ?? 1,
    starred: json['starred'] as bool? ?? false,
    deletedBatch: json['deletedBatch'] as String?,
    trashedAt: json['trashedAt'] == null
        ? null
        : _date(json['trashedAt']),
    createdAt: _date(json['createdAt']),
    addedAt: json['addedAt'] == null ? null : _date(json['addedAt']),
    lastOpenedAt: _date(json['lastOpenedAt']),
  );
}

class Evidence {
  const Evidence({
    required this.id,
    required this.documentId,
    required this.documentHash,
    required this.page,
    required this.region,
    required this.text,
    this.origin = EvidenceOrigin.text,
    this.confidence,
  });

  final String id;
  final String documentId;
  final String documentHash;
  final int page;
  final SourceRegion region;
  final String text;
  final EvidenceOrigin origin;
  final double? confidence;

  Evidence copyWith({
    String? id,
    String? documentId,
    String? documentHash,
    int? page,
    SourceRegion? region,
    String? text,
    EvidenceOrigin? origin,
    double? confidence,
  }) => Evidence(
    id: id ?? this.id,
    documentId: documentId ?? this.documentId,
    documentHash: documentHash ?? this.documentHash,
    page: page ?? this.page,
    region: region ?? this.region,
    text: text ?? this.text,
    origin: origin ?? this.origin,
    confidence: confidence ?? this.confidence,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'documentId': documentId,
    'documentHash': documentHash,
    'page': page,
    'region': region.toJson(),
    'text': text,
    'origin': origin.name,
    'confidence': confidence,
  };

  factory Evidence.fromJson(Map<String, dynamic> json) => Evidence(
    id: json['id'] as String,
    documentId: json['documentId'] as String,
    documentHash: json['documentHash'] as String,
    page: json['page'] as int,
    region: SourceRegion.fromJson(_map(json['region'])),
    text: json['text'] as String,
    origin: EvidenceOrigin.values.byName(json['origin'] as String),
    confidence: (json['confidence'] as num?)?.toDouble(),
  );
}

class PageRecord {
  const PageRecord({
    required this.documentId,
    required this.page,
    this.text = '',
    this.status = PageStatus.pending,
    this.error,
    this.manuallyCorrected = false,
  });

  final String documentId;
  final int page;
  final String text;
  final PageStatus status;
  final String? error;
  final bool manuallyCorrected;

  PageRecord copyWith({
    String? documentId,
    int? page,
    String? text,
    PageStatus? status,
    String? error,
    bool clearError = false,
    bool? manuallyCorrected,
  }) => PageRecord(
    documentId: documentId ?? this.documentId,
    page: page ?? this.page,
    text: text ?? this.text,
    status: status ?? this.status,
    error: clearError ? null : error ?? this.error,
    manuallyCorrected: manuallyCorrected ?? this.manuallyCorrected,
  );

  Map<String, dynamic> toJson() => {
    'documentId': documentId,
    'page': page,
    'text': text,
    'status': status.name,
    'error': error,
    'manuallyCorrected': manuallyCorrected,
  };

  factory PageRecord.fromJson(Map<String, dynamic> json) => PageRecord(
    documentId: json['documentId'] as String,
    page: json['page'] as int,
    text: json['text'] as String,
    status: PageStatus.values.byName(json['status'] as String),
    error: json['error'] as String?,
    manuallyCorrected: json['manuallyCorrected'] as bool? ?? false,
  );
}

class StudyNote {
  StudyNote({
    required this.id,
    required this.documentId,
    required this.page,
    this.documentHash = '',
    this.region = SourceRegion.fullPage,
    this.understanding = '',
    this.evidenceText = '',
    this.question = '',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  final String documentId;
  final String documentHash;
  final int page;
  final SourceRegion region;
  final String understanding;
  final String evidenceText;
  final String question;
  final DateTime createdAt;

  StudyNote copyWith({
    String? id,
    String? documentId,
    String? documentHash,
    int? page,
    SourceRegion? region,
    String? understanding,
    String? evidenceText,
    String? question,
    DateTime? createdAt,
  }) => StudyNote(
    id: id ?? this.id,
    documentId: documentId ?? this.documentId,
    documentHash: documentHash ?? this.documentHash,
    page: page ?? this.page,
    region: region ?? this.region,
    understanding: understanding ?? this.understanding,
    evidenceText: evidenceText ?? this.evidenceText,
    question: question ?? this.question,
    createdAt: createdAt ?? this.createdAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'documentId': documentId,
    'documentHash': documentHash,
    'page': page,
    'region': region.toJson(),
    'understanding': understanding,
    'evidenceText': evidenceText,
    'question': question,
    'createdAt': createdAt.toIso8601String(),
  };

  factory StudyNote.fromJson(Map<String, dynamic> json) => StudyNote(
    id: json['id'] as String,
    documentId: json['documentId'] as String,
    documentHash: json['documentHash'] as String? ?? '',
    page: json['page'] as int,
    region: SourceRegion.fromJson(_map(json['region'])),
    understanding: json['understanding'] as String,
    evidenceText: json['evidenceText'] as String,
    question: json['question'] as String,
    createdAt: _date(json['createdAt']),
  );
}

class StudyAttempt {
  StudyAttempt({
    required this.question,
    required this.answer,
    this.feedback = '',
    this.needsReview = false,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String question;
  final String answer;
  final String feedback;
  final bool needsReview;
  final DateTime createdAt;

  StudyAttempt copyWith({
    String? question,
    String? answer,
    String? feedback,
    bool? needsReview,
    DateTime? createdAt,
  }) => StudyAttempt(
    question: question ?? this.question,
    answer: answer ?? this.answer,
    feedback: feedback ?? this.feedback,
    needsReview: needsReview ?? this.needsReview,
    createdAt: createdAt ?? this.createdAt,
  );

  Map<String, dynamic> toJson() => {
    'question': question,
    'answer': answer,
    'feedback': feedback,
    'needsReview': needsReview,
    'createdAt': createdAt.toIso8601String(),
  };

  factory StudyAttempt.fromJson(Map<String, dynamic> json) => StudyAttempt(
    question: json['question'] as String,
    answer: json['answer'] as String,
    feedback: json['feedback'] as String,
    needsReview: json['needsReview'] as bool,
    createdAt: _date(json['createdAt']),
  );
}

class StudySession {
  StudySession({
    required this.id,
    required this.documentId,
    required this.startPage,
    required this.endPage,
    this.goal = '',
    this.minutes = 25,
    this.stage = 'plan',
    this.question = '',
    this.answer = '',
    this.feedback = '',
    this.needsReview = false,
    DateTime? updatedAt,
    List<StudyAttempt> attempts = const [],
  }) : updatedAt = updatedAt ?? DateTime.now(),
       attempts = List.unmodifiable(attempts);

  final String id;
  final String documentId;
  final int startPage;
  final int endPage;
  final String goal;
  final int minutes;
  final String stage;
  final String question;
  final String answer;
  final String feedback;
  final bool needsReview;
  final DateTime updatedAt;
  final List<StudyAttempt> attempts;

  StudySession copyWith({
    String? id,
    String? documentId,
    int? startPage,
    int? endPage,
    String? goal,
    int? minutes,
    String? stage,
    String? question,
    String? answer,
    String? feedback,
    bool? needsReview,
    DateTime? updatedAt,
    List<StudyAttempt>? attempts,
  }) => StudySession(
    id: id ?? this.id,
    documentId: documentId ?? this.documentId,
    startPage: startPage ?? this.startPage,
    endPage: endPage ?? this.endPage,
    goal: goal ?? this.goal,
    minutes: minutes ?? this.minutes,
    stage: stage ?? this.stage,
    question: question ?? this.question,
    answer: answer ?? this.answer,
    feedback: feedback ?? this.feedback,
    needsReview: needsReview ?? this.needsReview,
    updatedAt: updatedAt ?? this.updatedAt,
    attempts: attempts ?? this.attempts,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'documentId': documentId,
    'startPage': startPage,
    'endPage': endPage,
    'goal': goal,
    'minutes': minutes,
    'stage': stage,
    'question': question,
    'answer': answer,
    'feedback': feedback,
    'needsReview': needsReview,
    'updatedAt': updatedAt.toIso8601String(),
    'attempts': attempts.map((attempt) => attempt.toJson()).toList(),
  };

  factory StudySession.fromJson(Map<String, dynamic> json) => StudySession(
    id: json['id'] as String,
    documentId: json['documentId'] as String,
    startPage: json['startPage'] as int,
    endPage: json['endPage'] as int,
    goal: json['goal'] as String,
    minutes: json['minutes'] as int,
    stage: json['stage'] as String,
    question: json['question'] as String,
    answer: json['answer'] as String,
    feedback: json['feedback'] as String,
    needsReview: json['needsReview'] as bool,
    updatedAt: _date(json['updatedAt']),
    attempts: (json['attempts'] as List? ?? const [])
        .map((value) => StudyAttempt.fromJson(_map(value)))
        .toList(),
  );
}
