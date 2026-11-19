import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app_controller.dart';
import '../../../core/models.dart';
import '../../../services/document_service.dart';
import '../../notes/models/note_models.dart';
import '../../notes/notes_controller.dart';
import '../../notes/ui/answer_note_actions.dart';
import '../../review/models/review_models.dart';
import '../../review/ui/review_dialogs.dart';
import '../material_work.dart';
import '../paper/paper_card.dart';
import '../paper/translation_service.dart';
import '../science/solution_pdf.dart';
import 'material_work_dialog.dart';

class MaterialWorkspace extends StatefulWidget {
  const MaterialWorkspace({
    super.key,
    required this.study,
    required this.document,
    this.notes,
    this.openNote,
    this.entryId,
  });

  final StudyController study;
  final DocumentRecord document;
  final NotesController? notes;
  final ValueChanged<String>? openNote;
  final String? entryId;

  @override
  State<MaterialWorkspace> createState() => _MaterialWorkspaceState();
}

class _MaterialWorkspaceState extends State<MaterialWorkspace> {
  StudyController get study => widget.study;
  DocumentRecord get doc => widget.document;
  MaterialWork get work => study.materialWork;
  late final _start = TextEditingController(text: study.page.toString());
  late final _end = TextEditingController(text: study.page.toString());
  final _instruction = TextEditingController();
  late final _glossary = TextEditingController(
    text: work.readState(doc, 'paperGlossary') as String? ?? '',
  );
  late String _tab = doc.kind == DocumentKind.exercise
      ? 'exercise'
      : doc.kind == DocumentKind.paper
      ? 'metadata'
      : 'recognition';
  late String _language =
      work.readState(doc, 'paperLanguage') as String? ?? '简体中文';
  late PaperTranslationEngine _translation =
      PaperTranslationEngine.values.asNameMap()[work.readState(
        doc,
        'paperTranslationEngine',
      )] ??
      PaperTranslationEngine.ai;
  bool _retryUnknown = false;
  bool _busy = false;
  String? _notice;
  List<MaterialResult>? _lastBatch;
  bool _knownComplete = false;
  DocumentRecord? _export;

  @override
  void dispose() {
    _start.dispose();
    _end.dispose();
    _instruction.dispose();
    _glossary.dispose();
    super.dispose();
  }

  (int, int) _range() {
    final first = int.tryParse(_start.text.trim());
    final last = int.tryParse(_end.text.trim());
    if (first == null ||
        last == null ||
        first < 1 ||
        first > last ||
        last > doc.pageCount) {
      throw FormatException('请输入 1 至 ${doc.pageCount} 之间的有效页段。');
    }
    return (first, last);
  }

