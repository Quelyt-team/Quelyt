import 'package:flutter/material.dart';

import '../../app_controller.dart';
import '../../core/models.dart';
import '../../features/review/models/review_models.dart';
import '../../features/review/review_controller.dart';
import '../../features/review/ui/review_dialogs.dart';
import '../../features/review/ui/review_session_page.dart';
import '../../features/schedule/models/lesson_review.dart';
import '../theme/tokens.dart';
import '../widgets/app_dialog.dart';
import '../widgets/app_surfaces.dart';

class ReviewPage extends StatefulWidget {
  const ReviewPage({
    super.key,
    required this.controller,
    required this.onPractice,
    required this.onGoLibrary,
    this.lessonReviews,
    this.onOpenLesson,
    this.onOpenSource,
  });

  final StudyController controller;
  final void Function(DocumentRecord document, StudySession session) onPractice;
  final VoidCallback onGoLibrary;
  final List<LessonReviewItem> Function()? lessonReviews;
  final ValueChanged<LessonReviewItem>? onOpenLesson;
  final Future<void> Function(ReviewOrigin origin)? onOpenSource;

  @override
  State<ReviewPage> createState() => _ReviewPageState();
}

class _ReviewPageState extends State<ReviewPage> {
  final _searchController = TextEditingController();
  String _searchQuery = '';

  StudyController get study => widget.controller;
  ReviewController get rc => study.reviewController;
  ReviewTab get _tab => rc.tab;

  List<DocumentRecord> get _documents => study.library;

  List<StudySession> get _sessions => [
    for (final doc in _documents) ...study.store.getSessions(doc.id),
  ];

  List<LessonReviewItem> get _lessonReviews =>
      widget.lessonReviews?.call() ?? const [];

  @override
  void initState() {
    super.initState();
    rc.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(covariant ReviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.reviewController.removeListener(_onChanged);
      widget.controller.reviewController.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    rc.removeListener(_onChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _setTab(ReviewTab tab) => rc.setTab(tab);

  DocumentRecord? _docById(String id) {
    for (final doc in _documents) {
      if (doc.id == id) return doc;
    }
    return null;
  }

  Future<void> _openSession({
    ReviewSessionMode mode = ReviewSessionMode.formal,
    List<String>? explicitIds,
  }) async {
    rc.startOrResumeSession(mode: mode, explicitItemIds: explicitIds);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReviewSessionPage(
          study: study,
          onJumpToSource: widget.onOpenSource,
          onCompleted: rc.refresh,
        ),
      ),
    );
    rc.refresh();
  }

  Future<void> _pickCustomBudget() async {
    final input = TextEditingController(text: '${rc.budgetMinutes}');
    final minutes = await showAppDialog<int>(
      context: context,
      builder: (context) => AppDialog(
        title: '设置今日复习预算',
        subtitle: '按预算抽取今日队列，未完成题目自动延后。',
        icon: QIcons.duration,
        actions: [
          DialogActions.cancel(context),
          FilledButton(
            onPressed: () {
              final parsed = int.tryParse(input.text.trim());
              if (parsed != null && parsed >= 5 && parsed <= 180) {
                Navigator.pop(context, parsed);
              }
            },
            child: const Text('应用'),
          ),
        ],
        content: TextField(
          controller: input,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: '每日复习时长（分钟，5–180）',
          ),
        ),
      ),
    );
    input.dispose();
    if (minutes != null) {
      rc.setBudgetMinutes(minutes);
    }
  }

