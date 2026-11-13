import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/local_store.dart';
import '../../services/ai_gateway.dart';
import 'data/planning_repository.dart';
import 'data/schedule_repository.dart';
import 'domain/schedule_validator.dart';
import 'models/calendar_block.dart';
import 'models/catch_up.dart';
import 'models/daily_lesson.dart';
import 'models/knowledge_item.dart';
import 'models/learning_record.dart';
import 'models/local_date.dart';
import 'models/plan_availability.dart';
import 'models/planning_models.dart';
import 'models/schedule_draft.dart';
import 'models/schedule_revision.dart';
import 'models/study_plan.dart';
import 'models/study_task.dart';
import 'services/knowledge_ai_client.dart';
import 'services/lesson_ai_client.dart';
import 'services/material_catalog_service.dart';
import 'services/planning_ai_client.dart';

enum ScheduleViewMode { calendar, path }

enum CalendarDisplayMode { month, list }

enum CalendarLayer { study, review, exam, busy, completed }

extension CalendarLayerLabel on CalendarLayer {
  String get label => switch (this) {
    CalendarLayer.study => '学习安排',
    CalendarLayer.review => '复习安排',
    CalendarLayer.exam => '考试',
    CalendarLayer.busy => '个人占用',
    CalendarLayer.completed => '已完成项目',
  };
}

class DaySummary {
  const DaySummary({
    this.count = 0,
    this.minutes = 0,
    this.completedMinutes = 0,
    this.completedCount = 0,
    this.hasExam = false,
    this.isRest = false,
    this.isOverdue = false,
  });

  final int count;
  final int minutes;
  final int completedMinutes;
  final int completedCount;
  final bool hasExam;
  final bool isRest;
  final bool isOverdue;

  bool get isEmpty => count == 0 && !hasExam && !isRest;
}

/// UI state for the schedule. It owns the month view, the selected date and
/// the plan filter, but every write goes through [ScheduleRepository].
class ScheduleController extends ChangeNotifier {
  ScheduleController(
    this.repository, {
    DateTime Function()? clock,
    this.ai,
    this.settingsProvider,
  }) : _clock = clock ?? DateTime.now,
       planningRepository = PlanningRepository(repository.store) {
    planningClient = ai == null ? null : PlanningAiClient(ai!.transport);
    knowledgeClient = ai == null ? null : KnowledgeAiClient(ai!.transport);
    lessonClient = ai == null ? null : LessonAiClient(ai!.transport);
  }

  final ScheduleRepository repository;
  final PlanningRepository planningRepository;
  final AiGateway? ai;
  final ProviderSettings Function()? settingsProvider;
  late final PlanningAiClient? planningClient;
  late final KnowledgeAiClient? knowledgeClient;
  late final LessonAiClient? lessonClient;
  final DateTime Function() _clock;
  static const String _uiStateKey = 'schedule.ui';

  LocalStore get store => repository.store;

  LocalDate visibleMonth = LocalDate.today().firstOfMonth;
  LocalDate selectedDate = LocalDate.today();
  int monthDirection = 0;
  bool dayPanelOpen = true;
  ScheduleViewMode viewMode = ScheduleViewMode.calendar;
  CalendarDisplayMode calendarMode = CalendarDisplayMode.month;
  final Set<CalendarLayer> hiddenLayers = {};
  String? planFilterId;
  List<StudyPlan> plans = const [];
  List<CalendarBlock> _monthBlocks = const [];
  List<CalendarBlock> _dayBlocks = const [];
  Map<String, StudyTask> _tasks = const {};
  Map<String, StudyPlan> _planById = const {};
  Map<String, PlanAvailability?> _availability = const {};
  int calendarRevision = 0;
  String? error;
  bool loading = false;
  bool _initialized = false;
  bool _disposed = false;
  PlanningConversation? planningConversation;
  List<PlanningMessage> planningMessages = const [];
  bool planningOpen = false;
  bool planningSending = false;
  String? planningError;
  int _planningGeneration = 0;

  DateTime get now => _clock();
  LocalDate get today => LocalDate.today(_clock());

