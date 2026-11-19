import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';

import 'app_controller.dart';
import 'ui/bootstrap_error.dart';
import 'ui/study_app.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    for (final item in {
      'Tesseract / tessdata_fast': 'licenses/tesseract.txt',
      'Leptonica': 'licenses/leptonica.txt',
      'Tesseract4Android': 'licenses/tesseract4android.txt',
      'Charles Weld Tesseract runtime distribution':
          'licenses/charlesw-tesseract.txt',
      'Manrope Font': 'licenses/manrope.txt',
      'desktop_drop': 'licenses/desktop_drop.txt',
      'MathJax 3.2.2': 'licenses/MathJax-Apache-2.0.txt',
      'Noto Sans SC': 'licenses/NotoSansSC-OFL.txt',
    }.entries) {
      yield LicenseEntryWithLineBreaks([
        item.key,
      ], await rootBundle.loadString(item.value));
    }
  });
  try {
    await pdfrxFlutterInitialize();
    final directory = arguments
        .where((argument) => argument.startsWith('--data-directory='))
        .map((argument) => argument.substring('--data-directory='.length))
        .firstOrNull;
    if (directory != null && !p.isAbsolute(directory)) {
      throw const FormatException('资料库路径必须是绝对路径。');
    }
    final controller = await StudyController.create(
      dataDirectory: directory == null ? null : Directory(directory),
    );
    runApp(
      StudyApp(
        controller: controller,
        showWindowChrome: Platform.isWindows,
        showSplash: true,
      ),
    );
  } catch (error) {
    runApp(
      BootstrapErrorApp(error: error, showWindowChrome: Platform.isWindows),
    );
  }
}
