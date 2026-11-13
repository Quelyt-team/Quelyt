import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../../../core/local_store.dart';
import '../../../core/models.dart';
import '../../../services/ai_types.dart';
import '../models/book_qa_models.dart';
import '../models/book_understanding.dart';

/// One pre-book-QA reply decoded from the legacy `history:<document>` setting.
/// It is imported once so an existing library does not lose its questions when
/// the new textbook conversation is created.
class LegacyBookReply {
  const LegacyBookReply({
    required this.question,
    required this.answer,
    required this.sources,
    required this.model,
    this.tokens = 0,
    this.insufficient = false,
    this.createdAt,
  });

  final String question;
  final String answer;
  final List<Evidence> sources;
  final String model;
  final int tokens;
  final bool insufficient;
  final DateTime? createdAt;
}

/// All textbook-understanding, conversation and web-cache persistence.
///
/// Feature code uses this repository instead of writing SQL. The underlying
/// [LocalStore] connection is shared, so a question and its source snapshot can
/// be written in one transaction and deleting a textbook cascades through
/// every related table.
class BookQaRepository {
  BookQaRepository(this.store);

  final LocalStore store;
  static const Uuid _uuid = Uuid();
  static const int maxTurnsPerConversation = 400;

  Map<String, dynamic> _decode(Object? value) =>
      Map<String, dynamic>.from(jsonDecode(value as String) as Map);

  DocumentRecord _requireDocument(String id, [String? hash]) {
    final document = store.getDocument(id);
    if (document == null) {
      throw ArgumentError('这本教材已不在书库中。');
    }
    if (hash != null && hash != document.contentHash) {
      throw ArgumentError('教材版本已经改变。');
    }
    return document;
  }

  // ---------------------------------------------------------------------------
  // Conversations
  // ---------------------------------------------------------------------------

  BookConversation? findConversation(String documentId, String documentHash) {
    final rows = store.selectRows(
      '''SELECT data FROM book_qa_conversations
      WHERE document_id = ? AND document_hash = ?
      ORDER BY updated_at DESC LIMIT 1''',
      [documentId, documentHash],
    );
    return rows.isEmpty ? null : _conversation(rows.first);
  }

  BookConversation ensureConversation(DocumentRecord document) {
    _requireDocument(document.id, document.contentHash);
    final existing = findConversation(document.id, document.contentHash);
    if (existing != null) return existing;
    final now = DateTime.now();
    final conversation = BookConversation(
      id: _uuid.v4(),
      documentId: document.id,
      documentHash: document.contentHash,
      title: document.title,
      createdAt: now,
      updatedAt: now,
    );
    store.executeSql(
      '''INSERT INTO book_qa_conversations
      (id, document_id, document_hash, created_at, updated_at, data)
      VALUES (?, ?, ?, ?, ?, ?)''',
      [
        conversation.id,
        conversation.documentId,
        conversation.documentHash,
        now.millisecondsSinceEpoch,
        now.millisecondsSinceEpoch,
        jsonEncode(conversation.toJson()),
      ],
    );
    return conversation;
  }

  BookConversation? getConversation(String id) {
    final rows = store.selectRows(
      'SELECT data FROM book_qa_conversations WHERE id = ?',
      [id],
    );
    return rows.isEmpty ? null : _conversation(rows.first);
  }

  BookConversation _conversation(Map<String, Object?> row) =>
      BookConversation.fromJson(_decode(row['data']));

  void _touchConversation(BookConversation conversation, {String? title}) {
    final now = DateTime.now();
    final stored = getConversation(conversation.id) ?? conversation;
    final updated = stored.copyWith(title: title, updatedAt: now);
    store.executeSql(
      '''UPDATE book_qa_conversations
      SET updated_at = ?, data = ? WHERE id = ?''',
      [
        updated.updatedAt.millisecondsSinceEpoch,
        jsonEncode(updated.toJson()),
        updated.id,
      ],
    );
  }

  int _nextSequence(String conversationId) {
    final rows = store.selectRows(
      '''SELECT COALESCE(MAX(sequence), -1) AS maximum
      FROM book_qa_messages WHERE conversation_id = ?''',
      [conversationId],
    );
    final value = rows.isEmpty ? -1 : (rows.first['maximum'] as num).toInt();
    return value + 1;
  }

