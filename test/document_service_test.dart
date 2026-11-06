import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:local_study/core/local_store.dart';
import 'package:local_study/core/models.dart';
import 'package:local_study/services/document_service.dart';
import 'package:local_study/services/ocr_service.dart';
import 'package:pdfrx/pdfrx.dart';

class _ControlledOcr extends OcrService {
  final started = Completer<void>();
  final result = Completer<OcrPage>();
  @override
  Future<OcrAvailability> availability() async =>
      const OcrAvailability(available: true, backend: 'test-only');
  @override
  Future<OcrPage> recognizeImage(String path, {String? language}) {
    started.complete();
    return result.future;
  }
}

Future<RenderedPage> _twoColorPage() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 10, 20),
    ui.Paint()..color = const ui.Color(0xFFFF0000),
  );
  canvas.drawRect(
    const ui.Rect.fromLTWH(10, 0, 10, 20),
    ui.Paint()..color = const ui.Color(0xFF0000FF),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(20, 20);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return RenderedPage(png!.buffer.asUint8List(), 20, 20);
}

// An original minimal PDF fixture: no external document or copyrighted text.
Uint8List _pdfFixture(int rotation) {
  const stream =
      'BT /F1 18 Tf 72 650 Td (Momentum is mass times velocity.) Tj ET';
  final objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /Rotate $rotation '
        '/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    '<< /Length ${stream.length} >>\nstream\n$stream\nendstream',
  ];
  var output = '%PDF-1.4\n';
  final offsets = <int>[0];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(output.length);
    output += '${i + 1} 0 obj\n${objects[i]}\nendobj\n';
  }
  final xref = output.length;
  output += 'xref\n0 ${objects.length + 1}\n0000000000 65535 f \n';
  for (final offset in offsets.skip(1)) {
    output += '${offset.toString().padLeft(10, '0')} 00000 n \n';
  }
  output +=
      'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n';
  return Uint8List.fromList(ascii.encode(output));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    Pdfrx.cacheDirectoryPath = Directory.systemTemp.path;
    await pdfrxFlutterInitialize();
  });
  late Directory directory;
  late LocalStore store;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('local_study_documents_');
    store = LocalStore.inMemory();
  });
  tearDown(() async {
    store.dispose();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('image import deduplicates managed copies and deletion preserves the external original', () async {
    final source = File('${directory.path}/external.png');
    await source.writeAsBytes((await _twoColorPage()).bytes);
    final service = DocumentService(
      Directory('${directory.path}/app'),
      store,
      OcrService(),
    );
    final first = await service.importFile(source.path, DocumentKind.textbook);
    final second = await service.importFile(source.path, DocumentKind.textbook);
    expect(first.id, second.id);
    expect(store.getDocuments(), hasLength(1));
    expect(first.filePath, isNot(source.path));
    final managed = Directory('${directory.path}/app/documents');
    expect(await managed.list().length, 1);
    await service.delete(first);
    expect(await source.exists(), isTrue);
    expect(await File(first.filePath).exists(), isFalse);
    expect(store.getDocuments(), isEmpty);
  });

  test(
    'late OCR cannot overwrite a manual correction or its search index',
    () async {
      final ocr = _ControlledOcr();
      final service = DocumentService(directory, store, ocr);
      final doc = DocumentRecord(
        id: 'ocr-doc',
        title: 'OCR race',
        kind: DocumentKind.textbook,
        filePath: 'test-only.png',
        contentHash: 'hash',
      );
      store.importDocument(doc, [PageRecord(documentId: doc.id, page: 1)]);
      final opened = OpenDocument(
        doc,
        null,
        renderer: (_, _) async => RenderedPage(Uint8List.fromList([1]), 1, 1),
      );
      final indexing = service.indexPage(opened, 1);
      await ocr.started.future;
      await service.correctPage(doc, 1, '人工更正：动量守恒', SourceRegion.fullPage);
      ocr.result.complete(
        const OcrPage(
          text: '过期 OCR 错字',
          blocks: [],
          width: 1,
          height: 1,
          backend: 'test-only',
        ),
      );
      await indexing;
      expect(store.getPage(doc.id, 1)!.text, '人工更正：动量守恒');
      expect(store.getPage(doc.id, 1)!.manuallyCorrected, isTrue);
      expect(store.searchEvidence('动量'), hasLength(1));
      expect(store.searchEvidence('过期'), isEmpty);
      await opened.dispose();
    },
  );

  test(
    'document close waits for in-flight rendering and rejects later work',
    () async {
      final doc = DocumentRecord(
        id: 'render',
        title: 'render',
        kind: DocumentKind.paper,
        filePath: 'test-only',
        contentHash: 'hash',
      );
      final result = Completer<RenderedPage>();
      final document = OpenDocument(
        doc,
        null,
        renderer: (_, _) => result.future,
      );
      final rendering = document.render(1);
      var closed = false;
      final closing = document.dispose().then((_) => closed = true);
      await Future<void>.value();
      expect(closed, isFalse);
      result.complete(RenderedPage(Uint8List(0), 1, 1));
      await rendering;
      await closing;
      expect(closed, isTrue);
      await expectLater(document.render(1), throwsStateError);
    },
  );

  test('cropping preserves the exact selected pixels and dimensions', () async {
    final bytes = await cropPage(
      await _twoColorPage(),
      const SourceRegion(.5, 0, 1, 1),
    );
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    expect(frame.image.width, 10);
    expect(frame.image.height, 20);
    final data = await frame.image.toByteData(
      format: ui.ImageByteFormat.rawRgba,
    );
    expect(data!.buffer.asUint8List().take(4), [0, 0, 255, 255]);
    frame.image.dispose();
    codec.dispose();
  });

  for (final rotation in [0, 90, 180, 270]) {
    test(
      'PDF text citation encloses rendered glyphs with page rotation $rotation',
      () async {
        final file = File('${directory.path}/original-$rotation.pdf');
        await file.writeAsBytes(_pdfFixture(rotation));
        final service = DocumentService(
          Directory('${directory.path}/app'),
          store,
          OcrService(),
        );
        final doc = await service.importFile(file.path, DocumentKind.paper);
        final opened = await service.open(doc);
        try {
          await service.indexPage(opened, 1);
          final evidence = store.searchEvidence('Momentum', documentId: doc.id);
          expect(evidence, isNotEmpty, reason: store.getPage(doc.id, 1)?.error);
          final rendered = await opened.render(1, maxSide: 800);
          final cropped = await cropPage(rendered, evidence.first.region);
          final codec = await ui.instantiateImageCodec(cropped);
          final frame = await codec.getNextFrame();
          final pixels = await frame.image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          final values = pixels!.buffer.asUint8List();
          var dark = 0;
          for (var i = 0; i < values.length; i += 4) {
            if (values[i] < 180 && values[i + 1] < 180 && values[i + 2] < 180) {
              dark++;
            }
          }
          expect(
            dark,
            greaterThan(20),
            reason: 'Citation rectangle must include actual source glyphs',
          );
          frame.image.dispose();
          codec.dispose();
        } finally {
          await opened.dispose();
        }
      },
    );
  }
}
