import 'package:flutter_test/flutter_test.dart';

import 'package:local_study/features/book_qa/services/book_understanding_client.dart';
import 'package:local_study/features/book_qa/services/book_understanding_service.dart';

import 'acceptance_cases.dart';
import 'book_fixture.dart';

void main() {
  late BookFixture fixture;

  setUp(() async {
    fixture = BookFixture.create();
    final service = BookUnderstandingService(
      store: fixture.store,
      repository: fixture.repository,
      client: BookUnderstandingClient(fixture.gateway.transport),
    );
    // Structure only; no model request is made.
    service.ensureStructure(fixture.document);
  });

  tearDown(() => fixture.dispose());

  test('the acceptance set has the required spread of cases', () {
    expect(acceptanceCases, hasLength(20));
    expect(
      acceptanceCases.where((item) => item.startsOutsideExpectedPages).length,
      greaterThanOrEqualTo(6),
    );
    expect(
      acceptanceCases.where((item) => item.needsExternal).length,
      greaterThanOrEqualTo(5),
    );
    expect(
      acceptanceCases.map((item) => item.category).toSet(),
      containsAll(['definition', 'reason', 'crossChapter', 'author', 'latest']),
    );
  });

  for (var index = 0; index < acceptanceCases.length; index++) {
    final item = acceptanceCases[index];
    test('Q${index + 1} · ${item.question}', () {
      final retrieval = fixture.retriever.retrieve(
        fixture.document,
        item.question,
        focusPage: item.focusPage,
      );
      final pages = retrieval.evidence.map((evidence) => evidence.page).toSet();
      expect(
        retrieval.evidence,
        isNotEmpty,
        reason: 'no evidence for: ${item.question}',
      );
      expect(
        pages.intersection(item.expectedPages),
        isNotEmpty,
        reason:
            'expected one of ${item.expectedPages} for “${item.question}”, '
            'got $pages',
      );
      expect(
        retrieval.hitChapters.map((chapter) => chapter.title),
        contains(item.expectedChapter),
        reason:
            'expected chapter ${item.expectedChapter} for “${item.question}”',
      );
      if (item.needsExternal) {
        expect(
          retrieval.webQueries(),
          isNotEmpty,
          reason: 'external cases need at least one search query',
        );
      }
      expect(
        retrieval.coverage().wholeBookSearched,
        isTrue,
        reason: 'a question away from its answer must still search the book',
      );
    });
  }
}
