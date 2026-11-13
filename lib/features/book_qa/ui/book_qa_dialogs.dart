import 'package:flutter/material.dart';

import '../../../ui/theme/tokens.dart';
import '../../../ui/widgets/app_dialog.dart';
import '../../../ui/widgets/app_surfaces.dart';
import '../models/book_qa_models.dart';
import '../models/book_understanding.dart';
import '../services/book_qa_client.dart';
import '../services/book_understanding_service.dart';

/// One approval covers this bounded run: whole-book recall, at most two
/// searches, three page reads and one answer request. Fetched page text is not
/// known yet, so the copy says so instead of pretending it was previewed.
Future<bool> showBookQaPreview(
  BuildContext context, {
  required PreparedBookQaRequest request,
  required bool webSupported,
}) async {
  final result = await showAppDialog<bool>(
    context: context,
    builder: (context) => AppDialog(
      title: '教材问答预览',
      subtitle: '确认本轮范围后，会执行一次有上限的查找与回答。',
      icon: QIcons.study,
      accent: context.colors.violetAccent,
      maxWidth: 720,
      actions: [
        DialogActions.cancel(context),
        FilledButton.icon(
          onPressed: () => Navigator.of(context).pop(true),
          icon: const QIcon(QIcons.web, size: IconSizes.sm),
          label: Text(request.webEnabled && webSupported ? '开始查找并回答' : '开始回答'),
        ),
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Destination(request: request),
          const SizedBox(height: Space.lg),
          _KeyValue(label: '问题', value: request.question),
          const SizedBox(height: Space.md),
          _KeyValue(label: '范围', value: request.coverage.scope),
          const SizedBox(height: Space.md),
          _KeyValue(
            label: '教材文字',
            value:
                '${request.bookSources.length} 段原文，共 ${request.bookCharacters} 字符',
          ),
          const SizedBox(height: Space.sm),
          if (request.bookSources.isEmpty)
            const AppCallout(
              tone: CalloutTone.warning,
              message: '这次没有检索到直接匹配的教材原文；回答会明确标注教材依据的缺口。',
            )
          else
            for (final source in request.bookSources.take(6)) ...[
              _Excerpt(source: source),
              const SizedBox(height: Space.sm),
            ],
          if (request.bookSources.length > 6)
            Text(
              '另有 ${request.bookSources.length - 6} 段未在此展开，但仍会随请求发送。',
              style: context.texts.bodySmall!.copyWith(fontSize: 12),
            ),
          if (request.image != null) ...[
            const SizedBox(height: Space.lg),
            _KeyValue(label: '图片', value: request.image!.scopeLabel),
            const SizedBox(height: Space.sm),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(Radii.sm),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: context.colors.outline),
                    borderRadius: BorderRadius.circular(Radii.sm),
                  ),
                  child: Image.memory(
                    request.image!.bytes,
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
            const SizedBox(height: Space.sm),
            const TrustNote('图片仅用于这次请求。', icon: QIcons.visible),
          ],
          const SizedBox(height: Space.lg),
          if (request.webEnabled) ...[
            if (!webSupported) ...[
              const AppCallout(
                tone: CalloutTone.warning,
                message:
                    '未配置联网搜索（仅支持 DeepSeek 官方接口），本次仅依据教材回答。',
              ),
              const SizedBox(height: Space.md),
            ],
            _KeyValue(
              label: '搜索词',
              value: request.searchQueries.isEmpty
                  ? '无'
                  : request.searchQueries.join('；'),
            ),
            const SizedBox(height: Space.md),
            _KeyValue(
              label: '本轮上限',
              value:
                  '${request.maxSearchRequests} 次搜索 · ${request.maxFetchRequests} 次网页读取 · 1 次回答',
            ),
            const SizedBox(height: Space.sm),
            Text(
              '本轮授权覆盖检索、网页读取与总结，按次计费且不自动重试。',
              style: context.texts.bodySmall!.copyWith(
                fontSize: 12,
                height: 1.6,
              ),
            ),
          ] else
            _KeyValue(label: '联网', value: '不发送搜索请求'),
          const SizedBox(height: Space.lg),
          Container(
            padding: const EdgeInsets.all(Space.md),
            decoration: BoxDecoration(
              color: context.colors.canvas,
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: context.colors.outline),
            ),
            child: const TrustNote(
              '教材原文与网页片段将分列；按次计费，不自动重试。',
              icon: QIcons.billing,
              emphasize: true,
            ),
          ),
          const SizedBox(height: Space.sm),
          if (request.coverage.gaps.isNotEmpty)
            AppCallout(
              tone: CalloutTone.info,
              message: '仍有未完成部分：${request.coverage.gaps.take(3).join('；')}',
            ),
        ],
      ),
    ),
  );
  return result ?? false;
}

