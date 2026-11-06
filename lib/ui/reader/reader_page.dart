import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_controller.dart';
import '../../core/models.dart';
import '../../services/ai_gateway.dart';
import '../dialogs/app_dialogs.dart';
import '../learning_panel.dart';
import '../page_surface.dart';
import '../shell/app_chrome.dart';
import '../shell/app_shell.dart';
import '../shell/window_title_bar.dart';
import '../theme/appearance.dart';
import '../theme/tokens.dart';
import '../widgets/app_surfaces.dart';
import 'learning_dock.dart';

enum _ReaderMode { compact, medium, desktop }

class ReaderPage extends StatefulWidget {
  const ReaderPage({
    super.key,
    required this.controller,
    required this.appearance,
    required this.section,
    required this.onNavigate,
    required this.onBack,
    required this.onRequest,
    required this.onJump,
    this.showRail = false,
    this.showWindowChrome = false,
    this.openPanelOnStart = false,
    this.onOpenOcrSettings,
  });

  final StudyController controller;
  final AppearanceController appearance;
  final AppSection section;
  final ValueChanged<AppSection> onNavigate;
  final VoidCallback onBack;
  final Future<void> Function(AiTask, String, bool) onRequest;
  final Future<void> Function(Evidence) onJump;
  final bool showRail;
  final bool showWindowChrome;
  final bool openPanelOnStart;
  final VoidCallback? onOpenOcrSettings;

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage>
    with SingleTickerProviderStateMixin {
  final _pageKey = GlobalKey<PageSurfaceState>();
  final Set<int> _dismissedCallouts = {};
  late final TabController _tabs;
  bool _panelOpen = true;
  double? _panelWidth;
  bool _drawerOpen = false;
  double? _sheetFraction;
  bool _draggingSheet = false;
  double _sheetAreaHeight = 0;
  double _collapsedFraction = .08;
  bool _hintVisible = true;
  _ReaderMode _mode = _ReaderMode.desktop;

  StudyController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _hintVisible = !widget.appearance.readerHintSeen;
    _drawerOpen = widget.openPanelOnStart;
    if (widget.openPanelOnStart) _sheetFraction = .5;
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _toast(String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));

