import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:local_study/features/schedule/models/local_date.dart';
import 'package:local_study/features/schedule/models/plan_availability.dart';
import 'package:local_study/features/schedule/models/planning_models.dart';
import 'package:local_study/features/schedule/models/study_plan.dart';
import 'package:local_study/features/schedule/services/planning_ai_client.dart';
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

Matcher _fails(AiError code) =>
    throwsA(isA<AiFailure>().having((error) => error.code, 'code', code));

const _settings = ProviderSettings(
  provider: '测试服务商',
  baseUrl: 'https://example.test/v1',
  model: 'text-model',
);

StudyPlan _selectedPlan() => StudyPlan(
  id: 'plan',
  title: '期中数学备考',
  subject: '数学',
  startDate: LocalDate(2026, 11, 9),
  endDate: LocalDate(2026, 11, 28),
  examDate: LocalDate(2026, 11, 29),
  goal: '覆盖二次函数与判别式',
);

StudyPlan _otherPlan() => StudyPlan(
  id: 'other',
  title: '私密英语计划标题',
  subject: '英语',
  startDate: LocalDate(2026, 11, 9),
  endDate: LocalDate(2026, 11, 28),
  examDate: LocalDate(2026, 11, 20),
);

PlanAvailability _availability() => PlanAvailability(
  planId: 'plan',
  weekly: [
    for (var weekday = 1; weekday <= 5; weekday++)
      WeeklySlot(
        weekday: weekday,
        startMinute: 19 * 60 + 30,
        endMinute: 21 * 60,
      ),
  ],
);

PlanningContext _context({List<PlanningMessage> history = const []}) =>
    PlanningContext(
      today: LocalDate(2026, 11, 7),
      timezone: 'Asia/Shanghai',
      plans: [_selectedPlan(), _otherPlan()],
      selectedPlan: _selectedPlan(),
      selectedAvailability: _availability(),
      history: history,
    );

String _envelope(
  Map<String, dynamic> reply, {
  String finishReason = 'stop',
  int promptTokens = 300,
  int completionTokens = 80,
}) => jsonEncode({
  'choices': [
    {
      'finish_reason': finishReason,
      'message': {'content': jsonEncode(reply)},
    },
  ],
  'usage': {
    'prompt_tokens': promptTokens,
    'completion_tokens': completionTokens,
    'total_tokens': promptTokens + completionTokens,
  },
});

