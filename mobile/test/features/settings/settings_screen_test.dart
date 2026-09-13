import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/app/theme/app_palettes.dart';
import 'package:manhwamaniacs/app/theme/app_palettes.generated.dart';
import 'package:manhwamaniacs/app/theme/app_presets.dart';
import 'package:manhwamaniacs/app/theme/preset_controller.dart';
import 'package:manhwamaniacs/app/theme/theme_controller.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/core/storage/secure_storage.dart';
import 'package:manhwamaniacs/core/utils/pagination.dart';
import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/library/models/collection.dart';
import 'package:manhwamaniacs/features/library/models/collection_detail.dart';
import 'package:manhwamaniacs/features/library/models/continue_reading_item.dart';
import 'package:manhwamaniacs/features/library/models/followed_series.dart';
import 'package:manhwamaniacs/features/library/models/library_list_state.dart';
import 'package:manhwamaniacs/features/library/models/library_statistics.dart';
import 'package:manhwamaniacs/features/library/models/reading_history_item.dart';
import 'package:manhwamaniacs/features/library/models/recommendation.dart';
import 'package:manhwamaniacs/features/library/models/series_detail.dart';
import 'package:manhwamaniacs/features/library/models/tag.dart';
import 'package:manhwamaniacs/features/library/providers/bookmarks_provider.dart';
import 'package:manhwamaniacs/features/library/providers/dashboard_providers.dart';
import 'package:manhwamaniacs/features/library/providers/intelligence_providers.dart';
import 'package:manhwamaniacs/features/library/providers/library_list_provider.dart';
import 'package:manhwamaniacs/features/library/repositories/library_repository.dart';
import 'package:manhwamaniacs/features/reader/models/bookmark.dart';
import 'package:manhwamaniacs/features/reader/models/chapter_manifest.dart';
import 'package:manhwamaniacs/features/reader/models/chapter_manifest_window.dart';
import 'package:manhwamaniacs/features/reader/models/reading_progress.dart';
import 'package:manhwamaniacs/features/reader/repositories/reader_repository.dart';
import 'package:manhwamaniacs/features/settings/models/app_version.dart';
import 'package:manhwamaniacs/features/settings/models/reader_defaults.dart';
import 'package:manhwamaniacs/features/settings/providers/app_update_provider.dart';
import 'package:manhwamaniacs/features/settings/providers/settings_provider.dart';
import 'package:manhwamaniacs/features/settings/repositories/mature_settings_repository.dart';
import 'package:manhwamaniacs/features/settings/screens/settings_screen.dart';
import 'package:manhwamaniacs/features/sources/models/source_search_group.dart';
import 'package:manhwamaniacs/features/updates/models/update_notification.dart';
import 'package:manhwamaniacs/features/updates/models/update_settings.dart';
import 'package:manhwamaniacs/features/updates/providers/updates_provider.dart';
import 'package:manhwamaniacs/features/updates/repositories/updates_repository.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../support/test_overrides.dart';

class _FakeSecureStorageService extends SecureStorageService {
  String? _storedUrl;

  @override
  Future<String?> getApiUrl() async => _storedUrl;

  @override
  Future<void> setApiUrl(String url) async {
    _storedUrl = url;
  }

  @override
  Future<void> clearApiUrl() async {
    _storedUrl = null;
  }
}

const _emptyLibraryStatistics = LibraryStatistics(
  followedTotal: 0,
  favorites: 0,
  byReadingStatus: {},
  chaptersCompleted: 0,
);

class _EmptyLibraryListNotifier extends LibraryListNotifier {
  @override
  Future<LibraryListState> build() async => const LibraryListState();
}

class _EmptySearchListNotifier extends SearchListNotifier {
  @override
  Future<GroupedSearchResult> build() async => const GroupedSearchResult();
}

class _EmptyBookmarksNotifier extends BookmarksNotifier {
  @override
  Future<BookmarksState> build() async => const BookmarksState(bookmarks: []);
}

class _EmptyUpdatesNotifier extends UpdatesNotifier {
  @override
  Future<UpdatesState> build() async => const UpdatesState(
        notifications: [],
        unreadCount: 0,
        followed: [],
      );
}

