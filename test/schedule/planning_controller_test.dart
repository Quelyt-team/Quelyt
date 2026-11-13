import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:local_study/core/local_store.dart';
import 'package:local_study/features/schedule/data/planning_repository.dart';
import 'package:local_study/features/schedule/data/schedule_repository.dart';
import 'package:local_study/features/schedule/domain/schedule_validator.dart';
import 'package:local_study/features/schedule/models/local_date.dart';
import 'package:local_study/features/schedule/models/plan_availability.dart';
import 'package:local_study/features/schedule/models/planning_models.dart';
import 'package:local_study/features/schedule/models/study_plan.dart';
import 'package:local_study/features/schedule/schedule_controller.dart';
import 'package:local_study/services/ai_gateway.dart';

const _settings = ProviderSettings(
  provider: '测试服务商',
  baseUrl: 'https://example.test/v1',
  model: 'text-model',
);

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

String _envelope(Map<String, dynamic> reply) => jsonEncode({
  'choices': [
    {
      'finish_reason': 'stop',
      'message': {'content': jsonEncode(reply)},
    },
  ],
  'usage': {'prompt_tokens': 120, 'completion_tokens': 30, 'total_tokens': 150},
});

Map<String, dynamic> _clarification() => {
  'kind': 'clarification',
  'message': '还需要确认考试范围。',
  'questions': [
    {'field': 'scope', 'question': '这次考哪几章？'},
  ],
};

Map<String, dynamic> _newPlanProposal() => {
  'kind': 'proposal',
  'message': '按工作日晚上安排。',
  'proposal': {
    'planId': null,
    'title': '数学冲刺',
    'subject': '数学',
    'startDate': '2030-01-07',
    'endDate': '2030-01-20',
    'examDate': '2030-01-21',
    'availability': {
      'weekly': [
        for (var weekday = 1; weekday <= 5; weekday++)
          {'weekday': weekday, 'startMinute': 1170, 'endMinute': 1260},
      ],
      'dailyCapMinutes': 120,
      'bufferPercent': 10,
      'maxStudyDaysPerWeek': 5,
      'breakMinutes': 0,
      'unitMinutes': 45,
    },
    'assumptions': ['只安排工作日晚上'],
    'unsupported': ['尚未绑定教材'],
  },
};

StudyPlan _plan() => StudyPlan(
  id: 'plan',
  title: '期中数学',
  subject: '数学',
  startDate: LocalDate(2030, 1, 7),
  endDate: LocalDate(2030, 1, 20),
  examDate: LocalDate(2030, 1, 21),
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

void main() {
  late LocalStore store;
  late ScheduleRepository repository;
  late _MemoryVault vault;
  late AiGateway gateway;
  late ScheduleController controller;
  late String responseBody;
  late List<http.Request> requests;
  Completer<http.Response>? pending;

  setUp(() async {
    store = LocalStore.inMemory();
    repository = ScheduleRepository(store);
    repository.savePlan(_plan());
    repository.saveAvailability(_availability());
    vault = _MemoryVault();
    requests = [];
    responseBody = _envelope(_clarification());
    gateway = AiGateway(
      vault: vault,
      client: MockClient((request) {
        requests.add(request);
        final waiting = pending;
        if (waiting != null) return waiting.future;
        return Future.value(http.Response.bytes(utf8.encode(responseBody), 200));
      }),
    );
    await gateway.saveKey(_settings, 'test-key');
    controller = ScheduleController(
      repository,
      ai: gateway,
      settingsProvider: () => _settings,
    );
    controller.initialize();
    controller.openPlanning(planId: 'plan');
  });

  tearDown(() {
    controller.dispose();
    gateway.close();
    store.dispose();
  });

  test('a clarification is persisted in the plan conversation', () async {
    final request = controller.preparePlanning('这个月29号考数学');
    await controller.sendPreparedPlanning(request);
    expect(requests, hasLength(1));
    expect(controller.planningMessages, hasLength(2));
    expect(controller.planningMessages.first.role, PlanningRole.user);
    expect(controller.planningMessages.last.kind, PlanningKind.clarification);
    expect(controller.planningMessages.last.usage!.totalTokens, 150);
    expect(controller.planningConversation!.planId, 'plan');
    final stored = PlanningRepository(store).messages(
      controller.planningConversation!.id,
    );
    expect(stored, hasLength(2));
    expect(stored.last.questions.single.field, 'scope');
  });

  test('proposal is applied as one plan and availability transaction', () async {
    responseBody = _envelope(_newPlanProposal());
    await controller.sendPreparedPlanning(
      controller.preparePlanning('每周一到五晚上七点半到九点'),
    );
    final proposalMessage = controller.planningMessages.last;
    expect(proposalMessage.kind, PlanningKind.proposal);
    final plan = controller.applyPlanningProposal(proposalMessage);
    expect(plan.title, '数学冲刺');
    expect(controller.planFilterId, plan.id);
    expect(repository.getPlan(plan.id)!.title, '数学冲刺');
    final availability = repository.getAvailability(plan.id)!;
    expect(availability.weekly, hasLength(5));
    expect(availability.bufferPercent, 10);
    expect(
      controller.planningMessages.last.applied,
      isTrue,
    );
    expect(
      controller.planningConversation!.planId,
      plan.id,
    );
  });

  test('cancelling prevents a late reply from entering the conversation', () async {
    final waiting = Completer<http.Response>();
    pending = waiting;
    final request = controller.preparePlanning('帮我排数学');
    final sending = controller.sendPreparedPlanning(request);
    await Future<void>.delayed(Duration.zero);
    expect(controller.planningSending, isTrue);
    controller.cancelPlanningSend();
    expect(controller.planningSending, isFalse);
    waiting.complete(
      http.Response.bytes(utf8.encode(_envelope(_newPlanProposal())), 200),
    );
    await sending;
    expect(controller.planningMessages, hasLength(2));
    expect(controller.planningMessages.last.kind, PlanningKind.cancelled);
    expect(repository.getPlans(), hasLength(1));
    expect(
      controller.planningMessages.any((message) => message.proposal != null),
      isFalse,
    );
  });

  test('missing key is recorded without a network request', () async {
    await gateway.deleteKey(_settings);
    final request = controller.preparePlanning('帮我排数学');
    await controller.sendPreparedPlanning(request);
    expect(requests, isEmpty);
    expect(controller.planningError, contains('API Key'));
    expect(controller.planningMessages.last.kind, PlanningKind.error);
    expect(controller.planningMessages.last.failed, isTrue);
  });

  test('a stale prepared request cannot be sent after switching conversation', () async {
    final request = controller.preparePlanning('帮我排数学');
    controller.startNewPlanningConversation();
    await expectLater(
      controller.sendPreparedPlanning(request),
      throwsA(isA<ScheduleValidationException>()),
    );
    expect(requests, isEmpty);
  });
}
