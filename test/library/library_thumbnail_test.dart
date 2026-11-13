import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:local_study/core/local_store.dart';
import 'package:local_study/core/models.dart';
import 'package:local_study/features/library/services/library_thumbnail_service.dart';
import 'package:local_study/services/document_service.dart';
import 'package:local_study/services/ocr_service.dart';

Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 40, 60),
    ui.Paint()..color = const ui.Color(0xFF336699),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(40, 60);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late LocalStore store;
  late DocumentService documents;
  late LibraryThumbnailService thumbnails;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('library_thumb_');
    store = LocalStore.inMemory();
    documents = DocumentService(temp, store, OcrService());
    thumbnails = LibraryThumbnailService(documents: documents);
  });

  tearDown(() {
    store.dispose();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  Future<DocumentRecord> add(
    String id, {
    DocumentLifecycle lifecycle = DocumentLifecycle.active,
    bool missing = false,
  }) async {
    final bytes = await _png();
    final file = File(p.join(temp.path, '$id.png'));
    if (!missing) await file.writeAsBytes(bytes);
    final document = DocumentRecord(
      id: id,
      title: '封面 $id',
      kind: DocumentKind.unspecified,
      filePath: file.path,
      contentHash: sha256.convert(bytes).toString(),
      pageCount: 1,
      format: 'png',
      lifecycle: lifecycle,
      lifecycleVersion: lifecycle == DocumentLifecycle.active ? 1 : 2,
    );
    store.upsertDocument(document);
    return store.getDocument(id)!;
  }

  test('renders and reuses a cached first-page cover', () async {
    final document = await add('cover');
    final cover = await thumbnails.coverFor(document);
    expect(cover, isNotNull);
    expect(cover!.existsSync(), isTrue);
    expect(p.basename(cover.path), 'cover.png');
    expect(p.isWithin(p.join(temp.path, 'cache'), cover.path), isTrue);
    final bytes = await cover.readAsBytes();
    expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47], reason: 'PNG signature');
    final again = await thumbnails.coverFor(store.getDocument('cover')!);
    expect(again!.path, cover.path);
  });

  test('missing files and trashed documents fall back without a cover', () async {
    final missing = await add('missing', missing: true);
    expect(await thumbnails.coverFor(missing), isNull);
    final trashed = await add('trashed', lifecycle: DocumentLifecycle.trashed);
    expect(await thumbnails.coverFor(trashed), isNull);
    expect(await thumbnails.coverFor(trashed.copyWith(title: '改名')), isNull);
  });
}