List<Override> _metadataCacheProviderOverrides() => [
      continueReadingProvider.overrideWith(
        (ref) async => const <ContinueReadingItem>[],
      ),
      libraryListProvider.overrideWith(_EmptyLibraryListNotifier.new),
      searchListProvider.overrideWith(_EmptySearchListNotifier.new),
      statisticsProvider.overrideWith((ref) async => _emptyLibraryStatistics),
      recommendationsProvider.overrideWith((ref) async => <RecommendationGenre>[]),
      readingHistoryProvider.overrideWith((ref) async => <ReadingHistoryItem>[]),
      bookmarksProvider.overrideWith(_EmptyBookmarksNotifier.new),
      updatesProvider.overrideWith(_EmptyUpdatesNotifier.new),
    ];

class _EmptyLibraryRepository implements LibraryRepository {
  @override
  Future<Result<PagedResult<FollowedSeries>>> listSeries({
    int page = 1,
    int perPage = 40,
    String? sort,
    String? search,
    String? readingStatus,
    bool? isFavorite,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<SeriesDetail>> getSeries(int followedId) => throw UnimplementedError();

  @override
  Future<Result<FollowedSeries>> follow({
    required String sourceId,
    required String seriesKey,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<void>> unfollow(int followedId) => throw UnimplementedError();

  @override
  Future<Result<FollowedSeries>> patchSeries(
    int followedId, {
    bool? isFavorite,
    String? readingStatus,
    bool? notify,
    bool? matureOverride,
    int? sortOrder,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<List<ContinueReadingItem>>> continueReading({int limit = 10}) =>
      throw UnimplementedError();

  @override
  Future<Result<List<FollowedSeries>>> recentlyUpdated({int limit = 10}) =>
      throw UnimplementedError();

  @override
  Future<Result<List<RecommendationGenre>>> recommendations({int limit = 10}) =>
      throw UnimplementedError();

  @override
  Future<Result<PagedResult<FollowedSeries>>> search(
    String query, {
    int page = 1,
    int perPage = 20,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<LibraryStatistics>> statistics() => throw UnimplementedError();

  @override
  Future<Result<List<ReadingHistoryItem>>> readingHistory({
    int limit = 50,
    int offset = 0,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<List<Collection>>> listCollections() => throw UnimplementedError();

  @override
  Future<Result<CollectionDetail>> getCollection(int collectionId) => throw UnimplementedError();

  @override
  Future<Result<Collection>> createCollection({
    required String name,
    String? description,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<Collection>> updateCollection(
    int collectionId, {
    String? name,
    String? description,
    int? sortOrder,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<void>> deleteCollection(int collectionId) => throw UnimplementedError();

  @override
  Future<Result<CollectionDetail>> addSeriesToCollection(
    int collectionId, {
    required String sourceId,
    required String seriesKey,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<void>> removeSeriesFromCollection(
    int collectionId, {
    required String sourceId,
    required String seriesKey,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<List<Tag>>> listTags({String? category}) => throw UnimplementedError();

  @override
  Future<Result<Tag>> createTag({
    required String name,
    String category = 'custom',
    String? color,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<void>> deleteTag(int tagId) => throw UnimplementedError();

  @override
  Future<Result<void>> addTagToSeries({
    required String sourceId,
    required String seriesKey,
    required int tagId,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<void>> removeTagFromSeries({
    required String sourceId,
    required String seriesKey,
    required int tagId,
  }) =>
      throw UnimplementedError();
}

class _EmptyReaderRepository implements ReaderRepository {
  @override
  Future<Result<List<Bookmark>>> listBookmarks({
    String? sourceId,
    String? seriesKey,
    DateTime? since,
    bool includeDeleted = false,
    int? limit,
  }) async =>
      const Ok([]);

  @override
  Future<Result<void>> deleteBookmark(int bookmarkId) => throw UnimplementedError();

  @override
  Future<Result<BookmarkSyncResult>> syncBookmarks(List<BookmarkOp> ops) =>
      throw UnimplementedError();

  @override
  Future<Result<ChapterManifest>> manifest({
    required String sourceId,
    required String seriesKey,
    required String chapterKey,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<ReadingProgress>> saveProgress(ProgressPush push) => throw UnimplementedError();

  @override
  Future<Result<({int saved, int advanced})>> saveProgressBatch(List<ProgressPush> pushes) =>
      throw UnimplementedError();

  @override
  Future<Result<List<ReadingProgress>>> seriesProgress({
    required String sourceId,
    required String seriesKey,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<ChapterManifestWindow>> manifestWindow({
    required String sourceId,
    required String seriesKey,
    required List<String> chapterKeys,
  }) =>
      throw UnimplementedError();
}

class _EmptyUpdatesRepository implements UpdatesRepository {
  @override
  Future<Result<List<UpdateNotification>>> listNotifications({
    bool unreadOnly = false,
    int limit = 100,
  }) async =>
      const Ok([]);

  @override
  Future<Result<int>> getUnreadCount() async => const Ok(0);

  @override
  Future<Result<void>> markRead(int notificationId) => throw UnimplementedError();

  @override
  Future<Result<void>> markAllRead() => throw UnimplementedError();

  @override
  Future<Result<UpdateSettings>> getSettings() => throw UnimplementedError();

  @override
  Future<Result<UpdateSettings>> updateSettings({
    bool? enabled,
    int? checkIntervalMinutes,
    bool? notifyEnabled,
    bool? checkOnStartup,
  }) =>
      throw UnimplementedError();

  @override
  Future<Result<List<UpdateRun>>> listRuns({int limit = 20}) => throw UnimplementedError();

  @override
  Future<Result<UpdateCheckOutcome>> triggerCheck({List<int>? followedIds}) =>
      throw UnimplementedError();

  @override
  Future<Result<UpdateRun>> checkFollowed(int followedId) => throw UnimplementedError();
}

final _testPackageInfo = PackageInfo(
  appName: 'ManhwaManiacs',
  packageName: 'com.manhwamaniacs.reader',
  version: '1.0.0',
  buildNumber: '1',
);

class _StubMatureRepo implements MatureSettingsRepository {
  @override
  Future<Result<bool>> getMatureEnabled() async => const Ok(false);

  @override
  Future<Result<bool>> setMatureEnabled(bool enabled) async => Ok(enabled);
}

/// Mature controller whose initial load always fails — used to prove the
/// Content section degrades to its own retry card rather than red-outing the
/// General tab.
class _ThrowingMatureController extends MatureContentController {
  @override
  Future<bool> build() async =>
      throw const UnknownError(message: 'boom');
}

Future<ProviderContainer> _pumpSettings(
  WidgetTester tester, {
  List<Override> extraOverrides = const [],
  // Several sections branch on `Theme.of(context).platform` — the update
  // channel, and the two reader settings backed by Android-only platform
  // channels. Drive it through the theme rather than dart:io so both branches
  // are reachable from a test.
  TargetPlatform platform = TargetPlatform.android,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      apiBaseUrlOverride('http://127.0.0.1:8000'),
      sharedPrefsProvider.overrideWithValue(prefs),
      libraryRepositoryProvider.overrideWithValue(_EmptyLibraryRepository()),
      readerRepositoryProvider.overrideWithValue(_EmptyReaderRepository()),
      updatesRepositoryProvider.overrideWithValue(_EmptyUpdatesRepository()),
      // PackageInfo.fromPlatform() hits a real platform channel that isn't
      // mocked in widget tests, so override the provider directly instead
      // of introducing a wrapper interface just for this.
      packageInfoProvider.overrideWith((ref) async => _testPackageInfo),
      // Suppress network call in tests — update check should not hit the server.
      appUpdateProvider.overrideWith((ref) async => null),
      secureStorageProvider.overrideWithValue(_FakeSecureStorageService()),
      // The Content section's 18+ toggle builds on the General tab and would
      // otherwise fire a real GET /settings; stub the repo so tests stay offline.
      matureSettingsRepositoryProvider.overrideWithValue(_StubMatureRepo()),
      ..._metadataCacheProviderOverrides(),
      ...extraOverrides,
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(platform: platform),
        home: const SettingsScreen(),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return container;
}

/// The General tab is tall enough that most of its content sits outside the
/// default test viewport's build/cache extent. `ListView` only builds
/// children near the viewport, so `find.text()` won't see anything further
/// down until we scroll to it.
Future<void> _scrollToText(WidgetTester tester, String text) async {
  // TabBarView's own PageView is also a Scrollable, so
  // find.byType(Scrollable).first can resolve to that instead of the
  // visible tab's ListView. Target the Scrollable that the ListView itself
  // renders, not the outer PageView's.
  await tester.scrollUntilVisible(
    find.text(text),
    300,
    scrollable: find
        .descendant(of: find.byType(ListView).first, matching: find.byType(Scrollable))
        .first,
  );
  await tester.pump();
}

/// Scroll the General tab down to the Theme section.
///
/// The section's own heading is not unique enough to steer by, so this uses
/// the one line that is: the active palette's name, shown beside the
/// miniature. Nothing is stored in these pumps, so that is the app default —
/// read from [AppPalettes] rather than spelled out, because the anchor is
/// incidental to every test that uses it and moving the default should not
/// silently break four of them.
Future<void> _scrollToTheme(WidgetTester tester) =>
    _scrollToText(tester, AppPalettes.defaultPalette.name);

/// Bring one palette thumbnail on the Theme strip into view.
///
/// The strip is a horizontal `ListView` holding every registered palette, so
/// anything past the first handful is not built until it is scrolled to —
/// `ensureVisible` alone only works for what already exists.
Future<void> _revealStripSwatch(WidgetTester tester, String id) async {
  await _scrollToTheme(tester);
  final target = find.byKey(Key('theme-strip-$id'));
  if (!tester.any(target)) {
    await tester.scrollUntilVisible(
      target,
      120,
      scrollable: find.descendant(
        of: find.byKey(const Key('theme-strip')),
        matching: find.byType(Scrollable),
      ),
    );
  }
  await tester.ensureVisible(target);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsScreen navigation', () {
    testWidgets('renders General, Server, and About tabs', (tester) async {
      await _pumpSettings(tester);

      expect(find.text('General'), findsOneWidget);
      expect(find.text('Server'), findsOneWidget);
      expect(find.text('About'), findsOneWidget);
    });

    testWidgets('General tab is shown by default with theme/reader sections',
        (tester) async {
      await _pumpSettings(tester);

      // Section headings are rendered by _SectionHeading, which uppercases.
      // The Content (18+) section now sits near the top, so Theme/Language are
      // further down the General tab — scroll to each before asserting.
      await _scrollToText(tester, 'THEME');
      expect(find.text('THEME'), findsOneWidget);

      await _scrollToText(tester, 'LANGUAGE');
      expect(find.text('LANGUAGE'), findsOneWidget);

      await _scrollToText(tester, 'DEFAULT READER PREFERENCES');
      expect(find.text('DEFAULT READER PREFERENCES'), findsOneWidget);
    });

    testWidgets('tapping the Server tab shows the server URL field', (tester) async {
      await _pumpSettings(tester);

      await tester.tap(find.text('Server'));
      await tester.pumpAndSettle();

      // Section heading is uppercased by _SectionHeading.
      expect(find.text('SERVER CONNECTION'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('search jumps to the tab a result lives on', (tester) async {
      await _pumpSettings(tester);

      await tester.tap(find.byIcon(Icons.search));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'server connection');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Server connection').first);
      await tester.pumpAndSettle();

      // After navigating to the Server tab the section heading is uppercased.
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('SERVER CONNECTION'), findsOneWidget);
    });

    testWidgets('tapping the About tab shows version info and licenses button',
        (tester) async {
      await _pumpSettings(tester);

      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();

      expect(find.text('Version'), findsOneWidget);
      expect(find.text('Build'), findsOneWidget);
      expect(find.text('Open source licenses'), findsOneWidget);
    });

    testWidgets('tapping the Debug tab shows diagnostics and reset sections',
        (tester) async {
      await _pumpSettings(tester);

      await tester.tap(find.text('Debug'));
      await tester.pumpAndSettle();

      // Section headings are uppercased by _SectionHeading.
      expect(find.text('DIAGNOSTICS'), findsOneWidget);
      expect(find.text('RESET'), findsOneWidget);
      expect(find.text('Reset reader settings'), findsOneWidget);
    });

    testWidgets(
        'General tab survives a failed mature load with a per-section retry '
        'and no global error', (tester) async {
      await _pumpSettings(
        tester,
        extraOverrides: [
          matureContentProvider.overrideWith(_ThrowingMatureController.new),
        ],
      );
      await tester.pump(const Duration(milliseconds: 100));

      // The whole-tab "Something went wrong" red-out must be gone: the failing
      // section must not render UnknownError.userMessage.
      expect(find.text('Something went wrong — please try again.'), findsNothing);

      // Assert top-to-bottom (scrollUntilVisible only scrolls downward): the
      // Content section (near the top) shows its own isolated retry card…
      await _scrollToText(tester, "Couldn't load the mature content setting.");
      expect(
        find.text("Couldn't load the mature content setting."),
        findsOneWidget,
      );
      // …carrying its own Retry affordance (asserted here, while the card is
      // still on screen — ListView disposes children it scrolls past)…
      expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);

      // …and the local Theme/Language sections still render (never
      // network-backed).
      await _scrollToText(tester, 'THEME');
      expect(find.text('THEME'), findsOneWidget);
      await _scrollToText(tester, 'LANGUAGE');
      expect(find.text('LANGUAGE'), findsOneWidget);
    });

    testWidgets('every tab opens without throwing during build',
        (tester) async {
      await _pumpSettings(tester);

      for (final tab in const [
        'General',
        'Server',
        'About',
        'Debug',
      ]) {
        await tester.tap(find.text(tab));
        await tester.pumpAndSettle();
        // A build-time throw in any panel would have surfaced as a test
        // failure by now; assert the screen is still intact.
        expect(tester.takeException(), isNull);
        expect(find.byType(SettingsScreen), findsOneWidget);
      }
    });
  });

  group('SettingsScreen widgets', () {
    testWidgets('shows the active theme, the strip, and a way to the gallery',
        (tester) async {
      await _pumpSettings(tester);

      await _scrollToTheme(tester);
      // The section says what is on and offers the full gallery…
      expect(find.byKey(const Key('theme-open-gallery')), findsOneWidget);
      expect(find.byKey(const Key('theme-strip')), findsOneWidget);
      expect(
        tester
            .widget<ListView>(find.byKey(const Key('theme-strip')))
            .semanticChildCount,
        AppPalettes.all.length,
      );
      // …and the strip carries every registered palette, lazily. Gallery
      // order leads with the house palettes, so Eclipse is at the head of it
      // and is built without scrolling.
      expect(find.byKey(const Key('theme-strip-eclipse')), findsOneWidget);
      // Something far enough down the strip to prove the rail actually holds
      // the generated set and not just the house palettes.
      await _revealStripSwatch(tester, 'kanagawa');
      expect(find.byKey(const Key('theme-strip-kanagawa')), findsOneWidget);
    });

    testWidgets('the gallery opens with search and a filter', (tester) async {
      final container = await _pumpSettings(tester);

      await _scrollToTheme(tester);
      await tester.tap(find.byKey(const Key('theme-open-gallery')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('theme-search')), findsOneWidget);
      expect(find.byKey(const Key('theme-filter-dark')), findsOneWidget);

      // Search narrows forty-five palettes to the one being looked for, and
      // picking it from the gallery applies it like any other swatch.
      await tester.enterText(find.byKey(const Key('theme-search')), 'kanagawa');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('theme-swatch-kanagawa')), findsOneWidget);
      expect(find.byKey(const Key('theme-swatch-eclipse')), findsNothing);

      await tester.tap(find.byKey(const Key('theme-swatch-kanagawa')));
      await tester.pumpAndSettle();
      expect(container.read(themeControllerProvider), Base16Palettes.kanagawa);
    });

    testWidgets(
        'language dropdown renders its current value as a valid item and opens',
        (tester) async {
      final container = await _pumpSettings(tester);

      // The selected value (English by default) must be present exactly once in
      // the dropdown's items, otherwise DropdownButton throws
      // "There should be exactly one item with [DropdownButton]'s value".
      await _scrollToText(tester, 'App language');
      expect(find.byType(DropdownButtonFormField<AppLanguage>), findsOneWidget);
      expect(container.read(languageProvider), AppLanguage.english);
      // Selected label is shown in the closed field.
      expect(find.text('English'), findsWidgets);
      expect(tester.takeException(), isNull);

      // Opening the menu builds every item without throwing.
      await tester.tap(find.byType(DropdownButtonFormField<AppLanguage>));
      await tester.pumpAndSettle();
      for (final lang in AppLanguage.values) {
        expect(find.text(lang.label), findsWidgets);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping a strip swatch applies and persists that theme', (tester) async {
      final container = await _pumpSettings(tester);

      await _revealStripSwatch(tester, 'nord');
      await tester.tap(find.byKey(const Key('theme-strip-nord')));
      await tester.pump();

      expect(container.read(themeControllerProvider), Base16Palettes.nord);
      // No signed-in (user, profile) scope in this pump, so the selection
      // lands in the device slot.
      final prefs = container.read(sharedPrefsProvider);
      expect(prefs.getString('mm.theme.device'), 'nord');
    });

    testWidgets('shows a row per design preset with its position', (tester) async {
      await _pumpSettings(tester);

      await _scrollToText(tester, 'Signature');
      for (final preset in AppPresets.all) {
        expect(
          find.byKey(Key('preset-row-${preset.id}')),
          findsOneWidget,
          reason: preset.id,
        );
      }
    });

    testWidgets('tapping a design applies and persists it, live', (tester) async {
      final container = await _pumpSettings(tester);

      await _scrollToText(tester, 'Signature');
      await tester.ensureVisible(find.byKey(const Key('preset-row-compact')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('preset-row-compact')));
      await tester.pump();

      expect(container.read(presetControllerProvider), AppPresets.compact);
      // No signed-in (user, profile) scope in this pump, so the selection
      // lands in the device slot.
      expect(
        container.read(sharedPrefsProvider).getString('mm.preset.device'),
        'compact',
      );
    });

    testWidgets('choosing a design leaves the theme alone', (tester) async {
      // The orthogonality promise where a user can actually see it: the two
      // pickers sit next to each other and must not disturb one another.
      final container = await _pumpSettings(tester);

      await _revealStripSwatch(tester, 'nord');
      await tester.tap(find.byKey(const Key('theme-strip-nord')));
      await tester.pump();

      await _scrollToText(tester, 'Signature');
      await tester.ensureVisible(find.byKey(const Key('preset-row-editorial')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('preset-row-editorial')));
      await tester.pumpAndSettle();

      expect(container.read(themeControllerProvider), Base16Palettes.nord);
      expect(container.read(presetControllerProvider), AppPresets.editorial);
      expect(tester.takeException(), isNull);
    });

    testWidgets('toggling Keep screen awake persists the preference', (tester) async {
      final container = await _pumpSettings(tester);

      await _scrollToText(tester, 'Keep screen awake');
      await tester.tap(find.text('Keep screen awake'));
      await tester.pump();

      expect(container.read(readerDefaultsProvider).keepScreenAwake, isTrue);
      expect(container.read(preferencesProvider).keepScreenAwake, isTrue);
    });
  });

  group('SettingsScreen update channel', () {
    const anUpdateIsAvailable = AppVersionInfo(
      localVersion: '1.3.2',
      localBuild: 17,
      remoteVersion: '1.3.3',
      remoteBuild: 18,
      downloadUrl: 'http://127.0.0.1:8000/app/download',
      channel: AppUpdateChannel.apk,
    );

    testWidgets('Android still offers the APK download', (tester) async {
      await _pumpSettings(
        tester,
        extraOverrides: [
          appUpdateProvider.overrideWith((ref) async => anUpdateIsAvailable),
        ],
      );

      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();

      expect(find.text('Update available'), findsOneWidget);
      expect(find.text('Download Update'), findsOneWidget);
    });

    testWidgets('iOS never offers a download and never claims "up to date"',
        (tester) async {
      // Even handed an APK-channel result that says an update exists, the iOS
      // build must not surface a download: /app/download is an Android package
      // an iPhone cannot open, and the two channels do not share a build-number
      // sequence, so the verdict itself is meaningless here.
      await _pumpSettings(
        tester,
        platform: TargetPlatform.iOS,
        extraOverrides: [
          appUpdateProvider.overrideWith((ref) async => anUpdateIsAvailable),
        ],
      );

      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();

      expect(find.text('Managed by SideStore'), findsOneWidget);
      expect(find.text('Download Update'), findsNothing);
      expect(find.text('Update available'), findsNothing);
      expect(find.textContaining('Up to date'), findsNothing);
      // The manifest SideStore subscribes to — not the .apk, not a raw .ipa.
      expect(
        find.text('http://127.0.0.1:8000/app/source.json'),
        findsOneWidget,
      );
    });
  });

  group('SettingsScreen hides Android-only reader settings', () {
    testWidgets('Android shows refresh rate and volume-key paging',
        (tester) async {
      await _pumpSettings(tester);

      await _scrollToText(tester, 'Refresh rate');
      expect(find.text('Refresh rate'), findsOneWidget);

      await _scrollToText(tester, 'Volume key navigation');
      expect(find.text('Volume key navigation'), findsOneWidget);
    });

    testWidgets('iOS shows neither — both are silent no-ops there',
        (tester) async {
      // `flutter_displaymode` and the volume-key NativeBridge are both gated to
      // Android and return immediately elsewhere, so on an iPhone these
      // controls saved a preference and then did nothing at all.
      await _pumpSettings(tester, platform: TargetPlatform.iOS);

      await _scrollToText(tester, 'Lock reader controls');

      expect(find.text('Refresh rate', skipOffstage: false), findsNothing);
      expect(
        find.text('Volume key navigation', skipOffstage: false),
        findsNothing,
      );
      // The cross-platform reader settings are untouched.
      expect(find.text('Lock reader controls'), findsOneWidget);
    });
  });
}