  bool get initialized => _initialized;

  bool get planningEnabled =>
      planningClient != null && settingsProvider != null;

  bool get knowledgeEnabled =>
      knowledgeClient != null && settingsProvider != null;

  ProviderSettings get planningSettings =>
      (settingsProvider ?? ProviderSettings.deepSeek)();

  PreparedKnowledgeRequest prepareKnowledge(
    StudyPlan plan, {
    String focus = '',
  }) {
    final client = knowledgeClient;
    final provider = settingsProvider;
    if (client == null || provider == null) {
      throw const AiFailure(AiError.invalidSettings, '请先在设置中配置文本模型。');
    }
    final extraction = MaterialCatalogService(store).extractPlan(
      plan.id,
      maxChunks: KnowledgeAiClient.maxChunks,
      maxCharsPerChunk: KnowledgeAiClient.maxChunkCharacters,
    );
    if (!extraction.hasReadyText) {
      throw const AiFailure(
        AiError.rejected,
        '没有已解析的材料页；请先在“计划管理 → 材料”补齐页段。',
      );
    }
    return client.prepare(
      settings: provider(),
      plan: plan,
      chunks: extraction.chunks,
      focus: focus,
    );
  }

  Future<List<KnowledgeItem>> sendKnowledge(
    PreparedKnowledgeRequest request,
  ) async {
    final client = knowledgeClient;
    if (client == null) {
      throw const AiFailure(AiError.invalidSettings, '请先在设置中配置文本模型。');
    }
    final result = await client.send(request);
    final saved = repository.saveKnowledgeItems(result.items);
    _notify();
    return saved;
  }

  KnowledgeItem saveKnowledge(KnowledgeItem item) {
    final saved = repository.saveKnowledgeItem(item);
    _notify();
    return saved;
  }

  void deleteKnowledge(String id) {
    repository.deleteKnowledgeItem(id);
    _notify();
  }

  StudyTask generateTaskFromKnowledge(KnowledgeItem item) {
    final task = repository.createTaskFromKnowledge(item);
    refresh();
    return task;
  }

  PreparedLessonRequest prepareLesson(StudyTask task) {
    final client = lessonClient;
    final provider = settingsProvider;
    if (client == null || provider == null) {
      throw const AiFailure(AiError.invalidSettings, '请先在设置中配置文本模型。');
    }
    final material = task.material;
    if (material == null) {
      throw const AiFailure(AiError.rejected, '这个任务还没有绑定教材页段。');
    }
    final plan = task.planId == null ? null : repository.getPlan(task.planId!);
    if (plan == null) {
      throw const AiFailure(AiError.rejected, '任务所属计划已不存在。');
    }
    final document = store.getDocument(material.documentId);
    if (document == null || document.contentHash != material.documentHash) {
      throw const AiFailure(AiError.rejected, '教材已删除或版本已改变。');
    }
    return client.prepare(
      settings: provider(),
      task: task,
      plan: plan,
      material: material,
      pages: store.getPages(material.documentId),
    );
  }

  Future<DailyLesson> sendLesson(
    PreparedLessonRequest request, {
    bool Function()? isCancelled,
  }) async {
    final client = lessonClient;
    if (client == null) {
      throw const AiFailure(AiError.invalidSettings, '请先在设置中配置文本模型。');
    }
    final lesson = await client.send(request);
    if (isCancelled?.call() ?? false) {
      throw const AiFailure(AiError.rejected, '已取消生成，未保存课程。');
    }
    final saved = repository.saveLesson(lesson);
    _notify();
    return saved;
  }

