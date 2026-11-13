import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app_controller.dart';
import '../../../services/ai_gateway.dart';
import '../../../ui/dialogs/app_dialogs.dart';
import '../../../ui/theme/tokens.dart';
import '../../../ui/widgets/app_dialog.dart';
import '../../../ui/widgets/app_surfaces.dart';
import '../data/review_repository.dart';
import '../models/review_models.dart';
import '../review_controller.dart';
import '../services/review_answer_evaluator.dart';
import 'review_dialogs.dart';

class ReviewSessionPage extends StatefulWidget {
  const ReviewSessionPage({
    super.key,
    required this.study,
    required this.onJumpToSource,
    this.onCompleted,
  });

  final StudyController study;
  final Future<void> Function(ReviewOrigin origin)? onJumpToSource;
  final VoidCallback? onCompleted;

  @override
  State<ReviewSessionPage> createState() => _ReviewSessionPageState();
}

class _ReviewSessionPageState extends State<ReviewSessionPage> {
  final _answerController = TextEditingController();
  final _answerFocus = FocusNode();
  final _correctionNoteController = TextEditingController();
  final _correctionFocus = FocusNode();

  bool _revealed = false;
  bool _hintVisible = false;
  bool _usedHint = false;
  bool _viewedSource = false;
  final Set<int> _peekedRects = {};

  LocalRuleCheckResult? _objectiveCheck;
  AiReviewSuggestion? _aiSuggestion;
  bool _aiLoading = false;
  bool _aiDisputed = false;
  String? _selectedReason;
  String? _loadedItemKey;

  ReviewController get rc => widget.study.reviewController;

  @override
  void initState() {
    super.initState();
    rc.addListener(_onControllerChanged);
    rc.beginActiveItemTimer();
    _syncCurrentItemState();
  }

  @override
  void dispose() {
    rc.removeListener(_onControllerChanged);
    _answerController.dispose();
    _answerFocus.dispose();
    _correctionNoteController.dispose();
    _correctionFocus.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    _syncCurrentItemState();
    setState(() {});
  }

  void _syncCurrentItemState() {
    final session = rc.activeSession;
    if (session == null || session.currentIndex >= session.items.length) {
      return;
    }
    final slot = session.items[session.currentIndex];
    final item = rc.repository.getItem(slot.itemId);
    final nextKey =
        '${session.id}:${session.currentIndex}:${item?.revision ?? 0}';
    if (nextKey == _loadedItemKey) return;
    _loadedItemKey = nextKey;

    _answerController.text = slot.draftAnswer;
    _revealed = false;
    _hintVisible = slot.usedHint;
    _usedHint = slot.usedHint;
    _viewedSource = slot.viewedSource;
    _peekedRects.clear();
    _objectiveCheck = null;
    _aiSuggestion = null;
    _aiDisputed = false;
    _selectedReason = (item?.errorReason.isNotEmpty == true)
        ? item!.errorReason
        : null;
    _correctionNoteController.text = item?.correctionNote ?? '';
  }

