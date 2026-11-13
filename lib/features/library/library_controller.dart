import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../../../core/local_store.dart';
import '../../../core/models.dart';
import '../../../services/document_service.dart';
import '../review/data/review_repository.dart';
import 'data/library_repository.dart';
import 'import/import_queue.dart';
import 'models/library_models.dart';
import 'services/library_export_service.dart';

class LibraryException implements Exception {
  const LibraryException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum LibrarySearchScope {
  currentFolder('当前文件夹'),
  subtree('包含子文件夹'),
  all('全部资料');

  const LibrarySearchScope(this.label);
  final String label;
}

class LibraryUndo {
  LibraryUndo(this.description, this._action);
  final String description;
  final Future<void> Function() _action;

  Future<void> run() => _action();
}

/// UI-independent state for the file workspace: tree, placement entries, tags,
/// selection, search and soft deletion.
///
/// The controller never opens a rendered document. Opening, OCR and AI stay in
/// [StudyController], which keeps file management usable while the reader is
/// closed and prevents a drag-and-drop action from starting a page render.
class LibraryController extends ChangeNotifier {
  LibraryController({required this.store, required this.documents})
    : repository = LibraryRepository(store) {
    queue = ImportQueue(
      store: store,
      documents: documents,
      repository: repository,
      onLibraryChanged: _reload,
      onNotice: (message) {
        _notice = message;
        _notify();
      },
    );
    _view = _loadView();
    _smartFolders = _loadSmartFolders();
    _activeSmartFolderId = _view.smartFolderId;
    _folderViews = _loadFolderViews();
    if (_view.scope == LibraryScope.folder && _view.folderId != null) {
      final preference = _folderViews[_view.folderId!];
      if (preference != null) {
        _view = _view.copyWith(
          layout: preference.layout,
          sortField: preference.sortField,
          ascending: preference.ascending,
        );
      }
    }
    _reload();
  }

  final LocalStore store;
  final DocumentService documents;
  final LibraryRepository repository;
  final LibraryExportService exportService = const LibraryExportService();
  late final ImportQueue queue;

  static const _viewKey = 'library.view';
  static const _smartFoldersKey = 'library.smartFolders';
  static const _folderViewsKey = 'library.folderViews';
  static const _uuid = Uuid();

  late LibraryViewState _view;
  LibraryFilter _filter = const LibraryFilter();
  String _query = '';
  LibrarySearchScope _searchScope = LibrarySearchScope.subtree;
  List<SmartFolder> _smartFolders = const [];
  String? _activeSmartFolderId;
  Map<String, FolderViewPreference> _folderViews = const {};

  List<LibraryFolder> _allFolders = const [];
  List<LibraryFolder> _folders = const [];
  List<DocumentEntry> _entries = const [];
  Map<String, DocumentRecord> _documents = const {};
  Map<String, Set<String>> _tagIds = const {};
  List<LibraryTag> _tags = const [];
  LibraryCounts _counts = const LibraryCounts();
  List<DeletionBatch> _batches = const [];
  _SearchCache? _searchCache;
  String? _itemCacheKey;
  List<LibraryItem> _itemCache = const [];

  final Set<String> _selectedEntries = {};
  final Set<String> _selectedFolders = {};
  String? _anchorEntryId;
  String? _detailEntryId;

  LibraryUndo? _undo;
  String? _notice;
  String? _error;
  bool _busy = false;
  bool _disposed = false;

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  LibraryViewState get view => _view;
  LibraryFilter get filter => _effectiveFilter;
  String get query => _effectiveQuery;
  LibrarySearchScope get searchScope => _effectiveSearchScope;
  List<SmartFolder> get smartFolders => _smartFolders;
  SmartFolder? get activeSmartFolder {
    final id = _activeSmartFolderId;
    if (id == null) return null;
    for (final folder in _smartFolders) {
      if (folder.id == id) return folder;
    }
    return null;
  }

  bool get hasSearchConditions =>
      _query.trim().isNotEmpty || !_filter.isEmpty;

  String get _effectiveQuery => activeSmartFolder?.query ?? _query;
  LibraryFilter get _effectiveFilter => activeSmartFolder?.filter ?? _filter;
  LibrarySearchScope get _effectiveSearchScope =>
      activeSmartFolder == null ? _searchScope : LibrarySearchScope.all;

  LibraryCounts get counts => _counts;
  List<LibraryTag> get tags => _tags;
  Map<String, Set<String>> get tagIdsByDocument => _tagIds;
  bool get busy => _busy;
  LibraryUndo? get undo => _undo;
  String? takeNotice() {
    final value = _notice;
    _notice = null;
    return value;
  }

  String? takeError() {
    final value = _error;
    _error = null;
    return value;
  }

  List<LibraryFolder> get folders => _folders;
  List<DeletionBatch> get trashBatches => _batches;
  Set<String> get selectedEntries => Set.unmodifiable(_selectedEntries);
  Set<String> get selectedFolders => Set.unmodifiable(_selectedFolders);
  Set<String> get expandedFolders => _view.expandedFolders;
  int get selectionCount => _selectedEntries.length + _selectedFolders.length;
  bool get hasSelection => selectionCount > 0;
  Set<String> get selectedDocumentIds => {
    for (final id in _selectedEntries)
      if (_entryById(id) case final entry?) entry.documentId,
  };

  /// Active folders only. Use [anyFolderById] when a deleted folder still needs
  /// a readable name, for example a trash entry's original location.
  LibraryFolder? folderById(String? id) => _folderById(id);

  LibraryFolder? anyFolderById(String? id) =>
      id == null ? null : _folderById(id) ?? _deletedFolderById(id);

  LibraryFolder? _folderById(String? id) {
    if (id == null) return null;
    for (final folder in _folders) {
      if (folder.id == id) return folder;
    }
    return null;
  }

  LibraryFolder? _deletedFolderById(String? id) {
    if (id == null) return null;
    for (final folder in _allFolders) {
      if (folder.id == id) return folder;
    }
    return null;
  }

