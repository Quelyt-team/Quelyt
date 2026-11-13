import 'package:flutter/foundation.dart';

import '../../../core/models.dart';

enum NoteLifecycle { active, trashed }

NoteLifecycle noteLifecycleFrom(String value) => value == 'trashed'
    ? NoteLifecycle.trashed
    : NoteLifecycle.active;

enum NoteQuestionStatus { open, resolved }

enum NotesScope {
  all,
  recent,
  starred,
  openQuestions,
  related,
  unfiled,
  trash,
  folder,
}

enum NotesSortBy { updatedAt, createdAt, title, starred }

extension NotesSortByX on NotesSortBy {
  String get label => switch (this) {
    NotesSortBy.updatedAt => '最近更新',
    NotesSortBy.createdAt => '创建时间',
    NotesSortBy.title => '标题名称',
    NotesSortBy.starred => '星标优先',
  };
}

extension NotesScopeX on NotesScope {
  String get label => switch (this) {
    NotesScope.all => '全部笔记',
    NotesScope.recent => '最近编辑',
    NotesScope.starred => '星标',
    NotesScope.openQuestions => '待解决问题',
    NotesScope.related => '关联资料',
    NotesScope.unfiled => '未归档',
    NotesScope.trash => '回收站',
    NotesScope.folder => '文件夹',
  };
}

class NoteRecord {
  const NoteRecord({
    required this.id,
    this.title = '',
    this.body = '',
    this.bodyFormat = 'markdown',
    this.bodySchemaVersion = 1,
    this.revision = 1,
    this.starred = false,
    this.lifecycle = NoteLifecycle.active,
    this.deletedBatch,
    this.trashedAt,
    required this.createdAt,
    required this.updatedAt,
    this.lastOpenedAt,
  });

  final String id;
  final String title;
  final String body;
  final String bodyFormat;
  final int bodySchemaVersion;
  final int revision;
  final bool starred;
  final NoteLifecycle lifecycle;
  final String? deletedBatch;
  final DateTime? trashedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? lastOpenedAt;

  bool get isActive => lifecycle == NoteLifecycle.active;
  bool get isTrashed => lifecycle == NoteLifecycle.trashed;
  String get displayTitle => title.trim().isEmpty ? '未命名笔记' : title.trim();

  String get plainText {
    var value = body;
    value = value.replaceAll(RegExp(r'```[\s\S]*?```'), ' ');
    value = value.replaceAll(RegExp(r'[#>*_~`|]'), '');
    value = value.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), ' ');
    value = value.replaceAll(RegExp(r'\[([^\]]*)\]\([^)]*\)'), r'$1');
    value = value.replaceAll(RegExp(r'\s+'), ' ');
    return value.trim();
  }

  NoteRecord copyWith({
    String? title,
    String? body,
    String? bodyFormat,
    int? bodySchemaVersion,
    int? revision,
    bool? starred,
    NoteLifecycle? lifecycle,
    String? deletedBatch,
    bool clearDeletedBatch = false,
    DateTime? trashedAt,
    bool clearTrashedAt = false,
    DateTime? updatedAt,
    DateTime? lastOpenedAt,
  }) => NoteRecord(
    id: id,
    title: title ?? this.title,
    body: body ?? this.body,
    bodyFormat: bodyFormat ?? this.bodyFormat,
    bodySchemaVersion: bodySchemaVersion ?? this.bodySchemaVersion,
    revision: revision ?? this.revision,
    starred: starred ?? this.starred,
    lifecycle: lifecycle ?? this.lifecycle,
    deletedBatch: clearDeletedBatch ? null : deletedBatch ?? this.deletedBatch,
    trashedAt: clearTrashedAt ? null : trashedAt ?? this.trashedAt,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'body': body,
    'bodyFormat': bodyFormat,
    'bodySchemaVersion': bodySchemaVersion,
    'revision': revision,
    'starred': starred,
    'lifecycle': lifecycle.name,
    'deletedBatch': deletedBatch,
    'trashedAt': trashedAt?.toIso8601String(),
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'lastOpenedAt': lastOpenedAt?.toIso8601String(),
  };

  factory NoteRecord.fromJson(Map<String, dynamic> json) => NoteRecord(
    id: json['id'] as String,
    title: json['title'] as String? ?? '',
    body: json['body'] as String? ?? '',
    bodyFormat: json['bodyFormat'] as String? ?? 'markdown',
    bodySchemaVersion: (json['bodySchemaVersion'] as num?)?.toInt() ?? 1,
    revision: (json['revision'] as num?)?.toInt() ?? 1,
    starred: json['starred'] as bool? ?? false,
    lifecycle: noteLifecycleFrom(json['lifecycle'] as String? ?? 'active'),
    deletedBatch: json['deletedBatch'] as String?,
    trashedAt: _date(json['trashedAt']),
    createdAt: _date(json['createdAt']) ?? DateTime.now(),
    updatedAt: _date(json['updatedAt']) ?? DateTime.now(),
    lastOpenedAt: _date(json['lastOpenedAt']),
  );
}

