import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../../services/ai_types.dart';
import '../material_work_models.dart';

enum PaperTranslationEngine {
  ai('已配置的 AI'),
  azure('Azure Translator'),
  google('Google Cloud Translation');

  const PaperTranslationEngine(this.label);
  final String label;
}

class TranslationProfile {
  const TranslationProfile(this.engine, {this.region = ''});
  final PaperTranslationEngine engine;
  final String region;

  static const languages = {
    '简体中文': ('zh-Hans', 'zh-CN'),
    '繁體中文': ('zh-Hant', 'zh-TW'),
    'English': ('en', 'en'),
    '日本語': ('ja', 'ja'),
    'Deutsch': ('de', 'de'),
    'Français': ('fr', 'fr'),
  };

  String get accountId => 'quelyt_paper_translation_${engine.name}';
  String get version =>
      '${engine.name}-${engine == PaperTranslationEngine.azure ? '3.0' : 'v2'}';

  Uri endpoint(String language) {
    final code = languages[language];
    if (code == null) throw const FormatException('不支持该目标语言。');
    return switch (engine) {
      PaperTranslationEngine.azure => Uri.https(
        'api.cognitive.microsofttranslator.com',
        '/translate',
        {'api-version': '3.0', 'to': code.$1},
      ),
      PaperTranslationEngine.google => Uri.https(
        'translation.googleapis.com',
        '/language/translate/v2',
      ),
      PaperTranslationEngine.ai => throw StateError('AI 翻译使用已配置模型。'),
    };
  }

  String body(String text, String language) => jsonEncode(
    engine == PaperTranslationEngine.azure
        ? [
            {'Text': text},
          ]
        : {'q': text, 'target': languages[language]!.$2, 'format': 'text'},
  );

  Future<void> saveKey(
    String key, {
    CredentialVault vault = const SystemCredentialVault(),
  }) async {
    if (key.trim().isEmpty) return;
    await vault.write(accountId, key.trim());
  }
}

class TranslationWire {
  const TranslationWire(this.profile, this.language);
  final TranslationProfile profile;
  final String language;

  Uri get endpoint => profile.endpoint(language);
  String get label => profile.engine.label;

  Future<(String, int?)> translate(
    String approvedBody, {
    CredentialVault vault = const SystemCredentialVault(),
    http.Client? httpClient,
  }) async {
    final key = await vault.read(profile.accountId);
    if (key == null || key.isEmpty) {
      throw AiFailure(AiError.missingKey, '请先给 $label 保存自己的 API Key。');
    }
    final client = httpClient ?? http.Client();
    final abort = Completer<void>();
    try {
      final azure = profile.engine == PaperTranslationEngine.azure;
      final request =
          http.AbortableRequest('POST', endpoint, abortTrigger: abort.future)
            ..followRedirects = false
            ..headers.addAll({
              'Content-Type': 'application/json; charset=UTF-8',
              (azure ? 'Ocp-Apim-Subscription-Key' : 'X-Goog-Api-Key'): key,
              if (azure && profile.region.isNotEmpty)
                'Ocp-Apim-Subscription-Region': profile.region,
            })
            ..body = approvedBody;
      final response = await (() async {
        final reply = await client.send(request);
        final buffer = BytesBuilder(copy: false);
        await for (final chunk in reply.stream) {
          if (buffer.length + chunk.length > 400000) {
            throw const AiFailure(AiError.invalidResponse, '翻译响应过长。');
          }
          buffer.add(chunk);
        }
        return http.Response.bytes(
          buffer.takeBytes(),
          reply.statusCode,
          headers: reply.headers,
        );
      })().timeout(const Duration(seconds: 40));
      if (response.statusCode != 200) {
        final status = response.statusCode;
        throw AiFailure(
          status == 429
              ? AiError.rateLimited
              : (status == 401 || status == 403)
              ? AiError.unauthorized
              : AiError.rejected,
          '$label 拒绝了请求（$status）。请核对密钥、启用状态或额度。',
          statusCode: status,
        );
      }
      final result = jsonDecode(utf8.decode(response.bodyBytes));
      final root = azure
          ? materialJson((result as List?)?.firstOrNull)
          : materialJson(materialJson(result)['data']);
      final entry = materialJson((root['translations'] as List?)?.firstOrNull);
      final text = entry[azure ? 'text' : 'translatedText'];
      if (text is! String || text.trim().isEmpty) {
        throw const FormatException('翻译结果为空。');
      }
      return (text, int.tryParse(response.headers['x-metered-usage'] ?? ''));
    } on TimeoutException {
      throw const AiFailure(AiError.timeout, '翻译请求超时，服务商受理状态未知。');
    } on http.ClientException {
      throw const AiFailure(AiError.network, '翻译连接中断，服务商受理状态未知。');
    } finally {
      if (!abort.isCompleted) abort.complete();
      if (httpClient == null) client.close();
    }
  }
}
