import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'core/local_store.dart';
import 'core/models.dart';
import 'core/search_index.dart';
import 'services/ai_gateway.dart';
import 'services/document_service.dart';
import 'services/ocr_service.dart';

class SavedReply {
  SavedReply({
    required this.question,
    required this.answer,
    required List<Evidence> sources,
    required this.model,
    required this.tokens,
    this.insufficient = false,
    this.task,
    this.sessionId,
    this.documentHash,
    DateTime? createdAt,
  }) : sources = List.unmodifiable(sources),
       createdAt = createdAt ?? DateTime.now();
  final String question;
  final String answer;
  final List<Evidence> sources;
  final String model;
  final int tokens;
  final bool insufficient;
  final String? task;
  final String? sessionId;
  final String? documentHash;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
    'question': question,
    'answer': answer,
    'sources': sources.map((e) => e.toJson()).toList(),
    'model': model,
    'tokens': tokens,
    'insufficient': insufficient,
    'task': task,
    'sessionId': sessionId,
    'documentHash': documentHash,
    'createdAt': createdAt.toIso8601String(),
  };
  factory SavedReply.fromJson(Map<String, dynamic> data) => SavedReply(
    question: data['question'] as String,
    answer: data['answer'] as String,
    sources: (data['sources'] as List)
        .map((e) => Evidence.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    model: data['model'] as String,
    tokens: data['tokens'] as int,
    insufficient: data['insufficient'] as bool,
    task: data['task'] as String?,
    sessionId: data['sessionId'] as String?,
    documentHash: data['documentHash'] as String?,
    createdAt: DateTime.parse(data['createdAt'] as String),
  );
}

class _RequestOrigin {
  const _RequestOrigin(this.document, this.session);
  final DocumentRecord document;
  final StudySession? session;
}

class StudyController extends ChangeNotifier {
  StudyController({
    required this.store,
    required this.documents,
    required this.gateway,
    required this.ocr,
  }) {
    final config = store.getSetting('provider');
    if (config != null) {
      try {
        settings = ProviderSettings.fromJson(
          Map<String, dynamic>.from(jsonDecode(config) as Map),
        );
      } catch (_) {
        error = '已保存的模型设置无法读取，请重新填写。';
      }
    }
  }

