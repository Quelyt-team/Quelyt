import 'dart:convert';
import 'dart:math';

import 'package:uuid/uuid.dart';

import '../../../core/models.dart';
import '../../../services/ai_transport.dart';
import '../../../services/ai_types.dart';
import '../models/daily_lesson.dart';
import '../models/material_ref.dart';
import '../models/study_plan.dart';
import '../models/study_task.dart';

class PreparedLessonRequest {
  PreparedLessonRequest._({
    required this.settings,
    required this.model,
    required this.task,
    required this.plan,
    required this.material,
    required this.pages,
    required this.payloadJson,
    required this.endpoint,
    required this.requestId,
    required this.previewSummary,
  });

  final ProviderSettings settings;
  final String model;
  final StudyTask task;
  final StudyPlan plan;
  final MaterialRef material;
  final List<PageRecord> pages;
  final String payloadJson;
  final Uri endpoint;
  final String requestId;
  final String previewSummary;
  bool _sent = false;
}

class LessonAiClient {
  LessonAiClient(this.transport);

  final AiTransport transport;
  static const int maxPages = 8;
  static const int maxCharacters = 9000;
  static const int maxOutputTokens = 3000;
  static const Uuid _uuid = Uuid();

  PreparedLessonRequest prepare({
    required ProviderSettings settings,
    required StudyTask task,
    required StudyPlan plan,
    required MaterialRef material,
    required List<PageRecord> pages,
  }) {
    final model = settings.model.trim();
    if (model.isEmpty) {
      throw const AiFailure(AiError.invalidSettings, '请先在设置中填写文本模型名称。');
    }
    final ready = pages
        .where(
          (page) =>
              page.page >= material.startPage &&
              page.page <= material.endPage &&
              page.status == PageStatus.ready &&
              page.text.trim().isNotEmpty,
        )
        .take(maxPages)
        .toList();
    if (ready.isEmpty) {
      throw const AiFailure(AiError.rejected, '这个任务的教材页还没有可读文字。');
    }
    final text = StringBuffer();
    for (final page in ready) {
      if (text.length >= maxCharacters) break;
      final room = maxCharacters - text.length;
      final body = page.text.trim();
      text.writeln('[第 ${page.page} 页]');
      text.writeln(body.length <= room ? body : body.substring(0, room));
    }
    final payload = <String, dynamic>{
      'model': model,
      'messages': [
        {'role': 'system', 'content': _systemPrompt},
        {
          'role': 'user',
          'content': jsonEncode({
            'task': 'generateLessonUnit',
            'plan': {
              'id': plan.id,
              'title': plan.title,
              'subject': plan.subject,
              'examDate': plan.examDate?.iso,
            },
            'lesson_task': {
              'title': task.title,
              'knowledge': task.knowledge,
              'completionCondition': task.completionCondition,
              'minutes': task.minutes,
              'activity': task.activity.name,
            },
            'material': {
              'documentTitle': material.title,
              'startPage': material.startPage,
              'endPage': material.endPage,
            },
            'pages': [
              for (final page in ready)
                {'page': page.page, 'text': page.text.trim()},
            ],
          }),
        },
      ],
      'stream': false,
      'max_tokens': maxOutputTokens,
      'response_format': {'type': 'json_object'},
      if (settings.endpoint.host == 'api.deepseek.com')
        'thinking': {'type': 'disabled'},
      if (settings.endpoint.host.endsWith('.aliyuncs.com') &&
          model.startsWith('qwen'))
        'enable_thinking': false,
    };
    return PreparedLessonRequest._(
      settings: settings,
      model: model,
      task: task,
      plan: plan,
      material: material,
      pages: ready,
      payloadJson: jsonEncode(payload),
      endpoint: settings.endpoint,
      requestId: List.generate(
        16,
        (_) => Random.secure().nextInt(256),
      ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
      previewSummary:
          '任务：${task.title}\n'
          '模型：$model\n'
          '材料：${material.title} · 第 ${material.startPage}–${material.endPage} 页\n'
          '发送 ${ready.length} 页已解析文本；不会发送整本书或其他计划。',
    );
  }

  Future<DailyLesson> send(PreparedLessonRequest request) async {
    if (request._sent) {
      throw const AiFailure(AiError.alreadySent, '这次课程请求已提交。');
    }
    request._sent = true;
    final response = await transport.postJson(
      settings: request.settings,
      endpoint: request.endpoint,
      payloadJson: request.payloadJson,
    );
    final dynamic outer;
    try {
      outer = jsonDecode(response.body);
    } catch (_) {
      throw const AiFailure(AiError.invalidResponse, '服务商未返回有效的 JSON 响应。');
    }
    if (outer is! Map ||
        outer['choices'] is! List ||
        (outer['choices'] as List).isEmpty) {
      throw const AiFailure(AiError.invalidResponse, '服务商响应缺少回答。');
    }
    final dynamic choice = (outer['choices'] as List).first;
    if (choice is! Map || choice['message'] is! Map) {
      throw const AiFailure(AiError.invalidResponse, '服务商响应格式不受支持。');
    }
    if (choice['finish_reason'] == 'length') {
      throw const AiFailure(AiError.truncated, '课程因长度限制被截断，请缩小材料范围。');
    }
    final dynamic content = (choice['message'] as Map)['content'];
    if (content is! String || content.trim().isEmpty) {
      throw const AiFailure(AiError.invalidResponse, '模型返回了空课程。');
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(AiTransport.stripJsonFence(content));
    } catch (_) {
      throw const AiFailure(AiError.invalidResponse, '模型没有返回结构化课程 JSON。');
    }
    if (decoded is! Map) {
      throw const AiFailure(AiError.invalidResponse, '课程结果不是 JSON 对象。');
    }
    final json = Map<String, dynamic>.from(decoded);
    if (!const {
      'title',
      'objective',
      'sections',
      'exercises',
    }.containsAll(json.keys)) {
      throw const AiFailure(AiError.invalidResponse, '课程包含未允许的字段。');
    }
    final title = json['title'];
    final objective = json['objective'];
    final rawSections = json['sections'];
    final rawExercises = json['exercises'];
    if (title is! String ||
        title.trim().isEmpty ||
        title.length > 120 ||
        objective is! String ||
        objective.trim().isEmpty ||
        objective.length > 500 ||
        rawSections is! List ||
        rawSections.isEmpty ||
        rawSections.length > 8 ||
        rawExercises is! List ||
        rawExercises.isEmpty ||
        rawExercises.length > 6) {
      throw const AiFailure(AiError.invalidResponse, '课程标题、目标、讲解或练习数量不合法。');
    }
    final sections = <LessonSection>[];
    for (final raw in rawSections) {
      if (raw is! Map) {
        throw const AiFailure(AiError.invalidResponse, '课程讲解块格式不正确。');
      }
      final item = Map<String, dynamic>.from(raw);
      if (!const {'title', 'body', 'sourcePage'}.containsAll(item.keys)) {
        throw const AiFailure(AiError.invalidResponse, '课程讲解块包含未允许字段。');
      }
      final sectionTitle = item['title'];
      final body = item['body'];
      final page = (item['sourcePage'] as num?)?.toInt();
      if (sectionTitle is! String ||
          sectionTitle.trim().isEmpty ||
          body is! String ||
          body.trim().isEmpty ||
          body.length > 4000 ||
          (page != null &&
              (page < request.material.startPage ||
                  page > request.material.endPage))) {
        throw const AiFailure(AiError.invalidResponse, '课程讲解内容或页码不合法。');
      }
      sections.add(
        LessonSection(
          title: sectionTitle.trim(),
          body: body.trim(),
          sourcePage: page,
        ),
      );
    }
    final exercises = <LessonExercise>[];
    for (final raw in rawExercises) {
      if (raw is! Map) {
        throw const AiFailure(AiError.invalidResponse, '课程练习格式不正确。');
      }
      final item = Map<String, dynamic>.from(raw);
      if (!const {
        'prompt',
        'answer',
        'solution',
        'sourcePage',
      }.containsAll(item.keys)) {
        throw const AiFailure(AiError.invalidResponse, '课程练习包含未允许字段。');
      }
      final prompt = item['prompt'];
      final answer = item['answer'];
      final solution = item['solution'];
      final page = (item['sourcePage'] as num?)?.toInt();
      if (prompt is! String ||
          prompt.trim().isEmpty ||
          answer is! String ||
          answer.trim().isEmpty ||
          solution is! String ||
          solution.trim().isEmpty ||
          prompt.length > 1000 ||
          answer.length > 1000 ||
          solution.length > 3000 ||
          (page != null &&
              (page < request.material.startPage ||
                  page > request.material.endPage))) {
        throw const AiFailure(AiError.invalidResponse, '课程练习缺少题干、答案、解答或页码越界。');
      }
      exercises.add(
        LessonExercise(
          id: _uuid.v4(),
          prompt: prompt.trim(),
          answer: answer.trim(),
          solution: solution.trim(),
          sourcePage: page,
        ),
      );
    }
    return DailyLesson(
      id: _uuid.v4(),
      taskId: request.task.id,
      planId: request.plan.id,
      title: title.trim(),
      objective: objective.trim(),
      sections: sections,
      exercises: exercises,
      materialDocumentId: request.material.documentId,
      materialHash: request.material.documentHash,
      startPage: request.material.startPage,
      endPage: request.material.endPage,
      model: request.model,
    );
  }

  static const String _systemPrompt =
      '你是每日学习课程生成器。只使用 user JSON 中提供的教材页文本，'
      '生成一份可在任务预算内完成的课程。返回严格 JSON：'
      '{"title":"不超过120字","objective":"可观察的今日目标",'
      '"sections":[{"title":"讲解标题","body":"讲解正文",'
      '"sourcePage":页号}],'
      '"exercises":[{"prompt":"题干","answer":"最终答案",'
      '"solution":"完整解答与理由","sourcePage":页号}]}。'
      'sections 1–8 个，exercises 1–6 个；sourcePage 必须在提供范围内。'
      '答案与解答必须分开；不得编造教材页码、题目出处或未提供的事实。'
      '不要输出 Markdown 以外的解释文字。';
}
