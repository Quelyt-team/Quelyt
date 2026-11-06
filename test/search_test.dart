import 'package:flutter_test/flutter_test.dart';

import 'package:local_study/core/local_store.dart';
import 'package:local_study/core/models.dart';
import 'package:local_study/core/search_index.dart';

DocumentRecord _document(String id) => DocumentRecord(
  id: id,
  title: id,
  kind: DocumentKind.textbook,
  filePath: '/managed/$id.pdf',
  contentHash: 'hash-$id',
  pageCount: 5,
);

Evidence _evidence(String id, String documentId, int page, String text) =>
    Evidence(
      id: id,
      documentId: documentId,
      documentHash: 'hash-$documentId',
      page: page,
      region: SourceRegion.fullPage,
      text: text,
    );

void main() {
  late LocalStore store;

  setUp(() {
    store = LocalStore.inMemory();
    store.upsertDocument(_document('a'));
    store.upsertDocument(_document('b'));
    store.saveEvidence(
      _evidence('entropy', 'a', 1, '熵描述系统的状态。Entropy is a state function.'),
    );
    store.saveEvidence(
      _evidence('momentum', 'a', 2, '动量等于质量乘以速度。Momentum is conserved.'),
    );
    store.saveEvidence(_evidence('other', 'b', 3, '动量和熵用于不同的问题。'));
  });

  tearDown(() => store.dispose());

  test(
    'one-character and two-character Chinese terms are searchable offline',
    () {
      expect(store.searchEvidence('熵').map((e) => e.id), contains('entropy'));
      expect(store.searchEvidence('动量').map((e) => e.id), contains('momentum'));
      expect(store.searchEvidence('动量', documentId: 'a').map((e) => e.id), [
        'momentum',
      ]);
      expect(store.searchEvidence('动静').map((e) => e.id), isEmpty);
    },
  );

  test('English terms are case-insensitive whole words', () {
    expect(
      store.searchEvidence('ENTROPY', documentId: 'a').single.id,
      'entropy',
    );
    expect(store.searchEvidence('moment', documentId: 'a'), isEmpty);
    expect(store.searchEvidence('momentum', documentId: 'a').single.page, 2);
  });

  test(
    'document and physical page restrictions do not leak other evidence',
    () {
      expect(store.searchEvidence('动量', documentId: 'b').single.id, 'other');
      expect(
        store.searchEvidence('动量', documentId: 'a', startPage: 1, endPage: 1),
        isEmpty,
      );
      expect(
        store
            .searchEvidence('动量', documentId: 'a', startPage: 2, endPage: 2)
            .single
            .id,
        'momentum',
      );
    },
  );

  test('FTS syntax and SQL punctuation are literal query input', () {
    expect(
      () =>
          store.searchEvidence('" OR NEAR() * : - \' ; DROP TABLE documents;'),
      returnsNormally,
    );
    expect(store.getDocuments(), hasLength(2));
    expect(store.searchEvidence('   ***   '), isEmpty);
  });

  test('correcting OCR replaces old indexed text in the same transaction', () {
    store.saveEvidence(_evidence('momentum', 'a', 2, '速度 velocity'));
    expect(store.searchEvidence('动量', documentId: 'a'), isEmpty);
    expect(
      store.searchEvidence('velocity', documentId: 'a').single.id,
      'momentum',
    );
  });

  test('replacing page evidence preserves manual annotations', () {
    store.saveEvidence(
      _evidence(
        'manual',
        'a',
        2,
        '人工校正的批注',
      ).copyWith(origin: EvidenceOrigin.manual),
    );
    store.replacePageEvidence('a', 2, [_evidence('new', 'a', 2, '新的识别结果')]);
    expect(store.getEvidence('a', page: 2).map((e) => e.id), ['manual', 'new']);
    expect(store.searchEvidence('momentum', documentId: 'a'), isEmpty);
    expect(store.searchEvidence('识别', documentId: 'a').single.id, 'new');
  });

  test(
    'a failed page replacement rolls back the old evidence and FTS index',
    () {
      expect(
        () => store.replacePageEvidence('a', 2, [
          _evidence('new', 'a', 2, '替换内容'),
          _evidence(
            'invalid',
            'a',
            2,
            '错误版本',
          ).copyWith(documentHash: 'changed-hash'),
        ]),
        throwsArgumentError,
      );
      expect(
        store.searchEvidence('momentum', documentId: 'a').single.id,
        'momentum',
      );
      expect(store.searchEvidence('替换', documentId: 'a'), isEmpty);
    },
  );

  test('Han token stream includes singletons and adjacent pairs', () {
    expect(
      SearchIndex.tokens('熵与动量 Momentum'),
      containsAll(['熵', '动', '量', '动量', 'momentum']),
    );
    expect(SearchIndex.matchQuery('动量'), '("动量")');
  });
}
