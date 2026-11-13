import 'package:path/path.dart' as p;

/// Per-item state of the shared import queue. OCR is a separate post-import
/// state: "imported" only means the managed copy and the database row exist.
enum ImportItemStatus {
  waiting('等待'),
  scanning('扫描'),
  copying('复制'),
  verifying('校验'),
  existing('已存在'),
  imported('已入库'),
  unsupported('不支持'),
  failed('失败'),
  cancelled('已取消'),
  interrupted('待继续');

  const ImportItemStatus(this.label);
  final String label;

  bool get isTerminal =>
      this == imported ||
      this == existing ||
      this == unsupported ||
      this == failed ||
      this == cancelled;

  bool get isSuccess => this == imported || this == existing;
}

class ImportBatch {
  ImportBatch({
    required this.id,
    required this.targetFolderId,
    required this.createdAt,
    required this.items,
    this.rootFolderName,
    this.keepStructure = true,
  });

  final String id;
  final String? targetFolderId;
  final DateTime createdAt;
  final List<ImportItem> items;

  /// When a directory was dropped, the new folder created for it. Imported
  /// files are placed inside it, mirroring their relative directories.
  String? rootFolderName;
  final bool keepStructure;

  int get total => items.length;
  int get imported => items.where((e) => e.status == ImportItemStatus.imported).length;
  int get existing =>
      items.where((e) => e.status == ImportItemStatus.existing).length;
  int get failed => items
      .where(
        (e) =>
            e.status == ImportItemStatus.failed ||
            e.status == ImportItemStatus.unsupported,
      )
      .length;
  int get finished => items.where((e) => e.status.isTerminal).length;
  bool get active => items.any((e) => !e.status.isTerminal);

  int get bytesTotal =>
      items.fold(0, (sum, item) => sum + item.bytesTotal);
  int get bytesDone => items.fold(0, (sum, item) => sum + item.bytesDone);
}

/// A queued file. Mutable on purpose: the queue updates one item at a time and
/// notifies listeners instead of rebuilding the whole batch around immutable
/// copies of progress counters.
class ImportItem {
  ImportItem({
    required this.id,
    required this.batchId,
    required this.sourcePath,
    required this.sourceName,
    required this.extension,
    required this.createdAt,
    this.targetFolderId,
    this.relativeDirectory = '',
    this.status = ImportItemStatus.waiting,
    this.bytesTotal = 0,
    this.bytesDone = 0,
    this.documentId,
    this.error,
    this.message,
    this.stagedPath,
  });

  final String id;
  final String batchId;
  final String sourcePath;

  /// Original file name including the extension, kept for metadata search and
  /// duplicate explanations.
  final String sourceName;
  final String extension;
  final DateTime createdAt;
  String? targetFolderId;

  /// Directory path relative to the dropped folder, used to mirror structure.
  final String relativeDirectory;

  ImportItemStatus status;
  int bytesTotal;
  int bytesDone;
  String? documentId;
  String? error;
  String? message;

  /// Complete staged copy inside the app's import area. A restart can finish
  /// this item without reading the source again.
  String? stagedPath;

  DateTime updatedAt = DateTime.now();

  String get displayDirectory =>
      relativeDirectory.isEmpty ? '' : p.posix.normalize(relativeDirectory);

  String get title => p.basenameWithoutExtension(sourceName);

  double get progress {
    if (bytesTotal <= 0) return status == ImportItemStatus.imported ? 1 : 0;
    return (bytesDone / bytesTotal).clamp(0.0, 1.0);
  }
}

/// Preview shown before a dropped directory is queued. Scanning is bounded and
/// does not follow links; unsupported files remain listed with a reason.
class DirectoryScan {
  const DirectoryScan({
    required this.rootName,
    this.files = const [],
    this.unsupported = const [],
    this.unreadable = const [],
    this.truncated = false,
  });

  final String rootName;
  final List<ScannedFile> files;
  final List<ScannedFile> unsupported;
  final List<String> unreadable;
  final bool truncated;

  int get totalBytes => files.fold(0, (sum, file) => sum + file.sizeBytes);
}

class ScannedFile {
  const ScannedFile({
    required this.path,
    required this.name,
    required this.extension,
    required this.sizeBytes,
    required this.relativeDirectory,
  });

  final String path;
  final String name;
  final String extension;
  final int sizeBytes;
  final String relativeDirectory;
}
