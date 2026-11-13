import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../app_controller.dart';
import '../../core/models.dart';
import '../../services/ai_gateway.dart';
import '../../services/web_search_provider.dart';
import 'data/book_qa_repository.dart';
import 'models/book_qa_models.dart';
import 'models/book_understanding.dart';
import 'services/book_qa_client.dart';
import 'services/book_qa_service.dart';
import 'services/book_retriever.dart';
import 'services/book_understanding_client.dart';
import 'services/book_understanding_service.dart';

/// Owns the textbook conversation independently of the reading page.
///
/// Page turns, session changes and panel rebuilds do not clear the conversation;
/// switching to another book switches to that book's conversation, and a late
/// result is always written back to the conversation it belongs to.
class BookQaController extends ChangeNotifier {
  BookQaController({
    required this.study,
    WebSearchProvider Function(ProviderSettings settings)? providerFactory,
  }) : repository = BookQaRepository(study.store) {
    retriever = BookRetriever(store: study.store, repository: repository);
    understandingClient = BookUnderstandingClient(study.gateway.transport);
    understanding = BookUnderstandingService(
      store: study.store,
      repository: repository,
      client: understandingClient,
    );
    service = BookQaService(
      store: study.store,
      repository: repository,
      transport: study.gateway.transport,
      retriever: retriever,
      providerFactory: providerFactory,
    );
  }

  final StudyController study;
  final BookQaRepository repository;
  late final BookRetriever retriever;
  late final BookUnderstandingClient understandingClient;
  late final BookUnderstandingService understanding;
  late final BookQaService service;

  BookConversation? conversation;
  List<BookQaTurn> turns = [];
  UnderstandingProgress? progress;
  BookQaStage stage = BookQaStage.idle;
  bool loading = false;
  bool asking = false;
  bool understandingRunning = false;
  String? error;
  String? notice;

  String? _documentId;
  String? _documentHash;
  PreparedBookQaRequest? _activeRequest;
  bool _cancelRequested = false;
  bool _understandingCancelled = false;
  bool _disposed = false;

  DocumentRecord? get document => study.current;

  bool get hasConversation => conversation != null;

  bool get webAvailable {
    try {
      return service.supportsWeb(study.settings);
    } catch (_) {
      return false;
    }
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  /// Attaches to the currently opened document. A different book starts its own
  /// conversation; the previous one stays in the database.
  void attach(DocumentRecord? document) {
    if (_disposed) return;
    final id = document?.id;
    final hash = document?.contentHash;
    if (id == _documentId && hash == _documentHash) return;
    if (understandingRunning) {
      _understandingCancelled = true;
      understandingRunning = false;
    }
    _activeRequest?.cancel();
    _activeRequest = null;
    _documentId = id;
    _documentHash = hash;
    conversation = null;
    turns = [];
    progress = null;
    error = null;
    notice = null;
    stage = BookQaStage.idle;
    asking = false;
    if (document == null) {
      _emit();
      return;
    }
    loading = true;
    _emit();
    try {
      final active = repository.ensureConversation(document);
      _importLegacy(active, document);
      conversation = active;
      turns = repository.getTurns(active.id);
      repository.normalizeInterruptedJob(document.id);
      progress = repository.progress(document);
    } catch (catchError) {
      error = '教材会话无法读取：$catchError';
    } finally {
      loading = false;
      _emit();
    }
  }

  void _importLegacy(BookConversation conversation, DocumentRecord document) {
    final raw = study.store.getSetting('history:${document.id}');
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final replies = <LegacyBookReply>[];
      for (final item in decoded) {
        if (item is! Map) continue;
        final data = Map<String, dynamic>.from(item);
        if (data['documentHash'] != document.contentHash) continue;
        final task = data['task'] as String?;
        if (task != null &&
            task != 'explain' &&
            task != 'explainTerm' &&
            task != 'explainImage') {
          continue;
        }
        final question = data['question'] as String? ?? '';
        final answer = data['answer'] as String? ?? '';
        if (question.trim().isEmpty || answer.trim().isEmpty) continue;
        final sources = <Evidence>[];
        for (final source in data['sources'] as List? ?? const []) {
          if (source is! Map) continue;
          try {
            sources.add(Evidence.fromJson(Map<String, dynamic>.from(source)));
          } catch (_) {
            // A legacy reply with an unreadable source stays readable as text.
          }
        }
        replies.add(
          LegacyBookReply(
            question: question,
            answer: answer,
            sources: sources,
            model: data['model'] as String? ?? '',
            tokens: (data['tokens'] as num?)?.toInt() ?? 0,
            insufficient: data['insufficient'] as bool? ?? false,
            createdAt: data['createdAt'] is String
                ? DateTime.tryParse(data['createdAt'] as String)
                : null,
          ),
        );
      }
      if (replies.isNotEmpty) {
        repository.importLegacyReplies(conversation, replies);
      }
    } catch (_) {
      // Legacy history is best-effort and must never block the new panel.
    }
  }

