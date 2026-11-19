import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../../../core/models.dart';
import '../material_work.dart';

class PaperMetadata {
  const PaperMetadata({
    required this.fields,
    this.origin = '本机首页',
    this.fetchedAt,
    this.metricYears = const [],
  });

  final Map<String, String> fields;
  final String origin;
  final DateTime? fetchedAt;
  final List<Map<String, dynamic>> metricYears;

  String operator [](String key) => fields[key] ?? '';

  Map<String, dynamic> toJson() => {
    'fields': fields,
    'origin': origin,
    'fetchedAt': fetchedAt?.toIso8601String(),
    'metricYears': metricYears,
  };

  factory PaperMetadata.fromJson(Map<String, dynamic> row) => PaperMetadata(
    fields: Map<String, String>.from(row['fields'] as Map? ?? {}),
    origin: row['origin'] as String? ?? '本机首页',
    fetchedAt: DateTime.tryParse(row['fetchedAt'] as String? ?? ''),
    metricYears: [
      for (final value in row['metricYears'] as List? ?? [])
        materialJson(value),
    ],
  );
}

class PaperMetadataService {
  PaperMetadataService(this.work);
  final MaterialWork work;
  static final _doi = RegExp(
    r'\b10\.\d{4,9}/[^\s<>"\]]+',
    caseSensitive: false,
  );
  static final _boundary = RegExp(
    r'^\s*(?:references|bibliography|参考文献)\s*[:：]?\s*$',
    caseSensitive: false,
    multiLine: true,
  );

  PaperMetadata? read(DocumentRecord doc) {
    final value = work.readState(doc, 'paperMetadata');
    return value is Map ? PaperMetadata.fromJson(materialJson(value)) : null;
  }

  Map<String, String> edits(DocumentRecord doc) => Map<String, String>.from(
    work.readState(doc, 'paperFieldEdits') as Map? ?? {},
  );

  void save(DocumentRecord doc, PaperMetadata metadata) =>
      work.saveState(doc, 'paperMetadata', metadata.toJson());

  void edit(DocumentRecord doc, Map<String, String> fields) =>
      work.saveState(doc, 'paperFieldEdits', fields);

  Future<PaperMetadata> extract(DocumentRecord doc) async {
    final text = work.store.getPage(doc.id, 1)?.text ?? '';
    final front = text.split(_boundary).first;
    final lines = front
        .split('\n')
        .map((v) => v.trim())
        .where((v) => v.length >= 9 && v.length < 300)
        .take(12)
        .toList();
    final xml = await _xmp(doc);
    final field = <String, String>{...xml};
    if ((field['title'] ?? '').isEmpty) {
      field['title'] = lines.firstWhere(
        (line) =>
            line.length >= 22 &&
            !RegExp(
              r'^(https?://|abstract\b|doi\b|issn|arxiv|copyright|vol\.|accepted\b)',
              caseSensitive: false,
            ).hasMatch(line),
        orElse: () => doc.title,
      );
    }
    final header = front
        .split(RegExp(r'\babstract\b|摘\s*要', caseSensitive: false))
        .first;
    final candidate = _doi.firstMatch(header);
    if ((field['doi'] ?? '').isEmpty && candidate != null) {
      field['doi'] = candidate[0]!.replaceFirst(RegExp(r'[.,;:)。]+$'), '');
    }
    final year = RegExp(
      r'(?:published|copyright|©|出版)\D{0,22}((?:19|20)\d\d)',
      caseSensitive: false,
    ).firstMatch(header)?[1];
    if (year != null) field.putIfAbsent('year', () => year);
    return PaperMetadata(
      fields: field,
      origin: xml.isEmpty ? '本机首页' : '本机 PDF 元数据与首页',
    );
  }

  Future<Map<String, String>> _xmp(DocumentRecord doc) async {
    if (doc.materialFormat != MaterialFormat.pdf) return {};
    final file = File(doc.filePath);
    if (!await file.exists()) return {};
    final stream = await file.open();
    try {
      final bytes = await stream.read(768 * 1024);
      final body = utf8.decode(bytes, allowMalformed: true);
      final from = body.indexOf('<x:xmpmeta');
      final end = body.indexOf('</x:xmpmeta>', from < 0 ? 0 : from);
      if (from < 0 || end < from) return {};
      final xmp = XmlDocument.parse(
        body.substring(from, end + '</x:xmpmeta>'.length),
      );
      String first(String part) =>
          xmp
              .findAllElements(part, namespaceUri: '*')
              .firstOrNull
              ?.innerText
              .trim() ??
          '';
      final creator = xmp
          .findAllElements('creator', namespaceUri: '*')
          .firstOrNull;
      final authors = creator
          ?.findAllElements('li', namespaceUri: '*')
          .map((node) => node.innerText.trim())
          .where((value) => value.isNotEmpty)
          .join('、');
      final title = first('title');
      final doi = _doi.firstMatch(first('doi'))?[0];
      return {
        if (title.isNotEmpty) 'title': title,
        if (authors?.isNotEmpty == true) 'authors': authors!,
        'doi': ?doi,
      };
    } catch (_) {
      return {};
    } finally {
      await stream.close();
    }
  }