Future<bool> confirmBookUnderstanding(
  BuildContext context, {
  required String bookTitle,
  required String provider,
  required UnderstandingEstimate estimate,
  required int maxChunks,
}) async {
  final result = await showAppDialog<bool>(
    context: context,
    builder: (context) => AppDialog(
      title: '建立教材理解',
      subtitle: bookTitle,
      icon: QIcons.knowledge,
      accent: context.colors.blueAccent,
      maxWidth: 620,
      actions: [
        DialogActions.cancel(context),
        FilledButton.icon(
          onPressed: () => Navigator.of(context).pop(true),
          icon: const QIcon(QIcons.play, size: IconSizes.sm),
          label: Text('开始整理 ${estimate.pendingChunks} 个分块'),
        ),
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _KeyValue(
            label: '页面文字',
            value:
                '${estimate.pages.readyPages}/${estimate.pages.totalPages} 页可用'
                '${estimate.pages.gapLabel.isEmpty ? '' : '；未解析：${estimate.pages.gapLabel}'}',
          ),
          const SizedBox(height: Space.md),
          _KeyValue(
            label: '章节与分块',
            value:
                '${estimate.chapterCount} 章 · ${estimate.chunkCount} 块'
                '（本次处理 ${estimate.pendingChunks} 块）',
          ),
          const SizedBox(height: Space.md),
          _KeyValue(label: '模型', value: provider),
          const SizedBox(height: Space.md),
          _KeyValue(
            label: '本轮上限',
            value:
                '${estimate.pendingChunks} 次分块请求'
                '${estimate.needsOverview ? ' + 1 次全书概览' : ''}'
                '，总计最多 ${estimate.plannedRequests} 次模型请求',
          ),
          const SizedBox(height: Space.lg),
          const AppCallout(
            tone: CalloutTone.info,
            message: '按页段分批发送文本；取消后已完成分块将保留，下次继续。',
          ),
          const SizedBox(height: Space.md),
          Container(
            padding: const EdgeInsets.all(Space.md),
            decoration: BoxDecoration(
              color: context.colors.canvas,
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: context.colors.outline),
            ),
            child: const TrustNote(
              '结果存本机，摘要不作原文引用；费用由模型服务商计收。',
              icon: QIcons.local,
              emphasize: true,
            ),
          ),
        ],
      ),
    ),
  );
  return result ?? false;
}

Future<List<({String title, int startPage, int endPage})>?> showChapterEditor(
  BuildContext context, {
  required List<BookChapter> chapters,
  required int pageCount,
}) => showAppDialog<List<({String title, int startPage, int endPage})>>(
  context: context,
  builder: (context) =>
      _ChapterEditor(chapters: chapters, pageCount: pageCount),
);

class _ChapterEditor extends StatefulWidget {
  const _ChapterEditor({required this.chapters, required this.pageCount});

  final List<BookChapter> chapters;
  final int pageCount;

  @override
  State<_ChapterEditor> createState() => _ChapterEditorState();
}

class _ChapterEditorState extends State<_ChapterEditor> {
  late final List<TextEditingController> _titles;
  late final List<TextEditingController> _starts;
  String? _error;

  @override
  void initState() {
    super.initState();
    _titles = [
      for (final chapter in widget.chapters)
        TextEditingController(text: chapter.title),
    ];
    _starts = [
      for (var index = 0; index < widget.chapters.length; index++)
        TextEditingController(
          text: index == 0 ? '1' : '${widget.chapters[index].startPage}',
        ),
    ];
  }

