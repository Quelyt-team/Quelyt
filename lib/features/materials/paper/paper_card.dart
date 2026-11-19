import 'package:flutter/material.dart';

import '../../../core/models.dart';
import '../material_work.dart';
import 'paper_metadata.dart';

class PaperCard extends StatefulWidget {
  const PaperCard({super.key, required this.document, required this.work});

  final DocumentRecord document;
  final MaterialWork work;

  @override
  State<PaperCard> createState() => _PaperCardState();
}

class _PaperCardState extends State<PaperCard> {
  late final service = PaperMetadataService(widget.work);
  static const labels = {
    'title': '题名',
    'authors': '作者',
    'doi': 'DOI',
    'venue': '期刊或会议',
    'publisher': '出版机构',
    'year': '出版年',
    'publishedOnline': '在线发表',
    'publishedPrint': '卷期出版',
    'volume': '卷',
    'issue': '期',
    'pages': '页码',
    'issn': 'ISSN',
    'type': '版本类型',
  };
  static const metricLabels = {
    'year': '指标年份',
    'issn': '期刊 ISSN 或 eISSN',
    'jif': '影响因子（JIF）',
    'jcr': 'JCR 学科与分区',
    'scie': 'SCIE 收录年份或查询日期',
    'cas': '中科院历史分区与学科',
    'source': '授权来源',
  };
  PaperMetadata? _local;
  PaperMetadata? _remote;
  bool _querying = false;
  String? _status;

  Map<String, String> get _fields => {
    ...?_local?.fields,
    for (final pair
        in _remote?.fields.entries ?? const <MapEntry<String, String>>[])
      if (pair.value.isNotEmpty) pair.key: pair.value,
    ...service.edits(widget.document),
  };

  @override
  void initState() {
    super.initState();
    _remote = service.read(widget.document);
    _load();
  }

  Future<void> _load() async {
    final local = await service.extract(widget.document);
    if (!mounted) return;
    setState(() => _local = local);
  }