  Future<PreparedBookQaRequest> prepare(
    String question, {
    BookAskMode mode = BookAskMode.wholeBookWeb,
    ImageAttachment? image,
  }) async {
    final document = study.current;
    final conversation = this.conversation;
    if (document == null || conversation == null) {
      throw StateError('请先打开一本教材。');
    }
    if (asking) {
      throw StateError('正在等待上一问的回答。');
    }
    final prepared = service.prepare(
      document: document,
      conversation: conversation,
      question: question,
      settings: study.settings,
      mode: mode,
      currentPage: study.page,
      history: _history(),
      image: image,
    );
    return prepared;
  }

  List<BookQaHistoryTurn> _history() {
    final history = <BookQaHistoryTurn>[];
    var characters = 0;
    for (final turn in turns.reversed) {
      final answer = turn.answer;
      if (answer == null || answer.plainText.trim().isEmpty) continue;
      final text = answer.plainText.length <= 1200
          ? answer.plainText
          : '${answer.plainText.substring(0, 1200)}…';
      final length = turn.question.length + text.length;
      if (history.length >= 6 || characters + length > 8000) break;
      history.add(BookQaHistoryTurn(question: turn.question, answer: text));
      characters += length;
    }
    return history.reversed.toList();
  }

  /// Persists the question before any request, then runs the bounded pipeline.
  Future<void> send(
    PreparedBookQaRequest prepared, {
    BookQaImageApproval? imageApproval,
  }) async {
    final conversation = this.conversation;
    final document = study.current;
    if (conversation == null ||
        document == null ||
        document.id != prepared.documentId ||
        document.contentHash != prepared.documentHash) {
      throw const AiFailure(AiError.rejected, '教材或会话已经改变，请重新预览这次提问。');
    }
    if (asking) {
      throw StateError('正在等待上一问的回答。');
    }
    asking = true;
    _cancelRequested = false;
    _activeRequest = prepared;
    stage = BookQaStage.retrievingBook;
    error = null;
    notice = null;
    final turn = repository.appendQuestion(
      conversation,
      prepared.question,
      prepared.mode,
    );
    turns = [...turns, turn];
    _emit();
    try {
      final answer = await service.ask(
        prepared,
        imageApproval: imageApproval,
        onStage: (next) {
          if (_cancelRequested) return;
          stage = next;
          _emit();
        },
      );
      repository.saveAnswer(conversation, turn, answer);
      if (document.id == _documentId) {
        _replaceTurn(turn.withAnswer(answer));
        stage = BookQaStage.done;
        if (_cancelRequested) {
          notice = '已取消后续步骤；已经发出的回答请求返回了结果，已保存。';
        }
        _emit();
      }
    } on AiFailure catch (failure) {
      if (failure.code == AiError.cancelled) {
        repository.saveCancelled(conversation, turn);
        if (document.id == _documentId) {
          _replaceTurn(turn.withCancelled());
          notice = '已取消本次问答，问题已保留。';
        }
      } else {
        repository.saveFailure(conversation, turn, failure.message);
        if (document.id == _documentId) {
          _replaceTurn(turn.withFailure(failure.message));
          error = failure.message;
        }
      }
      _emit();
    } catch (catchError) {
      repository.saveFailure(conversation, turn, '问答未完成。');
      if (document.id == _documentId) {
        _replaceTurn(turn.withFailure('问答未完成。'));
        error = '问答未完成：$catchError';
      }
      _emit();
    } finally {
      asking = false;
      _activeRequest = null;
      if (stage != BookQaStage.done) stage = BookQaStage.idle;
      _emit();
    }
  }

