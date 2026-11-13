import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app_controller.dart';
import '../../../core/models.dart';
import '../../../services/ai_gateway.dart';
import '../../../services/document_service.dart';
import '../../../ui/theme/tokens.dart';
import '../../../ui/widgets/app_dialog.dart';
import '../../../ui/widgets/app_surfaces.dart';
import '../../review/models/review_models.dart';
import '../../review/ui/review_dialogs.dart';
import '../book_qa_controller.dart';
import '../models/book_qa_models.dart';
import '../models/book_understanding.dart';
import 'book_qa_dialogs.dart';

/// Textbook question workspace. It replaces the page-scoped question box for
/// textbooks while keeping the practice tabs and the paper flow unchanged.
class BookQaPanel extends StatefulWidget {
  const BookQaPanel({
    super.key,
    required this.controller,
    required this.study,
    required this.onJump,
  });

  final BookQaController controller;
  final StudyController study;
  final Future<void> Function(Evidence evidence) onJump;

  @override
  State<BookQaPanel> createState() => _BookQaPanelState();
}

class _BookQaPanelState extends State<BookQaPanel> {
  final _question = TextEditingController();
  BookAskMode _mode = BookAskMode.wholeBookWeb;
  bool _preparing = false;

  BookQaController get q => widget.controller;