  Future<void> _pickManualDueDate(ReviewItem item) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (picked == null || !mounted) return;
    rc.repository.setManualDueDate(
      item.id,
      DateTime(picked.year, picked.month, picked.day, 9).toUtc(),
      reason: '手动调整复习日期',
    );
    rc.notice = '已把此题调整到 ${picked.year}-${picked.month}-${picked.day}。';
    rc.refresh();
  }

  List<StudySession> get _unacceptedLegacySessions {
    final items = _sessions.where((s) => s.attempts.isNotEmpty).toList();
    items.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final summary = rc.summary;
    final legacySessions = _sessions;
    final openCheckCount =
        summary.openChecksCount +
        legacySessions.where((s) => s.needsReview).length;
    final pendingCandidateCount =
        summary.pendingCandidatesCount + _lessonReviews.length;

    return ColoredBox(
      color: c.canvas,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1120),
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  Space.xl,
                  Space.xl,
                  Space.xl,
                  Space.md,
                ),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _HeaderBar(
                        hasStudy: true,
                        trashedView: rc.trashedView,
                        dueCount: summary.dueCount,
                        overdueCount: summary.overdueCount,
                        onCreate: () => showCreateOrEditReviewItemDialog(
                          context,
                          study: study,
                        ),
                        onAiGenerate: () => showGenerateReviewDraftDialog(
                          context,
                          study: study,
                        ),
                        onExport: () => showExportImportReviewDialog(
                          context,
                          study: study,
                        ),
                        onToggleTrash: () => rc.setTrashedView(!rc.trashedView),
                      ),
                      const SizedBox(height: Space.md),
                      _FilterBar(
                        tab: _tab,
                        onSelect: _setTab,
                        dueCount: summary.dueCount,
                        mistakeCount: summary.mistakesCount,
                        checkCount: openCheckCount,
                        totalCount:
                            summary.totalActiveCount + legacySessions.length,
                      ),
                      if (rc.notice != null) ...[
                        const SizedBox(height: Space.md),
                        AppCallout(
                          tone: CalloutTone.info,
                          message: rc.notice!,
                        ),
                      ],
                      if (rc.canUndoLastGrade) ...[
                        const SizedBox(height: Space.sm),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: OutlinedButton.icon(
                            onPressed: rc.undoLastGrade,
                            icon: const QIcon(QIcons.undo, size: IconSizes.sm),
                            label: const Text('撤销上次评分并恢复间隔'),
                          ),
                        ),
                      ],
                      if (pendingCandidateCount > 0 &&
                          _tab != ReviewTab.today) ...[
                        const SizedBox(height: Space.sm),
                        Text(
                          '另有 $pendingCandidateCount 条待确认候选（见「今日」）。',
                          style: context.texts.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  Space.xl,
                  0,
                  Space.xl,
                  Space.xxl,
                ),
                sliver: _buildTabSliver(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTabSliver(BuildContext context) {
    if (rc.trashedView) {
      return _buildAllOrTrashSliver(context, isTrash: true);
    }

    switch (_tab) {
      case ReviewTab.today:
        return _buildTodaySliver(context);
      case ReviewTab.mistakes:
        return _buildMistakesSliver(context);
      case ReviewTab.checks:
        return _buildChecksSliver(context);
      case ReviewTab.all:
        return _buildAllOrTrashSliver(context, isTrash: false);
      case ReviewTab.stats:
        return _buildStatsSliver(context);
    }
  }

  Widget _buildTodaySliver(BuildContext context) {
    final controller = rc;
    final legacySessions = _unacceptedLegacySessions;
    final todayQueue = controller.todayQueue;
    final candidates = controller.candidates;
    final exams = controller.examSummaries;
    final activeSession = controller.activeSession;
    final hasResume =
        activeSession != null &&
        activeSession.items.any((i) => i.status == 'pending');

    return SliverList.list(
      children: [
        _TodayHeroCard(
          summary: controller.summary,
          budgetMinutes: controller.budgetMinutes,
          hasResume: hasResume,
          onSelectBudget: controller.setBudgetMinutes,
          onCustomBudget: _pickCustomBudget,
          onStartOrResume: () => _openSession(mode: ReviewSessionMode.formal),
          onFreePractice: () => _openSession(mode: ReviewSessionMode.free),
          onScheduleBatch: () =>
              showScheduleReviewBatchDialog(context, study: study),
        ),
        const SizedBox(height: Space.lg),
        for (final exam in exams) ...[
          AppCallout(
            tone: exam.hasDeficit ? CalloutTone.warning : CalloutTone.info,
            title:
                '${exam.planTitle} · 距截止/考试 ${exam.daysRemaining} 天',
            message: exam.hasDeficit
                ? '待覆盖 ${exam.dueAndOverdueCount}/${exam.coveredItemCount} 题 · 缺约 ${exam.deficitMinutes} 分钟，建议调高每日预算或聚焦错题。'
                : '待覆盖 ${exam.dueAndOverdueCount}/${exam.coveredItemCount} 题 · 未覆知识点 ${exam.uncoveredKnowledgeCount} · 预算充足。',
          ),
          const SizedBox(height: Space.md),
        ],
        if (_lessonReviews.isNotEmpty) ...[
          _SectionTitle(
            title: '课程自评待复习',
            subtitle: '共 ${_lessonReviews.length} 项 · 来自每日课程自评，可回原课或转为记忆卡',
          ),
          const SizedBox(height: Space.sm),
          for (final item in _lessonReviews) ...[
            AppCard(
              padding: const EdgeInsets.all(Space.md),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.task.title, style: context.texts.labelLarge),
                        const SizedBox(height: 2),
                        Text(
                          item.exercise.prompt,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: context.texts.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: Space.sm),
                  if (widget.onOpenLesson != null)
                    OutlinedButton(
                      onPressed: () => widget.onOpenLesson!(item),
                      child: const Text('回到课程'),
                    ),
                ],
              ),
            ),
            const SizedBox(height: Space.sm),
          ],
          const SizedBox(height: Space.md),
        ],
        if (candidates.isNotEmpty) ...[
          _SectionTitle(
            title: '待整理复习候选 (${candidates.length})',
            subtitle: '确认加入后按遗忘曲线与独立闭卷调度',
          ),
          const SizedBox(height: Space.sm),
          for (final cand in candidates) ...[
            _CandidateCard(
              candidate: cand,
              onAccept: () => controller.acceptCandidate(cand.id),
              onEditAccept: () => showCandidateAcceptDialog(
                context,
                controller: controller,
                candidate: cand,
              ),
              onIgnore: () => controller.ignoreCandidate(cand.id),
            ),
            const SizedBox(height: Space.sm),
          ],
          const SizedBox(height: Space.md),
        ],
        if (legacySessions.isNotEmpty) ...[
          _SectionTitle(
            title: '近期阅读练习 (${legacySessions.length})',
            subtitle: '可直接继续在原资料中练习',
          ),
          const SizedBox(height: Space.sm),
          for (final session in legacySessions) ...[
            _LegacySessionCard(
              session: session,
              document: _docById(session.documentId),
              onPractice: widget.onPractice,
            ),
            const SizedBox(height: Space.sm),
          ],
          const SizedBox(height: Space.md),
        ],
        if (todayQueue.isNotEmpty) ...[
          _SectionTitle(
            title: '今日队列 (${todayQueue.length})',
            subtitle: '按超期优先、新旧混排与同源分散排序',
          ),
          const SizedBox(height: Space.sm),
          for (final entry in todayQueue) ...[
            _QueueEntryCard(
              entry: entry,
              onPracticeSingle: () => _openSession(
                mode: ReviewSessionMode.formal,
                explicitIds: [entry.item.id],
              ),
              onEdit: () => showCreateOrEditReviewItemDialog(
                context,
                study: study,
                existing: entry.item,
              ),
              onDefer: () => controller.deferItemOneDay(entry.item.id),
              onPauseToggle: () => controller.pauseOrResumeItem(entry.item),
              onTrash: () => controller.trashItem(entry.item.id),
              onManualDate: () => _pickManualDueDate(entry.item),
            ),
            const SizedBox(height: Space.sm),
          ],
        ] else if (legacySessions.isEmpty &&
            candidates.isEmpty &&
            _lessonReviews.isEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.xl),
            child: EmptyState(
              key: const ValueKey('review-empty'),
              icon: QIcons.review,
              title: '今日队列暂无到期题目',
              message: '可新建概念/填空/推导题，或在阅读、笔记、问答中加入；完成作答后会显示在这里。',
              action: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: () => showCreateOrEditReviewItemDialog(
                      context,
                      study: study,
                    ),
                    child: const Text('新建复习题'),
                  ),
                  OutlinedButton(
                    onPressed: widget.onGoLibrary,
                    child: const Text('去书库阅读'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildMistakesSliver(BuildContext context) {
    final mistakes = rc.mistakes;
    if (mistakes.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: EmptyState(
            key: const ValueKey('review-empty'),
            icon: QIcons.verify,
            title: '当前没有积压错题',
            message: '连续跨天独立做对后，错题自动完成闭环并移出。',
          ),
        ),
      );
    }

    return SliverList.list(
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: Space.md),
          child: Wrap(
            spacing: Space.sm,
            runSpacing: Space.sm,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '错题闭环清单 (${mistakes.length})',
                style: context.texts.titleSmall,
              ),
              FilledButton.icon(
                onPressed: () => _openSession(
                  mode: ReviewSessionMode.formal,
                  explicitIds: mistakes.map((e) => e.item.id).toList(),
                ),
                icon: const QIcon(QIcons.play, size: IconSizes.sm),
                label: const Text('专项重练全部错题'),
              ),
            ],
          ),
        ),
        for (final entry in mistakes) ...[
          _MistakeCard(
            entry: entry,
            onPractice: () => _openSession(
              mode: ReviewSessionMode.formal,
              explicitIds: [entry.item.id],
            ),
            onEdit: () => showCreateOrEditReviewItemDialog(
              context,
              study: study,
              existing: entry.item,
            ),
            onCreateVariant: () => showCreateOrEditReviewItemDialog(
              context,
              study: study,
              initialObjective: entry.item.objective,
              initialPrompt: '${entry.item.prompt}（变式巩固）',
              initialKind: entry.item.kind,
              origin: entry.origins.firstOrNull,
            ),
            onBackToSource: entry.origins.firstOrNull == null ||
                    widget.onOpenSource == null
                ? null
                : () => widget.onOpenSource!(entry.origins.first),
          ),
          const SizedBox(height: Space.sm),
        ],
      ],
    );
  }

  Widget _buildChecksSliver(BuildContext context) {
    final checks = rc.checks;
    final legacyFlagged = _sessions.where((s) => s.needsReview).toList();

    if (checks.isEmpty && legacyFlagged.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: EmptyState(
            key: const ValueKey('review-empty'),
            icon: QIcons.verify,
            title: '没有待核对的问题',
            message: '对 AI 评语或答案存疑的条目在此集中处理。',
          ),
        ),
      );
    }

    return SliverList.list(
      children: [
        for (final chk in checks) ...[
          AppCard(
            padding: const EdgeInsets.all(Space.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    AppBadge(
                      label: chk.targetType.label,
                      tone: BadgeTone.warm,
                      dense: true,
                    ),
                    if (chk.documentTitle.isNotEmpty)
                      AppBadge(label: chk.documentTitle, dense: true),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  chk.question.isEmpty ? chk.reason : chk.question,
                  style: context.texts.labelLarge,
                ),
                if (chk.reason.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text('原因：${chk.reason}', style: context.texts.bodySmall),
                ],
                const SizedBox(height: Space.sm),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    FilledButton.tonal(
                      onPressed: () => showResolveCheckDialog(
                        context,
                        controller: rc,
                        check: chk,
                      ),
                      child: const Text('核对并处理'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.sm),
        ],
        for (final session in legacyFlagged) ...[
          _LegacySessionCard(
            session: session,
            document: _docById(session.documentId),
            onPractice: widget.onPractice,
          ),
          const SizedBox(height: Space.sm),
        ],
      ],
    );
  }

  Widget _buildAllOrTrashSliver(BuildContext context, {required bool isTrash}) {
    final items = rc.allItems;
    final legacySessions = _unacceptedLegacySessions;
    final q = _searchQuery.trim().toLowerCase();
    final filteredItems = items.where((e) {
      if (q.isEmpty) return true;
      return e.item.prompt.toLowerCase().contains(q) ||
          e.item.objective.toLowerCase().contains(q) ||
          e.item.answer.toLowerCase().contains(q);
    }).toList();

    return SliverList.list(
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: Space.md),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(
                    prefixIcon: Padding(
                      padding: EdgeInsets.all(10),
                      child: QIcon(QIcons.search, size: IconSizes.sm),
                    ),
                    hintText: '搜索题干、知识点目标或答案…',
                  ),
                  onChanged: (v) => setState(() => _searchQuery = v),
                ),
              ),
              if (!isTrash) ...[
                const SizedBox(width: Space.sm),
                FilterChip(
                  label: const Text('仅看错题'),
                  selected: rc.scope.mistakesOnly,
                  onSelected: (selected) => rc.setScope(
                    ReviewScopeFilter(
                      query: rc.scope.query,
                      mistakesOnly: selected,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (!isTrash && legacySessions.isNotEmpty) ...[
          for (final session in legacySessions) ...[
            _LegacySessionCard(
              session: session,
              document: _docById(session.documentId),
              onPractice: widget.onPractice,
            ),
            const SizedBox(height: Space.sm),
          ],
        ],
        if (filteredItems.isEmpty &&
            (isTrash || legacySessions.isEmpty))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.xl),
            child: EmptyState(
              key: const ValueKey('review-empty'),
              icon: isTrash ? QIcons.trash : QIcons.review,
              title: isTrash ? '回收站为空' : '暂无复习题',
              message: isTrash
                  ? '移除的题目会先保留在此，可随时恢复。'
                  : '可从阅读、笔记或右上角新建第一道复习题。',
              action: isTrash
                  ? OutlinedButton(
                      onPressed: () => rc.setTrashedView(false),
                      child: const Text('返回全部题目'),
                    )
                  : OutlinedButton(
                      onPressed: widget.onGoLibrary,
                      child: const Text('打开书库'),
                    ),
            ),
          )
        else
          for (final entry in filteredItems) ...[
            _QueueEntryCard(
              entry: entry,
              inTrash: isTrash,
              onPracticeSingle: isTrash
                  ? null
                  : () => _openSession(
                      mode: ReviewSessionMode.free,
                      explicitIds: [entry.item.id],
                    ),
              onEdit: isTrash
                  ? null
                  : () => showCreateOrEditReviewItemDialog(
                      context,
                      study: study,
                      existing: entry.item,
                    ),
              onDefer: isTrash ? null : () => rc.deferItemOneDay(entry.item.id),
              onPauseToggle: isTrash
                  ? null
                  : () => rc.pauseOrResumeItem(entry.item),
              onTrash: isTrash ? null : () => rc.trashItem(entry.item.id),
              onRestore: isTrash ? () => rc.restoreItem(entry.item.id) : null,
              onPurge: isTrash ? () => rc.purgeItem(entry.item.id) : null,
              onManualDate:
                  isTrash ? null : () => _pickManualDueDate(entry.item),
            ),
            const SizedBox(height: Space.sm),
          ],
      ],
    );
  }

  Widget _buildStatsSliver(BuildContext context) {
    final stats = rc.stats;
    if (stats.totalAttempts == 0) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: EmptyState(
            key: const ValueKey('review-empty'),
            icon: QIcons.knowledge,
            title: '暂无统计数据',
            message: '完成主动回忆作答后，将展示独立闭卷通过率与负荷趋势。',
          ),
        ),
      );
    }

    final c = context.colors;
    final passLabel = stats.independentSampleCount == 0
        ? '暂无独立闭卷样本'
        : '${(stats.independentRecallRate! * 100).round()}% '
              '(${stats.independentSuccessCount}/${stats.independentSampleCount})';

    return SliverList.list(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final cols = constraints.maxWidth < 580 ? 2 : 4;
            return GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: cols,
              mainAxisSpacing: Space.sm,
              crossAxisSpacing: Space.sm,
              childAspectRatio: constraints.maxWidth < 580 ? 1.55 : 1.75,
              children: [
                _StatTile(
                  label: '独立闭卷通过率',
                  value: passLabel,
                  note: '严格剔除提示与查看原文',
                ),
                _StatTile(
                  label: '协助完成次数',
                  value: '${stats.assistedCount} 次',
                  note: '查看提示/原文后完成',
                ),
                _StatTile(
                  label: '跨天重做过关',
                  value: '${stats.crossDayRedoPassedCount} 题',
                  note: '变式迁移过关 ${stats.variantPassedCount} 题',
                ),
                _StatTile(
                  label: '近 30 天实际投入',
                  value: '${stats.activeMinutes} 分钟',
                  note: '累计完成 ${stats.totalAttempts} 次',
                ),
              ],
            );
          },
        ),
        const SizedBox(height: Space.lg),
        AppCard(
          padding: const EdgeInsets.all(Space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('未来 14 天待复习负荷预测', style: context.texts.titleSmall),
              const SizedBox(height: Space.md),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final e in stats.forecastNext14Days.entries)
                      Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: Column(
                          children: [
                            Text(
                              '${e.value}',
                              style: context.texts.labelSmall!.copyWith(
                                fontFeatures: AppNumerals.tabular,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Container(
                              width: 18,
                              height: (e.value * 8.0).clamp(4.0, 72.0),
                              decoration: BoxDecoration(
                                color: e.value > 0 ? c.primary : c.outline,
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              e.key.substring(5),
                              style: context.texts.labelSmall!.copyWith(
                                fontSize: 10.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Space.lg),
        if (stats.weakObjectives.isNotEmpty) ...[
          AppCallout(
            tone: CalloutTone.warning,
            title: '薄弱知识点提醒',
            message: stats.weakObjectives.join('、'),
          ),
          const SizedBox(height: Space.lg),
        ],
        if (stats.knowledgeEvidence.isNotEmpty) ...[
          _SectionTitle(
            title: '知识点证据等级 (${stats.knowledgeEvidence.length})',
            subtitle: '按初次记忆、跨天复现与迁移应用分级',
          ),
          const SizedBox(height: Space.sm),
          for (final ev in stats.knowledgeEvidence) ...[
            AppCard(
              padding: const EdgeInsets.all(Space.md),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(ev.objective, style: context.texts.labelLarge),
                        const SizedBox(height: 2),
                        Text(
                          '${ev.itemCount} 题 · 独立通过 ${ev.independentCrossDayDays} 天',
                          style: context.texts.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  AppBadge(
                    label: ev.level.label,
                    tone: ev.level == KnowledgeEvidenceLevel.needsStudy
                        ? BadgeTone.warm
                        : (ev.level ==
                                    KnowledgeEvidenceLevel.applicationVerified ||
                                ev.level ==
                                    KnowledgeEvidenceLevel.crossDayRecall
                            ? BadgeTone.green
                            : BadgeTone.blue),
                    dense: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: Space.sm),
          ],
        ],
      ],
    );
  }
}

class _HeaderBar extends StatelessWidget {
  const _HeaderBar({
    required this.hasStudy,
    required this.trashedView,
    required this.dueCount,
    required this.overdueCount,
    required this.onCreate,
    required this.onAiGenerate,
    required this.onExport,
    required this.onToggleTrash,
  });

  final bool hasStudy;
  final bool trashedView;
  final int dueCount;
  final int overdueCount;
  final VoidCallback? onCreate;
  final VoidCallback? onAiGenerate;
  final VoidCallback? onExport;
  final VoidCallback? onToggleTrash;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: Space.md,
    runSpacing: Space.sm,
    alignment: WrapAlignment.spaceBetween,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            trashedView ? '复习回收站' : '主动回忆与错题复习',
            style: context.texts.headlineSmall,
          ),
          if (hasStudy && !trashedView)
            Text(
              '今日到期 $dueCount 题${overdueCount > 0 ? ' · 超期 $overdueCount 题' : ''}',
              style: context.texts.bodySmall,
            ),
        ],
      ),
      if (hasStudy)
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            FilledButton.icon(
              onPressed: onCreate,
              icon: const QIcon(QIcons.add, size: IconSizes.sm),
              label: const Text('新建复习题'),
            ),
            OutlinedButton.icon(
              onPressed: onAiGenerate,
              icon: const QIcon(QIcons.ai, size: IconSizes.sm),
              label: const Text('AI 出题'),
            ),
            OutlinedButton.icon(
              onPressed: onExport,
              icon: const QIcon(QIcons.download, size: IconSizes.sm),
              label: const Text('导出'),
            ),
            OutlinedButton.icon(
              onPressed: onToggleTrash,
              icon: QIcon(
                trashedView ? QIcons.back : QIcons.trash,
                size: IconSizes.sm,
              ),
              label: Text(trashedView ? '返回列表' : '回收站'),
            ),
          ],
        ),
    ],
  );
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.tab,
    required this.onSelect,
    required this.dueCount,
    required this.mistakeCount,
    required this.checkCount,
    required this.totalCount,
  });

  final ReviewTab tab;
  final ValueChanged<ReviewTab> onSelect;
  final int dueCount;
  final int mistakeCount;
  final int checkCount;
  final int totalCount;

  @override
  Widget build(BuildContext context) {
    final segments = <(ReviewTab, String)>[
      (ReviewTab.today, '今日'),
      (ReviewTab.mistakes, '错题 ($mistakeCount)'),
      (ReviewTab.checks, '待核对'),
      (ReviewTab.all, '全部'),
      (ReviewTab.stats, '统计'),
    ];
    return Align(
      alignment: Alignment.centerLeft,
      child: SingleChildScrollView(
        key: const ValueKey('review-filter'),
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (value, label) in segments) ...[
              ChoiceChip(
                label: Text(
                  value == ReviewTab.checks && checkCount > 0
                      ? '待核对'
                      : value == ReviewTab.today && dueCount > 0
                      ? '今日 ($dueCount)'
                      : value == ReviewTab.all && totalCount > 0
                      ? '全部'
                      : label,
                ),
                selected: tab == value,
                onSelected: (_) => onSelect(value),
              ),
              const SizedBox(width: 6),
            ],
          ],
        ),
      ),
    );
  }
}

