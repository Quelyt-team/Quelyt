import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../../../core/local_store.dart';
import '../../../core/models.dart';
import '../../../services/ai_types.dart';
import '../data/book_qa_repository.dart';
import '../models/book_understanding.dart';
import 'book_understanding_client.dart';

class UnderstandingEstimate {
  const UnderstandingEstimate({
    required this.pages,
    required this.chapterCount,
    required this.chunkCount,
    required this.pendingChunks,
    required this.needsOverview,
  });

  final PageParseReport pages;
  final int chapterCount;
  final int chunkCount;
  final int pendingChunks;
  final bool needsOverview;

  int get plannedRequests => pendingChunks + (needsOverview ? 1 : 0);
  bool get hasWork => plannedRequests > 0;
}

class BookUnderstandingResult {
  const BookUnderstandingResult({
    required this.progress,
    required this.processedChunks,
    required this.requests,
    this.cancelled = false,
    this.note = '',
    this.overviewGenerated = false,
  });

  final UnderstandingProgress progress;
  final int processedChunks;
  final int requests;
  final bool cancelled;
  final String note;
  final bool overviewGenerated;
}

/// Builds and maintains the reusable whole-book index.
///
/// A run is bounded by [maxChunks]; pending chunks stay persisted, so the user
/// can continue later. No method silently discards the rest of the book, and
/// every batch writes its result before the next request starts.
class BookUnderstandingService {
  BookUnderstandingService({
    required this.store,
    required this.repository,
    required this.client,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final LocalStore store;
  final BookQaRepository repository;
  final BookUnderstandingClient client;
  final DateTime Function() _now;
  static const Uuid _uuid = Uuid();
  static const int maxPageCharacters = 9000;
  static const int maxPagesPerChunk = 8;
  static const int fallbackChapterPages = 20;
  static const int maxConsecutiveFailures = 3;

  UnderstandingEstimate estimate(DocumentRecord document) {
    ensureStructure(document);
    final progress = repository.progress(document);
    final chunks = repository.getChunks(document.id);
    final pending = chunks
        .where(
          (chunk) =>
              chunk.status == BookChunkStatus.pending ||
              chunk.status == BookChunkStatus.failed,
        )
        .length;
    return UnderstandingEstimate(
      pages: progress.pages,
      chapterCount: progress.chapterCount,
      chunkCount: progress.chunkTotal,
      pendingChunks: pending,
      needsOverview:
          progress.overview == null && pending == 0 && chunks.isNotEmpty,
    );
  }

  /// Creates chapter and chunk records when missing. This is entirely local and
  /// never calls the model, so it is safe to run before the confirmation dialog.
  void ensureStructure(DocumentRecord document) {
    final pages = store.getPages(document.id);
    final report = PageParseReport.fromPages(document.pageCount, pages);
    if (report.readyPages == 0) {
      throw StateError('这本教材还没有可解析的页面文字，请先完成文字提取或 OCR。');
    }
    var chapters = repository.getChapters(document.id);
    if (chapters.isEmpty) {
      chapters = _planChapters(document, pages);
      repository.replaceChapters(document, chapters);
    }
    var chunks = repository.getChunks(document.id);
    if (chunks.isEmpty) {
      chunks = _planChunks(document, chapters, pages);
      repository.saveChunks(chunks);
    } else {
      _refreshStaleChunks(document, chunks, pages);
    }
    final job = repository.getJob(document.id);
    if (job == null || job.documentHash != document.contentHash) {
      repository.saveJob(
        BookUnderstandingJob(
          documentId: document.id,
          documentHash: document.contentHash,
          status: BookJobStatus.paused,
          updatedAt: _now(),
        ),
      );
    } else {
      repository.normalizeInterruptedJob(document.id);
    }
  }

  Future<BookUnderstandingResult> run(
    DocumentRecord document,
    ProviderSettings settings, {
    int maxChunks = 40,
    void Function(UnderstandingProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    ensureStructure(document);
    final chapters = {
      for (final chapter in repository.getChapters(document.id))
        chapter.id: chapter,
    };
    final chunks = repository.getChunks(document.id)
      ..sort((a, b) => a.ordinal.compareTo(b.ordinal));
    final pending = chunks
        .where(
          (chunk) =>
              chunk.status == BookChunkStatus.pending ||
              chunk.status == BookChunkStatus.failed,
        )
        .toList();
    var processed = 0;
    var requests = 0;
    var consecutiveFailures = 0;
    var cancelled = false;
    final notes = <String>[];

    if (pending.isNotEmpty) {
      repository.saveJob(
        BookUnderstandingJob(
          documentId: document.id,
          documentHash: document.contentHash,
          status: BookJobStatus.running,
          overview: repository.getJob(document.id)?.overview,
          revision: (repository.getJob(document.id)?.revision ?? 1) + 1,
          updatedAt: _now(),
          startedAt: _now(),
        ),
      );
      onProgress?.call(repository.progress(document));
    }

    final batch = pending.take(maxChunks).toList();
    for (final chunk in batch) {
      if (isCancelled?.call() ?? false) {
        cancelled = true;
        break;
      }
      final chapter = chapters[chunk.chapterId];
      if (chapter == null) {
        final failed = chunk.copyWith(
          status: BookChunkStatus.failed,
          error: '章节结构已改变，请重新建立教材理解。',
          updatedAt: _now(),
        );
        repository.saveChunk(failed);
        notes.add('有分块缺少章节，已标记失败。');
        continue;
      }
      final pages = store.getPages(document.id);
      try {
        final request = client.prepareChunk(
          settings: settings,
          document: document,
          chapter: chapter,
          chunk: chunk,
          pages: pages,
        );
        final result = await client.sendChunk(request);
        requests++;
        final updated = chunk.copyWith(
          status: BookChunkStatus.ready,
          insight: result.insight,
          clearError: true,
          truncated: request.truncated,
          sourceCharacters: request.characters,
          updatedAt: _now(),
        );
        repository.saveChunk(updated);
        _mergeKnowledgePoints(document, chapter, updated, result.insight);
        consecutiveFailures = 0;
        processed++;
        onProgress?.call(repository.progress(document));
      } on AiFailure catch (error) {
        if (error.code == AiError.cancelled) {
          cancelled = true;
          break;
        }
        requests++;
        consecutiveFailures++;
        repository.saveChunk(
          chunk.copyWith(
            status: BookChunkStatus.failed,
            error: error.message,
            updatedAt: _now(),
          ),
        );
        notes.add(
          '第 ${chunk.startPage}–${chunk.endPage} 页整理失败：${error.message}',
        );
        onProgress?.call(repository.progress(document));
        if (consecutiveFailures >= maxConsecutiveFailures) {
          final stopNote = '连续 $consecutiveFailures 个分块整理失败，已停止以避免继续计费。';
          notes.add(stopNote);
          repository.saveJob(
            BookUnderstandingJob(
              documentId: document.id,
              documentHash: document.contentHash,
              status: BookJobStatus.failed,
              overview: repository.getJob(document.id)?.overview,
              error: stopNote,
              revision: (repository.getJob(document.id)?.revision ?? 1) + 1,
              updatedAt: _now(),
            ),
          );
          return BookUnderstandingResult(
            progress: repository.progress(document),
            processedChunks: processed,
            requests: requests,
            note: notes.join('\n'),
          );
        }
      } catch (error) {
        if (error is StateError) rethrow;
        requests++;
        consecutiveFailures++;
        repository.saveChunk(
          chunk.copyWith(
            status: BookChunkStatus.failed,
            error: '整理未完成。',
            updatedAt: _now(),
          ),
        );
        notes.add('第 ${chunk.startPage}–${chunk.endPage} 页整理未完成。');
      }
    }

    var overviewGenerated = false;
    String? overviewError;
    final remaining = repository
        .getChunks(document.id)
        .where(
          (chunk) =>
              chunk.status == BookChunkStatus.pending ||
              chunk.status == BookChunkStatus.failed,
        )
        .length;
    if (!cancelled && remaining == 0) {
      requests++;
      try {
        overviewGenerated = await _synthesizeOverview(document, settings);
      } on AiFailure catch (error) {
        overviewError = '全书概览未生成：${error.message}';
        notes.add(overviewError);
      }
    }

    final progress = repository.progress(document);
    final complete =
        !cancelled &&
        remaining == 0 &&
        progress.chunkFailed == 0 &&
        progress.pages.allParsed &&
        repository.getJob(document.id)?.overview != null;
    final status = cancelled
        ? BookJobStatus.paused
        : complete
        ? BookJobStatus.complete
        : BookJobStatus.partial;
    repository.saveJob(
      BookUnderstandingJob(
        documentId: document.id,
        documentHash: document.contentHash,
        status: status,
        overview: repository.getJob(document.id)?.overview,
        error: cancelled
            ? '已取消，已完成的分块可以继续使用。'
            : complete
            ? null
            : remaining > 0
            ? '还有 $remaining 个分块待整理。'
            : overviewError ?? '全书概览尚未生成，可再次整理。',
        revision: (repository.getJob(document.id)?.revision ?? 1) + 1,
        updatedAt: _now(),
        startedAt: repository.getJob(document.id)?.startedAt,
        finishedAt: _now(),
      ),
    );
    if (!cancelled && remaining > 0) {
      notes.add('本次已整理 $processed 块，还有 $remaining 块待继续；已保存的结果不会重做。');
    }
    onProgress?.call(repository.progress(document));
    return BookUnderstandingResult(
      progress: repository.progress(document),
      processedChunks: processed,
      requests: requests,
      cancelled: cancelled,
      note: notes.join('\n'),
      overviewGenerated: overviewGenerated,
    );
  }

  Future<bool> _synthesizeOverview(
    DocumentRecord document,
    ProviderSettings settings,
  ) async {
    final chapters = repository.getChapters(document.id);
    final chunks = {
      for (final chunk in repository.getChunks(document.id)) chunk.id: chunk,
    };
    if (!chunks.values.any((chunk) => chunk.status == BookChunkStatus.ready)) {
      return false;
    }
    final request = client.prepareOverview(
      settings: settings,
      document: document,
      chapters: chapters,
      chunks: chunks,
    );
    final result = await client.sendOverview(request);
    final progress = repository.progress(document);
    final unfinished = <String>[
      for (final chapter in chapters)
        if (!chunks.values.any(
          (chunk) =>
              chunk.chapterId == chapter.id &&
              chunk.status == BookChunkStatus.ready &&
              chunk.insight != null,
        ))
          '${chapter.title}（${chapter.rangeLabel}）尚未整理',
    ];
    if (!progress.pages.allParsed) {
      unfinished.add('${progress.pages.gapLabel}的文字尚不可用');
    }
    repository.saveJob(
      BookUnderstandingJob(
        documentId: document.id,
        documentHash: document.contentHash,
        status: repository.getJob(document.id)?.status ?? BookJobStatus.partial,
        overview: BookOverview(
          subject: result.overview.subject,
          conventions: result.overview.conventions,
          chapterRelations: result.overview.chapterRelations,
          themes: result.overview.themes,
          unfinished: [
            ...result.overview.unfinished,
            ...unfinished,
          ].take(8).toList(),
          generatedAt: _now(),
        ),
        error: repository.getJob(document.id)?.error,
        revision: (repository.getJob(document.id)?.revision ?? 1) + 1,
        updatedAt: _now(),
        startedAt: repository.getJob(document.id)?.startedAt,
      ),
    );
    return true;
  }

  void _mergeKnowledgePoints(
    DocumentRecord document,
    BookChapter chapter,
    BookChunk chunk,
    BookChunkInsight insight,
  ) {
    if (insight.terms.isEmpty) return;
    final existing = {
      for (final point in repository.getKnowledgePoints(
        document.id,
        chapterId: chapter.id,
      ))
        point.id: point,
    };
    final merged = <String, BookKnowledgePoint>{};
    for (final term in insight.terms) {
      final norm = normalizeBookTerm(term.term);
      if (norm.isEmpty) continue;
      final id =
          '${document.id}:kp:${sha1.convert(utf8.encode('${chapter.id}:$norm')).toString()}';
      final pages = term.pages.isEmpty ? [chunk.startPage] : term.pages;
      final current = existing[id] ?? merged[id];
      final aliases = <String>{
        if (current != null) ...current.aliases,
        term.term,
        if (term.englishAlias.isNotEmpty) term.englishAlias,
        if (term.symbol.isNotEmpty) term.symbol,
      }.take(8).toList();
      final definition =
          (current?.definition.length ?? 0) >= term.definition.length
          ? current?.definition ?? term.definition
          : term.definition;
      final start = current == null
          ? pages.reduce((a, b) => a < b ? a : b)
          : [current.startPage, ...pages].reduce((a, b) => a < b ? a : b);
      final end = current == null
          ? pages.reduce((a, b) => a > b ? a : b)
          : [current.endPage, ...pages].reduce((a, b) => a > b ? a : b);
      final point = BookKnowledgePoint(
        id: id,
        documentId: document.id,
        documentHash: document.contentHash,
        chapterId: chapter.id,
        term: current?.term ?? term.term,
        termNorm: norm,
        startPage: start.clamp(1, document.pageCount),
        endPage: end.clamp(1, document.pageCount),
        englishAlias: term.englishAlias.isNotEmpty
            ? term.englishAlias
            : current?.englishAlias ?? '',
        symbol: term.symbol.isNotEmpty ? term.symbol : current?.symbol ?? '',
        definition: definition,
        aliases: aliases,
        relatedTerms: current?.relatedTerms ?? const [],
        prerequisiteTerms: current?.prerequisiteTerms ?? const [],
        verified: pages.isNotEmpty,
        revision: (current?.revision ?? 0) + 1,
        updatedAt: _now(),
      );
      merged[id] = point;
    }
    repository.saveKnowledgePoints(merged.values.toList());
  }

  List<BookChapter> _planChapters(
    DocumentRecord document,
    List<PageRecord> pages,
  ) {
    final byPage = {for (final page in pages) page.page: page};
    final starts = <int, String>{};
    for (var page = 1; page <= document.pageCount; page++) {
      final text = byPage[page]?.text.trim() ?? '';
      if (text.isEmpty) continue;
      final heading = _majorHeading(text);
      if (heading != null) starts[page] = heading;
    }
    // A single heading at page 1 is not enough evidence to claim a real table
    // of contents; fall back to temporary page-range chapters.
    final detected =
        starts.length >= 2 || (starts.length == 1 && starts.keys.single > 1);
    if (!detected) {
      final result = <BookChapter>[];
      final count = (document.pageCount / fallbackChapterPages).ceil();
      for (var index = 0; index < count; index++) {
        final start = index * fallbackChapterPages + 1;
        final end = ((index + 1) * fallbackChapterPages).clamp(
          1,
          document.pageCount,
        );
        result.add(
          _chapter(
            document,
            index,
            '第 ${index + 1} 部分（第 $start–$end 页）',
            start,
            end,
            generated: true,
          ),
        );
      }
      return result;
    }
    final ordered = starts.keys.toList()..sort();
    final result = <BookChapter>[];
    var ordinal = 0;
    if (ordered.first > 1) {
      result.add(
        _chapter(
          document,
          ordinal++,
          '开篇（第 1–${ordered.first - 1} 页）',
          1,
          ordered.first - 1,
          generated: true,
        ),
      );
    }
    for (var index = 0; index < ordered.length; index++) {
      final start = ordered[index];
      final end = index + 1 < ordered.length
          ? ordered[index + 1] - 1
          : document.pageCount;
      if (end < start) continue;
      result.add(_chapter(document, ordinal++, starts[start]!, start, end));
    }
    return result;
  }

  BookChapter _chapter(
    DocumentRecord document,
    int ordinal,
    String title,
    int start,
    int end, {
    bool generated = false,
  }) => BookChapter(
    id: _uuid.v4(),
    documentId: document.id,
    documentHash: document.contentHash,
    ordinal: ordinal,
    title: title.length <= 90 ? title : '${title.substring(0, 90)}…',
    startPage: start,
    endPage: end,
    generated: generated,
    updatedAt: _now(),
  );

  /// Only top-level headings start a chapter. Subsection headings such as
  /// “1.2 速度” stay inside their chapter.
  static String? _majorHeading(String text) {
    final first = text
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.trim())
        .firstWhere((line) => line.isNotEmpty, orElse: () => '');
    if (first.isEmpty || first.length > 90) return null;
    if (RegExp(r'^第\s*[0-9一二三四五六七八九十百零〇]+\s*[章篇部]').hasMatch(first)) {
      return first;
    }
    if (RegExp(r'^Chapter\s+\d+\b', caseSensitive: false).hasMatch(first)) {
      return first;
    }
    if (RegExp(r'^\d{1,2}\s+\S').hasMatch(first) &&
        !RegExp(r'^\d{1,2}[.．]\d').hasMatch(first)) {
      return first;
    }
    return null;
  }

  List<BookChunk> _planChunks(
    DocumentRecord document,
    List<BookChapter> chapters,
    List<PageRecord> pages,
  ) {
    final byPage = {for (final page in pages) page.page: page};
    final chunks = <BookChunk>[];
    var ordinal = 0;
    for (final chapter in chapters) {
      final ready = <PageRecord>[];
      for (var page = chapter.startPage; page <= chapter.endPage; page++) {
        final record = byPage[page];
        if (record != null &&
            record.status == PageStatus.ready &&
            record.text.trim().isNotEmpty) {
          ready.add(record);
        }
      }
      var index = 0;
      while (index < ready.length) {
        final group = <PageRecord>[];
        var characters = 0;
        while (index < ready.length && group.length < maxPagesPerChunk) {
          final page = ready[index];
          final length = page.text.trim().length;
          if (group.isNotEmpty && characters + length > maxPageCharacters) {
            break;
          }
          group.add(page);
          characters += length;
          index++;
        }
        final start = group.first.page;
        final end = group.last.page;
        final digest = _digest(document, group);
        chunks.add(
          BookChunk(
            id: _uuid.v4(),
            documentId: document.id,
            documentHash: document.contentHash,
            chapterId: chapter.id,
            ordinal: ordinal++,
            startPage: start,
            endPage: end,
            sourceDigest: digest,
            sourceCharacters: characters,
            updatedAt: _now(),
          ),
        );
      }
    }
    return chunks;
  }

  String _digest(DocumentRecord document, List<PageRecord> pages) {
    final buffer = StringBuffer('${document.id}\n${document.contentHash}\n');
    for (final page in pages) {
      buffer.writeln('${page.page}:${page.text.trim()}');
    }
    return sha256.convert(utf8.encode(buffer.toString())).toString();
  }

  void _refreshStaleChunks(
    DocumentRecord document,
    List<BookChunk> chunks,
    List<PageRecord> pages,
  ) {
    final byPage = {for (final page in pages) page.page: page};
    final changed = <BookChunk>[];
    final invalidatedChapters = <String>{};
    var overviewInvalidated = false;
    for (final chunk in chunks) {
      final source = <PageRecord>[
        for (var page = chunk.startPage; page <= chunk.endPage; page++)
          if (byPage[page] != null) byPage[page]!,
      ];
      if (source.isEmpty) continue;
      final digest = _digest(document, source);
      if (chunk.sourceDigest.isEmpty) {
        changed.add(
          chunk.copyWith(
            sourceDigest: digest,
            sourceCharacters: source.fold<int>(
              0,
              (sum, page) => sum + page.text.trim().length,
            ),
            updatedAt: _now(),
          ),
        );
      } else if (digest != chunk.sourceDigest &&
          chunk.status != BookChunkStatus.pending) {
        // Only the affected chunk is rebuilt; completed neighbours are kept.
        if (chunk.status == BookChunkStatus.ready) {
          overviewInvalidated = true;
          if (chunk.chapterId != null) {
            invalidatedChapters.add(chunk.chapterId!);
          }
        }
        changed.add(
          chunk.copyWith(
            status: BookChunkStatus.pending,
            clearError: true,
            sourceDigest: digest,
            sourceCharacters: source.fold<int>(
              0,
              (sum, page) => sum + page.text.trim().length,
            ),
            updatedAt: _now(),
          ),
        );
      }
    }
    if (changed.isEmpty) return;
    repository.saveChunks(changed);
    for (final chapterId in invalidatedChapters) {
      repository.deleteKnowledgePointsForChapter(document.id, chapterId);
    }
    if (overviewInvalidated) {
      final job = repository.getJob(document.id);
      if (job != null) {
        repository.saveJob(
          BookUnderstandingJob(
            documentId: document.id,
            documentHash: document.contentHash,
            status: BookJobStatus.paused,
            overview: null,
            error: '页面文字已更新，相关分块与全书概览需要重新整理。',
            revision: job.revision + 1,
            updatedAt: _now(),
            startedAt: job.startedAt,
            finishedAt: job.finishedAt,
          ),
        );
      }
    }
  }

  /// Marks cover or blank pages as deliberately skipped. A skipped page is
  /// stored as ready with empty text, so coverage can reach 100% without
  /// pretending the page contained readable content.
  void markPagesSkipped(DocumentRecord document, Iterable<int> pages) {
    for (final page in pages) {
      if (page < 1 || page > document.pageCount) {
        throw RangeError.range(page, 1, document.pageCount, 'page');
      }
      store.savePage(
        PageRecord(
          documentId: document.id,
          page: page,
          text: '',
          status: PageStatus.ready,
          manuallyCorrected: true,
        ),
      );
    }
  }

  /// Applies user-edited chapter boundaries and rebuilds dependent chunks.
  void applyChapters(
    DocumentRecord document,
    List<({String title, int startPage, int endPage})> chapters,
  ) {
    if (chapters.isEmpty) throw ArgumentError('至少需要一章。');
    final sorted = [...chapters]
      ..sort((a, b) => a.startPage.compareTo(b.startPage));
    var expected = 1;
    final result = <BookChapter>[];
    for (var index = 0; index < sorted.length; index++) {
      final item = sorted[index];
      if (item.startPage != expected || item.endPage < item.startPage) {
        throw ArgumentError('章节必须从第 1 页开始连续覆盖全书。');
      }
      result.add(
        _chapter(
          document,
          index,
          item.title.trim().isEmpty ? '第 ${index + 1} 章' : item.title.trim(),
          item.startPage,
          item.endPage,
        ),
      );
      expected = item.endPage + 1;
    }
    if (expected != document.pageCount + 1) {
      throw ArgumentError('章节必须连续覆盖到最后一页。');
    }
    repository.replaceChapters(document, result);
    ensureStructure(document);
  }
}