  /// Persists the question before any network request, so a crash or a
  /// cancelled run still leaves a visible, resumable turn.
  BookQaTurn appendQuestion(
    BookConversation conversation,
    String question,
    BookAskMode mode,
  ) {
    _requireConversation(conversation);
    final trimmed = question.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('问题不能为空。');
    }
    final now = DateTime.now();
    final sequence = _nextSequence(conversation.id);
    final turn = BookQaTurn(
      id: _uuid.v4(),
      conversationId: conversation.id,
      sequence: sequence,
      question: trimmed,
      askedAt: now,
      mode: mode,
    );
    store.transact(() {
      store.executeSql(
        '''INSERT INTO book_qa_messages
        (id, conversation_id, sequence, role, created_at, data)
        VALUES (?, ?, ?, 'question', ?, ?)''',
        [
          turn.id,
          turn.conversationId,
          turn.sequence,
          now.millisecondsSinceEpoch,
          jsonEncode(turn.toQuestionJson()),
        ],
      );
      final title = sequence == 0
          ? (trimmed.length <= 60 ? trimmed : '${trimmed.substring(0, 60)}…')
          : null;
      _touchConversation(conversation, title: title);
    });
    return turn;
  }

  void saveAnswer(
    BookConversation conversation,
    BookQaTurn turn,
    BookQaAnswer answer,
  ) {
    _requireConversation(conversation);
    _writeAnswerRow(conversation, turn.answerSequence, {
      'answer': answer.toJson(),
    }, answer.createdAt);
  }

  void saveFailure(
    BookConversation conversation,
    BookQaTurn turn,
    String message,
  ) {
    _requireConversation(conversation);
    _writeAnswerRow(conversation, turn.answerSequence, {
      'failure': message,
    }, DateTime.now());
  }

  void saveCancelled(BookConversation conversation, BookQaTurn turn) {
    _requireConversation(conversation);
    _writeAnswerRow(conversation, turn.answerSequence, {
      'cancelled': true,
    }, DateTime.now());
  }

  void _writeAnswerRow(
    BookConversation conversation,
    int sequence,
    Map<String, dynamic> data,
    DateTime createdAt,
  ) {
    store.transact(() {
      store.executeSql(
        '''INSERT INTO book_qa_messages
        (id, conversation_id, sequence, role, created_at, data)
        VALUES (?, ?, ?, 'answer', ?, ?)
        ON CONFLICT(conversation_id, sequence) DO UPDATE SET
          role = excluded.role,
          created_at = excluded.created_at,
          data = excluded.data''',
        [
          '${conversation.id}:$sequence',
          conversation.id,
          sequence,
          createdAt.millisecondsSinceEpoch,
          jsonEncode(data),
        ],
      );
      _touchConversation(conversation);
    });
  }

  void _requireConversation(BookConversation conversation) {
    _requireDocument(conversation.documentId, conversation.documentHash);
    final stored = getConversation(conversation.id);
    if (stored == null) {
      throw ArgumentError('教材会话已不存在。');
    }
  }

  List<BookQaTurn> getTurns(String conversationId, {int limit = 200}) {
    final bounded = limit.clamp(1, maxTurnsPerConversation);
    final rows = store
        .selectRows(
          '''SELECT id, sequence, role, data FROM book_qa_messages
      WHERE conversation_id = ? ORDER BY sequence DESC LIMIT ?''',
          [conversationId, bounded * 2],
        )
        .toList();
    // The query is descending to keep the newest turns when a limit applies.
    final turns = <BookQaTurn>[];
    for (final row in rows.reversed) {
      final data = _decode(row['data']);
      if (row['role'] == 'question') {
        turns.add(
          BookQaTurn.fromQuestionJson(
            id: row['id'] as String,
            conversationId: conversationId,
            sequence: (row['sequence'] as num).toInt(),
            json: data,
          ),
        );
        continue;
      }
      if (turns.isEmpty) continue;
      final last = turns.last;
      if (data['answer'] is Map) {
        turns[turns.length - 1] = last.withAnswer(
          BookQaAnswer.fromJson(
            Map<String, dynamic>.from(data['answer'] as Map),
          ),
        );
      } else if (data['failure'] is String) {
        turns[turns.length - 1] = last.withFailure(data['failure'] as String);
      } else if (data['cancelled'] == true) {
        turns[turns.length - 1] = last.withCancelled();
      }
    }
    return turns.length <= bounded
        ? turns
        : turns.sublist(turns.length - bounded);
  }

  bool hasTurns(String conversationId) => store
      .selectRows(
        '''SELECT 1 AS present FROM book_qa_messages
        WHERE conversation_id = ? LIMIT 1''',
        [conversationId],
      )
      .isNotEmpty;

  /// Imports legacy replies exactly once. Their source excerpts are retained
  /// as book citations; the old `history:` setting is left untouched so a
  /// rollback can still read it.
  int importLegacyReplies(
    BookConversation conversation,
    List<LegacyBookReply> replies,
  ) {
    if (replies.isEmpty) return 0;
    if (hasTurns(conversation.id)) return 0;
    var imported = 0;
    for (final reply in replies.take(50)) {
      if (reply.question.trim().isEmpty || reply.answer.trim().isEmpty) {
        continue;
      }
      final turn = appendQuestion(
        conversation,
        reply.question,
        BookAskMode.bookOnly,
      );
      final sources = <BookCitation>[];
      for (var index = 0; index < reply.sources.length; index++) {
        sources.add(
          BookCitation(id: 'B${index + 1}', evidence: reply.sources[index]),
        );
      }
      final answer = BookQaAnswer(
        answerStatus: reply.insufficient
            ? AnswerStatus.partial
            : AnswerStatus.answered,
        blocks: [BookAnswerBlock(text: reply.answer)],
        coverage: const BookCoverage(
          scope: '旧版问答（页段范围按当时设置）',
          wholeBookSearched: false,
          understandingComplete: false,
          parsedPages: 0,
          totalPages: 0,
          note: '旧版回答按当时的证据范围保存；未记录联网状态。',
        ),
        webStatus: WebLookupStatus.notNeeded,
        bookSources: sources,
        webSources: const [],
        usage: BookQaUsage(
          answer: TokenUsage(
            promptTokens: 0,
            completionTokens: 0,
            totalTokens: reply.tokens,
          ),
        ),
        model: reply.model,
        provider: '旧版记录',
        requestId: '',
        webNote: '旧版回答。',
        createdAt: reply.createdAt ?? turn.askedAt,
      );
      saveAnswer(conversation, turn, answer);
      imported++;
    }
    return imported;
  }

  // ---------------------------------------------------------------------------
  // Whole-book understanding
  // ---------------------------------------------------------------------------

  BookUnderstandingJob? getJob(String documentId) {
    final document = _requireDocument(documentId);
    final rows = store.selectRows(
      'SELECT data FROM book_understanding_jobs WHERE document_id = ?',
      [documentId],
    );
    if (rows.isEmpty) return null;
    final job = BookUnderstandingJob.fromJson(_decode(rows.first['data']));
    return job.documentHash == document.contentHash ? job : null;
  }

  void saveJob(BookUnderstandingJob job) {
    _requireDocument(job.documentId, job.documentHash);
    final stamp = job.updatedAt ?? DateTime.now();
    store.executeSql(
      '''INSERT INTO book_understanding_jobs
      (document_id, document_hash, status, revision, updated_at, data)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(document_id) DO UPDATE SET
        document_hash = excluded.document_hash,
        status = excluded.status,
        revision = excluded.revision,
        updated_at = excluded.updated_at,
        data = excluded.data''',
      [
        job.documentId,
        job.documentHash,
        job.status.name,
        job.revision,
        stamp.millisecondsSinceEpoch,
        jsonEncode(job.toJson()),
      ],
    );
  }

  /// A job left in `running` belongs to a previous process. Marking it paused
  /// keeps the UI honest and lets the user continue the same chunks.
  BookUnderstandingJob? normalizeInterruptedJob(String documentId) {
    final job = getJob(documentId);
    if (job == null || job.status != BookJobStatus.running) return job;
    final paused = BookUnderstandingJob(
      documentId: job.documentId,
      documentHash: job.documentHash,
      status: BookJobStatus.paused,
      overview: job.overview,
      error: '上次整理在完成前停止，可继续处理剩余分块。',
      revision: job.revision,
      updatedAt: DateTime.now(),
      startedAt: job.startedAt,
      finishedAt: job.finishedAt,
    );
    saveJob(paused);
    return paused;
  }

  List<BookChapter> getChapters(String documentId) {
    _requireDocument(documentId);
    return store
        .selectRows(
          '''SELECT data FROM book_chapters
          WHERE document_id = ? ORDER BY ordinal, start_page''',
          [documentId],
        )
        .map((row) => BookChapter.fromJson(_decode(row['data'])))
        .toList();
  }

  /// Replaces the chapter structure. Chunks and knowledge points depend on
  /// chapter boundaries, so they are rebuilt together.
  void replaceChapters(DocumentRecord document, List<BookChapter> chapters) {
    _requireDocument(document.id, document.contentHash);
    for (final chapter in chapters) {
      if (chapter.documentId != document.id ||
          chapter.documentHash != document.contentHash ||
          chapter.startPage < 1 ||
          chapter.endPage > document.pageCount ||
          chapter.endPage < chapter.startPage) {
        throw ArgumentError('章节页段超出教材范围。');
      }
    }
    store.transact(() {
      store.executeSql('DELETE FROM book_chunks WHERE document_id = ?', [
        document.id,
      ]);
      store.executeSql(
        'DELETE FROM book_knowledge_points WHERE document_id = ?',
        [document.id],
      );
      store.executeSql('DELETE FROM book_chapters WHERE document_id = ?', [
        document.id,
      ]);
      for (final chapter in chapters) {
        store.executeSql(
          '''INSERT INTO book_chapters
          (id, document_id, document_hash, ordinal, start_page, end_page,
           title, revision, updated_at, data)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
          [
            chapter.id,
            chapter.documentId,
            chapter.documentHash,
            chapter.ordinal,
            chapter.startPage,
            chapter.endPage,
            chapter.title,
            chapter.revision,
            chapter.updatedAt.millisecondsSinceEpoch,
            jsonEncode(chapter.toJson()),
          ],
        );
      }
    });
  }

  List<BookChunk> getChunks(String documentId) {
    _requireDocument(documentId);
    return store
        .selectRows(
          '''SELECT data FROM book_chunks
          WHERE document_id = ? ORDER BY ordinal''',
          [documentId],
        )
        .map((row) => BookChunk.fromJson(_decode(row['data'])))
        .toList();
  }

  BookChunk? getChunk(String documentId, String chunkId) {
    final rows = store.selectRows(
      '''SELECT data FROM book_chunks
      WHERE document_id = ? AND id = ?''',
      [documentId, chunkId],
    );
    return rows.isEmpty
        ? null
        : BookChunk.fromJson(_decode(rows.first['data']));
  }

  void saveChunk(BookChunk chunk) => saveChunks([chunk]);

  void saveChunks(List<BookChunk> chunks) {
    if (chunks.isEmpty) return;
    final document = _requireDocument(chunks.first.documentId);
    for (final chunk in chunks) {
      if (chunk.documentId != document.id ||
          chunk.documentHash != document.contentHash ||
          chunk.startPage < 1 ||
          chunk.endPage > document.pageCount ||
          chunk.endPage < chunk.startPage) {
        throw ArgumentError('分块页段超出教材范围。');
      }
      if (chunk.chapterId != null) {
        final chapter = store.selectRows(
          'SELECT 1 AS present FROM book_chapters WHERE id = ? AND document_id = ?',
          [chunk.chapterId, document.id],
        );
        if (chapter.isEmpty) {
          throw ArgumentError('分块引用了不属于这本教材的章节。');
        }
      }
    }
    store.transact(() {
      for (final chunk in chunks) {
        store.executeSql(
          '''INSERT INTO book_chunks
          (id, document_id, chapter_id, document_hash, ordinal, start_page,
           end_page, status, revision, updated_at, data)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            chapter_id = excluded.chapter_id,
            ordinal = excluded.ordinal,
            start_page = excluded.start_page,
            end_page = excluded.end_page,
            status = excluded.status,
            revision = excluded.revision,
            updated_at = excluded.updated_at,
            data = excluded.data''',
          [
            chunk.id,
            chunk.documentId,
            chunk.chapterId,
            chunk.documentHash,
            chunk.ordinal,
            chunk.startPage,
            chunk.endPage,
            chunk.status.name,
            chunk.revision,
            (chunk.updatedAt ?? DateTime.now()).millisecondsSinceEpoch,
            jsonEncode(chunk.toJson()),
          ],
        );
      }
    });
  }

  void deleteChunks(String documentId) {
    _requireDocument(documentId);
    store.executeSql('DELETE FROM book_chunks WHERE document_id = ?', [
      documentId,
    ]);
  }

  List<BookKnowledgePoint> getKnowledgePoints(
    String documentId, {
    String? chapterId,
  }) {
    _requireDocument(documentId);
    final rows = chapterId == null
        ? store.selectRows(
            '''SELECT data FROM book_knowledge_points
            WHERE document_id = ? ORDER BY start_page, term''',
            [documentId],
          )
        : store.selectRows(
            '''SELECT data FROM book_knowledge_points
            WHERE document_id = ? AND chapter_id = ?
            ORDER BY start_page, term''',
            [documentId, chapterId],
          );
    return rows
        .map((row) => BookKnowledgePoint.fromJson(_decode(row['data'])))
        .toList();
  }

  void saveKnowledgePoints(List<BookKnowledgePoint> points) {
    if (points.isEmpty) return;
    final document = _requireDocument(points.first.documentId);
    for (final point in points) {
      if (point.documentId != document.id ||
          point.documentHash != document.contentHash ||
          point.startPage < 1 ||
          point.endPage > document.pageCount ||
          point.endPage < point.startPage) {
        throw ArgumentError('知识点页码超出教材范围。');
      }
    }
    store.transact(() {
      for (final point in points) {
        store.executeSql(
          '''INSERT INTO book_knowledge_points
          (id, document_id, chapter_id, document_hash, term, term_norm,
           start_page, end_page, revision, updated_at, data)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            chapter_id = excluded.chapter_id,
            term = excluded.term,
            term_norm = excluded.term_norm,
            start_page = excluded.start_page,
            end_page = excluded.end_page,
            revision = excluded.revision,
            updated_at = excluded.updated_at,
            data = excluded.data''',
          [
            point.id,
            point.documentId,
            point.chapterId,
            point.documentHash,
            point.term,
            point.termNorm,
            point.startPage,
            point.endPage,
            point.revision,
            (point.updatedAt ?? DateTime.now()).millisecondsSinceEpoch,
            jsonEncode(point.toJson()),
          ],
        );
      }
    });
  }

  void deleteKnowledgePointsForChapter(String documentId, String chapterId) {
    _requireDocument(documentId);
    store.executeSql(
      'DELETE FROM book_knowledge_points WHERE document_id = ? AND chapter_id = ?',
      [documentId, chapterId],
    );
  }

  void deleteUnderstanding(String documentId) {
    _requireDocument(documentId);
    store.transact(() {
      store.executeSql(
        'DELETE FROM book_understanding_jobs WHERE document_id = ?',
        [documentId],
      );
      store.executeSql('DELETE FROM book_chunks WHERE document_id = ?', [
        documentId,
      ]);
      store.executeSql(
        'DELETE FROM book_knowledge_points WHERE document_id = ?',
        [documentId],
      );
      store.executeSql('DELETE FROM book_chapters WHERE document_id = ?', [
        documentId,
      ]);
    });
  }

  UnderstandingProgress progress(DocumentRecord document) {
    final pages = store.getPages(document.id);
    final report = PageParseReport.fromPages(document.pageCount, pages);
    final job = getJob(document.id);
    final chapters = getChapters(document.id);
    final chunks = getChunks(document.id);
    return UnderstandingProgress(
      pages: report,
      status: job?.status ?? BookJobStatus.idle,
      chapterCount: chapters.length,
      chunkTotal: chunks.length,
      chunkReady: chunks
          .where((chunk) => chunk.status == BookChunkStatus.ready)
          .length,
      chunkFailed: chunks
          .where((chunk) => chunk.status == BookChunkStatus.failed)
          .length,
      overview: job?.overview,
      error: job?.error,
    );
  }

  // ---------------------------------------------------------------------------
  // Web cache
  // ---------------------------------------------------------------------------

  String webCacheKey(String url) {
    final uri = Uri.tryParse(url.trim());
    final normalized = uri == null
        ? url.trim()
        : uri.replace(fragment: '').toString();
    return sha256.convert(utf8.encode(normalized)).toString();
  }

  WebCacheEntry? getCachedPage(String url, {Duration? maxAge}) {
    final rows = store.selectRows(
      'SELECT data FROM web_source_cache WHERE url_hash = ?',
      [webCacheKey(url)],
    );
    if (rows.isEmpty) return null;
    final entry = WebCacheEntry.fromJson(_decode(rows.first['data']));
    if (maxAge != null && DateTime.now().difference(entry.fetchedAt) > maxAge) {
      return null;
    }
    return entry;
  }

  void saveCachedPage(WebCacheEntry entry) {
    if (entry.url.trim().isEmpty || entry.content.trim().isEmpty) return;
    store.executeSql(
      '''INSERT INTO web_source_cache
      (url_hash, url, title, fetched_at, data)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(url_hash) DO UPDATE SET
        url = excluded.url,
        title = excluded.title,
        fetched_at = excluded.fetched_at,
        data = excluded.data''',
      [
        webCacheKey(entry.url),
        entry.url,
        entry.title,
        entry.fetchedAt.millisecondsSinceEpoch,
        jsonEncode(entry.toJson()),
      ],
    );
  }

  int pruneWebCache({Duration maxAge = const Duration(days: 30)}) {
    final cutoff = DateTime.now().subtract(maxAge).millisecondsSinceEpoch;
    store.executeSql('DELETE FROM web_source_cache WHERE fetched_at < ?', [
      cutoff,
    ]);
    return store
            .selectRows('SELECT COUNT(*) AS total FROM web_source_cache')
            .first['total']
        as int;
  }
}