class _TodayHeroCard extends StatelessWidget {
  const _TodayHeroCard({
    required this.summary,
    required this.budgetMinutes,
    required this.hasResume,
    required this.onSelectBudget,
    required this.onCustomBudget,
    required this.onStartOrResume,
    required this.onFreePractice,
    required this.onScheduleBatch,
  });

  final ReviewDashboardSummary summary;
  final int budgetMinutes;
  final bool hasResume;
  final ValueChanged<int> onSelectBudget;
  final VoidCallback onCustomBudget;
  final VoidCallback onStartOrResume;
  final VoidCallback onFreePractice;
  final VoidCallback onScheduleBatch;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      padding: const EdgeInsets.all(Space.xl),
      background: c.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: Space.md,
            runSpacing: Space.md,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    summary.dueCount > 0
                        ? '今日建议复习 ${summary.dueCount} 题'
                        : '今日到期复习已清零',
                    style: context.texts.titleLarge,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '预算 $budgetMinutes 分钟 · 超期 ${summary.overdueCount} · 错题未过关 ${summary.mistakesCount} · 活跃题库 ${summary.totalActiveCount}',
                    style: context.texts.bodySmall,
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: onScheduleBatch,
                    child: const Text('排入日程'),
                  ),
                  OutlinedButton(
                    onPressed: summary.totalActiveCount == 0
                        ? null
                        : onFreePractice,
                    child: const Text('自由练习'),
                  ),
                  FilledButton.icon(
                    key: const ValueKey('review-start-btn'),
                    onPressed: (summary.dueCount == 0 && !hasResume)
                        ? (summary.totalActiveCount > 0 ? onFreePractice : null)
                        : onStartOrResume,
                    icon: const QIcon(QIcons.play, size: IconSizes.sm),
                    label: Text(hasResume ? '继续复习' : '开始今日复习'),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: Space.md),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('每日预算：', style: context.texts.bodySmall),
              for (final mins in [10, 20, 30])
                ChoiceChip(
                  label: Text('$mins 分钟'),
                  selected: budgetMinutes == mins,
                  onSelected: (_) => onSelectBudget(mins),
                ),
              ActionChip(
                label: const Text('自定义'),
                onPressed: onCustomBudget,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(title, style: context.texts.titleSmall),
      const SizedBox(height: 2),
      Text(subtitle, style: context.texts.bodySmall),
    ],
  );
}