  static Future<StudyController> create() async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(p.join(support.path, 'local_study'));
    await directory.create(recursive: true);
    final store = LocalStore.open(directory.path);
    final ocr = OcrService();
    final documents = DocumentService(directory, store, ocr);
    final controller = StudyController(
      store: store,
      ocr: ocr,
      documents: documents,
      gateway: AiGateway(),
    );
    try {
      await documents.recoverPendingDeletions();
    } catch (_) {
      controller.error = '上次删除资料的文件清理尚未完成，重启时会再尝试。';
    }
    return controller;
  }

  final LocalStore store;
  final DocumentService documents;
  final AiGateway gateway;
  final OcrService ocr;
  ProviderSettings settings = ProviderSettings.deepSeek();
  DocumentRecord? current;
  OpenDocument? opened;
  RenderedPage? raster;
  SourceRegion? selection;
  SourceRegion? highlight;
  int page = 1;
  bool loading = false;
  bool importing = false;
  bool sending = false;
  bool indexing = false;
  bool paused = false;
  int? indexingPage;
  String? error;
  int _generation = 0;
  int _renderGeneration = 0;
  Future<void>? _indexTask;
  bool _disposed = false;
  Future<void> _transition = Future.value();
  Future<void>? _shutdownTask;
  final Set<Future<void>> _operations = {};
  final _requestOrigins = Expando<_RequestOrigin>();
  List<SavedReply> replies = [];
  StudySession? session;
  static const uuid = Uuid();

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void clearError() {
    if (_disposed) return;
    error = null;
    _emit();
  }

  Future<void> _track(Future<void> Function() action) {
    if (_disposed) return Future.value();
    final task = action();
    _operations.add(task);
    unawaited(
      task.then(
        (_) {
          _operations.remove(task);
        },
        onError: (Object _, StackTrace _) {
          _operations.remove(task);
        },
      ),
    );
    return task;
  }

  Future<void> _waitForIndex() async {
    try {
      await _indexTask;
    } catch (_) {
      /* State is recorded per page. */
    }
  }

  List<SavedReply> _history(String documentId) {
    final history = store.getSetting('history:$documentId');
    if (history == null) return [];
    try {
      return (jsonDecode(history) as List)
          .map((e) => SavedReply.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  List<DocumentRecord> get library => store.getDocuments();
  List<PageRecord> get pages =>
      current == null ? [] : store.getPages(current!.id);
  List<StudyNote> get notes =>
      current == null ? [] : store.getNotes(current!.id);
  List<StudySession> get sessions =>
      current == null ? [] : store.getSessions(current!.id);
  List<Evidence> get pageEvidence =>
      current == null ? [] : store.getEvidence(current!.id, page: page);
  PageRecord? get currentPage =>
      current == null ? null : store.getPage(current!.id, page);

  Future<void> importPath(String path, DocumentKind kind) => _track(() async {
    if (importing) return;
    importing = true;
    error = null;
    _emit();
    try {
      final record = await documents.importFile(path, kind);
      if (!_disposed) await open(record);
    } catch (e) {
      error = '导入失败：$e';
    } finally {
      importing = false;
      _emit();
    }
  });

  Future<void> open(DocumentRecord record) {
    if (_disposed) return Future.value();
    final token = ++_generation;
    _renderGeneration++;
    loading = true;
    error = null;
    _emit();
    final task = _transition.then((_) async {
      OpenDocument? candidate;
      try {
        if (token != _generation || _disposed) return;
        await _waitForIndex();
        if (token != _generation || _disposed) return;
        final old = opened;
        opened = null;
        await old?.dispose();
        if (token != _generation || _disposed) return;
        final latest = store.getDocument(record.id);
        if (latest == null || latest.contentHash != record.contentHash) {
          throw StateError('资料已删除或版本已改变。');
        }
        final active = latest.copyWith(lastOpenedAt: DateTime.now());
        candidate = await documents.open(active);
        if (token != _generation || _disposed) {
          await candidate.dispose();
          candidate = null;
          return;
        }
        current = active;
        opened = candidate;
        candidate = null;
        store.upsertDocument(active);
        page = active.currentPage;
        selection = null;
        highlight = null;
        raster = null;
        replies = _history(active.id);
        final previous = store.getSessions(active.id);
        session = previous.isEmpty ? null : previous.first;
        await goToPage(page);
        if (token != _generation || _disposed) return;
        paused = false;
        startIndexing();
      } catch (e) {
        await candidate?.dispose();
        if (token == _generation && !_disposed) {
          error = '打开失败：$e';
          current = null;
          raster = null;
        }
      } finally {
        if (token == _generation && !_disposed) {
          loading = false;
          _emit();
        }
      }
    });
    _transition = task;
    return task;
  }

  Future<void> goToPage(int target, {SourceRegion? region}) async {
    final document = opened;
    final record = current;
    if (_disposed || document == null || record == null) return;
    final token = ++_renderGeneration;
    final generation = _generation;
    page = target.clamp(1, record.pageCount);
    selection = null;
    highlight = region;
    raster = null;
    current = record.copyWith(currentPage: page, lastOpenedAt: DateTime.now());
    store.upsertDocument(current!);
    _emit();
    try {
      final result = await document.render(page);
      if (!_disposed &&
          token == _renderGeneration &&
          generation == _generation &&
          identical(opened, document)) {
        raster = result;
      }
    } catch (e) {
      if (!_disposed &&
          token == _renderGeneration &&
          generation == _generation) {
        error = '页面渲染失败：$e';
      }
    }
    if (token == _renderGeneration && generation == _generation) _emit();
  }

  void select(SourceRegion? region) {
    if (_disposed) return;
    selection = region;
    highlight = null;
    _emit();
  }

  Future<void> backToLibrary() {
    if (_disposed) return Future.value();
    _generation++;
    _renderGeneration++;
    current = null;
    raster = null;
    error = null;
    selection = null;
    highlight = null;
    loading = false;
    _emit();
    final task = _transition.then((_) async {
      try {
        await _waitForIndex();
        final old = opened;
        opened = null;
        await old?.dispose();
      } catch (e) {
        if (!_disposed) error = '关闭资料失败：$e';
        _emit();
      }
    });
    _transition = task;
    return task;
  }

  void startIndexing() {
    if (_disposed || indexing || opened == null || paused) return;
    final token = _generation;
    final document = opened!;
    indexing = true;
    _emit();
    _indexTask = () async {
      try {
        final availability = await ocr.availability();
        if (_disposed || token != _generation) return;
        final todo = store
            .getPages(document.record.id)
            .where(
              (p) =>
                  p.status == PageStatus.pending ||
                  (availability.available && p.status == PageStatus.needsOcr),
            )
            .map((p) => p.page)
            .toList();
        while (todo.isNotEmpty &&
            token == _generation &&
            !paused &&
            !_disposed) {
          final preferred = todo.indexOf(page);
          final next = todo.removeAt(preferred < 0 ? 0 : preferred);
          indexingPage = next;
          _emit();
          await documents.indexPage(document, next);
          if (token != _generation || _disposed) break;
          _emit();
          await Future<void>.delayed(Duration.zero);
        }
      } catch (e) {
        if (!_disposed && token == _generation) error = '索引队列暂停：$e';
      } finally {
        indexing = false;
        indexingPage = null;
        _emit();
      }
    }();
  }

  void toggleIndexing() {
    if (_disposed) return;
    paused = !paused;
    if (!paused) startIndexing();
    _emit();
  }

  Future<void> recognizeCurrentPage() async {
    if (_disposed || opened == null || indexing) return;
    final token = _generation;
    indexing = true;
    indexingPage = page;
    _emit();
    _indexTask = documents.indexPage(opened!, page, forceOcr: true);
    try {
      await _indexTask;
    } catch (e) {
      if (!_disposed && token == _generation) error = '识别失败：$e';
    } finally {
      indexing = false;
      indexingPage = null;
      _emit();
    }
  }

  Future<void> correctText(String text) => _track(() async {
    if (current == null) return;
    await documents.correctPage(current!, page, text, SourceRegion.fullPage);
    _emit();
  });

  void saveSession(StudySession value) {
    if (_disposed || current?.id != value.documentId) return;
    session = value.copyWith(updatedAt: DateTime.now());
    store.saveSession(session!);
    _emit();
  }

  void beginSession({
    required int start,
    required int end,
    required String goal,
    required int minutes,
  }) {
    if (current == null) return;
    saveSession(
      StudySession(
        id: uuid.v4(),
        documentId: current!.id,
        startPage: start,
        endPage: end,
        goal: goal,
        minutes: minutes,
        stage: 'read',
      ),
    );
  }

  void saveAnswer(String answer) {
    final value = session;
    if (value == null || _disposed) return;
    if (value.stage == 'feedback' && value.answer == answer) return;
    var attempts = value.attempts;
    if (answer.trim().isNotEmpty) {
      final draft = StudyAttempt(question: value.question, answer: answer);
      if (attempts.isNotEmpty &&
          attempts.last.question == value.question &&
          attempts.last.feedback.isEmpty) {
        attempts = [...attempts.take(attempts.length - 1), draft];
      } else {
        attempts = [...attempts, draft];
      }
    }
    saveSession(
      value.copyWith(
        answer: answer,
        stage: 'answered',
        attempts: attempts,
        feedback: '',
        needsReview: false,
      ),
    );
  }

  void markForReview(bool value) {
    if (session == null) return;
    var attempts = session!.attempts;
    if (attempts.isNotEmpty) {
      attempts = [
        ...attempts.take(attempts.length - 1),
        attempts.last.copyWith(needsReview: value),
      ];
    }
    saveSession(session!.copyWith(needsReview: value, attempts: attempts));
  }

  Future<void> saveSettings(ProviderSettings value, String? key) =>
      _track(() async {
        if (key != null && key.trim().isNotEmpty) {
          await gateway.saveKey(value, key.trim());
        }
        if (_disposed) return;
        settings = value;
        store.setSetting('provider', jsonEncode(value.toJson()));
        _emit();
      });

  List<Evidence> _boundEvidence(Iterable<Evidence> items) {
    final result = <Evidence>[];
    final ids = <String>{};
    var remaining = AiGateway.maxEvidenceCharacters;
    for (final item in items) {
      if (result.length >= 10 || remaining <= 0) break;
      if (!ids.add(item.id) || item.text.trim().isEmpty) continue;
      final text = item.text.length <= remaining
          ? item.text
          : item.text.substring(0, remaining);
      result.add(text == item.text ? item : item.copyWith(text: text));
      remaining -= text.length;
    }
    return result;
  }

  List<Evidence> evidenceFor(String question, {bool useRange = false}) {
    if (current == null || _disposed) return [];
    if (selection != null && !useRange) {
      final selected = pageEvidence
          .where((e) => e.region.intersects(selection!))
          .toList();
      // Selection plus the two nearest context fragments. All remain visible
      // in the request preview and retain their own original rectangles.
      final nearby = pageEvidence.where((e) => !selected.contains(e)).toList()
        ..sort(
          (a, b) => (a.region.top - selection!.top).abs().compareTo(
            (b.region.top - selection!.top).abs(),
          ),
        );
      return _boundEvidence([...selected, ...nearby.take(2)]);
    }
    final start = useRange ? session?.startPage ?? 1 : page;
    final end = useRange ? session?.endPage ?? current!.pageCount : page;
    final matches = store.searchEvidence(
      question,
      documentId: current!.id,
      startPage: start,
      endPage: end,
      limit: 10,
    );
    if (matches.isNotEmpty) return _boundEvidence(matches);
    // Natural questions contain grammar absent from the source. A bounded
    // second search uses adjacent pairs, within the same reviewed range.
    const stop = {
      '什么',
      '怎么',
      '为何',
      '如何',
      '是否',
      '这个',
      '那个',
      '可以',
      '我们',
      '本文',
      '请问',
    };
    final terms = SearchIndex.tokens(question)
        .where((term) => term.length >= 2 && !stop.contains(term))
        .toSet()
        .take(24)
        .join(' ');
    final relaxed = terms.isEmpty
        ? <Evidence>[]
        : store.searchEvidence(
            terms,
            documentId: current!.id,
            startPage: start,
            endPage: end,
            limit: 10,
          );
    if (relaxed.isNotEmpty) return _boundEvidence(relaxed);
    final local = pageEvidence.where((e) => e.page >= start && e.page <= end);
    return _boundEvidence([
      ...local,
      ...store
          .getEvidence(current!.id, startPage: start, endPage: end)
          .take(10),
    ]);
  }

  // Overview tasks need page coverage, not a keyword search dominated by the
  // introduction. Each excerpt retains a full-page, versioned source anchor.
  (List<Evidence>, String) _guideEvidence() {
    final doc = current!;
    final start = session?.startPage ?? 1;
    final end = session?.endPage ?? doc.pageCount;
    final byPage = <int, List<Evidence>>{};
    for (final item in store.getEvidence(
      doc.id,
      startPage: start,
      endPage: end,
    )) {
      if (item.text.trim().isNotEmpty) {
        byPage.putIfAbsent(item.page, () => []).add(item);
      }
    }
    final available = byPage.keys.toList()..sort();
    final included = available.length <= AiGateway.maxEvidenceCount
        ? available
        : List.generate(
            AiGateway.maxEvidenceCount,
            (index) =>
                available[(index *
                        (available.length - 1) /
                        (AiGateway.maxEvidenceCount - 1))
                    .round()],
          );
    final budget = included.isEmpty
        ? 0
        : AiGateway.maxEvidenceCharacters ~/ included.length;
    var shortened = false;
    final evidence = <Evidence>[];
    for (final page in included) {
      var text = byPage[page]!.map((item) => item.text).join('\n');
      if (text.length > budget) {
        shortened = true;
        const marker = '\n[本页中间文字未发送]\n';
        final head = (budget - marker.length) ~/ 2;
        final tail = budget - marker.length - head;
        text =
            '${text.substring(0, head)}$marker${text.substring(text.length - tail)}';
      }
      evidence.add(
        Evidence(
          id: 'overview:${doc.id}:${doc.contentHash}:$page',
          documentId: doc.id,
          documentHash: doc.contentHash,
          page: page,
          region: SourceRegion.fullPage,
          text: text,
        ),
      );
    }
    final partial =
        available.length != end - start + 1 ||
        included.length != available.length ||
        shortened;
    final note =
        '请求第 $start–$end 页；${available.length} 页有已提取文字，'
        '本次发送 ${included.length} 页${shortened ? '的节选' : '的已提取文字'}。'
        '${partial ? '这是局部导读，缺页或未发送的文字不能用于判断全文是否说明。' : ''}'
        '图表、公式及识别遗漏仍需对照原页核验。';
    return (evidence, note);
  }

  List<AiConversationTurn> _conversationFor(AiTask task) {
    if (task != AiTask.explain &&
        task != AiTask.explainTerm &&
        task != AiTask.explainImage) {
      return [];
    }
    final doc = current!;
    final turns = <AiConversationTurn>[];
    var remaining = AiGateway.maxHistoryCharacters;
    for (final reply in _history(doc.id).reversed) {
      // Legacy replies lack a trustworthy scope and remain readable locally.
      if (reply.task == null ||
          reply.task == AiTask.searchTerms.name ||
          reply.documentHash != doc.contentHash ||
          reply.sessionId != session?.id ||
          reply.insufficient) {
        continue;
      }
      final length = reply.question.length + reply.answer.length;
      if (length > remaining || turns.length == AiGateway.maxHistoryTurns) {
        break;
      }
      turns.add(
        AiConversationTurn(question: reply.question, answer: reply.answer),
      );
      remaining -= length;
    }
    return turns.reversed.toList();
  }

  PreparedAiRequest prepare(
    AiTask task,
    String question, {
    ImageAttachment? image,
    bool useRange = false,
  }) {
    if (_disposed || current == null) {
      throw StateError('请先打开资料，再预览要发送的内容。');
    }
    final overview = task == AiTask.paperGuide ? _guideEvidence() : null;
    final evidence =
        overview?.$1 ??
        (task == AiTask.searchTerms
            ? <Evidence>[]
            : evidenceFor(question, useRange: useRange));
    final request = gateway.prepare(
      settings: settings,
      task: task,
      question: question,
      evidence: evidence
          .map(
            (e) => AiEvidence(
              id: e.id,
              text: e.text,
              page: e.page,
              documentId: e.documentId,
              documentHash: e.documentHash,
              region: {
                'left': e.region.left,
                'top': e.region.top,
                'right': e.region.right,
                'bottom': e.region.bottom,
              },
            ),
          )
          .toList(),
      learnerAnswer: task == AiTask.gradeAnswer ? session?.answer : null,
      image: image,
      history: _conversationFor(task),
      coverageNote: overview?.$2,
    );
    _requestOrigins[request] = _RequestOrigin(current!, session);
    return request;
  }

  Future<void> send(PreparedAiRequest request, {ImageApproval? approval}) =>
      _track(() async {
        if (sending || current == null) return;
        final doc = current!;
        final origin = _requestOrigins[request];
        if (origin == null ||
            origin.document.id != doc.id ||
            origin.document.contentHash != doc.contentHash ||
            !identical(origin.session, session) ||
            request.evidence.any(
              (source) =>
                  source.documentId != doc.id ||
                  source.documentHash != doc.contentHash,
            )) {
          error = '资料或学习进度已改变，请重新预览本次请求。';
          _emit();
          return;
        }
        // Citations retain the exact reviewed text and coordinates even when a
        // background OCR job or manual correction changes the local index.
        final sourceSnapshot = request.evidence
            .map(
              (source) => Evidence(
                id: source.id,
                documentId: source.documentId,
                documentHash: source.documentHash,
                page: source.page,
                text: source.text,
                region: source.region == null
                    ? SourceRegion.fullPage
                    : SourceRegion.fromJson(
                        Map<String, dynamic>.from(source.region!),
                      ),
              ),
            )
            .toList();
        final sessionSnapshot = origin.session;
        sending = true;
        error = null;
        _emit();
        try {
          final result = await gateway.send(request, imageApproval: approval);
          if (_disposed ||
              store.getDocument(doc.id)?.contentHash != doc.contentHash) {
            return;
          }
          final history = [
            ..._history(doc.id),
            SavedReply(
              question: request.question,
              answer: result.answer,
              sources: sourceSnapshot
                  .where((e) => result.citations.contains(e.id))
                  .toList(),
              model: request.model,
              tokens: result.usage?.totalTokens ?? 0,
              insufficient: result.insufficientEvidence,
              task: request.task.name,
              sessionId: sessionSnapshot?.id,
              documentHash: doc.contentHash,
            ),
          ];
          store.setSetting(
            'history:${doc.id}',
            jsonEncode(history.map((e) => e.toJson()).toList()),
          );
          if (current?.id != doc.id) return;
          replies = history;
          if (result.insufficientEvidence &&
              (request.task == AiTask.generateQuestion ||
                  request.task == AiTask.gradeAnswer)) {
            error = '资料依据不足，练习进度已保留。请补充原文后重试。';
          }
          if (result.insufficientEvidence ||
              sessionSnapshot == null ||
              !identical(session, sessionSnapshot)) {
            return;
          }
          if (request.task == AiTask.generateQuestion &&
              session?.stage == sessionSnapshot.stage) {
            saveSession(
              session!.copyWith(
                question: result.answer,
                answer: '',
                feedback: '',
                needsReview: false,
                stage: 'question',
              ),
            );
          } else if (request.task == AiTask.gradeAnswer &&
              session?.answer == request.learnerAnswer &&
              session?.question == sessionSnapshot.question) {
            final attempts = [...session!.attempts];
            if (attempts.isNotEmpty &&
                attempts.last.question == sessionSnapshot.question &&
                attempts.last.answer == request.learnerAnswer) {
              attempts[attempts.length - 1] = attempts.last.copyWith(
                feedback: result.answer,
              );
            } else {
              attempts.add(
                StudyAttempt(
                  question: sessionSnapshot.question,
                  answer: request.learnerAnswer ?? '',
                  feedback: result.answer,
                ),
              );
            }
            saveSession(
              session!.copyWith(
                feedback: result.answer,
                stage: 'feedback',
                attempts: attempts,
              ),
            );
          }
        } catch (e) {
          if (!_disposed && current?.id == doc.id) error = e.toString();
        } finally {
          sending = false;
          _emit();
        }
      });

  void addNote({required String understanding, required String question}) {
    if (current == null || _disposed) return;
    final sources = selection == null
        ? pageEvidence
        : pageEvidence.where((e) => e.region.intersects(selection!)).toList();
    store.saveNote(
      StudyNote(
        id: uuid.v4(),
        documentId: current!.id,
        documentHash: current!.contentHash,
        page: page,
        region: selection ?? SourceRegion.fullPage,
        understanding: understanding,
        evidenceText: sources.map((e) => e.text).join('\n'),
        question: question,
      ),
    );
    _emit();
  }

  Future<void> jumpToEvidence(Evidence evidence) async {
    if (_disposed) return;
    final doc = store.getDocument(evidence.documentId);
    if (doc == null || doc.contentHash != evidence.documentHash) {
      error = '来源版本与当前资料不一致，无法跳转。';
      _emit();
      return;
    }
    if (current?.id != doc.id) await open(doc);
    if (current?.id == doc.id && !_disposed) {
      await goToPage(evidence.page, region: evidence.region);
    }
  }

  Future<void> deleteDocument(DocumentRecord record) => _track(() async {
    try {
      if (current?.id == record.id) await backToLibrary();
      await documents.delete(record);
    } catch (e) {
      if (!_disposed) error = '删除未完成：$e';
    }
    _emit();
  });

  /// Widgets can dispose immediately; process owners and tests may await the
  /// completion of pending file work before PDF and SQLite handles close.
  Future<void> shutdown() => _shutdownTask ??= _shutdown();

  Future<void> _shutdown() async {
    _disposed = true;
    _generation++;
    _renderGeneration++;
    gateway.close();
    try {
      await _transition;
    } catch (_) {
      /* Continue releasing resources. */
    }
    await Future.wait(
      _operations.toList().map((task) => task.catchError((Object _) {})),
    );
    await _waitForIndex();
    await opened?.dispose();
    opened = null;
    store.dispose();
  }

  @override
  void dispose() {
    unawaited(shutdown());
    super.dispose();
  }
}
