import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:local_study/features/schedule/models/local_date.dart';
import 'package:local_study/features/schedule/models/plan_source.dart';
import 'package:local_study/features/schedule/models/study_plan.dart';
import 'package:local_study/features/schedule/services/knowledge_ai_client.dart';
import 'package:local_study/features/schedule/services/material_catalog_service.dart';
import 'package:local_study/services/ai_transport.dart';
import 'package:local_study/services/ai_types.dart';

class _MemoryVault implements CredentialVault {
  final values = <String, String>{};
  @override
  Future<void> delete(String accountId) async => values.remove(accountId);
  @override
  Future<String?> read(String accountId) async => values[accountId];
  @override
  Future<void> write(String accountId, String value) async =>
      values[accountId] = value;
}

const _settings = ProviderSettings(
  provider: '测试服务商',
  baseUrl: 'https://example.test/v1',
  model: 'text-model',
);

StudyPlan _plan() => StudyPlan(
  id: 'plan',
  title: '期中数学',
  subject: '数学',
  startDate: LocalDate(2026, 11, 9),
  endDate: LocalDate(2026, 11, 27),
  examDate: LocalDate(2026, 11, 29),
);

List<MaterialChunk> _chunks() => [
  MaterialChunk(
    sourceId: 'source',
    planId: 'plan',
    documentId: 'book',
    documentHash: 'hash-book',
    documentTitle: '数学教材',
    purpose: MaterialPurpose.textbook,
    chapter: '第三章',
    startPage: 2,
    endPage: 3,
    text: '二次函数的图像是一条抛物线，顶点与对称轴决定它的位置。',
  ),
];

String _envelope(List<Map<String, dynamic>> items) => jsonEncode({
  'choices': [
    {
      'finish_reason': 'stop',
      'message': {'content': jsonEncode({'items': items})},
    },
  ],
});

AiTransport _transport(_MemoryVault vault, String body) => AiTransport(
  vault: vault,
  client: MockClient(
    (request) async => http.Response.bytes(utf8.encode(body), 200),
  ),
);

void main() {
  late _MemoryVault vault;

  setUp(() async {
    vault = _MemoryVault();
    final seed = _transport(vault, '{}');
    await seed.saveKey(_settings, 'test-key');
    seed.close();
  });

  test('extracts source-linked knowledge and validates page bounds', () async {
    final body = _envelope([
      {
        'title': '二次函数图像',
        'objective': '能判断开口方向与顶点。',
        'sourceChunkId': 'c1',
        'startPage': 2,
        'endPage': 3,
        'priority': 2,
        'minutes': 45,
        'activity': 'learn',
        'completionCondition': '能独立画出图像。',
        'prerequisites': [],
      },
    ]);
    final client = KnowledgeAiClient(_transport(vault, body));
    final prepared = client.prepare(
      settings: _settings,
      plan: _plan(),
      chunks: _chunks(),
    );
    expect(prepared.previewSummary, contains('数学教材'));
    expect(prepared.chunks.single.startPage, 2);

    final result = await client.send(prepared);
    expect(result.items, hasLength(1));
    final item = result.items.single;
    expect(item.sourceId, 'source');
    expect(item.documentHash, 'hash-book');
    expect(item.startPage, 2);
    expect(item.endPage, 3);
    expect(item.priority, 2);
    expect(item.generatedByAi, isTrue);
  });

  test('rejects invented pages', () async {
    final body = _envelope([
      {
        'title': '编造页',
        'sourceChunkId': 'c1',
        'startPage': 8,
        'endPage': 9,
      },
    ]);
    final client = KnowledgeAiClient(_transport(vault, body));
    final prepared = client.prepare(
      settings: _settings,
      plan: _plan(),
      chunks: _chunks(),
    );
    await expectLater(
      client.send(prepared),
      throwsA(
        isA<AiFailure>().having(
          (failure) => failure.code,
          'code',
          AiError.invalidResponse,
        ),
      ),
    );
  });

  test('rejects forward prerequisites', () async {
    final body = _envelope([
      {
        'title': '自引用',
        'sourceChunkId': 'c1',
        'prerequisites': [0],
      },
    ]);
    final client = KnowledgeAiClient(_transport(vault, body));
    final request = client.prepare(
      settings: _settings,
      plan: _plan(),
      chunks: _chunks(),
    );
    await expectLater(
      client.send(request),
      throwsA(
        isA<AiFailure>().having(
          (failure) => failure.code,
          'code',
          AiError.invalidResponse,
        ),
      ),
    );
  });

  test('refuses extraction without ready material chunks', () {
    final client = KnowledgeAiClient(_transport(vault, '{}'));
    expect(
      () => client.prepare(
        settings: _settings,
        plan: _plan(),
        chunks: const [],
      ),
      throwsA(
        isA<AiFailure>().having(
          (failure) => failure.code,
          'code',
          AiError.rejected,
        ),
      ),
    );
  });
}
