import 'dart:io';

/// Opens a file manager at [path]. Export/backup report paths are directories,
/// so they are opened directly; passing [select] reveals a file in its parent.
abstract final class FileReveal {
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
    throw UnsupportedError('Revealing files is not supported on this platform.');
  }
}
