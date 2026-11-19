import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:uuid/uuid.dart';
import 'package:xml/xml.dart';

class SlideConversion {
  const SlideConversion(this.renderer, {this.notice});

  final String renderer;
  final String? notice;
}

class SlideConverter {
  const SlideConverter();

  static const previewName = 'slides.pdf';
  static const basicRenderer = 'openxml-static-1';
  static const impressRenderer = 'impress-pdf-1';

  Future<SlideConversion> convert(File source, File destination) async {
    final soffice = _impressExecutable();
    if (soffice != null) {
      final result = await _impress(soffice, source, destination);
      if (result) return const SlideConversion(impressRenderer);
    }
    if (p.extension(source.path).toLowerCase() == '.pptx') {
      await _openXml(source, destination);
      return const SlideConversion(
        basicRenderer,
        notice: '静态预览。请对照原件核对字体、图表和叠放对象。',
      );
    }
    throw StateError(
      Platform.isWindows
          ? '旧式 PPT 需要本机 LibreOffice Impress 转换。安装或修复组件后可重试。'
          : '此设备暂不能转换旧式 PPT。可导入 PPTX 或在 Windows 转换后恢复备份。',
    );
  }

  String? _impressExecutable() {
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

  Future<bool> _impress(
    String executable,
    File source,
    File destination,
  ) async {
    final scratch = await destination.parent.createTemp('impress-');
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
        'pdf:impress_pdf_Export',
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
        // A converter interrupted during cleanup may still own these files.
      }
    }
  }

  Future<void> _openXml(File source, File destination) async {
    final input = InputFileStream(source.path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      XmlElement parse(String name) {
        final entry = archive.findFile(name);
        if (entry == null || entry.size > 16 * 1024 * 1024) {
          throw const FormatException('课件结构缺失或超过可读取大小。');
        }
        return XmlDocument.parse(utf8.decode(entry.content)).rootElement;
      }

      final presentation = parse('ppt/presentation.xml');
      final rels = _relationships(
        parse('ppt/_rels/presentation.xml.rels'),
        'ppt',
      );
      final ids = presentation
          .findAllElements('sldId', namespaceUri: '*')
          .map(
            (node) => node.attributes
                .firstWhere(
                  (a) => a.name.local == 'id' && a.name.prefix != null,
                )
                .value,
          )
          .toList();
      if (ids.isEmpty || ids.length > 1500) {
        throw const FormatException('课件没有可读取的幻灯片或页数过多。');
      }
      final geometry = presentation
          .findAllElements('sldSz', namespaceUri: '*')
          .firstOrNull;
      final cx = double.tryParse(geometry?.getAttribute('cx') ?? '') ?? 9144000;
      final cy = double.tryParse(geometry?.getAttribute('cy') ?? '') ?? 5143500;
      if (cx <= 0 || cy <= 0 || !cx.isFinite || !cy.isFinite) {
        throw const FormatException('课件页面尺寸无效。');
      }
      final ratio = (cy / cx).clamp(.30, 2.5);
      final format = PdfPageFormat(720, 720 * ratio);
      final font = pw.Font.ttf(
        await rootBundle.load('assets/science/NotoSansSC-Regular.ttf'),
      );
      final pdf = pw.Document(
        theme: pw.ThemeData.withFont(base: font, bold: font),
      );
      for (final id in ids) {
        final path = rels[id];
        if (path == null) throw const FormatException('课件缺少幻灯片关系。');
        final root = parse(path);
        final relPath =
            '${p.posix.dirname(path)}/_rels/${p.posix.basename(path)}.rels';
        final references = archive.findFile(relPath) == null
            ? <String, String>{}
            : _relationships(parse(relPath), p.posix.dirname(path));
        final tree = root
            .findAllElements('spTree', namespaceUri: '*')
            .firstOrNull;
        final positioned = <pw.Widget>[];
        var fallbackTop = 22.0;
        for (final shape in tree?.childElements ?? const <XmlElement>[]) {
          final kind = shape.name.local;
          final text = shape
              .findAllElements('p', namespaceUri: '*')
              .map(
                (line) => line
                    .findAllElements('t', namespaceUri: '*')
                    .map((t) => t.innerText)
                    .join(),
              )
              .where((line) => line.isNotEmpty)
              .join('\n');
          final transform = shape
              .findAllElements('xfrm', namespaceUri: '*')
              .firstOrNull;
          final offset = transform?.childElements
              .where((e) => e.name.local == 'off')
              .firstOrNull;
          final extent = transform?.childElements
              .where((e) => e.name.local == 'ext')
              .firstOrNull;
          double? metric(XmlElement? node, String key, double scale) {
            final raw = double.tryParse(node?.getAttribute(key) ?? '');
            return raw == null || !raw.isFinite ? null : raw * scale;
          }

          final left = (metric(offset, 'x', format.width / cx) ?? 25).clamp(
            0.0,
            format.width - 1,
          );
          final top = (metric(offset, 'y', format.height / cy) ?? fallbackTop)
              .clamp(0.0, format.height - 1);
          final width =
              (metric(extent, 'cx', format.width / cx) ?? format.width - 50)
                  .clamp(1.0, format.width - left);
          final height = (metric(extent, 'cy', format.height / cy) ?? 72).clamp(
            1.0,
            format.height - top,
          );
          pw.Widget? child;
          if (kind == 'pic') {
            final blip = shape
                .findAllElements('blip', namespaceUri: '*')
                .firstOrNull;
            final sourceId = blip?.attributes
                .where((a) => a.name.local == 'embed')
                .firstOrNull
                ?.value;
            final mediaPath = references[sourceId];
            final media = mediaPath == null
                ? null
                : archive.findFile(mediaPath);
            if (media != null &&
                media.size <= 24 * 1024 * 1024 &&
                RegExp(
                  r'\.(png|jpe?g)$',
                  caseSensitive: false,
                ).hasMatch(media.name)) {
              child = pw.Image(
                pw.MemoryImage(media.content),
                fit: pw.BoxFit.contain,
              );
            }
          }
          if (child == null && text.isNotEmpty) {
            final properties = shape
                .findAllElements('rPr', namespaceUri: '*')
                .firstOrNull;
            final size =
                (double.tryParse(properties?.getAttribute('sz') ?? '') ??
                    1800) /
                100;
            child = pw.Text(
              text,
              style: pw.TextStyle(fontSize: size.clamp(7, 65)),
              maxLines: math.max(1, (height / (size.clamp(7, 65) + 2)).floor()),
            );
          }
          if (child == null) continue;
          positioned.add(
            pw.Positioned(
              left: left,
              top: top,
              child: pw.SizedBox(
                width: width,
                height: height,
                child: pw.ClipRect(child: child),
              ),
            ),
          );
          if (offset == null) fallbackTop += height;
        }
        if (positioned.isEmpty) {
          positioned.add(
            pw.Positioned(
              left: 24,
              top: 24,
              child: pw.Text(
                '该页需要用课件原件核对',
                style: const pw.TextStyle(fontSize: 14),
              ),
            ),
          );
        }
        pdf.addPage(
          pw.Page(
            pageFormat: format,
            margin: pw.EdgeInsets.zero,
            build: (_) => pw.Stack(children: positioned),
          ),
        );
      }
      final staged = File('${destination.path}.${const Uuid().v4()}.tmp');
      try {
        await staged.writeAsBytes(await pdf.save(), flush: true);
        await staged.rename(destination.path);
      } finally {
        if (await staged.exists()) await staged.delete();
      }
    } finally {
      await input.close();
    }
  }

  Map<String, String> _relationships(XmlElement doc, String base) => {
    for (final item in doc.childElements)
      if (item.getAttribute('Target') case final target?
          when item.getAttribute('TargetMode') != 'External' &&
              item.getAttribute('Id') != null &&
              !target.contains('\\'))
        item.getAttribute('Id')!: p.posix.normalize(
          target.startsWith('/')
              ? target.substring(1)
              : p.posix.join(base, target),
        ),
  };
}