  DocumentEntry? _entryById(String id) {
    for (final entry in _entries) {
      if (entry.id == id) return entry;
    }
    for (final entry in _deletedEntries) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  List<DocumentEntry> _deletedEntries = const [];

  DocumentRecord? documentById(String id) => _documents[id];

  /// Bumped whenever the visible set changes so widgets can reset scroll or
  /// selection safely.
  int _revision = 0;
  int get revision => _revision;

  LibraryFolder? get currentFolder =>
      _view.scope == LibraryScope.folder ? _folderById(_view.folderId) : null;

  List<LibraryFolder> get breadcrumb {
    final result = <LibraryFolder>[];
    var current = currentFolder;
    final seen = <String>{};
    while (current != null && seen.add(current.id)) {
      result.insert(0, current);
      current = _folderById(current.parentId);
    }
    return result;
  }

  List<LibraryFolder> get childFolders {
    final parent = currentFolder?.id;
    final result = _folders.where((folder) => folder.parentId == parent).toList()
      ..sort(_compareFolders);
    return result;
  }

  List<LibraryFolder> childrenOf(String? parentId) =>
      (_folders.where((folder) => folder.parentId == parentId).toList()
        ..sort(_compareFolders));

  List<LibraryFolderNode> get folderTree {
    List<LibraryFolderNode> build(String? parentId, int depth) {
      return [
        for (final folder in childrenOf(parentId))
          LibraryFolderNode(
            folder: folder,
            depth: depth,
            children: build(folder.id, depth + 1),
          ),
      ];
    }

    return build(null, 0);
  }

  int depthOf(String? folderId) {
    var depth = 0;
    var current = _folderById(folderId);
    final seen = <String>{};
    while (current?.parentId != null && seen.add(current!.id)) {
      depth++;
      current = _folderById(current.parentId);
    }
    return depth;
  }

  int subtreeHeight(String folderId) {
    var height = 0;
    void walk(String id, int level) {
      height = level > height ? level : height;
      for (final child in _folders.where((folder) => folder.parentId == id)) {
        walk(child.id, level + 1);
      }
    }

    walk(folderId, 0);
    return height;
  }

  Set<String> descendantFolderIds(String folderId, {bool includeSelf = false}) {
    final result = <String>{if (includeSelf) folderId};
    final pending = <String>[folderId];
    while (pending.isNotEmpty) {
      final id = pending.removeLast();
      for (final child in _folders) {
        if (child.parentId == id && result.add(child.id)) {
          pending.add(child.id);
        }
      }
    }
    return result;
  }

  String folderPathName(String? folderId, {String separator = ' / '}) {
    final parts = <String>[];
    var current = anyFolderById(folderId);
    final seen = <String>{};
    while (current != null && seen.add(current.id)) {
      parts.insert(0, current.name);
      current = anyFolderById(current.parentId);
    }
    return parts.join(separator);
  }

  List<LibraryItem> get childItems => _computeItems();

  List<LibraryItem> get items => _computeItems();

  List<LibraryItem> get selectedItems => [
    for (final item in _computeItems(ignoreSelectionScope: true))
      if (_selectedEntries.contains(item.entry.id)) item,
  ];

  List<LibraryItem> get allSelectedItems => [
    for (final entry in _entries)
      if (_selectedEntries.contains(entry.id))
        if (_documents[entry.documentId] case final document?)
          LibraryItem(entry: entry, document: document),
  ];

  LibraryItem? get detailItem {
    final id = _detailEntryId;
    if (id == null) return null;
    for (final item in _computeItems(ignoreSelectionScope: true)) {
      if (item.entry.id == id) return item;
    }
    final entry = _entryById(id);
    final document = entry == null ? null : _documents[entry.documentId];
    return entry == null || document == null
        ? null
        : LibraryItem(entry: entry, document: document);
  }

  List<LibrarySearchHit> get fullTextHits {
    final search = _search;
    if (search.hits.isEmpty) return const [];
    final allowed = _scopeDocumentIds();
    return search.hits
        .where((hit) => allowed == null || allowed.contains(hit.document.id))
        .take(30)
        .toList();
  }

  List<LibraryItem> get trashItems {
    final deleted = _deletedEntries;
    return [
      for (final entry in deleted)
        if (_documents[entry.documentId] case final document?)
          LibraryItem(entry: entry, document: document),
    ];
  }

  List<LibraryFolder> trashFoldersFor(String batchId) => [
    for (final folder in _allFolders)
      if (folder.deletedBatch == batchId && folder.isDeleted) folder,
  ];

  List<LibraryItem> trashItemsFor(String batchId) {
    final entries = _deletedEntries
        .where((entry) => entry.deletedBatch == batchId)
        .toList();
    return [
      for (final entry in entries)
        if (_documents[entry.documentId] case final document?)
          LibraryItem(entry: entry, document: document),
    ];
  }

  DeletionBatch? batchFor(String id) {
    for (final batch in _batches) {
      if (batch.id == id) return batch;
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Navigation and view state
  // ---------------------------------------------------------------------------

  void showAll() => _setScope(LibraryScope.all);

  void showRecent() => _setScope(LibraryScope.recent);

  void showUnfiled() => _setScope(LibraryScope.unfiled);

  void showStarred() => _setScope(LibraryScope.starred);

  void showTrash() {
    _view = _view.copyWith(
      scope: LibraryScope.trash,
      clearFolder: true,
      clearSmartFolder: true,
    );
    _activeSmartFolderId = null;
    _clearSelection();
    _persistView();
    _notify();
  }

  void openFolder(String folderId) {
    final folder = _folderById(folderId);
    if (folder == null) return;
    _view = _view.copyWith(
      scope: LibraryScope.folder,
      folderId: folderId,
      expandedFolders: {..._view.expandedFolders, ..._ancestorIds(folderId)},
      clearSmartFolder: true,
    );
    _activeSmartFolderId = null;
    final preference = _folderViews[folderId];
    if (preference != null) {
      _view = _view.copyWith(
        layout: preference.layout,
        sortField: preference.sortField,
        ascending: preference.ascending,
      );
    }
    _clearSelection();
    _detailEntryId = null;
    _persistView();
    _notify();
  }

  void navigateUp() {
    final parent = currentFolder?.parentId;
    if (parent == null) {
      showAll();
    } else {
      openFolder(parent);
    }
  }

  Set<String> _ancestorIds(String folderId) {
    final result = <String>{};
    var current = _folderById(folderId);
    while (current?.parentId != null) {
      result.add(current!.parentId!);
      current = _folderById(current.parentId);
    }
    return result;
  }

  void _setScope(LibraryScope scope) {
    _view = _view.copyWith(
      scope: scope,
      clearFolder: true,
      clearSmartFolder: true,
    );
    _activeSmartFolderId = null;
    _clearSelection();
    _detailEntryId = null;
    _persistView();
    _notify();
  }

  void toggleExpanded(String folderId) {
    final expanded = {..._view.expandedFolders};
    if (!expanded.remove(folderId)) expanded.add(folderId);
    _view = _view.copyWith(expandedFolders: expanded);
    _persistView();
    _notify();
  }

  void expandAll() {
    _view = _view.copyWith(
      expandedFolders: {for (final folder in _folders) folder.id},
    );
    _persistView();
    _notify();
  }

  void collapseAll() {
    _view = _view.copyWith(expandedFolders: <String>{});
    _persistView();
    _notify();
  }

  void setSort(LibrarySortField field) {
    _view = _view.copyWith(
      sortField: field,
      ascending: field == LibrarySortField.manual ? true : _view.ascending,
    );
    _rememberFolderView();
    _persistView();
    _notify();
  }

  void toggleSortDirection() {
    _view = _view.copyWith(ascending: !_view.ascending);
    _rememberFolderView();
    _persistView();
    _notify();
  }

  void setLayout(LibraryLayout layout) {
    _view = _view.copyWith(layout: layout);
    _rememberFolderView();
    _persistView();
    _notify();
  }

  void setDensity(LibraryDensity density) {
    _view = _view.copyWith(density: density);
    _persistView();
    _notify();
  }

  void toggleBranchLines() {
    _view = _view.copyWith(showBranchLines: !_view.showBranchLines);
    _persistView();
    _notify();
  }

  void setColumns(LibraryListColumns columns) {
    _view = _view.copyWith(columns: columns);
    _persistView();
    _notify();
  }

  void toggleColumn(String column) {
    final current = _view.columns;
    setColumns(
      switch (column) {
        'tags' => current.copyWith(tags: !current.tags),
        'format' => current.copyWith(format: !current.format),
        'status' => current.copyWith(status: !current.status),
        'progress' => current.copyWith(progress: !current.progress),
        _ => current,
      },
    );
  }

  void toggleDetails() {
    _view = _view.copyWith(showDetails: !_view.showDetails);
    _persistView();
    _notify();
  }

  void setFilter(LibraryFilter filter) {
    if (_activeSmartFolderId != null) {
      _activeSmartFolderId = null;
      if (_view.scope == LibraryScope.smart) {
        _view = _view.copyWith(
          scope: LibraryScope.all,
          clearSmartFolder: true,
        );
        _persistView();
      }
    }
    _filter = filter;
    _clearSelection();
    _notify();
  }

  void setQuery(String value) {
    if (_activeSmartFolderId != null) {
      _activeSmartFolderId = null;
      if (_view.scope == LibraryScope.smart) {
        _view = _view.copyWith(
          scope: LibraryScope.all,
          clearSmartFolder: true,
        );
        _persistView();
      }
      _searchCache = null;
    }
    if (_query == value) return;
    _query = value;
    _searchCache = null;
    _clearSelection();
    _notify();
  }

  void setSearchScope(LibrarySearchScope scope) {
    if (_activeSmartFolderId != null) {
      _activeSmartFolderId = null;
      if (_view.scope == LibraryScope.smart) {
        _view = _view.copyWith(
          scope: LibraryScope.all,
          clearSmartFolder: true,
        );
        _persistView();
      }
    }
    _searchScope = scope;
    _searchCache = null;
    _notify();
  }

  LibraryViewState _loadView() {
    final raw = store.getSetting(_viewKey);
    if (raw == null) return const LibraryViewState();
    try {
      return LibraryViewState.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return const LibraryViewState();
    }
  }

  void _persistView() {
    try {
      store.setSetting(_viewKey, jsonEncode(_view.toJson()));
    } catch (_) {
      /* A read-only or closing library must not break navigation. */
    }
  }

  Map<String, FolderViewPreference> _loadFolderViews() {
    final raw = store.getSetting(_folderViewsKey);
    if (raw == null) return const {};
    try {
      final decoded = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      return {
        for (final entry in decoded.entries)
          if (entry.value is Map)
            entry.key: FolderViewPreference.fromJson(
              Map<String, dynamic>.from(entry.value as Map),
            ),
      };
    } catch (_) {
      return const {};
    }
  }

  void _persistFolderViews() {
    try {
      store.setSetting(
        _folderViewsKey,
        jsonEncode({
          for (final entry in _folderViews.entries)
            entry.key: entry.value.toJson(),
        }),
      );
    } catch (_) {
      /* Display preferences are optional. */
    }
  }

  void _rememberFolderView() {
    if (_view.scope != LibraryScope.folder || _view.folderId == null) return;
    final updated = {..._folderViews};
    updated[_view.folderId!] = FolderViewPreference(
      layout: _view.layout,
      sortField: _view.sortField,
      ascending: _view.ascending,
    );
    _folderViews = updated;
    _persistFolderViews();
  }

  // ---------------------------------------------------------------------------
  // Smart folders
  // ---------------------------------------------------------------------------

  List<SmartFolder> _loadSmartFolders() {
    final raw = store.getSetting(_smartFoldersKey);
    if (raw == null) return const [];
    try {
      return [
        for (final value in jsonDecode(raw) as List)
          SmartFolder.fromJson(Map<String, dynamic>.from(value as Map)),
      ];
    } catch (_) {
      return const [];
    }
  }

  void _persistSmartFolders() {
    try {
      store.setSetting(
        _smartFoldersKey,
        jsonEncode(_smartFolders.map((folder) => folder.toJson()).toList()),
      );
    } catch (_) {
      /* Persisting a view condition must never break content. */
    }
  }

  void showSmartFolder(String id) {
    final folder = _firstOrNull(_smartFolders.where((item) => item.id == id));
    if (folder == null) return;
    _activeSmartFolderId = id;
    _view = _view.copyWith(
      scope: LibraryScope.smart,
      clearFolder: true,
      smartFolderId: id,
    );
    _clearSelection();
    _detailEntryId = null;
    _searchCache = null;
    _persistView();
    _notify();
  }

  void clearSmartFolder() {
    if (_activeSmartFolderId == null && _view.smartFolderId == null) return;
    _activeSmartFolderId = null;
    if (_view.scope == LibraryScope.smart) {
      _view = _view.copyWith(
        scope: LibraryScope.all,
        clearSmartFolder: true,
      );
    } else {
      _view = _view.copyWith(clearSmartFolder: true);
    }
    _searchCache = null;
    _persistView();
    _notify();
  }

  /// Saves the current search text and filter as conditions. The saved item
  /// never copies documents, so results stay current and it cannot receive a
  /// move operation.
  Future<SmartFolder?> saveCurrentAsSmartFolder(String name) =>
      _guard(() async {
        final trimmed = name.trim();
        if (trimmed.isEmpty) throw const LibraryException('智能文件夹需要名称。');
        if (!hasSearchConditions) {
          throw const LibraryException('先输入搜索词或设置筛选，再保存为智能文件夹。');
        }
        if (_smartFolders.any((folder) => folder.name == trimmed)) {
          throw LibraryException('已经有名为「$trimmed」的智能文件夹。');
        }
        final folder = SmartFolder(
          id: _uuid.v4(),
          name: trimmed,
          query: _query.trim(),
          filter: _filter,
        );
        _smartFolders = [..._smartFolders, folder];
        _persistSmartFolders();
        _notice = '已保存智能文件夹「${folder.name}」。';
        showSmartFolder(folder.id);
        return folder;
      });

  Future<void> renameSmartFolder(String id, String name) => _guard(() async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw const LibraryException('智能文件夹需要名称。');
    final index = _smartFolders.indexWhere((folder) => folder.id == id);
    if (index < 0) return;
    if (_smartFolders.any(
      (folder) => folder.id != id && folder.name == trimmed,
    )) {
      throw LibraryException('已经有名为「$trimmed」的智能文件夹。');
    }
    final updated = [..._smartFolders];
    updated[index] = updated[index].copyWith(name: trimmed);
    _smartFolders = updated;
    _persistSmartFolders();
    _reload();
  });

  Future<void> deleteSmartFolder(String id) => _guard(() async {
    final folder = _firstOrNull(_smartFolders.where((item) => item.id == id));
    if (folder == null) return;
    _smartFolders = [
      for (final item in _smartFolders)
        if (item.id != id) item,
    ];
    _persistSmartFolders();
    if (_activeSmartFolderId == id) {
      _activeSmartFolderId = null;
      _view = _view.copyWith(
        scope: LibraryScope.all,
        clearSmartFolder: true,
      );
      _persistView();
    }
    _notice = '已删除智能文件夹「${folder.name}」，资料本身不受影响。';
    _reload();
  });

  // ---------------------------------------------------------------------------
  // Selection
  // ---------------------------------------------------------------------------

  bool isEntrySelected(String id) => _selectedEntries.contains(id);
  bool isFolderSelected(String id) => _selectedFolders.contains(id);

  void selectEntry(
    String id, {
    bool toggle = false,
    bool range = false,
  }) {
    if (range && _anchorEntryId != null) {
      final items = _computeItems();
      final anchor = items.indexWhere((item) => item.entry.id == _anchorEntryId);
      final target = items.indexWhere((item) => item.entry.id == id);
      if (anchor >= 0 && target >= 0) {
        final start = anchor < target ? anchor : target;
        final end = anchor < target ? target : anchor;
        _selectedEntries
          ..clear()
          ..addAll(items.sublist(start, end + 1).map((item) => item.entry.id));
        _selectedFolders.clear();
        _detailEntryId = id;
        _notify();
        return;
      }
    }
    if (toggle) {
      if (!_selectedEntries.remove(id)) _selectedEntries.add(id);
      _anchorEntryId = id;
    } else {
      _selectedEntries
        ..clear()
        ..add(id);
      _selectedFolders.clear();
      _anchorEntryId = id;
    }
    _detailEntryId = id;
    _notify();
  }

  void selectFolder(String id, {bool toggle = false}) {
    if (toggle) {
      if (!_selectedFolders.remove(id)) _selectedFolders.add(id);
    } else {
      _selectedFolders
        ..clear()
        ..add(id);
      _selectedEntries.clear();
    }
    _notify();
  }

  void selectAllVisible() {
    _selectedEntries
      ..clear()
      ..addAll(_computeItems().map((item) => item.entry.id));
    _selectedFolders
      ..clear()
      ..addAll(childFolders.map((folder) => folder.id));
    _notify();
  }

  void clearSelection() {
    _clearSelection();
    _notify();
  }

  void _clearSelection() {
    _selectedEntries.clear();
    _selectedFolders.clear();
    _anchorEntryId = null;
    _detailEntryId = null;
  }

  void showDetail(String? entryId) {
    _detailEntryId = entryId;
    _notify();
  }

  bool get isTrashView => _view.scope == LibraryScope.trash;

  // ---------------------------------------------------------------------------
  // Import entry points
  // ---------------------------------------------------------------------------

  String? get importTargetFolderId => currentFolder?.id;
  String get importTargetLabel => currentFolder?.name ?? '未归档';
  bool get canImport => !isTrashView;

  Future<void> importPaths(Iterable<String> paths) async {
    if (isTrashView || paths.isEmpty) {
      if (isTrashView) _error = '回收站不接收导入，请先回到书库。';
      _notify();
      return;
    }
    try {
      await queue.enqueueSources(
        paths,
        targetFolderId: importTargetFolderId,
      );
    } catch (error) {
      _error = '导入没有开始：$error';
      _notify();
    }
  }

  Future<void> importDirectory(String path) async {
    if (isTrashView) {
      _error = '回收站不接收导入，请先回到书库。';
      _notify();
      return;
    }
    try {
      await queue.enqueueDirectory(
        path,
        targetFolderId: importTargetFolderId,
        keepStructure: true,
      );
    } catch (error) {
      _error = '文件夹扫描失败：$error';
      _notify();
    }
  }

  Future<LibraryPurgeImpact> impactForBatch(String batchId) async {
    final folderIds = [
      for (final folder in repository.deletedFoldersInBatch(batchId)) folder.id,
    ];
    final documents = [
      for (final document in store.getDocuments(includeTrashed: true))
        if (document.deletedBatch == batchId) document,
    ];
    return repository.purgeImpactForDocuments(
      documents.map((document) => document.id),
    ) + repository.purgeImpactForFolders(folderIds);
  }

  // ---------------------------------------------------------------------------
  // Folder operations
  // ---------------------------------------------------------------------------

  Future<LibraryFolder?> createFolder({
    required String name,
    String? parentId,
    int? colorValue,
    String? icon,
    String? description,
    bool inheritColor = true,
  }) => _guard(() async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw const LibraryException('文件夹名称不能为空。');
    if (trimmed.length > 80) throw const LibraryException('文件夹名称不要超过 80 个字符。');
    final parent = parentId ?? currentFolder?.id;
    if (parent != null && _folderById(parent) == null) {
      throw const LibraryException('目标文件夹已不存在。');
    }
    if (depthOf(parent) + 2 > LibraryRepository.maxFolderDepth) {
      throw const LibraryException('文件夹层级过深，已达到 64 层保护上限。');
    }
    if (repository.folderNameExists(parent, trimmed)) {
      throw LibraryException('这里已经有名为「$trimmed」的文件夹。');
    }
    late final LibraryFolder created;
    store.transact(() {
      created = repository.insertFolder(
        name: trimmed,
        parentId: parent,
        colorMode: inheritColor || colorValue == null
            ? FolderColorMode.inherit
            : FolderColorMode.custom,
        colorValue: colorValue,
        icon: icon,
        description: description,
      );
    });
    if (parent != null) {
      _view = _view.copyWith(
        expandedFolders: {..._view.expandedFolders, parent},
      );
      _persistView();
    }
    _notice = '已新建文件夹「${created.name}」。';
    _reload();
    return created;
  });

  Future<void> renameFolder(String folderId, String name) => _guard(() async {
    final folder = _folderById(folderId);
    if (folder == null) throw const LibraryException('这个文件夹已经不在书库里。');
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw const LibraryException('文件夹名称不能为空。');
    if (trimmed == folder.name) return;
    if (repository.folderNameExists(folder.parentId, trimmed, exceptId: folderId)) {
      throw LibraryException('同一位置已经有名为「$trimmed」的文件夹。');
    }
    store.transact(() {
      repository.updateFolder(folder.copyWith(name: trimmed));
    });
    _pushUndo(
      '撤销重命名「${folder.name}」',
      () async => store.transact(() {
        final current = _folderById(folderId);
        if (current == null) return;
        repository.updateFolder(current.copyWith(name: folder.name));
      }),
    );
    _notice = '文件夹已重命名为「$trimmed」。';
    _reload();
  });

  Future<void> setFolderAppearance(
    String folderId, {
    FolderColorMode? colorMode,
    int? colorValue,
    bool clearColor = false,
    String? icon,
    bool clearIcon = false,
    String? description,
  }) => _guard(() async {
    final folder = _folderById(folderId);
    if (folder == null) throw const LibraryException('这个文件夹已经不在书库里。');
    final nextMode = clearColor ? FolderColorMode.inherit : colorMode;
    store.transact(() {
      repository.updateFolder(
        folder.copyWith(
          colorMode: nextMode,
          colorValue: clearColor
              ? null
              : colorValue ?? folder.colorValue,
          clearColor: clearColor,
          icon: icon,
          clearIcon: clearIcon,
          description: description,
        ),
      );
    });
    _notice = '文件夹外观已保存。';
    _reload();
  });

  Future<void> resetFolderAppearance(String folderId) => _guard(() async {
    final folder = _folderById(folderId);
    if (folder == null) return;
    store.transact(() {
      repository.updateFolder(
        folder.copyWith(
          colorMode: FolderColorMode.inherit,
          clearColor: true,
          clearIcon: true,
        ),
      );
    });
    _notice = '已恢复默认外观。';
    _reload();
  });

  /// Moves folders and entries in one transaction. Parent folders that are also
  /// selected absorb their selected descendants; each item is processed once.
  Future<void> moveNodes({
    Iterable<String> folderIds = const [],
    Iterable<String> entryIds = const [],
    String? targetFolderId,
    String? beforeFolderId,
  }) => _guard(() async {
    final target = targetFolderId;
    if (target != null && _folderById(target) == null) {
      throw const LibraryException('目标文件夹已不存在。');
    }
    final folders = _minimalFolderSet(folderIds.toSet());
    final entries = entryIds
        .map(_entryById)
        .whereType<DocumentEntry>()
        // An entry inside a folder that is also moving is already carried by
        // the folder move; processing it again would pull it out to the target.
        .where((entry) => !_insideFolders(entry, folders))
        .toList();

    for (final id in folders) {
      final folder = _folderById(id);
      if (folder == null) continue;
      if (target == id) {
        throw const LibraryException('不能把文件夹移动到自己里面。');
      }
      if (target != null && descendantFolderIds(id).contains(target)) {
        throw const LibraryException('不能把文件夹移动到它的子文件夹里。');
      }
      if (depthOf(target) + subtreeHeight(id) + 1 >
          LibraryRepository.maxFolderDepth) {
        throw const LibraryException('移动后将超过 64 层，没有执行。');
      }
    }
    for (final entry in entries) {
      if (entry.folderId == target) continue;
      if (repository.entryInFolder(target, entry.documentId) != null) {
        throw LibraryException('目标文件夹里已经有「${_documents[entry.documentId]?.title ?? '这份资料'}」。');
      }
    }

    final previous = <String, Object?>{};
    var moved = 0;
    store.transact(() {
      var folderSort = beforeFolderId == null
          ? repository.nextFolderSortKey(target)
          : repository.nextFolderSortKey(target);
      for (final id in folders) {
        final folder = _folderById(id)!;
        previous['folder:$id'] = [folder.parentId, folder.sortKey];
        repository.updateFolder(
          folder.copyWith(
            parentId: target,
            clearParent: target == null,
            sortKey: folderSort,
          ),
        );
        folderSort += 1024;
        moved++;
      }
      var entrySort = repository.nextEntrySortKey(target);
      for (final entry in entries) {
        if (entry.folderId == target) continue;
        previous['entry:${entry.id}'] = [entry.folderId, entry.sortKey];
        repository.updateEntry(
          entry.copyWith(
            folderId: target,
            clearFolder: target == null,
            sortKey: entrySort,
          ),
        );
        entrySort += 1024;
        moved++;
      }
    });
    if (moved == 0) {
      _notice = '这些项目已经在目标位置。';
      _reload();
      return;
    }
    _pushUndo('撤销移动 $moved 项', () async {
      store.transact(() {
        for (final entry in previous.entries) {
          final parts = entry.key.split(':');
          final id = parts[1];
          final value = entry.value as List;
          if (parts.first == 'folder') {
            final folder = _folderById(id);
            if (folder != null) {
              repository.updateFolder(
                folder.copyWith(
                  parentId: value[0] as String?,
                  clearParent: value[0] == null,
                  sortKey: value[1] as int,
                ),
              );
            }
          } else {
            final item = _entries.firstWhere(
              (candidate) => candidate.id == id,
              orElse: () => DocumentEntry(
                id: id,
                documentId: '',
                sortKey: 0,
                createdAt: DateTime.now(),
              ),
            );
            if (item.documentId.isNotEmpty) {
              repository.updateEntry(
                item.copyWith(
                  folderId: value[0] as String?,
                  clearFolder: value[0] == null,
                  sortKey: value[1] as int,
                ),
              );
            }
          }
        }
      });
    });
    _clearSelection();
    _notice = '已移动 $moved 项。';
    _reload();
  });

  Future<void> reorderFolder(
    String folderId, {
    String? beforeFolderId,
  }) => _guard(() async {
    final folder = _folderById(folderId);
    if (folder == null) return;
    final siblings = childrenOf(folder.parentId)
        .where((item) => item.id != folderId)
        .toList();
    final index = beforeFolderId == null
        ? siblings.length
        : siblings.indexWhere((item) => item.id == beforeFolderId);
    final position = index < 0 ? siblings.length : index;
    final before = position == 0 ? null : siblings[position - 1].sortKey;
    final after = position >= siblings.length ? null : siblings[position].sortKey;
    final sortKey = _midpoint(before, after);
    store.transact(() {
      repository.updateFolder(folder.copyWith(sortKey: sortKey));
    });
    _notice = '已调整文件夹顺序。';
    _reload();
  });

  /// Moves a folder one position inside its current parent. Manual order is
  /// stored on the folder, never inferred from the name.
  Future<void> shiftFolder(String folderId, int delta) => _guard(() async {
    final folder = _folderById(folderId);
    if (folder == null) return;
    final siblings = childrenOf(folder.parentId);
    final index = siblings.indexWhere((item) => item.id == folderId);
    final target = index + delta;
    if (index < 0 || target < 0 || target >= siblings.length) {
      _notice = delta < 0 ? '已经是最前面的文件夹。' : '已经是最后面的文件夹。';
      return;
    }
    final sortKey = delta < 0
        ? _midpoint(
            index >= 2 ? siblings[index - 2].sortKey : null,
            siblings[index - 1].sortKey,
          )
        : _midpoint(
            siblings[index + 1].sortKey,
            index + 2 < siblings.length ? siblings[index + 2].sortKey : null,
          );
    store.transact(() {
      repository.updateFolder(folder.copyWith(sortKey: sortKey));
    });
    _notice = '已调整文件夹顺序。';
    _reload();
  });
  Future<void> reorderEntry(
    String entryId, {
    String? beforeEntryId,
  }) => _guard(() async {
    final entry = _entryById(entryId);
    if (entry == null) return;
    final siblings = repository
        .entries(folderId: entry.folderId, unfiled: entry.folderId == null)
        .where((item) => item.id != entryId)
        .toList();
    final index = beforeEntryId == null
        ? siblings.length
        : siblings.indexWhere((item) => item.id == beforeEntryId);
    final position = index < 0 ? siblings.length : index;
    final before = position == 0 ? null : siblings[position - 1].sortKey;
    final after = position >= siblings.length ? null : siblings[position].sortKey;
    store.transact(() {
      repository.updateEntry(
        entry.copyWith(sortKey: _midpoint(before, after)),
      );
    });
    _reload();
  });

  int _midpoint(int? before, int? after) {
    if (before == null && after == null) return 1024;
    if (before == null) return after! ~/ 2;
    if (after == null) return before + 1024;
    final gap = after - before;
    return gap <= 1 ? after : before + gap ~/ 2;
  }

  /// "Dissolve" keeps every item and removes only the empty folder shell.
  Future<void> dissolveFolder(String folderId) => _guard(() async {
    final folder = _folderById(folderId);
    if (folder == null) return;
    final parentId = folder.parentId;
    final conflicts = <String>[];
    for (final child in childrenOf(folderId)) {
      if (repository.folderNameExists(parentId, child.name)) {
        conflicts.add(child.name);
      }
    }
    if (conflicts.isNotEmpty) {
      throw LibraryException(
        '上一层已经有同名文件夹：${conflicts.join('、')}。请先改名或移动这些文件夹。',
      );
    }
    final children = childrenOf(folderId);
    final entries = repository.entries(folderId: folderId);
    store.transact(() {
      var sortKey = repository.nextFolderSortKey(parentId);
      for (final child in children) {
        repository.updateFolder(
          child.copyWith(
            parentId: parentId,
            clearParent: parentId == null,
            sortKey: sortKey,
          ),
        );
        sortKey += 1024;
      }
      var entrySort = repository.nextEntrySortKey(parentId);
      for (final entry in entries) {
        repository.updateEntry(
          entry.copyWith(
            folderId: parentId,
            clearFolder: parentId == null,
            sortKey: entrySort,
          ),
        );
        entrySort += 1024;
      }
      repository.purgeFolders([folderId]);
    });
    _notice = '已解散「${folder.name}」，其中的资料和子文件夹保留。';
    _reload();
    if (parentId != null) openFolder(parentId);
  });

  Future<void> createShortcut(
    String documentId, {
    String? folderId,
    String? alias,
  }) => _guard(() async {
    final target = folderId ?? currentFolder?.id;
    if (target != null && _folderById(target) == null) {
      throw const LibraryException('目标文件夹已不存在。');
    }
    final document = _documents[documentId];
    if (document == null || !document.isActive) {
      throw const LibraryException('这份资料在回收站里，先恢复再建立快捷方式。');
    }
    if (repository.entryInFolder(target, documentId) != null) {
      throw const LibraryException('目标文件夹里已经有这份资料。');
    }
    final created = repository.insertEntry(
      documentId: documentId,
      folderId: target,
      isShortcut: true,
      alias: alias,
    );
    _pushUndo('撤销快捷方式', () async {
      store.executeSql('DELETE FROM document_entries WHERE id = ?', [
        created.id,
      ]);
    });
    _notice = '已建立快捷方式。';
    _reload();
  });

  Future<void> removeEntry(String entryId) => _guard(() async {
    final entry = _entryById(entryId);
    if (entry == null) return;
    if (!entry.isShortcut) {
      await _trashEntries([entry], label: '资料');
      return;
    }
    late final DeletionBatch batch;
    store.transact(() {
      batch = repository.insertDeletionBatch(
        kind: 'shortcut',
        label: _documents[entry.documentId]?.title ?? '快捷方式',
        itemCount: 1,
        documentCount: 0,
      );
      repository.markEntriesDeleted([entry.id], batch.id, DateTime.now());
    });
    _pushUndo('撤销删除快捷方式', () async => restoreBatch(batch.id));
    _notice = '已删除这个快捷方式，原资料不受影响。';
    _reload();
  });

  // ---------------------------------------------------------------------------
  // Item operations
  // ---------------------------------------------------------------------------

  Future<void> renameItem(LibraryItem item, String name) => _guard(() async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw const LibraryException('名称不能为空。');
    if (trimmed.length > 200) throw const LibraryException('名称不要超过 200 个字符。');
    if (item.isShortcut) {
      store.transact(() {
        repository.updateEntry(
          item.entry.copyWith(alias: trimmed, clearAlias: false),
        );
      });
      _pushUndo('撤销重命名快捷方式', () async {
        final current = repository.entries(
          folderId: item.entry.folderId,
          unfiled: item.entry.folderId == null,
        ).where((entry) => entry.id == item.entry.id);
        if (current.isEmpty) return;
        repository.updateEntry(
          current.first.copyWith(
            alias: item.entry.alias,
            clearAlias: item.entry.alias == null,
          ),
        );
      });
    } else {
      final before = item.document.title;
      store.renameDocument(item.document.id, trimmed);
      _pushUndo('撤销重命名「$before」', () async {
        store.renameDocument(item.document.id, before);
      });
    }
    _notice = '已重命名为「$trimmed」。';
    _reload();
  });