class NoteEntry {
  const NoteEntry({
    required this.id,
    required this.noteId,
    this.folderId,
    this.isShortcut = false,
    this.alias,
    this.sortKey = 0,
    required this.createdAt,
  });

  final String id;
  final String noteId;
  final String? folderId;
  final bool isShortcut;
  final String? alias;
  final int sortKey;
  final DateTime createdAt;
}

class NoteSource {
  const NoteSource({
    required this.id,
    required this.noteId,
    this.documentId,
    this.documentHash = '',
    this.page,
    this.region = SourceRegion.fullPage,
    this.excerpt = '',
    this.sourceType = 'document',
    this.title = '',
    required this.createdAt,
  });

  final String id;
  final String noteId;
  final String? documentId;
  final String documentHash;
  final int? page;
  final SourceRegion region;
  final String excerpt;
  final String sourceType;
  final String title;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'noteId': noteId,
    'documentId': documentId,
    'documentHash': documentHash,
    'page': page,
    'region': region.toJson(),
    'excerpt': excerpt,
    'sourceType': sourceType,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
  };

  factory NoteSource.fromJson(Map<String, dynamic> json) => NoteSource(
    id: json['id'] as String,
    noteId: json['noteId'] as String,
    documentId: json['documentId'] as String?,
    documentHash: json['documentHash'] as String? ?? '',
    page: (json['page'] as num?)?.toInt(),
    region: _region(json['region']),
    excerpt: json['excerpt'] as String? ?? '',
    sourceType: json['sourceType'] as String? ?? 'document',
    title: json['title'] as String? ?? '',
    createdAt: _date(json['createdAt']) ?? DateTime.now(),
  );
}

class NoteQuestion {
  const NoteQuestion({
    required this.id,
    required this.noteId,
    required this.text,
    this.status = NoteQuestionStatus.open,
    required this.createdAt,
    this.resolvedAt,
  });

  final String id;
  final String noteId;
  final String text;
  final NoteQuestionStatus status;
  final DateTime createdAt;
  final DateTime? resolvedAt;

  bool get isOpen => status == NoteQuestionStatus.open;

  NoteQuestion copyWith({
    NoteQuestionStatus? status,
    DateTime? resolvedAt,
    bool clearResolvedAt = false,
  }) => NoteQuestion(
    id: id,
    noteId: noteId,
    text: text,
    status: status ?? this.status,
    createdAt: createdAt,
    resolvedAt: clearResolvedAt ? null : resolvedAt ?? this.resolvedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'noteId': noteId,
    'text': text,
    'status': status.name,
    'createdAt': createdAt.toIso8601String(),
    'resolvedAt': resolvedAt?.toIso8601String(),
  };

  factory NoteQuestion.fromJson(Map<String, dynamic> json) => NoteQuestion(
    id: json['id'] as String,
    noteId: json['noteId'] as String,
    text: json['text'] as String? ?? '',
    status: json['status'] == 'resolved'
        ? NoteQuestionStatus.resolved
        : NoteQuestionStatus.open,
    createdAt: _date(json['createdAt']) ?? DateTime.now(),
    resolvedAt: _date(json['resolvedAt']),
  );
}

class NoteRevision {
  const NoteRevision({
    required this.id,
    required this.noteId,
    required this.revision,
    required this.title,
    required this.body,
    this.reason = 'auto',
    required this.createdAt,
    this.manual = false,
  });

