import 'dart:convert';

import 'ai_transport.dart';
import 'ai_types.dart';

enum WebSearchState { searched, empty, failed, notConfigured }

class WebSearchHit {
  const WebSearchHit({
    required this.title,
    required this.url,
    required this.snippet,
    required this.summary,
    required this.content,
    required this.query,
    this.siteName = '',
    this.publishedAt,
    this.authority = -1,
    this.rerankScore = 0,
  });

  final String title;
  final String url;
  final String snippet;
  final String summary;
  final String content;
  final String query;
  final String siteName;
  final String? publishedAt;
  final int authority;
  final double rerankScore;

  bool get hasContent => content.trim().isNotEmpty;
  bool get highQuality => rerankScore >= 1.5 || authority >= 3;

  String get displayTitle => title.trim().isEmpty ? host : title.trim();

  String get host => Uri.tryParse(url)?.host ?? '';
}

class WebSearchOutcome {
  const WebSearchOutcome({
    required this.state,
    this.hits = const [],
    this.note = '',
  });

  final WebSearchState state;
  final List<WebSearchHit> hits;
  final String note;

  bool get ok => state == WebSearchState.searched;
}

class WebFetchOutcome {
  const WebFetchOutcome({
    required this.ok,
    this.title = '',
    this.content = '',
    this.note = '',
  });

  final bool ok;
  final String title;
  final String content;
  final String note;
}

/// One provider-neutral search interface. A configured chat endpoint is not
/// evidence that the same provider offers a search API, so an unsupported
/// provider reports [WebSearchState.notConfigured] without any request.
abstract interface class WebSearchProvider {
  String get name;
  bool get isConfigured;
  Future<WebSearchOutcome> search(
    String query, {
    String? originalQuestion,
    int count = 5,
  });
  Future<WebFetchOutcome> fetch(String url);
}

/// Official DeepSeek Search/Fetch adapter.
///
/// The endpoints are fixed to `https://api.deepseek.com/v1/tools/...`; a custom
/// base URL is never extended with these paths, and a chat credential is only
/// used when the configured endpoint really belongs to `api.deepseek.com`.
class DeepSeekWebSearchProvider implements WebSearchProvider {
  DeepSeekWebSearchProvider(this.transport, this.settings);

  final AiTransport transport;
  final ProviderSettings settings;

  static final Uri searchEndpoint = Uri.parse(
    'https://api.deepseek.com/v1/tools/search',
  );
  static final Uri fetchEndpoint = Uri.parse(
    'https://api.deepseek.com/v1/tools/fetch',
  );
  static const int maxQueryCharacters = 128;
  static const int maxContentCharacters = 12000;
  static const int maxUrlCharacters = 8192;

  @override
  String get name => 'DeepSeek Search / Fetch';

  @override
  bool get isConfigured {
    final uri = Uri.tryParse(settings.baseUrl.trim());
    return uri != null && uri.host == 'api.deepseek.com';
  }

  static String _clip(String value, int limit) =>
      value.length <= limit ? value : '${value.substring(0, limit)}…';

  /// Counts Unicode code points, matching the API's character limit instead of
  /// UTF-16 code units.
  static String _clipQuery(String value) {
    final runes = value.trim().runes.toList();
    if (runes.length <= maxQueryCharacters) return value.trim();
    return String.fromCharCodes(runes.take(maxQueryCharacters));
  }

