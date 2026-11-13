import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Settings contain no secret and can be persisted with the learning records.
class ProviderSettings {
  const ProviderSettings({
    required this.provider,
    required this.baseUrl,
    required this.model,
    this.visionModel = '',
  });

  factory ProviderSettings.deepSeek() => const ProviderSettings(
    provider: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com',
    model: 'deepseek-flash',
  );

  factory ProviderSettings.bailian() => const ProviderSettings(
    provider: '阿里云百炼',
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    model: 'qwen-plus',
    visionModel: 'qwen-vl-plus',
  );

  factory ProviderSettings.fromJson(Map<String, dynamic> value) {
    final baseUrl = value['baseUrl'] as String? ?? '';
    var model = value['model'] as String? ?? '';
    // Repair the model id written by the previous broken preset. Users can
    // still enter another supported model manually.
    if (baseUrl.contains('api.deepseek.com') && model == 'deepseek-chat') {
      model = 'deepseek-flash';
    }
    return ProviderSettings(
      provider: value['provider'] as String? ?? '自定义',
      baseUrl: baseUrl,
      model: model,
      visionModel: value['visionModel'] as String? ?? '',
    );
  }

  final String provider;
  final String baseUrl;
  final String model;
  final String visionModel;

  Map<String, dynamic> toJson() => {
    'provider': provider,
    'baseUrl': baseUrl,
    'model': model,
    'visionModel': visionModel,
  };

  /// Accept a base URL or a complete Chat Completions endpoint.
  Uri get endpoint {
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) {
      throw const AiFailure(AiError.invalidSettings, '请填写有效的接口地址。');
    }
    final isLoopback = const [
      'localhost',
      '127.0.0.1',
      '::1',
    ].contains(uri.host);
    if (uri.scheme != 'https' && !(uri.scheme == 'http' && isLoopback)) {
      throw const AiFailure(
        AiError.invalidSettings,
        '接口需要使用 HTTPS；本机 localhost 服务可以使用 HTTP。',
      );
    }
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      throw const AiFailure(AiError.invalidSettings, '接口地址不能包含用户名、密码、查询参数或片段。');
    }
    var path = uri.path.replaceFirst(RegExp(r'/+$'), '');
    if (!path.endsWith('/chat/completions')) path += '/chat/completions';
    return uri.replace(path: path);
  }

  /// Bind a key to the actual destination, so editing a provider name or URL
  /// cannot silently send an existing credential to a different service.
  String get credentialId =>
      'learning_api_${sha256.convert(utf8.encode('${provider.trim()}\n${endpoint.toString()}'))}';
}

abstract interface class CredentialVault {
  Future<String?> read(String accountId);
  Future<void> write(String accountId, String value);
  Future<void> delete(String accountId);
}

class SystemCredentialVault implements CredentialVault {
  const SystemCredentialVault({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String accountId) => _storage.read(key: accountId);
  @override
  Future<void> write(String accountId, String value) =>
      _storage.write(key: accountId, value: value);
  @override
  Future<void> delete(String accountId) => _storage.delete(key: accountId);
}

class TokenUsage {
  const TokenUsage({
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
  });
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;

  Map<String, dynamic> toJson() => {
    'promptTokens': promptTokens,
    'completionTokens': completionTokens,
    'totalTokens': totalTokens,
  };

  factory TokenUsage.fromJson(Map<String, dynamic> json) => TokenUsage(
    promptTokens: (json['promptTokens'] as num?)?.toInt() ?? 0,
    completionTokens: (json['completionTokens'] as num?)?.toInt() ?? 0,
    totalTokens: (json['totalTokens'] as num?)?.toInt() ?? 0,
  );
}

enum AiError {
  invalidSettings,
  missingKey,
  credentialStorage,
  contextTooLarge,
  invalidImage,
  imageApprovalRequired,
  alreadySent,
  unauthorized,
  rateLimited,
  timeout,
  network,
  server,
  rejected,
  invalidResponse,
  truncated,
  cancelled,
}

class AiFailure implements Exception {
  const AiFailure(this.code, this.message, {this.statusCode});
  final AiError code;
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}
