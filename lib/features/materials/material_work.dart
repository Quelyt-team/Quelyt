import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../core/local_store.dart';
import '../../core/models.dart';
import '../../core/page_evidence_layout.dart';
import '../../services/ai_gateway.dart';
import '../../services/ai_transport.dart';
import '../../services/document_service.dart';
import 'material_work_models.dart';
import 'material_work_templates.dart';
import 'paper/translation_service.dart';

export 'material_work_models.dart';

class PreparedMaterialWork {
  PreparedMaterialWork._({
    required this.document,
    required this.action,
    required this.settings,
    required this.model,
    required List<MaterialUnit> units,
    required List<MaterialResult> cached,
    required List<String> gaps,
    this.scratch,
    this.translation,
  }) : units = List.unmodifiable(units),
       cached = List.unmodifiable(cached),
       gaps = List.unmodifiable(gaps);

  final DocumentRecord document;
  final MaterialAction action;
  final ProviderSettings settings;
  final String model;
  final List<MaterialUnit> units;
  final List<MaterialResult> cached;
  final List<String> gaps;
  final Directory? scratch;
  final TranslationWire? translation;
  bool _approved = false;
  bool _started = false;
  bool _closed = false;

  int get estimatedTokens =>
      units.fold(0, (total, unit) => total + unit.inputBudget + outputReserve);
  int get outputReserve => translation == null ? action.maxOutput : 0;
  String get billingUnit => translation == null ? 'token' : '字符';
  Uri get destination => translation?.endpoint ?? settings.endpoint;

  void approve() {
    if (_started || _closed) throw StateError('请重新预览任务。');
    _approved = true;
  }

  Future<void> close() async {
    _closed = true;
    final folder = scratch;
    if (folder != null && await folder.exists()) {
      await folder.delete(recursive: true);
    }
  }
}

class MaterialWork {
  MaterialWork({
    required this.store,
    required this.documents,
    required this.transport,
  });

  final LocalStore store;
  final DocumentService documents;
  final AiTransport transport;
  bool _busy = false;
  bool get busy => _busy;
  static const _scope = 'document_id=? AND document_hash=? AND task=?';

  void recoverInterrupted() {
    store.executeSql(
      "UPDATE material_items SET state='unknown', issue=? WHERE state='running'",
      ['上次退出时服务商受理状态未知。核对账单后可选择重新提交。'],
    );
  }

  List<Object?> _parameters(DocumentRecord document, MaterialAction action) => [
    document.id,
    document.contentHash,
    action.name,
  ];

  List<MaterialResult> results(
    DocumentRecord document,
    MaterialAction action,
  ) => store
      .selectRows(
        'SELECT * FROM material_items WHERE $_scope ORDER BY updated_at DESC, item_key',
        _parameters(document, action),
      )
      .map(MaterialResult.fromRow)
      .toList();

  Object? readState(DocumentRecord document, String slot) {
    final rows = store.selectRows(
      'SELECT data FROM material_state WHERE document_id=? AND document_hash=? AND slot=?',
      [document.id, document.contentHash, slot],
    );
    return rows.isEmpty ? null : jsonDecode(rows.single['data'] as String);
  }

