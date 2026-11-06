import 'package:flutter/material.dart';

import '../../app_controller.dart';
import '../../core/models.dart';
import '../theme/tokens.dart';
import '../widgets/app_surfaces.dart';

enum _ReviewSort { pendingFirst, recent }

class ReviewPage extends StatefulWidget {
  const ReviewPage({
    super.key,
    required this.controller,
    required this.onPractice,
    required this.onGoLibrary,
  });

  final StudyController controller;
  final Future<void> Function(DocumentRecord, StudySession) onPractice;
  final VoidCallback onGoLibrary;

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  bool _pendingOnly = false;
  _ReviewSort _sort = _ReviewSort.pendingFirst;

  StudyController get c => widget.controller;

  List<(DocumentRecord, StudySession)> get _items {
    final items = <(DocumentRecord, StudySession)>[];
    for (final doc in c.library) {
      for (final session in c.store.getSessions(doc.id)) {
        if (session.attempts.isEmpty && !session.needsReview) continue;
        if (_pendingOnly && !session.needsReview) continue;
        items.add((doc, session));
      }
    }
    items.sort((a, b) {
      if (_sort == _ReviewSort.pendingFirst &&
          a.$2.needsReview != b.$2.needsReview) {
        return a.$2.needsReview ? -1 : 1;
      }
      final aDate = a.$2.attempts.isEmpty
          ? a.$2.updatedAt
          : a.$2.attempts.last.createdAt;
      final bDate = b.$2.attempts.isEmpty
          ? b.$2.updatedAt
          : b.$2.attempts.last.createdAt;
      return bDate.compareTo(aDate);
    });
    return items;
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

  int get _allCount {
    var count = 0;
    for (final doc in c.library) {
      count += c.store
          .getSessions(doc.id)
          .where(
            (session) => session.attempts.isNotEmpty || session.needsReview,
          )
          .length;
    }
    return count;
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 600;
        final padding = wide ? Space.xl : Space.lg;
        return Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                padding,
                wide ? 16 : Space.md,
                padding,
                10,
              ),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1080),
                  child: SizedBox(
                    width: double.infinity,
                    child: _filterBar(context, items.length, wide),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1080),
                  child: items.isEmpty
                      ? Center(
                          child: SingleChildScrollView(
                            padding: EdgeInsets.symmetric(
                              horizontal: padding,
                              vertical: Space.lg,
                            ),
                            child: _EmptyReview(
                              pendingOnly: _pendingOnly,
                              onGoLibrary: widget.onGoLibrary,
                              onShowAll: () =>
                                  setState(() => _pendingOnly = false),
                            ),
                          ),
                        )
                      : ListView.builder(
                          key: PageStorageKey<String>(
                            _pendingOnly ? 'review-pending' : 'review-all',
                          ),
                          padding: EdgeInsets.fromLTRB(
                            padding,
                            0,
                            padding,
                            Space.xxl,
                          ),
                          itemCount: items.length,
                          itemBuilder: (context, index) {
                            final item = items[index];
                            return _ReviewCard(
                              document: item.$1,
                              session: item.$2,
                              onPractice: () =>
                                  widget.onPractice(item.$1, item.$2),
                            );
                          },
                        ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _filterBar(BuildContext context, int count, bool wide) {
    return Row(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: KeyedSubtree(
                    key: const ValueKey('review-filter'),
                    child: AppSegmentedControl(
                      segmentMinWidth: 104,
                      segments: [
                        AppSegment(label: '全部', count: _allCount),
                        AppSegment(label: '待核对', count: _pendingCount),
                      ],
                      selectedIndex: _pendingOnly ? 1 : 0,
                      onChanged: (index) =>
                          setState(() => _pendingOnly = index == 1),
                    ),
                  ),
                ),
                if (wide) ...[
                  const SizedBox(width: 12),
                  Text(
                    '共 $count 项',
                    style: context.texts.bodySmall!.copyWith(
                      fontSize: 12.5,
                      fontFeatures: AppNumerals.tabular,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(width: 4),
        PopupMenuButton<_ReviewSort>(
          tooltip: '复习排序',
          initialValue: _sort,
          onSelected: (value) => setState(() => _sort = value),
          icon: const Icon(Icons.swap_vert_rounded, size: 18),
          itemBuilder: (context) => const [
            PopupMenuItem(
              value: _ReviewSort.pendingFirst,
              child: Text('待核对优先'),
            ),
            PopupMenuItem(value: _ReviewSort.recent, child: Text('最近练习')),
          ],
        ),
      ],
    );
  }
}

class _EmptyReview extends StatelessWidget {
  const _EmptyReview({
    required this.pendingOnly,
    required this.onGoLibrary,
    required this.onShowAll,
  });

  final bool pendingOnly;
  final VoidCallback onGoLibrary;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) => KeyedSubtree(
    key: const ValueKey('review-empty'),
    child: EmptyState(
      icon: pendingOnly
          ? Icons.check_circle_outline_rounded
          : Icons.history_edu_outlined,
      accent: context.colors.neutralAccent,
      title: pendingOnly ? '暂无待核对' : '暂无练习',
      message: pendingOnly ? '已全部核对。' : '完成作答后会显示在这里。',
      action: pendingOnly
          ? TextButton(onPressed: onShowAll, child: const Text('查看全部'))
          : OutlinedButton.icon(
              onPressed: onGoLibrary,
              icon: const Icon(Icons.local_library_outlined, size: 16),
              label: const Text('去书库'),
            ),
    ),
  );
}

class _ReviewCard extends StatelessWidget {
  const _ReviewCard({
    required this.document,
    required this.session,
    required this.onPractice,
  });

