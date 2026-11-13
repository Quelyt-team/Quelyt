import 'package:flutter/material.dart';

import '../../../core/models.dart';
import '../../../services/file_reveal.dart';
import '../../../ui/theme/tokens.dart';
import '../../../ui/widgets/app_dialog.dart';
import '../../../ui/widgets/app_surfaces.dart';
import '../import/import_models.dart';
import '../library_controller.dart';
import '../services/library_export_service.dart';
import '../models/library_models.dart';
import 'library_style.dart';

Future<String?> showLibraryTextDialog(
  BuildContext context, {
  required String title,
  String? subtitle,
  String label = '名称',
  String initial = '',
  String? hint,
  String confirmLabel = '保存',
  String? helper,
  int maxLength = 200,
  String? Function(String value)? validate,
}) => showAppDialog<String>(
  context: context,
  builder: (context) => _TextDialog(
    title: title,
    subtitle: subtitle,
    label: label,
    initial: initial,
    hint: hint,
    confirmLabel: confirmLabel,
    helper: helper,
    maxLength: maxLength,
    validate: validate,
  ),
);

class _TextDialog extends StatefulWidget {
  const _TextDialog({
    required this.title,
    required this.label,
    required this.initial,
    required this.confirmLabel,
    required this.maxLength,
    this.subtitle,
    this.hint,
    this.helper,
    this.validate,
  });

  final String title;
  final String? subtitle;
  final String label;
  final String initial;
  final String? hint;
  final String confirmLabel;
  final String? helper;
  final int maxLength;
  final String? Function(String value)? validate;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final TextEditingController _input;
  String? _error;

  @override
  void initState() {
    super.initState();
    _input = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _input.text.trim();
    final error = widget.validate?.call(value) ??
        (value.isEmpty ? '${widget.label}不能为空。' : null);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => AppDialog(
    title: widget.title,
    subtitle: widget.subtitle,
    maxWidth: 460,
    actions: [
      DialogActions.cancel(context),
      FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
    ],
    content: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogFieldLabel(widget.label),
        TextField(
          controller: _input,
          autofocus: true,
          maxLength: widget.maxLength,
          decoration: InputDecoration(
            hintText: widget.hint,
            errorText: _error,
            counterText: '',
          ),
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          onSubmitted: (_) => _submit(),
        ),
        if (widget.helper != null) ...[
          const SizedBox(height: Space.sm),
          Text(
            widget.helper!,
            style: context.texts.bodySmall!.copyWith(fontSize: 12),
          ),
        ],
      ],
    ),
  );
}

Future<bool> showLibraryConfirmDialog(
  BuildContext context, {
  required String title,
  String? subtitle,
  required String message,
  String confirmLabel = '确定',
  bool danger = false,
  List<Widget> details = const [],
}) async {
  final result = await showAppDialog<bool>(
    context: context,
    builder: (context) {
      final colors = context.colors;
      return AppDialog(
        title: title,
        subtitle: subtitle,
        icon: danger ? QIcons.warning : QIcons.info,
        accent: danger
            ? AppAccent(color: colors.danger, tint: colors.dangerTint)
            : colors.neutralAccent,
        maxWidth: 540,
        actions: [
          DialogActions.cancel(context),
          FilledButton(
            style: danger
                ? FilledButton.styleFrom(
                    backgroundColor: colors.danger,
                    foregroundColor: colors.isDark
                        ? const Color(0xFF3A1410)
                        : Colors.white,
                  )
                : null,
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel),
          ),
        ],
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DialogBodyText(message),
            if (details.isNotEmpty) ...[
              const SizedBox(height: Space.md),
              ...details,
            ],
          ],
        ),
      );
    },
  );
  return result ?? false;
}

// -----------------------------------------------------------------------------
// Folder appearance
// -----------------------------------------------------------------------------

class FolderStyleDraft {
  const FolderStyleDraft({
    required this.colorMode,
    required this.colorValue,
    required this.icon,
    required this.description,
  });

  final FolderColorMode colorMode;
  final int? colorValue;
  final String? icon;
  final String description;
}

