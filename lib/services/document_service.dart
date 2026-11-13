import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:uuid/uuid.dart';

import '../core/local_store.dart';
import '../core/models.dart';
import 'ocr_service.dart';

class RenderedPage {
  const RenderedPage(this.bytes, this.width, this.height);
  final Uint8List bytes;
  final int width;
  final int height;
}

/// A complete copy inside the app's import area together with the hash of the
/// bytes that were actually copied. The queue can retry a commit without
/// reading the user's disk again, and the external original is never edited.
class StagedImport {
  const StagedImport({
    required this.sourcePath,
    required this.sourceName,
    required this.extension,
    required this.stagedPath,
    required this.digest,
    required this.sizeBytes,
  });

  final String sourcePath;
  final String sourceName;
  final String extension;
  final String stagedPath;
  final String digest;
  final int sizeBytes;
}

class ImportCommit {
  const ImportCommit({required this.record, required this.duplicate});
  final DocumentRecord record;

  /// True when the managed copy already existed and no new document row was
  /// created. The caller decides whether to point at it or create a shortcut.
  final bool duplicate;
}

/// One opened document at a time. All stored rectangles use the rendered
/// original page orientation, never widget or screen coordinates.
class OpenDocument {
  OpenDocument(this.record, this.pdf, {this.renderer});
  final DocumentRecord record;
  final PdfDocument? pdf;
  final Future<RenderedPage> Function(int page, int maxSide)? renderer;
  int _activeUses = 0;
  bool _closing = false;
  Completer<void>? _idle;
  Future<void>? _disposeTask;

  Future<T> _use<T>(Future<T> Function() operation) async {
    if (_closing) {
      throw StateError('这份资料已经关闭。');
    }
    _activeUses++;
    try {
      return await operation();
    } finally {
      _activeUses--;
      if (_activeUses == 0) {
        _idle?.complete();
        _idle = null;
      }
    }
  }

  Future<RenderedPage> render(int page, {int maxSide = 2000}) =>
      _use(() => _render(page, maxSide: maxSide));

  Future<RenderedPage> _render(int page, {int maxSide = 2000}) async {
    if (page < 1 || page > record.pageCount || maxSide < 1) {
      throw RangeError('页面或渲染尺寸超出范围。');
    }
    final customRenderer = renderer;
    if (customRenderer != null) return customRenderer(page, maxSide);
    if (pdf == null) {
      final codec = await ui.instantiateImageCodec(
        await File(record.filePath).readAsBytes(),
      );
      try {
        final frame = await codec.getNextFrame();
        try {
          final bytes = await frame.image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          if (bytes == null) throw StateError('无法解码图片。');
          return RenderedPage(
            bytes.buffer.asUint8List(),
            frame.image.width,
            frame.image.height,
          );
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
    }
    final source = pdf!.pages[page - 1];
    final scale = math.min(
      3.0,
      maxSide / math.max(source.width, source.height),
    );
    final raster = await source.render(
      fullWidth: source.width * scale,
      fullHeight: source.height * scale,
    );
    if (raster == null) throw StateError('无法渲染第 $page 页');
    try {
      final image = await raster.createImage();
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        if (bytes == null) throw StateError('无法编码 PDF 页面。');
        return RenderedPage(
          bytes.buffer.asUint8List(),
          image.width,
          image.height,
        );
      } finally {
        image.dispose();
      }
    } finally {
      raster.dispose();
    }
  }

  Future<void> dispose() => _disposeTask ??= _dispose();

  Future<void> _dispose() async {
    _closing = true;
    if (_activeUses > 0) {
      _idle ??= Completer<void>();
      await _idle!.future;
    }
    await pdf?.dispose();
  }
}

class DocumentService {
  DocumentService(this.directory, this.store, this.ocr);
  final Directory directory;
  final LocalStore store;
  final OcrService ocr;
  static const _uuid = Uuid();
  final Map<String, int> _pageRevisions = {};
  final Map<String, Set<Future<void>>> _indexOperations = {};
  final Set<String> _deletedDocuments = {};

