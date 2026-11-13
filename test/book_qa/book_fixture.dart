import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:local_study/core/local_store.dart';
import 'package:local_study/core/models.dart';
import 'package:local_study/features/book_qa/data/book_qa_repository.dart';
import 'package:local_study/features/book_qa/services/book_retriever.dart';
import 'package:local_study/services/ai_gateway.dart';

class MemoryVault implements CredentialVault {
  final values = <String, String>{};
  int reads = 0;

  @override
  Future<String?> read(String accountId) async {
    reads++;
    return values[accountId];
  }

  @override
  Future<void> write(String accountId, String value) async {
    values[accountId] = value;
  }

  @override
  Future<void> delete(String accountId) async {
    values.remove(accountId);
  }
}

String chatEnvelope(
  Map<String, dynamic> content, {
  String finishReason = 'stop',
  int totalTokens = 150,
}) => jsonEncode({
  'choices': [
    {
      'finish_reason': finishReason,
      'message': {'content': jsonEncode(content)},
    },
  ],
  'usage': {
    'prompt_tokens': 100,
    'completion_tokens': 50,
    'total_tokens': totalTokens,
  },
});

const bookPageTexts = <String>[
  '第一章 聚合物基础\n聚合物是许多重复单元通过共价键连接而成的大分子。',
  '聚合物由单体聚合而成，单体是能形成聚合物重复单元的分子。',
  '高分子材料的性能与其链结构密切相关。',
  '第二章 链结构\n链结构描述重复单元在聚合物链中的排列方式。',
  '聚合物链的连接方式包括头尾连接、头头连接和尾尾连接。',
  '连接方式会影响链的规整性和最终材料的性能。',
  '在常见乙烯基单体的自由基聚合中，聚合物多以头尾键连为主。',
  '不同连接方式的比例取决于单体和聚合机理。',
  '第三章 共聚\n共聚物由两种或多种单体共同聚合而成。',
  '竞聚率描述两种单体在共聚过程中的相对反应活性。',
  '共聚组成会随转化率变化，需要区分瞬时组成与平均组成。',
  '本章小结：链结构和共聚组成共同决定材料性能。',
];

/// A synthetic book whose page 7 states the conclusion without its reason, so
/// retrieval must reach another page and the web must supply the mechanism.
class BookFixture {
  BookFixture._({
    required this.store,
    required this.document,
    required this.vault,
    required this.server,
    required this.gateway,
    required this.settings,
  }) {
    repository = BookQaRepository(store);
    retriever = BookRetriever(store: store, repository: repository);
  }

  final LocalStore store;
  final DocumentRecord document;
  final MemoryVault vault;
  final FakeBookServer server;
  final AiGateway gateway;
  final ProviderSettings settings;
  late final BookQaRepository repository;
  late final BookRetriever retriever;

  static BookFixture create({
    String baseUrl = 'https://api.deepseek.com',
    int pageCount = 12,
  }) {
    final store = LocalStore.inMemory();
    final pages = List.generate(
      pageCount,
      (index) => PageRecord(
        documentId: 'book-1',
        page: index + 1,
        text: bookPageTexts[index % bookPageTexts.length],
        status: PageStatus.ready,
      ),
    );
    final document = DocumentRecord(
      id: 'book-1',
      title: '高分子化学导论',
      kind: DocumentKind.textbook,
      filePath: r'C:\managed\book-1\original.pdf',
      contentHash: 'sha256-book-version-1',
      pageCount: pageCount,
    );
    store.importDocument(document, pages);
    for (var page = 1; page <= pageCount; page++) {
      store.replacePageEvidence(document.id, page, [
        Evidence(
          id: '${document.id}:$page:t0',
          documentId: document.id,
          documentHash: document.contentHash,
          page: page,
          region: const SourceRegion(.08, .1, .95, .92),
          text: bookPageTexts[(page - 1) % bookPageTexts.length],
        ),
      ]);
    }
    final vault = MemoryVault();
    final settings = ProviderSettings(
      provider: 'DeepSeek',
      baseUrl: baseUrl,
      model: 'deepseek-flash',
    );
    final server = FakeBookServer();
    final gateway = AiGateway(vault: vault, client: MockClient(server.handle));
    return BookFixture._(
      store: store,
      document: document,
      vault: vault,
      server: server,
      gateway: gateway,
      settings: settings,
    );
  }

