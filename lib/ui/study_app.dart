import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../app_controller.dart';
import '../core/models.dart';
import '../features/book_qa/book_qa_controller.dart';
import '../features/library/library_controller.dart';
import '../features/notes/data/notes_repository.dart';
import '../features/notes/models/note_models.dart';
import '../features/notes/notes_controller.dart';
import '../features/notes/ui/notes_page.dart';
import '../features/notes/ui/notes_sidebar_tree.dart';
import '../features/library/ui/library_tree.dart';
import '../features/review/models/review_models.dart';
import '../features/schedule/data/schedule_repository.dart';
import '../features/schedule/models/lesson_review.dart';
import '../features/schedule/models/material_ref.dart';
import '../features/schedule/models/plan_source.dart';
import '../features/schedule/models/study_task.dart';
import '../features/schedule/schedule_controller.dart';
import '../features/schedule/ui/daily_lesson.dart';
import '../features/schedule/ui/schedule_page.dart';
import '../services/ai_gateway.dart';
import '../services/document_service.dart';
import 'dialogs/app_dialogs.dart';
import 'pages/library_page.dart';
import 'pages/review_page.dart';
import 'reader/reader_page.dart';
import 'settings/settings_dialog.dart';
import 'shell/app_shell.dart';
import 'shell/window_title_bar.dart';
import 'theme/app_theme.dart';
import 'widgets/app_surfaces.dart';
import 'theme/appearance.dart';
import 'theme/tokens.dart';

class StudyApp extends StatefulWidget {
  const StudyApp({
    super.key,
    required this.controller,
    this.showWindowChrome = false,
  });
  final StudyController controller;

  /// The real desktop entrypoint enables the custom Windows caption. Widget
  /// tests leave it off so their viewport models the content area only.
  final bool showWindowChrome;

  @override
  State<StudyApp> createState() => _StudyAppState();
}

class _StudyAppState extends State<StudyApp> {
  late final AppearanceController _appearance = AppearanceController(
    widget.controller.store,
  );

  @override
  void dispose() {
    _appearance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _appearance,
    builder: (context, _) => MaterialApp(
      title: 'Quelyt',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: lightTheme,
      darkTheme: darkTheme,
      themeMode: _appearance.themeMode,
      themeAnimationDuration: Motion.base,
      themeAnimationCurve: Motion.curve,
      builder: (context, child) => WindowFrame(
        enabled: widget.showWindowChrome,
        child: child ?? const SizedBox.shrink(),
      ),
      home: StudyHome(
        controller: widget.controller,
        appearance: _appearance,
        showWindowChrome: widget.showWindowChrome,
      ),
    ),
  );
}

class StudyHome extends StatefulWidget {
  const StudyHome({
    super.key,
    required this.controller,
    required this.appearance,
    required this.showWindowChrome,
  });

  final StudyController controller;
  final AppearanceController appearance;
  final bool showWindowChrome;

  @override
  State<StudyHome> createState() => _StudyHomeState();
}

class _StudyHomeState extends State<StudyHome> {
  AppSection _section = AppSection.library;
  bool _openPanelOnStart = false;
  bool _sidebarCollapsed = false;
  final _searchController = TextEditingController();
  late final ScheduleController _schedule;
  late final BookQaController _bookQa;
  late final LibraryController _library;
  late final NotesController _notes;
  late final Listenable _appListenable;
  String _query = '';
  String? _lastOpenedId;

