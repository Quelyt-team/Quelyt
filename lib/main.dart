import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'
    show LicenseEntryWithLineBreaks, LicenseRegistry;
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdfrx/pdfrx.dart';

import 'app_controller.dart';
import 'ui/bootstrap_error.dart';
import 'ui/study_app.dart';

Future<void> main() async {
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
    }.entries) {
      yield LicenseEntryWithLineBreaks([
        item.key,
      ], await rootBundle.loadString(item.value));
    }
  });
  try {
    await pdfrxFlutterInitialize();
    final controller = await StudyController.create();
    runApp(StudyApp(controller: controller, showWindowChrome: true));
  } catch (error) {
    runApp(BootstrapErrorApp(error: error, showWindowChrome: true));
  }
}
