import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/local_store.dart';
import '../library/data/library_repository.dart';
import '../library/models/library_models.dart';
import 'data/notes_repository.dart';
import 'models/note_models.dart';

/// Owns the global notes list and one editable note. All storage calls are
/// synchronous SQLite operations; the debounce only avoids writing on every
/// keystroke. A disposed controller flushes the pending edit once.
class NotesController extends ChangeNotifier {
  NotesController({
    required this.store,
    required this.repository,
    required this.library,
  });

  final LocalStore store;
  final NotesRepository repository;
  final LibraryRepository library;

  List<LibraryFolder> folders = const [];
  List<LibraryTag> tags = const [];
  List<NoteRecord> notes = const [];
  NoteCounts counts = const NoteCounts();
  Map<String, int> folderCounts = const {};
  Map<String, NoteListSummary> summaries = const {};
  NotesScope scope = NotesScope.all;
  String? scopeFolderId;
  String query = '';
  String? tagFilter;
  NotesSortBy sortBy = NotesSortBy.updatedAt;
  bool sortAsc = false;
  List<String> _lastTrashedIds = const [];

  bool get canUndoTrash => _lastTrashedIds.isNotEmpty;

  NoteRecord? selected;
  NoteEntry? selectedEntry;
  List<NoteSource> selectedSources = const [];
  List<NoteQuestion> selectedQuestions = const [];
  Set<String> selectedTagIds = const {};

  String draftTitle = '';
  String draftBody = '';
  bool dirty = false;
  String saveState = 'saved';
  String? error;
  String? notice;

  Timer? _saveTimer;
  bool _disposed = false;
  bool _saving = false;
  bool _pendingSave = false;

  void initialize() {
    reload();
  }

  void reload({bool keepSelection = true}) {
    folders = repository.folders();
    tags = repository.tags();
    notes = _sorted(
      repository.list(
        scope: scope,
        folderId: scope == NotesScope.folder ? scopeFolderId : null,
        query: query,
        tagId: tagFilter,
      ),
    );
    counts = repository.counts();
    folderCounts = repository.countsByFolder();
    summaries = repository.summariesFor(notes.map((note) => note.id));
    if (keepSelection &&
        selected != null &&
        notes.any((note) => note.id == selected!.id)) {
      // Keep the same editing session; only the list projection changed.
    } else if (selected != null && scope == NotesScope.trash) {
      // Trash keeps an editable preview until the user leaves the scope.
    }
    notifyListeners();
  }

  List<NoteRecord> _sorted(List<NoteRecord> items) {
    final result = [...items];
    final direction = sortAsc ? 1 : -1;
    result.sort((a, b) {
      final primary = switch (sortBy) {
        NotesSortBy.updatedAt => a.updatedAt.compareTo(b.updatedAt) * direction,
        NotesSortBy.createdAt => a.createdAt.compareTo(b.createdAt) * direction,
        NotesSortBy.title =>
          a.displayTitle
                  .toLowerCase()
                  .compareTo(b.displayTitle.toLowerCase()) *
              (sortAsc ? 1 : -1),
        NotesSortBy.starred =>
          a.starred == b.starred
              ? a.updatedAt.compareTo(b.updatedAt) * direction
              : (a.starred ? -1 : 1),
      };
      if (primary != 0) return primary;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return result;
  }

  void setSortBy(NotesSortBy value) {
    if (sortBy == value) {
      sortAsc = !sortAsc;
    } else {
      sortBy = value;
      sortAsc = value == NotesSortBy.title;
    }
    reload();
  }

  void toggleSortAsc() {
    sortAsc = !sortAsc;
    reload();
  }

  void setScope(NotesScope value, {String? folderId}) {
    flushNow();
    scope = value;
    scopeFolderId = value == NotesScope.folder ? folderId : null;
    reload();
  }

  void openFolder(String? folderId) {
    setScope(NotesScope.folder, folderId: folderId);
  }

  void setQuery(String value) {
    query = value;
    reload();
  }

  void setTagFilter(String? tagId) {
    tagFilter = tagId;
    reload();
  }

  void select(String id, {bool force = false}) {
    if (selected?.id == id && !force) return;
    flushNow();
    final note = repository.getNote(id);
    if (note == null) return;
    selected = note;
    selectedEntry = repository.primaryEntry(id);
    selectedSources = repository.sources(id);
    selectedQuestions = repository.questions(id);
    selectedTagIds = repository.tagIds(id);
    draftTitle = note.title;
    draftBody = note.body;
    dirty = false;
    saveState = 'saved';
    error = null;
    repository.touch(id);
    notifyListeners();
  }

  void closeSelected() {
    flushNow();
    selected = null;
    selectedEntry = null;
    selectedSources = const [];
    selectedQuestions = const [];
    selectedTagIds = const {};
    draftTitle = '';
    draftBody = '';
    dirty = false;
    notifyListeners();
  }

  NoteRecord? createNote({
    String? folderId,
    String title = '',
    String body = '',
    List<NoteSource> sources = const [],
  }) {
    flushNow();
    final targetFolderId =
        folderId ?? (scope == NotesScope.folder ? scopeFolderId : null);
    final note = repository.create(
      title: title,
      body: body,
      folderId: targetFolderId,
      sources: sources,
    );
    final keepFolderScope =
        scope == NotesScope.folder && targetFolderId == scopeFolderId;
    final keepUnfiledScope =
        scope == NotesScope.unfiled && targetFolderId == null;
    final keepRelatedScope =
        scope == NotesScope.related && sources.isNotEmpty;
    if (!keepFolderScope &&
        !keepUnfiledScope &&
        !keepRelatedScope &&
        scope != NotesScope.all &&
        scope != NotesScope.recent) {
      scope = NotesScope.all;
      scopeFolderId = null;
    }
    if (query.isNotEmpty) {
      query = '';
    }
    folders = repository.folders();
    reload(keepSelection: false);
    select(note.id);
    return note;
  }

  void editTitle(String value) {
    if (value == draftTitle) return;
    draftTitle = value;
    _markDirty();
  }

  void editBody(String value) {
    if (value == draftBody) return;
    draftBody = value;
    _markDirty();
  }

  void _markDirty() {
    dirty = true;
    saveState = 'saving';
    error = null;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 700), flushNow);
    notifyListeners();
  }