  StudyController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onGlobalKey);
    _schedule = ScheduleController(
      ScheduleRepository(widget.controller.store),
      ai: widget.controller.gateway,
      settingsProvider: () => widget.controller.settings,
    );
    _schedule.initialize();
    _schedule.addListener(_onScheduleChanged);
    _bookQa = BookQaController(study: widget.controller);
    _bookQa.attach(widget.controller.current);
    _library = LibraryController(
      store: widget.controller.store,
      documents: widget.controller.documents,
    );
    _library.addListener(_onLibraryChanged);
    _notes = NotesController(
      store: c.store,
      repository: NotesRepository(c.store),
      library: _library.repository,
    );
    _notes.initialize();
    _notes.addListener(_onNotesChanged);
    unawaited(_library.queue.restoreJournal());
    unawaited(_library.refreshSizes());
    widget.controller.addListener(_onStudyChanged);
    _lastOpenedId = widget.controller.current?.id;
    _appListenable = Listenable.merge([
      widget.controller,
      widget.controller.reviewController,
      _bookQa,
      _library,
    ]);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onGlobalKey);
    widget.controller.removeListener(_onStudyChanged);
    _schedule.removeListener(_onScheduleChanged);
    _schedule.dispose();
    _bookQa.dispose();
    _library.removeListener(_onLibraryChanged);
    _library.dispose();
    _notes.removeListener(_onNotesChanged);
    _notes.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onStudyChanged() {
    _bookQa.attach(c.current);
    final current = c.current;
    if (current?.id != _lastOpenedId) {
      _lastOpenedId = current?.id;
      _library.refresh();
    }
    // A document can enter the trash while its reader is open. Saving drafts is
    // handled by the reader; here the library forces a safe return instead of
    // leaving a page whose writes are already rejected.
    if (current != null) {
      final stored = c.store.getDocument(current.id);
      if (stored == null || !stored.isActive) {
        unawaited(c.backToLibrary());
        _library.refresh();
      }
    }
  }

  void _onLibraryChanged() {
    if (!mounted) return;
    c.reviewController.refresh();
    final current = c.current;
    if (current == null) return;
    final stored = c.store.getDocument(current.id);
    if (stored == null || !stored.isActive) {
      unawaited(c.backToLibrary());
    }
  }

  void _onNotesChanged() {
    if (!mounted) return;
    c.reviewRepository.detectUpdatedSourceNotes();
    c.reviewController.refresh();
    setState(() {});
  }

  void _onScheduleChanged() {
    if (!mounted) return;
    c.reviewController.refresh();
    setState(() {});
  }

  /// Global shortcut that does not depend on which widget currently owns
  /// focus. A `CallbackShortcuts` widget only works while a descendant has
  /// primary focus; after clicking a non-focusable area Windows still sends
  /// keys to the Flutter view, so a hardware handler is the reliable place.
  bool _onGlobalKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (!HardwareKeyboard.instance.isControlPressed) return false;
    if (!mounted) return false;
    if (ModalRoute.of(context)?.isCurrent == false) return false;
    if (event.logicalKey == LogicalKeyboardKey.comma) {
      _openSettings();
      return true;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyB && c.current == null) {
      _toggleSidebar();
      return true;
    }
    return false;
  }

  int get _pendingCount {
    final checks = c.reviewController.summary.openChecksCount;
    final due = c.reviewController.summary.dueCount;
    var legacyChecks = 0;
    if (checks == 0) {
      for (final doc in c.library) {
        legacyChecks += c.store
            .getSessions(doc.id)
            .where((session) => session.needsReview)
            .length;
      }
    }
    return checks + due + legacyChecks;
  }

  List<DocumentRecord> get _recentDocuments {
    final docs = [...c.library];
    docs.sort((a, b) => b.lastOpenedAt.compareTo(a.lastOpenedAt));
    return docs.take(6).toList();
  }

  String _scheduleSubtitle() {
    final summary = _schedule.summaryFor(_schedule.today);
    if (summary.count == 0) return '今日暂无安排';
    return '今日 ${summary.count} 项 · ${summary.minutes} 分钟';
  }

  Future<void> _openMaterial(MaterialRef material) async {
    final document = c.store.getDocument(material.documentId);
    if (document == null ||
        !document.isActive ||
        document.contentHash != material.documentHash) {
      _toast('原资料已移除或版本变更，日程记录仍保留。');
      return;
    }
    await c.open(document);
    if (c.current?.id == document.id) {
      await c.goToPage(material.startPage);
    }
  }

  Future<void> _openLessonReview(LessonReviewItem item) async {
    setState(() => _section = AppSection.schedule);
    if (item.block != null) {
      _schedule.selectDate(item.block!.date);
    }
    if (!mounted) return;
    await showDailyLesson(
      context,
      _schedule,
      item.task,
      blockId: item.block?.id,
    );
  }

  Future<void> _openTaskMaterial(StudyTask task, MaterialRef material) async {
    final document = c.store.getDocument(material.documentId);
    if (document == null ||
        !document.isActive ||
        document.contentHash != material.documentHash) {
      _toast('原资料已移除或版本变更，日程记录仍保留。');
      return;
    }
    if (c.current?.id != document.id) {
      await c.open(document);
    }
    if (c.current?.id != document.id) {
      _toast('无法打开这份教材，已保留日历位置。');
      return;
    }
    final currentTask = _schedule.repository.getTask(task.id) ?? task;
    final boundId = currentTask.readerSessionBindings[material.documentId];
    var restored = false;
    if (boundId != null) {
      final matches = c.store
          .getSessions(document.id)
          .where((session) => session.id == boundId)
          .toList();
      final bound = matches.isEmpty ? null : matches.first;
      if (bound != null &&
          bound.startPage == material.startPage &&
          bound.endPage == material.endPage) {
        restored = await c.restoreSession(boundId, page: material.startPage);
      }
    }
    if (!restored) {
      c.beginSession(
        start: material.startPage,
        end: material.endPage,
        goal: currentTask.title,
        minutes: currentTask.minutes,
      );
      final sessionId = c.session?.id;
      if (sessionId != null) {
        final latest = _schedule.repository.getTask(task.id) ?? currentTask;
        _schedule.repository.saveTask(
          latest.copyWith(
            readerSessionBindings: {
              ...latest.readerSessionBindings,
              material.documentId: sessionId,
            },
          ),
        );
      }
      await c.goToPage(material.startPage);
    }
  }

  Future<MaterialPreparationResult> _prepareMaterial(PlanSource source) async {
    final document = c.store.getDocument(source.documentId);
    if (document == null) {
      return MaterialPreparationResult(
        coverage: _schedule.repository.coverageFor(source),
        message: '这份资料已被删除，无法补齐。',
      );
    }
    if (document.contentHash != source.documentHash) {
      return MaterialPreparationResult(
        coverage: _schedule.repository.coverageFor(source),
        message: '资料版本已改变，请重新绑定后再补齐。',
      );
    }
    final pending = _schedule.repository.pagesNeedingAttention(source);
    if (pending.isEmpty) {
      return MaterialPreparationResult(
        coverage: _schedule.repository.coverageFor(source),
        message: '这段材料已经全部可读，不需要补齐。',
      );
    }
    final opened = await c.documents.open(document);
    var processed = 0;
    try {
      for (final page in pending) {
        await c.documents.indexPage(opened, page);
        processed++;
      }
    } finally {
      await opened.dispose();
    }
    final coverage = _schedule.repository.coverageFor(source);
    return MaterialPreparationResult(
      coverage: coverage,
      processed: processed,
      message: coverage.allReady
          ? '已补齐 $processed 页，这段材料现在全部可读。'
          : '已处理 $processed 页；仍有 ${coverage.attentionPages} 页需要处理，'
                '可检查本地 OCR 或原页文字后再次补齐。',
    );
  }

  void _toggleSidebar() {
    setState(() => _sidebarCollapsed = !_sidebarCollapsed);
  }

  void _setQuery(String value) {
    setState(() => _query = value);
  }

  void _clearQuery() {
    _searchController.clear();
    setState(() => _query = '');
  }

  void _toast(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _openSettings([
    SettingsSection section = SettingsSection.general,
  ]) => showSettingsDialog(
    context,
    controller: c,
    appearance: widget.appearance,
    initialSection: section,
  );


  Future<void> _navigate(AppSection section) async {
    if (c.sending) {
      _toast('请等待当前请求完成');
      return;
    }
    if (c.current != null || c.opened != null) {
      await c.backToLibrary();
    }
    if (!mounted) return;
    if (section == AppSection.library) _library.refresh();
    setState(() {
      _section = section;
      _openPanelOnStart = false;
    });
  }

  Future<void> _openFromLibrary(DocumentRecord document) async {
    await c.open(document);
    if (c.current?.id == document.id) {
      _library.refresh();
    }
  }

  Future<void> _openNoteById(String noteId) async {
    if (c.current != null || c.opened != null) {
      await c.backToLibrary();
    }
    if (!mounted) return;
    _notes.reload();
    _notes.setScope(NotesScope.all);
    _notes.select(noteId, force: true);
    setState(() {
      _section = AppSection.notes;
      _openPanelOnStart = false;
    });
  }

  Future<void> _openNoteFromReader(String noteId) async {
    await c.backToLibrary();
    if (!mounted) return;
    _notes.reload();
    _notes.setScope(NotesScope.all);
    _notes.select(noteId, force: true);
    setState(() {
      _section = AppSection.notes;
      _openPanelOnStart = false;
    });
  }

  Future<void> _createNoteForDocument(DocumentRecord document) async {
    final primary = _library.repository.primaryEntry(document.id);
    final created = _notes.createNote(
      title: '${document.title} · 读书笔记',
      folderId: primary?.folderId,
      sources: [
        NoteSource(
          id: 'src-${DateTime.now().microsecondsSinceEpoch}',
          noteId: '',
          documentId: document.id,
          documentHash: document.contentHash,
          page: document.currentPage > 0 ? document.currentPage : 1,
          excerpt: '关联资料：${document.title}',
          createdAt: DateTime.now(),
        ),
      ],
    );
    _library.refresh();
    if (created != null) {
      await _openNoteById(created.id);
    }
  }

  Future<void> _openNoteSource(NoteSource source) async {
    final documentId = source.documentId;
    if (documentId == null) {
      _toast('这条来源没有关联资料。');
      return;
    }
    final document = c.store.getDocument(documentId);
    if (document == null || !document.isActive) {
      _toast('来源资料已移除，摘录仍保留在笔记中。');
      return;
    }
    if (document.contentHash != source.documentHash) {
      _toast('来源版本已变更，无法定位原页码。');
      return;
    }
    if (c.current?.id != document.id) {
      await c.open(document);
    }
    if (c.current?.id != document.id) return;
    setState(() => _section = AppSection.notes);
    await c.jumpToEvidence(
      Evidence(
        id: 'note-source-${source.id}',
        documentId: document.id,
        documentHash: document.contentHash,
        page: source.page ?? 1,
        region: source.region,
        text: source.excerpt,
      ),
    );
  }

  Future<void> _openReviewOrigin(ReviewOrigin origin) async {
    if (origin.noteId != null) {
      await _openNoteById(origin.noteId!);
      return;
    }
    final docId = origin.documentId;
    if (docId == null) {
      _toast('该复习题未绑定教材出处。');
      return;
    }
    final doc = c.store.getDocument(docId);
    if (doc == null || !doc.isActive) {
      _toast('原教材已移除，文本快照仍保留在题目中。');
      return;
    }
    if (origin.documentHash.isNotEmpty &&
        doc.contentHash != origin.documentHash) {
      _toast('教材文件版本已变更，已尽量定位到页码。');
    }
    if (c.current?.id != doc.id) {
      await c.open(doc);
    }
    if (c.current?.id == doc.id) {
      await c.goToPage(origin.page ?? 1);
    }
  }

  Future<void> _practice(DocumentRecord document, StudySession session) async {
    if (c.sending) {
      _toast('请等待当前请求完成');
      return;
    }
    await c.open(document);
    if (c.current?.id != document.id) return;
    c.saveSession(session.copyWith(answer: '', stage: 'question'));
    await c.goToPage(session.startPage);
    if (!mounted) return;
    setState(() {
      _section = AppSection.library;
      _openPanelOnStart = true;
    });
  }

  Future<void> _request(AiTask task, String question, bool range) async {
    if (c.sending) return;
    try {
      var wholePage = false;
      while (mounted) {
        ImageAttachment? image;
        if (task == AiTask.explainImage) {
          if (c.raster == null) {
            _toast('请等待页面渲染完成');
            return;
          }
          if (!wholePage && c.selection == null) {
            _toast('先在原页框选一张图、表或公式');
            return;
          }
          final bytes = await cropPage(
            c.raster!,
            wholePage ? SourceRegion.fullPage : c.selection!,
          );
          image = ImageAttachment(
            bytes: bytes,
            mimeType: 'image/png',
            scopeLabel: '第 ${c.page} 页 · ${wholePage ? '当前整页' : '框选区域'}',
          );
        }
        final prepared = c.prepare(
          task,
          question,
          image: image,
          useRange: range,
        );
        if (!mounted) return;
        final action = await showRequestPreview(
          context,
          request: prepared,
          wholePage: wholePage,
        );
        if (action == 'scope') {
          wholePage = !wholePage;
          continue;
        }
        if (action == 'send') {
          await c.send(
            prepared,
            approval: image == null ? null : prepared.approveImage(),
          );
        }
        return;
      }
    } catch (error) {
      if (mounted) _toast(error.toString());
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _appListenable,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (c.current != null && _openPanelOnStart) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _openPanelOnStart = false);
          });
        }
        final activeView = c.current != null
            ? ReaderPage(
                key: ValueKey('reader-${c.current!.id}'),
                controller: c,
                appearance: widget.appearance,
                section: _section,
                onNavigate: _navigate,
                onBack: () => c.backToLibrary(),
                onRequest: _request,
                onJump: c.jumpToEvidence,
                bookQa: _bookQa,
                showRail: false,
                showWindowChrome: widget.showWindowChrome,
                openPanelOnStart: _openPanelOnStart,
                onOpenOcrSettings: () => _openSettings(SettingsSection.ocr),
                onOpenNoteInWorkspace: _openNoteFromReader,
              )
            : KeyedSubtree(
                key: const ValueKey('main-shell'),
                child: _mainShell(context, width),
              );
        return AnimatedSwitcher(
          duration: context.motion(Motion.slow),
          switchInCurve: Motion.curve,
          switchOutCurve: Curves.easeIn,
          layoutBuilder: (currentChild, previousChildren) => Stack(
            fit: StackFit.expand,
            children: [...previousChildren, ?currentChild],
          ),
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.992, end: 1.0).animate(
                CurvedAnimation(parent: animation, curve: Motion.curve),
              ),
              child: child,
            ),
          ),
          child: activeView,
        );
      },
    ),
  );

  Widget _mainShell(BuildContext context, double width) {
    final docked = width >= 760;
    final compact = !docked;
    final pending = _pendingCount;
    final subtitle = switch (_section) {
      AppSection.library =>
        '${_library.counts.all} 份资料'
            '${_library.folders.isEmpty ? '' : ' · ${_library.folders.length} 个文件夹'}',
      AppSection.notes =>
        '${_notes.counts.all} 篇笔记'
            '${_notes.counts.openQuestions == 0 ? '' : ' · ${_notes.counts.openQuestions} 个待解决问题'}',
      AppSection.schedule => _scheduleSubtitle(),
      AppSection.review => () {
        final s = c.reviewController.summary;
        if (s.dueCount > 0 && s.openChecksCount > 0) {
          return '今日到期 ${s.dueCount} 题 · ${s.openChecksCount} 项待核对';
        }
        if (s.dueCount > 0) return '今日到期 ${s.dueCount} 题';
        if (s.openChecksCount > 0 || pending > 0) {
          return '${s.openChecksCount > 0 ? s.openChecksCount : pending} 项待核对';
        }
        return '暂无待核对';
      }(),
    };
    final ownsHeader = _section == AppSection.library;
    final errorBanner = c.error != null
        ? AppErrorCallout(message: c.error!, onDismiss: c.clearError)
        : null;
    final header = ownsHeader
        ? null
        : MediaQuery.withClampedTextScaling(
            maxScaleFactor: 1.35,
            child: UnifiedHeader(
              title: _section.label,
              subtitle: subtitle,
              sidebarCollapsed: _sidebarCollapsed,
              onToggleSidebar: _toggleSidebar,
              onOpenSettings: () => _openSettings(),
              showSidebarToggle: docked,
              showSubtitle: width >= 1000,
              showWindowChrome: widget.showWindowChrome,
              compact: compact,
            ),
          );
    final sidebarOpen = docked && !_sidebarCollapsed;
    final content = Column(
      children: [
        ?header,
        if (!ownsHeader && errorBanner != null) errorBanner,
        Expanded(
          child: SectionSwitcher(
            child: KeyedSubtree(
              key: ValueKey(_section),
              child: _page(
                sidebarOpen: sidebarOpen,
                docked: docked,
                topBanner: errorBanner,
              ),
            ),
          ),
        ),
      ],
    );
    final body = docked
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AnimatedSwitcher(
                duration: context.motion(Motion.base),
                switchInCurve: Motion.curve,
                switchOutCurve: Curves.easeIn,
                layoutBuilder: (currentChild, previousChildren) => Stack(
                  fit: StackFit.passthrough,
                  alignment: Alignment.centerLeft,
                  children: [...previousChildren, ?currentChild],
                ),
                transitionBuilder: (child, animation) {
                  final curved = CurvedAnimation(
                    parent: animation,
                    curve: Motion.curve,
                  );
                  return FadeTransition(
                    opacity: curved,
                    child: SizeTransition(
                      axis: Axis.horizontal,
                      sizeFactor: curved,
                      alignment: Alignment.centerLeft,
                      child: child,
                    ),
                  );
                },
                child: sidebarOpen
                    ? KeyedSubtree(
                        key: const ValueKey('app-sidebar-open'),
                        child: AppSidebar(
                          section: _section,
                          onSelect: _navigate,
                          onOpenDocument: (doc) async {
                            await c.open(doc);
                          },
                          onOpenSettings: () => _openSettings(),
                          onCollapse: _toggleSidebar,
                          documents: _recentDocuments,
                          library: _library,
                          notes: _notes,
                          libraryCount: _library.counts.all,
                          notesCount: _notes.counts.all,
                          pendingCount: pending,
                        ),
                      )
                    : const SizedBox.shrink(key: ValueKey('app-sidebar-closed')),
              ),
              Expanded(child: content),
            ],
          )
        : content;
    return Scaffold(
      backgroundColor: context.colors.surface,
      drawer: compact &&
              (_section == AppSection.library || _section == AppSection.notes)
          ? Drawer(
              backgroundColor: context.colors.sidebar,
              child: SafeArea(
                child: _section == AppSection.library
                    ? LibraryTree(controller: _library, drawer: true)
                    : NotesSidebarTree(controller: _notes, drawer: true),
              ),
            )
          : null,
      body: SafeArea(
        child: Focus(autofocus: true, child: body),
      ),
      bottomNavigationBar: compact
          ? AppBottomNav(section: _section, onSelect: _navigate)
          : null,
    );
  }

  Widget _page({
    required bool sidebarOpen,
    required bool docked,
    required Widget? topBanner,
  }) => switch (_section) {
    AppSection.library => LibraryPage(
      study: c,
      library: _library,
      query: _query,
      onClearSearch: _clearQuery,
      onOpenDocument: _openFromLibrary,
      onOpenNote: _openNoteById,
      onCreateNoteForDocument: _createNoteForDocument,
      searchController: _searchController,
      onSearchChanged: _setQuery,
      sidebarCollapsed: _sidebarCollapsed,
      onToggleSidebar: _toggleSidebar,
      onOpenSettings: () => _openSettings(),
      showSidebarToggle: docked,
      showWindowChrome: widget.showWindowChrome,
      topBanner: topBanner,
    ),
    AppSection.notes => NotesPage(
      controller: _notes,
      study: c,
      onOpenSource: _openNoteSource,
      showSidebar: false,
    ),
    AppSection.schedule => SchedulePage(
      controller: _schedule,
      onOpenMaterial: _openMaterial,
      onOpenTaskMaterial: _openTaskMaterial,
      onOpenSettings: () => _openSettings(SettingsSection.models),
      onPrepareMaterial: _prepareMaterial,
    ),
    AppSection.review => ReviewPage(
      controller: c,
      onPractice: _practice,
      onGoLibrary: () => setState(() {
        _section = AppSection.library;
        _openPanelOnStart = false;
      }),
      lessonReviews: () => _schedule.repository.getLessonReviewItems(),
      onOpenLesson: _openLessonReview,
      onOpenSource: _openReviewOrigin,
    ),
  };

}
