import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:uuid/uuid.dart';
import 'package:xml/xml.dart';

import 'legacy_doc_parser.dart';

class WordConversion {
  const WordConversion(this.renderer, {this.notice});

  final String renderer;
  final String? notice;
}

class WordConverter {
  const WordConverter({this.allowExternalConverters = true});

  final bool allowExternalConverters;

  static const previewName = 'document.pdf';
  static const openXmlRenderer = 'docx-openxml-1';
  static const legacyDocRenderer = 'doc-cfb-1';
  static const writerRenderer = 'writer-pdf-1';
  static const wordComRenderer = 'word-com-pdf-1';

  Future<WordConversion> convert(File source, File destination) async {
    if (allowExternalConverters) {
      final soffice = _officeExecutable();
      if (soffice != null) {
        final result = await _writer(soffice, source, destination);
        if (result) return const WordConversion(writerRenderer);
      }
      if (Platform.isWindows) {
        final comOk = await _windowsWordCom(source, destination);
        if (comOk) return const WordConversion(wordComRenderer);
      }
    }

    final ext = p.extension(source.path).toLowerCase();
    final bytes = await source.readAsBytes();
    if (ext == '.docx' || LegacyDocParser.isZipBytes(bytes)) {
      await _openXml(source, destination);
      return const WordConversion(
        openXmlRenderer,
        notice: '静态预览。如需精确还原复杂排版，安装 Word / WPS / LibreOffice 后可重新转换，或对照原文件核对。',
      );
    }

    if (ext == '.doc') {
      final parsed = const LegacyDocParser().parse(bytes);
      await _renderLegacyDoc(parsed, destination);
      return const WordConversion(
        legacyDocRenderer,
        notice: '旧式 DOC 静态文本预览。如需完整保留原版式与图片，可另存为 DOCX 或在 Windows 安装 Word / WPS / LibreOffice 后重试转换。',
      );
    }

    throw StateError('暂不支持此 Word 文档格式：$ext');
  }

  /// Uses locally installed Microsoft Word or WPS Office via Windows COM
  /// automation (macros forcibly disabled) for high-fidelity `.doc`/`.docx`
  /// conversion when LibreOffice is not installed.
  Future<bool> _windowsWordCom(File source, File destination) async {
    if (!Platform.isWindows) return false;
    final scratch = await destination.parent.createTemp('word-com-');
    try {
      final outPdf = File(p.join(scratch.path, 'output.pdf'));
      final script = File(p.join(scratch.path, 'convert.ps1'));
      await script.writeAsString(r'''
param([string]$InputPath, [string]$OutputPath)
$ErrorActionPreference = 'Stop'
$app = $null
$doc = $null
foreach ($progId in @('Word.Application', 'KWPS.Application', 'Kwps.Application')) {
  try {
    $app = New-Object -ComObject $progId
    break
  } catch {
    $app = $null
  }
}
if ($null -eq $app) { exit 2 }
try {
  $app.Visible = $false
  try { $app.DisplayAlerts = 0 } catch {}
  try { $app.AutomationSecurity = 3 } catch {}
  $doc = $app.Documents.Open($InputPath, $false, $true, $false)
  try {
    $doc.ExportAsFixedFormat($OutputPath, 17)
  } catch {
    $doc.SaveAs2($OutputPath, 17)
  }
} finally {
  if ($null -ne $doc) {
    try { $doc.Close($false) } catch {}
    try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($doc) } catch {}
  }
  if ($null -ne $app) {
    try { $app.Quit() } catch {}
    try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($app) } catch {}
  }
}
''');
      final process = await Process.start('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
        '-InputPath',
        source.absolute.path,
        '-OutputPath',
        outPdf.absolute.path,
      ]);
      final out = process.stdout.drain<void>();
      final err = process.stderr.drain<void>();
      final code = await process.exitCode.timeout(
        const Duration(seconds: 45),
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
      if (code != -1) await Future.wait([out, err]);
      if (code != 0 || !await outPdf.exists() || await outPdf.length() == 0) {
        return false;
      }
      if (await destination.exists()) await destination.delete();
      await outPdf.rename(destination.path);
      return true;
    } on FileSystemException {
      return false;
    } on ProcessException {
      return false;
    } finally {
      try {
        await scratch.delete(recursive: true);
      } on FileSystemException {
        // Ignore cleanup races when COM holds temporary files briefly.
      }
    }
  }