  /// Suggests up to three future free windows inside the plan's weekly rules.
  /// It never changes availability, daily caps or other plans.
  List<CatchUpSuggestion> suggestCatchUp(
    StudyTask task,
    CalendarBlock block, {
    int limit = 3,
  }) {
    final planId = task.planId;
    if (planId == null) return const [];
    final plan = repository.getPlan(planId);
    final availability = repository.getAvailability(planId);
    if (plan == null || availability == null || !availability.isConfigured) {
      return const [];
    }
    final remaining = (block.minutes - block.completedMinutes).clamp(
      5,
      block.minutes,
    );
    final suggestions = <CatchUpSuggestion>[];
    var date = today < plan.startDate ? plan.startDate : today.addDays(1);
    var scanned = 0;
    while (date <= plan.schedulingEnd &&
        scanned < 21 &&
        suggestions.length < limit) {
      scanned++;
      final ranges = availability.rangesFor(date);
      if (ranges.isNotEmpty) {
        final blocks = repository
            .getBlocks(start: date, end: date)
            .where((item) => item.kind == BlockKind.study)
            .toList()
          ..sort((a, b) => a.startMinute.compareTo(b.startMinute));
        for (final range in ranges) {
          var cursor = range.startMinute;
          for (final occupied in blocks) {
            if (occupied.endMinute <= cursor) continue;
            if (occupied.startMinute >= cursor + remaining) break;
            if (occupied.startMinute > cursor &&
                occupied.startMinute - cursor >= remaining) {
              break;
            }
            cursor = occupied.endMinute;
          }
          if (cursor + remaining <= range.endMinute) {
            suggestions.add(
              CatchUpSuggestion(
                date: date,
                startMinute: cursor,
                endMinute: cursor + remaining,
              ),
            );
            if (suggestions.length >= limit) break;
          }
        }
      }
      date = date.addDays(1);
    }
    return suggestions;
  }

  CalendarBlock applyCatchUp(
    StudyTask task,
    CatchUpSuggestion suggestion,
  ) {
    final block = repository.appendCatchUpBlock(
      task: task,
      date: suggestion.date,
      startMinute: suggestion.startMinute,
      endMinute: suggestion.endMinute,
    );
    refresh();
    return block;
  }

  DailyLesson? lessonForTask(String taskId) {    final task = repository.getTask(taskId);
    final lesson = repository.latestLessonForTask(taskId);
    if (task == null || lesson == null) return null;
    final material = task.material;
    if (material == null) return null;
    if (store.getDocument(material.documentId) == null) return null;
    if (lesson.materialDocumentId != material.documentId ||
        lesson.materialHash != material.documentHash ||
        lesson.startPage != material.startPage ||
        lesson.endPage != material.endPage) {
      return null;
    }
    return lesson;
  }

  StudyPlan? get selectedPlan =>
      planFilterId == null ? null : _planById[planFilterId];

  String get planningScopeLabel {
    final plan = planningConversation?.planId == null
        ? null
        : _planById[planningConversation!.planId!];
    return plan == null ? '新计划' : plan.title;
  }

  List<StudyPlan> get activePlans => plans
      .where((plan) => plan.status != PlanStatus.archived)
      .toList(growable: false);

  List<CalendarBlock> get monthBlocks {
    final filtered = planFilterId == null
        ? _monthBlocks
        : _monthBlocks
              .where(
                (block) =>
                    block.planId == planFilterId ||
                    block.kind == BlockKind.busy,
              )
              .toList();
    return filtered;
  }

  List<CalendarBlock> get dayBlocks {
    final filtered = planFilterId == null
        ? _dayBlocks
        : _dayBlocks
              .where(
                (block) =>
                    block.planId == planFilterId ||
                    block.kind == BlockKind.busy,
              )
              .toList();
    return [...filtered.where(isBlockVisible)]..sort((a, b) {
      final start = a.startMinute.compareTo(b.startMinute);
      return start != 0 ? start : a.id.compareTo(b.id);
    });
  }

  StudyTask? taskFor(CalendarBlock block) =>
      block.taskId == null ? null : _tasks[block.taskId];

  StudyPlan? planFor(CalendarBlock block) =>
      block.planId == null ? null : _planById[block.planId];

  StudyPlan? planById(String? id) => id == null ? null : _planById[id];

  PlanAvailability? availabilityFor(String planId) => _availability[planId];

