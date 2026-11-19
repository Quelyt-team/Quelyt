import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart' hide PdfDocument;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';

import '../../../core/models.dart';
import '../../../services/document_service.dart';
import '../../library/data/library_repository.dart';
import '../material_work.dart';
import 'formula_engine.dart';
import 'science_markup.dart';

class SolutionPdf {
  SolutionPdf(this.documents) : library = LibraryRepository(documents.store);

  final DocumentService documents;
  final LibraryRepository library;
  static final _writes = <String>{};

  Future<DocumentRecord> save(
    DocumentRecord source,
    List<MaterialResult> answers, {
    String? entryId,
    required bool partial,
  }) async {
    final ready = answers
        .where((answer) => answer.hasResult && answer.text.isNotEmpty)
        .toList();
    if (ready.isEmpty) throw StateError('没有可导出的解答。');
    final key = materialDigest([
      source.id,
      source.contentHash,
      entryId,
      partial,
      ...ready.map((answer) => [answer.key, answer.text]),
    ]);
    final store = documents.store;
    final existing = store.selectRows(
      'SELECT document_id FROM material_outputs WHERE output_key=?',
      [key],
    );
    if (existing.isNotEmpty) {
      final document = store.getDocument(
        existing.single['document_id'] as String,
      );
      if (document?.isActive == true &&
          await File(document!.filePath).exists()) {
        return document;
      }
      throw StateError('解答已保存。请先恢复资料库中的文件或原件。');
    }
    if (!_writes.add(key)) throw StateError('正在生成这份解答。');
    Directory? temp;
    try {
      temp = await documents.directory.createTemp('solution-');
      final title = '${source.title}－${partial ? '部分解答' : '解答'}';
      final file = File(p.join(temp.path, '解答.pdf'));
      OpenDocument? opened;
      final crops = <String, Uint8List>{};
      try {
        for (final result in ready) {
          final anchor = result.sources.firstOrNull;
          if (anchor == null ||
              anchor.region == SourceRegion.fullPage ||
              anchor.timeMs != null) {
            continue;
          }
          opened ??= await documents.open(source);
          final original = await opened.render(anchor.page, maxSide: 1500);
          crops[result.key] = await cropPage(original, anchor.region);
        }
      } finally {
        await opened?.dispose();
      }
      await file.writeAsBytes(
        await render(title, ready, crops: crops),
        flush: true,
      );
      final pdf = await PdfDocument.openFile(file.path);
      try {
        if (pdf.pages.isEmpty) throw const FormatException('解答 PDF 没有可读页面。');
        final text = StringBuffer();
        for (final page in pdf.pages) {
          text.write((await page.loadText())?.fullText ?? '');
        }
        final normalized = text.toString().replaceAll(RegExp(r'\s+'), '');
        for (var i = 0; i < ready.length; i++) {
          if (!normalized.contains(
            _label(ready[i], i).replaceAll(RegExp(r'\s+'), ''),
          )) {
            throw const FormatException('PDF 复核未找到完整题号。');
          }
        }
      } finally {
        await pdf.dispose();
      }
      final staged = await documents.stageFile(file.path);
      final result = await documents.commitStaged(
        staged,
        title: title,
        kind: DocumentKind.exercise,
        register: (commit) {
          final current = store.getDocument(source.id);
          if (current?.isActive != true ||
              current!.contentHash != source.contentHash ||
              current.lifecycleVersion != source.lifecycleVersion) {
            throw StateError('源资料已移除或版本发生变化。');
          }
          if (!commit.record.isActive) throw StateError('同一解答已在回收站。');
          final entry = entryId == null
              ? library.primaryEntry(source.id)
              : library.entryById(entryId, includeDeleted: false);
          final folder = entry?.folderId;
          if (entryId != null && entry?.documentId != source.id) {
            throw StateError('发起任务的资料入口已移动或移除，请重新打开。');
          }
          final primary = library.primaryEntry(commit.record.id);
          if (!commit.duplicate &&
              primary != null &&
              primary.folderId != folder) {
            library.updateEntry(
              primary.copyWith(
                folderId: folder,
                clearFolder: folder == null,
                sortKey: library.nextEntrySortKey(folder),
              ),
            );
          } else if (library.entryInFolder(folder, commit.record.id) == null) {
            library.insertEntry(
              documentId: commit.record.id,
              folderId: folder,
              isShortcut: primary != null,
            );
          }
          store.executeSql(
            'INSERT INTO material_outputs VALUES (?,?,?,?,?,?)',
            [
              key,
              source.id,
              entry?.id,
              commit.record.id,
              'exercise',
              DateTime.now().millisecondsSinceEpoch,
            ],
          );
        },
      );
      return result.record;
    } finally {
      _writes.remove(key);
      if (temp != null && await temp.exists()) {
        await temp.delete(recursive: true);
      }
    }
  }

  static String _label(MaterialResult answer, int index) {
    final number = answer.data['number']?.toString().trim() ?? '';
    return number.isEmpty ? '框选题 ${index + 1}' : '第 $number 题';
  }