  Future<void> toggleStar(String documentId) => _guard(() async {
    final document = store.getDocument(documentId);
    if (document == null) throw const LibraryException('资料已不存在。');
    store.setDocumentStarred(documentId, !document.starred);
    _notice = document.starred ? '已取消星标。' : '已加星标。';
    _reload();
  });

  Future<void> setLearningMode(String documentId, DocumentKind kind) =>
      _guard(() async {
        store.setDocumentLearningMode(documentId, kind);
        _notice = '学习方式已设为「${kind.label}」，笔记与作答不会清空。';
        _reload();
      });

  Future<void> assignTags(String documentId, Set<String> tagIds) =>
      _guard(() async {
        repository.setDocumentTags(documentId, tagIds);
        _notice = tagIds.isEmpty ? '已清除标签。' : '标签已更新。';
        _reload();
      });

  Future<LibraryTag?> createTag(String name) => _guard(() async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw const LibraryException('标签名称不能为空。');
    final existing = repository.tagByNorm(normalizeFolderName(trimmed));
    if (existing != null) {
      _notice = '标签「${existing.name}」已经存在。';
      return existing;
    }
    late final LibraryTag tag;
    store.transact(() {
      tag = repository.createTag(trimmed);
    });
    _reload();
    return tag;
  });

  Future<void> renameTag(String tagId, String name) => _guard(() async {
    final tag = _firstOrNull(_tags.where((item) => item.id == tagId));
    if (tag == null) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw const LibraryException('标签名称不能为空。');
    if (repository.tagByNorm(normalizeFolderName(trimmed)) != null) {
      throw const LibraryException('已经有同名标签。');
    }
    repository.renameTag(tag, trimmed);
    _reload();
  });

