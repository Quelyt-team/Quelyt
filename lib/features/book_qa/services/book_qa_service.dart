import '../../../core/local_store.dart';
import '../../../core/models.dart';
import '../../../services/ai_gateway.dart';
import '../../../services/ai_transport.dart';
import '../../../services/web_search_provider.dart';
import '../data/book_qa_repository.dart';
import '../models/book_qa_models.dart';
import 'book_qa_client.dart';
import 'book_retriever.dart';

class _WebLookup {
  const _WebLookup({
    required this.sources,
    required this.status,
    required this.note,
    required this.usage,
  });

  final List<WebCitation> sources;
  final WebLookupStatus status;
  final String note;
  final BookQaUsage usage;
}

/// Orchestrates one textbook question: whole-book recall, real web search and
/// fetch inside a fixed budget, then the independent book-question contract.
///
/// A failed search never discards usable book evidence; it only changes the
/// reported network status and the strength of the final explanation.
class BookQaService {
  BookQaService({
    required this.store,
    required this.repository,
    required AiTransport transport,
    BookQaClient? client,
    BookRetriever? retriever,
    WebSearchProvider Function(ProviderSettings settings)? providerFactory,
    DateTime Function()? now,
  }) : client = client ?? BookQaClient(transport),
       retriever =
           retriever ?? BookRetriever(store: store, repository: repository),
       _providerFactory =
           providerFactory ??
           ((settings) => DeepSeekWebSearchProvider(transport, settings)),
       _now = now ?? DateTime.now;

  final LocalStore store;
  final BookQaRepository repository;
  final BookQaClient client;
  final BookRetriever retriever;
  final WebSearchProvider Function(ProviderSettings settings) _providerFactory;
  final DateTime Function() _now;

  static const int maxSearchRequests = 2;
  static const int maxFetchRequests = 3;
  static const Duration cacheFreshFor = Duration(days: 7);
  static const Duration cacheMaximumAge = Duration(days: 90);

  bool supportsWeb(ProviderSettings settings) {
    try {
      return _providerFactory(settings).isConfigured;
    } catch (_) {
      return false;
    }
  }

  BookQaClient get questionClient => client;

  PreparedBookQaRequest prepare({
    required DocumentRecord document,
    required BookConversation conversation,
    required String question,
    required ProviderSettings settings,
    required BookAskMode mode,
    required int currentPage,
    required List<BookQaHistoryTurn> history,
    ImageAttachment? image,
  }) {
    final retrieval = retriever.retrieve(
      document,
      question,
      focusPage: currentPage,
      currentPageOnly: mode == BookAskMode.currentPage,
    );
    return client.prepare(
      settings: settings,
      document: document,
      conversationId: conversation.id,
      question: question,
      mode: mode,
      retrieval: retrieval,
      searchQueries: retrieval.webQueries(max: maxSearchRequests),
      history: history,
      webEnabled: mode.allowsWeb,
      image: image,
    );
  }

  Future<BookQaAnswer> ask(
    PreparedBookQaRequest request, {
    void Function(BookQaStage stage)? onStage,
    BookQaImageApproval? imageApproval,
  }) async {
    final document = store.getDocument(request.documentId);
    if (document == null ||
        document.contentHash != request.documentHash ||
        document.title != request.documentTitle) {
      throw const AiFailure(AiError.rejected, '教材已删除或版本已改变，请重新预览这次提问。');
    }
    if (!request.isImageApproved(imageApproval)) {
      throw const AiFailure(AiError.imageApprovalRequired, '请预览并确认本次图片后再发送。');
    }
    _ensureNotCancelled(request);
    onStage?.call(BookQaStage.searchingWeb);
    final lookup = await _lookupWeb(request, onStage);
    _ensureNotCancelled(request);
    onStage?.call(BookQaStage.composing);
    return client.send(
      request,
      webSources: lookup.sources,
      webStatus: lookup.status,
      webNote: lookup.note,
      usage: lookup.usage,
      imageApproval: imageApproval,
    );
  }