  /// Writes the pending draft. Safe to call from navigation, app lifecycle and
  /// dispose; only a successful write changes [selected].
  void flushNow() {
    _saveTimer?.cancel();
    _saveTimer = null;
    final note = selected;
    if (note == null || !dirty) return;
    if (_saving) {
      _pendingSave = true;
      return;
    }
    _saving = true;
    try {
      final saved = repository.save(
        note.copyWith(
          title: draftTitle,
          body: draftBody,
          updatedAt: DateTime.now(),
        ),
        expectedRevision: note.revision,
      );
      selected = saved;
      selectedEntry = repository.primaryEntry(saved.id);
      dirty = false;
      saveState = 'saved';
      error = null;
      _refreshListProjection();
    } catch (failure) {
      saveState = 'error';
      error = '$failure';
      notifyListeners();
    } finally {
      _saving = false;
      if (_pendingSave && dirty && !_disposed) {
        _pendingSave = false;
        flushNow();
      }
    }
  }

  void saveNow() => flushNow();

  void loadRevisions(NoteRecord note) {}

  List<NoteRevision> revisions() =>
      selected == null ? const [] : repository.revisions(selected!.id);

  void restoreRevision(NoteRevision revision) {
    repository.restoreRevision(revision);
    select(revision.noteId, force: true);
    _refreshListProjection();
    notifyListeners();
  }

  void toggleStar() {
    final note = selected;
    if (note == null) return;
    repository.setStarred(note.id, !note.starred);
    selected = repository.getNote(note.id);
    _refreshListProjection();
    notifyListeners();
  }

  void toggleStarFor(String noteId) {
    final note = repository.getNote(noteId);
    if (note == null) return;
    repository.setStarred(noteId, !note.starred);
    if (selected?.id == noteId) selected = repository.getNote(noteId);
    _refreshListProjection();
    notifyListeners();
  }

  void moveToFolder(String? folderId) {
    final note = selected;
    if (note == null) return;
    flushNow();
    repository.move(note.id, folderId);
    selectedEntry = repository.primaryEntry(note.id);
    folders = repository.folders();
    _refreshListProjection();
    notifyListeners();
  }

  void setTags(Set<String> tagIds) {
    final note = selected;
    if (note == null) return;
    repository.setTags(note.id, tagIds);
    selectedTagIds = tagIds;
    _refreshListProjection();
    notifyListeners();
  }

  LibraryFolder createFolder(String name, {String? parentId}) {
    final folder = library.insertFolder(name: name, parentId: parentId);
    folders = repository.folders();
    notifyListeners();
    return folder;
  }

  LibraryTag createTag(String name) {
    final tag = library.createTag(name);
    tags = repository.tags();
    notifyListeners();
    return tag;
  }

  void addQuestion(String text) {
    final note = selected;
    final value = text.trim();
    if (note == null || value.isEmpty) return;
    repository.addQuestion(
      NoteQuestion(
        id: '',
        noteId: note.id,
        text: value,
        createdAt: DateTime.now(),
      ),
    );
    selectedQuestions = repository.questions(note.id);
    _refreshListProjection();
    notifyListeners();
  }

  void toggleQuestion(NoteQuestion question) {
    repository.toggleQuestion(question);
    if (selected != null) {
      selectedQuestions = repository.questions(selected!.id);
    }
    _refreshListProjection();
    notifyListeners();
  }