  Future<void> deleteTag(String tagId) => _guard(() async {
    final tag = _firstOrNull(_tags.where((item) => item.id == tagId));
    if (tag == null) return;
    repository.deleteTag(tagId);
    _notice = '已删除标签「${tag.name}」，资料本身保留。';
    _reload();
  });

  // ---------------------------------------------------------------------------
  // Trash
  // ---------------------------------------------------------------------------

  Future<void> trashSelection() => _guard(() async {
    final folders = _minimalFolderSet(_selectedFolders.toSet());
    final entries = [
      for (final id in _selectedEntries)
        if (_entryById(id) case final entry?)
          if (!_insideFolders(entry, folders)) entry,
    ];
    if (folders.isEmpty && entries.isEmpty) {
      throw const LibraryException('先选择要移入回收站的项目。');
    }
    await _trash(folders: folders, entries: entries);
  });

  Future<void> trashFolder(String folderId) => _guard(() async {
    await _trash(folders: {folderId}, entries: const []);
  });

  Future<void> trashDocument(String documentId) => _guard(() async {
    final primary = repository.primaryEntry(documentId);
    if (primary == null) {
      final entry = repository.entries().firstWhere(
        (item) => item.documentId == documentId,
        orElse: () => DocumentEntry(
          id: '',
          documentId: documentId,
          sortKey: 0,
          createdAt: DateTime.now(),
        ),
      );
      if (entry.id.isEmpty) throw const LibraryException('资料入口已不存在。');
      await _trashEntries([entry], label: '资料');
      return;
    }
    await _trashEntries([primary], label: '资料');
  });