  void _ensureNotCancelled(PreparedBookQaRequest request) {
    if (request.cancelled) {
      throw const AiFailure(AiError.cancelled, '已取消本次教材问答。');
    }
  }

  Future<_WebLookup> _lookupWeb(
    PreparedBookQaRequest request,
    void Function(BookQaStage stage)? onStage,
  ) async {
    if (!request.webEnabled) {
      return _WebLookup(
        sources: const [],
        status: request.strictAuthor
            ? WebLookupStatus.notNeeded
            : WebLookupStatus.disabled,
        note: request.strictAuthor
            ? '本次是作者原话核查，不发送网络搜索。'
            : '本次选择只依据教材，没有发送网络搜索。',
        usage: const BookQaUsage(),
      );
    }
    final provider = _providerFactory(request.settings);
    if (!provider.isConfigured) {
      return _WebLookup(
        sources: const [],
        status: WebLookupStatus.failed,
        note: '当前服务商未配置联网搜索，以下回答仅依据教材与模型知识。',
        usage: const BookQaUsage(),
      );
    }
    final notes = <String>[];
    final hits = <String, WebSearchHit>{};
    var searches = 0;
    for (final query in request.searchQueries.take(maxSearchRequests)) {
      _ensureNotCancelled(request);
      searches++;
      onStage?.call(BookQaStage.searchingWeb);
      final outcome = await provider.search(
        query,
        originalQuestion: request.question,
        count: 5,
      );
      switch (outcome.state) {
        case WebSearchState.searched:
          for (final hit in outcome.hits) {
            if (_blockedUrl(hit.url)) continue;
            final key = _urlKey(hit.url);
            final existing = hits[key];
            if (existing == null ||
                _score(hit, request.timeSensitive) >
                    _score(existing, request.timeSensitive)) {
              hits[key] = hit;
            }
          }
        case WebSearchState.empty:
          notes.add(outcome.note);
        case WebSearchState.failed:
          notes.add(outcome.note);
        case WebSearchState.notConfigured:
          notes.add(outcome.note);
      }
    }
    if (hits.isEmpty) {
      return _WebLookup(
        sources: const [],
        status: WebLookupStatus.failed,
        note: [
          if (searches > 0) '联网搜索未返回可用结果。',
          ...notes,
          '以下回答仅依据已检索的教材与模型知识，不伪造网络来源。',
        ].join(' '),
        usage: BookQaUsage(searchRequests: searches),
      );
    }
    final ranked = hits.values.toList()
      ..sort(
        (a, b) => _score(
          b,
          request.timeSensitive,
        ).compareTo(_score(a, request.timeSensitive)),
      );
    final sources = <WebCitation>[];
    var fetches = 0;
    var cached = 0;
    var summaryOnly = 0;
    for (final hit in ranked) {
      if (sources.length >= BookQaClient.maxWebSources) break;
      _ensureNotCancelled(request);
      var content = hit.content.trim();
      var title = hit.title.trim().isEmpty ? hit.url : hit.title.trim();
      var fromCache = false;
      var fullText = content.isNotEmpty;
      if (!fullText) {
        final cachedPage = request.timeSensitive
            ? null
            : repository.getCachedPage(hit.url, maxAge: cacheFreshFor);
        if (cachedPage != null) {
          content = cachedPage.content;
          title = cachedPage.title.trim().isEmpty ? title : cachedPage.title;
          fromCache = true;
          fullText = true;
          cached++;
        } else if (fetches < maxFetchRequests) {
          onStage?.call(BookQaStage.readingWeb);
          fetches++;
          final fetched = await provider.fetch(hit.url);
          if (fetched.ok) {
            content = fetched.content;
            title = fetched.title.trim().isEmpty ? title : fetched.title;
            fullText = true;
            repository.saveCachedPage(
              WebCacheEntry(
                url: hit.url,
                title: title,
                content: content,
                fetchedAt: _now(),
                siteName: hit.siteName,
                publishedAt: hit.publishedAt,
              ),
            );
          } else {
            notes.add('${hit.displayTitle}：${fetched.note}');
          }
        } else if (!request.timeSensitive) {
          final cachedPage = repository.getCachedPage(hit.url);
          if (cachedPage != null) {
            content = cachedPage.content;
            title = cachedPage.title.trim().isEmpty ? title : cachedPage.title;
            fromCache = true;
            fullText = true;
            cached++;
          }
        }
      } else {
        // Search already returned the page body; keep it for a later question.
        repository.saveCachedPage(
          WebCacheEntry(
            url: hit.url,
            title: title,
            content: content,
            fetchedAt: _now(),
            siteName: hit.siteName,
            publishedAt: hit.publishedAt,
          ),
        );
      }
      final summary = hit.summary.trim().isNotEmpty
          ? hit.summary.trim()
          : hit.snippet.trim();
      if (content.isEmpty) {
        content = summary;
      }
      if (content.trim().isEmpty) continue;
      if (!fullText) summaryOnly++;
      sources.add(
        WebCitation(
          id: 'W${sources.length + 1}',
          title: title,
          url: hit.url,
          excerpt: content,
          fetchedAt: _now(),
          siteName: hit.siteName,
          publishedAt: hit.publishedAt,
          fullText: fullText,
          fromCache: fromCache,
          searchQuery: hit.query,
        ),
      );
    }
    if (sources.isEmpty) {
      return _WebLookup(
        sources: const [],
        status: WebLookupStatus.failed,
        note: [
          '检索到了网页结果，但没有取得可读正文或摘要。',
          ...notes.take(2),
          '以下回答仅依据教材与模型知识。',
        ].join(' '),
        usage: BookQaUsage(searchRequests: searches, fetchRequests: fetches),
      );
    }
    final allCached = sources.every((source) => source.fromCache);
    final status = allCached
        ? WebLookupStatus.cached
        : WebLookupStatus.searched;
    final summary = <String>['搜索 $searches 次'];
    if (fetches > 0) summary.add('读取 $fetches 个网页');
    if (cached > 0) summary.add('$cached 个来源来自缓存');
    if (summaryOnly > 0) summary.add('$summaryOnly 个来源仅有摘要');
    summary.addAll(notes.take(2));
    if (allCached) summary.add('使用的是本地缓存正文，不是刚检索的全文。');
    return _WebLookup(
      sources: sources,
      status: status,
      note: summary.join('；'),
      usage: BookQaUsage(
        searchRequests: searches,
        fetchRequests: fetches,
        cachedSources: cached,
      ),
    );
  }

  double _score(WebSearchHit hit, bool timeSensitive) {
    var score = hit.rerankScore;
    if (hit.authority >= 3) score += 0.8;
    if (hit.hasContent) score += 0.4;
    if (timeSensitive && (hit.publishedAt ?? '').isNotEmpty) score += 0.5;
    return score;
  }

  static String _urlKey(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return url.trim();
    return uri
        .replace(
          scheme: uri.scheme.toLowerCase(),
          host: uri.host.toLowerCase(),
          fragment: '',
        )
        .toString();
  }

  static bool _blockedUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return true;
    if (uri.scheme != 'https' && uri.scheme != 'http') return true;
    if (uri.userInfo.isNotEmpty) return true;
    final host = uri.host.toLowerCase();
    if (host == 'localhost' || host == '::1' || host.endsWith('.local')) {
      return true;
    }
    final ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$')
        .firstMatch(host);
    if (ipv4 != null) {
      final first = int.parse(ipv4.group(1)!);
      final second = int.parse(ipv4.group(2)!);
      if (first == 10 || first == 127 || first == 169 && second == 254) {
        return true;
      }
      if (first == 192 && second == 168) return true;
      if (first == 172 && second >= 16 && second <= 31) return true;
    }
    return false;
  }
}