  void initialize() {
    if (_initialized) return;
    _initialized = true;
    final raw = store.getSetting(_uiStateKey);
    if (raw != null) {
      try {
        final data = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        final month = LocalDate.tryParse(data['month'] as String? ?? '');
        final selected = LocalDate.tryParse(data['selected'] as String? ?? '');
        if (month != null) visibleMonth = month.firstOfMonth;
        if (selected != null) selectedDate = selected;
        final filter = data['planFilter'] as String?;
        if (filter != null) planFilterId = filter;
        final view = data['view'] as String?;
        if (view == ScheduleViewMode.path.name) {
          viewMode = ScheduleViewMode.path;
        }
        final mode = data['calendarMode'] as String?;
        if (mode == CalendarDisplayMode.list.name) {
          calendarMode = CalendarDisplayMode.list;
        }
        final layers = data['hiddenLayers'];
        if (layers is List) {
          for (final value in layers.whereType<String>()) {
            for (final layer in CalendarLayer.values) {
              if (layer.name == value) hiddenLayers.add(layer);
            }
          }
        }
      } catch (_) {
        // A damaged preference must not block the schedule.
      }
    }
    refresh();
  }

  void refresh() {
    if (_disposed) return;
    loading = true;
    error = null;
    try {
      plans = repository.getPlans();
      _planById = {for (final plan in plans) plan.id: plan};
      final filteredPlan = planFilterId == null ? null : _planById[planFilterId];
      if (planFilterId != null &&
          (filteredPlan == null || filteredPlan.isArchived)) {
        planFilterId = null;
      }
      _availability = {
        for (final plan in plans) plan.id: repository.getAvailability(plan.id),
      };
      final gridStart = visibleMonth.gridStart;
      final gridEnd = visibleMonth.gridEnd;
      _monthBlocks = repository.getBlocks(start: gridStart, end: gridEnd);
      _dayBlocks = repository.getBlocks(
        start: selectedDate,
        end: selectedDate,
      );
      _tasks = {
        for (final task in repository.getTasks()) task.id: task,
      };
      calendarRevision = repository.calendarRevision;
    } catch (exception) {
      error = '日程读取失败：$exception';
    } finally {
      loading = false;
      _notify();
    }
  }

  DaySummary summaryFor(LocalDate date) {
    final blocks = _monthBlocks.where(
      (block) =>
          block.date == date &&
          (planFilterId == null || block.planId == planFilterId) &&
          isBlockVisible(block),
    );
    var count = 0;
    var minutes = 0;
    var completedMinutes = 0;
    var completedCount = 0;
    var overdue = false;
    for (final block in blocks) {
      if (!block.isStudy) continue;
      count++;
      minutes += block.minutes;
      completedMinutes += block.completedMinutes;
      if (block.state == BlockState.completed) completedCount++;
      if (block.isOverdue(now)) overdue = true;
    }
    return DaySummary(
      count: count,
      minutes: minutes,
      completedMinutes: completedMinutes,
      completedCount: completedCount,
      hasExam:
          isLayerVisible(CalendarLayer.exam) &&
          examPlansFor(date).isNotEmpty,
      isRest: isRestDay(date),
      isOverdue: overdue,
    );
  }

  List<StudyPlan> examPlansFor(LocalDate date) => plans
      .where(
        (plan) =>
            plan.examDate == date &&
            plan.status != PlanStatus.archived &&
            (planFilterId == null || plan.id == planFilterId),
      )
      .toList();

  /// The nearest exam on or after [date], used by the day panel to show the
  /// countdown even when the selected day is not the exam day.
  StudyPlan? nextExamOnOrAfter(LocalDate date) {
    StudyPlan? best;
    for (final plan in plans) {
      final exam = plan.examDate;
      if (exam == null ||
          plan.status == PlanStatus.archived ||
          (planFilterId != null && plan.id != planFilterId) ||
          exam < date) {
        continue;
      }
      if (best == null || exam < best.examDate!) best = plan;
    }
    return best;
  }

  bool isRestDay(LocalDate date) {
    for (final plan in plans) {
      if (planFilterId != null && plan.id != planFilterId) continue;
      final availability = _availability[plan.id];
      final exception = availability?.exceptionFor(date);
      if (exception != null && exception.isRestDay) return true;
    }
    return false;
  }