  final String id;
  final String noteId;
  final int revision;
  final String title;
  final String body;
  final String reason;
  final DateTime createdAt;
  final bool manual;

  Map<String, dynamic> toJson() => {
    'id': id,
    'noteId': noteId,
    'revision': revision,
    'title': title,
    'body': body,
    'reason': reason,
    'createdAt': createdAt.toIso8601String(),
    'manual': manual,
  };

  factory NoteRevision.fromJson(Map<String, dynamic> json) => NoteRevision(
    id: json['id'] as String,
    noteId: json['noteId'] as String,
    revision: (json['revision'] as num?)?.toInt() ?? 1,
    title: json['title'] as String? ?? '',
    body: json['body'] as String? ?? '',
    reason: json['reason'] as String? ?? 'auto',
    createdAt: _date(json['createdAt']) ?? DateTime.now(),
    manual: json['manual'] as bool? ?? false,
  );
}

class NoteCounts {
  const NoteCounts({
    this.all = 0,
    this.starred = 0,
    this.unfiled = 0,
    this.trash = 0,
    this.openQuestions = 0,
    this.related = 0,
  });

  final int all;
  final int starred;
  final int unfiled;
  final int trash;
  final int openQuestions;
  final int related;

  int forFolder(int count) => count;
}

class NoteItem {
  const NoteItem({
    required this.note,
    required this.entry,
    this.sources = const [],
    this.questions = const [],
    this.tagIds = const {},
  });

  final NoteRecord note;
  final NoteEntry entry;
  final List<NoteSource> sources;
  final List<NoteQuestion> questions;
  final Set<String> tagIds;

  int get openQuestions => questions.where((q) => q.isOpen).length;
  NoteSource? get primarySource =>
      sources.isEmpty ? null : sources.first;
}

class NoteListSummary {
  const NoteListSummary({
    this.primarySource,
    this.openQuestions = 0,
    this.tagIds = const {},
    this.folderId,
  });

  final NoteSource? primarySource;
  final int openQuestions;
  final Set<String> tagIds;
  final String? folderId;

  String? get sourceLabel {
    final source = primarySource;
    if (source == null || source.documentId == null) return null;
    final name = source.title.trim().isEmpty ? '资料' : source.title.trim();
    return source.page == null ? name : '$name · P.${source.page}';
  }
}

class NotesException implements Exception {
  const NotesException(this.message);
  final String message;
  @override
  String toString() => message;
}

DateTime? _date(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  if (value is String && value.isNotEmpty) return DateTime.tryParse(value);
  return null;
}

SourceRegion _region(Object? value) {
  if (value is! Map) return SourceRegion.fullPage;
  try {
    return SourceRegion.fromJson(Map<String, dynamic>.from(value));
  } catch (_) {
    return SourceRegion.fullPage;
  }
}

@immutable
class NoteTemplate {
  const NoteTemplate(this.name, this.hint, this.body);
  final String name;
  final String hint;
  final String body;
}

const noteTemplates = <NoteTemplate>[
  NoteTemplate('空白', '从零开始', ''),
  NoteTemplate(
    '概念理解',
    '定义、自己的解释、疑问',
    '## 概念\n\n**定义**：\n\n**我的理解**：\n\n**例子**：\n\n**还没想通**：\n',
  ),
  NoteTemplate(
    '章节总结',
    '本章结构、要点、待补',
    '## 章节\n\n### 一句话总结\n\n### 关键结构\n- \n\n### 需要回看\n- \n',
  ),
  NoteTemplate(
    '论文精读',
    '问题、方法、证据、局限',
    '## 研究问题\n\n## 方法\n\n## 主要证据\n\n## 我的评价\n\n## 局限与后续\n',
  ),
  NoteTemplate(
    '错题反思',
    '错因、正确思路、再练',
    '## 题目\n\n## 我的错误\n\n## 正确思路\n\n## 触发原因\n\n## 下次怎么避免\n',
  ),
  NoteTemplate(
    '每日学习',
    '日期、目标、总结、问题',
    '## 今日学习\n\n- 日期：\n- 目标：\n\n## 总结\n\n## 待解决问题\n- \n',
  ),
];