void main() {
  late _MemoryVault vault;
  late List<http.Request> requests;
  late String responseBody;
  late int status;
  late AiTransport transport;
  late PlanningAiClient client;

  setUp(() async {
    vault = _MemoryVault();
    requests = [];
    status = 200;
    responseBody = _envelope({
      'kind': 'clarification',
      'message': '还需要确认考试范围。',
      'questions': [
        {
          'field': 'scope',
          'question': '这次考试的范围是哪几章？',
          'options': ['二次函数', '整册'],
        },
      ],
    });
    transport = AiTransport(
      vault: vault,
      client: MockClient((request) async {
        requests.add(request);
        return http.Response.bytes(utf8.encode(responseBody), status);
      }),
    );
    client = PlanningAiClient(transport);
    await transport.saveKey(_settings, 'test-secret-key');
  });

  tearDown(() => transport.close());

  PreparedPlanningRequest prepare([String message = '这个月29号要考数学，帮我排一下']) =>
      client.prepare(
        settings: _settings,
        message: message,
        context: _context(),
        conversationId: 'conversation',
      );

  test('prepare is local and sends only selected plan plus other subjects', () {
    final request = prepare();
    expect(requests, isEmpty);
    expect(vault.values, hasLength(1));
    final payload = jsonDecode(request.payloadJson) as Map;
    expect(payload['model'], 'text-model');
    expect(payload['response_format'], {'type': 'json_object'});
    final user = jsonDecode(payload['messages'][1]['content'] as String) as Map;
    expect(user['local_date'], '2026-11-07');
    expect(user['timezone'], 'Asia/Shanghai');
    expect(user['selected_plan']['title'], '期中数学备考');
    expect(user['other_plans'].single['subject'], '英语');
    expect(request.payloadJson, isNot(contains('私密英语计划标题')));
    expect(request.payloadJson, isNot(contains('test-secret-key')));
    expect(request.contextSummary, contains('本地日期'));
  });

  test('clarification parses questions and exposes usage', () async {
    final result = await client.send(prepare());
    expect(result.reply.kind, PlanningKind.clarification);
    expect(result.reply.questions.single.field, 'scope');
    expect(result.reply.questions.single.options, ['二次函数', '整册']);
    expect(result.usage!.totalTokens, 380);
    expect(requests.single.headers['Authorization'], 'Bearer test-secret-key');
    expect(requests.single.followRedirects, isFalse);
  });

  test('proposal parses dates and availability for the selected plan', () async {
    responseBody = _envelope({
      'kind': 'proposal',
      'message': '按工作日晚上安排，保留机动时间。',
      'proposal': {
        'planId': 'plan',
        'examDate': '2026-11-29',
        'availability': {
          'weekly': [
            {'weekday': 1, 'startMinute': 1170, 'endMinute': 1260},
            {'weekday': 3, 'startMinute': 1170, 'endMinute': 1260},
          ],
          'dailyCapMinutes': 120,
          'bufferPercent': 15,
          'maxStudyDaysPerWeek': 2,
          'breakMinutes': 5,
          'unitMinutes': 25,
        },
        'assumptions': ['周三晚上可用'],
        'unsupported': ['尚未绑定教材'],
      },
    });
    final result = await client.send(prepare());
    final proposal = result.reply.proposal!;
    expect(proposal.planId, 'plan');
    expect(proposal.examDate, LocalDate(2026, 11, 29));
    expect(proposal.availability!.weekly, hasLength(2));
    expect(proposal.assumptions.single, '周三晚上可用');
  });

  test('new plan proposal requires dates and rejects unknown plan ids', () async {
    responseBody = _envelope({
      'kind': 'proposal',
      'message': '新计划',
      'proposal': {
        'planId': null,
        'title': '数学冲刺',
        'startDate': '2026-11-09',
        'endDate': '2026-11-28',
        'examDate': '2026-11-29',
      },
    });
    final result = await client.send(prepare());
    expect(result.reply.proposal!.title, '数学冲刺');

    responseBody = _envelope({
      'kind': 'proposal',
      'message': '越权计划',
      'proposal': {'planId': 'other', 'examDate': '2026-11-29'},
    });
    await expectLater(client.send(prepare()), _fails(AiError.invalidResponse));
  });

  test('invalid dates, unknown fields and too many questions are rejected', () async {
    responseBody = _envelope({
      'kind': 'proposal',
      'message': '不存在的日期',
      'proposal': {
        'planId': 'plan',
        'startDate': '2026-02-30',
        'endDate': '2026-03-01',
      },
    });
    await expectLater(client.send(prepare()), _fails(AiError.invalidResponse));

    responseBody = _envelope({
      'kind': 'proposal',
      'message': '过去的考试',
      'proposal': {'planId': 'plan', 'examDate': '2026-11-01'},
    });
    await expectLater(client.send(prepare()), _fails(AiError.invalidResponse));

    responseBody = _envelope({
      'kind': 'clarification',
      'message': '太多问题',
      'questions': [
        for (var index = 0; index < 4; index++)
          {'field': 'f$index', 'question': '问题 $index'},
      ],
    });
    await expectLater(client.send(prepare()), _fails(AiError.invalidResponse));

    responseBody = _envelope({
      'kind': 'clarification',
      'message': '多字段',
      'questions': [
        {'field': 'scope', 'question': '范围？'},
      ],
      'sql': 'delete from calendar_blocks',
    });
    await expectLater(client.send(prepare()), _fails(AiError.invalidResponse));
  });

  test('truncation, empty content and HTTP failures are safe', () async {
    responseBody = _envelope(
      {
        'kind': 'clarification',
        'message': '被截断',
        'questions': [
          {'field': 'scope', 'question': '范围？'},
        ],
      },
      finishReason: 'length',
    );
    await expectLater(client.send(prepare()), _fails(AiError.truncated));

    responseBody = '';
    status = 401;
    await expectLater(client.send(prepare()), _fails(AiError.unauthorized));

    status = 429;
    await expectLater(client.send(prepare()), _fails(AiError.rateLimited));

    status = 500;
    await expectLater(client.send(prepare()), _fails(AiError.server));

    status = 200;
    responseBody = 'not json';
    await expectLater(client.send(prepare()), _fails(AiError.invalidResponse));
  });

  test('missing key fails before any request and prepared request is single-use', () async {
    await transport.deleteKey(_settings);
    final request = prepare();
    await expectLater(client.send(request), _fails(AiError.missingKey));
    expect(requests, isEmpty);

    await transport.saveKey(_settings, 'another-key');
    final valid = prepare();
    await client.send(valid);
    await expectLater(client.send(valid), _fails(AiError.alreadySent));
    expect(requests, hasLength(1));
  });
}