  bool _insideFolders(DocumentEntry entry, Set<String> rootFolders) {
    var folderId = entry.folderId;
    final seen = <String>{};
    while (folderId != null && seen.add(folderId)) {
      if (rootFolders.contains(folderId)) return true;
      folderId = _folderById(folderId)?.parentId;
    }
    return false;
  }

  Future<void> _trash({
    required Set<String> folders,
    required List<DocumentEntry> entries,
  }) async {
    final now = DateTime.now();
    final folderSet = <String>{};
    for (final id in folders) {
      folderSet.addAll(descendantFolderIds(id, includeSelf: true));
    }
    final folderEntries = repository.activeEntriesInFolders(folderSet);
    final allEntries = <DocumentEntry>[
      ...entries,
      ...folderEntries,
    ];
    final byId = <String, DocumentEntry>{
      for (final entry in allEntries) entry.id: entry,
    };
    final documentIds = <String>{
      for (final entry in byId.values)
        if (!entry.isShortcut) entry.documentId,
    };
    final label = folders.isNotEmpty
        ? (folderById(folders.first)?.name ?? '文件夹')
        : (_documents[byId.values.first.documentId]?.title ?? '资料');
    late final DeletionBatch batch;
    store.transact(() {
      batch = repository.insertDeletionBatch(
        kind: folders.isNotEmpty
            ? 'folder'
            : documentIds.isEmpty
            ? 'shortcut'
            : 'documents',
        label: label,
        rootId: folders.isEmpty ? null : folders.first,
        itemCount: byId.length,
        documentCount: documentIds.length,
        details: {
          'folderIds': folderSet.toList(),
          'documentIds': documentIds.toList(),
          'entryIds': byId.keys.toList(),
        },
      );
      repository.markEntriesDeleted(byId.keys, batch.id, now);
      repository.markFoldersDeleted(folderSet, batch.id, now);
      for (final id in documentIds) {
        final document = store.getDocument(id);
        if (document == null || !document.isActive) continue;
        store.saveDocumentRecord(
          document.copyWith(
            lifecycle: DocumentLifecycle.trashed,
            lifecycleVersion: document.lifecycleVersion + 1,
            deletedBatch: batch.id,
            trashedAt: now,
          ),
        );
      }
      ReviewRepository(store).handleDocumentsLifecycleChanged(
        documentIds,
        available: false,
      );
    });
    for (final id in documentIds) {
      await documents.onLifecycleChanged(id);
    }
    if (currentFolder != null && folderSet.contains(currentFolder!.id)) {
      _view = _view.copyWith(scope: LibraryScope.all, clearFolder: true);
      _persistView();
    }
    _clearSelection();
    _pushUndo('撤销移入回收站', () async => restoreBatch(batch.id));
    _notice = '已移入回收站 ${byId.length} 项，可随时恢复。';
    _reload();
  }