  Uri lookupUri(Map<String, String> local) {
    final doi = local['doi']?.trim() ?? '';
    if (_doi.stringMatch(doi) == doi && doi.length <= 220) {
      return Uri(
        scheme: 'https',
        host: 'api.crossref.org',
        pathSegments: ['works', doi],
      );
    }
    final title = local['title']?.trim() ?? '';
    if (title.isEmpty) throw StateError('请输入论文题名或 DOI。');
    final firstAuthor = (local['authors'] ?? '')
        .split(RegExp('[、,;；]'))
        .first
        .trim();
    return Uri.https('api.crossref.org', '/works', {
      'query.title': title,
      if (firstAuthor.isNotEmpty) 'query.author': firstAuthor,
      'rows': '5',
    });
  }

  Future<List<PaperMetadata>> lookup(
    Uri destination,
    Map<String, String> local,
  ) async {
    if (destination != lookupUri(local)) throw StateError('请重新确认文献查询范围。');
    final client = http.Client();
    try {
      final reply = await client
          .send(http.Request('GET', destination)..followRedirects = false)
          .timeout(const Duration(seconds: 15));
      if (reply.statusCode != 200) {
        throw StateError('Crossref 查询未完成（${reply.statusCode}）。');
      }
      final buffer = BytesBuilder(copy: false);
      await for (final bytes in reply.stream.timeout(
        const Duration(seconds: 15),
      )) {
        buffer.add(bytes);
        if (buffer.length > 1_000_000) throw const FormatException('书目返回过长。');
      }
      final message = materialJson(
        jsonDecode(utf8.decode(buffer.takeBytes())),
      )['message'];
      final values = message is Map && message['items'] is List
          ? message['items'] as List
          : [message];
      final candidates = values
          .take(5)
          .map((item) => _crossref(materialJson(item)))
          .where((item) => item['title'].isNotEmpty && item['doi'].isNotEmpty)
          .toList();
      candidates.sort((a, b) => match(local, b).compareTo(match(local, a)));
      return candidates;
    } finally {
      client.close();
    }
  }

  double match(Map<String, String> local, PaperMetadata candidate) {
    String norm(String value) =>
        value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\u3400-\u9fff]'), '');
    Set<String> shingles(String value) {
      final normalized = norm(value);
      return {
        for (var i = 0; i + 1 < normalized.length; i++)
          normalized.substring(i, i + 2),
      };
    }

    final a = shingles(local['title'] ?? '');
    final b = shingles(candidate['title']);
    if (a.isEmpty || b.isEmpty) return 0;
    final score = 2 * a.intersection(b).length / (a.length + b.length);
    final doi = (local['doi'] ?? '').trim().toLowerCase();
    if (doi.isNotEmpty && doi != candidate['doi'].toLowerCase()) return 0;
    final year = local['year'] ?? '';
    if (year.isNotEmpty &&
        candidate['year'].isNotEmpty &&
        year != candidate['year']) {
      return score * .62;
    }
    final author = norm((local['authors'] ?? '').split('、').first);
    if (author.isNotEmpty && !norm(candidate['authors']).contains(author)) {
      return score * .65;
    }
    return score.toDouble();
  }

  PaperMetadata _crossref(Map<String, dynamic> row) {
    String first(String key) =>
        (row[key] as List?)?.firstOrNull?.toString() ?? '';
    String date(String key) {
      final parts = materialJson(row[key])['date-parts'] as List?;
      return (parts?.firstOrNull as List?)?.join('-') ?? '';
    }

    final authors = [
      for (final raw in row['author'] as List? ?? [])
        for (final item in [materialJson(raw)])
          [
            item['given'],
            item['family'],
            item['name'],
          ].whereType<String>().join(' '),
    ];
    final issued = date('issued');
    return PaperMetadata(
      origin: 'Crossref',
      fetchedAt: DateTime.now(),
      fields: {
        'title': first('title'),
        'authors': authors.join('、'),
        'doi': row['DOI']?.toString() ?? '',
        'venue': first('container-title'),
        'publisher': row['publisher']?.toString() ?? '',
        'year': issued.split('-').first,
        'publishedOnline': date('published-online'),
        'publishedPrint': date('published-print'),
        'volume': row['volume']?.toString() ?? '',
        'issue': row['issue']?.toString() ?? '',
        'pages': row['page']?.toString() ?? '',
        'issn': (row['ISSN'] as List?)?.join('、') ?? '',
        'type': row['type']?.toString() ?? '',
      },
    );
  }
}
