import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Platform capabilities for file picking, external sharing and folder access.
class PlatformFileCapabilities {
  const PlatformFileCapabilities({
    required this.openFolder,
    required this.safTree,
    required this.safSaveAs,
    required this.shareFile,
    required this.openExternal,
    required this.incomingShare,
  });

  final bool openFolder;
  final bool safTree;
  final bool safSaveAs;
  final bool shareFile;
  final bool openExternal;
  final bool incomingShare;
}

class PlatformStagedFile {
  const PlatformStagedFile({
    required this.path,
    required this.name,
    this.relativePath = '',
    this.mime = '',
    this.sizeBytes = 0,
  });

  final String path;
  final String name;
  final String relativePath;
  final String mime;
  final int sizeBytes;

  factory PlatformStagedFile.fromMap(Map<Object?, Object?> map) =>
      PlatformStagedFile(
        path: map['path'] as String? ?? '',
        name: map['name'] as String? ?? '',
        relativePath: map['relativePath'] as String? ?? '',
        mime: map['mime'] as String? ?? '',
        sizeBytes: (map['sizeBytes'] as num?)?.toInt() ?? 0,
      );
}

class PlatformPickedTree {
  const PlatformPickedTree({
    required this.opId,
    required this.rootName,
    required this.stagingDirectory,
    required this.files,
    required this.unsupported,
    required this.unreadable,
    required this.truncated,
    required this.totalBytes,
  });

  final String opId;
  final String rootName;
  final String stagingDirectory;
  final List<PlatformStagedFile> files;
  final List<String> unsupported;
  final List<String> unreadable;
  final bool truncated;
  final int totalBytes;

  factory PlatformPickedTree.fromMap(Map<Object?, Object?> map) =>
      PlatformPickedTree(
        opId: map['opId'] as String? ?? '',
        rootName: map['rootName'] as String? ?? '导入文件夹',
        stagingDirectory: map['stagingDirectory'] as String? ?? '',
        files: [
          for (final item in (map['files'] as List<Object?>? ?? const []))
            if (item is Map<Object?, Object?>) PlatformStagedFile.fromMap(item),
        ],
        unsupported: [
          for (final item in (map['unsupported'] as List<Object?>? ?? const []))
            if (item is String) item,
        ],
        unreadable: [
          for (final item in (map['unreadable'] as List<Object?>? ?? const []))
            if (item is String) item,
        ],
        truncated: map['truncated'] == true,
        totalBytes: (map['totalBytes'] as num?)?.toInt() ?? 0,
      );
}

class PlatformIncomingShare {
  const PlatformIncomingShare({
    required this.opId,
    required this.action,
    required this.stagingDirectory,
    required this.items,
    required this.rejected,
  });

  final String opId;
  final String action;
  final String stagingDirectory;
  final List<PlatformStagedFile> items;
  final List<String> rejected;

  factory PlatformIncomingShare.fromMap(Map<Object?, Object?> map) =>
      PlatformIncomingShare(
        opId: map['opId'] as String? ?? '',
        action: map['action'] as String? ?? '',
        stagingDirectory: map['stagingDirectory'] as String? ?? '',
        items: [
          for (final item in (map['items'] as List<Object?>? ?? const []))
            if (item is Map<Object?, Object?>) PlatformStagedFile.fromMap(item),
        ],
        rejected: [
          for (final item in (map['rejected'] as List<Object?>? ?? const []))
            if (item is String) item,
        ],
      );
}

class PlatformSaveResult {
  const PlatformSaveResult({
    required this.saved,
    this.cancelled = false,
    this.bytes = 0,
    this.displayName,
    this.error,
  });

  final bool saved;
  final bool cancelled;
  final int bytes;
  final String? displayName;
  final String? error;

  factory PlatformSaveResult.fromMap(Map<Object?, Object?> map) =>
      PlatformSaveResult(
        saved: map['saved'] == true,
        cancelled: map['cancelled'] == true,
        bytes: (map['bytes'] as num?)?.toInt() ?? 0,
        displayName: map['displayName'] as String?,
        error: map['error'] as String?,
      );
}

class PlatformFileActionResult {
  const PlatformFileActionResult({
    required this.ok,
    this.code,
    this.error,
  });

  final bool ok;
  final String? code;
  final String? error;

  factory PlatformFileActionResult.fromMap(Map<Object?, Object?> map) =>
      PlatformFileActionResult(
        ok: map['ok'] == true,
        code: map['code'] as String?,
        error: map['error'] as String?,
      );
}

/// Abstract platform file boundary separating external content URIs (Android
/// SAF / incoming share intents / FileProvider) from Quelyt's managed internal
/// storage paths.
class PlatformFileAccess {
  PlatformFileAccess({
    MethodChannel? channel,
    EventChannel? eventChannel,
    this.isAndroidOverride,
    this.isDesktopOverride,
  }) : _channel = channel ?? const MethodChannel('quelyt/android_platform'),
       _eventChannel =
           eventChannel ?? const EventChannel('quelyt/android_platform/events');

  static PlatformFileAccess instance = PlatformFileAccess();

  final MethodChannel _channel;
  final EventChannel _eventChannel;
  final bool? isAndroidOverride;
  final bool? isDesktopOverride;

