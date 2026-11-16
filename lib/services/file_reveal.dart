import 'dart:io';

import 'platform_file_access.dart';

/// Opens a file manager on desktop platforms or delegates to Android SAF share /
/// external app intents through [PlatformFileAccess].
abstract final class FileReveal {
  static bool get canOpenFolder => PlatformFileAccess.instance.capabilities.openFolder;
  static bool get canShare => PlatformFileAccess.instance.capabilities.shareFile;
  static bool get canOpenExternal =>
      PlatformFileAccess.instance.capabilities.openExternal;

  static Future<void> open(String path, {bool select = false}) async {
    if (Platform.isWindows) {
      await Process.run(
        'explorer.exe',
        select ? ['/select,', path] : [path],
        runInShell: false,
      );
      return;
    }
    if (Platform.isMacOS) {
      await Process.run('open', select ? ['-R', path] : [path]);
      return;
    }
    if (Platform.isLinux) {
      await Process.run('xdg-open', [select ? File(path).parent.path : path]);
      return;
    }
    if (Platform.isAndroid) {
      final result = await PlatformFileAccess.instance.openExternal(path);
      if (!result.ok) {
        throw FileSystemException(result.error ?? '无法用其他应用打开该文件。', path);
      }
      return;
    }
    throw UnsupportedError('Revealing files is not supported on this platform.');
  }

  static Future<PlatformFileActionResult> share(
    String path, {
    String? mimeType,
    String title = '分享文件',
  }) => PlatformFileAccess.instance.shareFile(
    path,
    mimeType: mimeType,
    title: title,
  );

  static Future<PlatformFileActionResult> openExternal(
    String path, {
    String? mimeType,
  }) => PlatformFileAccess.instance.openExternal(path, mimeType: mimeType);
}