  Future<void> saveKey([String value = 'test-secret-key']) =>
      vault.write(settings.credentialId, value);

  void dispose() {
    gateway.close();
    store.dispose();
  }

  String questionPayload() {
    final request = server.lastChatRequest;
    final payload = jsonDecode(request.body) as Map<String, dynamic>;
    final user = jsonDecode(
      ((payload['messages'] as List)[1] as Map)['content'] as String,
    );
    return jsonEncode(user);
  }

  Map<String, dynamic> chatUserAt(int index) {
    final chats = server.requests
        .where((request) => request.url.path.contains('chat'))
        .toList();
    final payload = jsonDecode(chats[index].body) as Map<String, dynamic>;
    return Map<String, dynamic>.from(
      jsonDecode(((payload['messages'] as List)[1] as Map)['content'] as String)
          as Map,
    );
  }
}

class FakeBookServer {
  final List<http.Request> requests = [];
  Map<String, dynamic>? questionContent;
  Map<String, dynamic>? overviewContent;
  List<Map<String, dynamic>>? searchResults;
  bool failSearch = false;
  bool failFetch = false;
  bool searchContentIncluded = false;
  bool chunkFailure = false;
  String fetchedTitle = 'Addition polymerisation';
  String fetchedContent =
      'Head-to-tail addition is favoured because the transition state is more '
      'stable and steric repulsion is lower.';

  http.Request get lastChatRequest =>
      requests.lastWhere((request) => request.url.path.contains('chat'));

  http.Request get lastSearchRequest =>
      requests.lastWhere((request) => request.url.path.endsWith('/search'));

