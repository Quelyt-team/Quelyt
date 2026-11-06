import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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

Matcher fails(AiError code) =>
    throwsA(isA<AiFailure>().having((error) => error.code, 'code', code));

const settings = ProviderSettings(
  provider: '测试服务商',
  baseUrl: 'https://example.test/v1',
  model: 'text-model',
  visionModel: 'vision-model',
);

AiEvidence source({String id = 'E1', String? text}) => AiEvidence(
  id: id,
  text: text ?? '动量等于质量与速度的乘积，p = mv。',
  page: 3,
  documentId: 'book-1',
  documentHash: 'sha256-document-version',
  region: {'left': 0.1, 'top': 0.2, 'right': 0.8, 'bottom': 0.4},
);

String answerBody({
  String answer = '动量是质量与速度的乘积。',
  List<String> citations = const ['E1'],
  bool insufficient = false,
  String finishReason = 'stop',
}) => jsonEncode({
  'choices': [
    {
      'finish_reason': finishReason,
      'message': {
        'content': jsonEncode({
          'answer': answer,
          'citations': citations,
          'insufficientEvidence': insufficient,
        }),
      },
    },
  ],
  'usage': {'prompt_tokens': 400, 'completion_tokens': 60, 'total_tokens': 460},
});

ImageAttachment image({String scope = '第3页框选区域'}) => ImageAttachment(
  bytes: base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jC1kAAAAASUVORK5CYII=',
  ),
  mimeType: 'image/png',
  scopeLabel: scope,
);

