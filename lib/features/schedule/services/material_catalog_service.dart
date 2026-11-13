import '../../../core/local_store.dart';
import '../../../core/models.dart';
import '../data/schedule_repository.dart';
import '../models/plan_source.dart';

/// One contiguous extract that can be sent to a later knowledge/lesson step.
/// It always names the source, document version and physical page range.
class MaterialChunk {
  const MaterialChunk({
    required this.sourceId,
    required this.planId,
    required this.documentId,
    required this.documentHash,
    required this.documentTitle,
    required this.purpose,
    required this.chapter,
    required this.startPage,
    required this.endPage,
    required this.text,
  });

  final String sourceId;
  final String planId;
  final String documentId;
  final String documentHash;
  final String documentTitle;
  final MaterialPurpose purpose;
  final String chapter;
  final int startPage;
  final int endPage;
  final String text;

  String get rangeLabel => startPage == endPage
      ? '第 $startPage 页'
      : '第 $startPage–$endPage 页';
}

class MaterialExtraction {
  const MaterialExtraction({
    required this.chunks,
    required this.readyPages,
    required this.selectedPages,
    required this.skippedSources,
    this.truncated = false,
  });

  final List<MaterialChunk> chunks;
  final int readyPages;
  final int selectedPages;
  final List<PlanSource> skippedSources;
  final bool truncated;

  bool get hasReadyText => chunks.isNotEmpty;
}

/// Reads only already committed page text. It never triggers OCR as a side
/// effect, so callers can inspect coverage and prepare pages explicitly first.
class MaterialCatalogService {
  MaterialCatalogService(this.store);

  final LocalStore store;

  MaterialExtraction extractPlan(
    String planId, {
    int maxCharsPerChunk = 4000,
    int maxChunks = 40,
  }) {
    if (maxCharsPerChunk < 500) {
      throw ArgumentError.value(
        maxCharsPerChunk,
        'maxCharsPerChunk',
        'Use at least 500 characters.',
      );
    }
    final repository = ScheduleRepository(store);
    final sources = repository.getPlanSources(planId);
    final chunks = <MaterialChunk>[];
    final skipped = <PlanSource>[];
    var readyPages = 0;
    var selectedPages = 0;
    var truncated = false;

    for (final source in sources) {
      selectedPages += source.pageCount;
      final pages = store
          .getPages(source.documentId)
          .where(
            (page) =>
                page.page >= source.startPage &&
                page.page <= source.endPage &&
                page.status == PageStatus.ready &&
                page.text.trim().isNotEmpty,
          )
          .toList();
      readyPages += pages.length;
      if (pages.isEmpty) {
        skipped.add(source);
        continue;
      }
      if (chunks.length >= maxChunks) {
        truncated = true;
        skipped.add(source);
        continue;
      }

      final buffer = StringBuffer();
      var chunkStart = 0;
      var chunkEnd = 0;
      void flush() {
        final text = buffer.toString().trim();
        if (text.isEmpty) return;
        if (chunks.length >= maxChunks) {
          truncated = true;
          buffer.clear();
          return;
        }
        chunks.add(
          MaterialChunk(
            sourceId: source.id,
            planId: source.planId,
            documentId: source.documentId,
            documentHash: source.documentHash,
            documentTitle: source.documentTitle,
            purpose: source.purpose,
            chapter: source.chapter,
            startPage: chunkStart,
            endPage: chunkEnd,
            text: text,
          ),
        );
        buffer.clear();
      }

      for (final page in pages) {
        if (chunks.length >= maxChunks) {
          truncated = true;
          break;
        }
        final text = page.text.trim();
        if (text.isEmpty) continue;
        if (buffer.isNotEmpty &&
            buffer.length + text.length + 2 > maxCharsPerChunk) {
          flush();
        }
        if (text.length > maxCharsPerChunk) {
          // Keep an overlong page addressable without silently dropping its
          // tail. Each segment still points to the same physical page.
          var offset = 0;
          while (offset < text.length && chunks.length < maxChunks) {
            final end = (offset + maxCharsPerChunk).clamp(0, text.length);
            chunks.add(
              MaterialChunk(
                sourceId: source.id,
                planId: source.planId,
                documentId: source.documentId,
                documentHash: source.documentHash,
                documentTitle: source.documentTitle,
                purpose: source.purpose,
                chapter: source.chapter,
                startPage: page.page,
                endPage: page.page,
                text: text.substring(offset, end),
              ),
            );
            offset = end;
          }
          if (offset < text.length) truncated = true;
          continue;
        }
        if (buffer.isEmpty) {
          chunkStart = page.page;
        }
        chunkEnd = page.page;
        if (buffer.isNotEmpty) buffer.write('\n\n');
        buffer.write(text);
      }
      flush();
    }

    return MaterialExtraction(
      chunks: chunks,
      readyPages: readyPages,
      selectedPages: selectedPages,
      skippedSources: skipped,
      truncated: truncated,
    );
  }
}
