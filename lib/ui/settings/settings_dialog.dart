import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_controller.dart';
import '../../core/models.dart';
import '../../features/library/services/library_backup_service.dart';
import '../../features/library/services/library_storage_service.dart';
import '../../services/ai_gateway.dart';
import '../../services/file_reveal.dart';
import '../../services/ocr_service.dart';
import '../dialogs/app_dialogs.dart';
import '../theme/appearance.dart';
import '../theme/tokens.dart';
import '../widgets/app_close_button.dart';
import '../widgets/app_dialog.dart';
import '../widgets/app_surfaces.dart';
import '../widgets/quelyt_mark.dart';

enum SettingsSection { general, models, ocr, privacy, about }

extension SettingsSectionX on SettingsSection {
  String get label => switch (this) {
    SettingsSection.general => '通用',
    SettingsSection.models => '模型服务',
    SettingsSection.ocr => '文字识别',
    SettingsSection.privacy => '隐私与数据',
    SettingsSection.about => '关于',
  };

  QIconData get icon => switch (this) {
    SettingsSection.general => QIcons.settings,
    SettingsSection.models => QIcons.model,
    SettingsSection.ocr => QIcons.ocr,
    SettingsSection.privacy => QIcons.local,
    SettingsSection.about => QIcons.info,
  };
}

