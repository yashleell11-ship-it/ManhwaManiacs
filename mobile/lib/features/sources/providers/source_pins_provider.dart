import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/core/logging/app_logger.dart';
import 'package:manhwamaniacs/features/auth/models/auth_state.dart';
import 'package:manhwamaniacs/features/auth/providers/auth_controller.dart';
import 'package:manhwamaniacs/features/profiles/providers/profiles_providers.dart';
import 'package:manhwamaniacs/features/sources/models/source_pin.dart';
import 'package:manhwamaniacs/features/sources/utils/source_pins_cache.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The server's cap on one scope's pins (`SourcePinService.MAX_PINS`). A
/// longer legacy list would be refused outright, so it is cut to fit.
const maxSourcePins = 50;

/// The pinned set plus whether it is safe to write back.
class SourcePinsState {
  const SourcePinsState({this.pins = const [], this.synced = false});

  final List<SourcePin> pins;

  /// True only when [pins] came from the server in the current scope.
  ///
  /// Load-bearing: the API replaces the *whole* set on every write, so a toggle
  /// built on a stale offline cache would delete pins the server holds and this
  /// device has never seen. [toggle] refuses to write until it has re-synced.
  final bool synced;

  List<String> get ids => [for (final pin in pins) pin.sourceId];

  bool contains(String sourceId) =>
      pins.any((pin) => pin.sourceId == sourceId);
}

/// Server-backed pinned sources for the active `(account, profile)` scope.
///
/// Deliberately NOT autoDispose — the Sources screen and the Search screen both
/// read it and toggling on one must be visible on the other without a refetch.
/// It rebuilds by itself whenever the signed-in user or the active profile
/// changes, so a new account can never render the previous one's pins even if a
/// caller forgets to invalidate it.
final sourcePinsProvider =
    AsyncNotifierProvider<SourcePinsNotifier, SourcePinsState>(
  SourcePinsNotifier.new,
  name: 'sourcePins',
);

/// Pinned connector ids, in display order. Convenience view for widgets that
/// only need "is this pinned?" and shouldn't rebuild on unrelated pin metadata.
final pinnedSourceIdsProvider = Provider<List<String>>(
  (ref) => ref.watch(sourcePinsProvider).valueOrNull?.ids ?? const [],
  name: 'pinnedSourceIds',
);

class SourcePinsNotifier extends AsyncNotifier<SourcePinsState> {
  String _cacheKey = sourcePinsCacheKeyFor(userId: null, profileId: null);
  bool _migrating = false;

  @override
  Future<SourcePinsState> build() async {
    final userId = ref.watch(
      authControllerProvider.select(
        (auth) => auth is AuthAuthenticated ? auth.user.id : null,
      ),
    );
    final profileId = ref.watch(activeProfileProvider.select((p) => p?.id));
    _cacheKey = sourcePinsCacheKeyFor(userId: userId, profileId: profileId);

    // No session, no pins — and no request that would only 401.
    if (userId == null) return const SourcePinsState();

    final prefs = ref.read(sharedPrefsProvider);
    final result = await ref.read(sourcesRepositoryProvider).listPins();

    if (result.isErr) {
      // Pins are a shortcut, not content: an offline launch shows the last
      // known order rather than an error panel over the whole Sources screen.
      // `synced: false` is what keeps that cache from being written back.
      appLogger.w('Failed to load source pins', result.error);
      return SourcePinsState(pins: readCachedSourcePins(prefs, _cacheKey));
    }

    final pins = await _migrateLegacyPins(prefs, serverPins: result.value);
    await writeCachedSourcePins(prefs, _cacheKey, pins);
    return SourcePinsState(pins: pins, synced: true);
  }

