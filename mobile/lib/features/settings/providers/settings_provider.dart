import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/core/network/base_url.dart';
import 'package:manhwamaniacs/core/network/dio_client.dart';
import 'package:manhwamaniacs/core/utils/haptics.dart';
import 'package:manhwamaniacs/features/collections/providers/collection_detail_provider.dart';
import 'package:manhwamaniacs/features/collections/providers/collections_provider.dart';
import 'package:manhwamaniacs/features/library/providers/bookmarks_provider.dart';
import 'package:manhwamaniacs/features/library/providers/dashboard_providers.dart';
import 'package:manhwamaniacs/features/library/providers/intelligence_providers.dart';
import 'package:manhwamaniacs/features/library/providers/library_list_provider.dart';
import 'package:manhwamaniacs/features/library/providers/series_detail_provider.dart';
import 'package:manhwamaniacs/features/ocr/providers/ocr_providers.dart';
import 'package:manhwamaniacs/features/settings/models/reader_defaults.dart';
import 'package:manhwamaniacs/features/settings/repositories/mature_settings_repository.dart';
import 'package:manhwamaniacs/features/settings/repositories/mature_settings_repository_impl.dart';
import 'package:manhwamaniacs/features/settings/services/image_cache_service.dart';
import 'package:manhwamaniacs/features/sources/providers/source_pins_provider.dart';
import 'package:manhwamaniacs/features/sources/providers/sources_provider.dart';
import 'package:manhwamaniacs/features/updates/providers/updates_provider.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:package_info_plus/package_info_plus.dart';

final settingsApiUrlProvider = FutureProvider.autoDispose<String>((ref) async {
  final storage = ref.watch(secureStorageProvider);
  final saved = await storage.getApiUrl();
  return saved ?? ref.watch(apiBaseUrlProvider);
});

// ── Mature content (per-profile) ───────────────────────────────────────────

final matureSettingsRepositoryProvider = Provider<MatureSettingsRepository>(
  (ref) => MatureSettingsRepositoryImpl(ref.watch(dioProvider)),
  name: 'matureSettingsRepository',
);

/// The active profile's `mature_content_enabled` flag, read from `GET /settings`
/// (scoped by the `X-Profile-Id` header). `autoDispose` and invalidated on a
/// profile switch (see `profileScopedInvalidators`), so it always reflects the
/// *current* profile's own value rather than a carried-over one.
final matureContentProvider =
    AsyncNotifierProvider.autoDispose<MatureContentController, bool>(
  MatureContentController.new,
  name: 'matureContent',
);

class MatureContentController extends AutoDisposeAsyncNotifier<bool> {
  @override
  Future<bool> build() async {
    final result =
        await ref.read(matureSettingsRepositoryProvider).getMatureEnabled();
    if (result.isErr) throw result.error;
    return result.value;
  }

  /// Persist [value] for the active profile. Optimistically flips the toggle so
  /// the switch responds instantly; rolls back and returns the [AppError] if the
  /// write fails.
  Future<AppError?> setEnabled(bool value) async {
    final previous = state.valueOrNull;
    state = AsyncData(value);
    final result =
        await ref.read(matureSettingsRepositoryProvider).setMatureEnabled(value);
    if (result.isErr) {
      state = AsyncData(previous ?? !value);
      return result.error;
    }
    state = AsyncData(result.value);
    // The mature gate decides which sources, browse rows and search results are
    // visible, so every cache that filters on it must be dropped to reflect the
    // new value (mirrors the web mutation invalidating those queries).
    for (final invalidate in matureScopedInvalidators) {
      invalidate(ref);
    }
    return null;
  }
}

