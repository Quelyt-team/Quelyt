import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:local_study/core/local_store.dart';
import 'package:local_study/core/models.dart';
import 'package:local_study/features/book_qa/data/book_qa_repository.dart';
import 'package:local_study/features/book_qa/models/book_qa_models.dart';
import 'package:local_study/features/book_qa/services/book_qa_client.dart';
import 'package:local_study/features/book_qa/services/book_retriever.dart';
import 'package:local_study/features/materials/material_work.dart';
import 'package:local_study/features/materials/paper/paper_metadata.dart';
import 'package:local_study/features/materials/science/science_markup.dart';
import 'package:local_study/features/materials/word/legacy_doc_parser.dart';
import 'package:local_study/features/materials/word/word_converter.dart';
import 'package:local_study/features/notes/data/notes_repository.dart';
import 'package:local_study/features/notes/models/note_models.dart';
import 'package:local_study/services/ai_transport.dart';
import 'package:local_study/services/ai_types.dart';
import 'package:local_study/services/document_service.dart';
import 'package:local_study/services/ocr_service.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';

import '../book_qa/book_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    Pdfrx.cacheDirectoryPath = Directory.systemTemp.path;
    await pdfrxFlutterInitialize();
  });
  late Directory temp;
  late LocalStore store;
  late DocumentService documents;
  late ProviderSettings settings;
  late MemoryVault vault;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('quelyt_materials_');
    store = LocalStore.inMemory();
    documents = DocumentService(temp, store, OcrService());
    settings = ProviderSettings.deepSeek();
    vault = MemoryVault()..values[settings.credentialId] = 'offline-test';
  });
  tearDown(() async {
    store.dispose();
    await temp.delete(recursive: true);
  });

  test(
    'real four-page PDF sends the entire Batch B row and keeps valid citations',
    () async {
      final path = await _createFourPageAcceptancePdf(temp);
      final doc = await documents.importFile(path, DocumentKind.textbook);
      final opened = await documents.open(doc);
      for (var i = 1; i <= doc.pageCount; i++) {
        await documents.indexPage(opened, i);
      }
      await opened.dispose();
      final repo = BookQaRepository(store);
      final retriever = BookRetriever(store: store, repository: repo);
      const problem = 'What is the measured mass of Batch B after drying?';
      final all = retriever.retrieve(
        doc,
        problem,
        focusPage: 1,
        maxEvidence: 6,
      );
      final current = retriever.retrieve(
        doc,
        problem,
        focusPage: 4,
        currentPageOnly: true,
        maxEvidence: 6,
      );
      for (final query in [all, current]) {
        expect(
          query.evidence.any(
            (item) =>
                item.page == 4 &&
                item.text.contains('Batch B: 15.0 g') &&
                item.text.contains('Mean measured mass'),
          ),
          isTrue,
          reason: query.evidence.map((e) => e.text).join('\n'),
        );
      }
      expect(current.evidence.every((item) => item.page == 4), isTrue);
      expect(
        retriever
            .retrieve(doc, '为什么聚合物多以头尾键连为主', focusPage: 1)
            .webQueries()
            .first,
        contains('乙烯基单体'),
      );
      final correct =
          current.evidence.indexWhere(
            (item) => item.text.contains('Batch B: 15.0 g'),
          ) +
          1;
      final transport = AiTransport(
        client: MockClient((request) async {
          expect(request.body, contains('Batch B: 15.0 g'));
          return http.Response(
            chatEnvelope({
              'answerStatus': 'answered',
              'blocks': [
                {
                  'text': '15.0 g',
                  'bookCitations': [
                    'B$correct',
                    ' B$correct ',
                    12,
                    ...List.filled(16, 'B$correct'),
                    'B999',
                  ],
                },
                {
                  'kind': 'chem',
                  'latex': r'\ce{Ag+ + Cl- -> AgCl v}',
                  'bookCitations': 'B$correct',
                },
              ],
            }),
            200,
          );
        }),
        vault: vault,
      );
      addTearDown(transport.close);
      final client = BookQaClient(transport);
      final request = client.prepare(
        settings: settings,
        document: doc,
        conversationId: 'local',
        question: problem,
        mode: BookAskMode.currentPage,
        retrieval: current,
        searchQueries: const [],
        history: const [
          BookQaHistoryTurn(
            question: 'another page',
            answer: 'private previous text',
          ),
        ],
        webEnabled: false,
      );
      expect(request.history, isEmpty);
      final answer = await client.send(
        request,
        webSources: const [],
        webStatus: WebLookupStatus.disabled,
        webNote: '',
        usage: const BookQaUsage(),
      );
      expect(answer.blocks.first.bookCitationIds, ['B$correct']);
      expect(answer.blocks.first.needsVerification, isTrue);
      expect(answer.plainText, contains(r'\ce{Ag+ + Cl- -> AgCl v}'));
    },
  );

  test(
    'visual indexing sends exactly the reviewed crop and reuses it for recall',
    () async {
      final doc = await documents.importFile(
        'assets/science/vision-test.png',
        DocumentKind.textbook,
      );
      MaterialImage? reviewed;
      var requests = 0;
      final transport = AiTransport(
        client: MockClient((request) async {
          requests++;
          final body = jsonDecode(request.body) as Map;
          expect(body['model'], 'deepseek-flash');
          final user = (body['messages'] as List).last as Map;
          final image =
              (user['content'] as List).last['image_url']['url'] as String;
          final attachment = await reviewed!.load();
          expect(base64Decode(image.split(',').last), attachment.bytes);
          return http.Response(
            chatEnvelope({
              'blocks': [
                {
                  'kind': 'table',
                  'text': 'Mean measured mass',
                  'bounds': [.2, .2, .7, .5],
                  'rows': [
                    ['Batch', 'Mass'],
                    ['Batch B', '15.0 g'],
                  ],
                },
                {
                  'kind': 'unclear',
                  'text': 'Unreadable',
                  'bounds': [-1, .8, .8, 1],
                },
              ],
            }),
            200,
          );
        }),
        vault: vault,
      );
      addTearDown(transport.close);
      final work = MaterialWork(
        store: store,
        documents: documents,
        transport: transport,
      );
      const region = SourceRegion(.1, .1, .75, .84);
      final prepared = await work.prepareRecognition(doc, settings, [
        1,
      ], region: region);
      reviewed = prepared.units.single.image;
      await expectLater(
        work.run(
          prepared,
          tokenBudget: prepared.estimatedTokens,
          paused: () => false,
          onProgress: (_) {},
        ),
        throwsStateError,
      );
      expect(requests, 0);
      prepared.approve();
      final result = await work.run(
        prepared,
        tokenBudget: prepared.estimatedTokens,
        paused: () => false,
        onProgress: (_) {},
      );
      await prepared.close();
      expect(result.single.needsVerification, isTrue);
      final found = store.searchEvidence('15.0 g', documentId: doc.id);
      expect(found.single.text, contains('Batch B | 15.0 g'));
      expect(found.single.region.left, closeTo(.23, .0001));
      final again = await work.prepareRecognition(doc, settings, [
        1,
      ], region: region);
      expect(again.units, isEmpty);
      expect(again.cached.single.key, result.single.key);
      await again.close();
      expect(requests, 1);
    },
  );

  test(
    'answer save and selection append are atomic, offline, and idempotent',
    () {
      final repo = NotesRepository(store);
      final destination = repo.create(title: '原稿', body: '手工写下的内容');
      final draft = AnswerNoteDraft(
        answerId: 'question:science',
        documentId: 'old-book',
        question: '质量是多少？',
        sections: [
          AnswerNoteSection(
            r'公式 \(\frac{m}{M}\)',
            sources: [
              NoteSource(
                id: '',
                noteId: '',
                documentId: 'old-book',
                documentHash: 'book-version',
                page: 3,
                excerpt: '分式',
                createdAt: DateTime(2026),
              ),
            ],
          ),
          AnswerNoteSection(
            '答案 15.0 g',
            sources: [
              NoteSource(
                id: '',
                noteId: '',
                documentId: 'video',
                documentHash: 'video-version',
                page: 1,
                timeMs: 5040,
                excerpt: '15.0 g',
                createdAt: DateTime(2026),
              ),
            ],
          ),
        ],
      );
      final appended = repo.saveAnswer(
        draft,
        selected: {1},
        targetNoteId: destination.id,
        expectedRevision: destination.revision,
      );
      expect(appended.body, contains('手工写下的内容'));
      expect(appended.body, isNot(contains('分式')));
      expect(repo.sources(destination.id).single.timeMs, 5040);
      expect(
        repo
            .saveAnswer(
              draft,
              selected: {1},
              targetNoteId: destination.id,
              expectedRevision: destination.revision,
            )
            .body,
        appended.body,
      );
      final created = repo.saveAnswer(draft);
      expect(repo.saveAnswer(draft).id, created.id);
      expect(repo.sources(created.id), hasLength(2));
    },
  );

  test('science delimiters ignore currency and code, and translation preserves tokens', () {
    const source = r'价格 $20 与 $x_i^2$，补充 \(\ce{SO4^2-}\) 和 \[\frac{m}{M}\]。';
    final spans = parseFormulas('$source\n```text\n\$not_math\$\n```');
    expect(spans.map((span) => span.latex), [
      r'x_i^2',
      r'\ce{SO4^2-}',
      r'\frac{m}{M}',
    ]);
    final lock = ProtectedTranslation(
      r'Figure 3 reports 15.0 g [12] at \(x_i^2\).',
      glossary: {'reports': '报告'},
    );
    expect(lock.masked, contains('[QZP0000]'));
    expect(lock.restore(lock.masked), contains(r'15.0 g [12] at \(x_i^2\)'));
    expect(lock.restore(lock.masked), contains('报告'));
    expect(() => lock.restore('遗漏标记'), throwsFormatException);
  });

  test('a DOI hit with the wrong paper title cannot be silently linked', () {
    final transport = AiTransport(vault: vault);
    addTearDown(transport.close);
    final service = PaperMetadataService(
      MaterialWork(store: store, documents: documents, transport: transport),
    );
    const fields = {
      'doi': '10.1234/selected',
      'title': 'Thermal motion of polymers',
    };
    expect(service.lookupUri(fields).host, 'api.crossref.org');
    expect(
      service.match(
        fields,
        const PaperMetadata(
          fields: {
            'doi': '10.1234/selected',
            'title': 'A catalogue of Latin poetry',
          },
        ),
      ),
      lessThan(.54),
    );
  });

  test('exercise question parser preserves sub-questions and command parser extracts all numbers', () {
    expect(parseRequestedQuestionNumbers('把第 3、7 题收进错题本'), {'3', '7'});
    expect(parseRequestedQuestionNumbers('把第3题和第7题收进错题本'), {'3', '7'});
    expect(parseRequestedQuestionNumbers('将第1, 2, 5题加入错题本'), {'1', '2', '5'});

    final doc = DocumentRecord(
      id: 'hw-1',
      title: '高分子作业',
      kind: DocumentKind.exercise,
      filePath: 'hw.pdf',
      contentHash: 'hw-hash',
      pageCount: 2,
    );
    store.importDocument(doc, [
      PageRecord(documentId: doc.id, page: 1, status: PageStatus.ready, text: 'p1'),
      PageRecord(documentId: doc.id, page: 2, status: PageStatus.ready, text: 'p2'),
    ]);
    store.saveEvidence(
      Evidence(
        id: 'hw-e1',
        documentId: doc.id,
        documentHash: doc.contentHash,
        page: 1,
        region: const SourceRegion(.1, .1, .9, .5),
        text: '1. 计算聚合度。\n1) 求数均聚合度。\n2) 求重均聚合度。\n2. 写出缩聚反应方程式。',
      ),
    );
    store.saveEvidence(
      Evidence(
        id: 'hw-e2',
        documentId: doc.id,
        documentHash: doc.contentHash,
        page: 2,
        region: const SourceRegion(.1, .1, .9, .4),
        text: '习题 3 说明自由基聚合的链转移机理。',
      ),
    );

    final transport = AiTransport(vault: vault);
    addTearDown(transport.close);
    final work = MaterialWork(
      store: store,
      documents: documents,
      transport: transport,
    );
    final questions = work.exerciseQuestions(doc, 1, 2);
    expect(questions.map((q) => q.number).toList(), ['1', '2', '3']);
    expect(questions[0].stem, contains('1) 求数均聚合度。'));
    expect(questions[0].stem, contains('2) 求重均聚合度。'));

    final prepared = work.prepareExercises(
      doc,
      settings,
      questions,
      instruction: '保留两位有效数字',
    );
    expect(prepared.gaps, isEmpty);
    expect(prepared.units, hasLength(3));
    expect(prepared.units.first.requestText, contains('保留两位有效数字'));

    final withoutInstruction = work.prepareExercises(doc, settings, questions);
    expect(withoutInstruction.units.first.requestText, isNot(contains('"instruction"')));
  });

  test('Word (.docx) imports offline, converts to readable PDF, opens and indexes text', () async {
    expect(DocumentService.isSupportedPath('notes.docx'), isTrue);
    expect(DocumentService.isSupportedPath('legacy.doc'), isTrue);

    const documentXml = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body>
    <w:p>
      <w:pPr><w:pStyle w:val="Heading1"/></w:pPr>
      <w:r><w:t>第一章 高分子物理导论</w:t></w:r>
    </w:p>
    <w:p>
      <w:r><w:t>玻璃化转变温度 Tg 是非晶态聚合物的重要特征温度。</w:t></w:r>
    </w:p>
    <w:tbl>
      <w:tr>
        <w:tc><w:p><w:r><w:t>样品</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>Tg</w:t></w:r></w:p></w:tc>
      </w:tr>
      <w:tr>
        <w:tc><w:p><w:r><w:t>聚苯乙烯</w:t></w:r></w:p></w:tc>
        <w:tc><w:p><w:r><w:t>100 °C</w:t></w:r></w:p></w:tc>
      </w:tr>
    </w:tbl>
  </w:body>
</w:document>''';
    final archive = Archive()
      ..addFile(
        ArchiveFile(
          'word/document.xml',
          utf8.encode(documentXml).length,
          utf8.encode(documentXml),
        ),
      );
    final docxFile = File('${temp.path}${Platform.pathSeparator}polymer_notes.docx');
    await docxFile.writeAsBytes(ZipEncoder().encode(archive));

    final record = await documents.importFile(docxFile.path);
    expect(record.format, 'docx');
    expect(record.materialFormat, MaterialFormat.word);
    expect(record.isWord, isTrue);
    expect(record.usesConvertedPreview, isTrue);
    expect(record.pageCount, greaterThanOrEqualTo(1));
    expect(await documents.previewFile(record).exists(), isTrue);

    final opened = await documents.open(record);
    try {
      await documents.indexPage(opened, 1);
      final page1 = store.getPage(record.id, 1);
      expect(page1?.status, PageStatus.ready);
      expect(page1?.text, contains('玻璃化转变温度'));
      expect(page1?.text, contains('聚苯乙烯'));
    } finally {
      await opened.dispose();
    }
  });

  test('Legacy binary OLE2 Word (.doc) and RTF-as-DOC convert offline to readable PDF', () async {
    // Build a valid MS-CFB (OLE2) + MS-DOC (Word 97-2003) binary .doc with
    // UTF-16LE Chinese text, a field code, and a 2x2 table.
    const bodyText =
        '高分子化学旧版文档\r'
        '\x13 HYPERLINK "https://example.com" \x14点击查看\x15\r'
        '单体\x07机理\x07\x07'
        '苯乙烯\x07自由基聚合\x07\x07';
    final docBytes = _buildMinimalOle2Doc(bodyText);

    // 1. Direct parser check
    final parsed = const LegacyDocParser().parse(docBytes);
    final texts = parsed.blocks
        .whereType<LegacyDocParagraph>()
        .map((p) => p.text)
        .join('\n');
    expect(texts, contains('高分子化学旧版文档'));
    expect(texts, contains('点击查看'));
    expect(texts, isNot(contains('HYPERLINK')));
    final tables = parsed.blocks.whereType<LegacyDocTable>().toList();
    expect(tables, hasLength(1));
    expect(tables.single.rows, [
      ['单体', '机理'],
      ['苯乙烯', '自由基聚合'],
    ]);

    // 2. Offline WordConverter -> readable PDF (no external Office needed)
    final legacyFile = File('${temp.path}${Platform.pathSeparator}legacy_notes.doc');
    await legacyFile.writeAsBytes(docBytes);
    final outPdf = File('${temp.path}${Platform.pathSeparator}legacy_out.pdf');
    final conversion = await const WordConverter(
      allowExternalConverters: false,
    ).convert(legacyFile, outPdf);
    expect(conversion.renderer, WordConverter.legacyDocRenderer);
    expect(await outPdf.exists(), isTrue);

    final pdf = await PdfDocument.openFile(outPdf.path);
    try {
      expect(pdf.pages.length, greaterThanOrEqualTo(1));
      final extracted = (await pdf.pages.first.loadText())?.fullText ?? '';
      expect(extracted, contains('高分子化学旧版文档'));
      expect(extracted, contains('自由基聚合'));
    } finally {
      await pdf.dispose();
    }

    // 3. RTF file saved with .doc extension also works offline
    final rtfFile = File('${temp.path}${Platform.pathSeparator}rtf_notes.doc');
    await rtfFile.writeAsString(
      r'{\rtf1\ansi{\fonttbl\f0 SimSun;}\u29289?\u29702?\u21270?\u23398?\par Hello RTF DOC\par}',
    );
    final rtfPdf = File('${temp.path}${Platform.pathSeparator}rtf_out.pdf');
    final rtfConv = await const WordConverter(
      allowExternalConverters: false,
    ).convert(rtfFile, rtfPdf);
    expect(rtfConv.renderer, WordConverter.legacyDocRenderer);
    final rtfOpened = await PdfDocument.openFile(rtfPdf.path);
    try {
      final extracted = (await rtfOpened.pages.first.loadText())?.fullText ?? '';
      expect(extracted, contains('物理化学'));
      expect(extracted, contains('Hello RTF DOC'));
    } finally {
      await rtfOpened.dispose();
    }
  });
}

/// Builds a minimal spec-compliant OLE2 (MS-CFB v3, 512-byte sectors) Word
/// 97–2003 `.doc` binary containing a single UTF-16LE piece in `WordDocument`
/// and a `1Table` Clx piece table.
Uint8List _buildMinimalOle2Doc(String text) {
  const sectorSize = 512;
  const endOfChain = 0xFFFFFFFE;
  const freeSect = 0xFFFFFFFF;
  const fatSect = 0xFFFFFFFD;

  // Build WordDocument stream (>= 4096 bytes so it uses regular FAT sectors).
  final wordDoc = Uint8List(4096);
  final fib = ByteData.sublistView(wordDoc);
  fib.setUint16(0, 0xA5EC, Endian.little); // wIdent
  fib.setUint16(2, 0x00C1, Endian.little); // nFib (Word 97)
  fib.setUint16(10, 0x0200, Endian.little); // flags: fWhichTblStm = 1 (1Table)
  fib.setUint16(32, 14, Endian.little); // csw = 14 -> 34 + 28 = 62
  fib.setUint16(62, 22, Endian.little); // cslw = 22 -> fibRgLwStart = 64
  fib.setUint32(64 + 12, text.length, Endian.little); // ccpText
  const cbPos = 64 + 22 * 4; // 152
  fib.setUint16(cbPos, 93, Endian.little); // cbRgFcLcb
  const fcBase = cbPos + 2; // 154
  fib.setUint32(fcBase + 33 * 8, 0, Endian.little); // fcClx = 0

  // Write UTF-16LE text at offset 1024 inside WordDocument.
  const textOffset = 1024;
  for (var i = 0; i < text.length; i++) {
    fib.setUint16(textOffset + i * 2, text.codeUnitAt(i), Endian.little);
  }

  // Build 1Table stream (>= 4096 bytes) containing Clx Pcdt (1 piece).
  final table1 = Uint8List(4096);
  final tView = ByteData.sublistView(table1);
  table1[0] = 0x02; // clxt = Pcdt
  tView.setUint32(1, 16, Endian.little); // lcb = 4*(1+1) + 8*1 = 16
  tView.setUint32(5, 0, Endian.little); // cp[0] = 0
  tView.setUint32(9, text.length, Endian.little); // cp[1] = len
  // Pcd[0] at offset 13 (8 bytes): fcField at +2 = textOffset (bit 30 = 0 -> UTF-16LE)
  tView.setUint32(13 + 2, textOffset, Endian.little);
  fib.setUint32(fcBase + 33 * 8 + 4, 21, Endian.little); // lcbClx = 5 + 16 = 21

  // Sector layout:
  // Sector 0: FAT
  // Sector 1: Directory
  // Sectors 2..9: WordDocument (8 sectors = 4096 bytes)
  // Sectors 10..17: 1Table (8 sectors = 4096 bytes)
  const totalSectors = 18;
  final out = Uint8List((totalSectors + 1) * sectorSize);
  final hdr = ByteData.sublistView(out, 0, sectorSize);
  const magic = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
  for (var i = 0; i < magic.length; i++) {
    out[i] = magic[i];
  }
  hdr.setUint16(24, 0x003E, Endian.little); // minor version
  hdr.setUint16(26, 0x0003, Endian.little); // major version 3
  hdr.setUint16(28, 0xFFFE, Endian.little); // little-endian
  hdr.setUint16(30, 9, Endian.little); // sectorShift = 9 (512B)
  hdr.setUint16(32, 6, Endian.little); // miniSectorShift = 6 (64B)
  hdr.setUint32(44, 1, Endian.little); // numFatSectors = 1
  hdr.setUint32(48, 1, Endian.little); // firstDirSector = 1
  hdr.setUint32(56, 4096, Endian.little); // miniStreamCutoff
  hdr.setUint32(60, endOfChain, Endian.little); // firstMiniFatSector
  hdr.setUint32(68, endOfChain, Endian.little); // firstDifatSector
  for (var i = 0; i < 109; i++) {
    hdr.setUint32(76 + i * 4, i == 0 ? 0 : freeSect, Endian.little);
  }

  // FAT sector (sector 0 -> file offset 512)
  final fat = ByteData.sublistView(out, sectorSize, sectorSize * 2);
  for (var i = 0; i < 128; i++) {
    fat.setUint32(i * 4, freeSect, Endian.little);
  }
  fat.setUint32(0 * 4, fatSect, Endian.little);
  fat.setUint32(1 * 4, endOfChain, Endian.little);
  for (var s = 2; s < 9; s++) {
    fat.setUint32(s * 4, s + 1, Endian.little);
  }
  fat.setUint32(9 * 4, endOfChain, Endian.little);
  for (var s = 10; s < 17; s++) {
    fat.setUint32(s * 4, s + 1, Endian.little);
  }
  fat.setUint32(17 * 4, endOfChain, Endian.little);

  // Directory sector (sector 1 -> file offset 1024)
  void writeDirEntry(int slot, String name, int type, int startSect, int size) {
    final base = sectorSize * 2 + slot * 128;
    final view = ByteData.sublistView(out, base, base + 128);
    for (var i = 0; i < name.length; i++) {
      view.setUint16(i * 2, name.codeUnitAt(i), Endian.little);
    }
    view.setUint16(64, (name.length + 1) * 2, Endian.little);
    out[base + 66] = type;
    view.setUint32(116, startSect, Endian.little);
    view.setUint32(120, size, Endian.little);
  }

  writeDirEntry(0, 'Root Entry', 5, endOfChain, 0);
  writeDirEntry(1, 'WordDocument', 2, 2, wordDoc.length);
  writeDirEntry(2, '1Table', 2, 10, table1.length);

  // Stream payloads
  out.setRange(sectorSize * 3, sectorSize * 3 + wordDoc.length, wordDoc);
  out.setRange(sectorSize * 11, sectorSize * 11 + table1.length, table1);
  return out;
}

Future<String> _createFourPageAcceptancePdf(Directory dir) async {
  final fontBytes = File('assets/science/NotoSansSC-Regular.ttf')
      .readAsBytesSync();
  final font = pw.Font.ttf(fontBytes.buffer.asByteData());
  final theme = pw.ThemeData.withFont(base: font, bold: font);
  final doc = pw.Document(theme: theme);
  doc.addPage(
    pw.Page(
      build: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text('第一章 自由基聚合机理', style: const pw.TextStyle(fontSize: 18)),
          pw.SizedBox(height: 12),
          pw.Text(
            '在自由基聚合中，乙烯基单体由于空间位阻与自由基共轭稳定效应，'
            '链增长阶段主要发生头尾加成，因此聚合物多以头尾键连为主。',
          ),
        ],
      ),
    ),
  );
  doc.addPage(
    pw.Page(
      build: (_) => pw.Text(
        'Chapter 2 Experimental setup and drying protocol for polymer batches.',
      ),
    ),
  );
  doc.addPage(
    pw.Page(
      build: (_) => pw.Text(
        'Chapter 3 Calibration checks and moisture equilibrium verification.',
      ),
    ),
  );
  doc.addPage(
    pw.Page(
      build: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            'Table 4.1 Mean measured mass after drying',
            style: const pw.TextStyle(fontSize: 16),
          ),
          pw.SizedBox(height: 10),
          pw.Text('Batch A: 12.4 g | Mean measured mass after drying'),
          pw.Text('Batch B: 15.0 g | Mean measured mass after drying'),
          pw.Text('Batch C: 14.2 g | Mean measured mass after drying'),
        ],
      ),
    ),
  );
  final file = File(p.join(dir.path, 'acceptance-four-page.pdf'));
  await file.writeAsBytes(await doc.save(), flush: true);
  return file.path;
}
