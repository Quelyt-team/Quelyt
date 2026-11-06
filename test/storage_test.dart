import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:local_study/core/local_store.dart';
import 'package:local_study/core/models.dart';

DocumentRecord _document() => DocumentRecord(
  id: 'book',
  title: '力学',
  kind: DocumentKind.textbook,
  filePath: '/managed/copy.pdf',
  contentHash: 'sha256-original',
  pageCount: 220,
  currentPage: 21,
);

Evidence _evidence() => const Evidence(
  id: 'source',
  documentId: 'book',
  documentHash: 'sha256-original',
  page: 21,
  region: SourceRegion(.12, .2, .8, .45),
  text: '动量等于质量乘以速度。',
  origin: EvidenceOrigin.ocr,
  confidence: .91,
);

void main() {
  test(
    'a library restart preserves page, OCR queue, citations, notes and retries',
    () {
      final directory = Directory.systemTemp.createTempSync('study-store-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final store = LocalStore.open(directory.path);
      store.upsertDocument(_document());
      store.savePage(
        const PageRecord(
          documentId: 'book',
          page: 21,
          status: PageStatus.ready,
          text: '动量等于质量乘以速度。',
        ),
      );
      store.savePage(
        const PageRecord(
          documentId: 'book',
          page: 22,
          status: PageStatus.needsOcr,
        ),
      );
      store.saveEvidence(_evidence());
      store.saveNote(
        StudyNote(
          id: 'note',
          documentId: 'book',
          page: 21,
          region: _evidence().region,
          understanding: '动量与速度同向',
          evidenceText: _evidence().text,
          question: '系统外力为零时如何变化？',
        ),
      );
      store.saveSession(
        StudySession(
          id: 'session',
          documentId: 'book',
          startPage: 20,
          endPage: 25,
          goal: '解释动量',
          minutes: 30,
          stage: 'feedback',
          question: '什么是动量？',
          answer: '质量乘速度',
          feedback: '遗漏了矢量条件',
          needsReview: true,
          attempts: [
            StudyAttempt(
              question: '什么是动量？',
              answer: '质量乘速度',
              feedback: '遗漏了矢量条件',
              needsReview: true,
            ),
          ],
        ),
      );
      store.dispose();

      final reopened = LocalStore.open(directory.path);
      addTearDown(reopened.dispose);
      expect(reopened.getDocument('book')!.currentPage, 21);
      expect(reopened.getPage('book', 22)!.status, PageStatus.needsOcr);
      expect(
        reopened.getEvidence('book').single.region,
        const SourceRegion(.12, .2, .8, .45),
      );
      expect(
        reopened.searchEvidence('动量').single.documentHash,
        'sha256-original',
      );
      expect(reopened.getNotes('book').single.documentHash, 'sha256-original');
      expect(
        reopened.getSessions('book').single.attempts.single.answer,
        '质量乘速度',
      );
      expect(reopened.getSessions('book').single.needsReview, isTrue);
    },
  );

  test('deleting a document cascades into all learning records and FTS', () {
    final store = LocalStore.inMemory();
    addTearDown(store.dispose);
    store.upsertDocument(_document());
    store.savePage(const PageRecord(documentId: 'book', page: 21));
    store.saveEvidence(_evidence());
    store.saveNote(StudyNote(id: 'note', documentId: 'book', page: 21));
    store.saveSession(
      StudySession(
        id: 'session',
        documentId: 'book',
        startPage: 21,
        endPage: 22,
      ),
    );
    store.deleteDocument('book');
    expect(store.getDocuments(), isEmpty);
    expect(store.getPages('book'), isEmpty);
    expect(store.getEvidence('book'), isEmpty);
    expect(store.searchEvidence('动量'), isEmpty);
    expect(store.getNotes('book'), isEmpty);
    expect(store.getSessions('book'), isEmpty);
  });

  test(
    'citations reject a different document version and invalid physical page',
    () {
      final store = LocalStore.inMemory();
      addTearDown(store.dispose);
      store.upsertDocument(_document());
      expect(
        () => store.saveEvidence(
          _evidence().copyWith(documentHash: 'sha256-new'),
        ),
        throwsArgumentError,
      );
      expect(
        () => store.saveEvidence(_evidence().copyWith(page: 221)),
        throwsRangeError,
      );
      expect(
        () => store.upsertDocument(
          _document().copyWith(contentHash: 'sha256-new'),
        ),
        throwsArgumentError,
      );
      expect(store.getEvidence('book'), isEmpty);
    },
  );

  test(
    'region round-trip is independent of viewport and rotates consistently',
    () {
      const region = SourceRegion(.1, .2, .7, .8);
      final restored = SourceRegion.fromJson(region.toJson());
      expect(restored, region);
      var rotated = region;
      for (var i = 0; i < 4; i++) {
        rotated = rotated.rotateClockwise();
      }
      expect(rotated.left, closeTo(region.left, 1e-12));
      expect(rotated.top, closeTo(region.top, 1e-12));
      expect(rotated.right, closeTo(region.right, 1e-12));
      expect(rotated.bottom, closeTo(region.bottom, 1e-12));
      expect(region.intersects(const SourceRegion(.6, .7, .9, .9)), isTrue);
      expect(region.intersects(const SourceRegion(.8, .1, .9, .4)), isFalse);
    },
  );

  test('secure credentials cannot be stored by the ordinary settings API', () {
    final store = LocalStore.inMemory();
    addTearDown(store.dispose);
    expect(
      () => store.setSetting('apiKey', 'do-not-store'),
      throwsArgumentError,
    );
    expect(
      () => store.setSetting('provider_secret', 'do-not-store'),
      throwsArgumentError,
    );
    store.setSetting('provider_model', 'my-model');
    expect(store.getSetting('provider_model'), 'my-model');
  });
}
