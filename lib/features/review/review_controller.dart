import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../schedule/models/local_date.dart';
import 'data/review_repository.dart';
import 'models/review_models.dart';
import 'services/review_ai_service.dart';
import 'services/study_time.dart';

enum ReviewTab { today, mistakes, checks, all, stats }

/// Stateful coordinator for the review dashboard, paginated queues, candidate
/// triage, feedback checks, active review sessions, and undoable grading.
class ReviewController extends ChangeNotifier {
  ReviewController({
    required this.repository,
    this.aiService,
  });

  final ReviewRepository repository;
  final ReviewAiService? aiService;
  static const _uuid = Uuid();

  ReviewTab tab = ReviewTab.today;
  ReviewScopeFilter scope = const ReviewScopeFilter();
  late int budgetMinutes = repository.getDefaultBudgetMinutes();
  String? notice;
  String? error;

  ReviewDashboardSummary? _summary;
  List<ReviewQueueEntry> _todayQueue = const [];
  List<ReviewQueueEntry> _mistakes = const [];
  List<ReviewQueueEntry> _allItems = const [];
  List<ReviewCandidate> _candidates = const [];
  List<ReviewCheck> _checks = const [];
  List<ReviewAttempt> _history = const [];
  ReviewStatsSummary? _stats;
  List<ExamPrepSummary> _examSummaries = const [];
  bool _trashedView = false;

  ReviewSession? _activeSession;
  String? _lastGradedItemId;
  String? _lastOperationId;
  int? _currentActiveSecondsStartedAtMs;
  int _accumulatedActiveSeconds = 0;

  ReviewDashboardSummary get summary => _summary ?? repository.buildDashboardSummary(
    scope: scope,
    budgetMinutes: budgetMinutes,
  );
  List<ReviewQueueEntry> get todayQueue => _todayQueue;
  List<ReviewQueueEntry> get mistakes => _mistakes;
  List<ReviewQueueEntry> get allItems => _allItems;
  List<ReviewCandidate> get candidates => _candidates;
  List<ReviewCheck> get checks => _checks;
  List<ReviewAttempt> get history => _history;
  ReviewStatsSummary get stats => _stats ?? repository.computeStats();
  List<ExamPrepSummary> get examSummaries => _examSummaries;
  bool get trashedView => _trashedView;
  ReviewSession? get activeSession => _activeSession;
  bool get canUndoLastGrade => _lastGradedItemId != null;

  void refresh() {
    _summary = repository.buildDashboardSummary(
      scope: scope,
      budgetMinutes: budgetMinutes,
    );
    _todayQueue = repository.buildTodayQueue(
      scope: scope,
      budgetMinutes: budgetMinutes,
    );
    _mistakes = repository.queryItems(
      scope: ReviewScopeFilter(
        documentId: scope.documentId,
        planId: scope.planId,
        tagId: scope.tagId,
        query: scope.query,
        kind: scope.kind,
        mistakesOnly: true,
      ),
      limit: 100,
    );
    _allItems = repository.queryItems(
      scope: scope,
      lifecycle: _trashedView ? ReviewItemLifecycle.trashed : null,
      limit: 100,
    );
    _candidates = repository.getCandidates(
      status: ReviewCandidateStatus.pending,
      limit: 100,
    );
    _checks = repository.getChecks(status: ReviewCheckStatus.open, limit: 100);
    _history = repository.queryAttemptHistory(limit: 100);
    _stats = repository.computeStats(windowDays: 30);
    _examSummaries = repository.computeExamSummaries(
      dailyBudgetMinutes: budgetMinutes,
    );
    _activeSession = repository.getActiveSession();
    notifyListeners();
  }

  void setTab(ReviewTab value) {
    if (tab == value) return;
    tab = value;
    refresh();
  }

  void setTrashedView(bool value) {
    if (_trashedView == value) return;
    _trashedView = value;
    refresh();
  }

  void setScope(ReviewScopeFilter next) {
    scope = next;
    refresh();
  }

  void setBudgetMinutes(int minutes) {
    budgetMinutes = minutes.clamp(5, 240);
    repository.setDefaultBudgetMinutes(budgetMinutes);
    refresh();
  }

  void clearMessages() {
    notice = null;
    error = null;
    notifyListeners();
  }