  List<CalendarBlock> blocksFor(LocalDate date) => monthBlocks
      .where((block) => block.date == date)
      .toList()
    ..sort((a, b) => a.startMinute.compareTo(b.startMinute));

  void selectDate(LocalDate date) {
    final oldMonth = visibleMonth;
    selectedDate = date;
    dayPanelOpen = true;
    if (date.year != visibleMonth.year || date.month != visibleMonth.month) {
      monthDirection = date > oldMonth ? 1 : -1;
      visibleMonth = date.firstOfMonth;
    } else {
      monthDirection = 0;
    }
    _saveUiState();
    refresh();
  }

  void selectMonth(LocalDate month) {
    final target = month.firstOfMonth;
    monthDirection = target.compareTo(visibleMonth);
    visibleMonth = target;
    final current = today;
    selectedDate =
        current.year == target.year && current.month == target.month
        ? current
        : LocalDate(target.year, target.month, 1);
    _saveUiState();
    refresh();
  }

  void toggleDayPanel() {
    dayPanelOpen = !dayPanelOpen;
    _notify();
  }

  void shiftMonth(int delta) {
    final target = LocalDate(
      visibleMonth.year,
      visibleMonth.month,
      delta > 0 ? visibleMonth.daysInMonth : 1,
    ).addDays(delta > 0 ? 1 : -1);
    final month = target.firstOfMonth;
    final day = selectedDate.day > month.daysInMonth
        ? month.daysInMonth
        : selectedDate.day;
    visibleMonth = month;
    selectedDate = LocalDate(month.year, month.month, day);
    monthDirection = delta.sign;
    _saveUiState();
    refresh();
  }

  void shiftDay(int delta) => selectDate(selectedDate.addDays(delta));

  LocalDate? nextUpcomingBlockDate(LocalDate date) {
    final blocks = repository.getBlocks(start: date, end: date.addDays(365));
    LocalDate? best;
    for (final block in blocks) {
      if (!isBlockVisible(block) ||
          block.kind != BlockKind.study ||
          (block.state != BlockState.scheduled &&
              block.state != BlockState.inProgress)) {
        continue;
      }
      if (best == null || block.date < best) {
        best = block.date;
      }
    }
    return best;
  }

  void goToday() {
    final current = today;
    monthDirection = current.firstOfMonth.compareTo(visibleMonth);
    selectedDate = current;
    visibleMonth = current.firstOfMonth;
    _saveUiState();
    refresh();
  }

  void selectPlan(String? planId) {
    planFilterId = planId;
    _saveUiState();
    refresh();
  }

  void setViewMode(ScheduleViewMode value) {
    if (viewMode == value) return;
    viewMode = value;
    _saveUiState();
    _notify();
  }

  void setCalendarMode(CalendarDisplayMode value) {
    if (calendarMode == value) return;
    calendarMode = value;
    _saveUiState();
    _notify();
  }

  void toggleLayer(CalendarLayer layer) {
    if (!hiddenLayers.add(layer)) hiddenLayers.remove(layer);
    _saveUiState();
    _notify();
  }

  bool isLayerVisible(CalendarLayer layer) => !hiddenLayers.contains(layer);

  bool isBlockVisible(CalendarBlock block) {
    if (block.kind == BlockKind.busy) {
      return isLayerVisible(CalendarLayer.busy);
    }
    if (block.state == BlockState.completed &&
        !isLayerVisible(CalendarLayer.completed)) {
      return false;
    }
    final activity = taskFor(block)?.activity;
    if (activity == TaskActivity.review &&
        !isLayerVisible(CalendarLayer.review)) {
      return false;
    }
    return isLayerVisible(CalendarLayer.study) ||
        activity == TaskActivity.review;
  }

