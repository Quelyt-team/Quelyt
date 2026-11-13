import 'dart:convert';
import 'dart:math';

import 'package:uuid/uuid.dart';

import '../../../services/ai_transport.dart';
import '../../../services/ai_types.dart';
import '../models/knowledge_item.dart';
import '../models/plan_source.dart';
import '../models/study_plan.dart';
import '../models/study_task.dart';
import '../services/material_catalog_service.dart';

class PreparedKnowledgeRequest {
  PreparedKnowledgeRequest._({
    required this.settings,
    required this.model,
    required this.plan,
    required this.chunks,
    required this.focus,
    required this.payloadJson,
    required this.endpoint,
    required this.requestId,
    required this.previewSummary,
  });

  final ProviderSettings settings;
  final String model;
  final StudyPlan plan;
  final List<MaterialChunk> chunks;
  final String focus;
  final String payloadJson;
  final Uri endpoint;
  final String requestId;
  final String previewSummary;
  bool _sent = false;
}

class KnowledgeSendResult {
  const KnowledgeSendResult({
    required this.items,
    required this.model,
    required this.requestId,
    this.usage,
  });

  final List<KnowledgeItem> items;
  final String model;
  final String requestId;
  final TokenUsage? usage;
}

/// Strict JSON protocol for extracting teachable knowledge points from selected
/// material chunks. Every item must point back to one submitted chunk and a
/// page range inside it; the client rejects invented pages.
class KnowledgeAiClient {
  KnowledgeAiClient(this.transport);

  final AiTransport transport;
  static const int maxChunks = 8;
  static const int maxChunkCharacters = 1600;
  static const int maxTotalCharacters = 10000;
  static const int maxItems = 20;
  static const int maxOutputTokens = 2400;
  static const Uuid _uuid = Uuid();