  void cancelAsk() {
    if (!asking) return;
    _cancelRequested = true;
    _activeRequest?.cancel();
    notice = stage == BookQaStage.composing
        ? '回答请求已发出，本次无法退回；到达的结果仍会保存。'
        : '正在取消，后续步骤不会再发送。';
    _emit();
  }

  void clearMessages() {
    error = null;
    notice = null;
    _emit();
  }

  void _replaceTurn(BookQaTurn turn) {
    final index = turns.indexWhere((item) => item.id == turn.id);
    if (index >= 0) {
      turns = [...turns.take(index), turn, ...turns.skip(index + 1)];
    } else {
      turns = [...turns, turn];
    }
  }

  UnderstandingEstimate? estimateUnderstanding() {
    final document = study.current;
    if (document == null) return null;
    try {
      final estimate = understanding.estimate(document);
      progress = repository.progress(document);
      _emit();
      return estimate;
    } catch (catchError) {
      error = catchError.toString();
      _emit();
      return null;
    }
  }

  Future<void> runUnderstanding({int maxChunks = 40}) async {
    final document = study.current;
    if (document == null || understandingRunning || asking) return;
    understandingRunning = true;
    _understandingCancelled = false;
    error = null;
    notice = null;
    _emit();
    try {
      final result = await understanding.run(
        document,
        study.settings,
        maxChunks: maxChunks,
        onProgress: (value) {
          progress = value;
          _emit();
        },
        isCancelled: () => _understandingCancelled,
      );
      progress = result.progress;
      notice = result.note.isEmpty ? null : result.note;
      if (result.cancelled) notice = '已取消教材理解；已完成的分块保留。';
    } on AiFailure catch (failure) {
      error = failure.message;
    } catch (catchError) {
      error = '建立教材理解未完成：$catchError';
    } finally {
      understandingRunning = false;
      _emit();
    }
  }

  void cancelUnderstanding() {
    if (!understandingRunning) return;
    _understandingCancelled = true;
    notice = '正在停止教材理解，当前分块结束后不再发送。';
    _emit();
  }

  void markPagesSkipped(Iterable<int> pages) {
    final document = study.current;
    if (document == null || pages.isEmpty) return;
    try {
      understanding.markPagesSkipped(document, pages);
      progress = repository.progress(document);
      _emit();
    } catch (catchError) {
      error = '标记空白页未完成：$catchError';
      _emit();
    }
  }

  void applyChapters(
    List<({String title, int startPage, int endPage})> chapters,
  ) {
    final document = study.current;
    if (document == null || chapters.isEmpty) return;
    try {
      understanding.applyChapters(document, chapters);
      progress = repository.progress(document);
      notice = '章节已更新；新增或受影响的分块需要继续整理。';
      _emit();
    } catch (catchError) {
      error = '章节未保存：$catchError';
      _emit();
    }
  }

  void refresh() {
    final document = study.current;
    if (document == null || conversation == null) return;
    try {
      turns = repository.getTurns(conversation!.id);
      progress = repository.progress(document);
      _emit();
    } catch (_) {
      /* Keep the last readable state. */
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _understandingCancelled = true;
    _activeRequest?.cancel();
    super.dispose();
  }
}