Future<void> showSettingsDialog(
  BuildContext context, {
  required StudyController controller,
  required AppearanceController appearance,
  SettingsSection initialSection = SettingsSection.general,
}) => showDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierColor: Colors.black.withValues(alpha: .42),
  builder: (context) => SettingsDialog(
    controller: controller,
    appearance: appearance,
    initialSection: initialSection,
  ),
);

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.controller,
    required this.appearance,
    this.initialSection = SettingsSection.general,
  });

  final StudyController controller;
  final AppearanceController appearance;
  final SettingsSection initialSection;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _provider;
  late final TextEditingController _url;
  late final TextEditingController _model;
  late final TextEditingController _vision;
  final _key = TextEditingController();

  late SettingsSection _section = widget.initialSection;
  late Future<OcrAvailability> _ocr;
  bool? _hasKey;
  bool? _ocrAvailable;
  bool _hidden = true;
  bool _saving = false;
  bool _testing = false;
  bool _allowClose = false;
  bool _compactDetail = false;
  String _savedKeyDraft = '';
  String? _error;
  String? _notice;

  StudyController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    final settings = c.settings;
    _provider = TextEditingController(text: settings.provider);
    _url = TextEditingController(text: settings.baseUrl);
    _model = TextEditingController(text: settings.model);
    _vision = TextEditingController(text: settings.visionModel);
    for (final controller in [_provider, _url, _model, _vision, _key]) {
      controller.addListener(_onChanged);
    }
    widget.appearance.addListener(_onAppearanceChanged);
    _loadOcr();
    _checkKey();
  }

  @override
  void dispose() {
    widget.appearance.removeListener(_onAppearanceChanged);
    for (final controller in [_provider, _url, _model, _vision, _key]) {
      controller.removeListener(_onChanged);
      controller.dispose();
    }
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _onAppearanceChanged() {
    if (mounted) setState(() {});
  }

  ProviderSettings get _settings => ProviderSettings(
    provider: _provider.text.trim(),
    baseUrl: _url.text.trim(),
    model: _model.text.trim(),
    visionModel: _vision.text.trim(),
  );

  bool get _dirty {
    final saved = c.settings;
    final current = _settings;
    return _key.text.trim().isNotEmpty &&
            _key.text.trim() != _savedKeyDraft ||
        current.provider != saved.provider ||
        current.baseUrl != saved.baseUrl ||
        current.model != saved.model ||
        current.visionModel != saved.visionModel;
  }

  String get _preset {
    final url = _url.text.trim().replaceFirst(RegExp(r'/+$'), '');
    if (url == 'https://api.deepseek.com') return 'deepseek';
    if (url.startsWith('https://dashscope.aliyuncs.com')) return 'bailian';
    return 'custom';
  }

  Future<void> _checkKey() async {
    try {
      final value = await c.gateway.readKey(_settings);
      if (mounted) setState(() => _hasKey = value?.isNotEmpty ?? false);
    } catch (_) {
      if (mounted) setState(() => _hasKey = false);
    }
  }

  void _loadOcr() {
    _ocr = c.ocr.availability();
    _ocr.then((value) {
      if (mounted) setState(() => _ocrAvailable = value.available);
    }, onError: (_) {
      if (mounted) setState(() => _ocrAvailable = false);
    });
  }

  void _applyPreset(ProviderSettings settings) {
    _provider.text = settings.provider;
    _url.text = settings.baseUrl;
    _model.text = settings.model;
    _vision.text = settings.visionModel;
    _error = null;
    _notice = null;
    _checkKey();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!(_form.currentState?.validate() ?? false)) {
      setState(() => _error = '请先修正标红的字段。');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _notice = null;
    });
    try {
      await c.saveSettings(_settings, _key.text);
      _savedKeyDraft = _key.text.trim();
      await _checkKey();
      if (mounted) {
        setState(() {
          _notice = '已保存（密钥已写入系统凭据）';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _testConnection() async {
    if (_testing || _saving) return;
    if (!(_form.currentState?.validate() ?? false)) {
      setState(() => _error = '请先修正标红的字段。');
      return;
    }
    if (!_keyDraft && _hasKey != true) {
      setState(() => _error = '请先填写并保存 API Key。');
      return;
    }
    setState(() {
      _testing = true;
      _error = null;
      _notice = null;
    });
    try {
      if (_keyDraft) {
        await c.saveSettings(_settings, _key.text);
        _savedKeyDraft = _key.text.trim();
        await _checkKey();
      }
      final result = await c.gateway.testConnection(_settings);
      if (mounted) {
        setState(
          () => _notice = '$result（已发送最小测试请求）',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = '连接测试失败：$error');
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _deleteKey() async {
    try {
      await c.gateway.deleteKey(_settings);
      _key.clear();
      _savedKeyDraft = '';
      await _checkKey();
      if (mounted) setState(() => _notice = '密钥已删除。');
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _requestClose() async {
    if (_saving) return;
    if (!_dirty) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('放弃未保存的更改？'),
        content: const Text('模型服务里还有未保存的字段。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('继续编辑'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('放弃更改'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      _allowClose = true;
      Navigator.of(context).pop();
    }
  }

  void _copyDataDirectory() {
    Clipboard.setData(ClipboardData(text: c.documents.directory.path));
    setState(() => _notice = '数据位置已复制。');
  }

  Future<void> _backupLibrary({bool includeTrash = true}) async {
    try {
      final destination = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择整库备份位置',
      );
      if (destination == null || !mounted) return;
      setState(() => _notice = '正在备份整库…');
      final report = await LibraryBackupService(
        store: c.store,
        documents: c.documents,
      ).create(destination, includeTrash: includeTrash);
      if (!mounted) return;
      setState(() => _notice = report.summary);
      await showAppDialog<void>(
        context: context,
        builder: (context) => AppDialog(
          title: '备份完成',
          subtitle: report.summary,
          icon: QIcons.archive,
          maxWidth: 560,
          actions: [
            TextButton(
              onPressed: () => FileReveal.open(report.path),
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
              SelectableText(
                report.path,
                style: context.texts.bodySmall!.copyWith(fontSize: 12),
              ),
              const SizedBox(height: Space.md),
              Text(
                '含原件与全部学习数据（不含 API Key）；'
                '${report.includeTrash ? '含回收站' : '不含回收站'}。',
                style: context.texts.bodySmall!.copyWith(height: 1.6),
              ),
              if (report.warnings.isNotEmpty) ...[
                const SizedBox(height: Space.md),
                for (final warning in report.warnings.take(8))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      warning,
                      style: context.texts.bodySmall!.copyWith(
                        fontSize: 11.5,
                        color: context.colors.danger,
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _notice = '备份失败：$error');
    }
  }

  Future<void> _showStorage() async {
    final service = LibraryStorageService(
      store: c.store,
      documents: c.documents,
    );
    LibraryStorageReport report;
    try {
      report = await service.measure();
    } catch (error) {
      if (mounted) setState(() => _notice = '无法读取存储占用：$error');
      return;
    }
    if (!mounted) return;
    final action = await showAppDialog<String>(
      context: context,
      builder: (context) => AppDialog(
        title: '存储占用',
        subtitle: '清理仅删除可重建缓存，不影响原件与数据。',
        icon: QIcons.archive,
        maxWidth: 620,
        actions: [
          if (report.rebuildableBytes > 0)
            TextButton(
              onPressed: () => Navigator.pop(context, 'cache'),
              child: const Text('清理可重建缓存'),
            ),
          if (report.hasMissingOriginals)
            TextButton(
              onPressed: () => Navigator.pop(context, 'repair'),
              child: const Text('修复缺失原件…'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context, 'close'),
            child: const Text('关闭'),
          ),
        ],
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _storageLine(context, '原件', formatBytes(report.originalsBytes)),
            _storageLine(
              context,
              '可重建缓存',
              formatBytes(report.rebuildableBytes),
            ),
            _storageLine(context, '数据库', formatBytes(report.databaseBytes)),
            _storageLine(
              context,
              '回收站中的资料',
              '${report.trashedDocuments} 份 · ${formatBytes(report.trashBytes)}',
            ),
            _storageLine(
              context,
              '合计',
              formatBytes(report.totalBytes),
              emphasized: true,
            ),
            const SizedBox(height: Space.md),
            if (report.hasMissingOriginals)
              AppCallout(
                tone: CalloutTone.warning,
                title: '${report.missingOriginals.length} 份资料缺少托管原件',
                message: '可按 SHA-256 哈希重新链接；内容不符的文件请作为新资料导入。',
              )
            else
              const TrustNote(
                '原件与数据完整。',
                icon: QIcons.local,
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'cache') {
      await _clearRebuildableCache(service);
    } else if (action == 'repair') {
      await _repairMissingOriginals(service, report.missingOriginals);
    }
  }

  Future<void> _clearRebuildableCache(LibraryStorageService service) async {
    if (c.indexing || c.sending) {
      setState(() => _notice = '请等待当前识别或请求结束，再清理缓存。');
      return;
    }
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: '清理可重建缓存？',
        maxWidth: 520,
        actions: [
          DialogActions.cancel(context),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清理'),
          ),
        ],
        content: const DialogBodyText(
          '仅删除缩略图、页面渲染与 OCR 临时文件，原件与学习数据不受影响。',
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    final freed = await service.clearRebuildableCache();
    if (!mounted) return;
    setState(() => _notice = '已清理 ${formatBytes(freed)} 可重建缓存。');
  }

  Future<void> _repairMissingOriginals(
    LibraryStorageService service,
    List<DocumentRecord> missing,
  ) async {
    if (missing.isEmpty) return;
    final proceed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: '修复缺失原件',
        subtitle: '${missing.length} 份资料缺少托管副本。',
        icon: QIcons.restore,
        maxWidth: 620,
        actions: [
          DialogActions.cancel(context),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('选择原件…'),
          ),
        ],
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final document in missing.take(8))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  document.title,
                  style: context.texts.bodySmall!.copyWith(fontSize: 12),
                ),
              ),
            if (missing.length > 8)
              Text(
                '还有 ${missing.length - 8} 份未列出。',
                style: context.texts.bodySmall!.copyWith(fontSize: 11.5),
              ),
            const SizedBox(height: Space.md),
            const TrustNote(
              '仅在 SHA-256 一致时写回。',
              icon: QIcons.verify,
            ),
          ],
        ),
      ),
    );
    if (proceed != true || !mounted) return;
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf', 'png', 'jpg', 'jpeg'],
      withData: false,
      allowMultiple: false,
      dialogTitle: '选择用于修复的原件',
    );
    final path = picked?.files.single.path;
    if (path == null || !mounted) return;
    var repaired = 0;
    String? firstError;
    for (final document in missing) {
      try {
        await service.relinkOriginal(document, path);
        repaired++;
      } catch (error) {
        firstError ??= '$error';
      }
    }
    if (!mounted) return;
    setState(() {
      _notice = repaired > 0
          ? '已按哈希重新链接 $repaired 份原件。'
          : '没有资料匹配这份文件：${firstError ?? '内容不一致'}';
    });
  }

  Widget _storageLine(
    BuildContext context,
    String label,
    String value, {
    bool emphasized = false,
  }) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    decoration: BoxDecoration(
      color: emphasized
          ? context.colors.tint
          : context.colors.surfaceRaised,
      borderRadius: BorderRadius.circular(Radii.sm),
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: context.texts.bodySmall!.copyWith(
              fontSize: 12.5,
              fontWeight: emphasized ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
        Text(
          value,
          style: context.texts.bodySmall!.copyWith(
            fontSize: 12.5,
            color: context.colors.ink,
            fontFeatures: AppNumerals.tabular,
          ),
        ),
      ],
    ),
  );
  Future<void> _restoreLibrary() async {
    try {
      final package = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择 Quelyt 备份文件夹',
      );
      if (package == null || !mounted) return;
      final validation = await LibraryBackupService.validate(package);
      if (!mounted) return;
      if (!validation.ok) {
        await showAppDialog<void>(
          context: context,
          builder: (context) => AppDialog(
            title: '这份备份不能恢复',
            icon: QIcons.warning,
            accent: AppAccent(
              color: context.colors.danger,
              tint: context.colors.dangerTint,
            ),
            maxWidth: 620,
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final error in validation.errors.take(10))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      error,
                      style: context.texts.bodySmall!.copyWith(
                        color: context.colors.danger,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
        return;
      }
      final confirmed = await showAppDialog<bool>(
        context: context,
        builder: (context) => AppDialog(
          title: '准备整库恢复？',
          subtitle: package,
          icon: QIcons.restore,
          maxWidth: 620,
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('准备恢复'),
            ),
          ],
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${validation.documents} 份资料 · 数据库版本 v${validation.schemaVersion}'
                '${validation.createdAt.isEmpty ? '' : ' · ${validation.createdAt}'}',
                style: context.texts.bodySmall!.copyWith(fontSize: 12.5),
              ),
              const SizedBox(height: Space.md),
              const TrustNote(
                '校验后将于下次启动时替换资料库；原库移至 pre-restore 目录，失败自动回滚。',
                icon: QIcons.info,
              ),
              if (validation.warnings.isNotEmpty) ...[
                const SizedBox(height: Space.sm),
                for (final warning in validation.warnings.take(6))
                  Text(
                    warning,
                    style: context.texts.bodySmall!.copyWith(
                      fontSize: 11.5,
                      color: context.colors.warm,
                    ),
                  ),
              ],
            ],
          ),
        ),
      );
      if (confirmed != true || !mounted) return;
      await LibraryBackupService.prepareRestore(
        package,
        c.documents.directory.path,
      );
      if (!mounted) return;
      setState(() => _notice = '已准备整库恢复，请重启应用生效。');
      await showAppDialog<void>(
        context: context,
        builder: (context) => AppDialog(
          title: '恢复已准备',
          icon: QIcons.restore,
          maxWidth: 520,
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('知道了'),
            ),
          ],
          content: const DialogBodyText(
            '备份已就绪。完全退出并重启 Quelyt 后生效，原库保留在 pre-restore 目录。',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _notice = '恢复准备失败：$error');
    }
  }

  Future<void> _showLastRestore() async {
    final result = await LibraryBackupService.readLastResult(
      c.documents.directory.path,
    );
    if (!mounted) return;
    await showAppDialog<void>(
      context: context,
      builder: (context) => AppDialog(
        title: '上次恢复结果',
        icon: QIcons.info,
        maxWidth: 560,
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
        content: result == null
            ? const DialogBodyText('还没有执行过整库恢复。')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DialogBodyText(
                    result['applied'] == true ? '恢复已应用。' : '恢复未应用。',
                  ),
                  if (result['error'] != null) ...[
                    const SizedBox(height: Space.sm),
                    Text(
                      '${result['error']}',
                      style: context.texts.bodySmall!.copyWith(
                        color: context.colors.danger,
                      ),
                    ),
                  ],
                  if (result['backupPath'] != null) ...[
                    const SizedBox(height: Space.md),
                    SelectableText(
                      '备份：${result['backupPath']}',
                      style: context.texts.bodySmall!.copyWith(fontSize: 11.5),
                    ),
                  ],
                  if (result['preRestorePath'] != null)
                    SelectableText(
                      '恢复前原库：${result['preRestorePath']}',
                      style: context.texts.bodySmall!.copyWith(fontSize: 11.5),
                    ),
                ],
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final compact = size.width < 720;
    return PopScope(
      canPop: _allowClose || !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _requestClose();
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.comma, control: true):
              _requestClose,
          const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
            if (_section == SettingsSection.models) _save();
          },
        },
        child: compact
            ? _compactPanel(context, size)
            : _desktopPanel(context, size),
      ),
    );
  }

  Widget _desktopPanel(BuildContext context, Size size) {
    final width = math.min(800.0, size.width - 48);
    final height = math.min(800.0, size.height - 48);
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      backgroundColor: context.colors.surface,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
        side: BorderSide(color: context.colors.outline),
      ),
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          children: [
            _header(context, compact: false),
            Divider(height: 1, color: context.colors.outline),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 232, child: _nav(context)),
                  VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: context.colors.outline,
                  ),
                  Expanded(child: _content(context, compact: false)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _compactPanel(BuildContext context, Size size) {
    return Dialog(
      insetPadding: EdgeInsets.zero,
      backgroundColor: context.colors.surface,
      surfaceTintColor: Colors.transparent,
      clipBehavior: Clip.antiAlias,
      shape: const RoundedRectangleBorder(),
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: SafeArea(
          child: Column(
            children: [
              _header(context, compact: true),
              Divider(height: 1, color: context.colors.outline),
              Expanded(
                child: _compactDetail
                    ? _content(context, compact: true)
                    : _compactNav(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context, {required bool compact}) {
    final detail = compact && _compactDetail;
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.only(left: 8, right: 8),
        child: Row(
          children: [
            if (detail)
              IconButton(
                tooltip: '返回设置分区',
                onPressed: () => setState(() => _compactDetail = false),
                icon: const QIcon(QIcons.back, size: IconSizes.md),
              )
            else
              const SizedBox(width: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                detail ? _section.label : '设置',
                style: context.texts.titleMedium!.copyWith(fontSize: 17),
              ),
            ),
            AppCloseButton(
              tooltip: '关闭设置',
              onPressed: _requestClose,
            ),
          ],
        ),
      ),
    );
  }

  Widget _nav(BuildContext context) {
    final c = context.colors;
    return ColoredBox(
      color: c.sidebar,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 14),
        children: [
          for (final item in SettingsSection.values) ...[
            _NavItem(
              item: item,
              selected: item == _section,
              status: _statusFor(item),
              onTap: () => setState(() {
                _section = item;
                _error = null;
                _notice = null;
              }),
            ),
            const SizedBox(height: 2),
          ],
        ],
      ),
    );
  }

  Widget _compactNav(BuildContext context) {
    final c = context.colors;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        for (final item in SettingsSection.values) ...[
          Semantics(
            button: true,
            label: item.label,
            child: InkWell(
              onTap: () => setState(() {
                _section = item;
                _compactDetail = true;
                _error = null;
                _notice = null;
              }),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                height: 54,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  border: Border(bottom: BorderSide(color: c.outline)),
                ),
                child: Row(
                  children: [
                    QIcon(item.icon, size: IconSizes.md, color: c.inkMuted),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        item.label,
                        style: context.texts.bodyMedium!.copyWith(fontSize: 14.5),
                      ),
                    ),
                    if (_statusFor(item) != null)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _StatusDot(tone: _statusFor(item)!),
                      ),
                    QIcon(
                      QIcons.chevronRight,
                      size: IconSizes.md,
                      color: c.inkMuted,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  bool get _keyDraft => _key.text.trim().isNotEmpty;

  _NavStatus? _statusFor(SettingsSection section) => switch (section) {
    SettingsSection.models when _hasKey == false && !_keyDraft =>
      _NavStatus.warning,
    SettingsSection.ocr when _ocrAvailable == false => _NavStatus.danger,
    _ => null,
  };

  Widget _content(BuildContext context, {required bool compact}) {
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              compact ? 20 : 28,
              22,
              compact ? 20 : 28,
              28,
            ),
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: _sectionBody(context),
              ),
            ),
          ),
        ),
        _footer(context, compact: compact),
      ],
    );
  }

  Widget _footer(BuildContext context, {required bool compact}) {
    final c = context.colors;
    final isModels = _section == SettingsSection.models;
    final isGeneral = _section == SettingsSection.general;
    final status = _error ??
        (_saving
            ? '保存中…'
            : isModels
            ? (_dirty ? '有未保存的更改' : (_notice ?? '已保存'))
            : (_notice ?? (isGeneral ? '更改会立即保存' : '只读信息')));
    return Container(
      height: 56,
      padding: EdgeInsets.symmetric(horizontal: compact ? 20 : 24),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.outline)),
      ),
      child: Row(
        children: [
          QIcon(
            _error != null
                ? QIcons.error
                : _dirty && isModels
                ? QIcons.edit
                : QIcons.success,
            size: IconSizes.sm,
            color: _error != null ? c.danger : c.inkMuted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.texts.bodySmall!.copyWith(
                fontSize: 12.5,
                color: _error != null ? c.danger : c.inkMuted,
              ),
            ),
          ),
          if (isModels) ...[
            FilledButton(
              onPressed: _saving || !_dirty ? null : _save,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
              child: Text(_saving ? '保存中…' : '保存更改'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _sectionBody(BuildContext context) => switch (_section) {
    SettingsSection.general => _generalPage(context),
    SettingsSection.models => _modelsPage(context),
    SettingsSection.ocr => _ocrPage(context),
    SettingsSection.privacy => _privacyPage(context),
    SettingsSection.about => _aboutPage(context),
  };

  Widget _generalPage(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(
          context,
          '通用',
          '仅作用于本机，改动立即生效。',
        ),
        _row(
          context,
          '界面主题',
          control: AppSegmentedControl(
            expand: true,
            segments: const [
              AppSegment(label: '跟随系统'),
              AppSegment(label: '浅色'),
              AppSegment(label: '深色'),
            ],
            selectedIndex: switch (widget.appearance.themeMode) {
              ThemeMode.light => 1,
              ThemeMode.dark => 2,
              ThemeMode.system => 0,
            },
            onChanged: (index) =>
                widget.appearance.setThemeMode(switch (index) {
                  1 => ThemeMode.light,
                  2 => ThemeMode.dark,
                  _ => ThemeMode.system,
                }),
          ),
        ),
        _row(
          context,
          '原页色调',
          description: '仅调整显示，不改选区与坐标。',
          control: AppSegmentedControl(
            expand: true,
            segments: const [
              AppSegment(label: '原色'),
              AppSegment(label: '护眼'),
              AppSegment(label: '反色'),
            ],
            selectedIndex: switch (widget.appearance.pageTone) {
              PageTone.normal => 0,
              PageTone.sepia => 1,
              PageTone.inverted => 2,
            },
            onChanged: (index) => widget.appearance.setPageTone(switch (index) {
              1 => PageTone.sepia,
              2 => PageTone.inverted,
              _ => PageTone.normal,
            }),
          ),
        ),
        _row(
          context,
          '阅读器手势提示',
          description: widget.appearance.readerHintSeen
              ? '首次进入阅读器的提示已经显示过。'
              : '下次进入阅读器时会显示提示。',
          control: OutlinedButton(
            onPressed: widget.appearance.readerHintSeen
                ? () => widget.appearance.resetReaderHint()
                : null,
            child: const Text('重新显示'),
          ),
        ),
        _row(
          context,
          '键盘快捷键',
          control: TextButton(
            onPressed: () => showShortcutsDialog(context),
            child: const Text('打开速查'),
          ),
        ),
      ],
    );
  }

  Widget _modelsPage(BuildContext context) {
    final c = context.colors;
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _sectionHeader(
            context,
            '模型服务',
            '兼容 Chat Completions 接口；密钥只进系统凭据。',
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                _StatusDot(
                  tone: _hasKey == false && !_keyDraft
                      ? _NavStatus.warning
                      : _NavStatus.ok,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _hasKey == false && !_keyDraft
                        ? '尚未配置 API Key'
                        : '已配置模型服务',
                    style: context.texts.bodySmall!.copyWith(
                      fontSize: 13,
                      color: c.ink,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Text(
                  _provider.text.trim().isEmpty ? '未命名' : _provider.text.trim(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.bodySmall!.copyWith(fontSize: 12.5),
                ),
              ],
            ),
          ),
          _row(
            context,
            '服务商预设',
            description: '切换预设覆盖地址与模型，保留已填 Key。',
            control: AppSegmentedControl(
              expand: true,
              segments: const [
                AppSegment(label: 'DeepSeek'),
                AppSegment(label: '百炼'),
                AppSegment(label: '自定义'),
              ],
              selectedIndex: switch (_preset) {
                'bailian' => 1,
                'custom' => 2,
                _ => 0,
              },
              onChanged: (index) {
                if (index == 1) {
                  _applyPreset(ProviderSettings.bailian());
                } else if (index == 2) {
                  _applyPreset(
                    const ProviderSettings(
                      provider: '自定义',
                      baseUrl: '',
                      model: '',
                    ),
                  );
                } else {
                  _applyPreset(ProviderSettings.deepSeek());
                }
              },
            ),
          ),
          _row(
            context,
            '服务商名称',
            control: TextFormField(
              controller: _provider,
              decoration: const InputDecoration(hintText: 'DeepSeek'),
              validator: (value) =>
                  value!.trim().isEmpty ? '请填写服务商名称' : null,
            ),
          ),
          _row(
            context,
            '接口地址',
            description: '基础地址或完整端点（仅 HTTPS）。',
            control: TextFormField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                hintText: 'https://api.example.com/v1',
              ),
              validator: (_) {
                try {
                  _settings.endpoint;
                  return null;
                } catch (error) {
                  return error.toString();
                }
              },
            ),
          ),
          _row(
            context,
            '文本模型',
            description: '用于阅读问答与核对。',
            control: TextFormField(
              controller: _model,
              decoration: const InputDecoration(hintText: 'deepseek-chat'),
              validator: (value) =>
                  value!.trim().isEmpty ? '请填写模型名称' : null,
            ),
          ),
          _row(
            context,
            '视觉模型',
            description: '用于图片问答；可留空。',
            control: TextFormField(
              controller: _vision,
              decoration: const InputDecoration(hintText: '可选'),
            ),
          ),
          _row(
            context,
            'API Key',
            description: _hasKey == true
                ? '已存系统凭据；测试连接将发送最小请求。'
                : '保存后输入框清空；可点“测试连接”验证。',
            action: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_hasKey == true || _keyDraft)
                  TextButton(
                    onPressed: _saving || _testing ? null : _testConnection,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 26),
                      padding: EdgeInsets.zero,
                      textStyle: context.texts.bodySmall!.copyWith(
                        fontSize: 12,
                      ),
                    ),
                    child: Text(_testing ? '测试中…' : '测试连接'),
                  ),
                if (_hasKey == true) ...[
                  const SizedBox(width: 10),
                  TextButton(
                    onPressed: _saving || _testing ? null : _deleteKey,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 26),
                      padding: EdgeInsets.zero,
                      textStyle: context.texts.bodySmall!.copyWith(
                        fontSize: 12,
                      ),
                    ),
                    child: const Text('删除密钥'),
                  ),
                ],
              ],
            ),
            control: TextFormField(
              controller: _key,
              obscureText: _hidden,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                hintText: _hasKey == true ? '已保存；留空继续使用' : 'sk-…',
                suffixIcon: IconButton(
                  tooltip: _hidden ? '显示密钥' : '隐藏密钥',
                  onPressed: () => setState(() => _hidden = !_hidden),
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(
                    minWidth: 34,
                    minHeight: 34,
                  ),
                  icon: QIcon(
                    _hidden ? QIcons.visible : QIcons.hidden,
                    size: IconSizes.sm,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _ocrPage(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(
          context,
          '文字识别',
          '扫描页本地离线识别；公式与表格建议对照原图。',
        ),
        FutureBuilder<OcrAvailability>(
          future: _ocr,
          builder: (context, snapshot) {
            final status = snapshot.data;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _row(
                  context,
                  '本地 OCR',
                  description: status == null
                      ? '正在检查识别引擎…'
                      : status.message.isEmpty
                      ? '中英文识别在设备本地完成。'
                      : status.message,
                  control: status == null
                      ? const SkeletonBlock(width: 180, height: 28)
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Flexible(
                              child: AppBadge(
                                label: status.available ? '可用' : '不可用',
                                tone: status.available
                                    ? BadgeTone.neutral
                                    : BadgeTone.danger,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                status.backend,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: context.texts.bodySmall!.copyWith(
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
                _row(
                  context,
                  '重新检查',
                  description: '切换设备或识别组件后可手动刷新。',
                  control: OutlinedButton.icon(
                    onPressed: () {
                      setState(() {
                        _ocrAvailable = null;
                        _loadOcr();
                      });
                    },
                    icon: const QIcon(QIcons.refresh, size: IconSizes.sm),
                    label: const Text('检查引擎'),
                  ),
                ),
              ],
            );
          },
        ),
        TrustNote(
          '识别全程本地；调用 AI 前会先预览发送内容。',
        ),
      ],
    );
  }

  Widget _privacyPage(BuildContext context) {
    const items = [
      ('发送前预览', '发送前展示服务商、模型、问题与原文片段。'),
      ('图片单次授权', '每张图片单独预览并单次授权。'),
      ('不自动重试', '超时或失败均不自动重发。'),
      ('数据存储', '原件、索引与数据均留在本机，无同步服务器。'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(context, '隐私与数据', '数据全程本地，AI 请求须先确认。'),
        for (final item in items) _infoRow(context, item.$1, item.$2),
        _row(
          context,
          '数据目录',
          description: c.documents.directory.path,
          control: OutlinedButton(
            onPressed: _copyDataDirectory,
            child: const Text('复制路径'),
          ),
        ),
        _row(
          context,
          '整库备份',
          description: '含原件、数据库与全部学习数据（不含 API Key），默认含回收站。',
          control: Column(
            children: [
              OutlinedButton.icon(
                onPressed: () => _backupLibrary(),
                icon: const QIcon(QIcons.archive, size: IconSizes.sm),
                label: const Text('选择位置并备份'),
              ),
              TextButton(
                onPressed: () => _backupLibrary(includeTrash: false),
                child: const Text('备份但不含回收站'),
              ),
            ],
          ),
        ),
        _row(
          context,
          '整库恢复',
          description: '校验后于下次启动时替换；原库移至 pre-restore，失败自动回滚。',
          control: OutlinedButton.icon(
            onPressed: _restoreLibrary,
            icon: const QIcon(QIcons.restore, size: IconSizes.sm),
            label: const Text('选择备份并准备恢复'),
          ),
        ),
        _row(
          context,
          '存储与原件修复',
          description: '查看占用、清理缓存或按哈希重新链接缺失原件。',
          control: OutlinedButton.icon(
            onPressed: _showStorage,
            icon: const QIcon(QIcons.archive, size: IconSizes.sm),
            label: const Text('查看占用与修复'),
          ),
        ),
        _row(
          context,
          '上次恢复结果',
          description: '查看应用状态、失败原因与原库位置。',
          control: TextButton(
            onPressed: _showLastRestore,
            child: const Text('查看'),
          ),
        ),
      ],
    );
  }

  Widget _aboutPage(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sectionHeader(context, '关于', '教材自学与论文精读客户端。'),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Row(
            children: [
              const QuelytMark(size: 36, compact: true, semanticLabel: null),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Quelyt 0.2.0-dev',
                    style: context.texts.titleSmall!.copyWith(fontSize: 16),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Baseline 3 · 本机优先',
                    style: context.texts.bodySmall!.copyWith(fontSize: 12.5),
                  ),
                ],
              ),
            ],
          ),
        ),
        _row(
          context,
          '键盘快捷键',
          control: TextButton(
            onPressed: () => showShortcutsDialog(context),
            child: const Text('打开速查'),
          ),
        ),
        _row(
          context,
          '开源许可',
          description: 'Flutter、PDFium、Tesseract 与字体许可。',
          control: OutlinedButton(
            onPressed: () => showLicensePage(
              context: context,
              applicationName: 'Quelyt',
              applicationVersion: '0.2.0-dev',
              applicationIcon: const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: QuelytMark(size: 40, tile: true),
              ),
              applicationLegalese: '教材自学与论文精读客户端',
            ),
            child: const Text('查看许可'),
          ),
        ),
        _row(
          context,
          '数据目录',
          description: c.documents.directory.path,
          control: TextButton(
            onPressed: _copyDataDirectory,
            child: const Text('复制路径'),
          ),
        ),
      ],
    );
  }

  Widget _sectionHeader(BuildContext context, String title, String detail) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.outline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: context.texts.titleMedium!.copyWith(fontSize: 18),
          ),
          const SizedBox(height: 4),
          Text(
            detail,
            style: context.texts.bodySmall!.copyWith(height: 1.55),
          ),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    String label, {
    String? description,
    required Widget control,
    Widget? action,
  }) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 440;
      final left = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: context.texts.bodySmall!.copyWith(
              fontSize: 14,
              color: context.colors.ink,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (description != null) ...[
            const SizedBox(height: 4),
            Text(
              description,
              style: context.texts.bodySmall!.copyWith(
                fontSize: 12.5,
                height: 1.5,
              ),
            ),
          ],
          if (action != null) ...[const SizedBox(height: 3), action],
        ],
      );
      final right = ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: SizedBox(width: double.infinity, child: control),
      );
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: context.colors.outline.withValues(alpha: .7),
            ),
          ),
        ),
        child: wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(flex: 44, child: left),
                  const SizedBox(width: 20),
                  Expanded(flex: 56, child: right),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [left, const SizedBox(height: 10), right],
              ),
      );
    },
  );

  Widget _infoRow(BuildContext context, String label, String detail) =>
      LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 440;
          final labelWidget = Text(
            label,
            style: context.texts.bodySmall!.copyWith(
              fontSize: 14,
              color: context.colors.ink,
              fontWeight: FontWeight.w500,
            ),
          );
          final detailWidget = Text(
            detail,
            style: context.texts.bodySmall!.copyWith(fontSize: 12.5, height: 1.5),
          );
          return Container(
            padding: const EdgeInsets.symmetric(vertical: 13),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: context.colors.outline.withValues(alpha: .7),
                ),
              ),
            ),
            child: wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 150, child: labelWidget),
                      const SizedBox(width: 20),
                      Expanded(child: detailWidget),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      labelWidget,
                      const SizedBox(height: 4),
                      detailWidget,
                    ],
                  ),
          );
        },
      );
}