  void deleteQuestion(NoteQuestion question) {
    repository.deleteQuestion(question.id);
    if (selected != null) {
      selectedQuestions = repository.questions(selected!.id);
    }
    _refreshListProjection();
    notifyListeners();
  }

  void deleteSource(NoteSource source) {
    repository.deleteSource(source.id);
    if (selected != null) {
      selectedSources = repository.sources(selected!.id);
    }
    _refreshListProjection();
    notifyListeners();
  }

  void trashSelected() {
    final note = selected;
    if (note == null) return;
    trashNote(note.id);
  }

  void trashNote(String noteId) {
    flushNow();
    final batch = repository.trash([noteId]);
    if (batch.isEmpty) return;
    _lastTrashedIds = [noteId];
    if (selected?.id == noteId) {
      selected = null;
      selectedEntry = null;
      selectedSources = const [];
      selectedQuestions = const [];
      selectedTagIds = const {};
      draftTitle = '';
      draftBody = '';
      dirty = false;
    }
    reload(keepSelection: true);
    if (selected == null && notes.isNotEmpty && scope != NotesScope.trash) {
      select(notes.first.id);
    }
    notice = '笔记已移入回收站。';
    notifyListeners();
  }

  void undoLastTrash() {
    if (_lastTrashedIds.isEmpty) return;
    final ids = [..._lastTrashedIds];
    _lastTrashedIds = const [];
    repository.restore(ids);
    reload(keepSelection: true);
    if (ids.isNotEmpty) {
      select(ids.first);
    }
    notice = '已撤销删除并恢复笔记。';
    notifyListeners();
  }

  void restoreSelected() {
    final note = selected;
    if (note == null) return;
    restoreNote(note.id);
  }

  void restoreNote(String noteId) {
    repository.restore([noteId]);
    _lastTrashedIds = const [];
    if (scope == NotesScope.trash) {
      reload(keepSelection: false);
      if (selected?.id == noteId) {
        selected = null;
        selectedEntry = null;
      }
    } else {
      reload(keepSelection: true);
      select(noteId);
    }
    notice = '笔记已恢复。';
    notifyListeners();
  }

  void purgeSelected() {
    final note = selected;
    if (note == null) return;
    purgeNote(note.id);
  }

  void purgeNote(String noteId) {
    repository.purge([noteId]);
    _lastTrashedIds = const [];
    if (selected?.id == noteId) {
      selected = null;
      selectedEntry = null;
      selectedSources = const [];
      selectedQuestions = const [];
      selectedTagIds = const {};
      draftTitle = '';
      draftBody = '';
      dirty = false;
    }
    reload(keepSelection: false);
    notice = '笔记已永久删除。';
    notifyListeners();
  }

  void emptyTrash() {
    final trashed = repository.list(scope: NotesScope.trash);
    if (trashed.isEmpty) return;
    repository.purge(trashed.map((n) => n.id).toList());
    _lastTrashedIds = const [];
    if (selected != null && selected!.isTrashed) {
      selected = null;
      selectedEntry = null;
      selectedSources = const [];
      selectedQuestions = const [];
      selectedTagIds = const {};
      draftTitle = '';
      draftBody = '';
      dirty = false;
    }
    reload(keepSelection: false);
    notice = '回收站已清空。';
    notifyListeners();
  }

  List<LibraryFolder> childrenOf(String? parentId) => [
    for (final folder in folders)
      if (folder.parentId == parentId) folder,
  ];

  String folderName(String? id) {
    if (id == null) return '未归档';
    for (final folder in folders) {
      if (folder.id == id) return folder.name;
    }
    return '未归档';
  }

  String folderPath(String? id) {
    if (id == null) return '未归档';
    final byId = {for (final folder in folders) folder.id: folder};
    final names = <String>[];
    var current = byId[id];
    var guard = 0;
    while (current != null && guard++ < 64) {
      names.insert(0, current.name);
      current = current.parentId == null ? null : byId[current.parentId];
    }
    return names.isEmpty ? '未归档' : names.join(' / ');
  }

  int noteCountForFolder(String folderId) => folderCounts[folderId] ?? 0;

  int openQuestionsFor(String noteId) {
    if (selected?.id == noteId) {
      return selectedQuestions.where((q) => q.isOpen).length;
    }
    return summaries[noteId]?.openQuestions ?? 0;
  }

  void clearNotice() {
    notice = null;
    notifyListeners();
  }

  void clearMessages() {
    notice = null;
    error = null;
    notifyListeners();
  }

  void _refreshListProjection() {
    notes = _sorted(
      repository.list(
        scope: scope,
        folderId: scope == NotesScope.folder ? scopeFolderId : null,
        query: query,
        tagId: tagFilter,
      ),
    );
    counts = repository.counts();
    folderCounts = repository.countsByFolder();
    summaries = repository.summariesFor(notes.map((note) => note.id));
  }

  @override
  void dispose() {
    flushNow();
    _disposed = true;
    _saveTimer?.cancel();
    super.dispose();
  }
}
