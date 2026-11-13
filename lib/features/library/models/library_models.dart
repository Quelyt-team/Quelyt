import '../../../core/models.dart';

/// Folder names are compared case- and whitespace-insensitively inside one
/// parent. The stored display name keeps the user's spelling.
String normalizeFolderName(String name) =>
    name.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

enum FolderColorMode {
  inherit,
  custom;

  static FolderColorMode parse(Object? value) =>
      FolderColorMode.values.asNameMap()[value as String? ?? ''] ?? inherit;
}

/// An in-app classification node. It is not a directory on disk: moving or
/// renaming it never touches the managed original, so open PDF handles and
/// document ids stay stable.
class LibraryFolder {
  const LibraryFolder({
    required this.id,
    required this.name,
    required this.sortKey,
    this.parentId,
    this.colorMode = FolderColorMode.inherit,
    this.colorValue,
    this.icon,
    this.description = '',
    this.revision = 1,
    required this.createdAt,
    required this.updatedAt,
    this.deletedBatch,
    this.deletedAt,
  });

  final String id;
  final String? parentId;
  final String name;
  final int sortKey;
  final FolderColorMode colorMode;

  /// ARGB colour when [colorMode] is [FolderColorMode.custom]. Inheritance is
  /// stored as a state, never copied from the parent, so later parent changes
  /// still reach this folder.
  final int? colorValue;
  final String? icon;
  final String description;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? deletedBatch;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;
  String get nameNorm => normalizeFolderName(name);

  LibraryFolder copyWith({
    String? id,
    String? parentId,
    bool clearParent = false,
    String? name,
    int? sortKey,
    FolderColorMode? colorMode,
    int? colorValue,
    bool clearColor = false,
    String? icon,
    bool clearIcon = false,
    String? description,
    int? revision,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? deletedBatch,
    bool clearDeletedBatch = false,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
  }) => LibraryFolder(
    id: id ?? this.id,
    parentId: clearParent ? null : parentId ?? this.parentId,
    name: name ?? this.name,
    sortKey: sortKey ?? this.sortKey,
    colorMode: colorMode ?? this.colorMode,
    colorValue: clearColor ? null : colorValue ?? this.colorValue,
    icon: clearIcon ? null : icon ?? this.icon,
    description: description ?? this.description,
    revision: revision ?? this.revision,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    deletedBatch: clearDeletedBatch ? null : deletedBatch ?? this.deletedBatch,
    deletedAt: clearDeletedAt ? null : deletedAt ?? this.deletedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'parentId': parentId,
    'name': name,
    'sortKey': sortKey,
    'colorMode': colorMode.name,
    'colorValue': colorValue,
    'icon': icon,
    'description': description,
    'revision': revision,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'deletedBatch': deletedBatch,
    'deletedAt': deletedAt?.toIso8601String(),
  };

  factory LibraryFolder.fromJson(Map<String, dynamic> json) => LibraryFolder(
    id: json['id'] as String,
    parentId: json['parentId'] as String?,
    name: json['name'] as String,
    sortKey: (json['sortKey'] as num?)?.toInt() ?? 0,
    colorMode: FolderColorMode.parse(json['colorMode']),
    colorValue: (json['colorValue'] as num?)?.toInt(),
    icon: json['icon'] as String?,
    description: json['description'] as String? ?? '',
    revision: (json['revision'] as num?)?.toInt() ?? 1,
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
    deletedBatch: json['deletedBatch'] as String?,
    deletedAt: json['deletedAt'] == null
        ? null
        : DateTime.parse(json['deletedAt'] as String),
  );
}

/// One placement of a document: [isShortcut] false is its single primary
/// location, true is an additional entry that shares the same original, notes,
/// Q&A and reading progress.
class DocumentEntry {
  const DocumentEntry({
    required this.id,
    required this.documentId,
    this.folderId,
    this.isShortcut = false,
    this.alias,
    required this.sortKey,
    required this.createdAt,
    this.deletedBatch,
    this.deletedAt,
  });