  static Future<Uint8List> render(
    String title,
    List<MaterialResult> answers, {
    Map<String, Uint8List> crops = const {},
  }) async {
    final cjk = pw.Font.ttf(
      await rootBundle.load('assets/science/NotoSansSC-Regular.ttf'),
    );
    final theme = pw.ThemeData.withFont(base: cjk, bold: cjk);
    final doc = pw.Document(theme: theme, title: title, creator: 'Quelyt');
    final body = <pw.Widget>[];
    for (var index = 0; index < answers.length; index++) {
      final answer = answers[index];
      final pages = answer.sources.map((source) => source.page).toSet().toList()
        ..sort();
      body.add(
        pw.Container(
          margin: const pw.EdgeInsets.only(top: 18, bottom: 8),
          padding: const pw.EdgeInsets.fromLTRB(11, 7, 11, 7),
          decoration: const pw.BoxDecoration(color: PdfColors.teal50),
          child: pw.Row(
            children: [
              pw.Expanded(
                child: pw.Text(
                  _label(answer, index),
                  style: const pw.TextStyle(
                    fontSize: 14,
                    color: PdfColors.teal900,
                  ),
                ),
              ),
              if (pages.isNotEmpty)
                pw.Text(
                  '原资料第 ${pages.join('、')} 页',
                  style: const pw.TextStyle(
                    fontSize: 9,
                    color: PdfColors.grey700,
                  ),
                ),
            ],
          ),
        ),
      );
      if (crops[answer.key] case final bytes?) {
        body.add(
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 6),
            child: pw.Image(
              pw.MemoryImage(bytes),
              width: 430,
              height: 160,
              fit: pw.BoxFit.contain,
              alignment: pw.Alignment.centerLeft,
            ),
          ),
        );
      }
      if (answer.issue?.isNotEmpty == true) {
        body.add(
          pw.Text(
            '待核对  ${answer.issue}',
            style: const pw.TextStyle(fontSize: 10, color: PdfColors.brown700),
          ),
        );
      }
      body.addAll(await _paragraphs(answer.text));
    }
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(48, 40, 48, 40),
        maxPages: 500,
        header: (context) => pw.Container(
          padding: const pw.EdgeInsets.only(bottom: 8),
          decoration: const pw.BoxDecoration(
            border: pw.Border(
              bottom: pw.BorderSide(width: .5, color: PdfColors.grey400),
            ),
          ),
          child: pw.Text(
            'QUELYT  ·  解答',
            style: const pw.TextStyle(fontSize: 9),
          ),
        ),
        footer: (context) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text(
            '${context.pageNumber} / ${context.pagesCount}',
            style: const pw.TextStyle(color: PdfColors.grey700, fontSize: 9),
          ),
        ),
        build: (_) => [
          pw.SizedBox(height: 14),
          pw.Text(
            title,
            style: const pw.TextStyle(fontSize: 21, color: PdfColors.teal900),
          ),
          ...body,
        ],
      ),
    );
    return doc.save();
  }

  static Future<List<pw.Widget>> _paragraphs(String source) async {
    final formulas = parseFormulas(source);
    final output = <pw.Widget>[];
    final inline = <pw.InlineSpan>[];
    void flush() {
      if (inline.isEmpty) return;
      output.add(
        pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 5),
          child: pw.RichText(
            text: pw.TextSpan(
              children: List.of(inline),
              style: const pw.TextStyle(fontSize: 10.5, lineSpacing: 3),
            ),
          ),
        ),
      );
      inline.clear();
    }

    void addText(String text) {
      final lines = text.split('\n');
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i]
            .replaceFirst(RegExp(r'^#{1,6}\s+'), '')
            .replaceAll('**', '');
        if (line.isNotEmpty) inline.add(pw.TextSpan(text: line));
        if (i < lines.length - 1) flush();
      }
    }

    var offset = 0;
    for (final formula in formulas) {
      addText(source.substring(offset, formula.start));
      final graphic = await FormulaEngine.shared.render(
        formula.latex,
        display: formula.display,
      );
      if (graphic == null) {
        inline.add(pw.TextSpan(text: '${formula.latex}（TeX）'));
      } else if (formula.display) {
        flush();
        output.add(
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 5),
            child: _image(graphic, 6.0),
          ),
        );
      } else {
        inline.add(pw.WidgetSpan(child: _image(graphic, 4.8)));
      }
      offset = formula.end;
    }
    addText(source.substring(offset));
    flush();
    return output;
  }

  static pw.Widget _image(FormulaGraphic graphic, double scale) {
    final width = (graphic.widthEx * scale).clamp(1.0, 470.0);
    final height = width * graphic.heightEx / graphic.widthEx;
    return pw.SvgImage(
      svg: graphic.svg.replaceAll('currentColor', '#192b28'),
      width: width,
      height: height.clamp(1.0, 450.0),
    );
  }
}