class _CandidateCard extends StatelessWidget {
  const _CandidateCard({
    required this.candidate,
    required this.onAccept,
    required this.onEditAccept,
    required this.onIgnore,
  });

  final ReviewCandidate candidate;
  final VoidCallback onAccept;
  final VoidCallback onEditAccept;
  final VoidCallback onIgnore;

  @override
  Widget build(BuildContext context) => AppCard(
    padding: const EdgeInsets.all(Space.md),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            AppBadge(
              label: candidate.sourceType == 'lesson' ? '课程错题' : '阅读候选',
              tone: BadgeTone.warm,
              dense: true,
            ),
            if (candidate.documentTitle.isNotEmpty)
              AppBadge(label: candidate.documentTitle, dense: true),
          ],
        ),
        const SizedBox(height: 6),
        Text(candidate.prompt, style: context.texts.labelLarge),
        if (candidate.reason.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(candidate.reason, style: context.texts.bodySmall),
        ],
        const SizedBox(height: Space.sm),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonal(onPressed: onAccept, child: const Text('直接加入复习')),
            OutlinedButton(onPressed: onEditAccept, child: const Text('编辑后加入')),
            TextButton(onPressed: onIgnore, child: const Text('暂不加入')),
          ],
        ),
      ],
    ),
  );
}

