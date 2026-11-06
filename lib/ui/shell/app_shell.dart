import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../theme/tokens.dart';
import '../widgets/app_surfaces.dart';
import '../widgets/quelyt_mark.dart';
import 'app_chrome.dart';
import 'window_title_bar.dart';

enum AppSection { library, review }

extension AppSectionX on AppSection {
  String get label => switch (this) {
    AppSection.library => '书库',
    AppSection.review => '复习',
  };

  String get shortLabel => label;

  IconData get icon => switch (this) {
    AppSection.library => Icons.local_library_outlined,
    AppSection.review => Icons.history_edu_outlined,
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
                        Icon(
                          item.icon,
                          size: 20,
                          color: item == section ? c.ink : c.inkMuted,
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
    required this.libraryCount,
    required this.pendingCount,
  });

  final AppSection section;
  final ValueChanged<AppSection> onSelect;
  final ValueChanged<DocumentRecord> onOpenDocument;
  final VoidCallback onOpenSettings;
  final VoidCallback onCollapse;
  final List<DocumentRecord> documents;
  final int libraryCount;
  final int pendingCount;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: 264,
      decoration: BoxDecoration(
        color: c.sidebar,
        border: Border(right: BorderSide(color: c.outline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SidebarBrand(onCollapse: onCollapse),
          const SizedBox(height: 12),
          _SidebarNavItem(
            icon: Icons.library_books_outlined,
            label: '书库',
            selected: section == AppSection.library,
            count: libraryCount,
            onTap: () => onSelect(AppSection.library),
          ),
          _SidebarNavItem(
            icon: Icons.history_edu_outlined,
            label: '复习',
            selected: section == AppSection.review,
            count: pendingCount,
            onTap: () => onSelect(AppSection.review),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 16, 12, 6),
            child: Divider(height: 1, color: c.outline),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
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
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Divider(height: 1, color: c.outline),
          ),
          _SidebarSettingsRow(onTap: onOpenSettings),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              'Quelyt 0.1.0',
              style: context.texts.labelSmall!.copyWith(
                fontSize: 11.5,
                letterSpacing: .2,
                color: c.inkMuted.withValues(alpha: .8),
              ),
            ),
          ),
        ],
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
        padding: const EdgeInsets.only(left: 16, right: 10),
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
                minWidth: 32,
                minHeight: 32,
              ),
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.view_sidebar_outlined, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

class _SidebarNavItem extends StatefulWidget {
  const _SidebarNavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? count;

  @override
  State<_SidebarNavItem> createState() => _SidebarNavItemState();
}

class _SidebarNavItemState extends State<_SidebarNavItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Semantics(
        button: true,
        selected: widget.selected,
        label: widget.label,
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
              color: widget.selected
                  ? c.tint
                  : (_hovered
                        ? c.tint.withValues(alpha: .5)
                        : Colors.transparent),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  widget.icon,
                  size: 18,
                  color: widget.selected ? c.ink : c.inkMuted,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.label,
                    style: context.texts.bodyMedium!.copyWith(
                      fontSize: 14,
                      color: widget.selected ? c.ink : c.inkMuted,
                      fontWeight: widget.selected
                          ? FontWeight.w600
                          : FontWeight.w500,
                    ),
                  ),
                ),
                SizedBox(
                  width: 28,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      widget.count != null && widget.count! > 0
                          ? '${widget.count}'
                          : '',
                      style: context.texts.bodySmall!.copyWith(
                        fontSize: 12,
                        color: c.inkMuted,
                        fontFeatures: AppNumerals.tabular,
                      ),
                    ),
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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
                Icon(Icons.tune_rounded, size: 18, color: c.inkMuted),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '设置',
                    style: context.texts.bodyMedium!.copyWith(
                      fontSize: 14,
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
            Icon(
              widget.document.kind == DocumentKind.textbook
                  ? Icons.menu_book_outlined
                  : Icons.article_outlined,
              size: 16,
              color: _hovered ? c.ink : c.inkMuted,
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                widget.document.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.texts.bodySmall!.copyWith(
                  fontSize: 13.5,
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
                      icon: const Icon(Icons.view_sidebar_outlined, size: 18),
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
                      icon: const Icon(Icons.tune_rounded, size: 18),
                    ),
                  ],
                ],
              ),
            ),
          Expanded(
            child: WindowDragRegion(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: compact ? 14 : 24),
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
                    if (showSubtitle && !compact && subtitle.isNotEmpty) ...[
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