  Future<void> _trashEntries(
    List<DocumentEntry> entries, {
    required String label,
  }) async {
    final now = DateTime.now();
    final documentsToTrash = <String>{};
    for (final entry in entries) {
      if (!entry.isShortcut) documentsToTrash.add(entry.documentId);
    }
    // Deleting a primary entry means the document leaves ordinary views; its
    // shortcuts elsewhere stay visible and are marked as in the trash.
    final ids = <String>{for (final entry in entries) entry.id};
    late final DeletionBatch batch;
    store.transact(() {
      batch = repository.insertDeletionBatch(
        kind: documentsToTrash.isEmpty ? 'shortcut' : 'documents',
        label: label,
        itemCount: ids.length,
        documentCount: documentsToTrash.length,
        details: {
          'entryIds': ids.toList(),
          'documentIds': documentsToTrash.toList(),
        },
      );
      repository.markEntriesDeleted(ids, batch.id, now);
      for (final id in documentsToTrash) {
        final document = store.getDocument(id);
        if (document == null || !document.isActive) continue;
        store.saveDocumentRecord(
          document.copyWith(
            lifecycle: DocumentLifecycle.trashed,
            lifecycleVersion: document.lifecycleVersion + 1,
            deletedBatch: batch.id,
            trashedAt: now,
          ),
        );
      }
      ReviewRepository(store).handleDocumentsLifecycleChanged(
        documentsToTrash,
        available: false,
      );
    });
    for (final id in documentsToTrash) {
      await documents.onLifecycleChanged(id);
    }
    _clearSelection();
    _pushUndo('撤销移入回收站', () async => restoreBatch(batch.id));
    _notice = '已移入回收站 ${ids.length} 项，可随时恢复。';
    _reload();
  }

  Future<void> restoreBatch(String batchId, {String? destinationFolderId}) =>
      _guard(() async {
        final batch = batchFor(batchId) ?? repository.deletionBatch(batchId);
        if (batch == null) throw const LibraryException('这个删除批次已经不存在。');
        final folders = repository.deletedFoldersInBatch(batchId);
        final entries = repository.deletedEntriesInBatch(batchId);
        final destination = destinationFolderId ??
            (batch.rootId == null ? null : _folderById(batch.rootId)?.id);
        var relocated = 0;
        var renamedFolders = 0;
        var mergedEntries = 0;
        final restoredFolders = <String>{};
        store.transact(() {
          final sorted = folders.toList()
            ..sort((a, b) => _folderDepth(a).compareTo(_folderDepth(b)));
          for (final folder in sorted) {
            var parentId = folder.parentId;
            if (parentId != null &&
                !restoredFolders.contains(parentId) &&
                _folderById(parentId) == null) {
              parentId = null;
              relocated++;
            }
            if (folder.parentId == batch.rootId &&
                destinationFolderId != null) {
              parentId = destinationFolderId;
            }
            var name = folder.name;
            if (repository.folderNameExists(
              parentId,
              name,
              exceptId: folder.id,
            )) {
              name = _availableRestoreName(parentId, name);
              renamedFolders++;
            }
            repository.updateFolder(
              folder.copyWith(
                name: name,
                parentId: parentId,
                clearParent: parentId == null,
                clearDeletedBatch: true,
                clearDeletedAt: true,
              ),
            );
            restoredFolders.add(folder.id);
          }
          for (final entry in entries) {
            var folderId = entry.folderId;
            if (folderId != null &&
                !restoredFolders.contains(folderId) &&
                _folderById(folderId) == null) {
              folderId = destination;
              if (folderId != null) relocated++;
            }
            if (folderId != null &&
                repository.entryInFolder(folderId, entry.documentId) != null) {
              if (entry.isShortcut) {
                // A live entry already represents this document in the target
                // folder; restoring a duplicate shortcut would violate the
                // one-entry-per-folder rule and add no value.
                repository.deleteEntryRow(entry.id);
                mergedEntries++;
                continue;
              }
              folderId = null;
              relocated++;
            }
            repository.updateEntry(
              entry.copyWith(
                folderId: folderId,
                clearFolder: folderId == null,
                clearDeletedBatch: true,
                clearDeletedAt: true,
              ),
            );
          }
          final restoredDocs = <String>[];
          for (final document in store.getDocuments(includeTrashed: true)) {
            if (document.deletedBatch != batchId) continue;
            store.saveDocumentRecord(
              document.copyWith(
                lifecycle: DocumentLifecycle.active,
                lifecycleVersion: document.lifecycleVersion + 1,
                clearDeletedBatch: true,
                clearTrashedAt: true,
              ),
            );
            restoredDocs.add(document.id);
          }
          if (restoredDocs.isNotEmpty) {
            ReviewRepository(store).handleDocumentsLifecycleChanged(
              restoredDocs,
              available: true,
            );
          }
          repository.deleteDeletionBatch(batchId);
        });
        final parts = <String>['已恢复「${batch.label}」'];
        if (relocated > 0) parts.add('$relocated 项调整了位置');
        if (renamedFolders > 0) parts.add('$renamedFolders 个重名文件夹已改名');
        if (mergedEntries > 0) parts.add('$mergedEntries 个重复快捷方式已合并');
        _notice = '${parts.join('，')}。';
        _reload();
      });

  /// Restores one trashed entry (and its document when needed) without
  /// touching the rest of the batch. Folder conflicts fall back to the root or
  /// the provided destination instead of overwriting an active folder.
  Future<void> restoreEntry(
    String entryId, {
    String? destinationFolderId,
  }) => _guard(() async {
    final entry = repository.entryById(entryId);
    if (entry == null || !entry.isDeleted) return;
    final batchId = entry.deletedBatch;
    final document = store.getDocument(entry.documentId);
    var folderId = destinationFolderId ?? entry.folderId;
    if (folderId != null && _folderById(folderId) == null) {
      folderId = null;
    }
    if (folderId != null &&
        repository.entryInFolder(folderId, entry.documentId) != null) {
      if (entry.isShortcut) {
        store.transact(() => repository.deleteEntryRow(entry.id));
        if (batchId != null) _cleanupDeletionBatch(batchId);
        _notice = '目标文件夹已经有这份资料，重复的快捷方式没有恢复。';
        _reload();
        return;
      }
      folderId = null;
    }
    var restoredDocument = false;
    store.transact(() {
      repository.updateEntry(
        entry.copyWith(
          folderId: folderId,
          clearFolder: folderId == null,
          clearDeletedBatch: true,
          clearDeletedAt: true,
        ),
      );
      if (document == null || document.isActive) return;
      store.saveDocumentRecord(
        document.copyWith(
          lifecycle: DocumentLifecycle.active,
          lifecycleVersion: document.lifecycleVersion + 1,
          clearDeletedBatch: true,
          clearTrashedAt: true,
        ),
      );
      restoredDocument = true;
      ReviewRepository(store).handleDocumentsLifecycleChanged(
        [document.id],
        available: true,
      );
      if (repository.primaryEntry(document.id) != null) return;
      final primary = repository.primaryEntryIncludingDeleted(document.id);
      if (primary == null) {
        repository.insertEntry(documentId: document.id);
        return;
      }
      if (primary.id == entry.id) return;
      var primaryFolder = primary.folderId;
      if (primaryFolder != null && _folderById(primaryFolder) == null) {
        primaryFolder = null;
      }
      if (primaryFolder != null &&
          repository.entryInFolder(primaryFolder, document.id) != null) {
        primaryFolder = null;
      }
      repository.updateEntry(
        primary.copyWith(
          folderId: primaryFolder,
          clearFolder: primaryFolder == null,
          clearDeletedBatch: true,
          clearDeletedAt: true,
        ),
      );
    });
    if (batchId != null) _cleanupDeletionBatch(batchId);
    _notice = restoredDocument
        ? '已恢复「${document?.title ?? '资料'}」及其入口。'
        : '已恢复这个入口。';
    _reload();
  });

  String _availableRestoreName(String? parentId, String desired) {
    var name = desired;
    var counter = 2;
    while (repository.folderNameExists(parentId, name)) {
      name = '$desired ($counter)';
      counter++;
    }
    return name;
  }

  void _cleanupDeletionBatch(String batchId) {
    if (!repository.batchHasRemainingItems(batchId)) {
      repository.deleteDeletionBatch(batchId);
    }
  }

