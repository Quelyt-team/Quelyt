import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_study/core/local_store.dart';
import 'package:local_study/core/models.dart';
import 'package:local_study/features/library/data/library_repository.dart';
import 'package:local_study/features/library/services/library_backup_service.dart';
import 'package:local_study/features/materials/material_work.dart';
import 'package:local_study/features/materials/science/formula_engine.dart';
import 'package:local_study/features/materials/science/solution_pdf.dart';
import 'package:local_study/features/notes/data/notes_repository.dart';
import 'package:local_study/features/notes/models/note_models.dart';
import 'package:local_study/services/document_service.dart';
import 'package:local_study/services/ocr_service.dart';
import 'package:local_study/ui/page_surface.dart';
import 'package:local_study/ui/theme/app_theme.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final verifyNative = Platform.environment['QUELYT_VERIFY_NATIVE'] == '1';
  final artifacts = Platform.environment['QUELYT_VERIFICATION_OUTPUT'];
  final legacySlide = Platform.environment['QUELYT_LEGACY_SLIDE'];
  setUpAll(() async {
    Pdfrx.cacheDirectoryPath = Directory.systemTemp.path;
    await pdfrxFlutterInitialize();
  });
  late Directory temp;
  late LocalStore store;
  late DocumentService documents;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('quelyt_outputs_');
    store = LocalStore.open(p.join(temp.path, 'data'));
    documents = DocumentService(
      Directory(p.join(temp.path, 'data')),
      store,
      OcrService(),
    );
  });
  tearDown(() async {
    store.dispose();
    await temp.delete(recursive: true);
  });

  testWidgets('a single move selects the exact region of a paused frame', (
    tester,
  ) async {
    final key = GlobalKey<PageSurfaceState>();
    final frame = RenderedPage(
      File('assets/science/vision-test.png').readAsBytesSync(),
      64,
      64,
    );
    SourceRegion? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: lightTheme,
        home: Scaffold(
          body: PageSurface(
            key: key,
            page: frame,
            selection: null,
            highlight: null,
            onSelect: (value) => selected = value,
          ),
        ),
      ),
    );
    key.currentState!.setSelecting(true);
    await tester.pumpAndSettle();
    final pixels = tester.getRect(find.byType(Image));
    expect(pixels.size.isEmpty, isFalse);
    final mouse = await tester.startGesture(
      pixels.topLeft + Offset(pixels.width * .1, pixels.height * .2),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveTo(
      pixels.topLeft + Offset(pixels.width * .6, pixels.height * .5),
    );
    await mouse.up();
    expect(selected?.left, closeTo(.1, .001));
    expect(selected?.top, closeTo(.2, .001));
    expect(selected?.right, closeTo(.6, .001));
    expect(selected?.bottom, closeTo(.5, .001));
  });

  test(
    'offline MathJax handles math and chemistry and the solution PDF reopens',
    () async {
      const formulas = [
        r'\frac{m}{M}',
        r'x_i^2',
        r'\ce{SO4^2-}',
        r'\ce{Ag+ + Cl- -> AgCl v}',
        r'\ce{CO2 + H2O <=> H2CO3}',
        r'\ce{A ->[heat] B}',
        r'\pu{123.4 kg m^-2}',
        r'\begin{pmatrix}1&2\\3&4\end{pmatrix}',
        r'\begin{aligned}x&=y+1\\y&=2\end{aligned}',
        r'\sqrt[3]{x}',
        r'\int_0^1 x\,dx',
        r'\sum_{i=1}^n i',
        r'\lim_{n\to\infty} a_n',
        r'\alpha\le\beta',
        r'\vec{v}',
        r'\ce{^{14}C}',
        r'\ce{CuSO4.5H2O}',
        r'\ce{H+ + OH- -> H2O}',
        r'\ce{2H2 + O2 -> 2H2O}',
        r'\ce{NO3-}',
        r'\pu{0.15 mol}',
        r'\frac{a+b}{c-d}',
        r'\begin{bmatrix}x\\y\end{bmatrix}',
        r'\ce{N2 + 3H2 <=>[Fe] 2NH3}',
      ];
      if (verifyNative) {
        for (final latex in formulas) {
          final svg = await FormulaEngine.shared.render(latex, display: true);
          expect(svg?.svg, contains('<path'), reason: latex);
        }
      }
      final source = await documents.importFile(
        'assets/science/vision-test.png',
        DocumentKind.exercise,
      );
      final entry = LibraryRepository(store).primaryEntry(source.id)!;
      final result = MaterialResult(
        key: 'q3',
        label: '第 3 题',
        data: const {'number': '3'},
        sources: [
          Evidence(
            id: 'q3',
            documentId: source.id,
            documentHash: source.contentHash,
            page: 1,
            region: SourceRegion.fullPage,
            text: '试题来源',
          ),
        ],
        text: [
          '### 原题',
          r'价格 $20。用 \(\frac{m}{M}\) 求物质的量。',
          '### 解题步骤',
          r'\[\ce{Ag+ + Cl- -> AgCl v}\]',
          r'$$\begin{aligned}m&=15.0\,\mathrm g\\n&=\frac{m}{M}\end{aligned}$$',
          '### 答案',
          '干燥后质量为 15.0 g。',
          if (verifyNative) ...[
            '### 科学符号检查',
            for (final latex in formulas) '\$\$$latex\$\$',
          ],
        ].join('\n\n'),
      );
      final service = SolutionPdf(documents);
      final saved = await service.save(
        source,
        [result],
        entryId: entry.id,
        partial: false,
      );
      expect(
        (await service.save(
          source,
          [result],
          entryId: entry.id,
          partial: false,
        )).id,
        saved.id,
      );
      expect(service.library.relatedMaterials(source.id).single.id, saved.id);
      expect(service.library.relatedMaterials(saved.id).single.id, source.id);
      final pdf = await PdfDocument.openFile(saved.filePath);
      final text = [
        for (final page in pdf.pages) (await page.loadText())?.fullText,
      ].join(' ');
      await pdf.dispose();
      expect(text, contains('干燥后质量为 15.0 g'));
      if (verifyNative) expect(text, isNot(contains(r'\ce{Ag')));
      if (artifacts != null) {
        await Directory(artifacts).create(recursive: true);
        await File(saved.filePath)
            .copy(p.join(artifacts, 'science-solutions.pdf'));
      }
    },
  );

  test('Impress converts a legacy PPT to two cited pages', () async {
    final doc = await documents.importFile(legacySlide!);
    expect(doc.kind, DocumentKind.textbook);
    expect(doc.pageCount, 2, reason: doc.conversionIssue);
    final opened = await documents.open(doc);
    try {
      expect(
        (await opened.pdf!.pages[0].loadText())?.fullText,
        contains('Quelyt legacy slide 1'),
      );
      expect(
        (await opened.pdf!.pages[1].loadText())?.fullText,
        contains('Quelyt legacy slide 2'),
      );
    } finally {
      await opened.dispose();
    }
    if (artifacts != null) {
      await documents
          .slidePreview(doc)
          .copy(p.join(artifacts, 'legacy-slides-preview.pdf'));
    }
  }, skip: legacySlide == null);

  test(
    'local PPTX yields ordered Chinese slides and preserves them in v3 backup',
    () async {
      final archive = Archive();
      void put(String name, String body) =>
          archive.addFile(ArchiveFile.string(name, body));
      put('ppt/presentation.xml', '''
<p:presentation xmlns:p="p" xmlns:r="r">
  <p:sldIdLst><p:sldId id="256" r:id="second"/><p:sldId id="257" r:id="first"/></p:sldIdLst>
  <p:sldSz cx="12192000" cy="6858000"/>
</p:presentation>''');
      put('ppt/_rels/presentation.xml.rels', '''
<Relationships><Relationship Id="first" Target="slides/slide1.xml"/>
<Relationship Id="second" Target="slides/slide2.xml"/></Relationships>''');
      for (final (name, title) in [
        ('slide1', '后讲反应与单位'),
        ('slide2', '先讲中文和物质的量'),
      ]) {
        put('ppt/slides/$name.xml', '''
<p:sld xmlns:p="p" xmlns:a="a"><p:cSld><p:spTree>
<p:sp><p:txBody><a:p><a:r><a:rPr sz="2800"/><a:t>$title</a:t></a:r></a:p></p:txBody></p:sp>
</p:spTree></p:cSld></p:sld>''');
      }
      final original = File(p.join(temp.path, '讲评课件.pptx'));
      await original.writeAsBytes(ZipEncoder().encode(archive));
      final doc = await documents.importFile(original.path);
      expect(doc.kind, DocumentKind.textbook);
      expect(doc.pageCount, 2, reason: doc.conversionIssue);
      final opened = await documents.open(doc);
      final first = await opened.pdf!.pages.first.loadText();
      expect(first?.fullText, contains('先讲中文和物质的量'));
      await opened.dispose();
      final service = LibraryBackupService(store: store, documents: documents);
      final report = await service.create(temp.path);
      final validation = await LibraryBackupService.validate(report.path);
      expect(validation.ok, isTrue, reason: validation.errors.join(' '));
      final manifest = validation.manifest!;
      expect(manifest['formatVersion'], 3);
      final slide = (manifest['documents'] as List).single['slidePreview'];
      expect(slide['relativePath'], endsWith('/slides.pdf'));
      if (artifacts != null) {
        await Directory(artifacts).create(recursive: true);
        await File(original.path).copy(p.join(artifacts, 'slides-sample.pptx'));
        await documents
            .slidePreview(doc)
            .copy(p.join(artifacts, 'slides-preview.pdf'));
      }
    },
  );

  test(
    'light backup restores a video reference and time note for hash relinking',
    () async {
      final source = File(p.join(temp.path, 'synthetic-video.mp4'));
      await source.writeAsBytes(utf8.encode('stream fixture'));
      final video = await documents.importFile(source.path);
      expect(video.kind, DocumentKind.video);
      final assetRoot = Directory(
        p.join(documents.directory.path, 'review_assets'),
      );
      await assetRoot.create(recursive: true);
      final asset = File(p.join(assetRoot.path, 'timestamp-snapshot.png'));
      await File('assets/science/vision-test.png').copy(asset.path);
      final note = NotesRepository(store).create(
        title: '图表转折点',
        body: '记录 3.52 秒的画面',
        sources: [
          NoteSource(
            id: 'source-time',
            noteId: '',
            documentId: video.id,
            documentHash: video.contentHash,
            timeMs: 3520,
            assetName: p.basename(asset.path),
            sourceType: 'video',
            createdAt: DateTime.utc(2026, 11, 19),
          ),
        ],
      );
      final service = LibraryBackupService(store: store, documents: documents);
      final report = await service.createZip(
        temp.path,
        includeVideoOriginals: false,
      );
      expect(report.omittedVideos, 1);
      final restore = p.join(temp.path, 'restore');
      final validation = await LibraryBackupService.prepareRestore(
        report.path,
        restore,
      );
      expect(validation.ok, isTrue);
      expect(
        (await LibraryBackupService.applyPendingRestore(restore))?.applied,
        isTrue,
      );
      final reopened = LocalStore.open(restore);
      try {
        final restoredDoc = reopened.getDocument(video.id)!;
        expect(restoredDoc.contentHash, video.contentHash);
        final restoredSource = NotesRepository(reopened)
            .sources(note.id)
            .single;
        expect(restoredSource.timeMs, 3520);
        expect(restoredSource.documentHash, video.contentHash);
        expect(
          await File(
            p.join(restore, 'review_assets', restoredSource.assetName!),
          ).readAsBytes(),
          await asset.readAsBytes(),
        );
        expect(
          await File(p.join(restore, 'documents', video.id, 'original.mp4'))
              .exists(),
          isFalse,
        );
      } finally {
        reopened.dispose();
      }
    },
  );
}
