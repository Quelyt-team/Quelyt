import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:local_study/ui/icons/q_icons.dart';

/// Old Material glyphs for the signature icons, used by the before/after sheet.
const _before = <String, IconData>{
  'library': Icons.library_books_outlined,
  'schedule': Icons.calendar_month_outlined,
  'review': Icons.history_edu_outlined,
  'settings': Icons.tune_rounded,
  'textbook': Icons.menu_book_outlined,
  'paper': Icons.article_outlined,
  'study': Icons.auto_stories_outlined,
  'ai': Icons.auto_awesome_outlined,
  'anchor': Icons.link_rounded,
  'recall': Icons.psychology_alt_outlined,
  'qa': Icons.forum_outlined,
  'notes': Icons.edit_note_outlined,
  'verify': Icons.fact_check_outlined,
  'knowledge': Icons.account_tree_outlined,
  'billing': Icons.receipt_long_outlined,
  'milestone': Icons.flag_outlined,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Folio Line geometry', () {
    test('every icon has a unique name and is listed once', () {
      final names = QIcons.all.map((i) => i.name).toList();
      expect(names.toSet().length, names.length);
      expect(names.length, greaterThanOrEqualTo(60));
    });

    test('every shape parses and stays inside the 24 grid', () {
      for (final icon in QIcons.all) {
        for (final shape in icon.shapes) {
          final bounds = shape.path.getBounds();
          expect(bounds.isFinite, isTrue, reason: icon.name);
          expect(bounds.left, greaterThanOrEqualTo(1.5), reason: icon.name);
          expect(bounds.top, greaterThanOrEqualTo(1.5), reason: icon.name);
          expect(bounds.right, lessThanOrEqualTo(22.5), reason: icon.name);
          expect(bounds.bottom, lessThanOrEqualTo(22.5), reason: icon.name);
        }
      }
    });

    test('nav icons have an active weight', () {
      for (final icon in [
        QIcons.library,
        QIcons.schedule,
        QIcons.review,
        QIcons.textbook,
        QIcons.study,
      ]) {
        expect(icon.hasActiveWeight, isTrue, reason: icon.name);
      }
    });

    test('svg path parser handles relative, smooth and arc commands', () {
      final path = parseSvgPathData(
        'M2 2h4v4H2z m10 0c1 0 2 1 2 2s-1 2-2 2'
        'a2 2 0 1 1 0-4Q14 2 16 4T20 4',
      );
      final bounds = path.getBounds();
      expect(bounds.left, closeTo(2, .01));
      expect(bounds.right, greaterThan(19));
      expect(() => parseSvgPathData('M1 1z 2 2'), throwsFormatException);
    });

    test('stroke stays optically consistent across sizes', () {
      expect(QIcon.strokeFor(IconSizes.sm), closeTo(1.38, .01));
      expect(QIcon.strokeFor(IconSizes.md), closeTo(1.5, .01));
      expect(QIcon.strokeFor(IconSizes.lg), closeTo(1.62, .01));
      expect(QIcon.strokeFor(IconSizes.xl), 2.0);
    });

    test('lib/ contains zero Material Icons or Icon widget usages', () {
      final violations = <String>[];
      final pattern = RegExp(
        r'\bIcons\.|(?<![A-Za-z0-9_])Icon\(|(?<![A-Za-z0-9_])IconData\b|\bBackButton\b',
      );
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i].trimLeft();
          if (line.startsWith('//')) continue;
          if (pattern.hasMatch(line)) {
            violations.add('${entity.path}:${i + 1}: $line');
          }
        }
      }
      expect(violations, isEmpty, reason: violations.join('\n'));
    });
  });

  group('Folio Line preview', () {
    setUpAll(() async {
      if (Platform.isWindows) {
        final fontFile = File(r'C:\Windows\Fonts\msyh.ttc');
        if (fontFile.existsSync()) {
          final bytes = ByteData.sublistView(fontFile.readAsBytesSync());
          for (final family in const ['Roboto', 'Microsoft YaHei UI']) {
            final loader = FontLoader(family)
              ..addFont(Future<ByteData>.value(bytes));
            await loader.load();
          }
        }
      }
      final manrope = File('assets/brand/Manrope.ttf');
      if (manrope.existsSync()) {
        final loader = FontLoader('Manrope')
          ..addFont(
            Future<ByteData>.value(
              ByteData.sublistView(manrope.readAsBytesSync()),
            ),
          );
        await loader.load();
      }
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    });

    Future<void> capture(
      WidgetTester tester,
      GlobalKey key,
      String name,
    ) async {
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = File('build/preview/icons/$name.png');
        await output.parent.create(recursive: true);
        await output.writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }

    testWidgets('contact sheet', (tester) async {
      tester.view.physicalSize = const Size(1480, 1500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RepaintBoundary(
            key: key,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: const [
                Expanded(child: _Sheet(dark: false)),
                Expanded(child: _Sheet(dark: true)),
              ],
            ),
          ),
        ),
      );
      await capture(tester, key, 'folio_line_sheet');
    });

    testWidgets('before and after', (tester) async {
      tester.view.physicalSize = const Size(1000, 520);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      final byName = {for (final i in QIcons.all) i.name: i};
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RepaintBoundary(
            key: key,
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _Label('Before · Material', size: 13, strong: true),
                  const SizedBox(height: 12),
                  _CompareRow(
                    labels: _before.keys.toList(),
                    children: [
                      for (final e in _before.entries)
                        Icon(e.value, size: 20, color: const Color(0xFF65656D)),
                    ],
                  ),
                  const SizedBox(height: 28),
                  const _Label('After · Folio Line', size: 13, strong: true),
                  const SizedBox(height: 12),
                  _CompareRow(
                    labels: _before.keys.toList(),
                    children: [
                      for (final name in _before.keys)
                        QIcon(
                          byName[name],
                          size: 20,
                          color: const Color(0xFF65656D),
                        ),
                    ],
                  ),
                  const SizedBox(height: 28),
                  const _Label(
                    'Active weight · selected navigation',
                    size: 13,
                    strong: true,
                  ),
                  const SizedBox(height: 12),
                  _CompareRow(
                    labels: _before.keys.toList(),
                    children: [
                      for (final name in _before.keys)
                        QIcon(
                          byName[name],
                          size: 20,
                          active: true,
                          color: const Color(0xFF171717),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await capture(tester, key, 'folio_line_before_after');
    });
  });
}

class _Sheet extends StatelessWidget {
  const _Sheet({required this.dark});

  final bool dark;

  @override
  Widget build(BuildContext context) {
    final ink = dark ? const Color(0xFFECECEC) : const Color(0xFF0D0D0D);
    final muted = dark ? const Color(0xFFA1A1AA) : const Color(0xFF65656D);
    return Container(
      color: dark ? const Color(0xFF121212) : Colors.white,
      padding: const EdgeInsets.all(24),
      child: DefaultTextStyle(
        style: TextStyle(fontFamily: 'Manrope', fontSize: 10, color: muted),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Quelyt · Folio Line  ${dark ? 'dark' : 'light'}  '
              '(24 / 20 / 16 px)',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: ink,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 4,
              runSpacing: 10,
              children: [
                for (final icon in QIcons.all)
                  SizedBox(
                    width: 110,
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            QIcon(icon, size: IconSizes.lg, color: ink),
                            const SizedBox(width: 10),
                            QIcon(icon, size: IconSizes.md, color: ink),
                            const SizedBox(width: 10),
                            QIcon(icon, size: IconSizes.sm, color: muted),
                            if (icon.hasActiveWeight) ...[
                              const SizedBox(width: 10),
                              QIcon(
                                icon,
                                size: IconSizes.md,
                                color: ink,
                                active: true,
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(icon.name),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CompareRow extends StatelessWidget {
  const _CompareRow({required this.children, required this.labels});

  final List<Widget> children;
  final List<String> labels;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (var i = 0; i < children.length; i++)
        SizedBox(
          width: 58,
          child: Column(
            children: [
              children[i],
              const SizedBox(height: 6),
              _Label(labels[i], size: 9),
            ],
          ),
        ),
    ],
  );
}

class _Label extends StatelessWidget {
  const _Label(this.text, {required this.size, this.strong = false});

  final String text;
  final double size;
  final bool strong;

  @override
  Widget build(BuildContext context) => Text(
    text,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      fontFamily: 'Manrope',
      fontSize: size,
      fontWeight: strong ? FontWeight.w600 : FontWeight.w400,
      color: strong ? const Color(0xFF0D0D0D) : const Color(0xFF65656D),
    ),
  );
}
