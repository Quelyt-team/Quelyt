import 'dart:io';

import 'package:path/path.dart' as p;

import '../../../core/models.dart';
import '../../../services/document_service.dart';

/// Lazily renders and caches the first page of a document for the library
/// details panel. Covers live under the managed `cache/<id>/` directory and are
/// deleted by "清理可重建缓存" like any other derived image.
class LibraryThumbnailService {
  LibraryThumbnailService({required this.documents});

  final DocumentService documents;
  final Map<String, Future<File?>> _inflight = {};

  Future<File?> coverFor(DocumentRecord document) {
    final existing = _inflight[document.id];
    if (existing != null) return existing;
    final task = _generate(document);
    _inflight[document.id] = task;
    task.whenComplete(() => _inflight.remove(document.id));
    return task;
  }

  Future<File?> _generate(DocumentRecord document) async {
    final source = File(document.filePath);
    if (!await source.exists() || !document.isActive) return null;
    final directory = Directory(
      p.join(documents.directory.path, 'cache', document.id),
    );
    final cover = File(p.join(directory.path, 'cover.png'));
    try {
      if (await cover.exists()) {
        final sourceTime = await source.lastModified();
        final coverTime = await cover.lastModified();
        if (!coverTime.isBefore(sourceTime)) return cover;
      }
      await directory.create(recursive: true);
      final opened = await documents.open(document);
      try {
        final page = await opened.render(1, maxSide: 520);
        await cover.writeAsBytes(page.bytes, flush: true);
        return cover;
      } finally {
        await opened.dispose();
      }
    } catch (_) {
      // A corrupt, missing or still-moving file simply keeps the format glyph.
      return null;
    }
  }
}
