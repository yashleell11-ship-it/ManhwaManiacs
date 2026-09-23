import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/app/app.dart';
import 'package:manhwamaniacs/core/config/env.dart';
import 'package:manhwamaniacs/core/config/startup_config.dart';
import 'package:manhwamaniacs/core/logging/app_logger.dart';
import 'package:manhwamaniacs/core/network/interceptors/app_version_interceptor.dart';
import 'package:manhwamaniacs/core/platform/system_ui.dart';
import 'package:manhwamaniacs/core/storage/preferences.dart';
import 'package:manhwamaniacs/core/storage/secure_storage.dart';
import 'package:manhwamaniacs/features/novels/utils/novel_audio_session.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // This build's version, for the X-App-Version header. Started here rather
  // than when the HTTP client is first built, so the platform has answered by
  // the time the first request goes out. Not awaited: a platform that never
  // answers must not hold up the first frame.
  startAppVersionLookup();

  // Three independent round trips, started together rather than chained.
  // None of them needs another's result, and all of them run before a single
  // frame can be scheduled — so serialising them was pure cold-start latency.
  // The secure-storage read is the expensive one: on Android that is
  // EncryptedSharedPreferences over the Keystore.
  //
  // Android: edge-to-edge with auto-hiding nav buttons (swipe up to reveal).
  // iOS: plain edge-to-edge — see `restingSystemUiMode` for why the immersive
  // modes are Android-only there.
  final systemUi = applyRestingSystemUiMode();
  final prefsLoad = SharedPreferences.getInstance();
  final storage = SecureStorageService();
  final savedApiUrl = storage.getApiUrl();

  final prefs = await prefsLoad;
  final preferences = PreferencesService(prefs);
  final apiUrl = await applyStartupConfig(
    storage: storage,
    preferences: preferences,
    savedUrl: savedApiUrl,
  );
  await systemUi;
  appLogger.i('API base URL: $apiUrl  flavor: ${Env.flavor}');

  // Narration is spoken word, not music: an interruption pauses the chapter
  // rather than talking over it. Not awaited — nothing plays before a reader
  // presses play, and a platform that refuses it must not delay first frame.
  unawaited(configureNovelAudioSession());

  runApp(
    ProviderScope(
      overrides: [
        apiBaseUrlProvider.overrideWith((ref) => apiUrl),
        sharedPrefsProvider.overrideWithValue(prefs),
      ],
      child: const ManhwaManiacsApp(),
    ),
  );
}