  Future<void> _renderLegacyDoc(
    LegacyDocContent content,
    File destination,
  ) async {
    final font = pw.Font.ttf(
      await rootBundle.load('assets/science/NotoSansSC-Regular.ttf'),
    );
    final pdf = pw.Document(
      theme: pw.ThemeData.withFont(base: font, bold: font),
    );
    final widgets = <pw.Widget>[];
    for (final block in content.blocks) {
      switch (block) {
        case LegacyDocPageBreak():
          if (widgets.isNotEmpty) widgets.add(pw.NewPage());
        case LegacyDocParagraph(:final text):
          widgets.add(
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 5),
              child: pw.Text(
                text,
                style: const pw.TextStyle(
                  fontSize: 10.5,
                  lineSpacing: 3.0,
                  color: PdfColors.grey900,
                ),
              ),
            ),
          );
        case LegacyDocTable(:final rows):
          final colCount = rows.fold<int>(
            0,
            (maxCols, row) => row.length > maxCols ? row.length : maxCols,
          );
          if (colCount > 0) {
            widgets.add(
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 6),
                child: pw.Table(
                  border: pw.TableBorder.all(
                    color: PdfColors.grey400,
                    width: 0.6,
                  ),
                  children: [
                    for (var r = 0; r < rows.length; r++)
                      pw.TableRow(
                        decoration: r == 0
                            ? const pw.BoxDecoration(color: PdfColors.grey100)
                            : null,
                        children: [
                          for (var c = 0; c < colCount; c++)
                            pw.Padding(
                              padding: const pw.EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 4,
                              ),
                              child: pw.Text(
                                c < rows[r].length ? rows[r][c] : '',
                                style: const pw.TextStyle(
                                  fontSize: 9.5,
                                  lineSpacing: 2.2,
                                  color: PdfColors.grey900,
                                ),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            );
          }
      }
    }
    if (widgets.isEmpty) {
      widgets.add(
        pw.Text(
          '（此 DOC 文档未包含可提取的正文内容）',
          style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey700),
        ),
      );
    }

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(48, 46, 48, 46),
        maxPages: 1500,
        footer: (context) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text(
            '${context.pageNumber} / ${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
          ),
        ),
        build: (_) => widgets,
      ),
    );

    final temp = File(
      p.join(destination.parent.path, '.word-${const Uuid().v4()}.pdf'),
    );
    try {
      await temp.writeAsBytes(await pdf.save(), flush: true);
      if (await destination.exists()) await destination.delete();
      await temp.rename(destination.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  String? _officeExecutable() {
    if (!Platform.isWindows) return null;
    final environment = Platform.environment;
    for (final candidate in [
      environment['QUELYT_SOFFICE'],
      if (environment['ProgramFiles'] case final dir?)
        p.join(dir, 'LibreOffice', 'program', 'soffice.com'),
      if (environment['ProgramFiles(x86)'] case final dir?)
        p.join(dir, 'LibreOffice', 'program', 'soffice.com'),
    ]) {
      if (candidate != null &&
          p.isAbsolute(candidate) &&
          File(candidate).existsSync()) {
        return candidate;
      }
    }
    return null;
  }

  Future<bool> _writer(
    String executable,
    File source,
    File destination,
  ) async {
    final scratch = await destination.parent.createTemp('writer-');
    try {
      final profile = Directory(p.join(scratch.path, 'profile'));
      final user = Directory(p.join(profile.path, 'user'));
      await user.create(recursive: true);
      await File(p.join(user.path, 'registrymodifications.xcu'))
          .writeAsString('''
<?xml version="1.0" encoding="UTF-8"?>
<oor:items xmlns:oor="http://openoffice.org/2001/registry">
  <item oor:path="/org.openoffice.Office.Common/Security/Scripting">
    <prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop>
    <prop oor:name="DisableMacrosExecution" oor:op="fuse"><value>true</value></prop>
  </item>
  <item oor:path="/org.openoffice.Office.Common/Update">
    <prop oor:name="Link" oor:op="fuse"><value>0</value></prop>
  </item>
</oor:items>
''');
      final process = await Process.start(executable, [
        '-env:UserInstallation=${Uri.directory(profile.path, windows: true)}',
        '--headless',
        '--nologo',
        '--norestore',
        '--convert-to',
        'pdf:writer_pdf_Export',
        '--outdir',
        scratch.path,
        source.path,
      ]);
      final out = process.stdout.drain<void>();
      final error = process.stderr.drain<void>();
      final code = await process.exitCode.timeout(
        const Duration(minutes: 2),
        onTimeout: () {
          process.kill();
          return -1;
        },
      );
      if (code != -1) await Future.wait([out, error]);
      final generated = File(
        p.join(scratch.path, '${p.basenameWithoutExtension(source.path)}.pdf'),
      );
      if (code != 0 ||
          !await generated.exists() ||
          await generated.length() == 0) {
        return false;
      }
      if (await destination.exists()) await destination.delete();
      await generated.rename(destination.path);
      return true;
    } on FileSystemException {
      return false;
    } on ProcessException {
      return false;
    } finally {
      try {
        await scratch.delete(recursive: true);
      } on FileSystemException {
        // Ignore cleanup races when the converter still holds handles.
      }
    }
  }

  Future<void> _openXml(File source, File destination) async {
    final input = InputFileStream(source.path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      XmlElement parse(String name) {
        final entry = archive.findFile(name);
        if (entry == null || entry.size > 24 * 1024 * 1024) {
          throw const FormatException('Word 文档结构缺失或超过可读取大小。');
        }
        return XmlDocument.parse(utf8.decode(entry.content)).rootElement;
      }

      final docXml = parse('word/document.xml');
      final relsEntry = archive.findFile('word/_rels/document.xml.rels');
      final rels = relsEntry == null
          ? const <String, String>{}
          : _relationships(
              XmlDocument.parse(utf8.decode(relsEntry.content)).rootElement,
              'word',
            );
      final body = docXml
          .findAllElements('body', namespaceUri: '*')
          .firstOrNull;
      if (body == null) {
        throw const FormatException('Word 文档缺少正文节点。');
      }

      final font = pw.Font.ttf(
        await rootBundle.load('assets/science/NotoSansSC-Regular.ttf'),
      );
      final pdf = pw.Document(
        theme: pw.ThemeData.withFont(base: font, bold: font),
      );

      final widgets = <pw.Widget>[];
      for (final child in body.childElements) {
        final name = child.name.local;
        if (name == 'p') {
          _appendParagraph(child, archive, rels, widgets);
        } else if (name == 'tbl') {
          final table = _buildTable(child);
          if (table != null) {
            widgets.add(
              pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 6),
                child: table,
              ),
            );
          }
        }
      }

      if (widgets.isEmpty) {
        widgets.add(
          pw.Text(
            '（此 Word 文档未包含可提取的正文或图片内容）',
            style: const pw.TextStyle(fontSize: 11, color: PdfColors.grey700),
          ),
        );
      }

      pdf.addPage(
        pw.MultiPage(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.fromLTRB(48, 46, 48, 46),
          maxPages: 1500,
          footer: (context) => pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Text(
              '${context.pageNumber} / ${context.pagesCount}',
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
            ),
          ),
          build: (_) => widgets,
        ),
      );

      final temp = File(
        p.join(destination.parent.path, '.word-${const Uuid().v4()}.pdf'),
      );
      try {
        await temp.writeAsBytes(await pdf.save(), flush: true);
        if (await destination.exists()) await destination.delete();
        await temp.rename(destination.path);
      } finally {
        if (await temp.exists()) await temp.delete();
      }
    } finally {
      await input.close();
    }
  }

  void _appendParagraph(
    XmlElement paragraph,
    Archive archive,
    Map<String, String> rels,
    List<pw.Widget> widgets,
  ) {
    final pPr = paragraph.childElements
        .where((e) => e.name.local == 'pPr')
        .firstOrNull;
    final hasPageBreakBefore =
        pPr?.childElements.any((e) => e.name.local == 'pageBreakBefore') ??
        false;
    if (hasPageBreakBefore && widgets.isNotEmpty) {
      widgets.add(pw.NewPage());
    }

    final styleId =
        pPr?.childElements
            .where((e) => e.name.local == 'pStyle')
            .firstOrNull
            ?.attributes
            .where((a) => a.name.local == 'val')
            .firstOrNull
            ?.value ??
        '';
    final jcVal =
        pPr?.childElements
            .where((e) => e.name.local == 'jc')
            .firstOrNull
            ?.attributes
            .where((a) => a.name.local == 'val')
            .firstOrNull
            ?.value ??
        '';
    final isListItem =
        pPr?.childElements.any((e) => e.name.local == 'numPr') ?? false;

    final buffer = StringBuffer();
    var sawPageBreak = false;
    final images = <Uint8List>[];

    for (final desc in paragraph.descendants.whereType<XmlElement>()) {
      switch (desc.name.local) {
        case 't':
          buffer.write(desc.innerText);
        case 'tab':
          buffer.write('    ');
        case 'br':
          final type = desc.attributes
              .where((a) => a.name.local == 'type')
              .firstOrNull
              ?.value;
          if (type == 'page') {
            sawPageBreak = true;
          } else {
            buffer.write('\n');
          }
        case 'blip':
          final embedId = desc.attributes
              .where((a) => a.name.local == 'embed')
              .firstOrNull
              ?.value;
          final mediaPath = embedId == null ? null : rels[embedId];
          if (mediaPath != null &&
              RegExp(r'\.(png|jpe?g)$', caseSensitive: false)
                  .hasMatch(mediaPath)) {
            final media = archive.findFile(mediaPath);
            if (media != null && media.size <= 24 * 1024 * 1024) {
              images.add(Uint8List.fromList(media.content));
            }
          }
      }
    }

    final rawText = buffer.toString();
    final trimmed = rawText.trim();
    if (trimmed.isNotEmpty) {
      final (fontSize, topPad, bottomPad) = _styleMetrics(styleId);
      final align = switch (jcVal.toLowerCase()) {
        'center' => pw.TextAlign.center,
        'right' || 'end' => pw.TextAlign.right,
        _ => pw.TextAlign.left,
      };
      final display = isListItem ? '•  $trimmed' : trimmed;
      widgets.add(
        pw.Padding(
          padding: pw.EdgeInsets.only(
            left: isListItem ? 12 : 0,
            top: topPad,
            bottom: bottomPad,
          ),
          child: pw.Text(
            display,
            textAlign: align,
            style: pw.TextStyle(
              fontSize: fontSize,
              lineSpacing: fontSize >= 15 ? 3.5 : 3.0,
              color: PdfColors.grey900,
            ),
          ),
        ),
      );
    }

    for (final bytes in images) {
      try {
        widgets.add(
          pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 6),
            child: pw.Center(
              child: pw.ConstrainedBox(
                constraints: const pw.BoxConstraints(
                  maxWidth: 460,
                  maxHeight: 320,
                ),
                child: pw.Image(pw.MemoryImage(bytes), fit: pw.BoxFit.contain),
              ),
            ),
          ),
        );
      } catch (_) {
        // Skip unsupported or corrupt embedded image streams safely.
      }
    }

    if (sawPageBreak && widgets.isNotEmpty) {
      widgets.add(pw.NewPage());
    }
  }

  (double, double, double) _styleMetrics(String styleId) {
    final lower = styleId.toLowerCase();
    if (lower == 'title' || lower.contains('文档标题')) {
      return (20.0, 4.0, 10.0);
    }
    if (lower == 'heading1' || lower == '1' || lower.contains('标题 1')) {
      return (16.5, 10.0, 6.0);
    }
    if (lower == 'heading2' || lower == '2' || lower.contains('标题 2')) {
      return (14.0, 8.0, 5.0);
    }
    if (lower == 'heading3' || lower == '3' || lower.contains('标题 3')) {
      return (12.5, 6.0, 4.0);
    }
    return (10.5, 0.0, 5.0);
  }

  pw.Widget? _buildTable(XmlElement table) {
    final rows = <List<String>>[];
    for (final tr in table.childElements.where((e) => e.name.local == 'tr')) {
      final cells = <String>[];
      for (final tc in tr.childElements.where((e) => e.name.local == 'tc')) {
        final paragraphs = tc.childElements
            .where((e) => e.name.local == 'p')
            .map(
              (pNode) => pNode
                  .findAllElements('t', namespaceUri: '*')
                  .map((t) => t.innerText)
                  .join(),
            )
            .where((s) => s.trim().isNotEmpty)
            .join('\n');
        cells.add(paragraphs.trim());
      }
      if (cells.isNotEmpty) rows.add(cells);
    }
    if (rows.isEmpty) return null;
    final colCount = rows.fold<int>(
      0,
      (maxCols, row) => row.length > maxCols ? row.length : maxCols,
    );
    if (colCount == 0) return null;
    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.6),
      children: [
        for (var r = 0; r < rows.length; r++)
          pw.TableRow(
            decoration: r == 0
                ? const pw.BoxDecoration(color: PdfColors.grey100)
                : null,
            children: [
              for (var c = 0; c < colCount; c++)
                pw.Padding(
                  padding: const pw.EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  child: pw.Text(
                    c < rows[r].length ? rows[r][c] : '',
                    style: const pw.TextStyle(
                      fontSize: 9.5,
                      lineSpacing: 2.2,
                      color: PdfColors.grey900,
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }

  Map<String, String> _relationships(XmlElement root, String base) {
    final map = <String, String>{};
    for (final rel in root.findAllElements('Relationship', namespaceUri: '*')) {
      final id = rel.getAttribute('Id');
      final target = rel.getAttribute('Target');
      final mode = rel.getAttribute('TargetMode');
      if (id == null || target == null || mode == 'External') continue;
      final normalized = p.posix.normalize(
        target.startsWith('/')
            ? target.substring(1)
            : p.posix.join(base, target),
      );
      if (!normalized.startsWith('..')) map[id] = normalized;
    }
    return map;
  }
}
