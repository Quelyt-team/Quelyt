import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

class LocalDiskSpace {
  static const _android = MethodChannel('quelyt/android_platform');

  static Future<int?> available(Directory directory) async {
    var current = directory.absolute;
    while (!await current.exists()) {
      final parent = current.parent;
      if (parent.path == current.path) return null;
      current = parent;
    }
    if (Platform.isAndroid) {
      try {
        return await _android.invokeMethod<int>('availableBytes', {
          'path': current.path,
        });
      } on PlatformException {
        return null;
      } on MissingPluginException {
        return null;
      }
    }
    if (!Platform.isWindows) return null;
    return using((memory) {
      final path = current.path.toNativeUtf16(allocator: memory);
      final result = memory<ffi.Uint64>();
      return _windowsFreeSpace(path, result, ffi.nullptr, ffi.nullptr) != 0
          ? result.value
          : null;
    });
  }

  static final _windowsFreeSpace = ffi.DynamicLibrary.open('kernel32.dll')
      .lookupFunction<
        ffi.Int32 Function(
          ffi.Pointer<Utf16>,
          ffi.Pointer<ffi.Uint64>,
          ffi.Pointer<ffi.Uint64>,
          ffi.Pointer<ffi.Uint64>,
        ),
        int Function(
          ffi.Pointer<Utf16>,
          ffi.Pointer<ffi.Uint64>,
          ffi.Pointer<ffi.Uint64>,
          ffi.Pointer<ffi.Uint64>,
        )
      >('GetDiskFreeSpaceExW');

  static Future<void> require(
    Directory directory,
    int bytes,
    String operation,
  ) async {
    final free = await available(directory);
    if (free != null && bytes > free) {
      throw FileSystemException(
        '$operation需要约 ${(bytes / 1048576).ceil()} MiB，可用 ${free ~/ 1048576} MiB。',
      );
    }
  }
}