/// Every backend service that filters on the 18+ gate, by module name.
///
/// The list below has to cover all of them, and the two drift apart silently:
/// the toggle keeps working on the surfaces it was last audited against while
/// the newest gated endpoint quietly keeps serving adult rows from cache.
/// `mature_invalidators_test.dart` reads the backend and fails when a service
/// starts importing `core.content_rating` without being added here, so the
/// next one cannot be added without a decision about its client caches.
const Set<String> kMatureGatedBackendServices = {
  'bookmark_service',
  'browse_service',
  'followed_series_service',
  'ocr_ingest_service',
  // Progress rows are written through the gate but no screen renders a list
  // from it: every surface that shows progress reads one of the others.
  'progress_service',
  'reading_stats_service',
  'source_cache_service',
  'source_pin_service',
  'update_service',
};

/// Caches whose contents depend on the active profile's mature-content gate.
/// Dropped after a successful toggle so every gated surface immediately
/// reflects the new value. Kept as a top-level list (mirroring
/// [metadataCacheInvalidators]) so the exact set is auditable and testable.
///
/// Wider than it looks like it needs to be, on purpose. The shell is a
/// `StatefulShellRoute.indexedStack`, so the Library tab stays mounted the
/// whole time the reader is in Settings and its `autoDispose` providers are
/// never torn down: without an explicit invalidation the shelf still holds
/// the adult covers the switch was just flipped to hide. Sources and search
/// updating while the shelf did not was worse than nothing — it read as
/// though the switch had been obeyed.
final List<void Function(Ref ref)> matureScopedInvalidators = [
  // Which sources appear (adult sources are hidden while the gate is off),
  // and which of them are pinned (source_pin_service).
  (ref) => ref.invalidate(sourcesListProvider),
  (ref) => ref.invalidate(sourcePinsProvider),
  // Per-source browse rows + their available browse modes (family, all args).
  (ref) => ref.invalidate(sourceBrowseProvider),
  (ref) => ref.invalidate(sourceBrowseModesProvider),
  // Library search results.
  (ref) => ref.invalidate(searchListProvider),
  // The followed shelf, its per-series pages, and the dashboard rails built
  // from the same gated service (followed_series_service).
  (ref) => ref.invalidate(libraryListProvider),
  (ref) => ref.invalidate(seriesDetailProvider),
  (ref) => ref.invalidate(continueReadingProvider),
  // Reading intelligence surfaces (reading_stats_service).
  (ref) => ref.invalidate(statisticsProvider),
  (ref) => ref.invalidate(recommendationsProvider),
  (ref) => ref.invalidate(readingHistoryProvider),
  // Bookmarks (bookmark_service).
  (ref) => ref.invalidate(bookmarksProvider),
  // Update notifications + the unread badge they drive (update_service).
  (ref) => ref.invalidate(updatesProvider),
  // Dialogue search and per-series coverage (ocr_ingest_service), families.
  (ref) => ref.invalidate(ocrSearchProvider),
  (ref) => ref.invalidate(ocrCoverageProvider),
  // Collections list only the series the gate allows through, because their
  // rows come from the same followed-series read.
  (ref) => ref.invalidate(collectionsProvider),
  (ref) => ref.invalidate(collectionDetailProvider),
];

// ── Theme ────────────────────────────────────────────────────────────────
// The old ThemeMode (system/light/dark) selector is gone: the multi-theme
// gallery owns the look now — see `app/theme/theme_controller.dart`.

// ── Language ─────────────────────────────────────────────────────────────

class LanguageController extends Notifier<AppLanguage> {
  @override
  AppLanguage build() =>
      AppLanguage.fromCode(ref.watch(preferencesProvider).language);

  Future<void> setLanguage(AppLanguage language) async {
    state = language;
    await ref.read(preferencesProvider).setLanguage(language.code);
  }
}

final languageProvider =
    NotifierProvider<LanguageController, AppLanguage>(LanguageController.new);

// ── Reader defaults ──────────────────────────────────────────────────────

class ReaderDefaultsController extends Notifier<ReaderDefaults> {
  @override
  ReaderDefaults build() {
    final prefs = ref.watch(preferencesProvider);
    return ReaderDefaults(
      direction: ReadingDirection.fromStorageValue(prefs.readingDirection),
      fitMode: ReaderFitMode.fromStorageValue(prefs.readerFitMode),
      keepScreenAwake: prefs.keepScreenAwake,
      autoNextChapter: prefs.autoNextChapter,
      lockControls: prefs.lockReaderControls,
      refreshRate: ReaderRefreshRate.fromStorageValue(prefs.readerRefreshRate),
      volumeKeyNavigation: prefs.volumeKeyNavigation,
      tapZones: TapZoneConfig.fromStorageValue(prefs.readerTapZones),
    );
  }

