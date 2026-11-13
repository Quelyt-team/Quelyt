import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../features/library/library_controller.dart';
import '../../features/library/ui/library_tree.dart';
import '../../features/notes/notes_controller.dart';
import '../../features/notes/ui/notes_sidebar_tree.dart';
import '../theme/tokens.dart';
import '../widgets/app_surfaces.dart';
import '../widgets/quelyt_mark.dart';
import 'app_chrome.dart';
import 'window_title_bar.dart';

enum AppSection { library, notes, schedule, review }

extension AppSectionX on AppSection {
  String get label => switch (this) {
    AppSection.library => '书库',
    AppSection.notes => '笔记',
    AppSection.schedule => '日程',
    AppSection.review => '复习',
  };

  String get shortLabel => label;

  QIconData get icon => switch (this) {
    AppSection.library => QIcons.library,
    AppSection.notes => QIcons.notes,
    AppSection.schedule => QIcons.schedule,
    AppSection.review => QIcons.review,
  };
}

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.showWordmark = true, this.iconSize = 32});

  final bool showWordmark;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    if (!showWordmark) {
      return QuelytMark(size: iconSize, compact: iconSize <= 32);
    }
    return QuelytWordmark(height: iconSize * 1.1875);
  }
}

/// Mobile flat bottom navigation bar with comfortable 60px touch targets and
/// 12px labels.
class AppBottomNav extends StatelessWidget {
  const AppBottomNav({
    super.key,
    required this.section,
    required this.onSelect,
  });

