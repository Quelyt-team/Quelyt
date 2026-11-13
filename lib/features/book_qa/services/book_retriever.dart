import '../../../core/local_store.dart';
import '../../../core/models.dart';
import '../../../core/search_index.dart';
import '../data/book_qa_repository.dart';
import '../models/book_qa_models.dart';
import '../models/book_understanding.dart';

/// What the question is asking for. This drives retrieval and the web query
/// plan; it is not shown to the model as a label.
class BookQuestionAnalysis {
  const BookQuestionAnalysis({
    required this.question,
    required this.normalized,
    required this.terms,
    required this.aliases,
    this.focusPage,
    this.asksWhy = false,
    this.asksExample = false,
    this.asksLatest = false,
    this.asksAuthor = false,
    this.asksRelation = false,
  });

  final String question;
  final String normalized;
  final List<String> terms;
  final List<String> aliases;
  final int? focusPage;
  final bool asksWhy;
  final bool asksExample;
  final bool asksLatest;
  final bool asksAuthor;
  final bool asksRelation;

  String get focusPageLabel => focusPage?.toString() ?? '当前';
}

class BookRetrieval {
  const BookRetrieval({
    required this.document,
    required this.analysis,
    required this.evidence,
    required this.hitChapters,
    required this.unprocessedChapters,
    required this.matchedKnowledge,
    required this.progress,
    required this.searchedWholeBook,
    required this.currentPageOnly,
    required this.queryTraces,
    required this.candidatesConsidered,
  });

  final DocumentRecord document;
  final BookQuestionAnalysis analysis;
  final List<Evidence> evidence;
  final List<BookChapter> hitChapters;
  final List<BookChapter> unprocessedChapters;
  final List<BookKnowledgePoint> matchedKnowledge;
  final UnderstandingProgress progress;
  final bool searchedWholeBook;
  final bool currentPageOnly;
  final List<String> queryTraces;
  final int candidatesConsidered;

  bool get hasBookEvidence => evidence.isNotEmpty;

  /// Coverage is computed from what was really searched and parsed, never from
  /// the model's confidence.
  BookCoverage coverage() {
    final gaps = <String>[
      if (!progress.pages.allParsed) '${progress.pages.gapLabel}（待识别或未完成）',
      for (final chapter in unprocessedChapters.take(4))
        '${chapter.title}（${chapter.rangeLabel}）尚未整理',
      if (unprocessedChapters.length > 4)
        '另有 ${unprocessedChapters.length - 4} 章尚未整理',
    ];
    final scope = currentPageOnly
        ? '第 ${analysis.focusPageLabel} 页及相邻页'
        : searchedWholeBook
        ? '整本教材 ${progress.pages.readyPages}/${progress.pages.totalPages} 页可用文字'
        : '教材已解析页';
    final buffer = StringBuffer();
    if (!progress.pages.allParsed) {
      buffer.write('教材仍有部分页面没有可用文字，未命中不能说明全书没有。');
    } else if (!searchedWholeBook) {
      buffer.write('本次只检索了当前页范围，不是全书核查。');
    } else if (!progress.complete) {
      buffer.write('已检索全部可用页，但章节与知识点索引尚未整理完成。');
    } else if (evidence.isEmpty) {
      buffer.write('全书已有可用文字，但本次问题没有检索到直接匹配的原文。');
    } else {
      buffer.write('已在全书可用文字中检索并核对命中页。');
    }
    return BookCoverage(
      scope: scope,
      wholeBookSearched: searchedWholeBook,
      understandingComplete: progress.complete,
      parsedPages: progress.pages.readyPages,
      totalPages: progress.pages.totalPages,
      hitChapters: hitChapters.map((chapter) => chapter.title).toList(),
      gaps: gaps,
      note: buffer.toString(),
    );
  }