  ReviewItem createManualItem({
    ReviewItemKind kind = ReviewItemKind.concept,
    String objective = '',
    required String prompt,
    String answer = '',
    String hint = '',
    String explanation = '',
    List<String> steps = const [],
    List<String> blankAnswers = const [],
    List<String> choices = const [],
    int? correctChoiceIndex,
    String? imagePath,
    List<ReviewOcclusionRect> occlusionRects = const [],
    ReviewOrigin? origin,
    List<String> planIds = const [],
  }) {
    final item = repository.createItem(
      kind: kind,
      objective: objective,
      prompt: prompt,
      answer: answer,
      hint: hint,
      explanation: explanation,
      steps: steps,
      blankAnswers: blankAnswers,
      choices: choices,
      correctChoiceIndex: correctChoiceIndex,
      imagePath: imagePath,
      occlusionRects: occlusionRects,
      origin: origin,
      planIds: planIds,
    );
    notice = '已加入复习：${item.objective.isEmpty ? '新题目' : item.objective}';
    refresh();
    return item;
  }

  void acceptCandidate(String candidateId) {
    final item = repository.acceptCandidate(candidateId);
    notice = '已将候选加入正式复习：${item.objective.isEmpty ? '复习题' : item.objective}';
    refresh();
  }

  void ignoreCandidate(String candidateId) {
    repository.ignoreCandidate(candidateId);
    notice = '已忽略该候选。';
    refresh();
  }

  void resolveCheck(
    String checkId, {
    ReviewCheckStatus status = ReviewCheckStatus.resolved,
    String resolutionNote = '',
    String? updatedAnswer,
  }) {
    repository.resolveCheck(
      checkId,
      status: status,
      resolutionNote: resolutionNote,
      updatedItemAnswer: updatedAnswer,
    );
    notice = status == ReviewCheckStatus.dismissed ? '已驳回此核对。' : '已完成核对并记录结论。';
    refresh();
  }

  void pauseOrResumeItem(ReviewItem item) {
    final next = item.isPaused
        ? ReviewItemLifecycle.active
        : ReviewItemLifecycle.paused;
    repository.setLifecycle([item.id], next);
    notice = item.isPaused ? '已恢复复习安排。' : '已暂停此题，恢复前不再自动入队。';
    refresh();
  }

  void trashItem(String itemId) {
    repository.setLifecycle([itemId], ReviewItemLifecycle.trashed);
    notice = '已移入回收站，可在回收视图恢复。';
    refresh();
  }

  void restoreItem(String itemId) {
    repository.setLifecycle([itemId], ReviewItemLifecycle.active);
    notice = '已从回收站恢复。';
    refresh();
  }

  List<String> purgeItem(String itemId) {
    final paths = repository.purgeItems([itemId]);
    notice = '已永久清除此复习项。';
    refresh();
    return paths;
  }

  void deferItemOneDay(String itemId) {
    final tomorrow = StudyTimeHelper.studyDayStartUtc(
      StudyTimeHelper.studyDate(
        DateTime.now().toUtc(),
        timezone: repository.getStudyTimezone(),
      ).addDays(1),
      timezone: repository.getStudyTimezone(),
    );
    repository.deferItemUntil(itemId, tomorrow);
    notice = '已设为明日再看。';
    refresh();
  }

  // ---------------------------------------------------------------------------
  // Active Session Lifecycle & Active Timer
  // ---------------------------------------------------------------------------

  ReviewSession startOrResumeSession({
    ReviewSessionMode mode = ReviewSessionMode.formal,
    List<String>? explicitItemIds,
  }) {
    final existing = repository.getActiveSession();
    if (existing != null &&
        existing.mode == mode &&
        explicitItemIds == null &&
        existing.items.any((i) => i.status == 'pending')) {
      repository.updateSessionProgress(
        existing.id,
        sessionStatus: ReviewSessionStatus.active,
      );
      _activeSession = repository.getSession(existing.id);
    } else {
      _activeSession = repository.startSession(
        mode: mode,
        scope: scope,
        budgetMinutes: budgetMinutes,
        explicitItemIds: explicitItemIds,
      );
    }
    beginActiveItemTimer();
    notifyListeners();
    return _activeSession!;
  }

  void beginActiveItemTimer() {
    _accumulatedActiveSeconds = 0;
    _currentActiveSecondsStartedAtMs = DateTime.now().millisecondsSinceEpoch;
  }

  void pauseActiveItemTimer() {
    final start = _currentActiveSecondsStartedAtMs;
    if (start != null) {
      final elapsed =
          ((DateTime.now().millisecondsSinceEpoch - start) / 1000).round();
      if (elapsed > 0) _accumulatedActiveSeconds += elapsed;
      _currentActiveSecondsStartedAtMs = null;
    }
  }