  final AppSection section;
  final ValueChanged<AppSection> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(top: BorderSide(color: c.outline)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 60,
          child: Row(
            children: [
              for (final item in AppSection.values)
                Expanded(
                  child: InkWell(
                    onTap: () => onSelect(item),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        QIcon(
                          item.icon,
                          size: IconSizes.md,
                          color: item == section ? c.ink : c.inkMuted,
                          active: item == section,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          item.shortLabel,
                          style: context.texts.bodySmall!.copyWith(
                            fontSize: 12,
                            color: item == section ? c.ink : c.inkMuted,
                            fontWeight: item == section
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class AppSidebar extends StatelessWidget {
  const AppSidebar({
    super.key,
    required this.section,
    required this.onSelect,
    required this.onOpenDocument,
    required this.onOpenSettings,
    required this.onCollapse,
    required this.documents,
    required this.library,
    required this.libraryCount,
    required this.notesCount,
    required this.pendingCount,
    this.notes,
  });

  final AppSection section;
  final ValueChanged<AppSection> onSelect;
  final ValueChanged<DocumentRecord> onOpenDocument;
  final VoidCallback onOpenSettings;
  final VoidCallback onCollapse;
  final List<DocumentRecord> documents;
  final LibraryController library;
  final NotesController? notes;
  final int libraryCount;
  final int notesCount;
  final int pendingCount;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: 276,
      decoration: BoxDecoration(
        color: c.sidebar,
        border: Border(right: BorderSide(color: c.outline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SidebarBrand(onCollapse: onCollapse),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
            child: _SidebarModuleSwitcher(
              section: section,
              pendingCount: pendingCount,
              onSelect: onSelect,
            ),
          ),
          if (section == AppSection.library)
            Expanded(child: LibraryTree(controller: library))
          else if (section == AppSection.notes && notes != null)
            Expanded(child: NotesSidebarTree(controller: notes!))
          else if (section == AppSection.notes)
            const Expanded(child: SizedBox.shrink())
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Text(
                '最近打开',
                style: context.texts.bodySmall!.copyWith(
                  fontSize: 12,
                  color: c.inkMuted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Expanded(
              child: documents.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                      child: Text(
                        '暂无资料',
                        style: context.texts.bodySmall!.copyWith(fontSize: 12.5),
                      ),
                    )
                  : ListView.builder(
                      padding: EdgeInsets.zero,
                      itemCount: documents.length,
                      itemBuilder: (context, index) {
                        final doc = documents[index];
                        return _RecentDocumentRow(
                          document: doc,
                          onTap: () => onOpenDocument(doc),
                        );
                      },
                    ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Divider(height: 1, color: c.outline),
          ),
          _SidebarSettingsRow(onTap: onOpenSettings),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

class _SidebarModuleSwitcher extends StatelessWidget {
  const _SidebarModuleSwitcher({
    required this.section,
    required this.pendingCount,
    required this.onSelect,
  });

  final AppSection section;
  final int pendingCount;
  final ValueChanged<AppSection> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final items = AppSection.values;
    final selectedIndex = items.indexOf(section).clamp(0, items.length - 1);
    final alignX = -1.0 + (selectedIndex / (items.length - 1)) * 2.0;
    final trackColor = c.isDark
        ? const Color(0xFF0E0E10)
        : const Color(0xFFEAEAE6);
    final thumbColor = c.isDark ? const Color(0xFF28282D) : Colors.white;
    return Container(
      height: 36,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: trackColor,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Stack(
        children: [
          AnimatedAlign(
            duration: context.motion(const Duration(milliseconds: 220)),
            curve: Curves.easeOutCubic,
            alignment: Alignment(alignX, 0),
            child: FractionallySizedBox(
              widthFactor: 1 / items.length,
              heightFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: thumbColor,
                  borderRadius: BorderRadius.circular(7),
                  border: c.isDark
                      ? Border.all(
                          color: Colors.white.withValues(alpha: .07),
                          width: 0.5,
                        )
                      : null,
                  boxShadow: c.isDark
                      ? const [
                          BoxShadow(
                            color: Color(0x55000000),
                            blurRadius: 6,
                            offset: Offset(0, 1.5),
                          ),
                        ]
                      : const [
                          BoxShadow(
                            color: Color(0x14000000),
                            blurRadius: 6,
                            offset: Offset(0, 1.5),
                          ),
                          BoxShadow(
                            color: Color(0x0A000000),
                            blurRadius: 1.5,
                            offset: Offset(0, 0.5),
                          ),
                        ],
                ),
              ),
            ),
          ),
          Row(
            children: [
              for (final item in items)
                Expanded(
                  child: _ModuleTab(
                    section: item,
                    selected: section == item,
                    badge: item == AppSection.review && pendingCount > 0,
                    onTap: () => onSelect(item),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ModuleTab extends StatefulWidget {
  const _ModuleTab({
    required this.section,
    required this.selected,
    required this.badge,
    required this.onTap,
  });

  final AppSection section;
  final bool selected;
  final bool badge;
  final VoidCallback onTap;

  @override
  State<_ModuleTab> createState() => _ModuleTabState();
}

class _ModuleTabState extends State<_ModuleTab> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final textColor = widget.selected
        ? c.ink
        : (_hovered ? c.ink.withValues(alpha: .82) : c.inkMuted);
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.section.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedDefaultTextStyle(
                  duration: context.motion(const Duration(milliseconds: 180)),
                  curve: Curves.easeOutCubic,
                  style: context.texts.bodySmall!.copyWith(
                    fontSize: 12.5,
                    color: textColor,
                    fontWeight: widget.selected
                        ? FontWeight.w600
                        : FontWeight.w500,
                  ),
                  child: Text(widget.section.label),
                ),
                if (widget.badge) ...[
                  const SizedBox(width: 4),
                  Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: c.primary,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarBrand extends StatelessWidget {
  const _SidebarBrand({required this.onCollapse});

  final VoidCallback onCollapse;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: AppChrome.titleBarHeight,
      child: Padding(
        padding: const EdgeInsets.only(left: 20, right: 12),
        child: Row(
          children: [
            Expanded(
              child: WindowDragRegion(
                child: Row(
                  children: [
                    const QuelytMark(
                      size: 24,
                      compact: true,
                      semanticLabel: null,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'Quelyt',
                      style: context.texts.bodyMedium!.copyWith(
                        fontFamily: 'Manrope',
                        fontWeight: FontWeight.w700,
                        fontSize: 15.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            IconButton(
              tooltip: '收起侧栏（Ctrl+B）',
              onPressed: onCollapse,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(
                minWidth: 34,
                minHeight: 34,
              ),
              padding: EdgeInsets.zero,
              icon: const QIcon(QIcons.sidebar, size: IconSizes.md),
            ),
          ],
        ),
      ),
    );
  }
}

class _SidebarSettingsRow extends StatefulWidget {
  const _SidebarSettingsRow({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_SidebarSettingsRow> createState() => _SidebarSettingsRowState();
}

class _SidebarSettingsRowState extends State<_SidebarSettingsRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Semantics(
        button: true,
        label: '设置',
        child: InkWell(
          onTap: widget.onTap,
          onHover: (value) => setState(() => _hovered = value),
          borderRadius: BorderRadius.circular(8),
          hoverColor: Colors.transparent,
          child: AnimatedContainer(
            duration: context.motion(Motion.fast),
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: _hovered ? c.tint.withValues(alpha: .55) : null,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                QIcon(QIcons.settings, size: IconSizes.md, color: c.inkMuted),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '设置',
                    style: context.texts.bodyMedium!.copyWith(
                      fontSize: 13.5,
                      color: c.inkMuted,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Text(
                  'Ctrl+,',
                  style: context.texts.labelSmall!.copyWith(
                    fontSize: 11,
                    letterSpacing: .1,
                    color: c.inkMuted.withValues(alpha: .7),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RecentDocumentRow extends StatefulWidget {
  const _RecentDocumentRow({required this.document, required this.onTap});

  final DocumentRecord document;
  final VoidCallback onTap;

  @override
  State<_RecentDocumentRow> createState() => _RecentDocumentRowState();
}

class _RecentDocumentRowState extends State<_RecentDocumentRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: widget.onTap,
      onHover: (value) => setState(() => _hovered = value),
      hoverColor: Colors.transparent,
      child: Container(
        height: 36,
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: _hovered ? c.tint : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            QIcon(
              switch (widget.document.kind) {
                DocumentKind.textbook => QIcons.textbook,
                DocumentKind.paper => QIcons.paper,
                DocumentKind.unspecified => QIcons.study,
              },
              size: IconSizes.sm,
              color: _hovered ? c.ink : c.inkMuted,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.document.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.texts.bodySmall!.copyWith(
                  fontSize: 13,
                  color: _hovered ? c.ink : c.inkMuted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class UnifiedHeader extends StatelessWidget {
  const UnifiedHeader({
    super.key,
    required this.title,
    required this.subtitle,
    required this.sidebarCollapsed,
    required this.onToggleSidebar,
    required this.showWindowChrome,
    this.onOpenSettings,
    this.showSidebarToggle = true,
    this.showSubtitle = true,
    this.compact = false,
    this.leading,
    this.titleContent,
    this.trailing = const [],
    this.search,
    this.importAction,
  });

  final String title;
  final String subtitle;
  final bool sidebarCollapsed;
  final VoidCallback onToggleSidebar;
  final bool showWindowChrome;
  final VoidCallback? onOpenSettings;
  final bool showSidebarToggle;
  final bool showSubtitle;
  final bool compact;
  final Widget? leading;
  final Widget? titleContent;
  final List<Widget> trailing;
  final Widget? search;
  final Widget? importAction;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final sidebarOpen = showSidebarToggle && !sidebarCollapsed;
    return Container(
      height: AppChrome.titleBarHeight,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.outline)),
      ),
      child: Row(
        children: [
          if (!sidebarOpen)
            Padding(
              padding: const EdgeInsets.only(left: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  WindowDragRegion(
                    child: QuelytMark(
                      size: 22,
                      compact: true,
                      semanticLabel: null,
                    ),
                  ),
                  if (showSidebarToggle) ...[
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: '展开侧栏（Ctrl+B）',
                      onPressed: onToggleSidebar,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 34,
                        minHeight: 34,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const QIcon(QIcons.sidebar, size: IconSizes.md),
                    ),
                  ],
                  if (onOpenSettings != null) ...[
                    const SizedBox(width: 2),
                    IconButton(
                      tooltip: '设置（Ctrl+,）',
                      onPressed: onOpenSettings,
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 34,
                        minHeight: 34,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const QIcon(QIcons.settings, size: IconSizes.md),
                    ),
                  ],
                ],
              ),
            ),
          if (leading != null)
            Padding(
              padding: EdgeInsets.only(
                left: !sidebarOpen ? 2 : (compact ? 8 : 14),
              ),
              child: leading!,
            ),
          Expanded(
            child: titleContent != null
                ? Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      const Positioned.fill(
                        child: WindowDragRegion(child: SizedBox.expand()),
                      ),
                      Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: compact ? 8 : (sidebarOpen ? 20 : 12),
                        ),
                        child: titleContent!,
                      ),
                    ],
                  )
                : WindowDragRegion(
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: compact ? 14 : 24,
                      ),
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: context.texts.bodyMedium!.copyWith(
                                fontSize: compact ? 16 : 18,
                                fontWeight: FontWeight.w600,
                                height: 1.25,
                                color: c.ink,
                              ),
                            ),
                          ),
                          if (showSubtitle &&
                              !compact &&
                              subtitle.isNotEmpty) ...[
                            const SizedBox(width: 10),
                            Flexible(
                              child: Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: context.texts.bodySmall!.copyWith(
                                  fontSize: 13,
                                  height: 1.25,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
          ),
          if (search != null)
            Padding(padding: const EdgeInsets.only(right: 10), child: search!),
          if (importAction != null)
            Padding(
              padding: EdgeInsets.only(right: showWindowChrome ? 10 : 16),
              child: importAction!,
            ),
          if (trailing.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(right: showWindowChrome ? 8 : 14),
              child: Row(mainAxisSize: MainAxisSize.min, children: trailing),
            ),
          if (showWindowChrome) const WindowCaptionControls(),
        ],
      ),
    );
  }
}

class AppErrorCallout extends StatelessWidget {
  const AppErrorCallout({
    super.key,
    required this.message,
    required this.onDismiss,
  });

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(Space.lg, Space.sm, Space.lg, 0),
    child: AppCallout(
      tone: CalloutTone.error,
      title: '这次操作没有完成',
      message: message,
      onDismiss: onDismiss,
    ),
  );
}