  final String id;
  final String documentId;
  final String? folderId;
  final bool isShortcut;
  final String? alias;
  final int sortKey;
  final DateTime createdAt;
  final String? deletedBatch;
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  DocumentEntry copyWith({
    String? id,
    String? documentId,
    String? folderId,
    bool clearFolder = false,
    bool? isShortcut,
    String? alias,
    bool clearAlias = false,
    int? sortKey,
    DateTime? createdAt,
    String? deletedBatch,
    bool clearDeletedBatch = false,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
  }) => DocumentEntry(
    id: id ?? this.id,
    documentId: documentId ?? this.documentId,
    folderId: clearFolder ? null : folderId ?? this.folderId,
    isShortcut: isShortcut ?? this.isShortcut,
    alias: clearAlias ? null : alias ?? this.alias,
    sortKey: sortKey ?? this.sortKey,
    createdAt: createdAt ?? this.createdAt,
    deletedBatch: clearDeletedBatch ? null : deletedBatch ?? this.deletedBatch,
    deletedAt: clearDeletedAt ? null : deletedAt ?? this.deletedAt,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'documentId': documentId,
    'folderId': folderId,
    'isShortcut': isShortcut,
    'alias': alias,
    'sortKey': sortKey,
    'createdAt': createdAt.toIso8601String(),
    'deletedBatch': deletedBatch,
    'deletedAt': deletedAt?.toIso8601String(),
  };

  factory DocumentEntry.fromJson(Map<String, dynamic> json) => DocumentEntry(
    id: json['id'] as String,
    documentId: json['documentId'] as String,
    folderId: json['folderId'] as String?,
    isShortcut: json['isShortcut'] as bool? ?? false,
    alias: json['alias'] as String?,
    sortKey: (json['sortKey'] as num?)?.toInt() ?? 0,
    createdAt: DateTime.parse(json['createdAt'] as String),
    deletedBatch: json['deletedBatch'] as String?,
    deletedAt: json['deletedAt'] == null
        ? null
        : DateTime.parse(json['deletedAt'] as String),
  );
}

class LibraryTag {
  const LibraryTag({
    required this.id,
    required this.name,
    required this.nameNorm,
    required this.createdAt,
    this.colorValue,
  });

  final String id;
  final String name;
  final String nameNorm;
  final int? colorValue;
  final DateTime createdAt;

  LibraryTag copyWith({String? name, String? nameNorm, int? colorValue}) =>
      LibraryTag(
        id: id,
        name: name ?? this.name,
        nameNorm: nameNorm ?? this.nameNorm,
        colorValue: colorValue ?? this.colorValue,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'nameNorm': nameNorm,
    'colorValue': colorValue,
    'createdAt': createdAt.toIso8601String(),
  };

  factory LibraryTag.fromJson(Map<String, dynamic> json) => LibraryTag(
    id: json['id'] as String,
    name: json['name'] as String,
    nameNorm: json['nameNorm'] as String,
    colorValue: (json['colorValue'] as num?)?.toInt(),
    createdAt: DateTime.parse(json['createdAt'] as String),
  );
}

/// Why a group of folders, entries and documents moved to the trash together.
/// Restoring replays the whole batch so colours, order and shortcut relations
/// come back; the original parent is recorded so a restore does not have to
/// guess where the items belonged.
class DeletionBatch {
  const DeletionBatch({
    required this.id,
    required this.kind,
    required this.label,
    required this.createdAt,
    required this.itemCount,
    required this.documentCount,
    this.rootId,
    Map<String, Object?>? details,
  }) : details = details ?? const {};

  final String id;
  final String kind;
  final String label;
  final String? rootId;
  final DateTime createdAt;
  final int itemCount;
  final int documentCount;
  final Map<String, Object?> details;

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'label': label,
    'rootId': rootId,
    'createdAt': createdAt.toIso8601String(),
    'itemCount': itemCount,
    'documentCount': documentCount,
    ...details,
  };
}

enum LibraryScope { all, recent, unfiled, starred, folder, smart, trash }

enum LibrarySortField {
  manual,
  name,
  addedAt,
  openedAt,
  size,
  format;

  String get label => switch (this) {
    LibrarySortField.manual => '手动顺序',
    LibrarySortField.name => '名称',
    LibrarySortField.addedAt => '导入日期',
    LibrarySortField.openedAt => '最近打开',
    LibrarySortField.size => '文件大小',
    LibrarySortField.format => '文件格式',
  };
}