  Future<void> setDirection(ReadingDirection direction) async {
    state = state.copyWith(direction: direction);
    await ref.read(preferencesProvider).setReadingDirection(direction.name);
  }

  Future<void> setFitMode(ReaderFitMode fitMode) async {
    state = state.copyWith(fitMode: fitMode);
    await ref.read(preferencesProvider).setReaderFitMode(fitMode.name);
  }

  Future<void> setKeepScreenAwake(bool value) async {
    state = state.copyWith(keepScreenAwake: value);
    await ref.read(preferencesProvider).setKeepScreenAwake(value);
  }

  Future<void> setAutoNextChapter(bool value) async {
    state = state.copyWith(autoNextChapter: value);
    await ref.read(preferencesProvider).setAutoNextChapter(value);
  }

  Future<void> setLockControls(bool value) async {
    state = state.copyWith(lockControls: value);
    await ref.read(preferencesProvider).setLockReaderControls(value);
  }

  Future<void> setVolumeKeyNavigation(bool value) async {
    state = state.copyWith(volumeKeyNavigation: value);
    await ref.read(preferencesProvider).setVolumeKeyNavigation(value);
  }

  Future<void> setRefreshRate(ReaderRefreshRate rate) async {
    state = state.copyWith(refreshRate: rate);
    await ref.read(preferencesProvider).setReaderRefreshRate(rate.name);
  }

  /// Pass `null` to stop customising: the stored value is removed rather than
  /// overwritten with today's default, so the bands go back to following the
  /// reading direction and its right-to-left flip.
  Future<void> setTapZones(TapZoneConfig? config) async {
    final prefs = ref.read(preferencesProvider);
    if (config == null) {
      state = state.copyWith(clearTapZones: true);
      await prefs.clearReaderTapZones();
      return;
    }
    state = state.copyWith(tapZones: config);
    await prefs.setReaderTapZones(config.storageValue);
  }
}

final readerDefaultsProvider =
    NotifierProvider<ReaderDefaultsController, ReaderDefaults>(
  ReaderDefaultsController.new,
);

// ── Download preferences (client-side only; no backend field exists) ───────

class WifiOnlyDownloadsController extends Notifier<bool> {
  @override
  bool build() => ref.watch(preferencesProvider).wifiOnlyDownloads;

  Future<void> setEnabled(bool value) async {
    state = value;
    await ref.read(preferencesProvider).setWifiOnlyDownloads(value);
  }
}

final wifiOnlyDownloadsProvider =
    NotifierProvider<WifiOnlyDownloadsController, bool>(
  WifiOnlyDownloadsController.new,
);

// ── Haptic feedback (app-wide interaction preference) ──────────────────────

class HapticFeedbackController extends Notifier<bool> {
  @override
  bool build() => ref.watch(preferencesProvider).hapticFeedback;

  Future<void> setEnabled(bool value) async {
    state = value;
    await ref.read(preferencesProvider).setHapticFeedback(value);
  }
}

final hapticFeedbackProvider =
    NotifierProvider<HapticFeedbackController, bool>(
  HapticFeedbackController.new,
);

/// Resolved [Haptics] helper — muted automatically when the user turns
/// interaction feedback off. Read it fresh at each gesture with `ref.read`.
final hapticsProvider = Provider<Haptics>(
  (ref) => Haptics(enabled: ref.watch(hapticFeedbackProvider)),
  name: 'haptics',
);

// ── Cache ────────────────────────────────────────────────────────────────

final imageCacheServiceProvider = Provider<ImageCacheService>(
  (_) => const ImageCacheServiceImpl(),
  name: 'imageCacheService',
);