Future<FolderStyleDraft?> showFolderStyleDialog(
  BuildContext context, {
  required LibraryController controller,
  required LibraryFolder folder,
}) => showAppDialog<FolderStyleDraft>(
  context: context,
  builder: (context) => _FolderStyleDialog(
    controller: controller,
    folder: folder,
  ),
);

class _FolderStyleDialog extends StatefulWidget {
  const _FolderStyleDialog({required this.controller, required this.folder});

  final LibraryController controller;
  final LibraryFolder folder;

  @override
  State<_FolderStyleDialog> createState() => _FolderStyleDialogState();
}

class _FolderStyleDialogState extends State<_FolderStyleDialog> {
  late FolderColorMode _mode;
  late int? _color;
  late final TextEditingController _icon;
  late final TextEditingController _description;

  @override
  void initState() {
    super.initState();
    _mode = widget.folder.colorMode;
    _color = widget.folder.colorValue;
    _icon = TextEditingController(text: widget.folder.icon ?? '');
    _description = TextEditingController(text: widget.folder.description);
  }

  @override
  void dispose() {
    _icon.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final inherited = effectiveFolderColor(
      widget.controller,
      widget.folder.parentId,
    );
    return AppDialog(
      title: '文件夹外观',
      subtitle: widget.controller.folderPathName(widget.folder.parentId),
      maxWidth: 520,
      actions: [
        TextButton(
          onPressed: () async {
            await widget.controller.resetFolderAppearance(widget.folder.id);
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('恢复默认'),
        ),
        DialogActions.cancel(context),
        FilledButton(
          onPressed: () {
            final icon = _icon.text.trim();
            Navigator.pop(
              context,
              FolderStyleDraft(
                colorMode: _mode,
                colorValue: _mode == FolderColorMode.custom ? _color : null,
                icon: icon.isEmpty ? null : icon,
                description: _description.text.trim(),
              ),
            );
          },
          child: const Text('保存外观'),
        ),
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const DialogFieldLabel('颜色'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _ColorDot(
                color: Colors.transparent,
                label: '继承',
                selected: _mode == FolderColorMode.inherit,
                inheritedColor: inherited,
                onTap: () => setState(() {
                  _mode = FolderColorMode.inherit;
                  _color = null;
                }),
              ),
              for (final value in folderPalette)
                _ColorDot(
                  color: Color(value),
                  label: '',
                  selected: _mode == FolderColorMode.custom && _color == value,
                  onTap: () => setState(() {
                    _mode = FolderColorMode.custom;
                    _color = value;
                  }),
                ),
            ],
          ),
          const SizedBox(height: Space.md),
          Text(
            _mode == FolderColorMode.inherit
                ? inherited == null
                    ? '跟随上级；当前没有自定义颜色。'
                    : '跟随上级；当前显示为 ${_hex(inherited)}。'
                : '已单独设置 ${_color == null ? '' : _hex(_color!)}；上级改色不会覆盖这里。',
            style: context.texts.bodySmall!.copyWith(fontSize: 12),
          ),
          const SizedBox(height: Space.lg),
          const DialogFieldLabel('图标（可选，单个 emoji）'),
          TextField(
            controller: _icon,
            maxLength: 8,
            decoration: const InputDecoration(
              hintText: '例如 📘 或 🧪',
              counterText: '',
            ),
          ),
          const SizedBox(height: Space.md),
          const DialogFieldLabel('说明（可选）'),
          TextField(
            controller: _description,
            minLines: 2,
            maxLines: 4,
            maxLength: 400,
            decoration: const InputDecoration(
              hintText: '写下这个文件夹的用途。',
              counterText: '',
            ),
          ),
          const SizedBox(height: Space.sm),
          Row(
            children: [
              QIcon(QIcons.folder, size: IconSizes.sm, color: colors.inkMuted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '颜色不会成为唯一含义：绿色不代表完成，红色不代表错误。',
                  style: context.texts.bodySmall!.copyWith(fontSize: 12),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _hex(int value) =>
      '#${value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.color,
    required this.label,
    required this.selected,
    required this.onTap,
    this.inheritedColor,
  });

  final Color color;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? inheritedColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Tooltip(
      message: label.isEmpty ? color.toARGB32().toRadixString(16) : label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.full),
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: label == '继承'
                ? (inheritedColor == null
                      ? colors.surfaceRaised
                      : Color(inheritedColor!))
                : color,
            border: Border.all(
              color: selected ? colors.ink : colors.outlineStrong,
              width: selected ? 2 : 1,
            ),
          ),
          child: label == '继承'
              ? Center(
                  child: QIcon(
                    QIcons.undo,
                    size: 15,
                    color: inheritedColor == null
                        ? colors.inkMuted
                        : Colors.white,
                  ),
                )
              : null,
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Folder picker (move, shortcut, restore destination)
// -----------------------------------------------------------------------------

class FolderChoice {
  const FolderChoice.root()
    : folderId = null,
      cancelled = false;
  const FolderChoice.folder(this.folderId) : cancelled = false;
  const FolderChoice.cancel() : folderId = null, cancelled = true;

  final String? folderId;
  final bool cancelled;
}

Future<FolderChoice?> showFolderPickerDialog(
  BuildContext context, {
  required LibraryController controller,
  required String title,
  String? subtitle,
  Set<String> excludeFolderIds = const {},
  String rootLabel = '未归档（根目录）',
  String confirmLabel = '移动到这里',
}) => showAppDialog<FolderChoice>(
  context: context,
  builder: (context) => _FolderPickerDialog(
    controller: controller,
    title: title,
    subtitle: subtitle,
    excludeFolderIds: excludeFolderIds,
    rootLabel: rootLabel,
    confirmLabel: confirmLabel,
  ),
);

class _FolderPickerDialog extends StatefulWidget {
  const _FolderPickerDialog({
    required this.controller,
    required this.title,
    required this.subtitle,
    required this.excludeFolderIds,
    required this.rootLabel,
    required this.confirmLabel,
  });

  final LibraryController controller;
  final String title;
  final String? subtitle;
  final Set<String> excludeFolderIds;
  final String rootLabel;
  final String confirmLabel;

  @override
  State<_FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends State<_FolderPickerDialog> {
  String? _selected;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final rows = <Widget>[
      _PickerRow(
        label: widget.rootLabel,
        depth: 0,
        icon: QIcons.folderOpen,
        selected: _selected == null,
        onTap: () => setState(() => _selected = null),
      ),
      ..._flatten(null, 0),
    ];
    return AppDialog(
      title: widget.title,
      subtitle: widget.subtitle,
      maxWidth: 520,
      actions: [
        DialogActions.cancel(context),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            _selected == null
                ? const FolderChoice.root()
                : FolderChoice.folder(_selected),
          ),
          child: Text(widget.confirmLabel),
        ),
      ],
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 360),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final row in rows)
                DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: colors.outline),
                    ),
                  ),
                  child: row,
                ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _flatten(String? parentId, int depth) {
    final result = <Widget>[];
    for (final folder in widget.controller.childrenOf(parentId)) {
      final excluded = widget.excludeFolderIds.contains(folder.id);
      result.add(
        _PickerRow(
          label: folder.name,
          depth: depth,
          icon: QIcons.folder,
          colorValue: effectiveFolderColor(widget.controller, folder.id),
          selected: _selected == folder.id,
          disabled: excluded,
          disabledHint: '自身或子文件夹',
          onTap: excluded ? null : () => setState(() => _selected = folder.id),
        ),
      );
      if (depth < 12) result.addAll(_flatten(folder.id, depth + 1));
    }
    return result;
  }
}