  int takeActiveItemSeconds() {
    pauseActiveItemTimer();
    final total = _accumulatedActiveSeconds;
    _accumulatedActiveSeconds = 0;
    // Cap runaway background drift if window was left idle without pausing.
    return total.clamp(0, 3600);
  }

  void pauseCurrentSession() {
    final session = _activeSession;
    if (session == null) return;
    final secs = takeActiveItemSeconds();
    repository.updateSessionProgress(
      session.id,
      activeSecondsDelta: secs,
      sessionStatus: ReviewSessionStatus.paused,
    );
    refresh();
  }

  void saveCurrentDraft({
    required int position,
    String? draftAnswer,
    String? draftNotes,
    bool? usedHint,
    bool? viewedSource,
  }) {
    final session = _activeSession;
    if (session == null) return;
    repository.updateSessionProgress(
      session.id,
      position: position,
      draftAnswer: draftAnswer,
      draftNotes: draftNotes,
      usedHint: usedHint,
      viewedSource: viewedSource,
    );
    _activeSession = repository.getSession(session.id);
    notifyListeners();
  }

  void skipCurrentItem(int position) {
    final session = _activeSession;
    if (session == null) return;
    takeActiveItemSeconds();
    repository.skipOrAdvanceSessionItem(session.id, position);
    beginActiveItemTimer();
    refresh();
  }

  List<ReviewRatingPreview> previewRatingsFor(ReviewItem item) {
    final schedule =
        repository.getSchedule(item.id) ??
        ReviewScheduleState(itemId: item.id, mode: item.scheduleMode);
    return repository.fsrs.previewAll(schedule, nowUtc: DateTime.now().toUtc());
  }

  SubmitGradeResult? submitGrade({
    required ReviewItem item,
    required int sessionPosition,
    String answerText = '',
    bool usedHint = false,
    bool viewedSource = false,
    ReviewRating? rating,
    ComplexityOutcome? complexityOutcome,
    AiReviewSuggestion? aiSuggestion,
    bool aiDisputed = false,
    ReviewResultSource resultSource = ReviewResultSource.self,
    String? errorReason,
    String? correctionNote,
    String? operationId,
  }) {
    final session = _activeSession;
    final opId = operationId ?? _uuid.v4();
    if (opId == _lastOperationId) return null;
    final activeSeconds = takeActiveItemSeconds();
    try {
      final result = repository.submitAttemptAndGrade(
        itemId: item.id,
        operationId: opId,
        expectedItemRevision: item.revision,
        sessionId: session?.id,
        sessionPosition: sessionPosition,
        mode: session?.mode == ReviewSessionMode.free ? 'free' : 'formal',
        answerText: answerText,
        usedHint: usedHint,
        viewedSource: viewedSource,
        selfEval: resultSource == ReviewResultSource.self,
        rating: rating,
        complexityOutcome: complexityOutcome,
        aiSuggestion: aiSuggestion,
        aiDisputed: aiDisputed,
        resultSource: resultSource,
        activeSeconds: activeSeconds,
        errorReason: errorReason,
        correctionNote: correctionNote,
      );
      _lastOperationId = opId;
      _lastGradedItemId = result.event != null ? item.id : null;
      notice = result.guidance;
      error = null;
      beginActiveItemTimer();
      refresh();
      return result;
    } on ReviewStaleVersionException catch (e) {
      error = e.message;
      notifyListeners();
      return null;
    }
  }

  void undoLastGrade() {
    final itemId = _lastGradedItemId;
    if (itemId == null) return;
    repository.undoLastGrade(itemId, sessionId: _activeSession?.id);
    _lastGradedItemId = null;
    _lastOperationId = null;
    notice = '已撤销上一条评分并恢复原有复习安排。';
    beginActiveItemTimer();
    refresh();
  }

  ScheduleBatchResult? scheduleBatchToCalendar({
    required String planId,
    required LocalDate date,
    int startMinute = 19 * 60,
  }) {
    final res = repository.scheduleReviewBatchToCalendar(
      planId: planId,
      date: date,
      startMinute: startMinute,
      budgetMinutes: budgetMinutes,
      sessionId: _activeSession?.id,
    );
    notice = res.duplicateReused
        ? '今日该复习批次已在日程中。'
        : '已将 $budgetMinutes 分钟复习排入日程（不改单卡到期日）。';
    refresh();
    return res;
  }
}