  void _saveUiState() {
    if (_disposed) return;
    try {
      store.setSetting(
        _uiStateKey,
        jsonEncode({
          'month': visibleMonth.iso,
          'selected': selectedDate.iso,
          'planFilter': planFilterId,
          'view': viewMode.name,
          'calendarMode': calendarMode.name,
          'hiddenLayers': [for (final layer in hiddenLayers) layer.name],
        }),
      );
    } catch (_) {
      // Preferences are not worth failing a schedule action over.
    }
  }

  StudyPlan savePlan(StudyPlan plan) {
    final saved = repository.savePlan(plan);
    refresh();
    return saved;
  }

  void deletePlan(String id) {
    repository.deletePlan(id);
    if (planFilterId == id) planFilterId = null;
    refresh();
  }

  StudyPlan archivePlan(StudyPlan plan) =>
      savePlan(plan.copyWith(status: PlanStatus.archived));

  PlanAvailability saveAvailability(PlanAvailability value) {
    final saved = repository.saveAvailability(value);
    refresh();
    return saved;
  }

  void setRestDay(LocalDate date, {required bool rest}) {
    final plan = selectedPlan;
    if (plan == null) {
      throw ScheduleValidationException('请先在顶部选择一个计划，再设置单日休息。');
    }
    final current =
        availabilityFor(plan.id) ?? PlanAvailability.suggestion(plan.id);
    final exceptions = current.exceptions
        .where((exception) => exception.date != date)
        .toList();
    if (rest) {
      exceptions.add(AvailabilityException(date: date, available: false));
    }
    saveAvailability(current.copyWith(exceptions: exceptions));
  }

  ScheduleSaveResult createManual({
    required StudyTask task,
    required CalendarBlock block,
    bool repeat = false,
    List<int> weekdays = const [],
    LocalDate? repeatEnd,
  }) {
    final result = repository.createManual(
      task: task,
      block: block,
      repeat: repeat,
      weekdays: weekdays,
      repeatEnd: repeatEnd,
    );
    refresh();
    return result;
  }

  ScheduleSaveResult updateManual({
    required StudyTask task,
    required CalendarBlock block,
    RepeatEditScope scope = RepeatEditScope.thisOnly,
    List<int>? weekdays,
    LocalDate? repeatEnd,
  }) {
    final result = repository.updateManual(
      task: task,
      block: block,
      scope: scope,
      weekdays: weekdays,
      repeatEnd: repeatEnd,
    );
    refresh();
    return result;
  }

  void deleteOccurrence(CalendarBlock block, {bool thisAndFuture = false}) {
    repository.deleteOccurrence(block, thisAndFuture: thisAndFuture);
    refresh();
  }

  List<CalendarBlock> createBusy({
    required CalendarBlock template,
    bool repeat = false,
    List<int> weekdays = const [],
    LocalDate? repeatEnd,
  }) {
    final result = repository.createBusy(
      template: template,
      repeat: repeat,
      weekdays: weekdays,
      repeatEnd: repeatEnd,
    );
    refresh();
    return result;
  }

  CalendarBlock updateBusy(
    CalendarBlock block, {
    RepeatEditScope scope = RepeatEditScope.thisOnly,
    List<int>? weekdays,
    LocalDate? repeatEnd,
  }) {
    final result = repository.updateBusy(
      block,
      scope: scope,
      weekdays: weekdays,
      repeatEnd: repeatEnd,
    );
    refresh();
    return result;
  }

  CalendarBlock markBlock({
    required CalendarBlock block,
    required LearningFact fact,
    int? completedMinutes,
    String note = '',
    String? operationId,
  }) {
    final result = repository.markBlock(
      block: block,
      fact: fact,
      completedMinutes: completedMinutes,
      note: note,
      operationId: operationId,
    );
    refresh();
    return result;
  }

  CalendarBlock setBlockLocked(CalendarBlock block, {required bool locked}) {
    final result = repository.setBlockLocked(block, locked: locked);
    refresh();
    return result;
  }

  StudyTask saveTask(StudyTask task) {
    final result = repository.saveTask(task);
    refresh();
    return result;
  }

  void deleteTask(String id) {
    repository.deleteTask(id);
    refresh();
  }