class _PickerRow extends StatelessWidget {
  const _PickerRow({
    required this.label,
    required this.depth,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.colorValue,
    this.disabled = false,
    this.disabledHint,
  });

  final String label;
  final int depth;
  final QIconData icon;
  final bool selected;
  final VoidCallback? onTap;
  final int? colorValue;
  final bool disabled;
  final String? disabledHint;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Material(
      color: selected ? colors.tint : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(12 + depth * 18.0, 10, 12, 10),
          child: Row(
            children: [
              QIcon(
                icon,
                size: IconSizes.md,
                color: disabled
                    ? colors.inkMuted.withValues(alpha: .4)
                    : folderInk(context, colorValue),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.bodyMedium!.copyWith(
                    fontSize: 13.5,
                    color: disabled
                        ? colors.inkMuted.withValues(alpha: .55)
                        : colors.ink,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              if (disabledHint != null)
                Text(
                  disabledHint!,
                  style: context.texts.bodySmall!.copyWith(fontSize: 11),
                ),
              if (selected)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: QIcon(
                    QIcons.check,
                    size: IconSizes.sm,
                    color: colors.ink,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Tags
// -----------------------------------------------------------------------------

Future<Set<String>?> showTagPickerDialog(
  BuildContext context, {
  required LibraryController controller,
  required DocumentRecord document,
}) => showAppDialog<Set<String>>(
  context: context,
  builder: (context) => _TagPickerDialog(
    controller: controller,
    document: document,
  ),
);

class _TagPickerDialog extends StatefulWidget {
  const _TagPickerDialog({required this.controller, required this.document});

  final LibraryController controller;
  final DocumentRecord document;

  @override
  State<_TagPickerDialog> createState() => _TagPickerDialogState();
}

class _TagPickerDialogState extends State<_TagPickerDialog> {
  late Set<String> _selected;
  final _newTag = TextEditingController();

  @override
  void initState() {
    super.initState();
    _selected = {...?widget.controller.tagIdsByDocument[widget.document.id]};
  }

  @override
  void dispose() {
    _newTag.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final value = _newTag.text.trim();
    if (value.isEmpty) return;
    final tag = await widget.controller.createTag(value);
    if (!mounted) return;
    if (tag != null) {
      setState(() {
        _selected = {..._selected, tag.id};
        _newTag.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tags = widget.controller.tags;
    return AppDialog(
      title: '标签',
      subtitle: '「${widget.document.title}」',
      maxWidth: 480,
      actions: [
        DialogActions.cancel(context),
        FilledButton(
          onPressed: () => Navigator.pop(context, _selected),
          child: const Text('保存标签'),
        ),
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (tags.isEmpty)
            Text(
              '还没有标签。新建一个，例如“考试重点”。',
              style: context.texts.bodySmall!.copyWith(fontSize: 12),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final tag in tags)
                  FilterChip(
                    label: Text(tag.name),
                    selected: _selected.contains(tag.id),
                    onSelected: (value) => setState(() {
                      if (value) {
                        _selected = {..._selected, tag.id};
                      } else {
                        _selected = {..._selected}..remove(tag.id);
                      }
                    }),
                  ),
              ],
            ),
          const SizedBox(height: Space.lg),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _newTag,
                  maxLength: 40,
                  decoration: const InputDecoration(
                    hintText: '新标签名称',
                    counterText: '',
                  ),
                  onSubmitted: (_) => _create(),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _create,
                icon: const QIcon(QIcons.add, size: IconSizes.sm),
                label: const Text('新建'),
              ),
            ],
          ),
          const SizedBox(height: Space.sm),
          Row(
            children: [
              QIcon(QIcons.tag, size: IconSizes.sm, color: colors.inkMuted),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '标签跨文件夹共享；改名不会丢失关联。',
                  style: context.texts.bodySmall!.copyWith(fontSize: 12),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Import queue
// -----------------------------------------------------------------------------

Future<void> showImportQueueDialog(
  BuildContext context, {
  required LibraryController controller,
}) => showAppDialog<void>(
  context: context,
  builder: (context) => _ImportQueueDialog(controller: controller),
);

class _ImportQueueDialog extends StatelessWidget {
  const _ImportQueueDialog({required this.controller});

  final LibraryController controller;

  @override
  Widget build(BuildContext context) {
    final queue = controller.queue;
    return AnimatedBuilder(
      animation: queue,
      builder: (context, _) {
        final batches = queue.batches;
        final colors = context.colors;
        return AppDialog(
          title: '导入队列',
          subtitle: queue.busy
              ? '正在处理，已入库的资料可以立即阅读。'
              : '每项独立处理；失败的项目可以重试。',
          maxWidth: 720,
          scrollContent: false,
          actions: [
            if (queue.failedCount > 0)
              TextButton(
                onPressed: queue.retryFailed,
                child: const Text('重试失败项'),
              ),
            if (queue.hasPending)
              TextButton(
                onPressed: queue.cancelPending,
                child: const Text('取消剩余'),
              ),
            if (batches.any((batch) => !batch.active))
              TextButton(
                onPressed: queue.clearFinished,
                child: const Text('清理已完成记录'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
          content: SizedBox(
            height: 420,
            child: batches.isEmpty
                ? Center(
                    child: EmptyState(
                      compact: true,
                      icon: QIcons.download,
                      title: '没有导入任务',
                      message: '从右上角选择文件或文件夹开始。',
                    ),
                  )
                : ListView(
                    children: [
                      for (final batch in batches)
                        _BatchTile(
                          controller: controller,
                          batch: batch,
                          colors: colors,
                        ),
                    ],
                  ),
          ),
        );
      },
    );
  }
}

class _BatchTile extends StatelessWidget {
  const _BatchTile({
    required this.controller,
    required this.batch,
    required this.colors,
  });

  final LibraryController controller;
  final ImportBatch batch;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    final queue = controller.queue;
    return Container(
      margin: const EdgeInsets.only(bottom: Space.md),
      decoration: BoxDecoration(
        border: Border.all(color: colors.outline),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Row(
              children: [
                QIcon(QIcons.folder, size: IconSizes.sm, color: colors.inkMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    batch.rootFolderName ?? '导入文件',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.bodyMedium!.copyWith(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                AppBadge(
                  label:
                      '${batch.finished}/${batch.total} · 新 ${batch.imported} · 已有 ${batch.existing} · 失败 ${batch.failed}',
                  dense: true,
                ),
                if (!batch.active)
                  IconButton(
                    tooltip: '移除记录',
                    onPressed: () => queue.dismiss(batch),
                    icon: QIcon(
                      QIcons.close,
                      size: IconSizes.sm,
                      color: colors.inkMuted,
                    ),
                  ),
              ],
            ),
          ),
          if (batch.bytesTotal > 0)
            LinearProgressIndicator(
              value: batch.bytesTotal <= 0
                  ? null
                  : (batch.bytesDone / batch.bytesTotal).clamp(0, 1),
              minHeight: 2,
              backgroundColor: colors.tint,
            ),
          for (final item in batch.items)
            _ImportRow(item: item, onRetry: () => queue.retry(item)),
        ],
      ),
    );
  }
}

class _ImportRow extends StatelessWidget {
  const _ImportRow({required this.item, required this.onRetry});

  final ImportItem item;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final label = item.status.label;
    final failed =
        item.status == ImportItemStatus.failed ||
        item.status == ImportItemStatus.unsupported;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 7, 8, 7),
      child: Row(
        children: [
          QIcon(
            documentIcon(item.extension),
            size: IconSizes.sm,
            color: colors.inkMuted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.sourceName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.bodySmall!.copyWith(
                    fontSize: 12.5,
                    color: colors.ink,
                  ),
                ),
                if (item.message?.isNotEmpty == true)
                  Text(
                    item.message!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.texts.bodySmall!.copyWith(
                      fontSize: 11,
                      color: failed ? colors.danger : colors.inkMuted,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: context.texts.bodySmall!.copyWith(
              fontSize: 11,
              color: failed ? colors.danger : colors.inkMuted,
            ),
          ),
          if (failed)
            IconButton(
              tooltip: '重试',
              onPressed: onRetry,
              visualDensity: VisualDensity.compact,
              icon: QIcon(QIcons.refresh, size: IconSizes.sm, color: colors.inkMuted),
            ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------------------------
// Delete and purge impact
// -----------------------------------------------------------------------------

Future<bool> showTrashImpactDialog(
  BuildContext context, {
  required String title,
  required String targetLabel,
  required int entries,
  required int folders,
  required int documents,
  required int shortcuts,
}) => showLibraryConfirmDialog(
  context,
  title: title,
  subtitle: targetLabel,
  message: '移入回收站后可随时恢复，外部原文件不受影响。',
  confirmLabel: '移入回收站',
  details: [
    _ImpactRow(label: '资料', value: '$documents 份'),
    _ImpactRow(label: '文件夹', value: '$folders 个'),
    _ImpactRow(label: '入口与快捷方式', value: '$entries 项'),
    if (shortcuts > 0) _ImpactRow(label: '其中快捷方式', value: '$shortcuts 项'),
  ],
);

Future<bool> showPurgeImpactDialog(
  BuildContext context, {
  required String label,
  required LibraryPurgeImpact impact,
}) => showLibraryConfirmDialog(
  context,
  title: '永久删除？',
  subtitle: label,
  message: '不可撤销：将清理托管原件、文字索引、笔记、会话与整书问答；'
      '独立日程与学习记录仍保留。',
  confirmLabel: '永久删除',
  danger: true,
  details: [
    _ImpactRow(label: '资料', value: '${impact.documents} 份'),
    _ImpactRow(label: '文件夹', value: '${impact.folders} 个'),
    _ImpactRow(label: '笔记', value: '${impact.notes} 条'),
    _ImpactRow(label: '学习会话', value: '${impact.sessions} 条'),
    _ImpactRow(label: '日程计划材料', value: '${impact.planSources} 处'),
    _ImpactRow(label: '整书问答会话', value: '${impact.bookQa} 个'),
    _ImpactRow(label: '托管占用', value: formatSize(impact.bytes)),
  ],
);

Future<String?> showExportNameDialog(
  BuildContext context, {
  required String initial,
}) => showLibraryTextDialog(
  context,
  title: '导出为',
  label: '文件名',
  initial: initial,
  hint: '不含扩展名',
  confirmLabel: '导出',
);

Future<void> showExportReportDialog(
  BuildContext context,
  LibraryExportReport report,
) => showAppDialog<void>(
  context: context,
  builder: (context) {
    final colors = context.colors;
    return AppDialog(
      title: report.ok ? '导出完成' : '导出未全部完成',
      subtitle: report.summary,
      icon: report.ok ? QIcons.download : QIcons.warning,
      accent: report.ok
          ? colors.neutralAccent
          : AppAccent(color: colors.danger, tint: colors.dangerTint),
      maxWidth: 560,
      actions: [
        if (report.destination != null)
          TextButton(
            onPressed: () => FileReveal.open(report.destination!),
            child: const Text('打开位置'),
          ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ],
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '导出仅包含托管原件副本，不含笔记、问答与日程。',
            style: context.texts.bodySmall!.copyWith(height: 1.6),
          ),
          if (report.renamed.isNotEmpty) ...[
            const SizedBox(height: Space.lg),
            Text(
              '因重名或非法字符调整的名称',
              style: context.texts.bodySmall!.copyWith(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            for (final name in report.renamed.take(8))
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  name,
                  style: context.texts.bodySmall!.copyWith(fontSize: 11.5),
                ),
              ),
          ],
          if (report.failures.isNotEmpty) ...[
            const SizedBox(height: Space.lg),
            Text(
              '失败项',
              style: context.texts.bodySmall!.copyWith(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colors.danger,
              ),
            ),
            const SizedBox(height: 6),
            for (final failure in report.failures.take(8))
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  failure,
                  style: context.texts.bodySmall!.copyWith(
                    fontSize: 11.5,
                    color: colors.danger,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  },
);

class _ImpactRow extends StatelessWidget {
  const _ImpactRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: colors.surfaceRaised,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: context.texts.bodySmall!.copyWith(fontSize: 12.5),
            ),
          ),
          Text(
            value,
            style: context.texts.bodySmall!.copyWith(
              fontSize: 12.5,
              color: colors.ink,
              fontFeatures: AppNumerals.tabular,
            ),
          ),
        ],
      ),
    );
  }
}