  Future<void> _lookup() async {
    if (_querying) return;
    final fields = {..._fields};
    final uri = service.lookupUri(fields);
    final query = uri.queryParameters;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('到 Crossref 核对书目'),
        content: SelectableText(
          uri.hasQuery
              ? '题名 ${query['query.title']}\n${query['query.author'] == null ? '' : '首位作者 ${query['query.author']}\n'}\napi.crossref.org'
              : 'DOI ${fields['doi']}\n\napi.crossref.org',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('查询'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    setState(() {
      _querying = true;
      _status = null;
    });
    try {
      final candidates = await service.lookup(uri, fields);
      if (!mounted) return;
      final compatible = candidates
          .where((candidate) => service.match(fields, candidate) >= .54)
          .toList();
      if (compatible.isEmpty) {
        setState(() => _status = '返回书目与原文题名、作者或 DOI 不一致，请核对本地字段。');
        return;
      }
      final accurate = compatible
          .where((candidate) => service.match(fields, candidate) >= .92)
          .toList();
      final selected = accurate.length == 1 && compatible.length == 1
          ? accurate.single
          : await _choose(compatible);
      if (selected == null || !mounted) return;
      final record = PaperMetadata(
        fields: selected.fields,
        origin: selected.origin,
        fetchedAt: selected.fetchedAt,
        metricYears: _remote?.metricYears ?? const [],
      );
      service.save(widget.document, record);
      setState(() => _remote = record);
    } catch (error) {
      if (mounted) setState(() => _status = '$error');
    } finally {
      if (mounted) setState(() => _querying = false);
    }
  }

  Future<PaperMetadata?> _choose(List<PaperMetadata> choices) =>
      showDialog<PaperMetadata>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('选择与这份原文相符的书目'),
          content: SizedBox(
            width: 520,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final item in choices)
                  ListTile(
                    title: Text(item['title']),
                    subtitle: Text(
                      [
                        item['authors'],
                        item['venue'],
                        item['year'],
                        item['type'],
                        item['doi'],
                      ].join(' · '),
                    ),
                    onTap: () => Navigator.pop(context, item),
                  ),
              ],
            ),
          ),
        ),
      );

  Future<void> _edit({required bool metrics}) async {
    final keys = metrics ? metricLabels : labels;
    final before = metrics
        ? Map<String, String>.from(
            widget.work.readState(widget.document, 'paperMetrics') as Map? ??
                {},
          )
        : _fields;
    final values = {...before};
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(metrics ? '录入有来源的期刊指标' : '修订书目'),
        content: SizedBox(
          width: 500,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final key in keys.entries)
                TextFormField(
                  initialValue: values[key.key] ?? '',
                  decoration: InputDecoration(labelText: key.value),
                  onChanged: (value) => values[key.key] = value.trim(),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved != true || !mounted) return;
    if (metrics) {
      if (!(values['source']?.isNotEmpty ?? false) ||
          !RegExp(r'^(?:19|20)\d\d$').hasMatch(values['year'] ?? '')) {
        setState(() => _status = '请注明指标年份和数据来源。');
        return;
      }
      widget.work.saveState(widget.document, 'paperMetrics', values);
    } else {
      service.edit(widget.document, {
        ...service.edits(widget.document),
        for (final key in keys.keys)
          if (before[key] != values[key]) key: values[key] ?? '',
      });
    }
    setState(() => _status = null);
  }

  @override
  Widget build(BuildContext context) {
    final fields = _fields;
    final edits = service.edits(widget.document);
    final metrics = Map<String, String>.from(
      widget.work.readState(widget.document, 'paperMetrics') as Map? ?? {},
    );
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 14),
      children: [
        for (final field in labels.entries)
          if (const {
                'title',
                'authors',
                'doi',
                'venue',
                'year',
              }.contains(field.key) ||
              fields[field.key]?.isNotEmpty == true)
            ListTile(
              dense: true,
              title: Text(field.value),
              subtitle: SelectableText(
                fields[field.key]?.isNotEmpty == true
                    ? fields[field.key]!
                    : '待补全',
              ),
              trailing: Text(
                edits.containsKey(field.key)
                    ? '手工修订'
                    : (_remote?[field.key].isNotEmpty ?? false)
                    ? 'Crossref'
                    : '本机',
              ),
            ),
        if (_remote?.fetchedAt case final date?)
          Text('查询于 ${date.toLocal().toString().split(' ').first}'),
        if (_status != null) Text(_status!),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: widget.work.store.getSetting('paperLookupOnImport') == 'true',
        title: const Text('导入论文时查询书目信息'),
        subtitle: const Text('向 Crossref 提交 DOI，或题名及首位作者。'),
        onChanged: (value) {
          widget.work.store.setSetting('paperLookupOnImport', value.toString());
          setState(() {});
        },
      ),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton(
              onPressed: () => _edit(metrics: false),
              child: const Text('修订书目'),
            ),
            FilledButton.tonal(
              onPressed: _querying || _local == null ? null : _lookup,
              child: Text(_querying ? '正在查询' : '查询 Crossref'),
            ),
          ],
        ),
        const Divider(),
        Text('期刊指标', style: Theme.of(context).textTheme.titleSmall),
        if (metrics.isEmpty) const Text('未连接指标来源'),
        for (final entry in metricLabels.entries)
          if (metrics[entry.key]?.isNotEmpty == true)
            ListTile(
              dense: true,
              title: Text(entry.value),
              subtitle: Text(metrics[entry.key]!),
            ),
        if (metrics['year'] != null &&
            fields['year'] != null &&
            metrics['year'] != fields['year'])
          Text('指标年 ${metrics['year']}，论文发表年 ${fields['year']}'),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => _edit(metrics: true),
            child: const Text('录入授权数据'),
          ),
        ),
      ],
    );
  }
}
