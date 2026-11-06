import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_controller.dart';
import '../../core/models.dart';
import '../../services/ai_gateway.dart';
import '../theme/tokens.dart';
import '../widgets/app_close_button.dart';
import '../widgets/app_dialog.dart';
import '../widgets/app_surfaces.dart';

Future<DocumentKind?> showImportKindDialog(BuildContext context) {
  return showAppDialog<DocumentKind>(
    context: context,
    builder: (context) => AppDialog(
      title: '导入资料',
      maxWidth: 420,
      actions: const [],
      content: const Column(
        children: [
          _ImportOption(
            icon: Icons.menu_book_outlined,
            title: '教材自学',
            description: '按节阅读与练习',
            kind: DocumentKind.textbook,
          ),
          _ImportOption(
            icon: Icons.article_outlined,
            title: '论文精读',
            description: '按页阅读与摘录',
            kind: DocumentKind.paper,
          ),
        ],
      ),
    ),
  );
}

class _ImportOption extends StatelessWidget {
  const _ImportOption({
    required this.icon,
    required this.title,
    required this.description,
    required this.kind,
  });

  final IconData icon;
  final String title;
  final String description;
  final DocumentKind kind;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: () => Navigator.pop(context, kind),
      hoverColor: c.sidebar,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.outline)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: c.inkMuted),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: context.texts.bodyMedium!.copyWith(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: context.texts.bodySmall!.copyWith(fontSize: 11),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 16, color: c.inkMuted),
          ],
        ),
      ),
    );
  }
}

Future<int?> showJumpPageDialog(
  BuildContext context, {
  required int current,
  required int pageCount,
}) => showAppDialog<int>(
  context: context,
  builder: (context) => _JumpPageDialog(current: current, pageCount: pageCount),
);

class _JumpPageDialog extends StatefulWidget {
  const _JumpPageDialog({required this.current, required this.pageCount});

  final int current;
  final int pageCount;

  @override
  State<_JumpPageDialog> createState() => _JumpPageDialogState();
}

class _JumpPageDialogState extends State<_JumpPageDialog> {
  late final _input = TextEditingController(text: '${widget.current}');
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _submit() {
    final page = int.tryParse(_input.text.trim());
    if (page == null || page < 1 || page > widget.pageCount) {
      setState(() => _error = '请输入 1–${widget.pageCount} 之间的页码');
      return;
    }
    Navigator.pop(context, page);
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    title: '跳转页码',
    subtitle: '共 ${widget.pageCount} 页。',
    maxWidth: 420,
    actions: [
      DialogActions.cancel(context),
      FilledButton(onPressed: _submit, child: const Text('跳转')),
    ],
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const DialogFieldLabel('页码'),
        TextField(
          controller: _input,
          autofocus: true,
          enableInteractiveSelection: false,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            hintText: '1–${widget.pageCount}',
            errorText: _error,
          ),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          onSubmitted: (_) => _submit(),
        ),
      ],
    ),
  );
}

Future<String?> showCorrectTextDialog(
  BuildContext context, {
  required String text,
  required int page,
}) => showAppDialog<String>(
  context: context,
  barrierDismissible: false,
  builder: (context) => _CorrectTextDialog(text: text, page: page),
);

class _CorrectTextDialog extends StatefulWidget {
  const _CorrectTextDialog({required this.text, required this.page});

  final String text;
  final int page;

  @override
  State<_CorrectTextDialog> createState() => _CorrectTextDialogState();
}

class _CorrectTextDialogState extends State<_CorrectTextDialog> {
  late final _input = TextEditingController(text: widget.text);

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    title: '校正文字',
    subtitle: '第 ${widget.page} 页。',
    icon: Icons.edit_note_rounded,
    accent: context.colors.blueAccent,
    maxWidth: 720,
    actions: [
      DialogActions.cancel(context),
      FilledButton(
        onPressed: () => Navigator.pop(context, _input.text),
        child: const Text('保存并更新索引'),
      ),
    ],
    content: TextField(
      controller: _input,
      minLines: 10,
      maxLines: 18,
      autocorrect: false,
      decoration: const InputDecoration(
        hintText: '按原页校对文字。',
        alignLabelWithHint: true,
      ),
    ),
  );
}

class NoteDraft {
  const NoteDraft({required this.understanding, required this.question});
  final String understanding;
  final String question;
}

Future<NoteDraft?> showNoteDialog(
  BuildContext context, {
  required int page,
  required bool hasSelection,
}) => showAppDialog<NoteDraft>(
  context: context,
  builder: (context) => _NoteDialog(page: page, hasSelection: hasSelection),
);

