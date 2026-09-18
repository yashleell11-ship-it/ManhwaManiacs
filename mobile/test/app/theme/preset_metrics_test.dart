import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/app/theme/app_spacing.dart';
import 'package:manhwamaniacs/app/theme/app_theme.dart';

import '../../support/wcag_contrast.dart';

/// The preset system's two promises, made mechanical.
///
/// 1. Colour and shape stay orthogonal — a preset never names a [Color], which
///    is what lets any of the fifteen palettes pair with any of the five
///    presets. A preset that started carrying colour would silently defeat the
///    palette contrast suite, because contrast would stop being a property of
///    the theme alone.
/// 2. Signature is the regression bar: byte-identical to the app that shipped
///    before presets existed.
void main() {
  group('orthogonality: presets hold shape, never colour', () {
    test('no preset field is a Color, at any depth', () {
      // Reflection is not available here, so this is the structural version of
      // the same check: the bundle is walked by hand and every leaf asserted
      // to be a number, a bool, a Duration or an enum. Adding a Color to
      // AppMetrics means adding it here too, which is the point — the
      // reviewer has to say out loud that colour moved axis.
      for (final p in AppPresets.all) {
        final leaves = <Object?>[
          ...p.space.steps,
          ...p.radii.steps,
          p.radii.pill,
          p.radii.full,
          p.strokes.border,
          p.strokes.focus,
          p.strokes.divider,
          p.surfaces.treatment,
          p.surfaces.blurSigma,
          p.surfaces.chromeBlurSigma,
          p.surfaces.panelOpacity,
          p.surfaces.chromeOpacity,
          p.surfaces.cardOpacity,
          p.surfaces.gradientCards,
          p.surfaces.glowAlpha,
          p.surfaces.cardBorderIsStrong,
          p.layout.seriesLayout,
          p.layout.gridColumnBias,
          p.layout.gridAspectRatio,
          p.layout.cardDetail,
          p.motion.scale,
          p.motion.scrollReveal,
          p.motion.pressScale,
          p.reader.autoHideAfter,
          p.reader.surfaceOpacity,
        ];
        for (final leaf in leaves) {
          expect(leaf, isNot(isA<Color>()), reason: '${p.id} leaked a colour');
        }
      }
    });

    test('no preset text style carries a colour', () {
      // Text colour is applied at the TextTheme level from the palette, the
      // same way AppTypography has always left it null.
      for (final p in AppPresets.all) {
        for (final style in p.text.all) {
          expect(style.color, isNull, reason: p.id);
        }
      }
    });

    test('every palette pairs with every preset', () {
      for (final palette in AppPalettes.all) {
        for (final preset in AppPresets.all) {
          final theme = AppTheme.fromPalette(palette, metrics: preset);
          expect(theme.extension<AppPalette>(), same(palette));
          expect(theme.extension<AppMetrics>(), same(preset));
          // Shape did not touch colour…
          expect(theme.scaffoldBackgroundColor, palette.bg);
          expect(theme.colorScheme.primary, palette.primary);
          // …and colour did not touch shape.
          expect(theme.dividerTheme.thickness, preset.strokes.divider);
        }
      }
    });
  });

  group('legibility floors survive every preset', () {
    test('no style drops below the minimum font size', () {
      for (final p in AppPresets.all) {
        for (final style in p.text.all) {
          expect(
            style.fontSize,
            greaterThanOrEqualTo(kMinPresetFontSize),
            reason: '${p.id} produced a ${style.fontSize}px step',
          );
        }
      }
    });

    test('body stays at least as large as the smallest label', () {
      // A preset may compress the scale; it may not invert it, which would put
      // running text below UI furniture.
      for (final p in AppPresets.all) {
        expect(
          p.text.body.fontSize,
          greaterThanOrEqualTo(p.text.caption.fontSize!),
          reason: p.id,
        );
        expect(
          p.text.h1.fontSize,
          greaterThan(p.text.body.fontSize!),
          reason: p.id,
        );
      }
    });

    test('spacing and radius scales stay monotonic', () {
      for (final p in AppPresets.all) {
        for (final steps in [p.space.steps, p.radii.steps]) {
          for (var i = 1; i < steps.length; i++) {
            expect(steps[i], greaterThanOrEqualTo(steps[i - 1]), reason: p.id);
          }
        }
      }
    });

    test('the fully-round tokens stay fully round', () {
      // An avatar or a progress rail that stops being circular reads as a bug,
      // not as a design position.
      for (final p in AppPresets.all) {
        expect(p.radii.pill, 999, reason: p.id);
        expect(p.radii.full, 9999, reason: p.id);
      }
    });

    test('motion is damped, never switched off', () {
      // "No animation at all" is the platform's reduce-motion flag to give,
      // not a preset's.
      for (final p in AppPresets.all) {
        expect(p.motion.scale, greaterThan(0), reason: p.id);
        expect(p.motion.pressScale, inInclusiveRange(0.9, 1.0), reason: p.id);
      }
    });
  });

  group('translucency never costs contrast', () {
    // The palette suite proves fg-on-surface clears the WCAG floors. A preset
    // that makes a surface see-through changes what is actually behind the
    // text, so the floors have to be re-checked on the *composited* result —
    // otherwise a preset could quietly undo the guarantee the theme tests
    // enforce without any of them failing.
    const bodyFloor = 4.5;
    const mutedFloor = 3.0;

    /// [over] seen through [surface] at [alpha].
    Color composite(Color surface, Color over, double alpha) => Color.from(
          alpha: 1,
          red: surface.r * alpha + over.r * (1 - alpha),
          green: surface.g * alpha + over.g * (1 - alpha),
          blue: surface.b * alpha + over.b * (1 - alpha),
        );

    test('panel, chrome and reader bars stay legible on every palette', () {
      for (final preset in AppPresets.all) {
        final alphas = {
          'panel': preset.surfaces.panelOpacity,
          'chrome': preset.surfaces.chromeOpacity,
          'reader bar': preset.reader.surfaceOpacity,
        };
        for (final palette in AppPalettes.all) {
          for (final entry in alphas.entries) {
            // These surfaces sit on the app background, which is the worst
            // realistic case for a dark-on-dark or light-on-light palette.
            final seen = composite(palette.surface, palette.bg, entry.value);
            expect(
              contrastRatio(palette.fg, seen),
              greaterThanOrEqualTo(bodyFloor),
              reason: '${preset.id} / ${palette.id}: body on ${entry.key} at '
                  '${entry.value}',
            );
            expect(
              contrastRatio(palette.muted, seen),
              greaterThanOrEqualTo(mutedFloor),
              reason: '${preset.id} / ${palette.id}: muted on ${entry.key} at '
                  '${entry.value}',
            );
          }
        }
      }
    });
  });

  group('Signature is the regression bar', () {
    final s = AppPresets.signature;

    test('is the default and comes first in the picker', () {
      expect(AppPresets.all.first, same(s));
      expect(AppPresets.byId(null), same(s));
      expect(AppPresets.byId('no_such_preset'), same(s));
    });

    test('spacing and radii are the shipped scale, value for value', () {
      expect(s.space.steps, [
        AppSpacing.xxs,
        AppSpacing.xs,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.xl,
        AppSpacing.xl2,
        AppSpacing.xl3,
        AppSpacing.xl4,
        AppSpacing.xl5,
        AppSpacing.xl6,
        AppSpacing.xl7,
      ]);
      expect(s.radii.steps, [
        AppRadius.xs,
        AppRadius.sm,
        AppRadius.md,
        AppRadius.lg,
        AppRadius.xl,
        AppRadius.xl2,
        AppRadius.xl3,
        AppRadius.xl4,
      ]);
    });

    test('typography is AppTypography untouched', () {
      expect(s.text.body.fontSize, AppTypography.body.fontSize);
      expect(s.text.body.height, AppTypography.body.height);
      expect(s.text.h1.fontSize, AppTypography.h1.fontSize);
      expect(s.text.h1.fontFamily, AppTypography.fontFamilyDisplay);
      expect(
        s.text.displayLg.letterSpacing,
        AppTypography.displayLg.letterSpacing,
      );
      expect(s.text.caption.fontSize, AppTypography.caption.fontSize);
      expect(s.text.mono.fontFamily, AppTypography.fontFamilyMono);
    });

    test('surfaces, layout, motion and reader chrome are the shipped values', () {
      expect(s.surfaces.treatment, SurfaceTreatment.glass);
      expect(s.surfaces.isGlass, isTrue);
      expect(s.surfaces.blurSigma, 16);
      // 8, lowered from 18 for scrolling: the nav bar floats over the list
      // (extendBody), so its BackdropFilter is re-read and re-blurred on every
      // frame the content moves under it, and blur cost is superlinear in
      // sigma. The float and the frosted look survive at 8.
      expect(s.surfaces.chromeBlurSigma, 8);
      expect(s.surfaces.panelOpacity, 0.7);
      // The shipped 8-bit alphas, exactly: withAlpha(217) on the nav bar
      // and withAlpha(184) on the reader's.
      expect(s.surfaces.chromeOpacity, 217 / 255);
      expect(s.reader.surfaceOpacity, 184 / 255);
      expect(s.surfaces.gradientCards, isTrue);
      expect(s.surfaces.glowAlpha, 28);
      expect(s.strokes.border, 1);
      expect(s.strokes.divider, 1);
      expect(s.layout.seriesLayout, SeriesLayout.grid);
      expect(s.layout.gridColumnBias, 0);
      expect(s.layout.gridAspectRatio, 0.52);
      expect(s.layout.cardDetail, CardDetail.standard);
      expect(s.motion.scale, 1);
      expect(s.motion.scrollReveal, isTrue);
      expect(s.motion.pressScale, 0.97);
      expect(s.reader.autoHideAfter, const Duration(milliseconds: 3000));
    });

    test('AppTheme.dark still builds on Signature', () {
      expect(AppTheme.dark.extension<AppMetrics>(), same(s));
    });
  });

  group('the four alternatives each take a distinct position', () {
    test('Matte drops glass entirely rather than turning it down', () {
      final m = AppPresets.matte;
      expect(m.surfaces.treatment, SurfaceTreatment.solid);
      expect(m.surfaces.isGlass, isFalse);
      expect(m.surfaces.isChromeGlass, isFalse);
      expect(m.surfaces.gradientCards, isFalse);
      expect(m.surfaces.glowAlpha, 0);
      expect(m.surfaces.cardBorderIsStrong, isTrue);
      // "The same density" — spacing is Signature's, only the surfaces change.
      expect(m.space, same(AppPresets.signature.space));
      expect(m.text, same(AppPresets.signature.text));
    });

    test('Compact is denser than Signature at every large step', () {
      final c = AppPresets.compact;
      final s = AppPresets.signature;
      for (final i in [4, 5, 6, 7, 8, 9, 10, 11]) {
        expect(c.space.steps[i], lessThan(s.space.steps[i]));
      }
      expect(c.text.body.fontSize, lessThan(s.text.body.fontSize!));
      expect(c.layout.seriesLayout, SeriesLayout.list);
      expect(c.layout.gridColumnBias, greaterThan(0));
      expect(c.layout.cardDetail, CardDetail.minimal);
      expect(c.text.h1.fontFamily, AppTypography.fontFamilyBody);
    });

    test('Editorial is roomier, larger and set in a system serif', () {
      final e = AppPresets.editorial;
      final s = AppPresets.signature;
      expect(e.space.xl2, greaterThan(s.space.xl2));
      expect(e.text.body.fontSize, greaterThan(s.text.body.fontSize!));
      expect(e.text.body.height, greaterThan(s.text.body.height!));
      expect(e.text.h1.fontFamily, kPresetSerifStack.first);
      expect(e.text.h1.fontFamilyFallback, kPresetSerifStack.sublist(1));
      // Bundling a serif would mean a new font asset; the phone's own faces
      // are the whole point of kPresetSerifStack.
      expect(kPresetSerifStack.last, 'serif');
      expect(e.layout.seriesLayout, SeriesLayout.list);
    });

    test('Cinema recedes: less chrome, bigger covers, less motion', () {
      final c = AppPresets.cinema;
      final s = AppPresets.signature;
      expect(c.surfaces.chromeOpacity, lessThan(s.surfaces.chromeOpacity));
      expect(c.reader.surfaceOpacity, lessThan(s.reader.surfaceOpacity));
      expect(c.reader.autoHideAfter, lessThan(s.reader.autoHideAfter));
      expect(c.motion.scale, lessThan(s.motion.scale));
      expect(c.motion.scrollReveal, isFalse);
      expect(c.layout.gridColumnBias, lessThan(0));
      expect(c.strokes.border, lessThan(s.strokes.border));
    });

    test('ids are unique and byId round-trips', () {
      final ids = AppPresets.all.map((p) => p.id).toSet();
      expect(ids.length, AppPresets.all.length);
      for (final p in AppPresets.all) {
        expect(AppPresets.byId(p.id), same(p));
      }
    });

    test('every preset states a name and a position', () {
      for (final p in AppPresets.all) {
        expect(p.name, isNotEmpty);
        expect(p.description, isNotEmpty);
      }
    });
  });

  group('column bias keeps every poster grid in step', () {
    test('bias applies then clamps to a readable cover', () {
      expect(AppPresets.signature.layout.columnsFor(3), 3);
      expect(AppPresets.compact.layout.columnsFor(3), 4);
      expect(AppPresets.cinema.layout.columnsFor(3), 2);
      // The clamp holds at both ends whatever the bias.
      expect(AppPresets.cinema.layout.columnsFor(2), 2);
      expect(AppPresets.compact.layout.columnsFor(6), 6);
    });
  });

  group('lerp', () {
    test('tweens the numbers and snaps the categories at the midpoint', () {
      final a = AppPresets.signature;
      final b = AppPresets.compact;

      final quarter = a.lerp(b, 0.25);
      expect(quarter.id, a.id);
      expect(quarter.layout.seriesLayout, a.layout.seriesLayout);
      expect(
        quarter.space.xl2,
        closeTo(a.space.xl2 + (b.space.xl2 - a.space.xl2) * 0.25, 1e-9),
      );

      final threeQuarters = a.lerp(b, 0.75);
      expect(threeQuarters.id, b.id);
      expect(threeQuarters.layout.seriesLayout, b.layout.seriesLayout);

      // The endpoints land exactly on the presets they name.
      expect(a.lerp(b, 1).space.xl2, b.space.xl2);
      expect(a.lerp(b, 0).space.xl2, a.space.xl2);
    });

    test('a foreign extension is ignored rather than crashing', () {
      expect(AppPresets.signature.lerp(null, 0.5), same(AppPresets.signature));
    });
  });

  group('context reads', () {
    testWidgets('resolve the installed preset', (tester) async {
      late AppMetrics seen;
      late double space;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.fromPalette(
            Base16Palettes.nord,
            metrics: AppPresets.compact,
          ),
          home: Builder(
            builder: (context) {
              seen = context.metrics;
              space = context.space.xl2;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(seen, same(AppPresets.compact));
      expect(space, AppPresets.compact.space.xl2);
    });

    testWidgets('fall back to Signature on a bare ThemeData', (tester) async {
      // Widget tests that pump a plain MaterialApp must keep rendering at the
      // shipped metrics, exactly as context.colors falls back to Eclipse.
      late AppMetrics seen;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(),
          home: Builder(
            builder: (context) {
              seen = context.metrics;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(seen, same(AppPresets.signature));
    });
  });
}
