import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../app_controller.dart';
import '../core/models.dart';
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
  String _query = '';

  StudyController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onGlobalKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onGlobalKey);
    _searchController.dispose();
    super.dispose();
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
    var count = 0;
    for (final doc in c.library) {
      count += c.store
          .getSessions(doc.id)
          .where((session) => session.needsReview)
          .length;
    }
    return count;
  }

  List<DocumentRecord> get _recentDocuments {
    final docs = [...c.library];
    docs.sort((a, b) => b.lastOpenedAt.compareTo(a.lastOpenedAt));
    return docs.take(6).toList();
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

  Future<void> _import() => _importAs(null);

  Future<void> _importAs(DocumentKind? kind) async {
    if (c.importing || c.loading) return;
    final selected = kind ?? await showImportKindDialog(context);
    if (selected == null || !mounted) return;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'png', 'jpg', 'jpeg'],
        withData: false,
        allowMultiple: false,
      );
      final path = result?.files.single.path;
      if (path == null) return;
      if (!mounted) return;
      setState(() {
        _section = AppSection.library;
        _openPanelOnStart = false;
      });
      await c.importPath(path, selected);
    } catch (error) {
      if (mounted) _toast('文件选择失败：$error');
    }
  }

  Future<void> _navigate(AppSection section) async {
    if (c.sending) {
      _toast('请等待当前请求完成');
      return;
    }
    if (c.current != null || c.opened != null) {
      await c.backToLibrary();
    }
    if (!mounted) return;
    setState(() {
      _section = section;
      _openPanelOnStart = false;
    });
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
    listenable: c,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (c.current != null) {
          if (_openPanelOnStart) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => _openPanelOnStart = false);
            });
          }
          return ReaderPage(
            controller: c,
            appearance: widget.appearance,
            section: _section,
            onNavigate: _navigate,
            onBack: () => c.backToLibrary(),
            onRequest: _request,
            onJump: c.jumpToEvidence,
            showRail: false,
            showWindowChrome: widget.showWindowChrome,
            openPanelOnStart: _openPanelOnStart,
            onOpenOcrSettings: () => _openSettings(SettingsSection.ocr),
          );
        }
        return _mainShell(context, width);
      },
    ),
  );

  Widget _mainShell(BuildContext context, double width) {
    final docked = width >= 760;
    final compact = !docked;
    final pending = _pendingCount;
    final subtitle = switch (_section) {
      AppSection.library => '${c.library.length} 份资料',
      AppSection.review => pending > 0 ? '$pending 项待核对' : '暂无待核对',
    };
    final searchWidth = compact
        ? 136.0
        : width >= 1200
        ? 240.0
        : width >= 900
        ? 200.0
        : 160.0;
    final search = _section == AppSection.library
        ? _HeaderSearch(
            width: searchWidth,
            compact: compact,
            controller: _searchController,
            onChanged: _setQuery,
            onClear: _clearQuery,
          )
        : null;
    final header = MediaQuery.withClampedTextScaling(
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
        search: search,
        importAction: _section == AppSection.library
            ? _importAction(compact: compact || width < 1000)
            : null,
      ),
    );
    final sidebarOpen = docked && !_sidebarCollapsed;
    final content = Column(
      children: [
        header,
        if (c.error != null)
          AppErrorCallout(message: c.error!, onDismiss: c.clearError),
        Expanded(child: _page()),
      ],
    );
    final body = sidebarOpen
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppSidebar(
                section: _section,
                onSelect: _navigate,
                onOpenDocument: (doc) async {
                  await c.open(doc);
                },
                onOpenSettings: () => _openSettings(),
                onCollapse: _toggleSidebar,
                documents: _recentDocuments,
                libraryCount: c.library.length,
                pendingCount: pending,
              ),
              Expanded(child: content),
            ],
          )
        : content;
    return Scaffold(
      backgroundColor: context.colors.surface,
      body: SafeArea(
        child: Focus(autofocus: true, child: body),
      ),
      bottomNavigationBar: compact
          ? AppBottomNav(section: _section, onSelect: _navigate)
          : null,
    );
  }

  Widget _page() => switch (_section) {
    AppSection.library => LibraryPage(
      controller: c,
      onImportKind: _importAs,
      query: _query,
      onClearSearch: _clearQuery,
    ),
    AppSection.review => ReviewPage(
      controller: c,
      onPractice: _practice,
      onGoLibrary: () => setState(() {
        _section = AppSection.library;
        _openPanelOnStart = false;
      }),
    ),
  };

  Widget _importAction({required bool compact}) {
    final onPressed = c.importing || c.loading ? null : _import;
    if (compact) {
      return IconButton(
        tooltip: '导入资料',
        onPressed: onPressed,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
        icon: const Icon(Icons.add_rounded, size: 20),
      );
    }
    return FilledButton.icon(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        textStyle: context.texts.labelLarge!.copyWith(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
        ),
      ),
      icon: const Icon(Icons.add_rounded, size: 16),
      label: const Text('导入资料'),
    );
  }
}

/// Header search with an explicit 34/36px box.
///
/// The previous `TextField` decoration carried its own minimum height, which
/// made the box look top-heavy inside the 48px header. The border and the
/// input are now separate: the outer box owns the vertical centring.
class _HeaderSearch extends StatefulWidget {
  const _HeaderSearch({
    required this.width,
    required this.compact,
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  final double width;
  final bool compact;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  State<_HeaderSearch> createState() => _HeaderSearchState();
}

class _HeaderSearchState extends State<_HeaderSearch> {
  final _focus = FocusNode();
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocus);
    _focus.dispose();
    super.dispose();
  }

  void _onFocus() {
    if (mounted) setState(() => _focused = _focus.hasFocus);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final height = widget.compact ? 34.0 : 36.0;
    return SizedBox(
      width: widget.width,
      height: height,
      child: AnimatedContainer(
        duration: context.motion(Motion.fast),
        curve: Motion.curve,
        decoration: BoxDecoration(
          color: c.sidebar,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: _focused ? c.outlineStrong : c.outline,
          ),
        ),
        child: Row(
          children: [
            const SizedBox(width: 10),
            Icon(Icons.search_rounded, size: 16, color: c.inkMuted),
            const SizedBox(width: 6),
            Expanded(
              child: TextField(
                controller: widget.controller,
                focusNode: _focus,
                onChanged: widget.onChanged,
                textAlignVertical: TextAlignVertical.center,
                style: context.texts.bodySmall!.copyWith(
                  color: c.ink,
                  fontSize: widget.compact ? 12.5 : 13.5,
                  height: 1.2,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  filled: false,
                  fillColor: Colors.transparent,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  hintText: '查找资料名称',
                  hintStyle: context.texts.bodySmall!.copyWith(
                    color: c.inkMuted,
                    fontSize: widget.compact ? 12.5 : 13.5,
                  ),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
            if (widget.controller.text.isNotEmpty)
              IconButton(
                tooltip: '清除搜索',
                onPressed: widget.onClear,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(
                  minWidth: 28,
                  minHeight: 28,
                ),
                padding: EdgeInsets.zero,
                icon: Icon(Icons.close_rounded, size: 15, color: c.inkMuted),
              )
            else
              const SizedBox(width: 4),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}