class _QueueEntryCard extends StatelessWidget {
  const _QueueEntryCard({
    required this.entry,
    this.inTrash = false,
    this.onPracticeSingle,
    this.onEdit,
    this.onDefer,
    this.onPauseToggle,
    this.onTrash,
    this.onRestore,
    this.onPurge,
    this.onManualDate,
  });

  final ReviewQueueEntry entry;
  final bool inTrash;
  final VoidCallback? onPracticeSingle;
  final VoidCallback? onEdit;
  final VoidCallback? onDefer;
  final VoidCallback? onPauseToggle;
  final VoidCallback? onTrash;
  final VoidCallback? onRestore;
  final VoidCallback? onPurge;
  final VoidCallback? onManualDate;

  @override
  Widget build(BuildContext context) {
    final item = entry.item;
    final origin = entry.origins.firstOrNull;
    return AppCard(
      padding: const EdgeInsets.all(Space.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    AppBadge(label: item.kind.label, dense: true),
                    if (entry.overdueDays > 0)
                      AppBadge(
                        label: '超期 ${entry.overdueDays} 天',
                        tone: BadgeTone.danger,
                        dense: true,
                      ),
                    if (item.isPaused || entry.schedule.paused)
                      const AppBadge(
                        label: '已暂停',
                        tone: BadgeTone.neutral,
                        dense: true,
                      ),
                    if (entry.origins.any((o) => o.sourceNoteUpdated))
                      const AppBadge(
                        label: '来源已更新',
                        tone: BadgeTone.warm,
                        dense: true,
                      ),
                    if (origin != null && !origin.sourceAvailable)
                      const AppBadge(
                        label: '原书已移除（保留快照）',
                        tone: BadgeTone.warm,
                        dense: true,
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  item.prompt,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.labelLarge,
                ),
                if (item.objective.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(item.objective, style: context.texts.bodySmall),
                ],
              ],
            ),
          ),
          const SizedBox(width: Space.sm),
          if (inTrash) ...[
            TextButton(onPressed: onRestore, child: const Text('恢复')),
            TextButton(onPressed: onPurge, child: const Text('彻底清除')),
          ] else ...[
            if (onPracticeSingle != null)
              OutlinedButton(
                onPressed: onPracticeSingle,
                child: const Text('练习'),
              ),
            PopupMenuButton<String>(
              onSelected: (v) {
                switch (v) {
                  case 'edit':
                    onEdit?.call();
                  case 'defer':
                    onDefer?.call();
                  case 'date':
                    onManualDate?.call();
                  case 'pause':
                    onPauseToggle?.call();
                  case 'trash':
                    onTrash?.call();
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'edit', child: Text('编辑题目')),
                const PopupMenuItem(value: 'defer', child: Text('推迟到明天')),
                const PopupMenuItem(value: 'date', child: Text('指定复习日期')),
                PopupMenuItem(
                  value: 'pause',
                  child: Text(item.isPaused ? '恢复自动安排' : '暂停此题'),
                ),
                const PopupMenuItem(value: 'trash', child: Text('移入回收站')),
              ],
              icon: const QIcon(QIcons.more, size: IconSizes.sm),
            ),
          ],
        ],
      ),
    );
  }
}