  /// Permanently removes one trash entry. A shortcut removes only itself; a
  /// primary entry removes the document (which also removes its other
  /// shortcuts) and then any batch left empty by that cleanup.
  Future<void> purgeEntry(String entryId) => _guard(() async {
    final entry = repository.entryById(entryId);
    if (entry == null) return;
    final document = store.getDocument(entry.documentId);
    if (entry.isShortcut && (document == null || document.isActive)) {
      store.transact(() => repository.deleteEntryRow(entry.id));
      _cleanupEmptyBatches();
      _notice = '已永久删除这个快捷方式，原资料不受影响。';
      _reload();
      return;
    }
    final records = document == null ? <DocumentRecord>[] : [document];
    for (final record in records) {
      await documents.preparePurge(record.id);
    }
    store.transact(() {
      repository.purgeDocuments(records.map((record) => record.id));
      repository.deleteEntryRow(entry.id);
      if (entry.deletedBatch != null) {
        repository.purgeEntriesInBatch(entry.deletedBatch!);
        repository.deleteDeletionBatch(entry.deletedBatch!);
      }
    });
    for (final record in records) {
      await documents.finishPurge(record);
    }
    _cleanupEmptyBatches();
    _notice = records.isEmpty
        ? '已永久删除这个入口。'
        : '已永久删除「${records.first.title}」。外部原文件没有改动。';
    _reload();
  });

  void _cleanupEmptyBatches() {
    for (final batch in repository.deletionBatches()) {
      if (!repository.batchHasRemainingItems(batch.id)) {
        repository.deleteDeletionBatch(batch.id);
      }
    }
  }

  Future<void> purgeBatch(String batchId) => _guard(() async {
    await _purgeBatch(batchId);
    _reload();
  });

  Future<void> _purgeBatch(String batchId) async {
    final batch = batchFor(batchId) ?? repository.deletionBatch(batchId);
    if (batch == null) return;
    final folderIds = [
      for (final folder in repository.deletedFoldersInBatch(batchId)) folder.id,
    ];
    final records = [
      for (final document in store.getDocuments(includeTrashed: true))
        if (document.deletedBatch == batchId) document,
    ];
    for (final record in records) {
      await documents.preparePurge(record.id);
    }
    store.transact(() {
      repository.purgeDocuments(records.map((record) => record.id));
      repository.purgeEntriesInBatch(batchId);
      repository.purgeFolders(folderIds);
      repository.deleteDeletionBatch(batchId);
    });
    for (final record in records) {
      await documents.finishPurge(record);
    }
    _notice = '已永久删除 ${records.length} 份资料。外部原文件没有改动。';
  }

  Future<void> emptyTrash() => _guard(() async {
    for (final batch in [..._batches]) {
      await _purgeBatch(batch.id);
    }
    _reload();
  });

  Future<LibraryPurgeImpact> purgeImpactForSelection() async {
    final documentIds = <String>{};
    for (final folderId in _selectedFolders) {
      for (final entry in repository.activeEntriesInFolders(
        descendantFolderIds(folderId, includeSelf: true),
      )) {
        documentIds.add(entry.documentId);
      }
    }
    for (final id in _selectedEntries) {
      final entry = _entryById(id);
      if (entry != null) documentIds.add(entry.documentId);
    }
    return repository.purgeImpactForDocuments(documentIds);
  }

  // ---------------------------------------------------------------------------
  // Export
  // ---------------------------------------------------------------------------

  /// Copies selected originals (or one folder subtree) to a user directory.
  /// The managed directory can never be chosen as the destination, so an
  /// export cannot overwrite a source that the app is still reading.
  Future<LibraryExportReport?> exportSelection(String destination) =>
      _guard<LibraryExportReport?>(() async {
        _ensureExportDestination(destination);
        if (_selectedFolders.length == 1 && _selectedEntries.isEmpty) {
          return await exportFolderTo(_selectedFolders.first, destination);
        }
        final items = allSelectedItems;
        if (items.isEmpty) {
          throw const LibraryException('先选择要导出的资料。');
        }
        final report = await exportService.exportDocuments(items, destination);
        _noteExport(report);
        return report;
      });

  Future<LibraryExportReport?> exportFolderTo(
    String folderId,
    String destination,
  ) => _guard(() async {
    final folder = _folderById(folderId);
    if (folder == null) throw const LibraryException('这个文件夹已经不在书库里。');
    _ensureExportDestination(destination);
    final folderIds = descendantFolderIds(folderId, includeSelf: true);
    final folders = <LibraryFolder>[
      for (final candidate in _folders)
        if (folderIds.contains(candidate.id)) candidate,
    ]..sort((a, b) => _folderDepth(a).compareTo(_folderDepth(b)));
    final items = <LibraryItem>[];
    for (final entry in _entries) {
      if (entry.folderId == null || !folderIds.contains(entry.folderId)) {
        continue;
      }
      final document = _documents[entry.documentId];
      if (document == null || !document.isActive) continue;
      items.add(LibraryItem(entry: entry, document: document));
    }
    final report = await exportService.exportFolderTree(
      root: folder,
      folders: folders,
      items: items,
      destination: destination,
    );
    _noteExport(report);
    return report;
  });

  void _noteExport(LibraryExportReport report) {
    _notice = report.summary;
    if (report.failures.isNotEmpty) {
      _error = '导出未全部完成：${report.failures.first}';
    }
  }

  void _ensureExportDestination(String destination) {
    final root = p.normalize(p.absolute(documents.directory.path));
    final target = p.normalize(p.absolute(destination));
    if (target == root || p.isWithin(root, target)) {
      throw const LibraryException('不能导出到应用托管目录，请选择其他位置。');
    }
  }

  // ---------------------------------------------------------------------------
  // Locate helpers
  // ---------------------------------------------------------------------------