  bool get _typing {
    final focus = FocusManager.instance.primaryFocus;
    final context = focus?.context;
    if (context == null) return false;
    if (context.widget is EditableText) return true;
    return context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  bool get _sheetExpanded =>
      _sheetFraction != null && _sheetFraction! > _collapsedFraction + .01;

  void _togglePanel() {
    setState(() {
      switch (_mode) {
        case _ReaderMode.desktop:
          _panelOpen = !_panelOpen;
        case _ReaderMode.medium:
          _drawerOpen = !_drawerOpen;
        case _ReaderMode.compact:
          _sheetFraction = _sheetExpanded ? _collapsedFraction : .5;
      }
    });
  }

  bool get _panelActive => switch (_mode) {
    _ReaderMode.desktop => _panelOpen,
    _ReaderMode.medium => _drawerOpen,
    _ReaderMode.compact => _sheetExpanded,
  };

  /// Opening a dock item; clicking the active item again closes the panel.
  void _selectLearningTab(int index) {
    final closing = _panelActive && _tabs.index == index;
    setState(() {
      switch (_mode) {
        case _ReaderMode.desktop:
          _panelOpen = !closing;
        case _ReaderMode.medium:
          _drawerOpen = !closing;
        case _ReaderMode.compact:
          _sheetFraction = closing ? _collapsedFraction : .5;
      }
    });
    if (!closing) _tabs.animateTo(index);
  }

  Widget _learningDock({required bool vertical, bool floating = false}) =>
      AnimatedBuilder(
        animation: _tabs,
        builder: (context, _) => LearningDock(
          kind: c.current!.kind,
          selectedIndex: _panelActive ? _tabs.index : null,
          replyCount: c.replies.length,
          noteCount: c.notes.length,
          onSelect: _selectLearningTab,
          vertical: vertical,
          floating: floating,
        ),
      );

  Future<void> _jump(Evidence evidence) async {
    await widget.onJump(evidence);
    if (!mounted) return;
    if (_mode == _ReaderMode.compact) {
      setState(() => _sheetFraction = _collapsedFraction);
    } else if (_mode == _ReaderMode.medium) {
      setState(() => _drawerOpen = false);
    }
  }

  Future<void> _addNote() async {
    final draft = await showNoteDialog(
      context,
      page: c.page,
      hasSelection: c.selection != null,
    );
    if (draft == null) return;
    c.addNote(understanding: draft.understanding, question: draft.question);
    if (mounted) _toast('笔记已保存。');
  }

  Future<void> _jumpPageDialog() async {
    final document = c.current;
    if (document == null) return;
    final target = await showJumpPageDialog(
      context,
      current: c.page,
      pageCount: document.pageCount,
    );
    if (target != null) await c.goToPage(target);
  }

  Future<void> _correctText() async {
    final result = await showCorrectTextDialog(
      context,
      text: c.currentPage?.text ?? '',
      page: c.page,
    );
    if (result == null) return;
    try {
      await c.correctText(result);
      if (mounted) _toast('本页文字已更新，检索与出处仍定位到这一页。');
    } catch (error) {
      if (mounted) _toast('保存失败：$error');
    }
  }

  Future<void> _search() async {
    if (!mounted) return;
    await showSearchDialog(context, controller: c);
  }

  void _toggleSelecting() => _pageKey.currentState?.toggleSelecting();

  void _fit() => _pageKey.currentState?.fit();

  void _rotate() => _pageKey.currentState?.rotate();

  void _zoom(double factor) => _pageKey.currentState?.zoomBy(factor);

  void _escape() {
    if (_mode == _ReaderMode.medium && _drawerOpen) {
      setState(() => _drawerOpen = false);
      return;
    }
    if (_mode == _ReaderMode.compact && _sheetExpanded) {
      setState(() => _sheetFraction = _collapsedFraction);
      return;
    }
    if (c.selection != null) {
      _pageKey.currentState?.clearSelection();
    }
  }

  void _previousPage() {
    if (_typing || c.page <= 1) return;
    c.goToPage(c.page - 1);
  }

  void _nextPage() {
    final total = c.current?.pageCount ?? 1;
    if (_typing || c.page >= total) return;
    c.goToPage(c.page + 1);
  }

  Map<ShortcutActivator, VoidCallback> get _shortcuts => {
    const SingleActivator(LogicalKeyboardKey.arrowLeft): _previousPage,
    const SingleActivator(LogicalKeyboardKey.pageUp): _previousPage,
    const SingleActivator(LogicalKeyboardKey.arrowRight): _nextPage,
    const SingleActivator(LogicalKeyboardKey.pageDown): _nextPage,
    const SingleActivator(LogicalKeyboardKey.keyG, control: true):
        _jumpPageDialog,
    const SingleActivator(LogicalKeyboardKey.keyF, control: true): _search,
    const SingleActivator(LogicalKeyboardKey.keyB, control: true): _togglePanel,
    const SingleActivator(LogicalKeyboardKey.keyS, control: true, shift: true):
        _toggleSelecting,
    const SingleActivator(LogicalKeyboardKey.equal, control: true): () =>
        _zoom(1.2),
    const SingleActivator(LogicalKeyboardKey.numpadAdd, control: true): () =>
        _zoom(1.2),
    const SingleActivator(LogicalKeyboardKey.minus, control: true): () =>
        _zoom(.84),
    const SingleActivator(
      LogicalKeyboardKey.numpadSubtract,
      control: true,
    ): () =>
        _zoom(.84),
    const SingleActivator(LogicalKeyboardKey.digit0, control: true): _fit,
    const SingleActivator(LogicalKeyboardKey.keyR, control: true): _rotate,
    const SingleActivator(LogicalKeyboardKey.escape): _escape,
  };

  @override
  Widget build(BuildContext context) {
    final document = c.current!;
    return Scaffold(
      backgroundColor: context.colors.canvas,
      body: SafeArea(
        child: Focus(
          autofocus: true,
          child: CallbackShortcuts(
            bindings: _shortcuts,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                _mode = width >= 1100
                    ? _ReaderMode.desktop
                    : width >= 600
                    ? _ReaderMode.medium
                    : _ReaderMode.compact;
                final body = switch (_mode) {
                  _ReaderMode.desktop => _desktop(document),
                  _ReaderMode.medium => _medium(document, width),
                  _ReaderMode.compact => _compact(document, constraints),
                };
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    body,
                    if (_mode != _ReaderMode.compact)
                      Positioned(
                        left: 16,
                        top: 64,
                        child: _learningDock(vertical: true, floating: true),
                      ),
                    if (widget.showWindowChrome)
                      const Positioned(
                        top: 0,
                        right: 0,
                        child: WindowCaptionControls(),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _desktop(DocumentRecord document) {
    // A fixed-width study rail reads better than a percentage: the page keeps
    // the remaining 1000px+ on a 1440 window while answers stay comfortable.
    final panelWidth = (_panelWidth ?? 400.0).clamp(380.0, 560.0).toDouble();
    return Row(
      children: [
        Expanded(child: _pageColumn(document)),
        if (_panelOpen)
          _ResizeHandle(
            onDrag: (dx) => setState(() {
              _panelWidth = (panelWidth - dx).clamp(380.0, 560.0).toDouble();
            }),
            onReset: () => setState(() => _panelWidth = null),
          ),
        ClipRect(
          child: AnimatedContainer(
            duration: context.motion(Motion.slow),
            curve: Motion.curve,
            width: _panelOpen ? panelWidth : 0,
            child: OverflowBox(
              alignment: Alignment.centerLeft,
              minWidth: panelWidth,
              maxWidth: panelWidth,
              child: SizedBox(
                width: panelWidth,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: context.colors.surface,
                    border: Border(
                      left: BorderSide(color: context.colors.outline),
                    ),
                  ),
                  child: _panel(
                    trailing: widget.showWindowChrome
                        ? const SizedBox(width: AppChrome.captionWidth)
                        : null,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _medium(DocumentRecord document, double width) {
    final drawerWidth = math.min(440.0, width * .92);
    return Stack(
      children: [
        _pageColumn(document),
        if (_drawerOpen)
          Positioned.fill(
            child: GestureDetector(
              onTap: () => setState(() => _drawerOpen = false),
              child: ColoredBox(color: Colors.black.withValues(alpha: .32)),
            ),
          ),
        AnimatedPositioned(
          duration: context.motion(Motion.slow),
          curve: Motion.curve,
          right: _drawerOpen ? 0 : -drawerWidth - 12,
          top: 0,
          bottom: 0,
          width: drawerWidth,
          child: Container(
            decoration: BoxDecoration(
              color: context.colors.surface,
              border: Border(left: BorderSide(color: context.colors.outline)),
            ),
            child: Column(
              children: [
                Container(
                  height: AppChrome.titleBarHeight,
                  padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.sm, 0),
                  child: Row(
                    children: [
                      AccentIcon(
                        icon: Icons.school_outlined,
                        accent: context.colors.blueAccent,
                        size: 28,
                        iconSize: 16,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          document.kind == DocumentKind.textbook
                              ? '教材学习面板'
                              : '论文精读面板',
                          style: context.texts.titleSmall!.copyWith(
                            fontSize: 14.5,
                          ),
                        ),
                      ),
                      if (widget.showWindowChrome)
                        const SizedBox(width: AppChrome.captionWidth),
                    ],
                  ),
                ),
                Divider(height: 1, color: context.colors.outline),
                Expanded(child: _panel(showHeader: false)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _compact(DocumentRecord document, BoxConstraints constraints) {
    final available = constraints.maxHeight;
    _sheetAreaHeight = available;
    final collapsed = _collapsedSheetHeight(context);
    final collapsedFraction = (collapsed / math.max(available, 1))
        .clamp(.05, .28)
        .toDouble();
    _collapsedFraction = collapsedFraction;
    final fraction = (_sheetFraction ?? collapsedFraction)
        .clamp(collapsedFraction, .9)
        .toDouble();
    final expanded = fraction > collapsedFraction + .01;
    final height = math.max(collapsed, available * fraction);
    return Column(
      children: [
        Expanded(child: _pageColumn(document)),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Align(
            alignment: Alignment.centerLeft,
            child: _learningDock(vertical: false, floating: true),
          ),
        ),
        AnimatedContainer(
          duration: _draggingSheet
              ? Duration.zero
              : context.motion(Motion.slow),
          curve: Motion.curve,
          height: height,
          child: Container(
            decoration: BoxDecoration(
              color: context.colors.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(Radii.lg),
              ),
              border: Border(
                top: BorderSide(color: context.colors.outline),
                left: BorderSide(color: context.colors.outline),
                right: BorderSide(color: context.colors.outline),
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x1F000000),
                  blurRadius: 18,
                  offset: Offset(0, -4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(Radii.lg),
              ),
              child: Column(
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() {
                      _sheetFraction = expanded ? collapsedFraction : .5;
                    }),
                    onVerticalDragStart: (_) =>
                        setState(() => _draggingSheet = true),
                    onVerticalDragUpdate: (details) {
                      if (_sheetAreaHeight <= 0) return;
                      final base = _sheetFraction ?? collapsedFraction;
                      final next = (base - details.delta.dy / _sheetAreaHeight)
                          .clamp(collapsedFraction, .9)
                          .toDouble();
                      setState(() => _sheetFraction = next);
                    },
                    onVerticalDragEnd: (details) {
                      final base = _sheetFraction ?? collapsedFraction;
                      final velocity = details.primaryVelocity ?? 0;
                      double target;
                      if (velocity < -300) {
                        target = base < .7 ? .9 : .9;
                      } else if (velocity > 300) {
                        target = base > .7 ? .5 : collapsedFraction;
                      } else {
                        target = [collapsedFraction, .5, .9].reduce(
                          (a, b) => (a - base).abs() < (b - base).abs() ? a : b,
                        );
                      }
                      setState(() {
                        _draggingSheet = false;
                        _sheetFraction = target;
                      });
                    },
                    child: _sheetHeader(document, expanded),
                  ),
                  if (expanded)
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, inner) {
                          // The sheet animates its height; laying the panel
                          // out at a stable minimum prevents a transient
                          // overflow before the animation settles.
                          final layoutHeight = math.max(inner.maxHeight, 300.0);
                          return ClipRect(
                            child: OverflowBox(
                              alignment: Alignment.topCenter,
                              minHeight: layoutHeight,
                              maxHeight: layoutHeight,
                              child: SizedBox(
                                height: layoutHeight,
                                child: _panel(showHeader: false),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _sheetHeader(DocumentRecord document, bool expanded) {
    final colors = context.colors;
    final session = c.session;
    final stage = session?.stage;
    final step = switch (stage) {
      'question' || 'answered' => '第 2 步 · 独立作答',
      'feedback' => '第 3 步 · 核对反馈',
      _ => session == null ? '尚未设定这一节' : '第 1 步 · 阅读',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.lg, 6, Space.lg, 6),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: colors.outlineStrong,
              borderRadius: BorderRadius.circular(Radii.full),
            ),
          ),
          const SizedBox(height: 7),
          Row(
            children: [
              Icon(Icons.school_outlined, size: 17, color: colors.primary),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  document.kind == DocumentKind.textbook
                      ? '学习面板 · $step'
                      : '论文精读 · $step',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.bodySmall!.copyWith(
                    fontSize: 13,
                    color: colors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(
                expanded
                    ? Icons.keyboard_arrow_down_rounded
                    : Icons.keyboard_arrow_up_rounded,
                size: 20,
                color: colors.inkMuted,
              ),
            ],
          ),
        ],
      ),
    );
  }

  double _collapsedSheetHeight(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(13) / 13;
    return (62 + (scale - 1) * 20).clamp(62.0, 96.0).toDouble();
  }

  Widget _panel({Widget? trailing, bool showHeader = true}) => LearningPanel(
    controller: c,
    onRequest: widget.onRequest,
    onNote: _addNote,
    onJump: _jump,
    trailing: trailing,
    tabController: _tabs,
    showHeader: showHeader,
    onExpanded: () {
      if (_mode == _ReaderMode.compact) {
        setState(() => _sheetFraction = .5);
      } else if (_mode == _ReaderMode.medium) {
        setState(() => _drawerOpen = true);
      }
    },
  );

  Widget _pageColumn(DocumentRecord document) {
    final callout = _pageCallout();
    return Column(
      children: [
        _toolbar(document),
        if (c.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.md, 0),
            child: AppCallout(
              tone: CalloutTone.error,
              title: '这次操作没有完成',
              message: c.error!,
              onDismiss: c.clearError,
            ),
          ),
        if (callout != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.md, 0),
            child: callout,
          ),
        Expanded(
          child: ColoredBox(
            color: context.colors.pageStage,
            child: c.raster == null
                ? _PageLoading(page: c.page)
                : PageSurface(
                    key: _pageKey,
                    page: c.raster!,
                    selection: c.selection,
                    highlight: c.highlight,
                    onSelect: c.select,
                    pageLabel: '第 ${c.page} 页原页，${document.title}',
                    filter: widget.appearance.pageFilter,
                    inverted: widget.appearance.pageTone == PageTone.inverted,
                    showHint:
                        _hintVisible &&
                        !(_mode == _ReaderMode.compact && _sheetExpanded),
                    onDismissHint: () {
                      setState(() => _hintVisible = false);
                      widget.appearance.markReaderHintSeen();
                    },
                  ),
          ),
        ),
      ],
    );
  }

  Widget? _pageCallout() {
    final page = c.currentPage;
    if (page == null || _dismissedCallouts.contains(c.page)) return null;
    if (page.status != PageStatus.needsOcr &&
        page.status != PageStatus.failed) {
      return null;
    }
    return AppCallout(
      tone: CalloutTone.warning,
      title: '本页文字未就绪',
      message: page.error ?? '可阅读原页或重新识别。',
      action: Wrap(
        spacing: Space.xs,
        children: [
          TextButton.icon(
            onPressed: c.indexing ? null : () => c.recognizeCurrentPage(),
            icon: const Icon(Icons.refresh_rounded, size: 15),
            label: const Text('重新识别本页'),
          ),
          TextButton.icon(
            onPressed: c.indexing ? null : _correctText,
            icon: const Icon(Icons.edit_note_rounded, size: 15),
            label: const Text('校正文字'),
          ),
          if (widget.onOpenOcrSettings != null)
            TextButton.icon(
              onPressed: widget.onOpenOcrSettings,
              icon: const Icon(Icons.settings_outlined, size: 15),
              label: const Text('文字识别设置'),
            ),
        ],
      ),
      onDismiss: () => setState(() => _dismissedCallouts.add(c.page)),
    );
  }

  Widget _toolbar(DocumentRecord document) {
    final colors = context.colors;
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 520;
        final showSearch = constraints.maxWidth >= 820;
        final ready = c.pages
            .where((page) => page.status == PageStatus.ready)
            .length;
        final status = c.indexing
            ? '正在处理第 ${c.indexingPage ?? c.page} 页'
            : c.paused
            ? '索引已暂停'
            : '已索引 $ready 页';
        final statusColor = colors.inkMuted;
        return Container(
          height: AppChrome.titleBarHeight,
          padding: EdgeInsets.symmetric(horizontal: narrow ? 6 : 16),
          decoration: BoxDecoration(
            color: colors.surface,
            border: Border(bottom: BorderSide(color: colors.outline)),
          ),
          child: Row(
            children: [
              Tooltip(
                message: '返回书库',
                child: TextButton.icon(
                  onPressed: c.sending ? null : widget.onBack,
                  style: TextButton.styleFrom(
                    minimumSize: Size(0, narrow ? 32 : 36),
                    padding: EdgeInsets.symmetric(
                      horizontal: narrow ? 7 : 10,
                      vertical: 6,
                    ),
                    foregroundColor: narrow ? colors.inkMuted : colors.ink,
                    textStyle: context.texts.bodySmall!.copyWith(
                      fontSize: narrow ? 12 : 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  icon: Icon(Icons.arrow_back_rounded, size: narrow ? 16 : 18),
                  label: const Text('书库'),
                ),
              ),
              SizedBox(width: narrow ? 2 : 6),
              if (constraints.maxWidth >= 520) ...[
                Icon(
                  document.kind == DocumentKind.textbook
                      ? Icons.menu_book_outlined
                      : Icons.article_outlined,
                  size: 18,
                  color: colors.inkMuted,
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: WindowDragRegion(
                  child: Text(
                    document.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.bodyMedium!.copyWith(
                      fontSize: narrow ? 13 : 15,
                      fontWeight: FontWeight.w600,
                      color: colors.ink,
                    ),
                  ),
                ),
              ),
              _PageStepper(
                page: c.page,
                total: document.pageCount,
                compact: narrow,
                onPrevious: c.page > 1 ? () => c.goToPage(c.page - 1) : null,
                onNext: c.page < document.pageCount
                    ? () => c.goToPage(c.page + 1)
                    : null,
                onJump: _jumpPageDialog,
              ),
              if (constraints.maxWidth >= 760)
                Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: Tooltip(
                    message: status,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: colors.surfaceRaised,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: colors.outline),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: statusColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            status,
                            style: context.texts.bodySmall!.copyWith(
                              fontSize: 12,
                              color: colors.inkMuted,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (showSearch)
                IconButton(
                  tooltip: '检索本篇原文（Ctrl+F）',
                  onPressed: ready > 0 ? _search : null,
                  icon: const Icon(Icons.search_rounded, size: 20),
                ),
              PopupMenuButton<String>(
                tooltip: '更多页面工具',
                icon: Icon(
                  Icons.more_vert_rounded,
                  size: 20,
                  color: colors.inkMuted,
                ),
                onSelected: (value) {
                  switch (value) {
                    case 'search':
                      _search();
                      break;
                    case 'jump':
                      _jumpPageDialog();
                      break;
                    case 'ocr':
                      c.recognizeCurrentPage();
                      break;
                    case 'correct':
                      _correctText();
                      break;
                    case 'index':
                      c.toggleIndexing();
                      break;
                    case 'shortcuts':
                      showShortcutsDialog(context);
                      break;
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'search',
                    enabled: ready > 0,
                    child: _menuRow(
                      context,
                      '检索本篇原文',
                      'Ctrl+F',
                      Icons.search_rounded,
                    ),
                  ),
                  PopupMenuItem(
                    value: 'jump',
                    child: _menuRow(
                      context,
                      '跳转物理页',
                      'Ctrl+G',
                      Icons.tag_rounded,
                    ),
                  ),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'ocr',
                    enabled: !c.indexing,
                    child: _menuRow(
                      context,
                      '重新识别当前整页',
                      null,
                      Icons.document_scanner_outlined,
                    ),
                  ),
                  PopupMenuItem(
                    value: 'correct',
                    enabled: !c.indexing,
                    child: _menuRow(
                      context,
                      '校正当前页文字',
                      null,
                      Icons.edit_note_outlined,
                    ),
                  ),
                  PopupMenuItem(
                    value: 'index',
                    child: _menuRow(
                      context,
                      c.paused ? '继续后台索引' : '暂停后台索引',
                      null,
                      c.paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                    ),
                  ),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    value: 'shortcuts',
                    child: _menuRow(
                      context,
                      '键盘快捷键',
                      null,
                      Icons.keyboard_outlined,
                    ),
                  ),
                ],
              ),
              if (widget.showWindowChrome)
                const SizedBox(width: AppChrome.captionWidth),
            ],
          ),
        );
      },
    );
  }

  Widget _menuRow(
    BuildContext context,
    String label,
    String? shortcut,
    IconData icon,
  ) {
    final c = context.colors;
    return Row(
      children: [
        Icon(icon, size: 16, color: c.inkMuted),
        const SizedBox(width: 8),
        Expanded(child: Text(label)),
        if (shortcut != null) ...[
          const SizedBox(width: Space.lg),
          KeyHint(shortcut),
        ],
      ],
    );
  }
}

class _PageStepper extends StatelessWidget {
  const _PageStepper({
    required this.page,
    required this.total,
    required this.compact,
    required this.onPrevious,
    required this.onNext,
    required this.onJump,
  });

  final int page;
  final int total;
  final bool compact;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback onJump;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final buttonSize = compact ? 28.0 : 34.0;
    return Container(
      height: compact ? 32 : 36,
      decoration: BoxDecoration(
        color: c.surfaceRaised,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: c.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '上一页（←）',
            onPressed: onPrevious,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: BoxConstraints(
              minWidth: buttonSize,
              minHeight: buttonSize,
            ),
            icon: Icon(Icons.chevron_left_rounded, size: compact ? 17 : 19),
          ),
          Semantics(
            button: true,
            label: '当前第 $page 页，共 $total 页，点击跳页',
            child: TextButton(
              onPressed: onJump,
              style: TextButton.styleFrom(
                minimumSize: Size(0, buttonSize),
                padding: EdgeInsets.symmetric(horizontal: compact ? 5 : 10),
                foregroundColor: c.ink,
                textStyle: context.texts.bodySmall!.copyWith(
                  fontSize: compact ? 11.5 : 13.5,
                  fontFeatures: AppNumerals.tabular,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: Text(compact ? '$page/$total' : '$page / $total'),
            ),
          ),
          IconButton(
            tooltip: '下一页（→）',
            onPressed: onNext,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: BoxConstraints(
              minWidth: buttonSize,
              minHeight: buttonSize,
            ),
            icon: Icon(Icons.chevron_right_rounded, size: compact ? 17 : 19),
          ),
        ],
      ),
    );
  }
}

class _ResizeHandle extends StatefulWidget {
  const _ResizeHandle({required this.onDrag, required this.onReset});

  final ValueChanged<double> onDrag;
  final VoidCallback onReset;

  @override
  State<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<_ResizeHandle> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => widget.onDrag(details.delta.dx),
        onDoubleTap: widget.onReset,
        child: Tooltip(
          message: '拖动调整面板宽度，双击恢复默认',
          child: SizedBox(
            width: 8,
            child: Center(
              child: AnimatedContainer(
                duration: context.motion(Motion.fast),
                width: _hovered ? 3 : 1,
                height: 44,
                decoration: BoxDecoration(
                  color: _hovered ? c.primary : c.outline,
                  borderRadius: BorderRadius.circular(Radii.full),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PageLoading extends StatelessWidget {
  const _PageLoading({required this.page});

  final int page;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = math.max(
          80.0,
          math.min(320.0, constraints.maxHeight - 80),
        );
        final width = height / 1.42;
        return Semantics(
          label: '正在渲染第 $page 页',
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: width,
                  height: height,
                  padding: EdgeInsets.symmetric(
                    horizontal: width * .12,
                    vertical: height * .1,
                  ),
                  decoration: BoxDecoration(
                    color: c.surfaceRaised,
                    border: Border.all(color: c.outline),
                    borderRadius: BorderRadius.circular(2),
                    boxShadow: AppShadow.paper,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SkeletonBlock(width: width * .5, height: 12),
                      const SizedBox(height: 14),
                      for (var i = 0; i < 8; i++) ...[
                        SkeletonBlock(
                          width: width * (i.isEven ? .7 : .62),
                          height: 6,
                        ),
                        const SizedBox(height: 8),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: Space.md),
                Text('正在渲染第 $page 页…', style: context.texts.bodySmall),
              ],
            ),
          ),
        );
      },
    );
  }
}