class _MistakeCard extends StatelessWidget {
  const _MistakeCard({
    required this.entry,
    required this.onPractice,
    this.onEdit,
    this.onCreateVariant,
    this.onBackToSource,
  });

  final ReviewQueueEntry entry;
  final VoidCallback onPractice;
  final VoidCallback? onEdit;
  final VoidCallback? onCreateVariant;
  final VoidCallback? onBackToSource;

  @override
  Widget build(BuildContext context) {
    final item = entry.item;
    return AppCard(
      padding: const EdgeInsets.all(Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              AppBadge(
                label: '累计错 ${item.wrongStreak} 次',
                tone: BadgeTone.danger,
                dense: true,
              ),
              if (item.errorReason.isNotEmpty)
                AppBadge(
                  label: item.errorReason,
                  tone: BadgeTone.warm,
                  dense: true,
                ),
              if (item.wrongStreak >= 3)
                const AppBadge(
                  label: '建议回看原书并拆解步骤',
                  tone: BadgeTone.blue,
                  dense: true,
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(item.prompt, style: context.texts.labelLarge),
          if (item.correctionNote.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('订正：${item.correctionNote}', style: context.texts.bodySmall),
          ],
          const SizedBox(height: Space.sm),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonal(
                onPressed: onPractice,
                child: const Text('立即重练'),
              ),
              if (onEdit != null)
                OutlinedButton(onPressed: onEdit, child: const Text('修改订正')),
              if (onCreateVariant != null)
                OutlinedButton(
                  onPressed: onCreateVariant,
                  child: const Text('生成变式题'),
                ),
              if (onBackToSource != null)
                TextButton(
                  onPressed: onBackToSource,
                  child: const Text('回看原书'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
    required this.note,
  });

  final String label;
  final String value;
  final String note;

  @override
  Widget build(BuildContext context) => AppCard(
    padding: const EdgeInsets.all(Space.md),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(label, style: context.texts.bodySmall),
        const SizedBox(height: 4),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.texts.titleMedium!.copyWith(
            fontWeight: FontWeight.w700,
            fontFeatures: AppNumerals.tabular,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          note,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.texts.labelSmall,
        ),
      ],
    ),
  );
}

class _LegacySessionCard extends StatelessWidget {
  const _LegacySessionCard({
    required this.session,
    required this.document,
    required this.onPractice,
  });

  final StudySession session;
  final DocumentRecord? document;
  final void Function(DocumentRecord document, StudySession session) onPractice;

  @override
  Widget build(BuildContext context) {
    final last = session.attempts.isEmpty ? null : session.attempts.last;
    return AppCard(
      padding: const EdgeInsets.all(Space.md),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  document?.title ?? '未关联资料的练习',
                  style: context.texts.labelLarge,
                ),
                const SizedBox(height: 2),
                Text(
                  '第 ${session.startPage}–${session.endPage} 页 · '
                  '${last?.question ?? session.goal}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.bodySmall,
                ),
              ],
            ),
          ),
          if (document != null) ...[
            const SizedBox(width: Space.sm),
            OutlinedButton(
              onPressed: () => onPractice(document!, session),
              child: const Text('继续练习'),
            ),
          ],
        ],
      ),
    );
  }
}