  @override
  Future<WebSearchOutcome> search(
    String query, {
    String? originalQuestion,
    int count = 5,
  }) async {
    if (!isConfigured) {
      return const WebSearchOutcome(
        state: WebSearchState.notConfigured,
        note: '只有 DeepSeek 官方接口支持本版联网搜索；当前服务商未配置。',
      );
    }
    final trimmed = _clipQuery(query);
    if (trimmed.isEmpty) {
      return const WebSearchOutcome(
        state: WebSearchState.failed,
        note: '搜索词为空。',
      );
    }
    final body = <String, dynamic>{
      'query': trimmed,
      'count': count.clamp(1, 50),
      'need_content': true,
    };
    final original = originalQuestion == null
        ? null
        : _clipQuery(originalQuestion);
    if (original != null && original.isNotEmpty) {
      body['ori_question'] = original;
    }
    try {
      final response = await transport.postJson(
        settings: settings,
        endpoint: searchEndpoint,
        payloadJson: jsonEncode(body),
      );
      final dynamic decoded;
      try {
        decoded = jsonDecode(response.body);
      } catch (_) {
        return const WebSearchOutcome(
          state: WebSearchState.failed,
          note: '搜索服务返回了无法解析的内容。',
        );
      }
      if (decoded is! Map || decoded['results'] is! List) {
        return const WebSearchOutcome(
          state: WebSearchState.failed,
          note: '搜索服务响应缺少结果列表。',
        );
      }
      final hits = <WebSearchHit>[];
      for (final dynamic item in decoded['results'] as List) {
        if (item is! Map) continue;
        final url = item['url'];
        if (url is! String || !_usableUrl(url)) continue;
        final authority = (item['authority'] as num?)?.toInt() ?? -1;
        hits.add(
          WebSearchHit(
            title: item['title'] is String ? item['title'] as String : '',
            url: url,
            snippet: item['snippet'] is String ? item['snippet'] as String : '',
            summary: item['summary'] is String ? item['summary'] as String : '',
            content: item['content'] is String
                ? _clip(item['content'] as String, maxContentCharacters)
                : '',
            query: trimmed,
            siteName: item['site_name'] is String
                ? item['site_name'] as String
                : '',
            publishedAt: item['date'] is String ? item['date'] as String : null,
            authority: authority.clamp(-1, 4),
            rerankScore: (item['rerank_score'] as num?)?.toDouble() ?? 0,
          ),
        );
      }
      if (hits.isEmpty) {
        return WebSearchOutcome(
          state: WebSearchState.empty,
          note: '“$trimmed”没有返回可用的搜索结果。',
        );
      }
      return WebSearchOutcome(state: WebSearchState.searched, hits: hits);
    } on AiFailure catch (error) {
      return WebSearchOutcome(
        state: WebSearchState.failed,
        note: _safeFailure(error),
      );
    } catch (_) {
      return const WebSearchOutcome(
        state: WebSearchState.failed,
        note: '联网搜索未完成，请检查网络和服务商设置。',
      );
    }
  }

  @override
  Future<WebFetchOutcome> fetch(String url) async {
    if (!isConfigured) {
      return const WebFetchOutcome(
        ok: false,
        note: '只有 DeepSeek 官方接口支持本版网页读取；当前服务商未配置。',
      );
    }
    if (!_usableUrl(url) || url.length > maxUrlCharacters) {
      return const WebFetchOutcome(ok: false, note: '这个页面地址无效，未发送请求。');
    }
    try {
      final response = await transport.postJson(
        settings: settings,
        endpoint: fetchEndpoint,
        payloadJson: jsonEncode({'url': url}),
      );
      final dynamic decoded;
      try {
        decoded = jsonDecode(response.body);
      } catch (_) {
        return const WebFetchOutcome(ok: false, note: '网页读取服务返回了无法解析的内容。');
      }
      if (decoded is! Map) {
        return const WebFetchOutcome(ok: false, note: '网页读取响应格式不正确。');
      }
      final content = decoded['content'] is String
          ? (decoded['content'] as String).trim()
          : '';
      if (content.isEmpty) {
        return const WebFetchOutcome(ok: false, note: '该网页没有可读取的正文。');
      }
      return WebFetchOutcome(
        ok: true,
        title: decoded['title'] is String ? decoded['title'] as String : '',
        content: _clip(content, maxContentCharacters),
      );
    } on AiFailure catch (error) {
      return WebFetchOutcome(ok: false, note: _safeFailure(error));
    } catch (_) {
      return const WebFetchOutcome(ok: false, note: '网页正文读取未完成。');
    }
  }

  static bool _usableUrl(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null || !uri.hasAuthority || uri.host.isEmpty) return false;
    if (uri.scheme != 'https' && uri.scheme != 'http') return false;
    if (uri.userInfo.isNotEmpty) return false;
    final host = uri.host.toLowerCase();
    if (host == 'localhost' || host == '::1' || host.endsWith('.local')) {
      return false;
    }
    final ipv4 = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$')
        .firstMatch(host);
    if (ipv4 != null) {
      final first = int.parse(ipv4.group(1)!);
      final second = int.parse(ipv4.group(2)!);
      if (first == 10 || first == 127 || (first == 169 && second == 254)) {
        return false;
      }
      if (first == 192 && second == 168) return false;
      if (first == 172 && second >= 16 && second <= 31) return false;
    }
    return true;
  }

  /// Provider failures are mapped to short, safe messages. The raw body may
  /// echo the URL or the user's query and is never displayed.
  static String _safeFailure(AiFailure error) => switch (error.code) {
    AiError.missingKey => '请先在设置中保存 DeepSeek API Key。',
    AiError.unauthorized => 'DeepSeek 认证失败，请检查 Key 和账号权限。',
    AiError.rateLimited => '搜索服务限流或余额不足，请稍后重试。',
    AiError.timeout => '搜索服务超时，本次不自动重试。',
    AiError.network => '无法连接搜索服务，请检查网络。',
    AiError.server => '搜索服务暂时不可用。',
    _ => '联网搜索未完成（${error.code.name}）。',
  };
}