  List<String> webQueries({int max = 2}) {
    final concept = matchedKnowledge.isNotEmpty
        ? matchedKnowledge.first.term
        : analysis.aliases.isNotEmpty
        ? analysis.aliases.first
        : analysis.terms.isNotEmpty
        ? analysis.terms.take(3).join()
        : analysis.question;
    final english = matchedKnowledge.isNotEmpty
        ? matchedKnowledge.first.englishAlias
        : '';
    final intent = analysis.asksWhy
        ? '原因 机理'
        : analysis.asksExample
        ? '举例 应用'
        : analysis.asksRelation
        ? '关系 区别'
        : analysis.asksLatest
        ? '最新 研究进展'
        : '';
    final queries = <String>[];
    final first = '$concept $intent'.trim();
    if (first.isNotEmpty) queries.add(_clipQuery(first));
    if (queries.length < max) {
      if (english.trim().isNotEmpty) {
        final suffix = analysis.asksWhy ? 'mechanism' : 'definition';
        queries.add(_clipQuery('$english $suffix'));
      } else if (intent.isEmpty) {
        queries.add(_clipQuery('$concept 解释'));
      } else {
        queries.add(_clipQuery('$concept 大学 教材'));
      }
    }
    return queries
        .map((query) => query.trim())
        .where((query) => query.isNotEmpty)
        .toSet()
        .take(max)
        .toList();
  }

  static String _clipQuery(String value) {
    final runes = value.runes.toList();
    if (runes.length <= 128) return value.trim();
    return String.fromCharCodes(runes.take(128));
  }
}

/// Whole-book retrieval. The current page is a ranking hint, never a boundary
/// unless the caller explicitly asks for the current-page mode.
class BookRetriever {
  BookRetriever({required this.store, required this.repository});

  final LocalStore store;
  final BookQaRepository repository;

  static const Set<String> _stopPhrases = {
    '为什么',
    '为何',
    '怎么回事',
    '怎么',
    '如何',
    '什么',
    '是否',
    '哪些',
    '哪个',
    '请问',
    '请解释',
    '解释一下',
    '解释',
    '说明一下',
    '说明',
    '谈谈',
    '书上',
    '课本上',
    '课本',
    '教材',
    '作者',
    '原文',
    '这里',
    '这个',
    '那个',
    '这些',
    '那些',
    '一下',
    '提到',
    '讲过',
    '说的',
    '到底',
    '究竟',
    '有没有',
    '关系',
    '联系',
    '区别',
    '对比',
    '相比',
    '以及',
    '然后',
    '那么',
    '应该',
    '可以',
    '我们',
    '本文',
  };

  static final RegExp _hanRuns = RegExp(
    r'[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]{2,}',
  );
  static final RegExp _latinRuns = RegExp(r'[A-Za-z][A-Za-z0-9_\-]{1,}');

  BookQuestionAnalysis analyze(String question, {int? focusPage}) {
    final trimmed = question.trim();
    final lower = trimmed.toLowerCase();
    final stripped = StringBuffer();
    var rest = lower;
    for (final phrase in _stopPhrases) {
      rest = rest.replaceAll(phrase, ' ');
    }
    stripped.write(rest);
    final terms = <String>[];
    final aliases = <String>[];
    for (final match in _hanRuns.allMatches(stripped.toString())) {
      final run = match.group(0)!;
      aliases.add(run);
      final characters = run.runes.map(String.fromCharCode).toList();
      for (var index = 0; index + 1 < characters.length; index++) {
        terms.add('${characters[index]}${characters[index + 1]}');
      }
    }
    for (final match in _latinRuns.allMatches(lower)) {
      final word = match.group(0)!;
      if (_stopPhrases.contains(word)) continue;
      terms.add(word);
      aliases.add(word);
    }
    final mergedTerms = <String>[
      for (final term in terms.toSet())
        if (term.trim().isNotEmpty) term,
    ];
    final mergedAliases = <String>[
      for (final alias in aliases.toSet())
        if (alias.trim().isNotEmpty) alias,
    ];
    return BookQuestionAnalysis(
      question: trimmed,
      normalized: normalizeBookTerm(trimmed),
      focusPage: focusPage,
      terms: mergedTerms.take(40).toList(),
      aliases: mergedAliases.take(12).toList(),
      asksWhy: RegExp(r'为什么|为何|原因|机理|怎么会|凭什么|缘由').hasMatch(lower),
      asksExample: RegExp(r'例子|举例|案例|实例|应用').hasMatch(lower),
      asksLatest: RegExp(r'最新|最近|今年|目前|现在|进展|新研究|2025|2026').hasMatch(lower),
      asksAuthor: RegExp(r'作者|原话|原文说|书上说|课本说|教材说|有没有说|是否说|说过').hasMatch(lower),
      asksRelation: RegExp(r'关系|联系|区别|对比|相比|前后|跨章').hasMatch(lower),
    );
  }