  @override
  void dispose() {
    _question.dispose();
    super.dispose();
  }

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }

  Future<void> _send() async {
    final text = _question.text.trim();
    if (text.isEmpty || _preparing || q.asking) return;
    setState(() => _preparing = true);
    try {
      final prepared = await q.prepare(text, mode: _mode);
      if (!mounted) return;
      final confirmed = await showBookQaPreview(
        context,
        request: prepared,
        webSupported: q.webAvailable,
      );
      if (!confirmed || !mounted) return;
      _question.clear();
      await q.send(prepared);
    } catch (error) {
      if (mounted) _message(error.toString());
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  Future<void> _askImage() async {
    if (_preparing || q.asking) return;
    final raster = widget.study.raster;
    final selection = widget.study.selection;
    if (raster == null) {
      _message('请等待页面渲染完成。');
      return;
    }
    if (selection == null) {
      _message('先在原页框选一张图、表或公式。');
      return;
    }
    setState(() => _preparing = true);
    try {
      final bytes = await cropPage(raster, selection);
      final attachment = ImageAttachment(
        bytes: bytes,
        mimeType: 'image/png',
        scopeLabel: '第 ${widget.study.page} 页 · 框选区域',
      );
      final typed = _question.text.trim();
      final question = typed.isEmpty
          ? '请结合正文解释本次框选图表或公式，核对数值、单位、符号和适用条件。'
          : typed;
      final prepared = await q.prepare(
        question,
        mode: _mode,
        image: attachment,
      );
      if (!mounted) return;
      final confirmed = await showBookQaPreview(
        context,
        request: prepared,
        webSupported: q.webAvailable,
      );
      if (!confirmed || !mounted) return;
      _question.clear();
      await q.send(prepared, imageApproval: prepared.approveImage());
    } catch (error) {
      if (mounted) _message(error.toString());
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  Future<void> _startUnderstanding() async {
    if (q.understandingRunning) {
      q.cancelUnderstanding();
      return;
    }
    final estimate = q.estimateUnderstanding();
    if (estimate == null) {
      _message('暂时无法估算教材整理任务。');
      return;
    }
    if (!estimate.hasWork) {
      _message('这本教材的页面与分块已经整理完成。');
      return;
    }
    final document = q.document;
    if (document == null) return;
    final confirmed = await confirmBookUnderstanding(
      context,
      bookTitle: document.title,
      provider:
          '${widget.study.settings.provider} · ${widget.study.settings.model}',
      estimate: estimate,
      maxChunks: 40,
    );
    if (!confirmed) return;
    unawaited(q.runUnderstanding());
  }

  Future<void> _showOverview() async {
    final document = q.document;
    final progress = q.progress;
    if (document == null || progress == null) return;
    final chapters = q.repository.getChapters(document.id);
    final points = q.repository.getKnowledgePoints(document.id);
    final overview = progress.overview;
    await showAppDialog<void>(
      context: context,
      builder: (context) => AppDialog(
        title: '教材理解',
        subtitle: document.title,
        icon: QIcons.knowledge,
        accent: context.colors.blueAccent,
        maxWidth: 680,
        actions: [
          TextButton.icon(
            onPressed: chapters.isEmpty
                ? null
                : () {
                    Navigator.of(context).pop();
                    _editChapters(chapters);
                  },
            icon: const QIcon(QIcons.edit, size: IconSizes.sm),
            label: const Text('编辑章节'),
          ),
          TextButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              _markSkipped();
            },
            icon: const QIcon(QIcons.clear, size: IconSizes.sm),
            label: const Text('标记空白页'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '页面解析 ${progress.pages.readyPages}/${progress.pages.totalPages} 页'
              '${progress.pages.skippedPages > 0 ? '（跳过 ${progress.pages.skippedPages} 页空白）' : ''}',
              style: context.texts.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(progress.coverageNote, style: context.texts.bodySmall),
            const SizedBox(height: Space.lg),
            if (overview != null) ...[
              Text('全书概览', style: context.texts.titleSmall),
              const SizedBox(height: 6),
              SelectableText(
                [
                  if (overview.subject.isNotEmpty) '学科范围：${overview.subject}',
                  if (overview.conventions.isNotEmpty)
                    '定义与约定：${overview.conventions}',
                  if (overview.chapterRelations.isNotEmpty)
                    '章节关系：${overview.chapterRelations.join('；')}',
                  if (overview.themes.isNotEmpty)
                    '全书主线：${overview.themes.join('；')}',
                  if (overview.unfinished.isNotEmpty)
                    '未完成：${overview.unfinished.join('；')}',
                ].join('\n'),
                style: context.texts.bodyMedium!.copyWith(height: 1.65),
              ),
              const SizedBox(height: Space.lg),
            ],
            Text('章节 · ${chapters.length}', style: context.texts.titleSmall),
            const SizedBox(height: 6),
            for (final chapter in chapters)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppBadge(
                      label: chapter.rangeLabel,
                      dense: true,
                      tone: chapter.generated
                          ? BadgeTone.warm
                          : BadgeTone.neutral,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        chapter.title,
                        style: context.texts.bodyMedium,
                      ),
                    ),
                    if (chapter.generated)
                      Text(
                        '临时',
                        style: context.texts.bodySmall!.copyWith(fontSize: 11),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: Space.md),
            Text('知识点 · ${points.length}', style: context.texts.titleSmall),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final point in points.take(40))
                  AppBadge(
                    label: '${point.term} · 第 ${point.startPage} 页',
                    dense: true,
                  ),
              ],
            ),
            if (progress.error != null) ...[
              const SizedBox(height: Space.md),
              AppCallout(tone: CalloutTone.warning, message: progress.error!),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _editChapters(List<BookChapter> chapters) async {
    final document = q.document;
    if (document == null || chapters.isEmpty) return;
    final result = await showChapterEditor(
      context,
      chapters: chapters,
      pageCount: document.pageCount,
    );
    if (result == null || !mounted) return;
    if (q.document?.id != document.id) return;
    q.applyChapters(result);
  }

  Future<void> _markSkipped() async {
    final document = q.document;
    if (document == null) return;
    final pages = await showSkipPagesDialog(
      context,
      pageCount: document.pageCount,
    );
    if (pages == null || !mounted) return;
    if (q.document?.id != document.id) return;
    q.markPagesSkipped(pages);
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return;
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (opened) return;
    } catch (_) {
      // Tests and unsupported platforms fall back to copying the link.
    }
    await Clipboard.setData(ClipboardData(text: url));
    _message('无法直接打开浏览器，链接已复制。');
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: q,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final progress = q.progress;
    return Column(
      children: [
        _header(context, progress),
        if (q.understandingRunning)
          _runningBanner(context)
        else if (progress != null && !progress.complete)
          _gapBanner(context, progress),
        if (q.error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: AppCallout(
              tone: CalloutTone.error,
              message: q.error!,
              onDismiss: q.clearMessages,
            ),
          ),
        if (q.notice != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: AppCallout(
              tone: CalloutTone.info,
              message: q.notice!,
              onDismiss: q.clearMessages,
            ),
          ),
        Expanded(child: _conversation(context)),
        _composer(context),
      ],
    );
  }

  Widget _header(BuildContext context, UnderstandingProgress? progress) {
    final complete = progress?.complete ?? false;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.colors.outline)),
      ),
      child: Row(
        children: [
          QIcon(
            QIcons.study,
            size: IconSizes.md,
            color: context.colors.inkMuted,
          ),
          const SizedBox(width: 7),
          Text('教材问答', style: context.texts.titleSmall),
          const SizedBox(width: 8),
          Tooltip(
            message: progress?.label ?? '尚未建立教材理解',
            child: AppBadge(
              label: complete
                  ? '已建立'
                  : progress == null
                  ? '未建立'
                  : '待整理',
              dense: true,
              tone: complete
                  ? BadgeTone.green
                  : progress == null
                  ? BadgeTone.neutral
                  : BadgeTone.warm,
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: progress == null ? '建立教材理解' : '查看教材理解',
            onPressed: _showOverview,
            visualDensity: VisualDensity.compact,
            icon: const QIcon(QIcons.textbook, size: IconSizes.md),
          ),
          IconButton(
            tooltip: q.understandingRunning
                ? '停止整理'
                : complete
                ? '教材理解已完成'
                : '建立/继续教材理解',
            onPressed: complete && !q.understandingRunning
                ? null
                : _startUnderstanding,
            visualDensity: VisualDensity.compact,
            icon: q.understandingRunning
                ? const QIcon(QIcons.stop, size: IconSizes.md)
                : const QIcon(QIcons.knowledge, size: IconSizes.md),
          ),
        ],
      ),
    );
  }

  Widget _runningBanner(BuildContext context) {
    final progress = q.progress;
    final total = progress?.chunkTotal ?? 0;
    final ready = progress?.chunkReady ?? 0;
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 10, 20, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.colors.tint,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '正在建立教材理解 · $ready/$total 块',
                  style: context.texts.bodySmall!.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              TextButton(
                onPressed: q.cancelUnderstanding,
                child: const Text('停止'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: total == 0 ? null : ready / total,
            minHeight: 3,
          ),
          const SizedBox(height: 6),
          Text(
            progress?.coverageNote ?? '正在准备章节与分块…',
            style: context.texts.bodySmall!.copyWith(fontSize: 11.5),
          ),
        ],
      ),
    );
  }

  Widget _gapBanner(BuildContext context, UnderstandingProgress progress) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
      child: AppCallout(
        tone: progress.status == BookJobStatus.failed
            ? CalloutTone.warning
            : CalloutTone.info,
        title: '教材仍有部分内容待处理',
        message: progress.coverageNote,
        action: TextButton(
          onPressed: _startUnderstanding,
          child: Text(progress.chunkReady == 0 ? '建立理解' : '继续整理'),
        ),
      ),
    );
  }

  Widget _conversation(BuildContext context) {
    if (q.loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (q.turns.isEmpty) {
      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: const EmptyState(
            compact: true,
            icon: QIcons.qa,
            title: '还没有教材问答',
            message: '可针对全书提问；开启联网时补充教材未展开的机理。',
          ),
        ),
      );
    }
    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      itemCount: q.turns.length,
      itemBuilder: (context, index) {
        final turn = q.turns[q.turns.length - 1 - index];
        return Padding(
          padding: const EdgeInsets.only(bottom: Space.md),
          child: _turnCard(context, turn),
        );
      },
    );
  }

  Widget _turnCard(BuildContext context, BookQaTurn turn) {
    final colors = context.colors;
    final isLast = q.turns.isNotEmpty && q.turns.last.id == turn.id;
    final answer = turn.answer;
    return Container(
      padding: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.outline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 340),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: colors.surfaceRaised,
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: SelectableText(
                  turn.question,
                  style: context.texts.bodyMedium!.copyWith(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    height: 1.55,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (answer != null)
            _answerBody(context, turn, answer)
          else if (turn.failure != null)
            AppCallout(
              tone: CalloutTone.error,
              message: turn.failure!,
              action: TextButton(
                onPressed: () {
                  _question.text = turn.question;
                  _question.selection = TextSelection.collapsed(
                    offset: _question.text.length,
                  );
                  setState(() {});
                },
                child: const Text('重新编辑'),
              ),
            )
          else if (turn.cancelled)
            AppCallout(tone: CalloutTone.info, message: '已取消这次问答，问题已保留。')
          else
            _pending(context, isLast),
        ],
      ),
    );
  }

  Widget _pending(BuildContext context, bool isLast) {
    final active = isLast ? q.stage : BookQaStage.idle;
    const steps = [
      BookQaStage.retrievingBook,
      BookQaStage.searchingWeb,
      BookQaStage.readingWeb,
      BookQaStage.composing,
    ];
    final activeIndex = steps.indexOf(active);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var index = 0; index < steps.length; index++)
              AppBadge(
                label: steps[index].label,
                dense: true,
                tone: index < activeIndex
                    ? BadgeTone.green
                    : index == activeIndex
                    ? BadgeTone.violet
                    : BadgeTone.neutral,
              ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 1.8),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${active == BookQaStage.idle ? '准备中' : active.label}…',
                style: context.texts.bodySmall,
              ),
            ),
            if (isLast && q.asking)
              TextButton(onPressed: q.cancelAsk, child: const Text('停止')),
          ],
        ),
      ],
    );
  }

  Widget _answerBody(
    BuildContext context,
    BookQaTurn turn,
    BookQaAnswer answer,
  ) {
    final colors = context.colors;
    final citedBookIds = {
      for (final block in answer.blocks) ...block.bookCitationIds,
    };
    final citedWebIds = {
      for (final block in answer.blocks) ...block.webCitationIds,
    };
    final citedBook = answer.bookSources
        .where((source) => citedBookIds.contains(source.id))
        .toList();
    final citedWeb = answer.webSources
        .where((source) => citedWebIds.contains(source.id))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            AppBadge(
              label: answer.answerStatus.label,
              dense: true,
              tone: switch (answer.answerStatus) {
                AnswerStatus.answered => BadgeTone.green,
                AnswerStatus.partial => BadgeTone.warm,
                AnswerStatus.needsClarification => BadgeTone.blue,
              },
            ),
            AppBadge(
              label: answer.webStatus.label,
              dense: true,
              tone: switch (answer.webStatus) {
                WebLookupStatus.searched => BadgeTone.blue,
                WebLookupStatus.cached => BadgeTone.violet,
                WebLookupStatus.failed => BadgeTone.danger,
                WebLookupStatus.disabled ||
                WebLookupStatus.notNeeded => BadgeTone.neutral,
              },
            ),
            Text(
              answer.coverage.scope,
              style: context.texts.bodySmall!.copyWith(fontSize: 11.5),
            ),
          ],
        ),
        const SizedBox(height: 10),
        for (final block in answer.blocks) ...[
          if (block.supplemental)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: AppBadge(
                label: '解释与补充',
                dense: true,
                tone: BadgeTone.warm,
              ),
            ),
          SelectableText(
            block.text,
            style: context.texts.bodyMedium!.copyWith(
              fontSize: 14.5,
              color: colors.ink,
              height: 1.72,
            ),
          ),
          if (block.bookCitationIds.isNotEmpty ||
              block.webCitationIds.isNotEmpty) ...[
            const SizedBox(height: 7),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final id in block.bookCitationIds)
                  if (_bookSource(answer, id) case final source?)
                    ActionChip(
                      avatar: const QIcon(QIcons.textbook, size: IconSizes.sm),
                      label: Text('第 ${source.page} 页'),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => widget.onJump(source.evidence),
                    ),
                for (final id in block.webCitationIds)
                  if (_webSource(answer, id) case final source?)
                    ActionChip(
                      avatar: const QIcon(QIcons.web, size: IconSizes.sm),
                      label: Text('$id · ${source.host}'),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _openUrl(source.url),
                    ),
              ],
            ),
          ],
          const SizedBox(height: Space.md),
        ],
        if (answer.webNote.trim().isNotEmpty) ...[
          Text(
            answer.webNote,
            style: context.texts.bodySmall!.copyWith(
              fontSize: 11.5,
              height: 1.5,
            ),
          ),
          const SizedBox(height: Space.sm),
        ],
        if (answer.missingInformation.isNotEmpty) ...[
          AppCallout(
            tone: CalloutTone.info,
            title: '还需要确认',
            message: answer.missingInformation.join('；'),
          ),
          const SizedBox(height: Space.sm),
        ],
        if (answer.rejectedCitationIds.isNotEmpty) ...[
          AppCallout(
            tone: CalloutTone.warning,
            message:
                '${answer.rejectedCitationIds.length} 个引用编号不在本次证据中，已隐藏链接；请回看原文。',
          ),
          const SizedBox(height: Space.sm),
        ],
        if (citedBook.isNotEmpty) ...[
          Text(
            '教材出处',
            style: context.texts.titleSmall!.copyWith(fontSize: 12.5),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final source in citedBook)
                ActionChip(
                  avatar: QIcon(
                    QIcons.external,
                    size: IconSizes.sm,
                    color: colors.inkMuted,
                  ),
                  label: Text(
                    source.chapterTitle.isEmpty
                        ? '第 ${source.page} 页'
                        : '${source.chapterTitle} · 第 ${source.page} 页',
                  ),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => widget.onJump(source.evidence),
                ),
            ],
          ),
          const SizedBox(height: Space.sm),
        ] else if (answer.bookSources.isNotEmpty) ...[
          Text(
            '已检索 ${answer.bookSources.length} 段原文，回答未直接引用具体片段，请回看原页核对。',
            style: context.texts.bodySmall!.copyWith(fontSize: 11.5),
          ),
          const SizedBox(height: Space.sm),
        ],
        if (citedWeb.isNotEmpty) ...[
          _WebSources(sources: citedWeb, onOpen: _openUrl),
          const SizedBox(height: Space.sm),
        ] else if (answer.webSources.isNotEmpty) ...[
          Text(
            '已读取 ${answer.webSources.length} 个网页，回答未直接引用链接。',
            style: context.texts.bodySmall!.copyWith(fontSize: 11.5),
          ),
          const SizedBox(height: Space.sm),
        ],
        const TrustNote(
          '引用编号仅标识来源，请点开原页核对结论。',
          icon: QIcons.verify,
        ),
        const SizedBox(height: Space.sm),
        Row(
          children: [
            Expanded(
              child: Text(
                '${answer.model} · '
                '${answer.usage.totalTokens > 0 ? '${answer.usage.totalTokens} token' : '服务商未返回用量'}'
                '${answer.usage.searchRequests > 0 ? ' · 搜索 ${answer.usage.searchRequests} 次' : ''}'
                '${answer.usage.fetchRequests > 0 ? ' · 读取 ${answer.usage.fetchRequests} 次' : ''}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.texts.bodySmall!.copyWith(
                  fontSize: 11.5,
                  fontFeatures: AppNumerals.tabular,
                ),
              ),
            ),
            IconButton(
              tooltip: '用这段生成复习题',
              onPressed: () {
                final doc = widget.study.current;
                final page = citedBook.isNotEmpty
                    ? citedBook.first.page
                    : widget.study.page;
                showCreateOrEditReviewItemDialog(
                  context,
                  study: widget.study,
                  initialObjective: doc?.title ?? '教材问答难点',
                  initialPrompt: turn.question,
                  initialAnswer: answer.plainText,
                  origin: ReviewOrigin(
                    id: '',
                    itemId: '',
                    originKey: 'book_qa:${doc?.id ?? 'none'}:$page',
                    sourceType: 'book_qa',
                    documentId: doc?.id,
                    documentHash: doc?.contentHash ?? '',
                    documentTitle: doc?.title ?? '',
                    page: page,
                    snapshotText: answer.plainText,
                  ),
                );
              },
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              icon: const QIcon(QIcons.review, size: IconSizes.sm),
            ),
            IconButton(
              tooltip: '复制回答',
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: answer.plainText));
                _message('回答已复制。');
              },
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              icon: const QIcon(QIcons.copy, size: IconSizes.sm),
            ),
          ],
        ),
        if (turn.cancelled)
          Text(
            '（这次问答被取消，但已返回的内容保留）',
            style: context.texts.bodySmall!.copyWith(fontSize: 11),
          ),
      ],
    );
  }

  BookCitation? _bookSource(BookQaAnswer answer, String id) {
    for (final source in answer.bookSources) {
      if (source.id == id) return source;
    }
    return null;
  }

  WebCitation? _webSource(BookQaAnswer answer, String id) {
    for (final source in answer.webSources) {
      if (source.id == id) return source;
    }
    return null;
  }

  Widget _composer(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.outline)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppSegmentedControl(
            expand: true,
            dense: true,
            segments: [
              for (final mode in BookAskMode.values)
                AppSegment(label: mode.label),
            ],
            selectedIndex: _mode.index,
            onChanged: q.asking
                ? (_) {}
                : (index) => setState(() => _mode = BookAskMode.values[index]),
          ),
          const SizedBox(height: 8),
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
                    ): _send,
                  },
                  child: TextField(
                    controller: _question,
                    minLines: 2,
                    maxLines: 5,
                    maxLength: 2000,
                    enabled: !q.asking && !_preparing,
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
                      hintText: '问这本教材，例如：为什么聚合物多以头尾键连为主？',
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
                      Expanded(
                        child: Text(
                          _mode.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: context.texts.bodySmall!.copyWith(
                            fontSize: 11.5,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (widget.study.selection != null && !q.asking)
                        IconButton(
                          tooltip: '问这张图',
                          onPressed: _preparing ? null : _askImage,
                          visualDensity: VisualDensity.compact,
                          icon: const QIcon(QIcons.region, size: IconSizes.md),
                        ),
                      if (q.asking) ...[
                        Text(
                          q.stage.label.isEmpty ? '处理中' : '${q.stage.label}…',
                          style: context.texts.bodySmall!.copyWith(
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(width: 6),
                        OutlinedButton(
                          onPressed: q.cancelAsk,
                          child: const Text('停止'),
                        ),
                      ] else
                        FilledButton.icon(
                          onPressed:
                              q.asking ||
                                  _preparing ||
                                  _question.text.trim().isEmpty
                              ? null
                              : _send,
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(0, 36),
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                          ),
                          icon: const QIcon(
                            QIcons.send,
                            size: IconSizes.sm,
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
    );
  }
}

class _WebSources extends StatefulWidget {
  const _WebSources({required this.sources, required this.onOpen});

  final List<WebCitation> sources;
  final Future<void> Function(String url) onOpen;

  @override
  State<_WebSources> createState() => _WebSourcesState();
}

class _WebSourcesState extends State<_WebSources> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(Radii.sm),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Text(
                  '网络参考 · ${widget.sources.length}',
                  style: context.texts.titleSmall!.copyWith(fontSize: 12.5),
                ),
                const SizedBox(width: 4),
                QIcon(
                  _expanded ? QIcons.chevronUp : QIcons.chevronDown,
                  size: IconSizes.sm,
                  color: colors.inkMuted,
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          for (final source in widget.sources) ...[
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 6),
              padding: const EdgeInsets.all(Space.md),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(Radii.sm),
                border: Border.all(color: colors.outline),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    source.title.isEmpty ? source.url : source.title,
                    style: context.texts.bodySmall!.copyWith(
                      fontSize: 12.5,
                      color: colors.ink,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    [
                      source.host,
                      source.statusLabel,
                      if ((source.publishedAt ?? '').isNotEmpty)
                        _date(source.publishedAt!),
                    ].join(' · '),
                    style: context.texts.bodySmall!.copyWith(fontSize: 11),
                  ),
                  const SizedBox(height: 4),
                  SelectableText(
                    source.url,
                    maxLines: 2,
                    style: context.texts.bodySmall!.copyWith(
                      fontSize: 11,
                      color: colors.inkMuted,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: () => widget.onOpen(source.url),
                        icon: const QIcon(QIcons.external, size: IconSizes.sm),
                        label: const Text('打开来源'),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: '复制链接',
                        visualDensity: VisualDensity.compact,
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: source.url),
                          );
                        },
                        icon: const QIcon(QIcons.link, size: IconSizes.sm),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
      ],
    );
  }

  static String _date(String value) =>
      value.length >= 10 ? value.substring(0, 10) : value;
}
