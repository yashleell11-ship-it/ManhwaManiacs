import 'package:flutter/material.dart';
import 'package:manhwamaniacs/app/theme/app_metrics.dart';
import 'package:manhwamaniacs/app/theme/app_spacing.dart';

/// The five design presets — the app's *shape* registry, sibling to
/// `AppPalettes`.
///
/// Each is a coherent position rather than a row of sliders: pick one and the
/// density, corner radius, surface treatment, type scale, layout defaults,
/// motion and reader chrome all move together. None of them names a colour;
/// that stays the theme's job, so every preset works under all fifteen
/// palettes.
///
/// Naming note: the spec called the default preset "Eclipse", but the default
/// *palette* is already called Eclipse and having "Theme: Eclipse / Design:
/// Eclipse" in one Settings pane makes the two axes look like one setting.
/// The default preset is therefore **Signature** — the house look — and the
/// remaining names say what position each takes rather than which knob moved.
abstract final class AppPresets {
  /// Reader bars for the presets that have no translucency anywhere else:
  /// opaque, at Signature's 3s auto-hide. A solid preset that left its
  /// reader chrome see-through would be advertising one position and
  /// shipping another.
  static const AppReaderChrome _solidReaderChrome = AppReaderChrome(
    autoHideAfter: Duration(milliseconds: 3000),
    surfaceOpacity: 1,
  );

  /// The shipped look, unchanged and the default.
  ///
  /// Every value here is the pre-preset constant, token for token. The
  /// spacing and radius steps are *read from* [AppSpacing] and [AppRadius]
  /// rather than retyped, so the shipped scale and the default preset cannot
  /// drift apart — the handful of layout-math sites that still need
  /// compile-time constants (sliver header extents, the reader's scroll
  /// geometry) keep measuring the same app this preset draws. The rest —
  /// blur 16 at 70% surface, the untouched [AppTypography] steps, the poster
  /// grid at 0.52, the 0.97 press, the 3s reader auto-hide — is pinned by
  /// `preset_metrics_test.dart` so a future preset edit cannot quietly
  /// redecorate the app the owner actually uses.
  static final AppMetrics signature = AppMetrics(
    id: 'signature',
    name: 'Signature',
    description: 'Frosted glass, generous spacing, poster-led browse.',
    space: const AppSpacingScale(
      xxs: AppSpacing.xxs,
      xs: AppSpacing.xs,
      sm: AppSpacing.sm,
      md: AppSpacing.md,
      lg: AppSpacing.lg,
      xl: AppSpacing.xl,
      xl2: AppSpacing.xl2,
      xl3: AppSpacing.xl3,
      xl4: AppSpacing.xl4,
      xl5: AppSpacing.xl5,
      xl6: AppSpacing.xl6,
      xl7: AppSpacing.xl7,
    ),
    radii: const AppRadiusScale(
      xs: AppRadius.xs,
      sm: AppRadius.sm,
      md: AppRadius.md,
      lg: AppRadius.lg,
      xl: AppRadius.xl,
      xl2: AppRadius.xl2,
      xl3: AppRadius.xl3,
      xl4: AppRadius.xl4,
    ),
    strokes: const AppStrokes(border: 1, focus: 1.5, divider: 1),
    surfaces: const AppSurfaceStyle(
      treatment: SurfaceTreatment.glass,
      blurSigma: 16,
      // 8, not 18: the nav bar floats over the list (extendBody), so its
      // BackdropFilter is re-read and re-blurred every frame the content moves
      // under it, and blur cost is superlinear in sigma. At 8 the float and the
      // frosted look survive; at 18 scrolling paid for them continuously.
      chromeBlurSigma: 8,
      panelOpacity: 0.7,
      // Stated as the exact 8-bit fraction the nav bar shipped with
      // (withAlpha(217)) so Signature stays byte-identical.
      chromeOpacity: 217 / 255,
      cardOpacity: 1,
      gradientCards: true,
      glowAlpha: 28,
      cardBorderIsStrong: false,
    ),
    text: AppTextStyles.resolve(const AppTypeScale()),
    layout: const AppLayoutDefaults(
      seriesLayout: SeriesLayout.grid,
      gridColumnBias: 0,
      gridAspectRatio: 0.52,
      cardDetail: CardDetail.standard,
    ),
    motion: const AppMotion(scale: 1, scrollReveal: true, pressScale: 0.97),
    reader: const AppReaderChrome(
      autoHideAfter: Duration(milliseconds: 3000),
      // withAlpha(184), the reader bar's shipped alpha, exactly.
      surfaceOpacity: 184 / 255,
    ),
  );