class _NoteDialog extends StatefulWidget {
  const _NoteDialog({required this.page, required this.hasSelection});

  final int page;
  final bool hasSelection;

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  final _understanding = TextEditingController();
  final _question = TextEditingController();

  @override
  void dispose() {
    _understanding.dispose();
    _question.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppDialog(
      title: '新建笔记',
      subtitle: '第 ${widget.page} 页 · ${widget.hasSelection ? '当前选区' : '当前整页'}',
      maxWidth: 420,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const DialogFieldLabel('我的理解'),
          TextField(
            controller: _understanding,
            minLines: 3,
            maxLines: 7,
            maxLength: 4000,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '写下你的理解。',
              counterText: '',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: Space.md),
          const DialogFieldLabel('待解决的问题（可选）'),
          TextField(
            controller: _question,
            minLines: 2,
            maxLines: 4,
            maxLength: 2000,
            decoration: const InputDecoration(counterText: ''),
          ),
          const SizedBox(height: Space.sm),
          Text(
            '会引用${widget.hasSelection ? '选区' : '整页'}原文。',
            style: context.texts.bodySmall!.copyWith(color: c.inkMuted),
          ),
        ],
      ),
      actions: [
        DialogActions.cancel(context),
        FilledButton(
          onPressed: _understanding.text.trim().isEmpty
              ? null
              : () => Navigator.pop(
                  context,
                  NoteDraft(
                    understanding: _understanding.text.trim(),
                    question: _question.text.trim(),
                  ),
                ),
          child: const Text('保存笔记'),
        ),
      ],
    );
  }
}

Future<bool> showDeleteDocumentDialog(
  BuildContext context, {
  required String title,
}) async {
  final result = await showAppDialog<bool>(
    context: context,
    builder: (context) {
      final c = context.colors;
      return AppDialog(
        title: '删除资料？',
        subtitle: '「$title」',
        icon: Icons.delete_outline_rounded,
        accent: AppAccent(color: c.danger, tint: c.dangerTint),
        maxWidth: 520,
        content: const DialogBodyText('将删除索引、笔记、问答与练习；外部原件不受影响。'),
        actions: [
          DialogActions.cancel(context),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: c.danger,
              foregroundColor: c.isDark
                  ? const Color(0xFF3A1410)
                  : Colors.white,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除资料'),
          ),
        ],
      );
    },
  );
  return result ?? false;
}

Future<void> showSearchDialog(
  BuildContext context, {
  required StudyController controller,
}) => showAppDialog<void>(
  context: context,
  builder: (context) => _SearchDialog(controller: controller),
);

class _SearchDialog extends StatefulWidget {
  const _SearchDialog({required this.controller});

  final StudyController controller;

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  List<Evidence> _results = const [];
  bool _searched = false;