  bool get isAndroid => isAndroidOverride ?? (!kIsWeb && Platform.isAndroid);
  bool get isDesktop =>
      isDesktopOverride ??
      (!kIsWeb &&
          (Platform.isWindows || Platform.isMacOS || Platform.isLinux));

  PlatformFileCapabilities get capabilities => PlatformFileCapabilities(
    openFolder: isDesktop,
    safTree: isAndroid,
    safSaveAs: isAndroid,
    shareFile: isAndroid,
    openExternal: isAndroid,
    incomingShare: isAndroid,
  );

  /// Stream of incoming share/view batches staged cleanly into managed cache.
  Stream<PlatformIncomingShare> get incomingShares {
    if (!capabilities.incomingShare) {
      return const Stream<PlatformIncomingShare>.empty();
    }
    return _eventChannel
        .receiveBroadcastStream()
        .where((event) => event is Map<Object?, Object?>)
        .map(
          (event) =>
              PlatformIncomingShare.fromMap(event as Map<Object?, Object?>),
        );
  }

  /// Drains incoming share batches received during cold start before UI mount.
  Future<List<PlatformIncomingShare>> consumePendingShares() async {
    if (!capabilities.incomingShare) return const [];
    try {
      final raw = await _channel.invokeListMethod<Object?>(
        'consumePendingShares',
      );
      if (raw == null) return const [];
      return [
        for (final item in raw)
          if (item is Map<Object?, Object?>)
            PlatformIncomingShare.fromMap(item),
      ];
    } on MissingPluginException {
      return const [];
    }
  }

  /// Launches Android SAF document tree picker and copies supported study files
  /// via ContentResolver streams into an isolated staging directory.
  Future<PlatformPickedTree?> pickDirectoryAndStage({int maxFiles = 5000}) async {
    if (!capabilities.safTree) return null;
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'pickDirectoryAndStage',
        {'maxFiles': maxFiles},
      );
      if (raw == null) return null;
      return PlatformPickedTree.fromMap(raw);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      throw FileSystemException(error.message ?? '系统目录选择失败');
    }
  }

  /// Launches Android ACTION_CREATE_DOCUMENT ("Save to...") and streams
  /// [sourcePath] to the user-chosen external document URI.
  Future<PlatformSaveResult> saveFileToUserLocation({
    required String sourcePath,
    required String fileName,
    String mimeType = 'application/octet-stream',
  }) async {
    if (!capabilities.safSaveAs) {
      return const PlatformSaveResult(
        saved: false,
        error: '当前平台不使用系统文档保存器。',
      );
    }
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'saveFileToUserLocation',
        {
          'sourcePath': sourcePath,
          'fileName': fileName,
          'mimeType': mimeType,
        },
      );
      if (raw == null) {
        return const PlatformSaveResult(saved: false, cancelled: true);
      }
      return PlatformSaveResult.fromMap(raw);
    } on MissingPluginException {
      return const PlatformSaveResult(
        saved: false,
        error: '系统文件保存服务不可用。',
      );
    } on PlatformException catch (error) {
      return PlatformSaveResult(
        saved: false,
        error: error.message ?? '保存到系统位置失败。',
      );
    }
  }

  Future<PlatformFileActionResult> shareFile(
    String path, {
    String? mimeType,
    String title = '分享文件',
  }) async {
    if (!capabilities.shareFile) {
      return const PlatformFileActionResult(
        ok: false,
        code: 'unsupported',
        error: '当前平台暂不支持系统分享面板。',
      );
    }
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'shareFile',
        {
          'path': path,
          'mimeType': ?mimeType,
          'title': title,
        },
      );
      if (raw == null) {
        return const PlatformFileActionResult(ok: false, error: '分享未响应。');
      }
      return PlatformFileActionResult.fromMap(raw);
    } on MissingPluginException {
      return const PlatformFileActionResult(
        ok: false,
        code: 'unavailable',
        error: '系统分享服务不可用。',
      );
    } on PlatformException catch (error) {
      return PlatformFileActionResult(
        ok: false,
        code: error.code,
        error: error.message ?? '分享失败。',
      );
    }
  }

  Future<PlatformFileActionResult> openExternal(
    String path, {
    String? mimeType,
  }) async {
    if (!capabilities.openExternal) {
      return const PlatformFileActionResult(
        ok: false,
        code: 'unsupported',
        error: '当前平台不支持外部应用打开。',
      );
    }
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>(
        'openFileExternally',
        {
          'path': path,
          'mimeType': ?mimeType,
        },
      );
      if (raw == null) {
        return const PlatformFileActionResult(ok: false, error: '未能打开外部应用。');
      }
      return PlatformFileActionResult.fromMap(raw);
    } on MissingPluginException {
      return const PlatformFileActionResult(
        ok: false,
        code: 'unavailable',
        error: '系统外部打开服务不可用。',
      );
    } on PlatformException catch (error) {
      return PlatformFileActionResult(
        ok: false,
        code: error.code,
        error: error.message ?? '外部应用打开失败。',
      );
    }
  }

  Future<void> cleanupStagedDirectory(String path) async {
    if (!isAndroid || path.trim().isEmpty) return;
    try {
      await _channel.invokeMethod<void>('cleanupStagedDirectory', {
        'path': path,
      });
    } catch (_) {
      // Best-effort staging cleanup.
    }
  }
}
