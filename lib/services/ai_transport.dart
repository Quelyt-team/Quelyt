import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'ai_types.dart';

class AiHttpResult {
  const AiHttpResult({required this.body, required this.statusCode});
  final String body;
  final int statusCode;
}

/// The one place that reads a credential and performs an HTTP request.
///
/// Every feature shares this transport: redirects are disabled, responses are
/// bounded, errors are mapped to safe messages and nothing is retried
/// automatically because each attempt may be billable.
class AiTransport {
  AiTransport({
    http.Client? client,
    CredentialVault? vault,
    this.timeout = const Duration(seconds: 90),
  }) : _client = client ?? http.Client(),
       _vault = vault ?? const SystemCredentialVault();

  final http.Client _client;
  final CredentialVault _vault;
  final Duration timeout;
  static const int maxResponseBytes = 2 * 1024 * 1024;

  Future<String?> readKey(ProviderSettings settings) async {
    final accountId = settings.credentialId;
    try {
      final value = await _vault.read(accountId);
      return value == null ? null : _normalizeKey(value);
    } catch (_) {
      throw const AiFailure(
        AiError.credentialStorage,
        '无法读取系统凭据存储，请重新保存 API Key。',
      );
    }
  }

  static String _normalizeKey(String input) {
    var value = input.trim();
    value = value
        .replaceFirst(RegExp(r'^Bearer\s+', caseSensitive: false), '')
        .trim();
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1).trim();
    }
    value = value
        .replaceFirst(RegExp(r'^Bearer\s+', caseSensitive: false), '')
        .trim();
    // API keys never contain whitespace. Removing it here repairs keys pasted
    // with line wraps, non-breaking spaces or zero-width characters.
    return value.replaceAll(
      RegExp(r'[\s\u00A0\u200B\u200C\u200D\uFEFF]+'),
      '',
    );
  }

  Future<void> saveKey(ProviderSettings settings, String key) async {
    final accountId = settings.credentialId;
    final normalized = _normalizeKey(key);
    if (normalized.isEmpty || normalized.contains('\n') || normalized.contains('\r')) {
      throw const AiFailure(AiError.missingKey, '请填写有效的 API Key。');
    }
    try {
      await _vault.write(accountId, normalized);
    } catch (_) {
      throw const AiFailure(
        AiError.credentialStorage,
        '无法写入系统凭据存储，API Key 尚未保存。',
      );
    }
  }

  Future<void> deleteKey(ProviderSettings settings) async {
    final accountId = settings.credentialId;
    try {
      await _vault.delete(accountId);
    } catch (_) {
      throw const AiFailure(AiError.credentialStorage, '无法删除系统凭据，请稍后重试。');
    }
  }

  /// Sends the exact reviewed payload and returns its body.
  ///
  /// No status-code interpretation is specific to one task; callers parse the
  /// body with their own contract after this method succeeds.
  Future<AiHttpResult> postJson({
    required ProviderSettings settings,
    required Uri endpoint,
    required String payloadJson,
  }) async {
    final key = await readKey(settings);
    if (key == null || key.trim().isEmpty) {
      throw const AiFailure(AiError.missingKey, '请先在设置中保存此服务商的 API Key。');
    }
    final abort = Completer<void>();
    try {
      // Explicit Request disables redirects. A server redirect must not move
      // a user's source text, image or Authorization header to a new host.
      final outgoing =
          http.AbortableRequest(
              'POST',
              endpoint,
              abortTrigger: abort.future,
            )
            ..followRedirects = false
            ..headers.addAll({
              'Authorization': 'Bearer $key',
              'Content-Type': 'application/json; charset=utf-8',
            })
            ..body = payloadJson;
      final response = await (() async {
        final streamed = await _client.send(outgoing);
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in streamed.stream) {
          if (bytes.length + chunk.length > maxResponseBytes) {
            if (!abort.isCompleted) abort.complete();
            throw const AiFailure(
              AiError.invalidResponse,
              '服务商返回内容过长，请缩小问题范围。',
            );
          }
          bytes.add(chunk);
        }
        return http.Response.bytes(bytes.takeBytes(), streamed.statusCode);
      })().timeout(
        timeout,
        onTimeout: () {
          if (!abort.isCompleted) abort.complete();
          throw TimeoutException('AI request timeout');
        },
      );
      if (response.statusCode != 200) {
        final body = utf8.decode(response.bodyBytes);
        throw httpFailure(
          response.statusCode,
          model: settings.model,
          detail: _providerError(body),
        );
      }
      return AiHttpResult(
        body: utf8.decode(response.bodyBytes),
        statusCode: response.statusCode,
      );
    } on AiFailure {
      rethrow;
    } on TimeoutException {
      throw const AiFailure(AiError.timeout, '请求超时。请检查网络后重新预览并发送；本次不自动重试。');
    } on http.ClientException {
      throw const AiFailure(AiError.network, '无法连接服务商。已保存的阅读、笔记和复习仍可离线使用。');
    } on FormatException {
      throw const AiFailure(AiError.invalidResponse, '服务商返回了无法核对的内容，请调整模型或重试。');
    } catch (_) {
      // Do not surface raw provider bodies or transport exception strings:
      // they may echo source material, user answers or credentials.
      throw const AiFailure(AiError.network, '请求未完成，请检查网络和服务商设置。');
    }
  }

  void close() => _client.close();

  /// Sends one minimal chat request to verify the key, endpoint and model.
  /// This is intentionally explicit in the UI because it may be billable.
  Future<String> testConnection(ProviderSettings settings) async {
    final model = settings.model.trim();
    if (model.isEmpty) {
      throw const AiFailure(AiError.invalidSettings, '请先填写文本模型名称。');
    }
    final key = await readKey(settings);
    final keyHint = key == null || key.isEmpty
        ? 'Key：未读取到'
        : 'Key 长度 ${key.length}，尾号 ${key.length <= 4 ? key : key.substring(key.length - 4)}';
    final targetHint =
        '地址 ${settings.endpoint}；模型 $model；$keyHint';
    final payload = jsonEncode({
      'model': model,
      'messages': [
        {'role': 'user', 'content': 'Reply with OK.'},
      ],
      'max_tokens': 8,
      'stream': false,
    });
    try {
      await postJson(
        settings: settings,
        endpoint: settings.endpoint,
        payloadJson: payload,
      );
      return '连接成功。$targetHint';
    } on AiFailure catch (error) {
      if (error.code != AiError.unauthorized &&
          error.code != AiError.rejected) {
        throw AiFailure(
          error.code,
          '${error.message}（$targetHint）',
          statusCode: error.statusCode,
        );
      }
      final models = await _availableModels(settings);
      if (models != null && models.isNotEmpty && !models.contains(model)) {
        throw AiFailure(
          error.code,
          '${error.message} 该 Key 可读取的模型：${models.take(8).join('、')}；'
          '当前模型 $model 不在列表中。（$targetHint）',
          statusCode: error.statusCode,
        );
      }
      throw AiFailure(
        error.code,
        '${error.message}（$targetHint）',
        statusCode: error.statusCode,
      );
    }
  }

  Future<List<String>?> _availableModels(ProviderSettings settings) async {
    try {
      final key = await readKey(settings);
      if (key == null || key.isEmpty) return null;
      final chat = settings.endpoint;
      final path = chat.path.endsWith('/chat/completions')
          ? '${chat.path.substring(0, chat.path.length - '/chat/completions'.length)}/models'
          : '/models';
      final request = http.Request('GET', chat.replace(path: path))
        ..headers['Authorization'] = 'Bearer $key';
      final streamed = await _client.send(request).timeout(
        const Duration(seconds: 20),
      );
      final body = await streamed.stream.bytesToString();
      if (streamed.statusCode != 200) return null;
      final decoded = jsonDecode(body);
      if (decoded is! Map || decoded['data'] is! List) return null;
      return [
        for (final item in decoded['data'] as List)
          if (item is Map && item['id'] is String) item['id'] as String,
      ];
    } catch (_) {
      return null;
    }
  }

  static TokenUsage? readUsage(dynamic rawUsage) {
    if (rawUsage is! Map) return null;
    int readCount(String name) {
      final dynamic count = rawUsage[name];
      return count is num && count >= 0 ? count.toInt() : 0;
    }

    return TokenUsage(
      promptTokens: readCount('prompt_tokens'),
      completionTokens: readCount('completion_tokens'),
      totalTokens: readCount('total_tokens'),
    );
  }

  static String? _providerError(String body) {
    dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final error = decoded['error'];
    final message = error is Map
        ? error['message']
        : decoded['message'];
    if (message is! String) return null;
    var value = message
        .replaceAll(RegExp(r'sk-[A-Za-z0-9_\-]+'), '[redacted]')
        .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
        .trim();
    if (value.length > 240) value = '${value.substring(0, 240)}…';
    return value;
  }

  static AiFailure httpFailure(int status, {String model = '', String? detail}) {
    final modelHint = model.trim().isEmpty ? '' : '，模型：${model.trim()}';
    final extra = detail == null || detail.trim().isEmpty
        ? ''
        : ' 服务商说明：${detail.trim()}';
    if (status == 401 || status == 403) {
      return AiFailure(
        AiError.unauthorized,
        '认证失败（HTTP $status$modelHint）。请核对：① Key 是否属于当前服务商；'
        '② 文本模型名称是否可用；③ 账号是否有该模型权限。$extra',
        statusCode: status,
      );
    }
    if (status == 429) {
      return AiFailure(
        AiError.rateLimited,
        '服务商限流或余额不足，请稍后检查账号后重试。',
        statusCode: status,
      );
    }
    if (status >= 500) {
      return AiFailure(AiError.server, '服务商暂时不可用，请稍后重试。', statusCode: status);
    }
    if (status >= 300 && status < 400) {
      return AiFailure(
        AiError.rejected,
        '服务商要求重定向，请核对接口地址后重新预览发送。',
        statusCode: status,
      );
    }
    return AiFailure(
      AiError.rejected,
      '服务商拒绝了请求（HTTP $status$modelHint），请核对模型名称、接口地址和图片支持情况。$extra',
      statusCode: status,
    );
  }

  /// A shared helper for callers that need a JSON object from a model reply.
  static String stripJsonFence(String content) => content
      .trim()
      .replaceFirst(RegExp(r'^```(?:json)?\s*', caseSensitive: false), '')
      .replaceFirst(RegExp(r'\s*```$'), '');

  /// Usage is exposed separately from the answer contract so every feature
  /// records the same provider report.
  static TokenUsage? usageFromEnvelope(dynamic outer) =>
      outer is Map ? readUsage(outer['usage']) : null;
}