enum LibraryLayout { list, grid }

enum LibraryDensity { comfortable, compact }

/// Visible metadata columns in the desktop list. The name is always visible;
/// the other columns can be hidden without changing any stored data.
class LibraryListColumns {
  const LibraryListColumns({
    this.tags = true,
    this.format = true,
    this.status = true,
    this.progress = true,
  });

  final bool tags;
  final bool format;
  final bool status;
  final bool progress;

  LibraryListColumns copyWith({
    bool? tags,
    bool? format,
    bool? status,
    bool? progress,
  }) => LibraryListColumns(
    tags: tags ?? this.tags,
    format: format ?? this.format,
    status: status ?? this.status,
    progress: progress ?? this.progress,
  );

  Map<String, dynamic> toJson() => {
    'tags': tags,
    'format': format,
    'status': status,
    'progress': progress,
  };

  factory LibraryListColumns.fromJson(Map<String, dynamic> json) =>
      LibraryListColumns(
        tags: json['tags'] as bool? ?? true,
        format: json['format'] as bool? ?? true,
        status: json['status'] as bool? ?? true,
        progress: json['progress'] as bool? ?? true,
      );
}

/// Per-folder display preference. The global view state is the default for new
/// folders; a folder that the user sorted or switched to grid keeps its own
/// choice independently.
class FolderViewPreference {
  const FolderViewPreference({
    this.layout = LibraryLayout.list,
    this.sortField = LibrarySortField.manual,
    this.ascending = true,
  });

  final LibraryLayout layout;
  final LibrarySortField sortField;
  final bool ascending;

  Map<String, dynamic> toJson() => {
    'layout': layout.name,
    'sortField': sortField.name,
    'ascending': ascending,
  };

  factory FolderViewPreference.fromJson(Map<String, dynamic> json) =>
      FolderViewPreference(
        layout:
            LibraryLayout.values.asNameMap()[json['layout'] as String? ?? ''] ??
            LibraryLayout.list,
        sortField:
            LibrarySortField.values.asNameMap()[json['sortField'] as String? ??
                ''] ??
            LibrarySortField.manual,
        ascending: json['ascending'] as bool? ?? true,
      );
}

/// Persisted view configuration. It never stores content, so restoring the
/// default layout cannot move or delete a document.
class LibraryViewState {
  const LibraryViewState({
    this.scope = LibraryScope.all,
    this.folderId,
    this.sortField = LibrarySortField.manual,
    this.ascending = true,
    this.layout = LibraryLayout.list,
    this.density = LibraryDensity.comfortable,
    this.showDetails = true,
    this.columns = const LibraryListColumns(),
    this.showBranchLines = true,
    this.expandedFolders = const {},
    this.smartFolderId,
  });

  final LibraryScope scope;
  final String? folderId;
  final LibrarySortField sortField;
  final bool ascending;
  final LibraryLayout layout;
  final LibraryDensity density;
  final bool showDetails;
  final LibraryListColumns columns;
  final bool showBranchLines;
  final Set<String> expandedFolders;

  /// Restores the last opened smart folder after a restart; null means the
  /// ordinary views are active.
  final String? smartFolderId;

  LibraryViewState copyWith({
    LibraryScope? scope,
    String? folderId,
    bool clearFolder = false,
    LibrarySortField? sortField,
    bool? ascending,
    LibraryLayout? layout,
    LibraryDensity? density,
    bool? showDetails,
    LibraryListColumns? columns,
    bool? showBranchLines,
    Set<String>? expandedFolders,
    String? smartFolderId,
    bool clearSmartFolder = false,
  }) => LibraryViewState(
    scope: scope ?? this.scope,
    folderId: clearFolder ? null : folderId ?? this.folderId,
    sortField: sortField ?? this.sortField,
    ascending: ascending ?? this.ascending,
    layout: layout ?? this.layout,
    density: density ?? this.density,
    showDetails: showDetails ?? this.showDetails,
    columns: columns ?? this.columns,
    showBranchLines: showBranchLines ?? this.showBranchLines,
    expandedFolders: expandedFolders ?? this.expandedFolders,
    smartFolderId: clearSmartFolder ? null : smartFolderId ?? this.smartFolderId,
  );