final cacheUsageProvider = FutureProvider.autoDispose<int>((ref) {
  return ref.watch(imageCacheServiceProvider).getCacheSizeBytes();
});

// ── About ────────────────────────────────────────────────────────────────

final packageInfoProvider = FutureProvider.autoDispose<PackageInfo>((ref) {
  return PackageInfo.fromPlatform();
});

// ── Actions ──────────────────────────────────────────────────────────────

class SettingsActions {
  SettingsActions(this.ref);

  final Ref ref;

  Future<AppError?> saveApiUrl(String url) async {
    final policyError = BaseUrl.validate(url);
    if (policyError != null) return policyError;
    final trimmed = url.trim();
    await ref.read(secureStorageProvider).setApiUrl(trimmed);
    ref.read(apiBaseUrlProvider.notifier).state = trimmed;
    ref.invalidate(dioProvider);
    ref.invalidate(settingsApiUrlProvider);
    return null;
  }

  Future<AppError?> validateAndSaveApiUrl(String url) async {
    // Enforce the https-in-release policy before touching the network.
    final policyError = BaseUrl.validate(url);
    if (policyError != null) return policyError;
    final trimmed = url.trim();

    final validationError = await ref.read(serverValidationProvider)(trimmed);
    if (validationError != null) return validationError;

    final saveError = await saveApiUrl(trimmed);
    if (saveError != null) return saveError;

    await ref.read(preferencesProvider).setSetupCompleted(true);
    return null;
  }

  Future<void> resetApiUrl() async {
    await ref.read(secureStorageProvider).clearApiUrl();
    ref.invalidate(settingsApiUrlProvider);
  }

  /// Clears every cached page/cover image on disk.
  Future<void> clearImageCache() async {
    await ref.read(imageCacheServiceProvider).clear();
    ref.invalidate(cacheUsageProvider);
  }

  /// Invalidates the in-memory library/reading metadata providers so the
  /// next visit to those screens refetches from the server. There is no
  /// persistent metadata store on the client to delete from disk — this
  /// only resets Riverpod's cached state.
  void clearMetadataCache() {
    for (final invalidate in metadataCacheInvalidators) {
      invalidate(ref);
    }
  }
}

final settingsActionsProvider = Provider<SettingsActions>(
  SettingsActions.new,
  name: 'settingsActions',
);

typedef ServerUrlValidator = Future<AppError?> Function(String url);

final serverValidationProvider = Provider<ServerUrlValidator>(
  (ref) => (url) async {
    final dio = createDioClient(baseUrl: url);
    try {
      await dio.get<Map<String, dynamic>>('/health');
      return null;
    } on DioException catch (e) {
      if (e.error is AppError) return e.error! as AppError;
      return NetworkError(message: e.message ?? 'Unable to reach server.');
    } catch (e) {
      return UnknownError(message: e.toString(), cause: e);
    }
  },
  name: 'serverValidation',
);

final setupCompletedProvider = Provider<bool>(
  (ref) => ref.watch(preferencesProvider).setupCompleted,
  name: 'setupCompleted',
);

/// Providers invalidated by [SettingsActions.clearMetadataCache], exposed
/// separately so tests can verify the exact set without invoking the whole
/// action.
///
/// Invalidates each top-level data provider directly rather than the shared
/// [libraryRepositoryProvider]: several of them (`bookmarksProvider`,
/// `libraryListProvider`) read the repository with `ref.read`, not
/// `ref.watch`, so invalidating only the repository would silently miss
/// them.
final List<void Function(Ref ref)> metadataCacheInvalidators = [
  (ref) => ref.invalidate(continueReadingProvider),
  (ref) => ref.invalidate(libraryListProvider),
  (ref) => ref.invalidate(searchListProvider),
  (ref) => ref.invalidate(statisticsProvider),
  (ref) => ref.invalidate(recommendationsProvider),
  (ref) => ref.invalidate(readingHistoryProvider),
  (ref) => ref.invalidate(bookmarksProvider),
  (ref) => ref.invalidate(updatesProvider),
];