  void saveState(DocumentRecord document, String slot, Object? data) {
    _requireActive(document);
    store.executeSql(
      '''INSERT INTO material_state VALUES (?,?,?,?,?)
      ON CONFLICT(document_id, document_hash, slot) DO UPDATE
      SET data=excluded.data, updated_at=excluded.updated_at''',
      [
        document.id,
        document.contentHash,
        slot,
        jsonEncode(data),
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  void _requireActive(DocumentRecord document) {
    final expected = store.getDocument(document.id);
    if (expected == null ||
        !expected.isActive ||
        expected.contentHash != document.contentHash ||
        expected.lifecycleVersion != document.lifecycleVersion) {
      throw StateError('资料状态或版本已改变，请重新打开。');
    }
  }

  String _model(ProviderSettings settings, {required bool image}) {
    final model = image ? settings.effectiveVisionModel : settings.model.trim();
    if (model.isEmpty) {
      throw const AiFailure(AiError.invalidSettings, '请在模型设置中配置对应的文本或视觉模型。');
    }
    settings.endpoint;
    return model;
  }

  String _key(
    DocumentRecord document,
    MaterialAction action,
    ProviderSettings settings,
    String model,
    Object request,
  ) => materialDigest([
    document.contentHash,
    document.slideRenderer,
    action.templateVersion,
    settings.endpoint.toString(),
    model,
    request,
  ]);

  bool _reuse(
    String key,
    Map<String, MaterialResult> history,
    List<MaterialResult> ready,
    List<String> gaps,
    String label, {
    required bool retryUnknown,
  }) {
    final old = history[key];
    if (old?.hasResult == true) {
      ready.add(old!);
      return true;
    }
    if (old != null &&
        !retryUnknown &&
        const {'unknown', 'running'}.contains(old.state)) {
      gaps.add('$label：上次受理状态未知，等待核对后重试');
      return true;
    }
    return false;
  }

  Map<String, MaterialResult> _history(
    DocumentRecord doc,
    MaterialAction action,
  ) => {for (final item in results(doc, action)) item.key: item};

  Evidence _source(
    DocumentRecord doc,
    int page,
    SourceRegion region,
    String text, {
    int? timeMs,
    String? label,
  }) => Evidence(
    id: materialDigest([doc.contentHash, page, timeMs, region.toJson(), text]),
    documentId: doc.id,
    documentHash: doc.contentHash,
    page: page,
    region: region,
    text: text,
    timeMs: timeMs,
    locatorLabel: label ?? (doc.isSlides ? '幻灯片 $page' : '第 $page 页'),
  );

  MaterialUnit _unit({
    required String key,
    required String label,
    required Map<String, dynamic> payload,
    required List<Evidence> sources,
    required ProviderSettings settings,
    required MaterialAction action,
    MaterialImage? image,
    ProtectedTranslation? protection,
    String? translationSlot,
  }) {
    final request = jsonEncode(payload);
    return MaterialUnit(
      key: key,
      label: label,
      requestText: request,
      sources: sources,
      image: image,
      protectedText: protection,
      translationSlot: translationSlot,
      inputBudget:
          utf8.encode(request).length +
          utf8.encode(materialInstructions(action)).length +
          (image == null
              ? 0
              : settings.endpoint.host == 'api.deepseek.com'
              ? 1024
              : 4096) +
          128,
    );
  }

  Future<PreparedMaterialWork> prepareRecognition(
    DocumentRecord doc,
    ProviderSettings settings,
    Iterable<int> pages, {
    SourceRegion region = SourceRegion.fullPage,
    int maxSide = 2000,
    bool retryUnknown = false,
  }) async {
    _requireActive(doc);
    final action = MaterialAction.recognition;
    final model = _model(settings, image: true);
    final history = _history(doc, action);
    final ready = <MaterialResult>[];
    final gaps = <String>[];
    final units = <MaterialUnit>[];
    Directory? scratch;
    OpenDocument? opened;
    try {
      for (final page in pages.toSet()) {
        if (page < 1 || page > doc.pageCount) throw RangeError('页面超出资料范围。');
        final source = _source(doc, page, region, '');
        final label = source.locatorLabel!;
        final payload = {
          'template': action.templateVersion,
          'page': page,
          'scope': region == SourceRegion.fullPage ? '整页' : '框选',
          'coordinate_system': 'top-left, normalized to this image',
        };
        final key = _key(doc, action, settings, model, [
          page,
          region.toJson(),
          maxSide,
          'original-orientation-png',
          payload,
        ]);
        if (_reuse(
          key,
          history,
          ready,
          gaps,
          label,
          retryUnknown: retryUnknown,
        )) {
          continue;
        }
        opened ??= await documents.open(doc);
        scratch ??= await _scratch();
        final raster = await opened.render(page, maxSide: maxSide);
        final bytes = region == SourceRegion.fullPage
            ? raster.bytes
            : await cropPage(raster, region);
        final image = await _prepareImage(
          scratch,
          bytes,
          '$label · ${payload['scope']}',
        );
        units.add(
          _unit(
            key: key,
            label: label,
            payload: payload,
            sources: [source],
            settings: settings,
            action: action,
            image: image,
          ),
        );
      }
      return PreparedMaterialWork._(
        document: doc,
        action: action,
        settings: settings,
        model: model,
        units: units,
        cached: ready,
        gaps: gaps,
        scratch: scratch,
      );
    } catch (_) {
      if (scratch != null && await scratch.exists()) {
        await scratch.delete(recursive: true);
      }
      rethrow;
    } finally {
      await opened?.dispose();
    }
  }

  Future<PreparedMaterialWork> preparePictureQuestion({
    required DocumentRecord document,
    required ProviderSettings settings,
    required String question,
    required Uint8List png,
    required SourceRegion region,
    int? timeMs,
    int page = 1,
    bool retryUnknown = false,
  }) async {
    _requireActive(document);
    final action = timeMs == null
        ? MaterialAction.exercise
        : MaterialAction.videoQuestion;
    final model = _model(settings, image: true);
    final title = timeMs == null
        ? '框选题目'
        : '暂停画面 ${formatMaterialTime(timeMs)}';
    final trimmed = question.trim();
    if (trimmed.isEmpty || trimmed.length > 3000) {
      throw const FormatException('请填写具体问题，限 3000 字。');
    }
    final source = _source(
      document,
      page,
      region,
      '',
      timeMs: timeMs,
      label: timeMs == null ? '第 $page 页 · 框选题目' : title,
    );
    final payload = {
      'template': action.templateVersion,
      'question': trimmed,
      'location': source.locatorLabel,
    };
    final key = _key(document, action, settings, model, [
      page,
      timeMs,
      region.toJson(),
      sha256.convert(png).toString(),
      payload,
    ]);
    final cached = <MaterialResult>[];
    final gaps = <String>[];
    final units = <MaterialUnit>[];
    Directory? scratch;
    try {
      if (!_reuse(
        key,
        _history(document, action),
        cached,
        gaps,
        title,
        retryUnknown: retryUnknown,
      )) {
        scratch = await _scratch();
        final image = await _prepareImage(scratch, png, source.locatorLabel!);
        units.add(
          _unit(
            key: key,
            label: trimmed,
            payload: payload,
            sources: [source],
            settings: settings,
            action: action,
            image: image,
          ),
        );
      }
      return PreparedMaterialWork._(
        document: document,
        action: action,
        settings: settings,
        model: model,
        units: units,
        cached: cached,
        gaps: gaps,
        scratch: scratch,
      );
    } catch (_) {
      if (scratch != null && await scratch.exists()) {
        await scratch.delete(recursive: true);
      }
      rethrow;
    }
  }

  Future<Directory> _scratch() async {
    final root = Directory(p.join(documents.directory.path, 'cache'));
    await root.create(recursive: true);
    return root.createTemp('material-preview-');
  }

  Future<MaterialImage> _prepareImage(
    Directory dir,
    Uint8List bytes,
    String label,
  ) async {
    final image = ImageAttachment(
      bytes: bytes,
      mimeType: 'image/png',
      scopeLabel: label,
    );
    final file = File(p.join(dir.path, '${image.digest}.png'));
    if (!await file.exists()) await file.writeAsBytes(bytes, flush: true);
    return MaterialImage(file, image.digest, label);
  }

  Future<String> keepSnapshot(Uint8List bytes) async {
    final name = 'material-${sha256.convert(bytes)}.png';
    final root = Directory(p.join(documents.directory.path, 'review_assets'));
    await root.create(recursive: true);
    final permanent = File(p.join(root.path, name));
    if (!await permanent.exists()) {
      final temp = await root.createTemp('snapshot-');
      try {
        final file = await File(p.join(temp.path, name))
            .writeAsBytes(bytes, flush: true);
        if (!await permanent.exists()) await file.rename(permanent.path);
      } finally {
        if (await temp.exists()) await temp.delete(recursive: true);
      }
    }
    return name;
  }

  List<Evidence> paragraphs(
    DocumentRecord doc,
    int first,
    int last, {
    SourceRegion? region,
  }) {
    RangeError.checkValueInInterval(first, 1, doc.pageCount);
    RangeError.checkValueInInterval(last, first, doc.pageCount);
    final all = <Evidence>[];
    for (var page = first; page <= last; page++) {
      final localPage = store.getPage(doc.id, page);
      final raw = store.getEvidence(doc.id, page: page);
      final visual = raw
          .where((e) => e.origin == EvidenceOrigin.vision)
          .toList();
      var selected = localPage?.manuallyCorrected == true && region == null
          ? [_source(doc, page, SourceRegion.fullPage, localPage!.text)]
          : PageEvidenceLayout(
              raw.where((e) => e.origin != EvidenceOrigin.vision),
            ).lines;
      if (visual.isNotEmpty && localPage?.manuallyCorrected != true) {
        selected = [
          for (final line in selected)
            if (!visual.any((block) => _contains(block.region, line.region)))
              line,
          ...visual,
        ]..sort((a, b) => a.region.top.compareTo(b.region.top));
      }
      for (final item in selected) {
        if (item.text.trim().isEmpty ||
            (region != null && !_contains(region, item.region))) {
          continue;
        }
        final text = item.text.trim();
        final fragments = text.runes.toList();
        for (var start = 0; start < fragments.length; start += 1100) {
          all.add(
            item.copyWith(
              id: '${item.id}:$start',
              text: String.fromCharCodes(fragments.skip(start).take(1100)),
              locatorLabel: doc.isSlides ? '幻灯片 $page' : '第 $page 页',
            ),
          );
        }
      }
    }
    return all;
  }

  static bool _contains(SourceRegion outer, SourceRegion inner) =>
      outer.left <= inner.left &&
      outer.top <= inner.top &&
      outer.right >= inner.right &&
      outer.bottom >= inner.bottom;

  List<ExerciseQuestion> exerciseQuestions(
    DocumentRecord doc,
    int start,
    int end,
  ) {
    final explicitEntry = RegExp(
      r'^\s*(?:(?:第\s*(\d+)\s*题)|(?:(?:习题|题目|例题?|Q(?:uestion)?)\s*(\d{1,3})))\s*[:：.．、)）]?\s*(.*)',
      caseSensitive: false,
    );
    final dotOrCommaEntry = RegExp(
      r'^\s*(\d{1,3})\s*[.．、](?!\d)\s*(.*)',
    );
    final parenEntry = RegExp(
      r'^\s*(\d{1,3})\s*[)）](?!\d)\s*(.*)',
    );
    final result = <ExerciseQuestion>[];
    String? number;
    String? activeStyle; // 'explicit' | 'dot' | 'paren'
    final buffer = <Evidence>[];
    void finish() {
      if (number != null && buffer.isNotEmpty) {
        result.add(
          ExerciseQuestion(
            number,
            buffer.map((e) => e.text).join('\n'),
            List.of(buffer),
          ),
        );
      }
      buffer.clear();
    }

    for (final segment in paragraphs(doc, start, end)) {
      for (final line
          in segment.text.split('\n').where((line) => line.trim().isNotEmpty)) {
        String? matchedNumber;
        String? matchedStyle;
        final explicit = explicitEntry.firstMatch(line);
        if (explicit != null) {
          matchedNumber = explicit[1] ?? explicit[2];
          matchedStyle = 'explicit';
        } else {
          final dotted = dotOrCommaEntry.firstMatch(line);
          if (dotted != null) {
            matchedNumber = dotted[1];
            matchedStyle = 'dot';
          } else {
            final paren = parenEntry.firstMatch(line);
            if (paren != null) {
              // Inside a question numbered with "第 N 题" or "N."/"N、", lines
              // starting with "1)"/"2)" are typically sub-questions, not new
              // top-level problems.
              final isSubQuestion =
                  activeStyle == 'explicit' || activeStyle == 'dot';
              if (!isSubQuestion) {
                matchedNumber = paren[1];
                matchedStyle = 'paren';
              }
            }
          }
        }
        if (matchedNumber != null) {
          finish();
          number = matchedNumber;
          activeStyle = matchedStyle;
        }
        if (number != null) buffer.add(segment.copyWith(text: line));
      }
    }
    finish();
    return result;
  }

  PreparedMaterialWork prepareExercises(
    DocumentRecord doc,
    ProviderSettings settings,
    List<ExerciseQuestion> questions, {
    List<String> gaps = const [],
    String instruction = '',
    bool retryUnknown = false,
  }) {
    final numberCounts = <String, int>{};
    for (final q in questions) {
      numberCounts.update(q.number, (n) => n + 1, ifAbsent: () => 1);
    }
    final trimmedInstruction = instruction.trim();
    final warnings = [...gaps];
    final candidates = <_TextUnit>[];
    for (final q in questions) {
      if (numberCounts[q.number] != 1) {
        warnings.add('第 ${q.number} 题有重号，请分开框选或调整范围。');
        continue;
      }
      candidates.add(
        _TextUnit(
          label: '第 ${q.number} 题',
          sources: q.sources,
          data: {
            'number': q.number,
            'stem': q.stem,
            if (trimmedInstruction.isNotEmpty)
              'instruction': trimmedInstruction,
          },
        ),
      );
    }
    return _prepareText(
      doc,
      settings,
      MaterialAction.exercise,
      candidates,
      warnings,
      retryUnknown: retryUnknown,
    );
  }

  PreparedMaterialWork prepareTranslation(
    DocumentRecord doc,
    ProviderSettings settings,
    int first,
    int last, {
    required String targetLanguage,
    String glossary = '',
    SourceRegion? selection,
    bool retryUnknown = false,
    TranslationProfile? profile,
  }) {
    final segments = paragraphs(doc, first, last, region: selection);
    final covered = segments.map((segment) => segment.page).toSet();
    final gaps = <String>[
      for (var page = first; page <= last; page++)
        if (!covered.contains(page)) '第 $page 页缺少所选范围内的完整文字，识别或补选后可继续。',
    ];
    final candidates = <_TextUnit>[];
    for (final segment in segments) {
      final protection = ProtectedTranslation(
        segment.text,
        glossary: profile == null ? const {} : _glossaryTerms(glossary),
      );
      final slot =
          'translation:${materialDigest([segment.id, segment.text, targetLanguage])}';
      candidates.add(
        _TextUnit(
          label: segment.locatorLabel!,
          sources: [segment],
          protectedText: protection,
          translationSlot: slot,
          data: {
            'target_language': targetLanguage,
            'glossary': glossary,
            'segment_id': segment.id,
            'text': protection.masked,
          },
        ),
      );
    }
    return _prepareText(
      doc,
      settings,
      MaterialAction.translation,
      candidates,
      gaps,
      retryUnknown: retryUnknown,
      translation: profile == null
          ? null
          : TranslationWire(profile, targetLanguage),
    );
  }

  Map<String, String> _glossaryTerms(String glossary) => {
    for (final line in glossary.split('\n'))
      if (line.indexOf('=') case final index
          when index > 0 && index < line.length - 1)
        line.substring(0, index).trim(): line.substring(index + 1).trim(),
  }..removeWhere((key, value) => key.isEmpty || value.isEmpty);

  PreparedMaterialWork prepareOutline(
    DocumentRecord doc,
    ProviderSettings settings,
    int first,
    int last, {
    bool retryUnknown = false,
  }) {
    final sections = <_TextUnit>[];
    final byPage = <int, List<Evidence>>{};
    for (final part in paragraphs(doc, first, last)) {
      byPage.putIfAbsent(part.page, () => []).add(part);
    }
    for (var start = first; start <= last; start += 4) {
      final end = math.min(start + 3, last);
      final balanced = [
        for (var page = start; page <= end; page++) ...?byPage[page]?.take(10),
      ];
      if (balanced.isEmpty) continue;
      sections.add(
        _TextUnit(
          label: '第 $start–$end 页',
          sources: balanced,
          data: {'task': '研究问题、方法、证据、结论和局限'},
        ),
      );
    }
    return _prepareText(doc, settings, MaterialAction.outline, sections, [
      for (var page = first; page <= last; page++)
        if (!byPage.containsKey(page)) '第 $page 页缺少可读文字。',
    ], retryUnknown: retryUnknown);
  }

  PreparedMaterialWork _prepareText(
    DocumentRecord doc,
    ProviderSettings settings,
    MaterialAction action,
    List<_TextUnit> candidates,
    List<String> gaps, {
    required bool retryUnknown,
    TranslationWire? translation,
  }) {
    _requireActive(doc);
    final model =
        translation?.profile.version ?? _model(settings, image: false);
    final history = _history(doc, action);
    final cached = <MaterialResult>[];
    final units = <MaterialUnit>[];
    for (final candidate in candidates) {
      final edited = candidate.translationSlot == null
          ? null
          : readState(doc, candidate.translationSlot!);
      final payload = {
        'template': action.templateVersion,
        ...candidate.data,
        if (action != MaterialAction.translation)
          'sources': [
            for (var i = 0; i < candidate.sources.length; i++)
              {
                'id': 'S${i + 1}',
                'page': candidate.sources[i].page,
                'text': candidate.sources[i].text,
              },
          ],
      };
      final key = translation == null
          ? _key(doc, action, settings, model, payload)
          : materialDigest([
              doc.contentHash,
              action.templateVersion,
              translation.endpoint.toString(),
              translation.profile.version,
              payload,
            ]);
      if (edited is String) {
        cached.add(
          MaterialResult(
            key: key,
            label: candidate.label,
            text: edited,
            sources: candidate.sources,
            data: {
              'translationSlot': candidate.translationSlot,
              'edited': true,
            },
          ),
        );
        continue;
      }
      if (_reuse(
        key,
        history,
        cached,
        gaps,
        candidate.label,
        retryUnknown: retryUnknown,
      )) {
        continue;
      }
      final protectedText = candidate.protectedText;
      units.add(
        translation == null
            ? _unit(
                key: key,
                label: candidate.label,
                payload: payload,
                sources: candidate.sources,
                settings: settings,
                action: action,
                protection: protectedText,
                translationSlot: candidate.translationSlot,
              )
            : MaterialUnit(
                key: key,
                label: candidate.label,
                sources: candidate.sources,
                requestText: translation.profile.body(
                  protectedText!.masked,
                  translation.language,
                ),
                inputBudget: protectedText.masked.length,
                protectedText: protectedText,
                translationSlot: candidate.translationSlot,
              ),
      );
    }
    return PreparedMaterialWork._(
      document: doc,
      action: action,
      settings: settings,
      model: model,
      units: units,
      cached: cached,
      gaps: gaps,
      translation: translation,
    );
  }

  Future<List<MaterialResult>> run(
    PreparedMaterialWork request, {
    required int tokenBudget,
    required bool Function() paused,
    required void Function(MaterialProgress) onProgress,
  }) async {
    if (_busy || !request._approved || request._started || request._closed) {
      throw StateError('请先确认本次任务的发送预览。');
    }
    _requireActive(request.document);
    _busy = true;
    request._started = true;
    final completed = [...request.cached];
    var spent = 0;
    var estimated = 0;
    var done = 0;
    void update(String message) => onProgress(
      MaterialProgress(
        done: done,
        total: request.units.length,
        spent: spent,
        budget: tokenBudget,
        estimated: estimated,
        message: message,
      ),
    );
    try {
      for (final unit in request.units) {
        if (paused()) {
          update('已暂停，可从缺项继续。');
          break;
        }
        _requireActive(request.document);
        final reserved = unit.inputBudget + request.outputReserve;
        if (spent + estimated + reserved > tokenBudget) {
          update('剩余估额不足，停在 ${unit.label} 前。');
          break;
        }
        final previous = _result(request, unit);
        if (previous?.hasResult == true) {
          completed.add(previous!);
          done++;
          update('复用 ${unit.label}');
          continue;
        }
        final image = await unit.image?.load();
        _requireActive(request.document);
        if (paused()) {
          update('已暂停，可从缺项继续。');
          break;
        }
        _write(request, unit, 'running');
        update(unit.label);
        TokenUsage? usage;
        int? characters;
        try {
          final Map<String, dynamic> parsed;
          if (request.translation case final translator?) {
            final (translated, metered) = await translator.translate(
              unit.requestText,
            );
            parsed = {'translation': translated};
            characters = metered;
          } else {
            final response = await transport.postJson(
              settings: request.settings,
              endpoint: request.settings.endpoint,
              payloadJson: _payload(request, unit, image),
            );
            final envelope = materialJson(jsonDecode(response.body));
            usage = AiTransport.usageFromEnvelope(envelope);
            final object = materialJson(
              (envelope['choices'] as List?)?.firstOrNull,
            );
            if (object['finish_reason'] == 'length') {
              throw const FormatException('输出被截断，请缩小范围或放大所需局部。');
            }
            final content = materialJson(object['message'])['content'];
            if (content is! String) throw const FormatException('模型返回了空结果。');
            parsed = materialJson(
              jsonDecode(AiTransport.stripJsonFence(content)),
            );
          }
          final decoded = decodeMaterialResponse(request.action, unit, parsed);
          _requireActive(request.document);
          store.transact(() {
            _write(
              request,
              unit,
              decoded.$2 == null ? 'ready' : 'verify',
              result: decoded.$1,
              issue: decoded.$2,
              usage: usage,
              characters: characters,
            );
            if (request.action == MaterialAction.recognition) {
              _indexRecognition(request.document, unit, decoded.$1);
            }
          });
        } catch (error) {
          final failure = error is AiFailure ? error : null;
          final uncertain =
              failure?.code == AiError.timeout ||
              failure?.code == AiError.network;
          _requireActive(request.document);
          _write(
            request,
            unit,
            uncertain ? 'unknown' : 'failed',
            issue:
                failure?.message ??
                (error is FormatException ? error.message : '无法保存本项结果。'),
            usage: usage,
            characters: characters,
          );
          if (uncertain ||
              failure?.code == AiError.rateLimited ||
              failure?.code == AiError.unauthorized ||
              failure?.code == AiError.missingKey) {
            if (uncertain) estimated += reserved;
            done++;
            completed.add(_result(request, unit)!);
            update(uncertain ? '受理状态未知，已停止后续请求。' : '服务商拒绝请求，已停止。');
            break;
          }
        }
        if (characters != null) {
          spent += characters;
        } else if (usage == null) {
          estimated += reserved;
        } else {
          spent += usage.totalTokens;
        }
        completed.add(_result(request, unit)!);
        done++;
        update('已处理 $done 项');
      }
      return completed;
    } finally {
      _busy = false;
    }
  }

  MaterialResult? _result(PreparedMaterialWork request, MaterialUnit unit) {
    final rows = store.selectRows(
      'SELECT * FROM material_items WHERE $_scope AND item_key=?',
      [..._parameters(request.document, request.action), unit.key],
    );
    return rows.isEmpty ? null : MaterialResult.fromRow(rows.single);
  }

  void _write(
    PreparedMaterialWork request,
    MaterialUnit unit,
    String state, {
    Map<String, dynamic>? result,
    String? issue,
    TokenUsage? usage,
    int? characters,
  }) {
    store.executeSql(
      '''INSERT INTO material_items
      (document_id, document_hash, task, item_key, state, input_budget, output_budget,
       usage, result, issue, updated_at)
      VALUES (?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(document_id,document_hash,task,item_key) DO UPDATE SET
        state=excluded.state, input_budget=excluded.input_budget, output_budget=excluded.output_budget,
        usage=excluded.usage, result=excluded.result, issue=excluded.issue, updated_at=excluded.updated_at''',
      [
        ..._parameters(request.document, request.action),
        unit.key,
        state,
        unit.inputBudget,
        request.outputReserve,
        usage == null ? null : jsonEncode(usage.toJson()),
        jsonEncode({
          'label': unit.label,
          'sources': unit.sources.map((e) => e.toJson()).toList(),
          ...?result,
          if (request.translation != null) ...{
            'billingUnit': request.billingUnit,
            'engine': request.translation!.label,
            'billedCharacters': characters,
          },
        }),
        issue,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
  }

  String _payload(
    PreparedMaterialWork request,
    MaterialUnit unit,
    ImageAttachment? image,
  ) => jsonEncode({
    'model': request.model,
    'messages': [
      {'role': 'system', 'content': materialInstructions(request.action)},
      {
        'role': 'user',
        'content': image == null
            ? unit.requestText
            : [
                {'type': 'text', 'text': unit.requestText},
                {
                  'type': 'image_url',
                  'image_url': {
                    'url': 'data:image/png;base64,${base64Encode(image.bytes)}',
                  },
                },
              ],
      },
    ],
    'stream': false,
    'max_tokens': request.action.maxOutput,
    if (image == null) 'response_format': {'type': 'json_object'},
    if (request.settings.endpoint.host == 'api.deepseek.com')
      'thinking': {'type': 'disabled'},
  });

  void _indexRecognition(
    DocumentRecord doc,
    MaterialUnit unit,
    Map<String, dynamic> result,
  ) {
    final anchor = unit.sources.single;
    if (store.getPage(doc.id, anchor.page)?.manuallyCorrected == true) return;
    final prefix =
        '${doc.id}:vision:${anchor.page}:${materialDigest(anchor.region.toJson()).substring(0, 12)}:';
    final existing = store.getEvidence(doc.id, page: anchor.page);
    for (final row in existing) {
      if (row.id.startsWith(prefix)) {
        store.executeSql('DELETE FROM evidence WHERE evidence_id=?', [row.id]);
      }
    }
    for (final value in result['sources'] as List) {
      final block = Evidence.fromJson(materialJson(value));
      if (!existing.any(
        (row) =>
            row.origin == EvidenceOrigin.manual &&
            row.region.intersects(block.region),
      )) {
        store.saveEvidence(block);
      }
    }
  }

  void saveRecognitionCorrection(
    DocumentRecord doc,
    int page,
    SourceRegion region,
    String text,
    String resultKey,
  ) {
    _requireActive(doc);
    final id =
        '${doc.id}:material-edit:$page:${materialDigest(region.toJson())}';
    store.transact(() {
      saveState(doc, 'recognitionEdit:$resultKey', text);
      for (final item in store.getEvidence(doc.id, page: page)) {
        if (item.origin == EvidenceOrigin.vision &&
            item.region.intersects(region)) {
          store.executeSql('DELETE FROM evidence WHERE evidence_id=?', [
            item.id,
          ]);
        }
      }
      store.saveEvidence(
        _source(
          doc,
          page,
          region,
          text,
        ).copyWith(id: id, origin: EvidenceOrigin.manual),
      );
    });
  }
}

class _TextUnit {
  const _TextUnit({
    required this.label,
    required this.sources,
    required this.data,
    this.protectedText,
    this.translationSlot,
  });
  final String label;
  final List<Evidence> sources;
  final Map<String, dynamic> data;
  final ProtectedTranslation? protectedText;
  final String? translationSlot;
}