  /// Pin or unpin [sourceId], optimistically.
  ///
  /// [name]/[iconUrl] only dress the optimistic row until the server's own
  /// answer replaces it. Throws the [AppError] on failure after rolling the
  /// state back, so the caller can surface it.
  Future<void> toggle(
    String sourceId, {
    String? name,
    String? iconUrl,
    bool mature = false,
  }) async {
    var current = state.valueOrNull ?? const SourcePinsState();
    final repo = ref.read(sourcesRepositoryProvider);

    if (!current.synced) {
      final refreshed = await repo.listPins();
      if (refreshed.isErr) throw refreshed.error;
      current = SourcePinsState(pins: refreshed.value, synced: true);
      state = AsyncData(current);
    }

    final pinned = current.contains(sourceId);
    final next = pinned
        ? [
            for (final pin in current.pins)
              if (pin.sourceId != sourceId) pin,
          ]
        : [
            ...current.pins,
            SourcePin(
              sourceId: sourceId,
              sortOrder: current.pins.length,
              name: name ?? sourceId,
              iconUrl: iconUrl,
              mature: mature,
            ),
          ];

    state = AsyncData(SourcePinsState(pins: next, synced: true));

    final result = await repo.replacePins([for (final pin in next) pin.sourceId]);
    if (result.isErr) {
      state = AsyncData(current);
      throw result.error;
    }

    state = AsyncData(SourcePinsState(pins: result.value, synced: true));
    await writeCachedSourcePins(
      ref.read(sharedPrefsProvider),
      _cacheKey,
      result.value,
    );
  }

  Future<void> refresh() async {
    ref.invalidateSelf();
    await future;
  }

  /// One-shot lift of the old device-global `pinned_sources` list onto the
  /// server, for the first scope that reaches this code online.
  ///
  /// Gated on a persisted flag rather than on "the server list is empty" — the
  /// latter would re-seed every launch for a user who deliberately unpinned
  /// everything. The empty check below is only a don't-clobber guard for the
  /// single run the flag permits. Running it *after* a successful GET means an
  /// offline launch never burns the flag.
  ///
  /// The flag is only set once the server has taken the list, or once there is
  /// nothing left worth sending. The server holds no pin rows for this scope
  /// yet, so every legacy id is new to it, and one new id it cannot resolve
  /// makes it refuse the whole set. An old device list that still names a
  /// removed connector would otherwise take every other pin down with it. So
  /// ids the server no longer lists are dropped first, and a refusal leaves
  /// the legacy list in place for the next launch to try again.
  Future<List<SourcePin>> _migrateLegacyPins(
    SharedPreferences prefs, {
    required List<SourcePin> serverPins,
  }) async {
    if (sourcePinsMigrated(prefs) || _migrating) return serverPins;

    final legacy = readLegacyPinnedSources(prefs);
    if (legacy.isEmpty || serverPins.isNotEmpty) {
      await completeSourcePinsMigration(prefs);
      return serverPins;
    }

    // A rebuild (a profile switch) while the requests below are in flight must
    // not start a second migration into another scope.
    _migrating = true;
    try {
      final repo = ref.read(sourcesRepositoryProvider);

      final installed = await repo.listSources();
      if (installed.isErr) {
        appLogger.w(
          'Could not list sources; device pin migration retries next launch',
          installed.error,
        );
        return serverPins;
      }

      final known = {for (final source in installed.value) source.id};
      final ids = <String>[];
      for (final raw in legacy) {
        final id = raw.trim();
        if (known.contains(id) && !ids.contains(id)) ids.add(id);
        if (ids.length == maxSourcePins) break;
      }

      if (ids.isEmpty) {
        await completeSourcePinsMigration(prefs);
        return serverPins;
      }

      final migrated = await repo.replacePins(ids);
      if (migrated.isErr) {
        appLogger.w(
          'Server refused device pins; migration retries next launch',
          migrated.error,
        );
        return serverPins;
      }
      await completeSourcePinsMigration(prefs);
      return migrated.value;
    } finally {
      _migrating = false;
    }
  }
}
