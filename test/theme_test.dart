import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:local_study/ui/bootstrap_error.dart';
import 'package:local_study/ui/shell/app_shell.dart';
import 'package:local_study/ui/theme/app_theme.dart';
import 'package:local_study/ui/theme/tokens.dart';
import 'package:local_study/ui/widgets/quelyt_mark.dart';

double _linear(double channel) => channel <= .03928
    ? channel / 12.92
    : math.pow((channel + .055) / 1.055, 2.4).toDouble();

double _luminance(Color color) =>
    .2126 * _linear(color.r) +
    .7152 * _linear(color.g) +
    .0722 * _linear(color.b);

double contrast(Color foreground, Color background) {
  final a = _luminance(foreground);
  final b = _luminance(background);
  final lighter = math.max(a, b);
  final darker = math.min(a, b);
  return (lighter + .05) / (darker + .05);
}

void main() {
  for (final (name, colors) in [
    ('light', AppColors.light),
    ('dark', AppColors.dark),
  ]) {
    group('$name palette contrast', () {
      void passes(String label, Color foreground, Color background) {
        final ratio = contrast(foreground, background);
        expect(
          ratio,
          greaterThanOrEqualTo(4.5),
          reason:
              '$label: ${ratio.toStringAsFixed(2)}:1 is below WCAG AA 4.5:1',
        );
      }

      test('body and secondary copy keep AA contrast on every surface', () {
        for (final surface in [
          colors.canvas,
          colors.surface,
          colors.surfaceRaised,
          colors.tint,
          colors.sidebar,
          colors.pageStage,
        ]) {
          passes('ink on surface', colors.ink, surface);
          passes('inkMuted on surface', colors.inkMuted, surface);
        }
      });

      test('action, warning and error colours keep AA contrast', () {
        passes('primary on surface', colors.primary, colors.surface);
        passes('onPrimary on primary', colors.onPrimary, colors.primary);
        passes('warm on warmTint', colors.warm, colors.warmTint);
        passes('warm on surface', colors.warm, colors.surface);
        passes('danger on dangerTint', colors.danger, colors.dangerTint);
        passes('danger on surface', colors.danger, colors.surface);
        passes('inkMuted on warmTint', colors.inkMuted, colors.warmTint);
        passes('inkMuted on dangerTint', colors.inkMuted, colors.dangerTint);
        passes('brand secondary on canvas', colors.brand, colors.canvas);
        passes('brand secondary on surface', colors.brand, colors.surface);
        passes('brand secondary on sidebar', colors.brand, colors.sidebar);
      });

      test('semantic icon accents keep AA on their chips and surfaces', () {
        for (final (name, accent, tint) in [
          ('blue', colors.blue, colors.blueTint),
          ('green', colors.green, colors.greenTint),
          ('violet', colors.violet, colors.violetTint),
          ('warm', colors.warm, colors.warmTint),
        ]) {
          passes('$name on tint', accent, tint);
          passes('$name on surface', accent, colors.surface);
          passes('inkMuted on $name tint', colors.inkMuted, tint);
        }
      });
    });
  }

  test('dark tile app icon colours meet WCAG AA contrast', () {
    const tileBg = Color(0xFF18181B);
    const tileSecondary = Color(0xFFA1A1AA);
    expect(contrast(Colors.white, tileBg), greaterThanOrEqualTo(4.5));
    expect(contrast(tileSecondary, tileBg), greaterThanOrEqualTo(4.5));
  });

  testWidgets('QuelytMark and BrandMark render vector geometry across modes', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: lightTheme,
        darkTheme: darkTheme,
        themeMode: ThemeMode.light,
        home: const Scaffold(
          body: Column(
            children: [
              BrandMark(),
              QuelytMark(size: 20),
              QuelytMark(size: 36, monochrome: true),
              QuelytMark(size: 32, watermark: true),
              QuelytMark(size: 40, tile: true),
            ],
          ),
        ),
      ),
    );

    final wordmarkPaint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(QuelytWordmark),
        matching: find.byType(CustomPaint),
      ),
    );
    expect(wordmarkPaint.painter, isA<QuelytWordmarkPainter>());

    final markPainters = tester
        .widgetList<CustomPaint>(
          find.descendant(
            of: find.byType(QuelytMark),
            matching: find.byType(CustomPaint),
          ),
        )
        .map((w) => w.painter! as QuelytMarkPainter)
        .toList();
    expect(markPainters, hasLength(4));
    // size 20 -> compact optical variant
    expect(markPainters[0].compact, isTrue);
    expect(markPainters[0].ink, AppColors.light.ink);
    expect(markPainters[0].brand, AppColors.light.brand);
    // size 36 monochrome -> ink == brand
    expect(markPainters[1].compact, isFalse);
    expect(markPainters[1].ink, AppColors.light.ink);
    expect(markPainters[1].brand, AppColors.light.ink);
    // watermark -> subtle monochrome zinc tones
    expect(markPainters[2].ink, const Color(0xFFD4D4D8));
    expect(markPainters[2].brand, const Color(0xFFE4E4E7));
    // dark tile -> white folio + #A1A1AA secondary on #18181B
    expect(markPainters[3].tile, isTrue);
    expect(markPainters[3].ink, Colors.white);
    expect(markPainters[3].brand, const Color(0xFFA1A1AA));
  });

  testWidgets(
    'BootstrapErrorApp uses monochrome QuelytMark without brand red',
    (tester) async {
      await tester.pumpWidget(
        BootstrapErrorApp(error: StateError('disk locked')),
      );
      await tester.pumpAndSettle();
      final mark = tester.widget<QuelytMark>(find.byType(QuelytMark));
      expect(mark.monochrome, isTrue);
      expect(find.text('Quelyt'), findsOneWidget);
    },
  );

  test('theme carries tokens and the agreed typographic floor', () {
    final theme = lightTheme;
    expect(theme.extension<AppColors>(), isNotNull);
    expect(theme.textTheme.bodyMedium!.fontSize, greaterThanOrEqualTo(13));
    expect(theme.textTheme.bodySmall!.fontSize, greaterThanOrEqualTo(12));
    expect(theme.textTheme.titleLarge!.fontSize, greaterThanOrEqualTo(18));
    expect(theme.textTheme.headlineMedium!.fontSize, greaterThanOrEqualTo(24));
    expect(
      theme.filledButtonTheme.style!.minimumSize!.resolve({}),
      const Size(0, 38),
    );
    expect(
      theme.cardTheme.shape,
      isA<RoundedRectangleBorder>().having(
        (shape) => shape.borderRadius,
        'radius',
        BorderRadius.circular(Radii.md),
      ),
    );
  });
}