  Map<String, dynamic> toJson() => {
    'scope': scope.name,
    'folderId': folderId,
    'sortField': sortField.name,
    'ascending': ascending,
    'layout': layout.name,
    'density': density.name,
    'showDetails': showDetails,
    'columns': columns.toJson(),
    'showBranchLines': showBranchLines,
    'expandedFolders': expandedFolders.toList(),
    'smartFolderId': smartFolderId,
  };

  factory LibraryViewState.fromJson(Map<String, dynamic> json) =>
      LibraryViewState(
        scope:
            LibraryScope.values.asNameMap()[json['scope'] as String? ?? ''] ??
            LibraryScope.all,
        folderId: json['folderId'] as String?,
        sortField:
            LibrarySortField.values.asNameMap()[json['sortField'] as String? ??
                ''] ??
            LibrarySortField.manual,
        ascending: json['ascending'] as bool? ?? true,
        layout:
            LibraryLayout.values.asNameMap()[json['layout'] as String? ?? ''] ??
            LibraryLayout.list,
        density:
            LibraryDensity.values.asNameMap()[json['density'] as String? ??
                ''] ??
            LibraryDensity.comfortable,
        showDetails: json['showDetails'] as bool? ?? true,
        columns: LibraryListColumns.fromJson(
          Map<String, dynamic>.from(json['columns'] as Map? ?? const {}),
        ),
        showBranchLines: json['showBranchLines'] as bool? ?? true,
        smartFolderId: json['smartFolderId'] as String?,
        expandedFolders: {
          for (final value in (json['expandedFolders'] as List? ?? const []))
            if (value is String) value,
        },
      );
}

class LibraryFilter {
  const LibraryFilter({
    this.formats = const {},
    this.tagIds = const {},
    this.starredOnly = false,
    this.processingOnly = false,
    this.unreadOnly = false,
  });

  final Set<String> formats;
  final Set<String> tagIds;
  final bool starredOnly;
  final bool processingOnly;
  final bool unreadOnly;

  bool get isEmpty =>
      formats.isEmpty &&
      tagIds.isEmpty &&
      !starredOnly &&
      !processingOnly &&
      !unreadOnly;

  int get activeCount =>
      formats.length +
      tagIds.length +
      (starredOnly ? 1 : 0) +
      (processingOnly ? 1 : 0) +
      (unreadOnly ? 1 : 0);

  LibraryFilter copyWith({
    Set<String>? formats,
    Set<String>? tagIds,
    bool? starredOnly,
    bool? processingOnly,
    bool? unreadOnly,
  }) => LibraryFilter(
    formats: formats ?? this.formats,
    tagIds: tagIds ?? this.tagIds,
    starredOnly: starredOnly ?? this.starredOnly,
    processingOnly: processingOnly ?? this.processingOnly,
    unreadOnly: unreadOnly ?? this.unreadOnly,
  );

  LibraryFilter toggleFormat(String value) => copyWith(
    formats: toggleValue(formats, value),
  );

  LibraryFilter toggleTag(String value) => copyWith(
    tagIds: toggleValue(tagIds, value),
  );

  Map<String, dynamic> toJson() => {
    'formats': formats.toList(),
    'tagIds': tagIds.toList(),
    'starredOnly': starredOnly,
    'processingOnly': processingOnly,
    'unreadOnly': unreadOnly,
  };

  factory LibraryFilter.fromJson(Map<String, dynamic> json) => LibraryFilter(
    formats: {
      for (final value in (json['formats'] as List? ?? const []))
        if (value is String) value,
    },
    tagIds: {
      for (final value in (json['tagIds'] as List? ?? const []))
        if (value is String) value,
    },
    starredOnly: json['starredOnly'] as bool? ?? false,
    processingOnly: json['processingOnly'] as bool? ?? false,
    unreadOnly: json['unreadOnly'] as bool? ?? false,
  );
}

/// A saved query and filter. It stores conditions, never documents, so its
/// results always reflect the current library and it cannot receive a move.
class SmartFolder {
  const SmartFolder({
    required this.id,
    required this.name,
    this.query = '',
    this.filter = const LibraryFilter(),
  });