  ScheduleDraft buildDraft(String planId) => repository.buildDraft(planId);

  ScheduleRevision applyDraft(ScheduleDraft draft) {
    final result = repository.applyDraft(draft);
    refresh();
    return result;
  }

  ScheduleRevision? get latestUndoableRevision =>
      repository.latestUndoableRevision();

  bool get canUndoLatest => repository.canUndoLatest;

  ScheduleRevision undoLast() {
    final revision = repository.latestUndoableRevision();
    if (revision == null) {
      throw ScheduleValidationException('没有可撤销的排期。');
    }
    final result = repository.undoRevision(revision.id);
    refresh();
    return result;
  }

  List<LearningRecord> recordsFor(CalendarBlock block) =>
      repository.getLearningRecords(blockId: block.id);

  // ---------------------------------------------------------------------------
  // Planning conversation
  // ---------------------------------------------------------------------------

  void openPlanning({String? planId, bool forceNew = false}) {
    final requested = planId ?? planFilterId;
    final scope =
        requested != null && repository.getPlan(requested) != null
        ? requested
        : null;
    final conversation = forceNew
        ? planningRepository.createConversation(planId: scope)
        : planningRepository.getOrCreate(planId: scope);
    planningConversation = conversation;
    planningMessages = planningRepository.messages(conversation.id);
    planningError = null;
    _notify();
  }

  void startNewPlanningConversation() => openPlanning(forceNew: true);

  void openPlanningPanel({String? planId}) {
    openPlanning(planId: planId);
    planningOpen = true;
    _notify();
  }

  void closePlanningPanel() {
    if (!planningOpen) return;
    planningOpen = false;
    _notify();
  }

  PreparedPlanningRequest preparePlanning(String text) {
    if (planningConversation == null) openPlanning();
    final client = planningClient;
    if (client == null) {
      throw ScheduleValidationException('当前构建没有接入 AI 排期服务。');
    }
    final conversation = planningConversation!;
    final context = _planningContext(conversation, planningMessages);
    return client.prepare(
      settings: planningSettings,
      message: text,
      context: context,
      conversationId: conversation.id,
    );
  }

  PlanningContext _planningContext(
    PlanningConversation conversation,
    List<PlanningMessage> history,
  ) {
    final plan = conversation.planId == null
        ? null
        : _planById[conversation.planId!];
    return PlanningContext(
      today: today,
      timezone: plan?.timezone ?? 'Asia/Shanghai',
      plans: plans,
      selectedPlan: plan,
      selectedAvailability: plan == null ? null : _availability[plan.id],
      history: history,
    );
  }

  Future<void> sendPreparedPlanning(PreparedPlanningRequest request) async {
    if (planningSending) return;
    final conversation = planningConversation;
    if (conversation == null || conversation.id != request.conversationId) {
      throw ScheduleValidationException('对话已切换，请重新预览这次请求。');
    }
    final client = planningClient;
    if (client == null) {
      throw ScheduleValidationException('当前构建没有接入 AI 排期服务。');
    }
    final generation = ++_planningGeneration;
    planningSending = true;
    planningError = null;
    _notify();
    try {
      final userMessage = planningRepository.appendMessage(
        conversationId: conversation.id,
        role: PlanningRole.user,
        kind: PlanningKind.text,
        text: request.message,
        requestId: request.requestId,
        model: request.model,
      );
      planningMessages = [...planningMessages, userMessage];
      _notify();
      final result = await client.send(request);
      if (_disposed || generation != _planningGeneration) return;
      final assistant = planningRepository.appendMessage(
        conversationId: conversation.id,
        role: PlanningRole.assistant,
        kind: result.reply.kind,
        text: result.reply.message,
        requestId: result.requestId,
        proposal: result.reply.proposal,
        questions: result.reply.questions,
        missingMaterial: result.reply.missingMaterial,
        model: result.model,
        usage: result.usage,
      );
      planningMessages = [...planningMessages, assistant];
      planningError = result.reply.kind == PlanningKind.insufficientMaterial
          ? result.reply.message
          : null;
      _notify();
    } on AiFailure catch (error) {
      if (_disposed || generation != _planningGeneration) return;
      planningError = error.message;
      final assistant = planningRepository.appendMessage(
        conversationId: conversation.id,
        role: PlanningRole.assistant,
        kind: PlanningKind.error,
        text: error.message,
        requestId: request.requestId,
        model: request.model,
        failed: true,
      );
      planningMessages = [...planningMessages, assistant];
      _notify();
    } catch (error) {
      if (_disposed || generation != _planningGeneration) return;
      planningError = '排期请求未完成，请检查网络和服务商设置。';
      final assistant = planningRepository.appendMessage(
        conversationId: conversation.id,
        role: PlanningRole.assistant,
        kind: PlanningKind.error,
        text: planningError!,
        requestId: request.requestId,
        model: request.model,
        failed: true,
      );
      planningMessages = [...planningMessages, assistant];
      _notify();
    } finally {
      if (!_disposed && generation == _planningGeneration) {
        planningSending = false;
        _notify();
      }
    }
  }