  /// Solid ink instead of glass, at Signature's density.
  ///
  /// The blur is not turned down, it is turned off — [AppSurfaceStyle.isGlass]
  /// is false, so the [BackdropFilter] and its saveLayer never enter the tree.
  /// The edges a panel used to imply with translucency it now states with a
  /// hairline, so radii tighten and card borders go to full strength.
  static final AppMetrics matte = AppMetrics(
    id: 'matte',
    name: 'Matte',
    description: 'No blur or translucency. Solid surfaces, crisp hairlines.',
    space: signature.space,
    radii: const AppRadiusScale(
      xs: 3,
      sm: 4,
      md: 6,
      lg: 8,
      xl: 12,
      xl2: 16,
      xl3: 20,
      xl4: 28,
    ),
    strokes: const AppStrokes(border: 1, focus: 2, divider: 1),
    surfaces: const AppSurfaceStyle(
      treatment: SurfaceTreatment.solid,
      blurSigma: 0,
      chromeBlurSigma: 0,
      panelOpacity: 1,
      chromeOpacity: 1,
      cardOpacity: 1,
      gradientCards: false,
      glowAlpha: 0,
      cardBorderIsStrong: true,
    ),
    text: signature.text,
    layout: const AppLayoutDefaults(
      seriesLayout: SeriesLayout.grid,
      gridColumnBias: 0,
      gridAspectRatio: 0.52,
      cardDetail: CardDetail.standard,
    ),
    motion: const AppMotion(scale: 0.65, scrollReveal: false, pressScale: 0.99),
    reader: _solidReaderChrome,
  );

  /// Density first: more rows per screen, list-led browse.
  ///
  /// The rhythm tightens where the padding actually is — the large steps — and
  /// leaves the 2px hairline gaps alone, because halving those buys nothing
  /// and costs legibility. Headings drop to the body face: Syne is
  /// characterful and wide, which is the opposite of what a scannable list
  /// wants.
  static final AppMetrics compact = AppMetrics(
    id: 'compact',
    name: 'Compact',
    description: 'Density first — tighter rhythm, list-led browse.',
    space: const AppSpacingScale(
      xxs: 2,
      xs: 3,
      sm: 6,
      md: 9,
      lg: 12,
      xl: 14,
      xl2: 16,
      xl3: 22,
      xl4: 28,
      xl5: 32,
      xl6: 44,
      xl7: 56,
    ),
    radii: const AppRadiusScale(
      xs: 3,
      sm: 5,
      md: 8,
      lg: 10,
      xl: 14,
      xl2: 18,
      xl3: 24,
      xl4: 32,
    ),
    strokes: const AppStrokes(border: 1, focus: 1.5, divider: 0.5),
    surfaces: const AppSurfaceStyle(
      treatment: SurfaceTreatment.solid,
      blurSigma: 0,
      chromeBlurSigma: 0,
      panelOpacity: 1,
      chromeOpacity: 1,
      cardOpacity: 1,
      gradientCards: false,
      glowAlpha: 0,
      cardBorderIsStrong: false,
    ),
    text: AppTextStyles.resolve(
      const AppTypeScale(
        sizeScale: 0.92,
        lineHeightScale: 0.94,
        headingFace: AppHeadingFace.body,
      ),
    ),
    layout: const AppLayoutDefaults(
      seriesLayout: SeriesLayout.list,
      gridColumnBias: 1,
      gridAspectRatio: 0.58,
      cardDetail: CardDetail.minimal,
    ),
    motion: const AppMotion(scale: 0.7, scrollReveal: true, pressScale: 0.98),
    reader: _solidReaderChrome,
  );

  /// Typography-led: a system serif for headings, wide margins, metadata over
  /// artwork.
  ///
  /// The serif comes from the phone, never from a download — see
  /// [kPresetSerifStack]. Weight drops to w600 because a book face at w700 at
  /// these sizes reads as shouting rather than as a title.
  static final AppMetrics editorial = AppMetrics(
    id: 'editorial',
    name: 'Editorial',
    description: 'Serif headings, wide margins, metadata over artwork.',
    space: const AppSpacingScale(
      xxs: 2,
      xs: 4,
      sm: 8,
      md: 12,
      lg: 18,
      xl: 24,
      xl2: 32,
      xl3: 44,
      xl4: 56,
      xl5: 68,
      xl6: 88,
      xl7: 112,
    ),
    radii: const AppRadiusScale(
      xs: 2,
      sm: 4,
      md: 6,
      lg: 10,
      xl: 14,
      xl2: 18,
      xl3: 24,
      xl4: 32,
    ),
    strokes: const AppStrokes(border: 1, focus: 1.5, divider: 1),
    surfaces: const AppSurfaceStyle(
      treatment: SurfaceTreatment.solid,
      blurSigma: 0,
      chromeBlurSigma: 0,
      panelOpacity: 1,
      chromeOpacity: 1,
      cardOpacity: 1,
      gradientCards: false,
      glowAlpha: 0,
      cardBorderIsStrong: true,
    ),
    text: AppTextStyles.resolve(
      const AppTypeScale(
        sizeScale: 1.06,
        lineHeightScale: 1.12,
        headingFace: AppHeadingFace.serif,
        headingTracking: -0.2,
        headingWeight: FontWeight.w600,
      ),
    ),
    layout: const AppLayoutDefaults(
      seriesLayout: SeriesLayout.list,
      gridColumnBias: 0,
      gridAspectRatio: 0.56,
      cardDetail: CardDetail.standard,
    ),
    motion: const AppMotion(scale: 1, scrollReveal: true, pressScale: 0.98),
    reader: _solidReaderChrome,
  );