  int get chatCalls =>
      requests.where((request) => request.url.path.contains('chat')).length;
  int get searchCalls =>
      requests.where((request) => request.url.path.endsWith('/search')).length;
  int get fetchCalls =>
      requests.where((request) => request.url.path.endsWith('/fetch')).length;

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    if (path.endsWith('/tools/search')) {
      if (failSearch) {
        return _jsonResponse(
          {
            'error': {'message': 'search unavailable', 'type': 'server_error'},
          },
          503,
          envelope: false,
        );
      }
      final results = searchResults ?? _defaultSearchResults();
      return _jsonResponse(
        {
          'results': [
            for (final item in results)
              if (searchContentIncluded)
                {...item, 'content': fetchedContent}
              else
                item,
          ],
        },
        200,
        envelope: false,
      );
    }
    if (path.endsWith('/tools/fetch')) {
      if (failFetch) {
        return _jsonResponse(
          {
            'error': {
              'message': 'cannot fetch',
              'type': 'invalid_request_error',
            },
          },
          404,
          envelope: false,
        );
      }
      return _jsonResponse(
        {'title': fetchedTitle, 'content': fetchedContent},
        200,
        envelope: false,
      );
    }
    if (!path.endsWith('/chat/completions')) {
      return http.Response('not found', 404);
    }
    final payload = jsonDecode(request.body) as Map<String, dynamic>;
    final content = ((payload['messages'] as List)[1] as Map)['content'];
    final String textContent;
    if (content is String) {
      textContent = content;
    } else if (content is List) {
      final textPart = content
          .cast<Map<String, dynamic>>()
          .firstWhere((part) => part['type'] == 'text');
      textContent = textPart['text'] as String;
    } else {
      return http.Response('unsupported content', 400);
    }
    final user = jsonDecode(textContent) as Map<String, dynamic>;
    return switch (user['task']) {
      'understandChunk' => _chunkResponse(user),
      'bookOverview' => _jsonResponse(
        overviewContent ?? _defaultOverview(),
        200,
      ),
      'bookQuestion' => _jsonResponse(
        questionContent ?? _defaultAnswer(user),
        200,
      ),
      _ => _jsonResponse({
        'answer': '默认回答',
        'citations': <String>[],
        'insufficientEvidence': false,
      }, 200),
    };
  }

  http.Response _jsonResponse(
    Map<String, dynamic> content,
    int status, {
    bool envelope = true,
  }) {
    final body = envelope ? chatEnvelope(content) : jsonEncode(content);
    return http.Response.bytes(
      utf8.encode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }

  http.Response _chunkResponse(Map<String, dynamic> user) {
    if (chunkFailure) {
      return _jsonResponse(
        {
          'error': {'message': 'chunk failed', 'type': 'server_error'},
        },
        500,
        envelope: false,
      );
    }
    final pages = (user['pages'] as List).cast<Map<String, dynamic>>();
    final firstPage = (pages.first['page'] as num).toInt();
    return _jsonResponse({
      'summary': '本块讨论聚合物链的连接方式与结构。',
      'definitions': ['聚合物是许多重复单元通过共价键连接而成的大分子。'],
      'conclusions': ['聚合物多以头尾键连为主。'],
      'conditions': ['常见乙烯基单体的自由基聚合'],
      'typicalProblems': ['解释为什么头尾连接更常见'],
      'terms': [
        {
          'term': '头尾键连',
          'english': 'head-to-tail',
          'symbol': '',
          'definition': '重复单元以头—尾方向相连。',
          'pages': [firstPage],
        },
        {
          'term': '单体',
          'english': 'monomer',
          'symbol': 'M',
          'definition': '能形成聚合物重复单元的分子。',
          'pages': [firstPage],
        },
      ],
    }, 200);
  }

  Map<String, dynamic> _defaultAnswer(Map<String, dynamic> user) {
    final webSources = user['web_sources'] as List? ?? const [];
    return {
      'answerStatus': 'answered',
      'blocks': [
        {
          'text': '教材指出聚合物多以头尾键连为主。',
          'bookCitations': ['B1'],
          'webCitations': <String>[],
          'supplemental': false,
        },
        {
          'text': webSources.isEmpty
              ? '教材没有展开原因；以下是结合学科知识的解释，供你核对。'
              : '外部资料补充：头尾加成过渡态更稳定，且位阻更小。',
          'bookCitations': <String>[],
          'webCitations': webSources.isEmpty ? <String>[] : ['W1'],
          'supplemental': true,
        },
      ],
      'bookCoverage': {
        'scope': '教材全书',
        'matchedChapters': ['第二章 链结构'],
        'gaps': <String>[],
      },
      'missingInformation': <String>[],
    };
  }

  Map<String, dynamic> _defaultOverview() => {
    'subject': '高分子化学，讨论聚合物结构与性能。',
    'conventions': '以重复单元和链结构描述聚合物。',
    'chapterRelations': ['链结构决定材料性能，共聚改变链结构。'],
    'themes': ['结构—性能关系'],
    'unfinished': <String>[],
  };

  List<Map<String, dynamic>> _defaultSearchResults() => [
    {
      'title': 'Addition polymerisation of vinyl monomers',
      'url': 'https://chemistry.example.edu/addition-polymerisation',
      'snippet': 'Head-to-tail addition dominates for vinyl monomers.',
      'summary':
          'Head-to-tail addition is favoured by transition-state stabilisation '
          'and reduced steric repulsion.',
      'content': '',
      'site_name': 'Example University',
      'date': '2026-01-02T00:00:00+00:00',
      'authority': 3,
      'rerank_score': 2.2,
    },
    {
      'title': 'Polymer chain configurations',
      'url': 'https://materials.example.org/chain-configuration',
      'snippet': 'Chain configuration and regio-regularity.',
      'summary': 'Regio-regularity depends on monomer and mechanism.',
      'content': '',
      'site_name': 'Example Materials',
      'date': '2025-05-01T00:00:00+00:00',
      'authority': 2,
      'rerank_score': 1.8,
    },
  ];
}