  void cancelPlanningSend() {
    if (!planningSending) return;
    _planningGeneration++;
    planningSending = false;
    planningError = '已取消这次请求。';
    final conversation = planningConversation;
    if (conversation != null) {
      final message = planningRepository.appendMessage(
        conversationId: conversation.id,
        role: PlanningRole.assistant,
        kind: PlanningKind.cancelled,
        text: '已取消这次请求。即使服务商稍后返回，也不会写入对话或修改计划。',
      );
      planningMessages = [...planningMessages, message];
    }
    _notify();
  }

  void clearPlanningError() {
    if (planningError == null) return;
    planningError = null;
    _notify();
  }

  StudyPlan applyPlanningProposal(PlanningMessage message) {
    final proposal = message.proposal;
    if (proposal == null) {
      throw ScheduleValidationException('这条消息没有可应用的设置草案。');
    }
    if (message.applied) {
      throw ScheduleValidationException('这次草案已经应用。');
    }
    final existing = proposal.planId == null
        ? null
        : repository.getPlan(proposal.planId!);
    if (proposal.planId != null && existing == null) {
      throw ScheduleValidationException('草案引用的计划已删除。');
    }
    final StudyPlan plan;
    if (existing == null) {
      if (proposal.title == null ||
          proposal.startDate == null ||
          proposal.endDate == null) {
        throw ScheduleValidationException('新计划草案缺少名称或起止日期。');
      }
      plan = StudyPlan(
        id: ScheduleRepository.uuid.v4(),
        title: proposal.title!,
        subject: proposal.subject ?? '',
        startDate: proposal.startDate!,
        endDate: proposal.endDate!,
        examDate: proposal.examDate,
        mode: proposal.mode ?? StudyMode.unknown,
        goal: proposal.goal ?? '',
        status: PlanStatus.active,
      );
    } else {
      plan = existing.copyWith(
        title: proposal.title ?? existing.title,
        subject: proposal.subject ?? existing.subject,
        goal: proposal.goal ?? existing.goal,
        startDate: proposal.startDate ?? existing.startDate,
        endDate: proposal.endDate ?? existing.endDate,
        examDate: proposal.examDate ?? existing.examDate,
        mode: proposal.mode ?? existing.mode,
      );
    }
    final availability = proposal.availability?.copyWith(planId: plan.id);
    final result = repository.applyPlanningSetup(
      plan: plan,
      availability: availability,
      conversationId: message.conversationId,
    );
    planningRepository.markApplied(message.id);
    planningMessages = [
      for (final item in planningMessages)
        item.id == message.id ? item.copyWith(applied: true) : item,
    ];
    planFilterId = result.plan.id;
    planningConversation = planningConversation?.copyWith(
      planId: result.plan.id,
    );
    planningError = null;
    refresh();
    return result.plan;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _planningGeneration++;
    super.dispose();
  }
}

/// Compatibility re-export so callers do not need a second import for the
/// repository exception type when showing an error in the UI.
typedef ScheduleError = ScheduleValidationException;