  /// Opens the folder that holds the document's primary entry and selects it.
  void locateDocument(String documentId) {
    final entry = repository.primaryEntry(documentId);
    if (entry == null) {
      _notice = '这份资料在回收站里，请先在回收站恢复。';
      _notify();
      return;
    }
    if (entry.folderId != null) {
      openFolder(entry.folderId!);
    } else {
      _view = _view.copyWith(
        scope: LibraryScope.unfiled,
        clearFolder: true,
      );
    }
    _selectedEntries
      ..clear()
      ..add(entry.id);
    _detailEntryId = entry.id;
    _persistView();
    _notify();
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  Future<T?> _guard<T>(Future<T> Function() action) async {
    if (_busy) {
      _error = '上一个文件操作还在进行，请稍候。';
      _notify();
      return null;
    }
    _busy = true;
    _error = null;
    _notify();
    try {
      return await action();
    } on LibraryException catch (error) {
      _error = error.message;
      _reload();
      return null;
    } catch (error) {
      _error = '$error';
      return null;
    } finally {
      _busy = false;
      _notify();
    }
  }

  void _pushUndo(String description, Future<void> Function() action) {
    _undo = LibraryUndo(description, action);
  }

  Future<void> undoLast() async {
    if (_busy) {
      _error = '上一个文件操作还在进行，请稍候。';
      _notify();
      return;
    }
    final undo = _undo;
    if (undo == null) {
      _notice = '没有可以撤销的文件操作。';
      _notify();
      return;
    }
    _undo = null;
    _error = null;
    _notify();
    try {
      // Undo actions call the same guarded operations a user menu would, so
      // this entry point must not hold `_busy` while they run.
      await undo.run();
      _notice = '已${undo.description}。';
    } catch (error) {
      _error = '无法撤销：$error';
    }
    _reload();
  }

  int _folderDepth(LibraryFolder folder) {
    var depth = 0;
    var current = folder.parentId;
    final seen = <String>{folder.id};
    while (current != null && seen.add(current)) {
      depth++;
      current = _folderById(current)?.parentId ??
          _deletedFolderById(current)?.parentId;
    }
    return depth;
  }

  Set<String> _minimalFolderSet(Set<String> ids) {
    final result = <String>{};
    for (final id in ids) {
      var parent = _folderById(id)?.parentId;
      var absorbed = false;
      final seen = <String>{};
      while (parent != null && seen.add(parent)) {
        if (ids.contains(parent)) {
          absorbed = true;
          break;
        }
        parent = _folderById(parent)?.parentId;
      }
      if (!absorbed) result.add(id);
    }
    return result;
  }

  int _compareFolders(LibraryFolder a, LibraryFolder b) {
    if (_view.sortField == LibrarySortField.name) {
      final result = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      return _view.ascending ? result : -result;
    }
    final result = a.sortKey.compareTo(b.sortKey);
    return result != 0 ? result : a.name.compareTo(b.name);
  }

  List<LibraryItem> _computeItems({bool ignoreSelectionScope = false}) {
    if (_view.scope == LibraryScope.trash) return const [];
    final cacheKey = jsonEncode([
      _revision,
      _view.scope.name,
      _view.folderId,
      _view.sortField.name,
      _view.ascending,
      _activeSmartFolderId,
      _effectiveQuery,
      _effectiveFilter.toJson(),
    ]);
    if (cacheKey == _itemCacheKey) return _itemCache;
    final query = _effectiveQuery.trim().toLowerCase();
    final scopeIds = query.isEmpty ? null : _scopeDocumentIds();
    final matching = query.isEmpty ? null : _search.ids;

    Iterable<DocumentEntry> base;
    if (_view.scope == LibraryScope.smart) {
      base = _primaryEntries();
    } else if (_view.scope == LibraryScope.folder) {
      final folderId = _view.folderId;
      if (folderId == null) {
        base = _primaryEntries();
      } else if (query.isNotEmpty &&
          _searchScope != LibrarySearchScope.currentFolder) {
        final ids = _searchScope == LibrarySearchScope.all
            ? null
            : descendantFolderIds(folderId, includeSelf: true);
        base = _primaryEntries().where(
          (entry) => ids == null || ids.contains(entry.folderId),
        );
      } else {
        base = _entries.where((entry) => entry.folderId == folderId);
      }
    } else if (_view.scope == LibraryScope.unfiled) {
      base = _entries.where(
        (entry) => entry.folderId == null && !entry.isShortcut,
      );
    } else if (_view.scope == LibraryScope.starred) {
      base = _primaryEntries().where(
        (entry) => _documents[entry.documentId]?.starred ?? false,
      );
    } else {
      base = _primaryEntries();
    }

    final items = <LibraryItem>[];
    for (final entry in base) {
      final document = _documents[entry.documentId];
      if (document == null) continue;
      if (query.isEmpty && _view.scope != LibraryScope.folder && !document.isActive) {
        continue;
      }
      if (matching != null && !matching.contains(entry.documentId)) continue;
      if (scopeIds != null && !scopeIds.contains(entry.documentId)) continue;
      if (!_matchesFilter(document, entry)) continue;
      items.add(LibraryItem(entry: entry, document: document));
    }

    if (_view.scope == LibraryScope.recent) {
      items.sort((a, b) => b.document.lastOpenedAt.compareTo(a.document.lastOpenedAt));
    } else {
      items.sort(_compareItems);
    }
    _itemCacheKey = cacheKey;
    _itemCache = items;
    return items;
  }

  Iterable<DocumentEntry> _primaryEntries() =>
      _entries.where((entry) => !entry.isShortcut);

  bool _matchesFilter(DocumentRecord document, DocumentEntry entry) {
    final filter = _effectiveFilter;
    if (filter.formats.isNotEmpty &&
        !filter.formats.contains(document.format.toLowerCase())) {
      return false;
    }
    if (filter.tagIds.isNotEmpty) {
      final tags = _tagIds[document.id] ?? const <String>{};
      if (!tags.any(filter.tagIds.contains)) return false;
    }
    if (filter.starredOnly && !document.starred) return false;
    if (filter.unreadOnly && document.currentPage > 1) return false;
    if (filter.processingOnly && !_needsProcessing(document.id)) {
      return false;
    }
    return true;
  }

  Set<String> _processingDocuments = const {};
  Map<String, PageProgress> _pageProgress = const {};

  Map<String, PageProgress> get pageProgress => _pageProgress;

  PageProgress progressFor(String documentId) =>
      _pageProgress[documentId] ?? const PageProgress(0, 0);

  bool _needsProcessing(String documentId) =>
      _processingDocuments.contains(documentId);

  int _compareItems(LibraryItem a, LibraryItem b) {
    var result = switch (_view.sortField) {
      LibrarySortField.manual => a.entry.sortKey.compareTo(b.entry.sortKey),
      LibrarySortField.name => a.displayName.toLowerCase().compareTo(
        b.displayName.toLowerCase(),
      ),
      LibrarySortField.addedAt => a.document.addedAt.compareTo(
        b.document.addedAt,
      ),
      LibrarySortField.openedAt => a.document.lastOpenedAt.compareTo(
        b.document.lastOpenedAt,
      ),
      LibrarySortField.size => a.document.sizeBytes.compareTo(
        b.document.sizeBytes,
      ),
      LibrarySortField.format => a.document.format.compareTo(
        b.document.format,
      ),
    };
    if (result == 0 &&
        (_view.sortField == LibrarySortField.manual ||
            _view.sortField == LibrarySortField.format)) {
      result = a.displayName.toLowerCase().compareTo(
        b.displayName.toLowerCase(),
      );
    }
    if (result == 0) result = a.entry.id.compareTo(b.entry.id);
    return _view.ascending ? result : -result;
  }

  Set<String>? _scopeDocumentIds() {
    if (_view.scope != LibraryScope.folder || _view.folderId == null) {
      return null;
    }
    if (_effectiveSearchScope == LibrarySearchScope.all) return null;
    final folders = _effectiveSearchScope == LibrarySearchScope.currentFolder
        ? {_view.folderId!}
        : descendantFolderIds(_view.folderId!, includeSelf: true);
    return {
      for (final entry in _entries)
        if (entry.folderId != null && folders.contains(entry.folderId))
          entry.documentId,
    };
  }

  _SearchCache get _search {
    if (_effectiveQuery.trim().isEmpty) return const _SearchCache({}, []);
    return _searchCache ??= _computeSearch();
  }

  _SearchCache _computeSearch() {
    final query = _effectiveQuery.trim();
    if (query.isEmpty) return const _SearchCache({}, []);
    final ids = repository.metadataMatches(query);
    final hits = <LibrarySearchHit>[];
    final evidence = store.searchEvidence(query, limit: 60);
    final grouped = <String, int>{};
    for (final item in evidence) {
      final document = _documents[item.documentId];
      if (document == null || !document.isActive) continue;
      ids.add(item.documentId);
      final count = grouped.update(item.documentId, (value) => value + 1, ifAbsent: () => 1);
      if (count > 3) continue;
      hits.add(
        LibrarySearchHit(
          document: document,
          reason: item.origin == EvidenceOrigin.ocr ? '识别文字' : '原文',
          page: item.page,
          snippet: item.text.length > 160
              ? '${item.text.substring(0, 160)}…'
              : item.text,
        ),
      );
    }
    return _SearchCache(ids, hits);
  }

  T? _firstOrNull<T>(Iterable<T> values) {
    for (final value in values) {
      return value;
    }
    return null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _reload() {
    _allFolders = repository.folders(includeDeleted: true);
    _folders = _allFolders.where((folder) => !folder.isDeleted).toList();
    _entries = repository.entries();
    _deletedEntries = repository.entries(includeDeleted: true)
        .where((entry) => entry.isDeleted)
        .toList();
    _documents = {
      for (final document in store.getDocuments(includeTrashed: true))
        document.id: document,
    };
    _tags = repository.tags();
    _tagIds = repository.documentTagIds();
    _counts = repository.counts();
    _batches = repository.deletionBatches();
    _processingDocuments = _loadProcessingDocuments();
    _searchCache = null;
    if (_activeSmartFolderId != null &&
        !_smartFolders.any((folder) => folder.id == _activeSmartFolderId)) {
      _activeSmartFolderId = null;
      _view = _view.copyWith(clearSmartFolder: true);
    }
    if (_view.scope == LibraryScope.smart && _activeSmartFolderId == null) {
      _view = _view.copyWith(scope: LibraryScope.all, clearSmartFolder: true);
    }
    if (_view.scope == LibraryScope.folder &&
        _folderById(_view.folderId) == null) {
      _view = _view.copyWith(scope: LibraryScope.all, clearFolder: true);
    }
    _selectedEntries.removeWhere(
      (id) => !_entries.any((entry) => entry.id == id),
    );
    _selectedFolders.removeWhere((id) => _folderById(id) == null);
    if (_detailEntryId != null &&
        !_entries.any((entry) => entry.id == _detailEntryId)) {
      _detailEntryId = null;
    }
    _revision++;
    _itemCacheKey = null;
    _notify();
  }

  Set<String> _loadProcessingDocuments() {
    try {
      final rows = store.selectRows(
        '''SELECT document_id,
          COUNT(*) AS total,
          SUM(CASE WHEN status = 'ready' THEN 1 ELSE 0 END) AS ready
        FROM pages GROUP BY document_id''',
      );
      final progress = <String, PageProgress>{};
      final pending = <String>{};
      for (final row in rows) {
        final id = row['document_id'] as String;
        final total = (row['total'] as num).toInt();
        final ready = (row['ready'] as num?)?.toInt() ?? 0;
        progress[id] = PageProgress(ready, total);
        if (ready < total) pending.add(id);
      }
      _pageProgress = progress;
      return pending;
    } catch (_) {
      _pageProgress = const {};
      return const {};
    }
  }

  /// Recomputes everything after a learning-side change (rename, star or
  /// lifecycle from another page).
  void refresh() {
    _reload();
  }

  Future<void> refreshSizes() async {
    var changed = false;
    for (final document in _documents.values.toList()) {
      if (document.sizeBytes > 0) continue;
      try {
        final file = File(document.filePath);
        if (!await file.exists()) continue;
        final length = await file.length();
        if (length <= 0) continue;
        store.saveDocumentRecord(document.copyWith(sizeBytes: length));
        changed = true;
      } catch (_) {
        /* A missing managed copy is reported by the detail panel. */
      }
    }
    if (changed) _reload();
  }

  @override
  void dispose() {
    _disposed = true;
    queue.dispose();
    super.dispose();
  }
}

class PageProgress {
  const PageProgress(this.ready, this.total);
  final int ready;
  final int total;

  bool get hasPages => total > 0;
  bool get complete => hasPages && ready == total;
  double get ratio => hasPages ? ready / total : 0;
}

class _SearchCache {
  const _SearchCache(this.ids, this.hits);
  final Set<String> ids;
  final List<LibrarySearchHit> hits;
}
