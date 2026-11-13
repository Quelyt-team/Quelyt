import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:local_study/app_controller.dart';
import 'package:local_study/core/local_store.dart';
import 'package:local_study/features/schedule/data/schedule_repository.dart';
import 'package:local_study/services/ai_gateway.dart';
import 'package:local_study/services/document_service.dart';
import 'package:local_study/services/ocr_service.dart';
import 'package:local_study/ui/study_app.dart';

class _MemoryVault implements CredentialVault {
  final _values = <String, String>{};
  @override
  Future<void> delete(String accountId) async => _values.remove(accountId);
  @override
  Future<String?> read(String accountId) async => _values[accountId];
  @override
  Future<void> write(String accountId, String value) async =>
      _values[accountId] = value;
}

String _proposalEnvelope() => jsonEncode({
  'choices': [
    {
      'finish_reason': 'stop',
      'message': {
        'content': jsonEncode({
          'kind': 'proposal',
          'message': '按工作日晚上排，先搭好时间框架。',
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
                  {
                    'weekday': weekday,
                    'startMinute': 1170,
                    'endMinute': 1260,
                  },
              ],
              'dailyCapMinutes': 120,
              'bufferPercent': 15,
              'maxStudyDaysPerWeek': 5,
              'breakMinutes': 5,
              'unitMinutes': 25,
            },
            'assumptions': ['只安排工作日晚上'],
            'unsupported': ['尚未绑定教材'],
          },
        }),
      },
    },
  ],
  'usage': {'prompt_tokens': 200, 'completion_tokens': 80, 'total_tokens': 280},
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late LocalStore store;
  late StudyController controller;
  late ScheduleRepository repository;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('planning-ui-');
    store = LocalStore.inMemory();
    repository = ScheduleRepository(store);
    final ocr = OcrService();
    controller = StudyController(
      store: store,
      ocr: ocr,
      documents: DocumentService(directory, store, ocr),
      gateway: AiGateway(
        vault: _MemoryVault(),
        client: MockClient(
          (request) async =>
              http.Response.bytes(utf8.encode(_proposalEnvelope()), 200),
        ),
      ),
    );
    await controller.gateway.saveKey(controller.settings, 'test-key');
  });

  tearDown(() async {
    await controller.shutdown();
    controller.dispose();
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  testWidgets('planning conversation previews and applies a new plan', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(StudyApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日程').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('planning-bar')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('planning-bar')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('planning-sheet')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('planning-input')),
      '2030 年 1 月 21 日数学考试，周一到周五晚上七点半到九点可以学',
    );
    await tester.tap(find.byKey(const ValueKey('planning-send')));
    await tester.pumpAndSettle();
    expect(find.text('发送排期请求'), findsOneWidget);
    expect(find.textContaining('不发送教材原文'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('planning-confirm-send')));
    await tester.pumpAndSettle();

    expect(find.textContaining('数学冲刺'), findsWidgets);
    expect(find.text('查看并应用设置'), findsOneWidget);
    await tester.tap(find.text('查看并应用设置'));
    await tester.pumpAndSettle();
    expect(find.text('应用新计划设置'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('planning-apply')));
    await tester.pumpAndSettle();

    final plans = repository.getPlans();
    expect(plans, hasLength(1));
    expect(plans.single.title, '数学冲刺');
    expect(plans.single.examDate!.iso, '2030-01-21');
    final availability = repository.getAvailability(plans.single.id)!;
    expect(availability.weekly, hasLength(5));
    expect(availability.bufferPercent, 15);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone planning sheet opens and previews', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(StudyApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日程').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('planning-bar')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('planning-sheet')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('planning-input')),
      '帮我排一个数学计划',
    );
    await tester.ensureVisible(find.byKey(const ValueKey('planning-send')));
    await tester.tap(find.byKey(const ValueKey('planning-send')));
    await tester.pumpAndSettle();
    expect(find.text('发送排期请求'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