  PreparedKnowledgeRequest prepare({
    required ProviderSettings settings,
    required StudyPlan plan,
    required List<MaterialChunk> chunks,
    String focus = '',
  }) {
    final model = settings.model.trim();
    if (model.isEmpty) {
      throw const AiFailure(AiError.invalidSettings, '请先在设置中填写文本模型名称。');
    }
    final trimmedFocus = focus.trim();
    if (trimmedFocus.length > 500) {
      throw const AiFailure(AiError.contextTooLarge, '提取重点过长，请精简到 500 字以内。');
    }
    if (chunks.isEmpty) {
      throw const AiFailure(AiError.rejected, '没有已解析的材料页，无法提取知识点。');
    }
    final selected = <MaterialChunk>[];
    var characters = 0;
    for (final chunk in chunks) {
      if (selected.length >= maxChunks || characters >= maxTotalCharacters) {
        break;
      }
      final text = chunk.text.trim();
      if (text.isEmpty) continue;
      final room = maxTotalCharacters - characters;
      final clipped = text.length <= min(room, maxChunkCharacters)
          ? text
          : text.substring(0, min(room, maxChunkCharacters));
      selected.add(
        MaterialChunk(
          sourceId: chunk.sourceId,
          planId: chunk.planId,
          documentId: chunk.documentId,
          documentHash: chunk.documentHash,
          documentTitle: chunk.documentTitle,
          purpose: chunk.purpose,
          chapter: chunk.chapter,
          startPage: chunk.startPage,
          endPage: chunk.endPage,
          text: clipped,
        ),
      );
      characters += clipped.length;
    }
    if (selected.isEmpty) {
      throw const AiFailure(AiError.rejected, '材料页还没有可用文字。');
    }
    final payload = <String, dynamic>{
      'model': model,
      'messages': [
        {'role': 'system', 'content': _systemPrompt},
        {
          'role': 'user',
          'content': jsonEncode({
            'task': 'extractKnowledge',
            'plan': {
              'id': plan.id,
              'title': plan.title,
              'subject': plan.subject,
              'goal': plan.goal,
              'examDate': plan.examDate?.iso,
            },
            'focus': trimmedFocus,
            'material_chunks': [
              for (var index = 0; index < selected.length; index++)
                {
                  'chunkId': 'c${index + 1}',
                  'documentTitle': selected[index].documentTitle,
                  'chapter': selected[index].chapter,
                  'purpose': selected[index].purpose.label,
                  'startPage': selected[index].startPage,
                  'endPage': selected[index].endPage,
                  'text': selected[index].text,
                },
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
    final pageCount = selected.fold<int>(
      0,
      (sum, chunk) => sum + (chunk.endPage - chunk.startPage + 1),
    );
    return PreparedKnowledgeRequest._(
      settings: settings,
      model: model,
      plan: plan,
      chunks: selected,
      focus: trimmedFocus,
      payloadJson: jsonEncode(payload),
      endpoint: settings.endpoint,
      requestId: List.generate(
        16,
        (_) => Random.secure().nextInt(256),
      ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
      previewSummary:
          '计划：${plan.title}\n'
          '模型：$model\n'
          '材料：${selected.map((chunk) => chunk.documentTitle).toSet().join('、')}'
          ' · ${selected.length} 个分块，覆盖 $pageCount 页\n'
          '重点：${trimmedFocus.isEmpty ? '按材料范围提取' : trimmedFocus}\n'
          '最多返回 $maxItems 个知识点；只发送已解析页面的文本。',
    );
  }

  Future<KnowledgeSendResult> send(PreparedKnowledgeRequest request) async {
    if (request._sent) {
      throw const AiFailure(AiError.alreadySent, '这次知识点请求已提交。');
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
      throw const AiFailure(AiError.truncated, '知识点结果因长度限制被截断，请减少材料范围后重试。');
    }
    final dynamic content = (choice['message'] as Map)['content'];
    if (content is! String || content.trim().isEmpty) {
      throw const AiFailure(AiError.invalidResponse, '模型返回了空结果。');
    }
    final dynamic decoded;
    try {
      decoded = jsonDecode(AiTransport.stripJsonFence(content));
    } catch (_) {
      throw const AiFailure(
        AiError.invalidResponse,
        '模型没有按约定返回知识点 JSON，请换用支持 JSON 的模型。',
      );
    }
    if (decoded is! Map) {
      throw const AiFailure(AiError.invalidResponse, '知识点结果不是 JSON 对象。');
    }
    final items = _parseItems(Map<String, dynamic>.from(decoded), request);
    return KnowledgeSendResult(
      items: items,
      model: request.model,
      requestId: request.requestId,
      usage: AiTransport.usageFromEnvelope(outer),
    );
  }

  List<KnowledgeItem> _parseItems(
    Map<String, dynamic> json,
    PreparedKnowledgeRequest request,
  ) {
    if (!const {'items'}.containsAll(json.keys)) {
      throw const AiFailure(AiError.invalidResponse, '知识点结果包含未允许的字段。');
    }
    final rawItems = json['items'];
    if (rawItems is! List || rawItems.isEmpty || rawItems.length > maxItems) {
      throw const AiFailure(AiError.invalidResponse, '知识点列表为空或超过 $maxItems 项。');
    }
    final chunkById = <String, MaterialChunk>{};
    for (var index = 0; index < request.chunks.length; index++) {
      chunkById['c${index + 1}'] = request.chunks[index];
    }
    final items = <KnowledgeItem>[];
    final ids = <String>[];
    for (var itemIndex = 0; itemIndex < rawItems.length; itemIndex++) {
      final value = rawItems[itemIndex];
      if (value is! Map) {
        throw const AiFailure(AiError.invalidResponse, '知识点条目格式不正确。');
      }
      final item = Map<String, dynamic>.from(value);
      const allowed = {
        'title',
        'objective',
        'sourceChunkId',
        'startPage',
        'endPage',
        'priority',
        'minutes',
        'activity',
        'completionCondition',
        'prerequisites',
      };
      if (!allowed.containsAll(item.keys)) {
        throw const AiFailure(AiError.invalidResponse, '知识点条目包含未允许的字段。');
      }
      final title = item['title'];
      final objective = item['objective'] as String? ?? '';
      final sourceChunkId = item['sourceChunkId'];
      if (title is! String ||
          title.trim().isEmpty ||
          title.trim().length > 120 ||
          objective.length > 500 ||
          sourceChunkId is! String) {
        throw const AiFailure(AiError.invalidResponse, '知识点缺少标题或来源。');
      }
      final chunk = chunkById[sourceChunkId];
      if (chunk == null) {
        throw const AiFailure(AiError.invalidResponse, '知识点引用了未提交的材料分块。');
      }
      final start = (item['startPage'] as num?)?.toInt() ?? chunk.startPage;
      final end = (item['endPage'] as num?)?.toInt() ?? chunk.endPage;
      if (start < chunk.startPage ||
          end > chunk.endPage ||
          end < start) {
        throw const AiFailure(AiError.invalidResponse, '知识点页码超出所引用的材料分块。');
      }
      final priority = (item['priority'] as num?)?.toInt() ?? 1;
      final minutes = (item['minutes'] as num?)?.toInt() ?? 45;
      if (priority < 0 || priority > 2 || minutes < 5 || minutes > 240) {
        throw const AiFailure(AiError.invalidResponse, '知识点优先级或用时不在允许范围。');
      }
      final activityName = item['activity'] as String? ?? 'learn';
      TaskActivity activity;
      try {
        activity = TaskActivity.values.byName(activityName);
      } catch (_) {
        throw const AiFailure(AiError.invalidResponse, '知识点活动类型未知。');
      }
      final completion = item['completionCondition'] as String? ?? '';
      if (completion.length > 300) {
        throw const AiFailure(AiError.invalidResponse, '知识点完成条件过长。');
      }
      final prerequisites = <int>[];
      final rawPrerequisites = item['prerequisites'];
      if (rawPrerequisites != null) {
        if (rawPrerequisites is! List || rawPrerequisites.length > 8) {
          throw const AiFailure(AiError.invalidResponse, '知识点前置关系格式不正确。');
        }
        for (final raw in rawPrerequisites) {
          final prerequisite = (raw as num?)?.toInt();
          if (prerequisite == null ||
              prerequisite < 0 ||
              prerequisite >= itemIndex) {
            throw const AiFailure(AiError.invalidResponse, '知识点前置关系必须引用更早的条目。');
          }
          prerequisites.add(prerequisite);
        }
      }
      final id = _uuid.v4();
      ids.add(id);
      items.add(
        KnowledgeItem(
          id: id,
          planId: request.plan.id,
          title: title.trim(),
          objective: objective.trim(),
          sourceId: chunk.sourceId,
          documentId: chunk.documentId,
          documentHash: chunk.documentHash,
          documentTitle: chunk.documentTitle,
          startPage: start,
          endPage: end,
          sourceExcerpt: chunk.text.trim().length <= 240
              ? chunk.text.trim()
              : '${chunk.text.trim().substring(0, 240)}…',
          prerequisiteIds: [
            for (final prerequisite in prerequisites) ids[prerequisite],
          ],
          priority: priority,
          minutes: minutes,
          activity: activity,
          completionCondition: completion.trim(),
          generatedByAi: true,
        ),
      );
    }
    return items;
  }

  static const String _systemPrompt =
      '你是课程知识点提取器。只读取 user JSON 中的 material_chunks，'
      '提取可以在给定时间内教完的知识点。返回严格 JSON：'
      '{"items":[{"title":"不超过120字","objective":"可观察的学习目标",'
      '"sourceChunkId":"c1","startPage":1,"endPage":2,'
      '"priority":0到2,"minutes":5到240,'
      '"activity":"learn|practice|review|quiz|correct|read|other",'
      '"completionCondition":"可验收的完成条件",'
      '"prerequisites":[只引用更早条目的整数下标]}]}。'
      '最多20项。禁止编造页码、章节、题目或材料中没有的事实；'
      '不能引用未提供的 chunkId；没有足够材料时返回 {"items":[]}。'
      '不要输出 Markdown 或解释文字。';
}