  String _pageKey(String documentId, int page) => '$documentId:$page';

  static const supportedExtensions = {'.pdf', '.jpg', '.jpeg', '.png'};

  static bool isSupportedPath(String path) =>
      supportedExtensions.contains(p.extension(path).toLowerCase());

  bool _canCommit(DocumentRecord document, int page, int revision) {
    final stored = store.getDocument(document.id);
    return !_deletedDocuments.contains(document.id) &&
        stored != null &&
        stored.isActive &&
        stored.lifecycleVersion == document.lifecycleVersion &&
        (_pageRevisions[_pageKey(document.id, page)] ?? 0) == revision &&
        stored.contentHash == document.contentHash;
  }

  /// Copies one source file into the app's import area with byte progress.
  /// Nothing is registered in the library yet; a failed or cancelled copy leaves
  /// the user's file untouched and can be retried from the staged copy.
  Future<StagedImport> stageFile(
    String sourcePath, {
    String? batchId,
    void Function(int done, int total)? onProgress,
  }) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw FileSystemException('找不到源文件', sourcePath);
    }
    final extension = p.extension(sourcePath).toLowerCase();
    if (!supportedExtensions.contains(extension)) {
      throw FormatException('暂不支持 $extension 格式，支持 PDF、JPG 和 PNG。');
    }
    final total = await source.length();
    if (total <= 0) throw const FormatException('文件是空的，没有导入。');
    final staging = _managedDirectory('imports', batchId ?? 'inbox');
    await staging.create(recursive: true);
    final temp = File(p.join(staging.path, '${_uuid.v4()}$extension.part'));
    var done = 0;
    final reader = await source.open();
    final writer = await temp.open(mode: FileMode.write);
    var copied = false;
    try {
      while (true) {
        final chunk = await reader.read(1024 * 1024);
        if (chunk.isEmpty) break;
        await writer.writeFrom(chunk);
        done += chunk.length;
        onProgress?.call(done, total);
      }
      await writer.flush();
      copied = true;
    } finally {
      await reader.close();
      await writer.close();
      if (!copied) {
        try {
          if (await temp.exists()) await temp.delete();
        } catch (_) {
          /* A cancelled copy leaves only a .part file in the import area. */
        }
      }
    }
    final digest = (await sha256.bind(temp.openRead()).first).toString();
    final target = File(
      p.join(staging.path, '${p.basenameWithoutExtension(temp.path)}$extension'),
    );
    await temp.rename(target.path);
    return StagedImport(
      sourcePath: sourcePath,
      sourceName: p.basename(sourcePath),
      extension: extension,
      stagedPath: target.path,
      digest: digest,
      sizeBytes: total,
    );
  }

  /// Re-hashes an existing staged copy after an app restart before committing.
  Future<StagedImport> adoptStaged(
    String stagedPath, {
    required String sourcePath,
    required String sourceName,
  }) async {
    final file = File(stagedPath);
    if (!await file.exists()) {
      throw FileSystemException('暂存副本已被清理', stagedPath);
    }
    final root = p.normalize(p.absolute(directory.path));
    final target = p.normalize(p.absolute(stagedPath));
    if (!p.isWithin(root, target)) {
      throw ArgumentError('Staged path escapes the app directory.');
    }
    final extension = p.extension(sourcePath).toLowerCase();
    final digest = (await sha256.bind(file.openRead()).first).toString();
    return StagedImport(
      sourcePath: sourcePath,
      sourceName: sourceName,
      extension: extension,
      stagedPath: target,
      digest: digest,
      sizeBytes: await file.length(),
    );
  }

  /// Moves a verified staged copy into the managed document directory and
  /// creates the document row. A hash match returns the existing record and
  /// deletes the staged copy; nothing is silently duplicated or re-owned.
  Future<ImportCommit> commitStaged(
    StagedImport staged, {
    String? title,
    DocumentKind kind = DocumentKind.unspecified,
  }) async {
    final existing = store.findDocumentByHash(staged.digest);
    if (existing != null) {
      await _deleteStaged(staged.stagedPath);
      return ImportCommit(record: existing, duplicate: true);
    }
    final id = _uuid.v4();
    final targetDirectory = _managedDirectory('documents', id);
    PdfDocument? pdf;
    try {
      await targetDirectory.create(recursive: true);
      final target = File(
        p.join(targetDirectory.path, 'original${staged.extension}'),
      );
      try {
        await File(staged.stagedPath).rename(target.path);
      } on FileSystemException {
        await File(staged.stagedPath).copy(target.path);
        await File(staged.stagedPath).delete();
      }
      var pageCount = 1;
      if (staged.extension == '.pdf') {
        pdf = await PdfDocument.openFile(target.path);
        pageCount = pdf.pages.length;
        if (pageCount == 0) {
          throw const FormatException('PDF 没有可读取的页面。');
        }
      } else {
        final codec = await ui.instantiateImageCodec(
          await target.readAsBytes(),
        );
        try {
          final frame = await codec.getNextFrame();
          frame.image.dispose();
        } finally {
          codec.dispose();
        }
      }
      final now = DateTime.now();
      final record = DocumentRecord(
        id: id,
        title: title?.trim().isNotEmpty == true
            ? title!.trim()
            : p.basenameWithoutExtension(staged.sourceName),
        kind: kind,
        filePath: target.path,
        contentHash: staged.digest,
        pageCount: pageCount,
        originalName: staged.sourceName,
        format: staged.extension.replaceFirst('.', ''),
        sizeBytes: staged.sizeBytes,
        createdAt: now,
        addedAt: now,
      );
      store.importDocument(
        record,
        List.generate(
          pageCount,
          (index) => PageRecord(documentId: id, page: index + 1),
        ),
      );
      return ImportCommit(record: record, duplicate: false);
    } catch (_) {
      await pdf?.dispose();
      pdf = null;
      await _deleteManagedDirectory('documents', id);
      rethrow;
    } finally {
      await pdf?.dispose();
    }
  }

  /// Compatibility helper for callers that only need a document record.
  Future<DocumentRecord> importFile(
    String sourcePath, [
    DocumentKind kind = DocumentKind.unspecified,
  ]) async {
    final staged = await stageFile(sourcePath);
    final commit = await commitStaged(staged, kind: kind);
    return commit.record;
  }

  Future<void> _deleteStaged(String stagedPath) async {
    final file = File(stagedPath);
    if (await file.exists()) await file.delete();
  }

  /// Called after a document entered or left the trash. In-flight OCR and
  /// indexing results are allowed to finish but can no longer commit because
  /// [_canCommit] checks the lifecycle and its version.
  Future<void> onLifecycleChanged(String documentId) async {
    final document = store.getDocument(documentId);
    if (document != null && document.isActive) {
      _deletedDocuments.remove(documentId);
      return;
    }
    _deletedDocuments.add(documentId);
    final operations = _indexOperations[documentId];
    if (operations != null) {
      await Future.wait(
        operations.toList().map((task) => task.catchError((Object _) {})),
      );
    }
  }

  Future<OpenDocument> open(DocumentRecord record) async {
    if (_deletedDocuments.contains(record.id) || !record.isActive) {
      throw StateError(
        record.isTrashed ? '资料在回收站里，恢复后才能打开。' : '资料已删除。',
      );
    }
    final stored = store.getDocument(record.id);
    if (stored == null || !stored.isActive) {
      throw StateError('资料在回收站里，恢复后才能打开。');
    }
    final isPdf = p.extension(record.filePath).toLowerCase() == '.pdf';
    return OpenDocument(
      record,
      isPdf ? await PdfDocument.openFile(record.filePath) : null,
    );
  }

  /// Text extraction and OCR are deliberately separate. A mixed page can be
  /// manually re-recognized, even if it already has a small text layer.
  Future<void> indexPage(
    OpenDocument document,
    int page, {
    bool forceOcr = false,
  }) {
    final task = document._use(
      () => _indexPage(document, page, forceOcr: forceOcr),
    );
    final operations = _indexOperations.putIfAbsent(
      document.record.id,
      () => <Future<void>>{},
    );
    operations.add(task);
    // Use then(onError:) rather than an unobserved whenComplete future.
    task.then(
      (_) => operations.remove(task),
      onError: (Object _, StackTrace _) {
        operations.remove(task);
      },
    );
    return task;
  }

  /// Separated so native rasterization can be replaced by a deterministic
  /// renderer in tests of OCR scheduling and manual correction races.
  Future<RenderedPage> renderPageForIndex(OpenDocument document, int page) =>
      document._render(page);

  Future<void> _indexPage(
    OpenDocument document,
    int page, {
    required bool forceOcr,
  }) async {
    final record = document.record;
    final revision = _pageRevisions[_pageKey(record.id, page)] ?? 0;
    if (!_canCommit(record, page, revision)) return;
    final previous = store.getPage(record.id, page);
    if (!forceOcr && previous?.manuallyCorrected == true) return;
    try {
      if (!forceOcr && document.pdf != null) {
        final pdfPage = document.pdf!.pages[page - 1];
        final text = await pdfPage.loadStructuredText();
        if (_usableText(text.fullText)) {
          final fragments = <Evidence>[];
          for (var i = 0; i < text.fragments.length; i++) {
            final fragment = text.fragments[i];
            // PDFium text boxes use unrotated PDF coordinates, whereas page
            // width/height and rendering already include the PDF /Rotate flag.
            final bounds = fragment.bounds.rotate(
              pdfPage.rotation.index,
              pdfPage,
            );
            final region = _region(
              bounds.left / pdfPage.width,
              1 - bounds.top / pdfPage.height,
              bounds.right / pdfPage.width,
              1 - bounds.bottom / pdfPage.height,
            );
            if (region != null && fragment.text.trim().isNotEmpty) {
              fragments.add(
                Evidence(
                  id: '${record.id}:$page:t$i',
                  documentId: record.id,
                  documentHash: record.contentHash,
                  page: page,
                  region: region,
                  text: fragment.text.trim(),
                ),
              );
            }
          }
          if (_canCommit(record, page, revision)) {
            await replacePage(record, page, text.fullText, fragments);
          }
          return;
        }
      }
      if (!_canCommit(record, page, revision)) return;
      // Existing searchable text remains available while an explicit OCR
      // refresh is running or fails.
      if (previous?.status != PageStatus.ready) {
        store.savePage(
          PageRecord(
            documentId: record.id,
            page: page,
            status: PageStatus.needsOcr,
          ),
        );
      }
      final availability = await ocr.availability();
      if (!_canCommit(record, page, revision)) return;
      if (!availability.available) {
        store.savePage(
          (previous ?? PageRecord(documentId: record.id, page: page)).copyWith(
            status: previous?.status == PageStatus.ready
                ? PageStatus.ready
                : PageStatus.needsOcr,
            error: availability.message,
          ),
        );
        return;
      }
      final raster = await renderPageForIndex(document, page);
      if (!_canCommit(record, page, revision)) return;
      final cache = _managedDirectory('cache', record.id);
      await cache.create(recursive: true);
      final imageFile = File(p.join(cache.path, 'ocr-$page-${_uuid.v4()}.png'));
      await imageFile.writeAsBytes(raster.bytes, flush: true);
      try {
        final result = await ocr.recognizeImage(imageFile.path);
        final evidence = <Evidence>[];
        for (var i = 0; i < result.blocks.length; i++) {
          final block = result.blocks[i];
          final region = _region(
            block.left,
            block.top,
            block.right,
            block.bottom,
          );
          if (region != null && block.text.trim().isNotEmpty) {
            evidence.add(
              Evidence(
                id: '${record.id}:$page:o$i',
                documentId: record.id,
                documentHash: record.contentHash,
                page: page,
                region: region,
                text: block.text,
                origin: EvidenceOrigin.ocr,
                confidence: block.confidence,
              ),
            );
          }
        }
        if (_canCommit(record, page, revision)) {
          await replacePage(
            record,
            page,
            result.text,
            evidence,
            preserveManual: !forceOcr,
          );
        }
      } finally {
        if (await imageFile.exists()) await imageFile.delete();
      }
    } catch (error) {
      if (_canCommit(record, page, revision)) {
        store.savePage(
          (previous ?? PageRecord(documentId: record.id, page: page)).copyWith(
            status: previous?.status == PageStatus.ready
                ? PageStatus.ready
                : PageStatus.failed,
            error: error.toString(),
          ),
        );
      }
    }
  }

  Future<void> replacePage(
    DocumentRecord record,
    int page,
    String text,
    List<Evidence> evidence, {
    bool preserveManual = true,
    bool manuallyCorrected = false,
  }) async {
    if (preserveManual &&
        store.getPage(record.id, page)?.manuallyCorrected == true) {
      return;
    }
    store.savePageWithEvidence(
      PageRecord(
        documentId: record.id,
        page: page,
        text: text,
        status: manuallyCorrected || text.trim().isNotEmpty
            ? PageStatus.ready
            : PageStatus.needsOcr,
        manuallyCorrected: manuallyCorrected,
      ),
      evidence,
      preserveManual: preserveManual,
    );
  }

  Future<void> correctPage(
    DocumentRecord doc,
    int page,
    String text,
    SourceRegion region,
  ) async {
    final key = _pageKey(doc.id, page);
    _pageRevisions[key] = (_pageRevisions[key] ?? 0) + 1;
    await replacePage(
      doc,
      page,
      text,
      text.trim().isEmpty
          ? []
          : [
              Evidence(
                id: '${doc.id}:$page:manual',
                documentId: doc.id,
                documentHash: doc.contentHash,
                page: page,
                region: region,
                text: text,
                origin: EvidenceOrigin.manual,
              ),
            ],
      preserveManual: false,
      manuallyCorrected: true,
    );
  }

  Future<void> delete(DocumentRecord record) async {
    // Validate the ID before changing database state or constructing a path.
    _managedDirectory('documents', record.id);
    _deletedDocuments.add(record.id);
    store.setSetting('pending-delete:${record.id}', 'true');
    final operations = _indexOperations[record.id];
    if (operations != null) {
      await Future.wait(
        operations.toList().map((task) => task.catchError((Object _) {})),
      );
    }
    store.deleteDocument(record.id);
    await _finishDeletion(record.id);
  }

  /// First phase of a permanent purge: stop background writes and record the
  /// intent so a crash between the database transaction and file deletion is
  /// repaired on the next launch. The database rows are removed by the caller.
  Future<void> preparePurge(String documentId) async {
    _managedDirectory('documents', documentId);
    _deletedDocuments.add(documentId);
    store.setSetting('pending-delete:$documentId', 'true');
    final operations = _indexOperations[documentId];
    if (operations != null) {
      await Future.wait(
        operations.toList().map((task) => task.catchError((Object _) {})),
      );
    }
  }

  /// Second phase: release the managed copy and render cache. Only paths inside
  /// the app's own directory are ever constructed here.
  Future<void> finishPurge(DocumentRecord record) async {
    _deletedDocuments.add(record.id);
    await _finishDeletion(record.id);
  }

  /// After a restore on another machine or after the managed directory moved,
  /// database rows can still point at the old absolute path. This rebuilds the
  /// path from the stable document id when the managed copy exists locally.
  Future<int> repairManagedPaths() async {
    var repaired = 0;
    for (final document in store.getDocuments(includeTrashed: true)) {
      var extension = p.extension(document.filePath).toLowerCase();
      if (extension.isEmpty && document.format.isNotEmpty) {
        extension = '.${document.format.toLowerCase()}';
      }
      final expected = p.join(
        directory.path,
        'documents',
        document.id,
        'original$extension',
      );
      if (p.equals(p.normalize(expected), p.normalize(document.filePath))) {
        continue;
      }
      if (!await File(expected).exists()) continue;
      store.saveDocumentRecord(document.copyWith(filePath: expected));
      repaired++;
    }
    return repaired;
  }

  /// Incomplete filesystem deletions are retried on the next app launch.
  Future<void> recoverPendingDeletions() async {
    for (final key in store.getSettings(prefix: 'pending-delete:').keys) {
      final id = key.substring('pending-delete:'.length);
      _managedDirectory('documents', id);
      _deletedDocuments.add(id);
      store.deleteDocument(id);
      await _finishDeletion(id);
    }
    // Empty import staging folders left by a cancelled batch are safe to drop;
    // the managed originals live in `documents/` and are never touched here.
  }

  Future<void> _finishDeletion(String id) async {
    // Each target is an exact child of the managed app directory. The
    // external file originally selected by the user is never referenced.
    await _deleteManagedDirectory('documents', id);
    await _deleteManagedDirectory('cache', id);
    store.deleteSetting('pending-delete:$id');
    _indexOperations.remove(id);
    _pageRevisions.removeWhere((key, _) => key.startsWith('$id:'));
  }

  Directory _managedDirectory(String category, String id) {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(id)) {
      throw ArgumentError('Invalid managed document id.');
    }
    final root = p.normalize(p.absolute(directory.path));
    final target = p.normalize(p.join(root, category, id));
    if (!p.isWithin(root, target)) {
      throw ArgumentError('Managed path escapes the app directory.');
    }
    return Directory(target);
  }

  Future<void> _deleteManagedDirectory(String category, String id) async {
    final target = _managedDirectory(category, id);
    if (!await target.exists()) return;
    final rootPath = await directory.resolveSymbolicLinks();
    final targetPath = await target.resolveSymbolicLinks();
    if (!p.isWithin(rootPath, targetPath) ||
        await FileSystemEntity.type(target.path, followLinks: false) ==
            FileSystemEntityType.link) {
      throw FileSystemException(
        'Refusing to delete a linked path outside managed data.',
        target.path,
      );
    }
    await target.delete(recursive: true);
  }

  static bool _usableText(String text) {
    final meaningful = text.replaceAll(
      RegExp(r'[\s\d\p{P}]', unicode: true),
      '',
    );
    final broken = '�'.allMatches(text).length;
    return meaningful.length >= 12 && broken / math.max(1, text.length) < .05;
  }

  static SourceRegion? _region(
    double left,
    double top,
    double right,
    double bottom,
  ) {
    final l = math.min(left, right).clamp(0.0, 1.0);
    final r = math.max(left, right).clamp(0.0, 1.0);
    final t = math.min(top, bottom).clamp(0.0, 1.0);
    final b = math.max(top, bottom).clamp(0.0, 1.0);
    if (r - l < .0001 || b - t < .0001) return null;
    return SourceRegion(l, t, r, b);
  }
}

/// The bytes displayed in the confirmation are the bytes sent to the provider.
Future<Uint8List> cropPage(RenderedPage page, SourceRegion region) async {
  final codec = await ui.instantiateImageCodec(page.bytes);
  final frame = await codec.getNextFrame();
  final source = frame.image;
  final width = math.max(1, (source.width * region.width).round());
  final height = math.max(1, (source.height * region.height).round());
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawImageRect(
    source,
    ui.Rect.fromLTRB(
      source.width * region.left,
      source.height * region.top,
      source.width * region.right,
      source.height * region.bottom,
    ),
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint(),
  );
  final picture = recorder.endRecording();
  final cropped = await picture.toImage(width, height);
  try {
    final data = await cropped.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  } finally {
    source.dispose();
    codec.dispose();
    cropped.dispose();
    picture.dispose();
  }
}