  void _reveal(ReviewItem item) {
    LocalRuleCheckResult? check;
    if (item.kind == ReviewItemKind.blank && item.blankAnswers.isNotEmpty) {
      final tokens = _answerController.text
          .split(RegExp(r'[；;\n\s]+'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      if (tokens.isNotEmpty) {
        check = ReviewAnswerEvaluator.evaluateBlanks(
          item: item,
          userBlanks: tokens,
        );
      }
    }
    setState(() {
      _revealed = true;
      _objectiveCheck = check;
    });
    _answerFocus.unfocus();
    _correctionFocus.unfocus();
  }

  Future<void> _askAiReview(ReviewItem item) async {
    if (_aiLoading) return;
    final answerText = _answerController.text.trim();
    if (answerText.isEmpty) {
      _toast('请先填写你的作答内容，再请 AI 对照评阅。');
      return;
    }
    final revisionAtStart = item.revision;
    final hashAtStart = ReviewRepository.hashAnswer(answerText);

    setState(() => _aiLoading = true);
    try {
      final evidence = <AiEvidence>[];
      final origins = rc.repository.getOrigins(item.id);
      final origin = origins.firstOrNull;
      if (origin != null &&
          origin.documentId != null &&
          origin.page != null) {
        final doc = widget.study.store.getDocument(origin.documentId!);
        final pages = doc == null
            ? const []
            : widget.study.store.getPages(doc.id);
        for (final pRec in pages) {
          if (pRec.page >= origin.page! - 1 && pRec.page <= origin.page! + 1) {
            if (pRec.text.trim().isNotEmpty) {
              evidence.add(
                AiEvidence(
                  id: 'review-${doc!.id}-p${pRec.page}',
                  documentId: doc.id,
                  documentHash: doc.contentHash,
                  page: pRec.page,
                  text: pRec.text,
                ),
              );
            }
          }
        }
      }

      final prepared = widget.study.reviewAi.prepareAnswerReview(
        settings: widget.study.settings,
        item: item,
        learnerAnswer: answerText,
        evidence: evidence,
      );
      if (!mounted) return;
      final action = await showRequestPreview(
        context,
        request: prepared,
        wholePage: true,
      );
      if (action != 'send' || !mounted) {
        setState(() => _aiLoading = false);
        return;
      }

      final response = await widget.study.gateway.send(prepared);
      if (!mounted) return;
      final parsed = widget.study.reviewAi.parseReviewSuggestion(
        rawText: response.answer,
        expectedItemRevision: revisionAtStart,
        expectedAnswerHash: hashAtStart,
      );

      final currentItem = rc.repository.getItem(item.id);
      if (currentItem == null ||
          !widget.study.reviewAi.isSuggestionFresh(
            suggestion: parsed,
            currentItem: currentItem,
            currentAnswerText: _answerController.text,
          )) {
        setState(() => _aiLoading = false);
        _toast('题干或你的作答已发生变化，旧的 AI 评阅结果已丢弃。');
        return;
      }

      setState(() {
        _aiLoading = false;
        _aiSuggestion = parsed;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _aiLoading = false);
        _toast('$e');
      }
    }
  }

  void _submitRating(
    ReviewItem item,
    int position, {
    ReviewRating? rating,
    ComplexityOutcome? outcome,
  }) {
    final result = rc.submitGrade(
      item: item,
      sessionPosition: position,
      answerText: _answerController.text,
      usedHint: _usedHint,
      viewedSource: _viewedSource,
      rating: rating,
      complexityOutcome: outcome,
      aiSuggestion: _aiSuggestion,
      aiDisputed: _aiDisputed,
      resultSource: _aiSuggestion != null && !_aiDisputed
          ? ReviewResultSource.aiConfirmed
          : ReviewResultSource.self,
      errorReason: _selectedReason,
      correctionNote: _correctionNoteController.text.trim(),
    );
    if (result == null) return;
    if (mounted) {
      FocusScope.of(context).unfocus();
      setState(() {});
    }
  }

  Future<void> _flagQuestion(ReviewItem item) async {
    final noteCtrl = TextEditingController();
    final saved = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: '标记此题 / 答案待核对',
        subtitle: '移入「待核对」并暂停调度，避免问题卡误导记忆判断。',
        icon: QIcons.warning,
        actions: [
          DialogActions.cancel(context),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('提交待核对'),
          ),
        ],
        content: TextField(
          controller: noteCtrl,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: '哪里有疑问？',
            hintText: '例如：参考答案漏了连续性条件 / 出处页码不对',
          ),
        ),
      ),
    );
    final reason = noteCtrl.text.trim();
    noteCtrl.dispose();
    if (saved == true) {
      rc.repository.upsertCheck(
        originKey: 'item_flag:${item.id}:v${item.revision}',
        targetType: ReviewCheckTargetType.item,
        targetId: item.id,
        targetVersion: item.revision,
        itemId: item.id,
        question: item.prompt,
        answer: item.answer,
        reason: reason.isEmpty ? '复习作答中人工标记待核对' : reason,
      );
      rc.refresh();
      _toast('已记入“待核对”列表。');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final session = rc.activeSession;
    final c = context.colors;

    if (session == null ||
        session.status == ReviewSessionStatus.completed ||
        session.currentIndex >= session.items.length) {
      return _SummaryView(
        study: widget.study,
        session: session,
        onFinish: () {
          widget.onCompleted?.call();
          Navigator.of(context).maybePop();
        },
        onScheduleBatch: () =>
            showScheduleReviewBatchDialog(context, study: widget.study),
      );
    }

    final slot = session.items[session.currentIndex];
    final item = rc.repository.getItem(slot.itemId);
    if (item == null) {
      return Scaffold(
        backgroundColor: c.canvas,
        appBar: AppBar(title: const Text('复习会话')),
        body: Center(
          child: EmptyState(
            icon: QIcons.review,
            title: '这道题目已被清理',
            message: '你可以跳过它并继续其余题目。',
            action: FilledButton(
              onPressed: () => rc.skipCurrentItem(session.currentIndex),
              child: const Text('跳过此题'),
            ),
          ),
        ),
      );
    }

    final origins = rc.repository.getOrigins(item.id);
    final previewList = item.scheduleMode == ReviewScheduleMode.fsrs
        ? rc.previewRatingsFor(item)
        : const <ReviewRatingPreview>[];

    final shortcutsEnabled =
        _revealed &&
        !_answerFocus.hasFocus &&
        !_correctionFocus.hasFocus &&
        item.scheduleMode == ReviewScheduleMode.fsrs;

    return Focus(
      autofocus: false,
      onKeyEvent: (node, event) {
        if (!shortcutsEnabled || event is! KeyDownEvent) {
          return KeyEventResult.ignored;
        }
        final key = event.logicalKey;
        ReviewRating? chosen;
        if (key == LogicalKeyboardKey.digit1) chosen = ReviewRating.again;
        if (key == LogicalKeyboardKey.digit2) chosen = ReviewRating.hard;
        if (key == LogicalKeyboardKey.digit3) chosen = ReviewRating.good;
        if (key == LogicalKeyboardKey.digit4) chosen = ReviewRating.easy;
        if (chosen != null) {
          _submitRating(item, session.currentIndex, rating: chosen);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        backgroundColor: c.canvas,
        body: SafeArea(
          child: Column(
            children: [
              _SessionHeader(
                session: session,
                item: item,
                canUndo: rc.canUndoLastGrade,
                onBack: () {
                  rc.pauseCurrentSession();
                  Navigator.of(context).maybePop();
                },
                onUndo: rc.undoLastGrade,
                onDefer: () {
                  rc.deferItemOneDay(item.id);
                  rc.skipCurrentItem(session.currentIndex);
                },
                onEdit: () async {
                  await showCreateOrEditReviewItemDialog(
                    context,
                    study: widget.study,
                    existing: item,
                  );
                  if (mounted) setState(() {});
                },
                onFlag: () => _flagQuestion(item),
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: context.motion(Motion.slow),
                  switchInCurve: Motion.curve,
                  switchOutCurve: Curves.easeIn,
                  layoutBuilder: (currentChild, previousChildren) => Stack(
                    fit: StackFit.expand,
                    children: [...previousChildren, ?currentChild],
                  ),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0.02, 0),
                        end: Offset.zero,
                      ).animate(
                        CurvedAnimation(parent: animation, curve: Motion.curve),
                      ),
                      child: child,
                    ),
                  ),
                  child: Center(
                    key: ValueKey(
                      'review-card-${item.id}-${session.currentIndex}',
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 820),
                      child: ListView(
                      padding: const EdgeInsets.fromLTRB(
                        Space.xl,
                        Space.lg,
                        Space.xl,
                        Space.xxl,
                      ),
                      children: [
                        if (rc.error != null) ...[
                          AppCallout(
                            tone: CalloutTone.error,
                            message: rc.error!,
                          ),
                          const SizedBox(height: Space.md),
                        ],
                        _PromptCard(
                          item: item,
                          origins: origins,
                          revealed: _revealed,
                          peekedRects: _peekedRects,
                          onPeekRect: (idx) => setState(() {
                            _peekedRects.add(idx);
                            _usedHint = true;
                          }),
                          onJumpToSource: (origin) async {
                            setState(() => _viewedSource = true);
                            rc.saveCurrentDraft(
                              position: session.currentIndex,
                              draftAnswer: _answerController.text,
                              usedHint: _usedHint,
                              viewedSource: true,
                            );
                            if (origin.sourceAvailable &&
                                widget.onJumpToSource != null) {
                              await widget.onJumpToSource!(origin);
                            } else {
                              if (!context.mounted) return;
                              await showAppDialog<void>(
                                context: context,
                                builder: (context) => AppDialog(
                                  title: '出处文本快照',
                                  subtitle: origin.sourceAvailable
                                      ? '${origin.documentTitle} 第 ${origin.page ?? 1} 页'
                                      : '原书已被移入回收站或清理，已保留文本快照',
                                  icon: QIcons.anchor,
                                  actions: [
                                    FilledButton(
                                      onPressed: () => Navigator.pop(context),
                                      child: const Text('关闭'),
                                    ),
                                  ],
                                  content: SelectableText(
                                    origin.snapshotText.isEmpty
                                        ? '暂无关联原文摘要。'
                                        : origin.snapshotText,
                                  ),
                                ),
                              );
                            }
                          },
                        ),
                        const SizedBox(height: Space.lg),
                        AppCard(
                          padding: const EdgeInsets.all(Space.lg),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text('主动回忆作答', style: context.texts.labelLarge),
                              const SizedBox(height: Space.sm),
                              TextField(
                                controller: _answerController,
                                focusNode: _answerFocus,
                                maxLines: 4,
                                decoration: InputDecoration(
                                  hintText: item.kind == ReviewItemKind.blank
                                      ? '依次写出各空答案（空格或分号分隔）…'
                                      : '先独立回忆或推导，再点击揭示参考答案',
                                ),
                                onChanged: (val) => rc.saveCurrentDraft(
                                  position: session.currentIndex,
                                  draftAnswer: val,
                                  usedHint: _usedHint,
                                  viewedSource: _viewedSource,
                                ),
                              ),
                              if (item.hint.trim().isNotEmpty) ...[
                                const SizedBox(height: Space.sm),
                                AnimatedSize(
                                  duration: context.motion(Motion.base),
                                  curve: Motion.curve,
                                  alignment: Alignment.topLeft,
                                  child: AnimatedSwitcher(
                                    duration: context.motion(Motion.fast),
                                    switchInCurve: Motion.curve,
                                    switchOutCurve: Curves.easeIn,
                                    child: !_hintVisible
                                        ? Align(
                                            key: const ValueKey('hint-btn'),
                                            alignment: Alignment.centerLeft,
                                            child: TextButton.icon(
                                              onPressed: () => setState(() {
                                                _hintVisible = true;
                                                _usedHint = true;
                                              }),
                                              icon: const QIcon(
                                                QIcons.info,
                                                size: IconSizes.sm,
                                              ),
                                              label: const Text(
                                                '查看助记提示（记为协助完成）',
                                              ),
                                            ),
                                          )
                                        : AppCallout(
                                            key: const ValueKey('hint-callout'),
                                            tone: CalloutTone.info,
                                            title: '助记提示（本次记为协助完成）',
                                            message: item.hint,
                                          ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: Space.lg),
                        AnimatedSize(
                          duration: context.motion(Motion.slow),
                          curve: Motion.curve,
                          alignment: Alignment.topCenter,
                          child: AnimatedSwitcher(
                            duration: context.motion(Motion.base),
                            switchInCurve: Motion.curve,
                            switchOutCurve: Curves.easeIn,
                            transitionBuilder: (child, animation) =>
                                FadeTransition(
                                  opacity: animation,
                                  child: SlideTransition(
                                    position: Tween<Offset>(
                                      begin: const Offset(0, 0.025),
                                      end: Offset.zero,
                                    ).animate(
                                      CurvedAnimation(
                                        parent: animation,
                                        curve: Motion.curve,
                                      ),
                                    ),
                                    child: child,
                                  ),
                                ),
                            child: !_revealed
                                ? SizedBox(
                                    key: const ValueKey('review-pre-reveal'),
                                    width: double.infinity,
                                    child: Wrap(
                                      spacing: Space.sm,
                                      runSpacing: Space.sm,
                                      alignment: WrapAlignment.spaceBetween,
                                      children: [
                                        OutlinedButton.icon(
                                          onPressed: () => rc.skipCurrentItem(
                                            session.currentIndex,
                                          ),
                                          icon: const QIcon(
                                            QIcons.chevronRight,
                                            size: IconSizes.sm,
                                          ),
                                          label: const Text('暂时跳过'),
                                        ),
                                        FilledButton.icon(
                                          key: const ValueKey(
                                            'review-reveal-btn',
                                          ),
                                          onPressed: () => _reveal(item),
                                          icon: const QIcon(
                                            QIcons.visible,
                                            size: IconSizes.sm,
                                          ),
                                          label: const Text('揭示参考答案'),
                                        ),
                                      ],
                                    ),
                                  )
                                : Column(
                                    key: const ValueKey('review-revealed'),
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      _RevealPanel(
                                        item: item,
                                        objectiveCheck: _objectiveCheck,
                                        usedAssistance:
                                            _usedHint || _viewedSource,
                                        aiLoading: _aiLoading,
                                        aiSuggestion: _aiSuggestion,
                                        aiDisputed: _aiDisputed,
                                        onAskAi: () => _askAiReview(item),
                                        onDisputeAi: () => setState(() {
                                          _aiDisputed = !_aiDisputed;
                                        }),
                                        selectedReason: _selectedReason,
                                        onReasonChanged: (r) => setState(
                                          () => _selectedReason = r,
                                        ),
                                        correctionController:
                                            _correctionNoteController,
                                        correctionFocus: _correctionFocus,
                                      ),
                                      const SizedBox(height: Space.lg),
                                      _GradingBar(
                                        item: item,
                                        previews: previewList,
                                        onRateFsrs: (rating) => _submitRating(
                                          item,
                                          session.currentIndex,
                                          rating: rating,
                                        ),
                                        onRateTraining: (outcome) =>
                                            _submitRating(
                                              item,
                                              session.currentIndex,
                                              outcome: outcome,
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
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SessionHeader extends StatelessWidget {
  const _SessionHeader({
    required this.session,
    required this.item,
    required this.canUndo,
    required this.onBack,
    required this.onUndo,
    required this.onDefer,
    required this.onEdit,
    required this.onFlag,
  });

  final ReviewSession session;
  final ReviewItem item;
  final bool canUndo;
  final VoidCallback onBack;
  final VoidCallback onUndo;
  final VoidCallback onDefer;
  final VoidCallback onEdit;
  final VoidCallback onFlag;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final total = session.items.length;
    final done = session.currentIndex;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: 10),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.outline)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: '暂停并退出（保留进度）',
            onPressed: onBack,
            icon: const QIcon(QIcons.back, size: IconSizes.md),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${session.mode.label} · 第 ${done + 1} / $total 题',
                  style: context.texts.titleSmall,
                ),
                const SizedBox(height: 4),
                TweenAnimationBuilder<double>(
                  tween: Tween<double>(
                    end: total == 0 ? 0 : (done / total).clamp(0.0, 1.0),
                  ),
                  duration: context.motion(Motion.slow),
                  curve: Motion.curve,
                  builder: (context, value, _) => ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: value,
                      minHeight: 4,
                      backgroundColor: c.tint,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: Space.md),
          if (canUndo)
            TextButton.icon(
              onPressed: onUndo,
              icon: const QIcon(QIcons.undo, size: IconSizes.sm),
              label: const Text('撤销上题'),
            ),
          PopupMenuButton<String>(
            tooltip: '更多操作',
            onSelected: (value) {
              switch (value) {
                case 'defer':
                  onDefer();
                case 'edit':
                  onEdit();
                case 'flag':
                  onFlag();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'defer', child: Text('推迟到明天再看')),
              PopupMenuItem(value: 'edit', child: Text('编辑题目/答案')),
              PopupMenuItem(value: 'flag', child: Text('标为“待核对”问题')),
            ],
            icon: const QIcon(QIcons.more, size: IconSizes.md),
          ),
        ],
      ),
    );
  }
}

class _PromptCard extends StatelessWidget {
  const _PromptCard({
    required this.item,
    required this.origins,
    required this.revealed,
    required this.peekedRects,
    required this.onPeekRect,
    required this.onJumpToSource,
  });

  final ReviewItem item;
  final List<ReviewOrigin> origins;
  final bool revealed;
  final Set<int> peekedRects;
  final ValueChanged<int> onPeekRect;
  final ValueChanged<ReviewOrigin> onJumpToSource;

  String _maskedPrompt() {
    if (item.kind != ReviewItemKind.blank) return item.prompt;
    var index = 0;
    return item.prompt.replaceAllMapped(RegExp(r'\{\{(.+?)\}\}'), (_) {
      index += 1;
      return ' [____ 空$index ____] ';
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      padding: const EdgeInsets.all(Space.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              AppBadge(label: item.kind.label, tone: BadgeTone.blue, dense: true),
              AppBadge(
                label: item.scheduleMode.label,
                tone: BadgeTone.neutral,
                dense: true,
              ),
              if (origins.any((o) => o.sourceNoteUpdated))
                const AppBadge(
                  label: '关联笔记已更新',
                  tone: BadgeTone.warm,
                  dense: true,
                ),
              for (final origin in origins)
                ActionChip(
                  avatar: QIcon(
                    origin.sourceAvailable ? QIcons.anchor : QIcons.warning,
                    size: IconSizes.sm,
                    color: origin.sourceAvailable ? c.blue : c.warm,
                  ),
                  label: Text(
                    origin.sourceAvailable
                        ? (origin.documentTitle.isNotEmpty
                              ? '${origin.documentTitle} · 第 ${origin.page ?? 1} 页'
                              : '查看来源')
                        : '原书已移除 · 查看快照',
                  ),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onJumpToSource(origin),
                ),
            ],
          ),
          if (item.objective.trim().isNotEmpty) ...[
            const SizedBox(height: Space.sm),
            Text(
              item.objective,
              style: context.texts.labelLarge!.copyWith(color: c.inkMuted),
            ),
          ],
          const SizedBox(height: Space.md),
          SelectableText(
            _maskedPrompt(),
            style: context.texts.titleMedium!.copyWith(height: 1.55),
          ),
          if (item.steps.isNotEmpty && !revealed) ...[
            const SizedBox(height: Space.md),
            Text('本题包含 ${item.steps.length} 个关键步骤，请先自行推导完整步骤。',
                style: context.texts.bodySmall),
          ],
          if (item.kind == ReviewItemKind.occlusion &&
              item.imagePath != null &&
              File(item.imagePath!).existsSync()) ...[
            const SizedBox(height: Space.md),
            LayoutBuilder(
              builder: (context, constraints) {
                final w = constraints.maxWidth;
                final h = 240.0;
                return SizedBox(
                  width: w,
                  height: h,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.file(File(item.imagePath!), fit: BoxFit.contain),
                      for (var i = 0; i < item.occlusionRects.length; i++)
                        if (!revealed && !peekedRects.contains(i))
                          Positioned(
                            left: item.occlusionRects[i].left * w,
                            top: item.occlusionRects[i].top * h,
                            width: item.occlusionRects[i].width * w,
                            height: item.occlusionRects[i].height * h,
                            child: GestureDetector(
                              onTap: () => onPeekRect(i),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: c.primary.withValues(alpha: 0.92),
                                  border: Border.all(
                                    color: c.onPrimary,
                                    width: 1.5,
                                  ),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  '遮挡 ${i + 1}（点击偷看）',
                                  style: context.texts.labelSmall!.copyWith(
                                    color: c.onPrimary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                    ],
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

class _RevealPanel extends StatelessWidget {
  const _RevealPanel({
    required this.item,
    required this.objectiveCheck,
    required this.usedAssistance,
    required this.aiLoading,
    required this.aiSuggestion,
    required this.aiDisputed,
    required this.onAskAi,
    required this.onDisputeAi,
    required this.selectedReason,
    required this.onReasonChanged,
    required this.correctionController,
    required this.correctionFocus,
  });

  final ReviewItem item;
  final LocalRuleCheckResult? objectiveCheck;
  final bool usedAssistance;
  final bool aiLoading;
  final AiReviewSuggestion? aiSuggestion;
  final bool aiDisputed;
  final VoidCallback onAskAi;
  final VoidCallback onDisputeAi;
  final String? selectedReason;
  final ValueChanged<String?> onReasonChanged;
  final TextEditingController correctionController;
  final FocusNode correctionFocus;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      padding: const EdgeInsets.all(Space.xl),
      background: c.surfaceRaised,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              QIcon(QIcons.verify, size: IconSizes.md, color: c.green),
              const SizedBox(width: 8),
              Text('参考答案与核对', style: context.texts.titleSmall),
              const Spacer(),
              TextButton.icon(
                onPressed: aiLoading ? null : onAskAi,
                icon: const QIcon(QIcons.ai, size: IconSizes.sm),
                label: Text(aiLoading ? 'AI 评阅中…' : 'AI 对照评阅'),
              ),
            ],
          ),
          if (usedAssistance) ...[
            const SizedBox(height: Space.sm),
            const AppCallout(
              tone: CalloutTone.info,
              message: '已查看提示或原文，记为“协助完成”（不计入独立掌握）。',
            ),
          ],
          if (objectiveCheck != null &&
              objectiveCheck!.explanation.isNotEmpty) ...[
            const SizedBox(height: Space.sm),
            AppCallout(
              tone: objectiveCheck!.decided
                  ? (objectiveCheck!.isCorrect
                        ? CalloutTone.info
                        : CalloutTone.warning)
                  : CalloutTone.info,
              message: objectiveCheck!.explanation,
            ),
          ],
          const SizedBox(height: Space.md),
          SelectableText(
            item.answer.trim().isEmpty
                ? (item.blankAnswers.isEmpty
                      ? '本题暂无参考答案文本，请对照教材原页核对。'
                      : item.blankAnswers.join(' / '))
                : item.answer,
            style: context.texts.bodyMedium!.copyWith(
              height: 1.65,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (item.steps.isNotEmpty) ...[
            const SizedBox(height: Space.md),
            Text('分步核对要点：', style: context.texts.labelLarge),
            const SizedBox(height: 4),
            for (var i = 0; i < item.steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('${i + 1}. ${item.steps[i]}'),
              ),
          ],
          if (item.explanation.trim().isNotEmpty) ...[
            const SizedBox(height: Space.md),
            Text('解析补充：', style: context.texts.labelLarge),
            const SizedBox(height: 4),
            SelectableText(item.explanation, style: context.texts.bodySmall),
          ],
          if (aiSuggestion != null) ...[
            const SizedBox(height: Space.md),
            Container(
              padding: const EdgeInsets.all(Space.md),
              decoration: BoxDecoration(
                color: c.violetTint,
                borderRadius: BorderRadius.circular(Radii.sm),
                border: Border.all(color: c.outline),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      AppBadge(
                        label: 'AI 建议：${aiSuggestion!.suggestedOutcome.label}',
                        tone: BadgeTone.violet,
                        dense: true,
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: onDisputeAi,
                        child: Text(aiDisputed ? '已标记评语待核对' : '评语有误 / 标记核对'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  SelectableText(aiSuggestion!.rationale),
                  if (aiSuggestion!.missingPoints.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      '建议补足：${aiSuggestion!.missingPoints.join('；')}',
                      style: context.texts.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: Space.md),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('错因与订正笔记（可选）'),
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final r in ReviewErrorReasons.presets)
                    ChoiceChip(
                      label: Text(r),
                      selected: selectedReason == r,
                      onSelected: (v) => onReasonChanged(v ? r : null),
                    ),
                ],
              ),
              const SizedBox(height: Space.sm),
              TextField(
                controller: correctionController,
                focusNode: correctionFocus,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: '订正笔记（记录卡点与切入点）',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GradingBar extends StatelessWidget {
  const _GradingBar({
    required this.item,
    required this.previews,
    required this.onRateFsrs,
    required this.onRateTraining,
  });

  final ReviewItem item;
  final List<ReviewRatingPreview> previews;
  final ValueChanged<ReviewRating> onRateFsrs;
  final ValueChanged<ComplexityOutcome> onRateTraining;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (item.scheduleMode == ReviewScheduleMode.training) {
      return AppCard(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('选择完成情况（训练阶段规则）', style: context.texts.labelLarge),
            const SizedBox(height: Space.sm),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () => onRateTraining(ComplexityOutcome.incomplete),
                  child: const Text('未完成 / 卡住（明日重做）'),
                ),
                OutlinedButton(
                  onPressed: () => onRateTraining(ComplexityOutcome.partial),
                  child: const Text('半对 / 借助提示（明日再练）'),
                ),
                FilledButton(
                  onPressed: () =>
                      onRateTraining(ComplexityOutcome.independentCorrect),
                  child: const Text('独立做对（进入下一跨天阶梯）'),
                ),
                TextButton(
                  onPressed: () => onRateTraining(ComplexityOutcome.disputed),
                  child: const Text('对答案存疑（转入待核对）'),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return AppCard(
      padding: const EdgeInsets.all(Space.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('记忆提取评分（FSRS v5）', style: context.texts.labelLarge),
              const Spacer(),
              Text(
                '快捷键 1 / 2 / 3 / 4',
                style: context.texts.bodySmall!.copyWith(color: c.inkMuted),
              ),
            ],
          ),
          const SizedBox(height: Space.sm),
          LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < 520;
              return GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: narrow ? 2 : 4,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: narrow ? 2.6 : 2.1,
                children: [
                  for (var i = 0; i < previews.length; i++)
                    _FsrsButton(
                      shortcutIndex: i + 1,
                      preview: previews[i],
                      onTap: () => onRateFsrs(previews[i].rating),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _FsrsButton extends StatelessWidget {
  const _FsrsButton({
    required this.shortcutIndex,
    required this.preview,
    required this.onTap,
  });

  final int shortcutIndex;
  final ReviewRatingPreview preview;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tint = switch (preview.rating) {
      ReviewRating.again => c.dangerTint,
      ReviewRating.hard => c.warmTint,
      ReviewRating.good => c.greenTint,
      ReviewRating.easy => c.blueTint,
    };
    final fg = switch (preview.rating) {
      ReviewRating.again => c.danger,
      ReviewRating.hard => c.warm,
      ReviewRating.good => c.green,
      ReviewRating.easy => c.blue,
    };
    return Material(
      color: tint,
      borderRadius: BorderRadius.circular(Radii.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.sm),
            border: Border.all(color: fg.withValues(alpha: 0.35)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '$shortcutIndex · ${preview.rating.label}',
                style: context.texts.labelLarge!.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                preview.intervalLabel,
                style: context.texts.bodySmall!.copyWith(
                  color: c.ink,
                  fontFeatures: AppNumerals.tabular,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SummaryView extends StatelessWidget {
  const _SummaryView({
    required this.study,
    required this.session,
    required this.onFinish,
    required this.onScheduleBatch,
  });

  final StudyController study;
  final ReviewSession? session;
  final VoidCallback onFinish;
  final VoidCallback onScheduleBatch;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final doneCount =
        session?.items.where((e) => e.status == 'done').length ?? 0;
    final activeSeconds = session?.activeSeconds ?? 0;
    final mins = activeSeconds ~/ 60;
    final secs = activeSeconds % 60;

    return Scaffold(
      backgroundColor: c.canvas,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(Space.xl),
            child: AppCard(
              padding: const EdgeInsets.all(Space.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      QIcon(QIcons.done, size: IconSizes.lg, color: c.green),
                      const SizedBox(width: 10),
                      Text('本轮复习完成', style: context.texts.headlineSmall),
                    ],
                  ),
                  const SizedBox(height: Space.md),
                  Text(
                    '共完成 $doneCount 道题目 · 实际专注用时 ${mins > 0 ? '$mins 分 ' : ''}$secs 秒',
                    style: context.texts.bodyMedium,
                  ),
                  const SizedBox(height: Space.sm),
                  Text(
                    '未完成与后续到期卡仍保留在复习队列中。',
                    style: context.texts.bodySmall,
                  ),
                  const SizedBox(height: Space.xl),
                  Wrap(
                    spacing: Space.sm,
                    runSpacing: Space.sm,
                    alignment: WrapAlignment.end,
                    children: [
                      OutlinedButton.icon(
                        onPressed: onScheduleBatch,
                        icon: const QIcon(QIcons.schedule, size: IconSizes.sm),
                        label: const Text('把下次复习批排入日程'),
                      ),
                      FilledButton(
                        onPressed: onFinish,
                        child: const Text('返回复习总览'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
