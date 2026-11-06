import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../core/models.dart';
import '../services/ai_gateway.dart';
import 'dialogs/app_dialogs.dart';
import 'shell/app_chrome.dart';
import 'theme/tokens.dart';
import 'widgets/app_surfaces.dart';

/// Shared learning workspace: beside a desktop page or inside a phone sheet.
class LearningPanel extends StatefulWidget {
  const LearningPanel({
    super.key,
    required this.controller,
    required this.onRequest,
    required this.onNote,
    required this.onJump,
    this.onExpanded,
    this.trailing,
    this.tabController,
    this.showHeader = true,
  });

  final StudyController controller;
  final Future<void> Function(AiTask, String, bool) onRequest;
  final Future<void> Function() onNote;
  final Future<void> Function(Evidence) onJump;
  final Widget? trailing;

  /// Shared with the reader's left dock so both surfaces stay in sync.
  final TabController? tabController;

  /// Hidden inside the medium drawer / phone sheet, which already have a title.
  final bool showHeader;

  /// Called when the panel wants more room (e.g. opening the phone sheet).
  final VoidCallback? onExpanded;

  @override
  State<LearningPanel> createState() => _LearningPanelState();
}

class _LearningPanelState extends State<LearningPanel>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  late final bool _ownsTabs;
  final _question = TextEditingController();
  final _term = TextEditingController();
  final _practiceQuestion = TextEditingController();
  final _answer = TextEditingController();
  final _noteSearch = TextEditingController();
  final _noteSearchFocus = FocusNode();

  final _readKey = GlobalKey();
  final _recallKey = GlobalKey();
  final _feedbackKey = GlobalKey();

  String? _documentId;
  String? _sessionId;
  String _savedQuestion = '';
  String _savedAnswer = '';
  bool _useRange = false;
  bool _previewing = false;
  bool _editingQuestion = false;
  Timer? _answerSaveTimer;
  String _noteQuery = '';

  StudyController get c => widget.controller;
  bool get _blocked => c.sending || c.loading || _previewing;

  @override
  void initState() {
    super.initState();
    _ownsTabs = widget.tabController == null;
    _tabs = widget.tabController ?? TabController(length: 3, vsync: this);
    _tabs.addListener(_onTabChanged);
    _syncFields();
  }

  void _onTabChanged() {
    if (!mounted || _tabs.indexIsChanging) return;
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant LearningPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncFields();
  }

  void _syncFields() {
    final documentId = c.current?.id;
    final session = c.session;
    final changedDocument = _documentId != documentId;
    final changedSession = _sessionId != session?.id;
    if (changedSession) _answerSaveTimer?.cancel();
    if (changedDocument) {
      _answerSaveTimer?.cancel();
      _documentId = documentId;
      _question.clear();
      _term.clear();
      _noteSearch.clear();
      _noteQuery = '';
      _useRange = false;
      _tabs.index = 0;
    }
    if (changedDocument ||
        changedSession ||
        _savedQuestion != (session?.question ?? '')) {
      _savedQuestion = session?.question ?? '';
      _practiceQuestion.text = _savedQuestion;
      if (changedDocument || changedSession) _editingQuestion = false;
    }
    if (changedDocument ||
        changedSession ||
        _savedAnswer != (session?.answer ?? '')) {
      _savedAnswer = session?.answer ?? '';
      _answer.text = _savedAnswer;
    }
    _sessionId = session?.id;
  }

  @override
  void dispose() {
    _answerSaveTimer?.cancel();
    _tabs.removeListener(_onTabChanged);
    if (_ownsTabs) _tabs.dispose();
    _question.dispose();
    _term.dispose();
    _practiceQuestion.dispose();
    _answer.dispose();
    _noteSearch.dispose();
    _noteSearchFocus.dispose();
    super.dispose();
  }

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }

  Future<void> _request(
    AiTask task,
    String question,
    bool useRange, {
    bool showReply = false,
  }) async {
    if (_blocked) return;
    final before = c.replies.length;
    setState(() => _previewing = true);
    try {
      await widget.onRequest(task, question, useRange);
      if (mounted && showReply && c.replies.length > before) {
        _tabs.animateTo(1);
      }
    } catch (error) {
      _message(error.toString());
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  Future<void> _editSession({bool createNew = false}) async {
    final document = c.current;
    if (document == null || _blocked) return;
    final previous = createNew ? null : c.session;
    final draft = await showSessionDialog(
      context,
      document: document,
      previous: previous,
      currentPage: c.page,
    );
    if (draft == null || c.current?.id != document.id) return;
    if (previous == null) {
      c.beginSession(
        start: draft.start,
        end: draft.end,
        goal: draft.goal,
        minutes: draft.minutes,
      );
    } else {
      final changedRange =
          previous.startPage != draft.start || previous.endPage != draft.end;
      c.saveSession(
        previous.copyWith(
          startPage: draft.start,
          endPage: draft.end,
          goal: draft.goal,
          minutes: draft.minutes,
          question: changedRange ? '' : previous.question,
          answer: changedRange ? '' : previous.answer,
          feedback: changedRange ? '' : previous.feedback,
          needsReview: changedRange ? false : previous.needsReview,
          stage: changedRange ? 'read' : previous.stage,
        ),
      );
    }
  }

  Future<void> _startCurrentPage() async {
    final document = c.current;
    if (document == null || _blocked) return;
    final page = c.page.clamp(1, document.pageCount);
    c.beginSession(
      start: page,
      end: page,
      goal: '理解并复述第 $page 页的核心内容',
      minutes: 15,
    );
  }

  Future<void> _jumpPage(int page, {SourceRegion? region}) async {
    final document = c.current;
    if (document == null) return;
    await widget.onJump(
      Evidence(
        id: 'reading-${document.id}-$page',
        documentId: document.id,
        documentHash: document.contentHash,
        page: page,
        region: region ?? SourceRegion.fullPage,
        text: '',
      ),
    );
  }

  Future<void> _jumpNote(StudyNote note) async {
    final document = c.store.getDocument(note.documentId);
    if (document == null || document.contentHash != note.documentHash) {
      _message('笔记来源版本不一致。');
      return;
    }
    await widget.onJump(
      Evidence(
        id: 'note-${note.id}',
        documentId: note.documentId,
        documentHash: note.documentHash,
        page: note.page,
        region: note.region,
        text: note.evidenceText,
      ),
    );
  }

  void _savePracticeQuestion() {
    final session = c.session;
    final text = _practiceQuestion.text.trim();
    if (session == null || text.isEmpty) return;
    c.saveSession(
      session.copyWith(
        question: text,
        answer: '',
        feedback: '',
        needsReview: false,
        stage: 'question',
      ),
    );
    if (mounted) setState(() => _editingQuestion = false);
  }

  void _persistAnswer({bool notify = true}) {
    final session = c.session;
    final text = _answer.text.trim();
    if (session == null || text.isEmpty) return;
    if (text != session.answer) {
      c.saveAnswer(text);
      if (notify) _message('作答已保存。');
    }
  }

  void _scheduleAnswerSave() {
    _answerSaveTimer?.cancel();
    final session = c.session;
    if (session == null) return;
    final sessionId = session.id;
    _answerSaveTimer = Timer(const Duration(milliseconds: 800), () {
      if (!mounted || c.session?.id != sessionId) return;
      _persistAnswer(notify: false);
    });
  }

  void _generateQuestion(StudySession session) => _request(
    AiTask.generateQuestion,
    '请根据第 ${session.startPage}–${session.endPage} 页原文，'
    '围绕学习目标“${session.goal}”提出一个主动回忆问题。暂时不展示答案。',
    true,
  );

  void _gradeAnswer(StudySession session) {
    if (_answer.text.trim().isEmpty) return;
    _answerSaveTimer?.cancel();
    _persistAnswer(notify: false);
    _request(
      AiTask.gradeAnswer,
      '请评阅这道题的作答。题目：${session.question}\n'
      '范围：第 ${session.startPage}–${session.endPage} 页。'
      '请指出答对的要点、遗漏的条件和可核对的原文。',
      true,
    );
  }

  void _retry() {
    final session = c.session;
    if (session == null) return;
    c.saveSession(
      session.copyWith(
        answer: '',
        feedback: '',
        needsReview: false,
        stage: 'question',
      ),
    );
  }

  void _sendQuestion() {
    final text = _question.text.trim();
    if (text.isEmpty || _blocked) return;
    _request(AiTask.explain, text, _useRange);
  }

  void _scrollToStep(int index) {
    final key = switch (index) {
      0 => _readKey,
      1 => _recallKey,
      _ => _feedbackKey,
    };
    final target = key.currentContext;
    if (target == null) {
      if (index == 2) _message('完成一次评阅后，可以在这里核对反馈。');
      return;
    }
    Scrollable.ensureVisible(
      target,
      duration: context.motion(Motion.base),
      curve: Motion.curve,
      alignment: .05,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (c.current == null) return const SizedBox.shrink();
    final colors = context.colors;
    return ColoredBox(
      color: colors.surface,
      child: Column(
        children: [
          if (widget.showHeader)
            Material(color: colors.surface, child: _panelHeader()),
          if (c.sending) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                c.current!.kind == DocumentKind.textbook
                    ? _textbook()
                    : _paper(),
                _questions(),
                _notes(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _panelHeader() {
    final kind = c.current!.kind;
    return AnimatedBuilder(
      animation: _tabs,
      builder: (context, _) {
        final (icon, label) = switch (_tabs.index) {
          1 => (Icons.forum_outlined, '问答'),
          2 => (Icons.edit_note_outlined, '笔记'),
          _ => (
            kind == DocumentKind.textbook
                ? Icons.menu_book_outlined
                : Icons.article_outlined,
            '学习',
          ),
        };
        return Container(
          height: AppChrome.titleBarHeight,
          padding: EdgeInsets.only(
            left: Space.lg,
            right: widget.trailing == null ? Space.lg : 0,
          ),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: context.colors.outline)),
          ),
          child: Row(
            children: [
              Icon(icon, size: 16, color: context.colors.inkMuted),
              const SizedBox(width: 8),
              Text(
                label,
                style: context.texts.bodyMedium!.copyWith(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (widget.trailing != null) widget.trailing!,
            ],
          ),
        );
      },
    );
  }

  Widget _textbook() {
    final session = c.session;
    if (session == null) return _emptyStudyState();
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      children: [
        _sessionCard(session),
        const SizedBox(height: Space.md),
        _recallCard(session),
        if (session.feedback.isNotEmpty && session.answer.isNotEmpty) ...[
          const SizedBox(height: Space.md),
          _feedbackCard(session),
        ],
        if (session.attempts.isNotEmpty) ...[
          const SizedBox(height: Space.md),
          _attemptHistory(session),
        ],
        const SizedBox(height: Space.md),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _blocked ? null : () => _editSession(createNew: true),
            icon: const Icon(Icons.add_rounded, size: 17),
            label: const Text('开始另一小节'),
          ),
        ),
        if (c.sessions.where((item) => item.id != session.id).isNotEmpty) ...[
          const SizedBox(height: Space.md),
          _previousSessions(),
        ],
      ],
    );
  }

  Widget _emptyStudyState() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final minHeight = (constraints.maxHeight - 48)
            .clamp(0.0, double.infinity)
            .toDouble();
        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minHeight),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AccentIcon(
                          icon: Icons.flag_outlined,
                          accent: context.colors.blueAccent,
                          size: 30,
                          iconSize: 17,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '本节目标',
                          textAlign: TextAlign.center,
                          style: context.texts.titleMedium!.copyWith(
                            fontSize: 17,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text(
                      '设定页段与目标 → 独立回忆作答 → AI 对照原文核对',
                      textAlign: TextAlign.center,
                      style: context.texts.bodySmall!.copyWith(
                        fontSize: 13,
                        height: 1.7,
                      ),
                    ),
                    const SizedBox(height: Space.lg),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: _blocked ? null : () => _editSession(),
                          icon: const Icon(Icons.add_rounded, size: 17),
                          label: const Text('设定本节目标'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _blocked ? null : _startCurrentPage,
                          icon: const Icon(Icons.play_arrow_rounded, size: 17),
                          label: const Text('直接学习当前页'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _sessionCard(StudySession session) {
    final c = context.colors;
    return Container(
      key: _readKey,
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 14),
      decoration: BoxDecoration(
        color: c.sidebar,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _stageTrail(session.stage)),
              PopupMenuButton<String>(
                tooltip: '本节操作',
                enabled: !_blocked,
                icon: Icon(
                  Icons.more_horiz_rounded,
                  size: 18,
                  color: c.inkMuted,
                ),
                onSelected: (value) {
                  switch (value) {
                    case 'edit':
                      _editSession();
                    case 'jump':
                      _jumpPage(session.startPage);
                    case 'refine':
                      _request(
                        AiTask.studyPlan,
                        '我准备在 ${session.minutes} 分钟学习第 ${session.startPage}–${session.endPage} 页。'
                        '我的目标是：${session.goal}。请拟出少量可编辑的学习目标，并标明对应原文。',
                        true,
                        showReply: true,
                      );
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'edit',
                    child: Row(
                      children: [
                        Icon(Icons.edit_outlined, size: 16, color: c.inkMuted),
                        const SizedBox(width: 8),
                        const Text('编辑学习目标'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'jump',
                    child: Row(
                      children: [
                        Icon(
                          Icons.open_in_new_rounded,
                          size: 16,
                          color: c.inkMuted,
                        ),
                        const SizedBox(width: 8),
                        const Text('回到这一节'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'refine',
                    child: Row(
                      children: [
                        Icon(
                          Icons.auto_awesome_outlined,
                          size: 16,
                          color: c.inkMuted,
                        ),
                        const SizedBox(width: 8),
                        const Text('AI 细化目标'),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '第 ${session.startPage}–${session.endPage} 页 · ${session.minutes} 分钟',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.texts.bodyMedium!.copyWith(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: c.ink,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '本节目标',
            style: context.texts.bodySmall!.copyWith(
              fontSize: 12,
              color: c.inkMuted,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            session.goal,
            maxLines: 3,
            style: context.texts.bodyMedium!.copyWith(
              fontSize: 14.5,
              color: c.ink,
              height: 1.65,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '原文读到第 ${this.c.page} 页 · 已保存 ${session.attempts.length} 次作答',
            style: context.texts.bodySmall!.copyWith(
              fontSize: 12.5,
              fontFeatures: AppNumerals.tabular,
            ),
          ),
        ],
      ),
    );
  }

  Widget _stageTrail(String stage) {
    final active = switch (stage) {
      'question' || 'answered' => 1,
      'feedback' => 2,
      _ => 0,
    };
    const labels = ['阅读', '独立作答', '核对反馈'];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var index = 0; index < labels.length; index++) ...[
            if (index > 0) const SizedBox(width: 12),
            _StepChip(
              index: index,
              label: labels[index],
              active: index == active,
              done: index < active,
              onTap: () => _scrollToStep(index),
            ),
          ],
        ],
      ),
    );
  }

  Widget _recallCard(StudySession session) {
    final c = context.colors;
    final hasQuestion = session.question.trim().isNotEmpty;
    final editing = _editingQuestion || !hasQuestion;
    final questionDraft = _practiceQuestion.text.trim();
    final canSaveQuestion =
        !_blocked &&
        questionDraft.isNotEmpty &&
        (questionDraft != session.question.trim() || !hasQuestion);
    final savedAnswer =
        _answer.text.trim().isNotEmpty &&
        _answer.text.trim() == session.answer.trim();
    return _card(
      key: _recallKey,
      children: [
        Row(
          children: [
            AccentIcon(
              icon: Icons.psychology_alt_outlined,
              accent: c.greenAccent,
              size: 26,
              iconSize: 15,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text('主动回忆', style: context.texts.titleSmall)),
            if (hasQuestion && !editing) ...[
              TextButton.icon(
                onPressed: _blocked
                    ? null
                    : () => setState(() {
                        _practiceQuestion.text = session.question;
                        _editingQuestion = true;
                      }),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  textStyle: context.texts.bodySmall!.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                icon: const Icon(Icons.edit_outlined, size: 15),
                label: const Text('自拟'),
              ),
              TextButton.icon(
                onPressed: _blocked ? null : () => _generateQuestion(session),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  textStyle: context.texts.bodySmall!.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                icon: const Icon(Icons.refresh_rounded, size: 15),
                label: const Text('换题'),
              ),
            ] else if (!hasQuestion)
              TextButton.icon(
                onPressed: _blocked ? null : () => _generateQuestion(session),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  textStyle: context.texts.bodySmall!.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                icon: const Icon(Icons.auto_awesome_outlined, size: 15),
                label: const Text('出题'),
              ),
          ],
        ),
        const SizedBox(height: Space.sm),
        if (editing) ...[
          TextField(
            controller: _practiceQuestion,
            minLines: 2,
            maxLines: 5,
            maxLength: 2000,
            enabled: !_blocked,
            buildCounter: (
              context, {
              required currentLength,
              required isFocused,
              maxLength,
            }) => null,
            decoration: const InputDecoration(
              hintText: '输入问题，或直接自拟一道题',
              alignLabelWithHint: true,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: Space.xs),
          Row(
            children: [
              if (hasQuestion)
                TextButton(
                  onPressed: _blocked
                      ? null
                      : () => setState(() => _editingQuestion = false),
                  child: const Text('取消'),
                ),
              const Spacer(),
              FilledButton(
                onPressed: canSaveQuestion ? _savePracticeQuestion : null,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 34),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                child: const Text('保存题目'),
              ),
            ],
          ),
        ] else ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              session.question,
              style: context.texts.bodyMedium!.copyWith(
                fontSize: 15,
                color: c.ink,
                fontWeight: FontWeight.w500,
                height: 1.7,
              ),
            ),
          ),
          const SizedBox(height: Space.md),
          Container(
            decoration: BoxDecoration(
              color: c.surfaceRaised,
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: c.outlineStrong),
            ),
            child: Column(
              children: [
                TextField(
                  controller: _answer,
                  minLines: 4,
                  maxLines: 10,
                  maxLength: 6000,
                  enabled: !_blocked,
                  style: context.texts.bodyMedium!.copyWith(
                    fontSize: 14.5,
                    color: c.ink,
                    height: 1.6,
                  ),
                  buildCounter: (
                    context, {
                    required currentLength,
                    required isFocused,
                    maxLength,
                  }) => null,
                  decoration: const InputDecoration(
                    hintText: '写下你的回答',
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.fromLTRB(14, 12, 14, 6),
                  ),
                  onChanged: (_) {
                    setState(() {});
                    _scheduleAnswerSave();
                  },
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 10, 10),
                  child: Row(
                    children: [
                      Icon(
                        savedAnswer
                            ? Icons.check_circle_outline_rounded
                            : Icons.edit_outlined,
                        size: 15,
                        color: savedAnswer ? c.green : c.inkMuted,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        savedAnswer ? '已保存' : '未保存',
                        style: context.texts.bodySmall!.copyWith(
                          fontSize: 12.5,
                          color: c.inkMuted,
                        ),
                      ),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: _blocked || _answer.text.trim().isEmpty
                            ? null
                            : () => _gradeAnswer(session),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 36),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                        ),
                        icon: const Icon(Icons.fact_check_outlined, size: 16),
                        label: const Text('核对作答'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _feedbackCard(StudySession session) => _card(
    key: _feedbackKey,
    children: [
      Row(
        children: [
          Icon(Icons.rule_outlined, size: 18, color: context.colors.primary),
          const SizedBox(width: Space.sm),
          Expanded(child: Text('反馈与核对', style: context.texts.titleSmall)),
          AppBadge(label: '已评阅', tone: BadgeTone.primary, dense: true),
          if (session.needsReview) ...[
            const SizedBox(width: 5),
            const AppBadge(label: '待核对', tone: BadgeTone.warm, dense: true),
          ],
        ],
      ),
      const SizedBox(height: Space.md),
      SelectableText(
        session.feedback,
        style: context.texts.bodyMedium!.copyWith(
          color: context.colors.ink,
          height: 1.7,
        ),
      ),
      const SizedBox(height: Space.sm),
      TextButton.icon(
        onPressed: () => _tabs.animateTo(1),
        icon: const Icon(Icons.link_rounded, size: 16),
        label: const Text('在问答中查看引用'),
      ),
      Divider(height: Space.lg, color: context.colors.outline),
      CheckboxListTile(
        value: session.needsReview,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: const Text('这条评语待核对'),
        onChanged: _blocked ? null : (value) => c.markForReview(value ?? false),
      ),
      const SizedBox(height: Space.sm),
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: _blocked ? null : _retry,
          icon: const Icon(Icons.replay_rounded, size: 16),
          label: const Text('重新作答'),
        ),
      ),
    ],
  );

  Widget _attemptHistory(StudySession session) => _card(
    children: [
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        title: Text(
          '历次作答 · ${session.attempts.length}',
          style: context.texts.titleSmall,
        ),
        children: [
          for (final attempt in session.attempts.reversed)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      AppBadge(label: _date(attempt.createdAt), dense: true),
                      if (attempt.needsReview) ...[
                        const SizedBox(width: 5),
                        const AppBadge(
                          label: '待核对',
                          tone: BadgeTone.warm,
                          dense: true,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  SelectableText(
                    attempt.question,
                    style: context.texts.bodyMedium!.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 1.6,
                    ),
                  ),
                  const SizedBox(height: 6),
                  SelectableText(
                    '我的作答：${attempt.answer}',
                    style: context.texts.bodyMedium!.copyWith(height: 1.65),
                  ),
                  const SizedBox(height: 6),
                  SelectableText(
                    '反馈：${attempt.feedback}',
                    style: context.texts.bodyMedium!.copyWith(
                      height: 1.65,
                      color: context.colors.inkMuted,
                    ),
                  ),
                  const Divider(height: Space.lg),
                ],
              ),
            ),
        ],
      ),
    ],
  );

  Widget _previousSessions() => _card(
    children: [
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        title: Text('历史记录', style: context.texts.titleSmall),
        children: [
          for (final previous in c.sessions.where(
            (item) => item.id != c.session?.id,
          ))
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                previous.goal,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '第 ${previous.startPage}–${previous.endPage} 页 · ${_date(previous.updatedAt)}',
              ),
              trailing: const Icon(Icons.chevron_right_rounded, size: 18),
              onTap: _blocked ? null : () => c.saveSession(previous),
            ),
        ],
      ),
    ],
  );

  Widget _paper() {
    final document = c.current!;
    final start = c.session?.startPage ?? 1;
    final end = c.session?.endPage ?? document.pageCount;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            children: [
              _card(
                children: [
                  _sectionTitle(
                    '论文导读',
                    Icons.article_outlined,
                    accent: context.colors.blueAccent,
                  ),
                  const SizedBox(height: Space.md),
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: Space.sm,
                    runSpacing: Space.sm,
                    children: [
                      AppBadge(
                        label: '第 $start–$end 页',
                        tone: BadgeTone.primary,
                      ),
                      TextButton(
                        onPressed: _blocked ? null : () => _editSession(),
                        child: const Text('选择页段'),
                      ),
                      if (start != 1 || end != document.pageCount)
                        TextButton(
                          onPressed: _blocked
                              ? null
                              : () {
                                  final previous = c.session;
                                  if (previous != null) {
                                    c.saveSession(
                                      previous.copyWith(
                                        startPage: 1,
                                        endPage: document.pageCount,
                                      ),
                                    );
                                  }
                                },
                          child: const Text('改为全篇'),
                        ),
                    ],
                  ),
                  const SizedBox(height: Space.md),
                  FilledButton.icon(
                    onPressed: _blocked
                        ? null
                        : () => _request(
                            AiTask.paperGuide,
                            '请导读本文第 $start–$end 页，分别核对研究问题、作者的方法或论证、'
                            '关键证据和局限；文中没有交代的项目写“本文未说明”。',
                            true,
                            showReply: true,
                          ),
                    icon: const Icon(Icons.auto_awesome_outlined, size: 17),
                    label: const Text('生成导读'),
                  ),
                ],
              ),
              const SizedBox(height: Space.md),
              _card(
                children: [
                  _sectionTitle(
                    '术语与句子',
                    Icons.translate_outlined,
                    accent: context.colors.warmAccent,
                  ),
                  const SizedBox(height: Space.md),
                  Text(
                    '术语、符号或一句原文',
                    style: context.texts.bodySmall!.copyWith(
                      fontSize: 13,
                      color: context.colors.ink,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _term,
                    minLines: 2,
                    maxLines: 5,
                    maxLength: 1000,
                    enabled: !_blocked,
                    decoration: const InputDecoration(
                      hintText: '输入困惑，或在原页框选对应位置',
                      counterText: '',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: Space.xs),
                  OutlinedButton.icon(
                    onPressed:
                        _blocked ||
                            (_term.text.trim().isEmpty && c.selection == null)
                        ? null
                        : () => _request(
                            AiTask.explainTerm,
                            _term.text.trim().isEmpty
                                ? '请解释本次原文选区中的术语、符号或句子，给出中文释义，并区分作者定义和你的解释。'
                                : '请结合本文解释：${_term.text.trim()}。给出中文释义，并区分作者定义和你的解释。',
                            false,
                            showReply: true,
                          ),
                    icon: const Icon(Icons.manage_search_outlined, size: 17),
                    label: const Text('解释'),
                  ),
                ],
              ),
              const SizedBox(height: Space.md),
              _card(
                children: [
                  _sectionTitle(
                    '核对图表与公式',
                    Icons.crop_outlined,
                    accent: context.colors.warmAccent,
                  ),
                  const SizedBox(height: Space.sm),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        c.selection == null
                            ? Icons.info_outline_rounded
                            : Icons.check_circle_outline_rounded,
                        size: 16,
                        color: c.selection == null
                            ? context.colors.inkMuted
                            : context.colors.primary,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          c.selection == null ? '先在原页框选图表或公式。' : '已框选原页区域。',
                          style: context.texts.bodySmall!.copyWith(height: 1.6),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Space.md),
                  OutlinedButton.icon(
                    onPressed: _blocked || c.selection == null
                        ? null
                        : () => _request(
                            AiTask.explainImage,
                            '请核对本次框选图表或公式：先读出列名、数值、单位、脚注或公式符号，'
                            '再结合正文解释关系与比较条件。不清楚或缺少图例时请指出。',
                            false,
                            showReply: true,
                          ),
                    icon: const Icon(Icons.image_search_outlined, size: 17),
                    label: const Text('解释图表'),
                  ),
                ],
              ),
            ],
          ),
        ),
        _paperFooter(),
      ],
    );
  }

  Widget _paperFooter() => Container(
    decoration: BoxDecoration(
      color: context.colors.surface,
      border: Border(top: BorderSide(color: context.colors.outline)),
    ),
    padding: const EdgeInsets.fromLTRB(20, Space.md, 20, Space.md),
    child: SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _blocked ? null : widget.onNote,
              icon: const Icon(Icons.edit_note_outlined, size: 17),
              label: const Text('记笔记'),
            ),
          ),
          const SizedBox(height: 6),
          const TrustNote('笔记会记录当前页与选区。', icon: Icons.shield_outlined),
        ],
      ),
    ),
  );

  Widget _questions() {
    final colors = context.colors;
    return Material(
      color: Colors.transparent,
      child: Column(
        children: [
          Expanded(
            child: c.replies.isEmpty
                ? Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 320),
                      child: const EmptyState(
                        compact: true,
                        icon: Icons.forum_outlined,
                        title: '暂无问答',
                        message: '向这份资料提问。',
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                    children: [
                      for (final reply in c.replies.reversed) ...[
                        _replyCard(reply),
                        const SizedBox(height: Space.md),
                      ],
                    ],
                  ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
            decoration: BoxDecoration(
              color: colors.surface,
              border: Border(top: BorderSide(color: colors.outline)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppSegmentedControl(
                  expand: true,
                  segments: [
                    AppSegment(label: c.selection == null ? '当前页' : '当前选区'),
                    const AppSegment(label: '本次页段'),
                  ],
                  selectedIndex: _useRange ? 1 : 0,
                  onChanged: (index) => setState(() => _useRange = index == 1),
                ),
                const SizedBox(height: 10),
                Container(
                  decoration: BoxDecoration(
                    color: colors.surfaceRaised,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: colors.outlineStrong),
                  ),
                  child: Column(
                    children: [
                      CallbackShortcuts(
                        bindings: {
                          const SingleActivator(
                            LogicalKeyboardKey.enter,
                            control: true,
                          ): _sendQuestion,
                        },
                        child: TextField(
                          controller: _question,
                          minLines: 2,
                          maxLines: 5,
                          maxLength: 2000,
                          enabled: !_blocked,
                          style: context.texts.bodyMedium!.copyWith(
                            fontSize: 14.5,
                            color: colors.ink,
                            height: 1.55,
                          ),
                          buildCounter: (
                            context, {
                            required currentLength,
                            required isFocused,
                            maxLength,
                          }) => null,
                          decoration: const InputDecoration(
                            hintText: '向原文提问',
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.fromLTRB(14, 12, 14, 6),
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 10, 10),
                        child: Row(
                          children: [
                            if (!c.sending) ...[
                              Icon(
                                Icons.visibility_outlined,
                                size: 15,
                                color: colors.inkMuted,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                '发送前确认',
                                style: context.texts.bodySmall!.copyWith(
                                  fontSize: 12.5,
                                ),
                              ),
                            ] else
                              Text(
                                '正在等待回答…',
                                style: context.texts.bodySmall!.copyWith(
                                  fontSize: 12.5,
                                ),
                              ),
                            const Spacer(),
                            if (c.selection != null)
                              TextButton.icon(
                                onPressed: _blocked
                                    ? null
                                    : () => _request(
                                        AiTask.explainImage,
                                        _question.text.trim().isEmpty
                                            ? '请结合正文解释本次框选图表或公式，核对数值、单位、符号和适用条件。'
                                            : _question.text.trim(),
                                        false,
                                      ),
                                style: TextButton.styleFrom(
                                  minimumSize: const Size(0, 34),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                  ),
                                  textStyle: context.texts.bodySmall!.copyWith(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                icon: const Icon(Icons.crop_rounded, size: 15),
                                label: const Text('问这张图'),
                              ),
                            const SizedBox(width: 6),
                            FilledButton.icon(
                              onPressed:
                                  _blocked || _question.text.trim().isEmpty
                                  ? null
                                  : _sendQuestion,
                              style: FilledButton.styleFrom(
                                minimumSize: const Size(0, 36),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                ),
                              ),
                              icon: const Icon(
                                Icons.arrow_upward_rounded,
                                size: 16,
                              ),
                              label: const Text('发送'),
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
        ],
      ),
    );
  }

  Widget _replyCard(SavedReply reply) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.outline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: c.surfaceRaised,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  reply.question,
                  style: context.texts.bodyMedium!.copyWith(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    height: 1.55,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (reply.insufficient) ...[
            AppCallout(tone: CalloutTone.warning, message: '依据不足，请回看原文并核对结论。'),
            const SizedBox(height: Space.sm),
          ],
          SelectableText(
            reply.answer,
            style: context.texts.bodyMedium!.copyWith(
              fontSize: 14.5,
              color: c.ink,
              height: 1.7,
            ),
          ),
          if (reply.sources.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final source in reply.sources)
                  ActionChip(
                    avatar: Icon(
                      Icons.open_in_new_rounded,
                      size: 14,
                      color: c.inkMuted,
                    ),
                    label: Text('第 ${source.page} 页'),
                    onPressed: _blocked ? null : () => widget.onJump(source),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  '模型 ${reply.model} · '
                  '${reply.tokens > 0 ? '${reply.tokens} token' : '服务商未返回用量'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.bodySmall!.copyWith(
                    fontSize: 12,
                    fontFeatures: AppNumerals.tabular,
                  ),
                ),
              ),
              IconButton(
                tooltip: '复制回答',
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: reply.answer));
                  _message('回答已复制。');
                },
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                icon: const Icon(Icons.copy_outlined, size: 15),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _notes() {
    final all = c.notes;
    final query = _noteQuery.trim().toLowerCase();
    final notes = query.isEmpty
        ? all
        : all
              .where(
                (note) =>
                    note.understanding.toLowerCase().contains(query) ||
                    note.question.toLowerCase().contains(query) ||
                    note.evidenceText.toLowerCase().contains(query) ||
                    '${note.page}' == query,
              )
              .toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: SizedBox(
            height: 40,
            child: Row(
              children: [
                Text('笔记', style: context.texts.titleMedium),
                const Spacer(),
                IconButton(
                  onPressed: _blocked ? null : widget.onNote,
                  tooltip: '新建笔记',
                  icon: const Icon(Icons.add_rounded, size: 20),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: TextField(
            controller: _noteSearch,
            focusNode: _noteSearchFocus,
            onChanged: (value) => setState(() => _noteQuery = value),
            decoration: InputDecoration(
              hintText: '搜索笔记',
              isDense: true,
              prefixIcon: const Icon(Icons.search_rounded, size: 18),
              suffixIcon: _noteQuery.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除搜索',
                      onPressed: () {
                        _noteSearch.clear();
                        setState(() => _noteQuery = '');
                      },
                      icon: const Icon(Icons.close_rounded, size: 16),
                    ),
            ),
          ),
        ),
        const SizedBox(height: Space.md),
        Expanded(
          child: all.isEmpty
              ? Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: EmptyState(
                      compact: true,
                      icon: Icons.note_alt_outlined,
                      title: '暂无笔记',
                      message: '框选原文，记录一条笔记。',
                      action: FilledButton.icon(
                        onPressed: _blocked ? null : widget.onNote,
                        icon: const Icon(Icons.edit_note_outlined, size: 17),
                        label: const Text('新建笔记'),
                      ),
                    ),
                  ),
                )
              : notes.isEmpty
              ? Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: EmptyState(
                      compact: true,
                      icon: Icons.search_off_rounded,
                      title: '没有匹配的笔记',
                      message: '换个关键词试试。',
                      action: TextButton(
                        onPressed: () {
                          _noteSearch.clear();
                          setState(() => _noteQuery = '');
                        },
                        child: const Text('清除搜索'),
                      ),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                  children: [
                    for (final note in notes) ...[
                      _noteCard(note),
                      const SizedBox(height: Space.md),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _noteCard(StudyNote note) {
    final c = context.colors;
    return _card(
      children: [
        SizedBox(
          width: double.infinity,
          height: 32,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _date(note.createdAt),
                    style: context.texts.bodySmall!.copyWith(fontSize: 12),
                  ),
                  const SizedBox(width: Space.sm),
                  AppBadge(label: '第 ${note.page} 页', dense: true),
                ],
              ),
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: IconButton(
                  tooltip: '回到原页',
                  onPressed: _blocked ? null : () => _jumpNote(note),
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  icon: const Icon(Icons.open_in_new_rounded, size: 16),
                ),
              ),
            ],
          ),
        ),
        if (note.understanding.isNotEmpty) ...[
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: Text(
              '我的理解',
              textAlign: TextAlign.center,
              style: context.texts.bodySmall!.copyWith(
                color: c.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: SelectableText(
              note.understanding,
              textAlign: TextAlign.center,
              style: context.texts.bodyMedium!.copyWith(
                color: c.ink,
                height: 1.7,
              ),
            ),
          ),
        ],
        if (note.question.isNotEmpty) ...[
          const SizedBox(height: Space.md),
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: c.inkMuted,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  '还没解决的问题',
                  style: context.texts.bodySmall!.copyWith(
                    color: c.inkMuted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: SelectableText(
              note.question,
              textAlign: TextAlign.center,
              style: context.texts.bodyMedium!.copyWith(
                color: c.ink,
                height: 1.7,
              ),
            ),
          ),
        ],
        if (note.evidenceText.isNotEmpty)
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              title: Padding(
                padding: const EdgeInsets.only(left: 24),
                child: Center(
                  child: Text(
                    '原文摘录',
                    style: context.texts.bodySmall!.copyWith(fontSize: 12.5),
                  ),
                ),
              ),
              children: [
                SizedBox(
                  width: double.infinity,
                  child: SelectableText(
                    note.evidenceText,
                    textAlign: TextAlign.center,
                    style: context.texts.bodySmall!.copyWith(
                      height: 1.6,
                      fontFeatures: AppNumerals.tabular,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _card({required List<Widget> children, Key? key}) => Material(
    key: key,
    color: Colors.transparent,
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: Space.lg),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.colors.outline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: children,
      ),
    ),
  );

  Widget _sectionTitle(String title, IconData icon, {AppAccent? accent}) {
    final a = accent ?? context.colors.neutralAccent;
    return Row(
      children: [
        AccentIcon(icon: icon, accent: a, size: 26, iconSize: 15),
        const SizedBox(width: 8),
        Expanded(child: Text(title, style: context.texts.titleSmall)),
      ],
    );
  }

  String _date(DateTime value) =>
      '${value.year}.${value.month.toString().padLeft(2, '0')}.'
      '${value.day.toString().padLeft(2, '0')}';
}

class _StepChip extends StatelessWidget {
  const _StepChip({
    required this.index,
    required this.label,
    required this.active,
    required this.done,
    required this.onTap,
  });

  final int index;
  final String label;
  final bool active;
  final bool done;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final foreground = active ? c.ink : c.inkMuted;
    return Semantics(
      button: true,
      selected: active,
      label: '第 ${index + 1} 步 $label${active ? '，当前步骤' : ''}',
      child: Tooltip(
        message: active ? '当前步骤' : '回到“$label”',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          hoverColor: c.tint,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  done
                      ? Icons.check_rounded
                      : active
                      ? Icons.circle
                      : Icons.circle_outlined,
                  size: active ? 8 : 13,
                  color: foreground,
                ),
                const SizedBox(width: 5),
                Text(
                  '${index + 1} $label',
                  style: context.texts.bodySmall!.copyWith(
                    fontSize: 13,
                    color: foreground,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w500,
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