  final DocumentRecord document;
  final StudySession session;
  final VoidCallback onPractice;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final textbook = document.kind == DocumentKind.textbook;
    final last = session.attempts.isEmpty
        ? session.updatedAt
        : session.attempts.last.createdAt;
    final question = session.question.isEmpty ? session.goal : session.question;
    return InkWell(
      onTap: onPractice,
      hoverColor: c.sidebar,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.outline)),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 560;
            final content = Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  key: ValueKey('review-icon-${session.id}'),
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: c.tint,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    textbook ? Icons.menu_book_outlined : Icons.article_outlined,
                    size: 18,
                    color: c.inkMuted,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        question,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: context.texts.bodyMedium!.copyWith(
                          fontSize: 15,
                          color: c.ink,
                          fontWeight: FontWeight.w600,
                          height: 1.55,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${document.title} · 第 ${session.startPage}–${session.endPage} 页'
                        ' · ${session.attempts.length} 次作答 · ${_dateLabel(last)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.texts.bodySmall!.copyWith(
                          fontSize: 13,
                          color: c.inkMuted,
                          fontFeatures: AppNumerals.tabular,
                        ),
                      ),
                    ],
                  ),
                ),
                if (!compact) ...[
                  const SizedBox(width: 16),
                  _actions(context),
                ],
              ],
            );
            if (!compact) return content;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                content,
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.only(left: 48),
                  child: Row(
                    children: [
                      _statusSlot(context),
                      const Spacer(),
                      _practiceButton(context),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _actions(BuildContext context) {
    return SizedBox(
      width: 202,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          _statusSlot(context),
          const SizedBox(width: 10),
          _practiceButton(context),
        ],
      ),
    );
  }

  Widget _statusSlot(BuildContext context) => SizedBox(
    width: 96,
    child: session.needsReview
        ? const Align(
            alignment: Alignment.centerRight,
            child: AppBadge(label: '待核对'),
          )
        : null,
  );

  Widget _practiceButton(BuildContext context) => SizedBox(
    width: 96,
    height: 36,
    child: FilledButton(
      onPressed: onPractice,
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        textStyle: context.texts.labelLarge!.copyWith(
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
        ),
      ),
      child: const Text(
        '继续练习',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
  );
}

String _dateLabel(DateTime value) {
  final now = DateTime.now();
  final local = value.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final difference = today.difference(day).inDays;
  if (difference == 0) {
    return '今天 ${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
  if (difference == 1) return '昨天';
  if (local.year == now.year) return '${local.month}月${local.day}日';
  return '${local.year}.${local.month}.${local.day}';
}
