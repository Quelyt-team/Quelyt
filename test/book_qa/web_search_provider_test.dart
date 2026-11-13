import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:local_study/services/ai_gateway.dart';
import 'package:local_study/services/web_search_provider.dart';

import 'book_fixture.dart';

void main() {
  late MemoryVault vault;
  late List<http.Request> requests;
  late http.Response Function(http.Request request) responder;
  late AiGateway gateway;
  late DeepSeekWebSearchProvider provider;

  const settings = ProviderSettings(
    provider: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com',
    model: 'deepseek-flash',
  );

  setUp(() async {
    vault = MemoryVault();
    requests = [];
    responder = (_) => http.Response(
      jsonEncode({
        'results': [
          {
            'title': 'Addition polymerisation',
            'url': 'https://chemistry.example.edu/addition',
            'snippet': 'Head-to-tail addition dominates.',
            'summary': 'Transition-state stabilisation and steric reasons.',
            'content': 'Head-to-tail addition is favoured by a more stable transition state.',
            'site_name': 'Example University',
            'site_icon': null,
            'date': '2026-01-02T00:00:00+00:00',
            'authority': 3,
            'rerank_score': 2.4,
          },
        ],
      }),
      200,
    );
    gateway = AiGateway(
      vault: vault,
      client: MockClient((request) async {
        requests.add(request);
        return responder(request);
      }),
    );
    await vault.write(settings.credentialId, 'test-secret-key');
    provider = DeepSeekWebSearchProvider(gateway.transport, settings);
  });

  tearDown(() => gateway.close());

  test(
    'search posts the documented body and parses every source field',
    () async {
      final outcome = await provider.search(
        '头尾 键连 原因',
        originalQuestion: '为什么聚合物多以头尾键连为主？',
        count: 5,
      );
      expect(outcome.state, WebSearchState.searched);
      expect(
        requests.single.url.toString(),
        'https://api.deepseek.com/v1/tools/search',
      );
      expect(
        requests.single.headers['Authorization'],
        'Bearer test-secret-key',
      );
      final body = jsonDecode(requests.single.body) as Map;
      expect(body['query'], '头尾 键连 原因');
      expect(body['ori_question'], '为什么聚合物多以头尾键连为主？');
      expect(body['count'], 5);
      expect(body['need_content'], isTrue);
      final hit = outcome.hits.single;
      expect(hit.title, 'Addition polymerisation');
      expect(hit.hasContent, isTrue);
      expect(hit.siteName, 'Example University');
      expect(hit.publishedAt, '2026-01-02T00:00:00+00:00');
      expect(hit.authority, 3);
      expect(hit.rerankScore, 2.4);
    },
  );

  test(
    'an unsupported provider never borrows the official route or key',
    () async {
      const custom = ProviderSettings(
        provider: '自定义',
        baseUrl: 'https://example.test/v1',
        model: 'text-model',
      );
      final unsupported = DeepSeekWebSearchProvider(gateway.transport, custom);
      expect(unsupported.isConfigured, isFalse);
      final search = await unsupported.search('问题');
      expect(search.state, WebSearchState.notConfigured);
      final fetch = await unsupported.fetch('https://example.com/a');
      expect(fetch.ok, isFalse);
      expect(requests, isEmpty);
      expect(vault.reads, 0);
    },
  );

  test('empty results and provider errors are reported, not retried', () async {
    responder = (_) => http.Response(jsonEncode({'results': []}), 200);
    final empty = await provider.search('无所指');
    expect(empty.state, WebSearchState.empty);
    expect(requests, hasLength(1));

    responder = (_) => http.Response(
      jsonEncode({
        'error': {'message': 'bad key test-secret-key'},
      }),
      401,
    );
    final failed = await provider.search('失败');
    expect(failed.state, WebSearchState.failed);
    expect(failed.note, isNot(contains('test-secret-key')));
    expect(requests, hasLength(2));
  });

  test(
    'fetch requires a real HTTP page and returns Markdown content',
    () async {
      responder = (request) {
        expect(
          request.url.toString(),
          'https://api.deepseek.com/v1/tools/fetch',
        );
        expect(jsonDecode(request.body), {
          'url': 'https://chemistry.example.edu/addition',
        });
        return http.Response(
          jsonEncode({
            'title': 'Addition polymerisation',
            'content': '# Addition\n\nHead-to-tail addition.',
          }),
          200,
        );
      };
      final result = await provider.fetch(
        'https://chemistry.example.edu/addition',
      );
      expect(result.ok, isTrue);
      expect(result.title, 'Addition polymerisation');
      expect(result.content, contains('Head-to-tail'));

      for (final url in [
        'file:///etc/passwd',
        'http://localhost/admin',
        'https://user:secret@example.com/a',
        'not a url',
      ]) {
        expect((await provider.fetch(url)).ok, isFalse);
      }
      expect(requests, hasLength(1));
    },
  );

  test('fetch failure keeps the search summary usable', () async {
    responder = (_) => http.Response('{"error":{"message":"no content"}}', 404);
    final result = await provider.fetch('https://example.com/missing');
    expect(result.ok, isFalse);
    expect(result.note, isNotEmpty);
  });

  test('queries are clipped to the documented 128 characters', () async {
    responder = (_) => http.Response('{"results":[]}', 200);
    await provider.search('问' * 200);
    final body = jsonDecode(requests.single.body) as Map;
    expect((body['query'] as String).runes.length, 128);
  });
}