void main() {
  late MemoryVault vault;
  late AiGateway gateway;
  late List<http.Request> requests;
  late int status;
  late String responseBody;

  setUp(() async {
    vault = MemoryVault();
    requests = [];
    status = 200;
    responseBody = answerBody();
    gateway = AiGateway(
      vault: vault,
      client: MockClient((request) async {
        requests.add(request);
        return http.Response.bytes(utf8.encode(responseBody), status);
      }),
    );
    await gateway.saveKey(settings, 'test-secret-key');
  });

  tearDown(() => gateway.close());

  PreparedAiRequest prepare({
    List<AiEvidence>? evidence,
    ImageAttachment? attachment,
    AiTask task = AiTask.explain,
    String question = '什么是动量？',
    String? learnerAnswer,
  }) => gateway.prepare(
    settings: settings,
    task: task,
    question: question,
    evidence: evidence ?? [source()],
    image: attachment,
    learnerAnswer: learnerAnswer,
  );

  test(
    'prepare is entirely local and preserves review text and source identity',
    () {
      final request = prepare();
      expect(request.question, '什么是动量？');
      expect(request.model, 'text-model');
      expect(request.evidence.single.text, source().text);
      expect(request.evidence.single.documentHash, 'sha256-document-version');
      final payload = jsonDecode(request.payloadJson) as Map;
      final userContent =
          jsonDecode(payload['messages'][1]['content'] as String) as Map;
      expect(userContent['question'], request.question);
      expect(userContent['evidence'][0]['text'], request.evidence.single.text);
      expect(userContent['evidence'][0]['physical_page'], 3);
      expect(userContent['evidence'][0]['region_normalized']['left'], 0.1);
      expect(request.payloadJson, isNot(contains('test-secret-key')));
      expect(settings.toJson().toString(), isNot(contains('test-secret-key')));
      expect(vault.reads, 0);
      expect(requests, isEmpty);
      expect(() => request.evidence.clear(), throwsUnsupportedError);
    },
  );

  test('send uses exactly reviewed payload, blocks redirects, reads Chinese and usage', () async {
    final request = prepare();
    final result = await gateway.send(request);
    expect(
      requests.single.url.toString(),
      'https://example.test/v1/chat/completions',
    );
    expect(requests.single.body, request.payloadJson);
    expect(requests.single.headers['Authorization'], 'Bearer test-secret-key');
    expect(requests.single.followRedirects, isFalse);
    expect(result.answer, '动量是质量与速度的乘积。');
    expect(result.citations, ['E1']);
    expect(result.insufficientEvidence, isFalse);
    expect(result.usage!.promptTokens, 400);
    expect(result.usage!.completionTokens, 60);
    expect(result.usage!.totalTokens, 460);
    expect(result.requestId, request.requestId);
  });

  test(
    'endpoint requires HTTPS except loopback and rejects embedded secrets',
    () {
      for (final address in [
        'http://example.test',
        'file:///tmp/api',
        'https://user:secret@example.test',
        'https://example.test?key=secret',
        'https://example.test#secret',
      ]) {
        expect(
          () => ProviderSettings(
            provider: 'x',
            baseUrl: address,
            model: 'x',
          ).endpoint,
          fails(AiError.invalidSettings),
        );
      }
      expect(
        const ProviderSettings(
          provider: 'x',
          baseUrl: 'http://localhost:11434/v1/',
          model: 'x',
        ).endpoint.toString(),
        'http://localhost:11434/v1/chat/completions',
      );
      expect(
        const ProviderSettings(
          provider: 'x',
          baseUrl: 'https://example.test/v1/chat/completions/',
          model: 'x',
        ).endpoint.toString(),
        'https://example.test/v1/chat/completions',
      );
    },
  );

  test('credential is bound to actual destination and never borrowed by edited URL', () async {
    const edited = ProviderSettings(
      provider: '测试服务商',
      baseUrl: 'https://another.test/v1',
      model: 'text-model',
    );
    expect(await gateway.readKey(settings), 'test-secret-key');
    expect(await gateway.readKey(edited), isNull);
    await gateway.deleteKey(settings);
    expect(await gateway.readKey(settings), isNull);
    await expectLater(gateway.send(prepare()), fails(AiError.missingKey));
    expect(requests, isEmpty);
  });

  test(
    'oversize context is rejected instead of silently altering send preview',
    () {
      expect(
        () => prepare(question: '问' * 3001),
        fails(AiError.contextTooLarge),
      );
      expect(
        () => prepare(evidence: [source(text: '文' * 16001)]),
        fails(AiError.contextTooLarge),
      );
      expect(
        () => prepare(evidence: List.generate(13, (i) => source(id: 'E$i'))),
        fails(AiError.contextTooLarge),
      );
      expect(requests, isEmpty);
    },
  );

  test('evidence must identify source version and use unique IDs', () {
    expect(
      () => prepare(evidence: [source(), source()]),
      fails(AiError.invalidSettings),
    );
    expect(
      () => prepare(
        evidence: [
          AiEvidence(
            id: 'E1',
            text: '文',
            page: 1,
            documentId: 'book',
            documentHash: '',
          ),
        ],
      ),
      fails(AiError.invalidSettings),
    );
  });

  test('cancelling image preview sends no image or other request', () async {
    final request = prepare(attachment: image(), task: AiTask.explainImage);
    expect(request.model, 'vision-model');
    expect(requests, isEmpty);
    await expectLater(
      gateway.send(request),
      fails(AiError.imageApprovalRequired),
    );
    expect(requests, isEmpty);
    expect(vault.reads, 0);
  });

  test('approved pixels and scope equal exact outgoing image and permission is single use', () async {
    final attachment = image();
    final request = prepare(attachment: attachment, task: AiTask.explainImage);
    final approval = request.approveImage();
    await gateway.send(request, imageApproval: approval);
    final payload = jsonDecode(requests.single.body) as Map;
    final content = payload['messages'][1]['content'] as List;
    expect(
      content[1]['image_url']['url'],
      'data:image/png;base64,${base64Encode(request.image!.bytes)}',
    );
    final text = jsonDecode(content[0]['text'] as String) as Map;
    expect(text['image_scope'], request.image!.scopeLabel);
    await expectLater(
      gateway.send(request, imageApproval: approval),
      fails(AiError.alreadySent),
    );
    expect(requests, hasLength(1));
  });

  test('approval cannot authorize another image request even with identical pixels', () async {
    final first = prepare(attachment: image());
    final approval = first.approveImage();
    final second = prepare(attachment: image(scope: '第3页整页'));
    await expectLater(
      gateway.send(second, imageApproval: approval),
      fails(AiError.imageApprovalRequired),
    );
    final third = prepare(attachment: image());
    await expectLater(
      gateway.send(third, imageApproval: approval),
      fails(AiError.imageApprovalRequired),
    );
    expect(requests, isEmpty);
    await gateway.send(first, imageApproval: approval);
    expect(requests, hasLength(1));
  });

  test('image bytes are copied so editing a selection cannot change reviewed content', () {
    final original = image().bytes;
    final attachment = ImageAttachment(
      bytes: original,
      mimeType: 'image/png',
      scopeLabel: '框选',
    );
    final initial = attachment.bytes;
    original[10] = 123;
    attachment.bytes[11] = 124;
    expect(attachment.bytes, orderedEquals(initial));
    expect(
      () => ImageAttachment(
        bytes: Uint8List(12),
        mimeType: 'image/png',
        scopeLabel: '框选',
      ),
      fails(AiError.invalidImage),
    );
  });

  test('a text-only preset cannot silently receive image pixels', () {
    expect(
      () => gateway.prepare(
        settings: ProviderSettings.deepSeek(),
        task: AiTask.explainImage,
        question: '解释公式',
        evidence: [source()],
        image: image(),
      ),
      fails(AiError.invalidSettings),
    );
    expect(requests, isEmpty);
  });

  test(
    'unknown source IDs are never clickable and force insufficient evidence',
    () async {
      responseBody = answerBody(citations: ['E1', 'invented-page-99', 'E1']);
      final result = await gateway.send(prepare());
      expect(result.citations, ['E1']);
      expect(result.rejectedCitationIds, ['invented-page-99']);
      expect(result.insufficientEvidence, isTrue);
      expect(result.requiresVerification, isTrue);
    },
  );

  test('text answer without a source is marked insufficient even if model says otherwise', () async {
    responseBody = answerBody(citations: []);
    final result = await gateway.send(prepare());
    expect(result.insufficientEvidence, isTrue);
    final noEvidence = await gateway.send(prepare(evidence: []));
    expect(noEvidence.insufficientEvidence, isTrue);
  });

  test(
    'search translation sends only the question without document or answer',
    () async {
      final request = prepare(task: AiTask.searchTerms, evidence: []);
      final payload = jsonDecode(request.payloadJson) as Map;
      final content =
          jsonDecode(payload['messages'][1]['content'] as String) as Map;
      expect(content.keys, unorderedEquals(['task', 'question']));
      expect(
        () => prepare(task: AiTask.searchTerms),
        fails(AiError.invalidSettings),
      );
      responseBody = answerBody(
        answer: 'momentum linear momentum',
        citations: [],
      );
      final result = await gateway.send(request);
      expect(result.insufficientEvidence, isFalse);
    },
  );

  test('grading requires independent learner answer', () {
    expect(
      () => prepare(task: AiTask.gradeAnswer),
      fails(AiError.invalidSettings),
    );
    final request = prepare(task: AiTask.gradeAnswer, learnerAnswer: 'p=mv');
    expect(request.learnerAnswer, 'p=mv');
    expect(request.payloadJson, contains('learner_answer'));
  });

  test(
    'prepared text requests also cannot be accidentally charged twice',
    () async {
      final request = prepare();
      await gateway.send(request);
      await expectLater(gateway.send(request), fails(AiError.alreadySent));
      expect(requests, hasLength(1));
    },
  );

  for (final entry in {
    401: AiError.unauthorized,
    403: AiError.unauthorized,
    429: AiError.rateLimited,
    503: AiError.server,
    400: AiError.rejected,
    302: AiError.rejected,
  }.entries) {
    test(
      'HTTP ${entry.key} maps to safe error without exposing body or retrying',
      () async {
        status = entry.key;
        responseBody =
            'provider echoes test-secret-key and private source text';
        try {
          await gateway.send(prepare());
          fail('Expected failure');
        } on AiFailure catch (error) {
          expect(error.code, entry.value);
          expect(error.statusCode, entry.key);
          expect(error.message, isNot(contains('test-secret-key')));
          expect(error.message, isNot(contains('private source text')));
        }
        expect(requests, hasLength(1));
      },
    );
  }

  test(
    'malformed provider envelope and malformed model JSON are rejected',
    () async {
      for (final body in [
        '<html>bad gateway</html>',
        '{}',
        '{"choices":[]}',
        jsonEncode({
          'choices': [
            {
              'message': {'content': 'unstructured opinion'},
            },
          ],
        }),
        jsonEncode({
          'choices': [
            {
              'message': {
                'content': '{"answer":"x","citations":[],"insufficientEvidence":"false"}',
              },
            },
          ],
        }),
      ]) {
        responseBody = body;
        await expectLater(
          gateway.send(prepare()),
          fails(AiError.invalidResponse),
        );
      }
    },
  );

  test('truncated JSON is not accepted as a complete answer', () async {
    responseBody = answerBody(finishReason: 'length');
    await expectLater(gateway.send(prepare()), fails(AiError.truncated));
  });

  test('network failure does not echo exception details or retry', () async {
    var calls = 0;
    final offline = AiGateway(
      vault: vault,
      client: MockClient((_) async {
        calls++;
        throw http.ClientException('private source test-secret-key');
      }),
    );
    addTearDown(offline.close);
    await expectLater(offline.send(prepare()), fails(AiError.network));
    expect(calls, 1);
  });

  test(
    'timeout is bounded and does not automatically send another request',
    () async {
      var calls = 0;
      final slow = AiGateway(
        vault: vault,
        timeout: const Duration(milliseconds: 1),
        client: MockClient((_) async {
          calls++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return http.Response(answerBody(), 200);
        }),
      );
      addTearDown(slow.close);
      await expectLater(slow.send(prepare()), fails(AiError.timeout));
      expect(calls, 1);
    },
  );

  test('current DeepSeek preset uses supported model and bounded non-thinking output', () {
    final request = gateway.prepare(
      settings: ProviderSettings.deepSeek(),
      task: AiTask.explain,
      question: '问题',
      evidence: [source()],
    );
    expect(request.model, 'deepseek-flash');
    expect((jsonDecode(request.payloadJson) as Map)['thinking'], {
      'type': 'disabled',
    });
  });
}
