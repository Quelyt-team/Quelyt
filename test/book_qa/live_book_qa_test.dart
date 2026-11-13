import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:local_study/features/book_qa/models/book_qa_models.dart';
import 'package:local_study/features/book_qa/services/book_qa_service.dart';
import 'package:local_study/features/book_qa/services/book_understanding_client.dart';
import 'package:local_study/features/book_qa/services/book_understanding_service.dart';
import 'package:local_study/services/ai_gateway.dart';

import 'book_fixture.dart';

/// Live Q09 check. It is skipped by default because Search, Fetch, chunk
/// understanding and the final answer are all billable.
///
/// Run from an ASCII alias path:
///   $env:BOOK_QA_LIVE='1'
///   $env:DEEPSEEK_API_KEY='sk-...'
///   flutter test test/book_qa/live_book_qa_test.dart
void main() {
  final key = Platform.environment['DEEPSEEK_API_KEY']?.trim() ?? '';
  final enabled = Platform.environment['BOOK_QA_LIVE'] == '1' && key.isNotEmpty;

  test(
    'live DeepSeek: understand a small book, search, fetch and answer with sources',
    () async {
      final fixture = BookFixture.create();
      final gateway = AiGateway(
        vault: fixture.vault,
        client: http.Client(),
        timeout: const Duration(seconds: 120),
      );
      final settings = ProviderSettings.deepSeek();
      await fixture.vault.write(settings.credentialId, key);
      addTearDown(() {
        gateway.close();
        fixture.dispose();
      });

      final understanding = BookUnderstandingService(
        store: fixture.store,
        repository: fixture.repository,
        client: BookUnderstandingClient(gateway.transport),
      );
      final structure = understanding.estimate(fixture.document);
      // ignore: avoid_print
      print(
        'LIVE structure: ${structure.chapterCount} chapters, '
        '${structure.chunkCount} chunks, ${structure.pendingChunks} pending',
      );
      final learned = await understanding.run(
        fixture.document,
        settings,
        maxChunks: 3,
      );
      // ignore: avoid_print
      print(
        'LIVE understanding: ${learned.progress.chunkReady}/'
        '${learned.progress.chunkTotal} chunks, complete='
        '${learned.progress.complete}, note=${learned.note}',
      );
      expect(learned.progress.chunkReady, greaterThan(0));

      final service = BookQaService(
        store: fixture.store,
        repository: fixture.repository,
        transport: gateway.transport,
      );
      final conversation = fixture.repository.ensureConversation(
        fixture.document,
      );
      final prepared = service.prepare(
        document: fixture.document,
        conversation: conversation,
        question: '为什么聚合物多以头尾键连为主？',
        settings: settings,
        mode: BookAskMode.wholeBookWeb,
        currentPage: 12,
        history: const [],
      );
      final answer = await service.ask(prepared);
      // ignore: avoid_print
      print(
        'LIVE answer: status=${answer.answerStatus.name}, '
        'web=${answer.webStatus.name}, book=${answer.bookSources.length}, '
        'webSources=${answer.webSources.length}, '
        'search=${answer.usage.searchRequests}, '
        'fetch=${answer.usage.fetchRequests}, '
        'tokens=${answer.usage.totalTokens}\n${answer.plainText}',
      );
      for (final source in answer.bookSources) {
        // ignore: avoid_print
        print('LIVE book source B${source.id}: page ${source.page}');
      }
      for (final source in answer.webSources) {
        // ignore: avoid_print
        print(
          'LIVE web source ${source.id}: ${source.url} (${source.statusLabel})',
        );
      }
      expect(answer.blocks, isNotEmpty);
      expect(answer.bookSources, isNotEmpty);
      expect(
        answer.webStatus == WebLookupStatus.searched ||
            answer.webStatus == WebLookupStatus.cached ||
            answer.webStatus == WebLookupStatus.failed,
        isTrue,
      );
      // A failed search is allowed, but it must then be labelled honestly.
      if (answer.webStatus == WebLookupStatus.failed) {
        expect(answer.webSources, isEmpty);
      }
    },
    skip: enabled ? false : 'Set BOOK_QA_LIVE=1 and DEEPSEEK_API_KEY to run the billable live check.',
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