  /// Content-maximal: the chrome gets out of the way.
  ///
  /// Panels stay glass — they float over artwork here, and solid bars would
  /// occlude the thing being read — but thinner, quieter and more transparent.
  /// Motion is more than halved and the reader's bars retire in 1.2s rather
  /// than 3s.
  static final AppMetrics cinema = AppMetrics(
    id: 'cinema',
    name: 'Cinema',
    description: 'Chrome recedes. Covers and pages take the screen.',
    space: const AppSpacingScale(
      xxs: 2,
      xs: 4,
      sm: 7,
      md: 10,
      lg: 13,
      xl: 16,
      xl2: 18,
      xl3: 26,
      xl4: 32,
      xl5: 40,
      xl6: 52,
      xl7: 64,
    ),
    radii: const AppRadiusScale(
      xs: 4,
      sm: 6,
      md: 10,
      lg: 14,
      xl: 20,
      xl2: 26,
      xl3: 36,
      xl4: 52,
    ),
    strokes: const AppStrokes(border: 0.5, focus: 1, divider: 0.5),
    surfaces: const AppSurfaceStyle(
      treatment: SurfaceTreatment.glass,
      blurSigma: 12,
      // Same reason as Signature: a live backdrop under a scrolling list.
      chromeBlurSigma: 8,
      panelOpacity: 0.5,
      chromeOpacity: 0.62,
      cardOpacity: 1,
      gradientCards: false,
      glowAlpha: 0,
      cardBorderIsStrong: false,
    ),
    text: AppTextStyles.resolve(const AppTypeScale(sizeScale: 0.96)),
    layout: const AppLayoutDefaults(
      seriesLayout: SeriesLayout.grid,
      gridColumnBias: -1,
      gridAspectRatio: 0.5,
      cardDetail: CardDetail.minimal,
    ),
    motion: const AppMotion(scale: 0.45, scrollReveal: false, pressScale: 0.985),
    reader: const AppReaderChrome(
      autoHideAfter: Duration(milliseconds: 1200),
      surfaceOpacity: 0.55,
    ),
  );

  /// Picker order: the default first, then the four alternatives.
  static final List<AppMetrics> all = [
    signature,
    matte,
    compact,
    editorial,
    cinema,
  ];

  /// Resolve a persisted id; unknown/absent ids fall back to [signature] so a
  /// removed preset can never brick startup.
  static AppMetrics byId(String? id) {
    for (final preset in all) {
      if (preset.id == id) return preset;
    }
    return signature;
  }
}

/// The way widgets read the active preset: `context.space.lg`,
/// `context.radii.xl`, `context.text.body`, `context.surfaces.isGlass`.
///
/// Reading through [Theme.of] registers a dependency, so a preset switch
/// rebuilds every widget that measured with it — that, and nothing else, is
/// why changing the design does not need a restart. The fallback keeps widget
/// tests that pump a bare `MaterialApp(theme: ThemeData(...))` rendering at
/// the shipped metrics, exactly as `context.colors` falls back to Eclipse.
extension AppMetricsContext on BuildContext {
  AppMetrics get metrics =>
      Theme.of(this).extension<AppMetrics>() ?? AppPresets.signature;

  AppSpacingScale get space => metrics.space;

  AppRadiusScale get radii => metrics.radii;

  AppStrokes get strokes => metrics.strokes;

  AppSurfaceStyle get surfaces => metrics.surfaces;

  AppTextStyles get text => metrics.text;

  AppLayoutDefaults get layout => metrics.layout;

  AppMotion get motion => metrics.motion;

  AppReaderChrome get readerChrome => metrics.reader;
}
