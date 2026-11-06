import 'package:flutter/material.dart';

import '../../core/local_store.dart';

enum PageTone { normal, sepia, inverted }

/// UI-only preferences. Kept separate from [StudyController] so reading data,
/// AI payloads and citation coordinates are never affected by appearance.
class AppearanceController extends ChangeNotifier {
  AppearanceController(this._store) {
    themeMode = _themeFrom(_store.getSetting(_themeKey));
    pageTone = _toneFrom(_store.getSetting(_toneKey));
    readerHintSeen = _store.getSetting(_hintKey) == '1';
  }

  static const _themeKey = 'ui.theme';
  static const _toneKey = 'ui.pageTone';
  static const _hintKey = 'ui.readerHintSeen';

  final LocalStore _store;

  ThemeMode themeMode = ThemeMode.system;
  PageTone pageTone = PageTone.normal;
  bool readerHintSeen = false;

  void setThemeMode(ThemeMode value) {
    if (themeMode == value) return;
    themeMode = value;
    _write(_themeKey, value.name);
    notifyListeners();
  }

  void setPageTone(PageTone value) {
    if (pageTone == value) return;
    pageTone = value;
    _write(_toneKey, value.name);
    notifyListeners();
  }

  void markReaderHintSeen() {
    if (readerHintSeen) return;
    readerHintSeen = true;
    _write(_hintKey, '1');
    notifyListeners();
  }

  /// Lets settings make the reader hint appear again.
  void resetReaderHint() {
    if (!readerHintSeen) return;
    readerHintSeen = false;
    _write(_hintKey, '0');
    notifyListeners();
  }

  /// Only the rendered pixels are filtered. Selection and citation rectangles
  /// remain in original-page coordinates and are unaffected.
  ColorFilter? get pageFilter => switch (pageTone) {
    PageTone.normal => null,
    PageTone.sepia => const ColorFilter.mode(
      Color(0xFFFFF1D0),
      BlendMode.multiply,
    ),
    PageTone.inverted => const ColorFilter.matrix(<double>[
      -1, 0, 0, 0, 255,
      0, -1, 0, 0, 255,
      0, 0, -1, 0, 255,
      0, 0, 0, 1, 0,
    ]),
  };

  void _write(String key, String value) {
    try {
      _store.setSetting(key, value);
    } catch (_) {
      // Appearance is best-effort UI state; a closed store must not crash the
      // app during shutdown or widget-test teardown.
    }
  }

  static ThemeMode _themeFrom(String? value) => switch (value) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  static PageTone _toneFrom(String? value) => switch (value) {
    'sepia' => PageTone.sepia,
    'inverted' => PageTone.inverted,
    _ => PageTone.normal,
  };
}