class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.item,
    required this.selected,
    required this.onTap,
    this.status,
  });

  final SettingsSection item;
  final bool selected;
  final VoidCallback onTap;
  final _NavStatus? status;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: widget.item.label,
      child: InkWell(
        onTap: widget.onTap,
        onHover: (value) => setState(() => _hovered = value),
        borderRadius: BorderRadius.circular(8),
        hoverColor: Colors.transparent,
        child: AnimatedContainer(
          duration: context.motion(Motion.fast),
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: widget.selected
                ? c.tint
                : (_hovered ? c.tint.withValues(alpha: .5) : null),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              QIcon(
                widget.item.icon,
                size: IconSizes.md,
                color: widget.selected ? c.ink : c.inkMuted,
                active: widget.selected,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.item.label,
                  style: context.texts.bodyMedium!.copyWith(
                    fontSize: 14,
                    color: widget.selected ? c.ink : c.inkMuted,
                    fontWeight: widget.selected
                        ? FontWeight.w600
                        : FontWeight.w500,
                  ),
                ),
              ),
              if (widget.status != null) _StatusDot(tone: widget.status!),
            ],
          ),
        ),
      ),
    );
  }
}

enum _NavStatus { ok, warning, danger }

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.tone});

  final _NavStatus tone;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = switch (tone) {
      _NavStatus.ok => c.inkMuted.withValues(alpha: .5),
      _NavStatus.warning => const Color(0xFFD97706),
      _NavStatus.danger => c.danger,
    };
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