  final String id;
  final String name;
  final String query;
  final LibraryFilter filter;

  bool get isEmpty => query.trim().isEmpty && filter.isEmpty;

  String get conditionLabel {
    final parts = <String>[
      if (query.trim().isNotEmpty) '“${query.trim()}”',
      if (filter.formats.isNotEmpty)
        filter.formats.map((value) => value.toUpperCase()).join('、'),
      if (filter.tagIds.isNotEmpty) '${filter.tagIds.length} 个标签',
      if (filter.starredOnly) '星标',
      if (filter.unreadOnly) '未读',
      if (filter.processingOnly) '待处理',
    ];
    return parts.isEmpty ? '全部资料' : parts.join(' · ');
  }

  SmartFolder copyWith({String? name, String? query, LibraryFilter? filter}) =>
      SmartFolder(
        id: id,
        name: name ?? this.name,
        query: query ?? this.query,
        filter: filter ?? this.filter,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'query': query,
    'filter': filter.toJson(),
  };

  factory SmartFolder.fromJson(Map<String, dynamic> json) => SmartFolder(
    id: json['id'] as String,
    name: json['name'] as String,
    query: json['query'] as String? ?? '',
    filter: LibraryFilter.fromJson(
      Map<String, dynamic>.from(json['filter'] as Map? ?? const {}),
    ),
  );
}

Set<String> toggleValue(Set<String> values, String value) {
  final next = {...values};
  if (!next.remove(value)) next.add(value);
  return next;
}

class LibraryCounts {
  const LibraryCounts({
    this.all = 0,
    this.unfiled = 0,
    this.starred = 0,
    this.trash = 0,
    this.folders = const {},
  });

  final int all;
  final int unfiled;
  final int starred;
  final int trash;

  /// Direct (not subtree) visible entries per folder.
  final Map<String, int> folders;

  int forFolder(String id) => folders[id] ?? 0;
}

/// A placement joined with its document. Entries whose document is in the
/// trash stay visible so the user can restore it instead of silently losing
/// the shortcut.
class LibraryItem {
  const LibraryItem({required this.entry, required this.document});

  final DocumentEntry entry;
  final DocumentRecord document;

  String get displayName {
    final alias = entry.alias?.trim();
    return alias == null || alias.isEmpty ? document.title : alias;
  }

  bool get available => document.isActive;
  bool get isShortcut => entry.isShortcut;
}

class LibraryFolderNode {
  const LibraryFolderNode({
    required this.folder,
    required this.depth,
    this.children = const [],
  });

  final LibraryFolder folder;
  final int depth;
  final List<LibraryFolderNode> children;
}

/// Counts shown in the permanent-delete preview before anything is removed.
class LibraryPurgeImpact {
  const LibraryPurgeImpact({
    this.documents = 0,
    this.folders = 0,
    this.entries = 0,
    this.notes = 0,
    this.sessions = 0,
    this.tasks = 0,
    this.planSources = 0,
    this.pages = 0,
    this.evidence = 0,
    this.bookQa = 0,
    this.bytes = 0,
  });

  final int documents;
  final int folders;
  final int entries;
  final int notes;
  final int sessions;
  final int tasks;
  final int planSources;
  final int pages;
  final int evidence;
  final int bookQa;
  final int bytes;

  LibraryPurgeImpact operator +(LibraryPurgeImpact other) =>
      LibraryPurgeImpact(
        documents: documents + other.documents,
        folders: folders + other.folders,
        entries: entries + other.entries,
        notes: notes + other.notes,
        sessions: sessions + other.sessions,
        tasks: tasks + other.tasks,
        planSources: planSources + other.planSources,
        pages: pages + other.pages,
        evidence: evidence + other.evidence,
        bookQa: bookQa + other.bookQa,
        bytes: bytes + other.bytes,
      );
}

class LibrarySearchHit {
  const LibrarySearchHit({
    required this.document,
    required this.reason,
    this.page,
    this.snippet,
    this.folderId,
    this.entryId,
  });

  final DocumentRecord document;
  final String reason;
  final int? page;
  final String? snippet;
  final String? folderId;
  final String? entryId;
}