  @override
  void dispose() {
    for (final controller in [..._titles, ..._starts]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _save() {
    final starts = <int>[1];
    for (var index = 1; index < widget.chapters.length; index++) {
      final value = int.tryParse(_starts[index].text.trim());
      if (value == null || value <= starts.last || value > widget.pageCount) {
        setState(() {
          _error =
              '第 ${index + 1} 章的起始页必须大于第 $index 章，且不超过第 ${widget.pageCount} 页。';
        });
        return;
      }
      starts.add(value);
    }
    final result = <({String title, int startPage, int endPage})>[];
    for (var index = 0; index < widget.chapters.length; index++) {
      final end = index + 1 < starts.length
          ? starts[index + 1] - 1
          : widget.pageCount;
      if (end < starts[index]) {
        setState(() => _error = '章节页段不能为空。');
        return;
      }
      final title = _titles[index].text.trim();
      result.add((
        title: title.isEmpty ? '第 ${index + 1} 章' : title,
        startPage: starts[index],
        endPage: end,
      ));
    }
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    title: '编辑章节',
    subtitle: '章节必须从第 1 页连续覆盖到最后一页；保存后会重建受影响的分块。',
    icon: QIcons.knowledge,
    accent: context.colors.blueAccent,
    maxWidth: 620,
    actions: [
      DialogActions.cancel(context),
      FilledButton(onPressed: _save, child: const Text('保存章节')),
    ],
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var index = 0; index < widget.chapters.length; index++) ...[
          Row(
            children: [
              SizedBox(
                width: 28,
                child: Text(
                  '${index + 1}',
                  style: context.texts.bodySmall!.copyWith(
                    fontFeatures: AppNumerals.tabular,
                  ),
                ),
              ),
              Expanded(
                child: TextField(
                  controller: _titles[index],
                  decoration: const InputDecoration(
                    labelText: '章节名',
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 92,
                child: TextField(
                  controller: _starts[index],
                  enabled: index > 0,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '起始页',
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.sm),
        ],
        if (_error != null)
          AppCallout(tone: CalloutTone.error, message: _error!),
      ],
    ),
  );
}

Future<List<int>?> showSkipPagesDialog(
  BuildContext context, {
  required int pageCount,
}) => showAppDialog<List<int>>(
  context: context,
  builder: (context) => _SkipPagesDialog(pageCount: pageCount),
);

class _SkipPagesDialog extends StatefulWidget {
  const _SkipPagesDialog({required this.pageCount});

  final int pageCount;

  @override
  State<_SkipPagesDialog> createState() => _SkipPagesDialogState();
}

class _SkipPagesDialogState extends State<_SkipPagesDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final pages = <int>{};
    for (final part in _controller.text.split(RegExp(r'[,，;；\s]+'))) {
      if (part.trim().isEmpty) continue;
      final match = RegExp(r'^(\d+)(?:[-–—~](\d+))?$').firstMatch(part.trim());
      if (match == null) {
        setState(() => _error = '无法识别“$part”，请写成 3 或 1-3。');
        return;
      }
      final start = int.parse(match.group(1)!);
      final end = int.tryParse(match.group(2) ?? '') ?? start;
      if (start < 1 || end > widget.pageCount || end < start) {
        setState(() => _error = '页码超出 1–${widget.pageCount} 或区间颠倒。');
        return;
      }
      for (var page = start; page <= end; page++) {
        pages.add(page);
      }
    }
    if (pages.isEmpty) {
      setState(() => _error = '请至少填写一页。');
      return;
    }
    Navigator.of(context).pop(pages.toList()..sort());
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    title: '标记空白页',
    subtitle: '封面、空白页可明确记为已处理，不再计入未解析；有正文的页不要这样标记。',
    icon: QIcons.clear,
    accent: context.colors.warmAccent,
    maxWidth: 520,
    actions: [
      DialogActions.cancel(context),
      FilledButton(onPressed: _save, child: const Text('标记')),
    ],
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _controller,
          decoration: const InputDecoration(
            labelText: '页码，例如 1, 2, 40-42',
            isDense: true,
          ),
          onSubmitted: (_) => _save(),
        ),
        if (_error != null) ...[
          const SizedBox(height: Space.md),
          AppCallout(tone: CalloutTone.error, message: _error!),
        ],
      ],
    ),
  );
}

class _Destination extends StatelessWidget {
  const _Destination({required this.request});

  final PreparedBookQaRequest request;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.tint,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(
        children: [
          QIcon(QIcons.cloud, size: IconSizes.sm, color: colors.primary),
          const SizedBox(width: 7),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${request.settings.provider} · ${request.model}',
                  style: context.texts.titleSmall!.copyWith(color: colors.ink),
                ),
                const SizedBox(height: 2),
                Text(
                  request.settings.endpoint.toString(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.bodySmall!.copyWith(
                    fontSize: 11,
                    color: colors.inkMuted,
                    fontFeatures: AppNumerals.tabular,
                  ),
                ),
              ],
            ),
          ),
          AppBadge(
            label: request.strictAuthor ? '原话核查' : request.mode.label,
            dense: true,
            tone: request.strictAuthor ? BadgeTone.warm : BadgeTone.violet,
          ),
        ],
      ),
    );
  }
}

class _KeyValue extends StatelessWidget {
  const _KeyValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 72,
        child: Text(
          label,
          style: context.texts.bodySmall!.copyWith(
            fontSize: 12,
            color: context.colors.inkMuted,
          ),
        ),
      ),
      Expanded(
        child: SelectableText(
          value,
          style: context.texts.bodyMedium!.copyWith(
            fontSize: 13.5,
            height: 1.6,
          ),
        ),
      ),
    ],
  );
}

class _Excerpt extends StatelessWidget {
  const _Excerpt({required this.source});

  final BookCitation source;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = source.evidence.text.length <= 260
        ? source.evidence.text
        : '${source.evidence.text.substring(0, 260)}…';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.outline),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppBadge(label: source.id, dense: true),
              const SizedBox(width: 6),
              Text(
                source.chapterTitle.isEmpty
                    ? '第 ${source.page} 页'
                    : '${source.chapterTitle} · 第 ${source.page} 页',
                style: context.texts.bodySmall!.copyWith(fontSize: 11.5),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            text,
            style: context.texts.bodySmall!.copyWith(
              color: colors.ink,
              fontSize: 12.5,
              height: 1.65,
            ),
          ),
        ],
      ),
    );
  }
}