  BookRetrieval retrieve(
    DocumentRecord document,
    String question, {
    int? focusPage,
    bool currentPageOnly = false,
    int maxEvidence = 12,
    int maxCharacters = 16000,
  }) {
    final analysis = analyze(question, focusPage: focusPage);
    final progress = repository.progress(document);
    final chapters = repository.getChapters(document.id);
    final knowledge = repository.getKnowledgePoints(document.id);
    final matched = _matchKnowledge(analysis, knowledge);
    final matchedChapters = _matchChapters(analysis, chapters);
    final traces = <String>[];
    final scores = <String, _ScoredEvidence>{};
    final start = currentPageOnly ? (focusPage ?? 1) - 1 : null;
    final end = currentPageOnly ? (focusPage ?? 1) + 1 : null;

    void collect(String label, String query, double weight, {int limit = 24}) {
      if (query.trim().isEmpty) return;
      final hits = store.searchEvidence(
        query,
        documentId: document.id,
        startPage: start,
        endPage: end,
        limit: limit,
      );
      traces.add('$label: ${hits.length}');
      for (var index = 0; index < hits.length; index++) {
        final hit = hits[index];
        final bonus = index < 3 ? 0.6 : 0;
        _add(scores, hit, weight + bonus);
      }
    }

    collect('问题', question, 6);
    final concept = <String>{
      for (final point in matched.take(4)) point.term,
      ...analysis.aliases.take(4),
    }.join(' ');
    collect('概念', concept, 5);
    if (analysis.terms.isNotEmpty) {
      collect('拆解', analysis.terms.take(24).join(' '), 2);
    }
    if (analysis.asksWhy) {
      final focus = matched.isNotEmpty ? matched.first.term : concept;
      collect('原因', '$focus 原因 机理 条件 因为', 4);
    }
    if (analysis.asksRelation) {
      for (final chapter in matchedChapters.take(2)) {
        collect('章节', chapter.title, 3, limit: 12);
      }
    }

    // Knowledge-point pages are searched directly, so a synonym in the
    // question still reaches the page where the book defines the concept.
    for (final point in matched.take(6)) {
      final pageEvidence = store.getEvidence(
        document.id,
        page: point.startPage,
      );
      for (final hit in pageEvidence.take(2)) {
        _add(scores, hit, 4.5);
      }
      traces.add('知识点页: ${point.startPage}');
    }

    for (final chapter in matchedChapters.take(3)) {
      final chapterEvidence = store.getEvidence(
        document.id,
        startPage: chapter.startPage,
        endPage: (chapter.startPage + 1).clamp(1, document.pageCount),
      );
      for (final hit in chapterEvidence.take(2)) {
        _add(scores, hit, 3.5);
      }
    }

    // Current page is a disambiguation hint, not a retrieval boundary.
    final hintPage = focusPage;
    if (hintPage != null && !currentPageOnly) {
      for (final hit
          in store.getEvidence(document.id, page: hintPage).take(2)) {
        _add(scores, hit, 1.2);
      }
    }

    final ranked = scores.values.toList()
      ..sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        if (byScore != 0) return byScore;
        return a.evidence.page.compareTo(b.evidence.page);
      });
    if (currentPageOnly && ranked.isEmpty) {
      // A current-page question still needs the page text when FTS misses it.
      final page = focusPage ?? 1;
      for (final hit in store.getEvidence(document.id, page: page).take(6)) {
        _add(scores, hit, 2);
      }
    }
    final expanded = _expandNeighbours(
      document,
      ranked.take(6).toList(),
      scores,
      start: start,
      end: end,
    );
    final selected = <Evidence>[];
    var characters = 0;
    final perPage = <int, int>{};
    for (final item in expanded) {
      if (selected.length >= maxEvidence) break;
      if (characters >= maxCharacters) break;
      if ((perPage[item.evidence.page] ?? 0) >= 3) continue;
      final room = maxCharacters - characters;
      final text = item.evidence.text.length <= room
          ? item.evidence.text
          : item.evidence.text.substring(0, room);
      if (text.trim().isEmpty) continue;
      selected.add(
        text == item.evidence.text
            ? item.evidence
            : item.evidence.copyWith(text: text),
      );
      characters += text.length;
      perPage.update(
        item.evidence.page,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
    }
    final hitChapters = <BookChapter>[];
    for (final chapter in chapters) {
      if (selected.any(
        (evidence) =>
            evidence.page >= chapter.startPage &&
            evidence.page <= chapter.endPage,
      )) {
        hitChapters.add(chapter);
      }
    }
    final readyChapterIds = {
      for (final chunk in repository.getChunks(document.id))
        if (chunk.status == BookChunkStatus.ready && chunk.chapterId != null)
          chunk.chapterId!,
    };
    final unprocessed = chapters
        .where((chapter) => !readyChapterIds.contains(chapter.id))
        .toList();
    return BookRetrieval(
      document: document,
      analysis: analysis,
      evidence: selected,
      hitChapters: hitChapters,
      unprocessedChapters: unprocessed,
      matchedKnowledge: matched,
      progress: progress,
      searchedWholeBook: !currentPageOnly,
      currentPageOnly: currentPageOnly,
      queryTraces: traces,
      candidatesConsidered: scores.length,
    );
  }

  List<_ScoredEvidence> _expandNeighbours(
    DocumentRecord document,
    List<_ScoredEvidence> ranked,
    Map<String, _ScoredEvidence> scores, {
    int? start,
    int? end,
  }) {
    for (final item in ranked.take(4)) {
      for (final offset in const [-1, 1]) {
        final page = item.evidence.page + offset;
        if (page < 1 || page > document.pageCount) continue;
        if (start != null && page < start) continue;
        if (end != null && page > end) continue;
        final neighbours = store.getEvidence(document.id, page: page);
        for (final hit in neighbours.take(1)) {
          _add(scores, hit, 1.4);
        }
      }
    }
    return scores.values.toList()..sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      return byScore != 0
          ? byScore
          : a.evidence.page.compareTo(b.evidence.page);
    });
  }

  void _add(
    Map<String, _ScoredEvidence> scores,
    Evidence evidence,
    double weight,
  ) {
    if (evidence.text.trim().isEmpty) return;
    final existing = scores[evidence.id];
    if (existing == null) {
      scores[evidence.id] = _ScoredEvidence(evidence, weight);
    } else if (existing.score < weight) {
      scores[evidence.id] = _ScoredEvidence(evidence, weight);
    } else {
      existing.score += 0.05;
    }
  }

  List<BookKnowledgePoint> _matchKnowledge(
    BookQuestionAnalysis analysis,
    List<BookKnowledgePoint> knowledge,
  ) {
    final scored = <_ScoredKnowledge>[];
    for (final point in knowledge) {
      var score = 0.0;
      final candidates = <String>[
        point.term,
        point.englishAlias,
        point.symbol,
        ...point.aliases,
      ];
      for (final candidate in candidates) {
        final norm = normalizeBookTerm(candidate);
        if (norm.length < 2) continue;
        if (analysis.normalized.contains(norm)) {
          score = score < norm.length ? norm.length.toDouble() : score;
        }
      }
      if (score == 0) {
        for (final alias in analysis.aliases) {
          final norm = normalizeBookTerm(alias);
          if (norm.length >= 2 && point.termNorm.contains(norm)) {
            score = norm.length.toDouble();
            break;
          }
        }
      }
      if (score > 0) {
        scored.add(_ScoredKnowledge(point, score));
      }
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(8).map((item) => item.point).toList();
  }

  List<BookChapter> _matchChapters(
    BookQuestionAnalysis analysis,
    List<BookChapter> chapters,
  ) {
    final scored = <_ScoredChapter>[];
    for (final chapter in chapters) {
      final title = normalizeBookTerm(chapter.title);
      if (title.length < 2) continue;
      var score = 0.0;
      if (analysis.normalized.contains(title)) {
        score = title.length.toDouble();
      } else {
        for (final alias in analysis.aliases) {
          final norm = normalizeBookTerm(alias);
          if (norm.length >= 2 && title.contains(norm)) {
            score = norm.length.toDouble();
            break;
          }
        }
      }
      if (score > 0) scored.add(_ScoredChapter(chapter, score));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(4).map((item) => item.chapter).toList();
  }
}

class _ScoredEvidence {
  _ScoredEvidence(this.evidence, this.score);
  final Evidence evidence;
  double score;
}

class _ScoredKnowledge {
  const _ScoredKnowledge(this.point, this.score);
  final BookKnowledgePoint point;
  final double score;
}

class _ScoredChapter {
  const _ScoredChapter(this.chapter, this.score);
  final BookChapter chapter;
  final double score;
}

/// Kept for callers that want the normalized FTS tokens without duplicating
/// the shared preprocessing rules.
List<String> bookQuestionTokens(String question) =>
    SearchIndex.tokens(question);