  Future<void> _execute(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _notice = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<List<MaterialResult>?> _run(PreparedMaterialWork prepared) async {
    if (!mounted) {
      await prepared.close();
      return null;
    }
    final result = await showMaterialWork(context, study, prepared);
    if (result == null || !mounted) return result;
    setState(() {
      _lastBatch = result;
      _knownComplete =
          prepared.gaps.isEmpty &&
          result.length == prepared.units.length + prepared.cached.length &&
          result.isNotEmpty &&
          result.every((item) => item.state == 'ready');
      if (prepared.gaps.isNotEmpty) {
        _notice = prepared.gaps.take(5).join('\n');
      } else if (result.length <
          prepared.units.length + prepared.cached.length) {
        _notice = '部分完成。请用同一范围继续缺项。';
      }
    });
    return result;
  }

  Future<void> _recognize({
    bool all = false,
    bool selection = false,
    bool high = false,
  }) => _execute(() async {
    final (first, last) = all
        ? (1, doc.pageCount)
        : selection
        ? (study.page, study.page)
        : _range();
    final region = selection ? study.selection : SourceRegion.fullPage;
    if (region == null) throw StateError('先在原页框选需要识别的区域。');
    await _run(
      await work.prepareRecognition(
        doc,
        study.settings,
        Iterable.generate(last - first + 1, (i) => first + i),
        region: region,
        maxSide: high ? 3200 : 2000,
        retryUnknown: _retryUnknown,
      ),
    );
  });

  Future<void> _translate({bool all = false, bool selection = false}) =>
      _execute(() async {
        final (first, last) = all
            ? (1, doc.pageCount)
            : selection
            ? (study.page, study.page)
            : _range();
        final region = selection ? study.selection : null;
        if (selection && region == null) throw StateError('先框选要翻译的正文。');
        work.saveState(doc, 'paperGlossary', _glossary.text.trim());
        work.saveState(doc, 'paperLanguage', _language);
        work.saveState(doc, 'paperTranslationEngine', _translation.name);
        final profile = _translation == PaperTranslationEngine.ai
            ? null
            : TranslationProfile(
                _translation,
                region:
                    study.store.getSetting(
                      'paperTranslator:${_translation.name}:region',
                    ) ??
                    '',
              );
        await _run(
          work.prepareTranslation(
            doc,
            study.settings,
            first,
            last,
            selection: region,
            targetLanguage: _language,
            glossary: _glossary.text.trim(),
            retryUnknown: _retryUnknown,
            profile: profile,
          ),
        );
      });

  Future<void> _configureTranslation() async {
    final key = TextEditingController();
    final setting = 'paperTranslator:${_translation.name}:region';
    final region = TextEditingController(
      text: study.store.getSetting(setting) ?? '',
    );
    try {
      final saved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(_translation.label),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: key,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '服务 API Key'),
                ),
                if (_translation == PaperTranslationEngine.azure)
                  TextField(
                    controller: region,
                    decoration: const InputDecoration(
                      labelText: 'Azure 资源区域（如 eastasia）',
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存'),
            ),
          ],
        ),
      );
      if (saved != true || !mounted) return;
      if (region.text.isNotEmpty &&
          !RegExp(r'^[a-zA-Z0-9-]{1,50}$').hasMatch(region.text.trim())) {
        setState(() => _notice = 'Azure 区域格式无效。');
        return;
      }
      await TranslationProfile(_translation).saveKey(key.text);
      study.store.setSetting(setting, region.text.trim());
      if (mounted) setState(() => _notice = '已保存翻译服务设置。');
    } catch (_) {
      if (mounted) setState(() => _notice = '系统凭据存储无法保存翻译密钥。');
    } finally {
      key.dispose();
      region.dispose();
    }
  }

  Future<void> _outline() => _execute(() async {
    await _run(
      work.prepareOutline(
        doc,
        study.settings,
        1,
        doc.pageCount,
        retryUnknown: _retryUnknown,
      ),
    );
  });

  Future<void> _solve({bool selection = false, bool command = false}) =>
      _execute(() async {
        final input = _instruction.text.trim();
        final PreparedMaterialWork prepared;
        if (selection) {
          final region = study.selection;
          final raster = study.raster;
          if (region == null || raster == null) throw StateError('先框选一道完整题目。');
          final image = await cropPage(raster, region);
          prepared = await work.preparePictureQuestion(
            document: doc,
            settings: study.settings,
            question: input.isEmpty ? '请解这道题，给出步骤、答案和核对结果。' : input,
            png: image,
            region: region,
            page: study.page,
            retryUnknown: _retryUnknown,
          );
        } else {
          final (first, last) = command ? (1, doc.pageCount) : _range();
          final questions = work.exerciseQuestions(doc, first, last);
          final numbered = questions
              .expand((q) => q.sources.map((source) => source.page))
              .toSet();
          prepared = work.prepareExercises(
            doc,
            study.settings,
            questions,
            gaps: [
              if (questions.isEmpty) '没有检测到明确题号，请先识别扫描页或框选一道题。',
              for (var page = first; page <= last; page++)
                if (!numbered.contains(page)) '第 $page 页没有可关联的题目，请核对是否缺页。',
            ],
            instruction: input,
            retryUnknown: _retryUnknown,
          );
        }
        final results = await _run(prepared);
        if (results == null || !mounted || !command) return;
        if (input.contains('错题')) {
          final selected = parseRequestedQuestionNumbers(input);
          var count = 0;
          for (final result in results) {
            if (result.hasResult &&
                selected.contains(result.data['number']?.toString())) {
              _archive(result, quiet: true);
              count++;
            }
          }
          if (mounted) setState(() => _notice = '已归档 $count 道指定错题。');
        }
        if (input.toLowerCase().contains('pdf') && _knownComplete) {
          await _writePdf(results, partial: false);
        }
      });

  void _archive(MaterialResult result, {bool quiet = false}) {
    final number = result.data['number']?.toString() ?? '';
    final label = number.isEmpty ? result.label : '第 $number 题';
    final knowledge = (result.data['knowledge'] as List?)?.join('、') ?? '';
    final draft = AnswerNoteDraft(
      answerId: result.key,
      documentId: doc.id,
      question: '${doc.title} · $label',
      label: '错题本',
      sections: [
        AnswerNoteSection(
          '**我的原答** 待补\n\n**错因** 待补'
          '${knowledge.isEmpty ? '' : '\n\n**知识点** $knowledge'}\n\n${result.text}',
          sources: [
            for (final source in result.sources)
              noteEvidence(source, title: doc.title),
          ],
        ),
      ],
    );
    final operation =
        'wrong:${doc.contentHash}:${number.isEmpty ? result.sources.firstOrNull?.id : number}';
    final note =
        widget.notes?.saveAnswer(draft, operationKey: operation) ??
        study.noteRepository.saveAnswer(draft, operationKey: operation);
    if (quiet || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('已收入错题笔记'),
        action: widget.openNote == null
            ? null
            : SnackBarAction(
                label: '打开笔记',
                onPressed: () => _openNote(note.id),
              ),
      ),
    );
  }

  Future<void> _writePdf(
    List<MaterialResult> results, {
    required bool partial,
  }) async {
    final sorted = [...results]
      ..sort((a, b) {
        final aPage = a.sources.firstOrNull?.page ?? 0;
        final bPage = b.sources.firstOrNull?.page ?? 0;
        if (aPage != bPage) return aPage.compareTo(bPage);
        final aNum = int.tryParse(a.data['number']?.toString() ?? '') ?? 0;
        final bNum = int.tryParse(b.data['number']?.toString() ?? '') ?? 0;
        return aNum.compareTo(bNum);
      });
    final pdf = await SolutionPdf(study.documents)
        .save(doc, sorted, entryId: widget.entryId, partial: partial);
    if (mounted) setState(() => _export = pdf);
  }

  Future<void> _edit(MaterialResult result, MaterialAction action) async {
    final text = TextEditingController(text: result.text);
    String? edited;
    try {
      edited = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            action == MaterialAction.translation ? '修订译文' : '修订该页的转写',
          ),
          content: SizedBox(
            width: 620,
            child: TextField(controller: text, minLines: 4, maxLines: 12),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, text.text.trim()),
              child: const Text('保存'),
            ),
          ],
        ),
      );
    } finally {
      text.dispose();
    }
    if (edited == null || edited.isEmpty || !mounted) return;
    if (result.data['translationSlot'] case final String slot
        when action == MaterialAction.translation) {
      work.saveState(doc, slot, edited);
    } else {
      final page = result.data['page'] as int?;
      final region = result.data['region'];
      if (page == null || region is! Map) return;
      final location = SourceRegion.fromJson(materialJson(region));
      if (location == SourceRegion.fullPage) {
        await study.documents.correctPage(doc, page, edited, location);
      } else {
        work.saveRecognitionCorrection(doc, page, location, edited, result.key);
      }
    }
    if (mounted) setState(() => _notice = '已保存人工修订。');
  }

  void _addReviewItem(MaterialResult item) {
    final source = item.sources.firstOrNull;
    showCreateOrEditReviewItemDialog(
      context,
      study: study,
      initialObjective: doc.title,
      initialPrompt: item.label,
      initialAnswer: item.text,
      origin: ReviewOrigin(
        id: '',
        itemId: '',
        originKey: 'exercise:${item.key}',
        sourceType: 'document',
        documentId: doc.id,
        documentHash: doc.contentHash,
        documentTitle: doc.title,
        page: source?.page ?? 1,
        snapshotText: item.text,
      ),
    );
  }

  Future<void> _jump(Evidence evidence) async {
    Navigator.pop(context);
    await study.jumpToEvidence(evidence);
  }

  void _openNote(String noteId) {
    Navigator.pop(context);
    widget.openNote?.call(noteId);
  }

  Widget _rangeField() => Row(
    children: [
      Expanded(
        child: TextField(
          controller: _start,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: '起始页'),
        ),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: TextField(
          controller: _end,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: '结束页（共 ${doc.pageCount} 页）'),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final tabs = <String, String>{
      'recognition': '识别',
      if (doc.kind == DocumentKind.exercise) 'exercise': '试题解答',
      if (doc.kind == DocumentKind.paper) ...{
        'metadata': '文献卡',
        'translation': '翻译',
        'outline': '导图',
      },
    };
    final action = MaterialAction.values.asNameMap()[_tab];
    final results = action == null
        ? <MaterialResult>[]
        : work.results(doc, action);
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(doc.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        content: SizedBox(
          width: 760,
          height: math.max(
            240,
            math.min(
              660,
              (MediaQuery.sizeOf(context).height -
                      MediaQuery.viewInsetsOf(context).bottom) *
                  .64,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final tab in tabs.entries)
                    ChoiceChip(
                      label: Text(tab.value),
                      selected: _tab == tab.key,
                      onSelected: _busy
                          ? null
                          : (_) => setState(() {
                              _tab = tab.key;
                              _lastBatch = null;
                              _knownComplete = false;
                              _notice = null;
                            }),
                    ),
                ],
              ),
              if (_busy) const LinearProgressIndicator(),
              if (_notice != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    _notice!,
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              Expanded(
                child: action == null
                    ? PaperCard(document: doc, work: work)
                    : ListView(
                        padding: const EdgeInsets.only(top: 10),
                        children: [
                          ..._actions(action, results),
                          if (results.isNotEmpty) const Divider(height: 26),
                          for (final result in results.take(600))
                            MaterialResultView(
                              study: study,
                              document: doc,
                              action: action,
                              result: result,
                              onJump: _jump,
                              notes: widget.notes,
                              openNote: widget.openNote == null
                                  ? null
                                  : _openNote,
                              onEdit: switch (action) {
                                MaterialAction.translation ||
                                MaterialAction.recognition => () => _execute(
                                  () => _edit(result, action),
                                ),
                                _ => null,
                              },
                              onArchive: action == MaterialAction.exercise
                                  ? () => _execute(() async {
                                      _archive(result);
                                    })
                                  : null,
                              onReview: action == MaterialAction.exercise
                                  ? () => _addReviewItem(result)
                                  : null,
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
        actions: [
          if (_export case final pdf?)
            FilledButton.tonal(
              onPressed: () {
                Navigator.pop(context);
                study.open(pdf);
              },
              child: const Text('打开解答 PDF'),
            ),
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  List<Widget> _actions(MaterialAction action, List<MaterialResult> results) {
    final ready = study.store
        .getPages(doc.id)
        .where((page) => page.status == PageStatus.ready)
        .length;
    final visual = results
        .where((item) => item.hasResult)
        .map((item) => item.data['page'])
        .whereType<int>()
        .toSet()
        .length;
    final output =
        _lastBatch?.where((item) => item.hasResult).toList() ??
        results.where((item) => item.hasResult).toList();
    return [
      if (action != MaterialAction.outline) _rangeField(),
      switch (action) {
        MaterialAction.recognition => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('本地可搜索 $ready / ${doc.pageCount} 页 · AI 已处理 $visual 页'),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: _busy ? null : () => _recognize(),
                  child: const Text('识别页段'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _recognize(all: true),
                  child: const Text('识别整份资料'),
                ),
                if (study.selection != null)
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => _recognize(selection: true, high: true),
                    child: const Text('高清识别选区'),
                  ),
              ],
            ),
          ],
        ),
        MaterialAction.exercise => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _instruction,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '对这份试题的要求',
                hintText: '解完这份作业，把第 3、7 题收进错题本，生成解答 PDF',
              ),
            ),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: _busy ? null : () => _solve(command: true),
                  child: const Text('处理整份作业'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _solve(),
                  child: const Text('解答页段'),
                ),
                OutlinedButton(
                  onPressed: _busy || study.selection == null
                      ? null
                      : () => _solve(selection: true),
                  child: const Text('解答选区'),
                ),
                if (output.isNotEmpty)
                  OutlinedButton(
                    onPressed: _busy
                        ? null
                        : () => _execute(
                            () => _writePdf(output, partial: !_knownComplete),
                          ),
                    child: Text(_knownComplete ? '生成解答 PDF' : '保存部分解答 PDF'),
                  ),
              ],
            ),
          ],
        ),
        MaterialAction.translation => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<PaperTranslationEngine>(
              initialValue: _translation,
              decoration: const InputDecoration(labelText: '翻译服务'),
              items: [
                for (final engine in PaperTranslationEngine.values)
                  DropdownMenuItem(value: engine, child: Text(engine.label)),
              ],
              onChanged: _busy
                  ? null
                  : (engine) => setState(() => _translation = engine!),
            ),
            if (_translation != PaperTranslationEngine.ai)
              TextButton(
                onPressed: _busy ? null : _configureTranslation,
                child: const Text('配置翻译服务'),
              ),
            DropdownButtonFormField<String>(
              initialValue: _language,
              decoration: const InputDecoration(labelText: '目标语言'),
              items: [
                for (final language in TranslationProfile.languages.keys)
                  DropdownMenuItem(value: language, child: Text(language)),
              ],
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _language = value!),
            ),
            TextField(
              controller: _glossary,
              maxLines: 3,
              minLines: 1,
              decoration: const InputDecoration(
                labelText: '论文术语表（可选）',
                hintText: '每行一个 术语=译名',
              ),
            ),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: _busy ? null : () => _translate(all: true),
                  child: const Text('翻译全文'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _translate(),
                  child: const Text('翻译页段'),
                ),
                if (study.selection != null)
                  OutlinedButton(
                    onPressed: _busy ? null : () => _translate(selection: true),
                    child: const Text('翻译选区'),
                  ),
              ],
            ),
          ],
        ),
        MaterialAction.outline => FilledButton.tonal(
          onPressed: _busy ? null : _outline,
          child: const Text('梳理论文'),
        ),
        MaterialAction.videoQuestion => const SizedBox.shrink(),
      },
      if (action == MaterialAction.exercise &&
          results.any((item) => item.hasResult))
        TextButton(
          onPressed: () {
            final item = results.firstWhere((result) => result.hasResult);
            final source = item.sources.firstOrNull;
            showCreateOrEditReviewItemDialog(
              context,
              study: study,
              initialObjective: doc.title,
              initialPrompt: item.label,
              initialAnswer: item.text,
              origin: ReviewOrigin(
                id: '',
                itemId: '',
                originKey: 'exercise:${item.key}',
                sourceType: 'document',
                documentId: doc.id,
                documentHash: doc.contentHash,
                documentTitle: doc.title,
                page: source?.page ?? 1,
                snapshotText: item.text,
              ),
            );
          },
          child: const Text('把最近一道解答加入复习'),
        ),
      if (results.any((item) => item.state == 'unknown'))
        CheckboxListTile(
          value: _retryUnknown,
          onChanged: _busy
              ? null
              : (value) => setState(() => _retryUnknown = value == true),
          title: const Text('已核对账单，允许重试受理状态未知的项'),
        ),
    ];
  }
}