  void _search(String query) {
    final document = widget.controller.current;
    setState(() {
      _searched = query.trim().isNotEmpty;
      _results = document == null || query.trim().isEmpty
          ? const []
          : widget.controller.store.searchEvidence(
              query,
              documentId: document.id,
              limit: 30,
            );
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppDialog(
      title: '查找原文',
      maxWidth: 520,
      showHeader: false,
      scrollContent: false,
      contentPadding: EdgeInsets.zero,
      actions: const [],
      content: SizedBox(
        height: 420,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
              child: Row(
                children: [
                  Icon(Icons.search_rounded, size: 20, color: c.inkMuted),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      autofocus: true,
                      onChanged: _search,
                      style: context.texts.bodyMedium!.copyWith(fontSize: 15),
                      decoration: const InputDecoration(
                        hintText: '查找原文',
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        errorBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        isDense: true,
                      ),
                    ),
                  ),
                  const KeyHint('Esc'),
                  AppCloseButton(size: 44, iconSize: 24),
                ],
              ),
            ),
            if (_searched && _results.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                  child: Text(
                    '找到 ${_results.length} 段原文',
                    style: context.texts.bodySmall!.copyWith(
                      fontFeatures: AppNumerals.tabular,
                    ),
                  ),
                ),
              ),
            Expanded(
              child: !_searched
                  ? Center(
                      child: EmptyState(
                        compact: true,
                        icon: Icons.manage_search_rounded,
                        title: '输入关键词',
                        message: '检索本篇文字。',
                      ),
                    )
                  : _results.isEmpty
                  ? Center(
                      child: EmptyState(
                        compact: true,
                        icon: Icons.search_off_rounded,
                        title: '没有匹配结果',
                        message: '换个词试试。',
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      itemCount: _results.length,
                      separatorBuilder: (_, _) =>
                          Divider(height: 1, color: c.outline),
                      itemBuilder: (context, index) {
                        final result = _results[index];
                        return _SearchResultTile(
                          result: result,
                          onTap: () {
                            Navigator.pop(context);
                            widget.controller.jumpToEvidence(result);
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchResultTile extends StatefulWidget {
  const _SearchResultTile({required this.result, required this.onTap});

  final Evidence result;
  final VoidCallback onTap;

  @override
  State<_SearchResultTile> createState() => _SearchResultTileState();
}

class _SearchResultTileState extends State<_SearchResultTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final origin = switch (widget.result.origin) {
      EvidenceOrigin.ocr => '识别文字',
      EvidenceOrigin.manual => '人工校正',
      EvidenceOrigin.text => '原文字层',
    };
    return Semantics(
      button: true,
      label: '第 ${widget.result.page} 页，$origin',
      child: Material(
        color: _hovered ? c.tint : Colors.transparent,
        child: InkWell(
          onTap: widget.onTap,
          onHover: (value) => setState(() => _hovered = value),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.sm,
              vertical: Space.md,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppBadge(label: '第 ${widget.result.page} 页', dense: true),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.result.text,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: context.texts.bodyMedium!.copyWith(
                          color: c.ink,
                          height: 1.55,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        origin,
                        style: context.texts.bodySmall!.copyWith(fontSize: 11),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Space.sm),
                Icon(Icons.chevron_right_rounded, size: 18, color: c.inkMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SessionDraft {
  const SessionDraft(this.start, this.end, this.goal, this.minutes);
  final int start;
  final int end;
  final String goal;
  final int minutes;
}

Future<SessionDraft?> showSessionDialog(
  BuildContext context, {
  required DocumentRecord document,
  required StudySession? previous,
  required int currentPage,
}) => showAppDialog<SessionDraft>(
  context: context,
  builder: (context) => _SessionDialog(
    document: document,
    previous: previous,
    currentPage: currentPage,
  ),
);

class _SessionDialog extends StatefulWidget {
  const _SessionDialog({
    required this.document,
    required this.previous,
    required this.currentPage,
  });

  final DocumentRecord document;
  final StudySession? previous;
  final int currentPage;

  @override
  State<_SessionDialog> createState() => _SessionDialogState();
}

class _SessionDialogState extends State<_SessionDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _start;
  late final TextEditingController _end;
  late final TextEditingController _goal;
  late final TextEditingController _minutes;

  bool get _paper => widget.document.kind == DocumentKind.paper;

  @override
  void initState() {
    super.initState();
    final previous = widget.previous;
    _start = TextEditingController(
      text: '${previous?.startPage ?? (_paper ? 1 : widget.currentPage)}',
    );
    _end = TextEditingController(
      text:
          '${previous?.endPage ?? (_paper ? widget.document.pageCount : widget.currentPage)}',
    );
    _goal = TextEditingController(text: previous?.goal ?? '');
    _minutes = TextEditingController(text: '${previous?.minutes ?? 25}');
  }

  @override
  void dispose() {
    for (final controller in [_start, _end, _goal, _minutes]) {
      controller.dispose();
    }
    super.dispose();
  }

  String? _validatePage(String? value) {
    final number = int.tryParse(value ?? '');
    return number == null || number < 1 || number > widget.document.pageCount
        ? '请输入 1–${widget.document.pageCount}'
        : null;
  }

  void _submit() {
    if (!(_form.currentState?.validate() ?? false)) return;
    final start = int.parse(_start.text);
    final end = int.parse(_end.text);
    if (end < start) return;
    final goal = _goal.text.trim();
    Navigator.pop(
      context,
      SessionDraft(
        start,
        end,
        goal.isEmpty ? '核对研究问题、论证、证据和局限' : goal,
        int.parse(_minutes.text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    title: _paper
        ? '阅读范围'
        : widget.previous == null
        ? '设置目标'
        : '编辑目标',
    subtitle: '共 ${widget.document.pageCount} 页。',
    maxWidth: 420,
    actions: [
      DialogActions.cancel(context),
      FilledButton(onPressed: _submit, child: const Text('保存')),
    ],
    content: Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const DialogFieldLabel('起始页'),
                    TextFormField(
                      controller: _start,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(hintText: '1'),
                      validator: _validatePage,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const DialogFieldLabel('结束页'),
                    TextFormField(
                      controller: _end,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(
                        hintText: '${widget.document.pageCount}',
                      ),
                      validator: (value) {
                        final error = _validatePage(value);
                        if (error != null) return error;
                        if (int.parse(value!) <
                            (int.tryParse(_start.text) ?? 1)) {
                          return '不能小于起始页';
                        }
                        return null;
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.md),
          DialogFieldLabel(_paper ? '阅读目标（可选）' : '学习目标'),
          TextFormField(
            controller: _goal,
            minLines: 3,
            maxLines: 6,
            maxLength: 1200,
            decoration: InputDecoration(
              hintText: _paper ? '例如：核对研究方法与主要证据' : '例如：分清动量与冲量',
              counterText: '',
            ),
            validator: (value) =>
                !_paper && (value?.trim().isEmpty ?? true) ? '请写下一个具体目标' : null,
          ),
          const SizedBox(height: Space.md),
          const DialogFieldLabel('预计用时（分钟）'),
          TextFormField(
            controller: _minutes,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(hintText: '25'),
            validator: (value) {
              final number = int.tryParse(value ?? '');
              return number == null || number < 1 || number > 720
                  ? '请输入 1–720 分钟'
                  : null;
            },
          ),
        ],
      ),
    ),
  );
}

Future<String?> showRequestPreview(
  BuildContext context, {
  required PreparedAiRequest request,
  required bool wholePage,
}) => showAppDialog<String>(
  context: context,
  barrierDismissible: true,
  builder: (context) => _RequestPreview(request: request, wholePage: wholePage),
);

class _RequestPreview extends StatelessWidget {
  const _RequestPreview({required this.request, required this.wholePage});

  final PreparedAiRequest request;
  final bool wholePage;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppDialog(
      title: '发送预览',
      subtitle: '以下内容将发送。',
      icon: Icons.outbound_outlined,
      accent: c.violetAccent,
      maxWidth: 700,
      contentPadding: const EdgeInsets.fromLTRB(
        Space.xl,
        Space.lg,
        Space.xl,
        Space.xl,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(context, 'send'),
          icon: const Icon(Icons.send_outlined, size: 17),
          label: const Text('发送'),
        ),
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DestinationBlock(request: request),
          const SizedBox(height: Space.lg),
          _PreviewSection(
            title: '问题',
            child: SelectableText(
              request.question,
              style: context.texts.bodyMedium!.copyWith(height: 1.65),
            ),
          ),
          if (request.learnerAnswer != null) ...[
            const SizedBox(height: Space.lg),
            _PreviewSection(
              title: '你的作答',
              child: SelectableText(
                request.learnerAnswer!,
                style: context.texts.bodyMedium!.copyWith(height: 1.65),
              ),
            ),
          ],
          if (request.history.isNotEmpty) ...[
            const SizedBox(height: Space.lg),
            _PreviewSection(
              title: '随本次发送的上下文 · ${request.history.length} 轮',
              child: SelectableText(
                request.history
                    .map((turn) => '问题：${turn.question}\n回答：${turn.answer}')
                    .join('\n\n'),
                style: context.texts.bodyMedium!.copyWith(height: 1.65),
              ),
            ),
          ],
          if (request.image != null) ...[
            const SizedBox(height: Space.lg),
            _PreviewSection(
              title: '图片 · ${request.image!.scopeLabel}',
              trailing: TextButton.icon(
                onPressed: () => Navigator.pop(context, 'scope'),
                icon: const Icon(Icons.crop_rounded, size: 16),
                label: Text(wholePage ? '切回框选区域' : '改为当前整页'),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 300),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(Radii.sm),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          border: Border.all(color: c.outline),
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
                  TrustNote('图片仅用于这次请求。', icon: Icons.visibility_outlined),
                ],
              ),
            ),
          ],
          const SizedBox(height: Space.lg),
          if (request.coverageNote != null) ...[
            _PreviewSection(
              title: '资料覆盖范围',
              child: SelectableText(request.coverageNote!),
            ),
            const SizedBox(height: Space.lg),
          ],
          _EvidenceBlock(request: request),
          const SizedBox(height: Space.lg),
          Container(
            padding: const EdgeInsets.all(Space.md),
            decoration: BoxDecoration(
              color: c.canvas,
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: c.outline),
            ),
            child: const TrustNote(
              '费用由服务商计入账户；不会自动重试。',
              icon: Icons.receipt_long_outlined,
              emphasize: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _DestinationBlock extends StatelessWidget {
  const _DestinationBlock({required this.request});

  final PreparedAiRequest request;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.tint,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.cloud_outlined, size: 16, color: c.primary),
              const SizedBox(width: 6),
              Text(
                '将发送给',
                style: context.texts.labelMedium!.copyWith(color: c.primary),
              ),
              const Spacer(),
              AppBadge(label: aiTaskLabel(request.task), dense: true),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            '${request.settings.provider} · ${request.model}',
            style: context.texts.titleSmall!.copyWith(color: c.ink),
          ),
          const SizedBox(height: 2),
          SelectableText(
            request.endpoint.toString(),
            style: context.texts.bodySmall!.copyWith(
              fontSize: 11,
              color: c.inkMuted,
              fontFeatures: AppNumerals.tabular,
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewSection extends StatelessWidget {
  const _PreviewSection({
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: context.texts.titleSmall!.copyWith(fontSize: 13),
            ),
          ),
          ?trailing,
        ],
      ),
      const SizedBox(height: 6),
      child,
    ],
  );
}

class _EvidenceBlock extends StatelessWidget {
  const _EvidenceBlock({required this.request});

  final PreparedAiRequest request;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final evidence = request.evidence;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '原文证据',
                style: context.texts.titleSmall!.copyWith(fontSize: 13),
              ),
            ),
            AppBadge(
              label: '${evidence.length} 段 / ${request.contextCharacters} 字符',
              dense: true,
            ),
          ],
        ),
        const SizedBox(height: Space.sm),
        if (evidence.isEmpty)
          AppCallout(tone: CalloutTone.warning, message: '没有可用的原文文字。')
        else
          for (final item in evidence) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(Space.md),
              decoration: BoxDecoration(
                color: c.surface,
                border: Border.all(color: c.outline),
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      AppBadge(label: '第 ${item.page} 页', dense: true),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          item.id,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.texts.bodySmall!.copyWith(
                            fontSize: 10,
                            fontFeatures: AppNumerals.tabular,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  SelectableText(
                    item.text,
                    style: context.texts.bodySmall!.copyWith(
                      color: c.ink,
                      fontSize: 12,
                      height: 1.6,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Space.sm),
          ],
      ],
    );
  }
}

String aiTaskLabel(AiTask task) => switch (task) {
  AiTask.explain => '原文提问',
  AiTask.studyPlan => '细化目标',
  AiTask.generateQuestion => '依据本节出题',
  AiTask.gradeAnswer => '核对作答',
  AiTask.paperGuide => '论文导读',
  AiTask.explainTerm => '术语解释',
  AiTask.explainImage => '图表提问',
  AiTask.searchTerms => '检索词',
};

Future<void> showShortcutsDialog(BuildContext context) => showAppDialog<void>(
  context: context,
  builder: (context) => AppDialog(
    title: '键盘快捷键',
    icon: Icons.keyboard_outlined,
    accent: context.colors.neutralAccent,
    maxWidth: 620,
    titleStyle: context.texts.bodyMedium!.copyWith(
      fontSize: 20,
      fontWeight: FontWeight.w600,
    ),
    actions: const [],
    content: const Column(
      children: [
        _ShortcutRow(label: '上一页 / 下一页', keys: '← / →, PageUp / PageDown'),
        _ShortcutRow(label: '跳转物理页', keys: 'Ctrl + G'),
        _ShortcutRow(label: '检索本篇原文', keys: 'Ctrl + F'),
        _ShortcutRow(label: '切换框选模式', keys: 'Ctrl + Shift + S'),
        _ShortcutRow(label: '缩放原页', keys: 'Ctrl + = / Ctrl + -'),
        _ShortcutRow(label: '适应窗口', keys: 'Ctrl + 0'),
        _ShortcutRow(label: '旋转显示', keys: 'Ctrl + R'),
        _ShortcutRow(label: '收起 / 展开学习面板', keys: 'Ctrl + B'),
        _ShortcutRow(label: '清除选区 / 关闭抽屉', keys: 'Esc'),
        _ShortcutRow(label: '保存作答 / 发送预览', keys: 'Ctrl + Enter'),
      ],
    ),
  ),
);

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({required this.label, required this.keys});

  final String label;
  final String keys;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: Space.sm),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            label,
            style: context.texts.bodyMedium!.copyWith(
              color: context.colors.ink,
            ),
          ),
        ),
        const SizedBox(width: Space.md),
        KeyHint(keys),
      ],
    ),
  );
}
