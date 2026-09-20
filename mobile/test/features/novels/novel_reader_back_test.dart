import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:manhwamaniacs/app/app.dart';
import 'package:manhwamaniacs/app/router/app_router.dart';
import 'package:manhwamaniacs/app/router/routes.dart';
import 'package:manhwamaniacs/features/novels/models/novel_audio.dart';
import 'package:manhwamaniacs/features/novels/models/novel_chapter.dart';
import 'package:manhwamaniacs/features/novels/providers/novel_audio_provider.dart';
import 'package:manhwamaniacs/features/novels/providers/novel_chapter_provider.dart';
import 'package:manhwamaniacs/features/novels/screens/novel_reader_screen.dart';
import 'package:manhwamaniacs/features/reader/models/chapter_manifest.dart';
import 'package:manhwamaniacs/features/reader/providers/reader_chapter_provider.dart';
import 'package:manhwamaniacs/features/reader/screens/reader_screen.dart';
import 'package:manhwamaniacs/features/reader/utils/reader_wakelock.dart';
import 'package:manhwamaniacs/features/sources/providers/sources_provider.dart';
import 'package:manhwamaniacs/features/sources/screens/source_series_detail_screen.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/test_overrides.dart';

/// A novel source, and a series key with a `/` in it — the shape every
/// aggregator key actually has, so the trip out to the series page has to
/// survive RoutePaths' encoding as well as the navigation.
const _sourceId = 'novelbin';
const _seriesKey = 'novelbin/the-long-book';
const _chapterOne = 'novelbin/the-long-book/ch-1';
const _chapterTwo = 'novelbin/the-long-book/ch-2';

/// The manga reader's own identity, kept deliberately unlike the novel's so a
/// mixed-up assertion cannot pass by accident.
const _mangaSourceId = 'mangadex';
const _mangaSeriesKey = 'solo-leveling';
const _mangaChapterOne = '1';
const _mangaChapterTwo = '2';

NovelChapterKey _novelKey(String chapterKey) =>
    (sourceId: _sourceId, seriesKey: _seriesKey, chapterKey: chapterKey);

NovelChapter _novelChapter({
  required String chapterKey,
  required double number,
  String? previous,
  String? next,
}) =>
    NovelChapter(
      sourceId: _sourceId,
      seriesKey: _seriesKey,
      chapterKey: chapterKey,
      chapterNumber: number,
      title: 'Chapter $number',
      paragraphs: const [
        'The first paragraph of the chapter.',
        'And a second one after it.',
      ],
      previousChapterKey: previous,
      nextChapterKey: next,
      wordCount: 12,
    );

ChapterManifestKey _mangaKey(String chapterKey) => (
      sourceId: _mangaSourceId,
      seriesKey: _mangaSeriesKey,
      chapterKey: chapterKey,
    );

ChapterManifest _mangaManifest(String chapterKey, {String? next}) =>
    ChapterManifest(
      sourceId: _mangaSourceId,
      seriesKey: _mangaSeriesKey,
      chapterKey: chapterKey,
      chapterNumber: 1,
      pageCount: 2,
      prev: null,
      next: next,
      pages: const [
        ManifestPage(number: 1, url: '/sources/$_mangaSourceId/pages/p1/image'),
        ManifestPage(number: 2, url: '/sources/$_mangaSourceId/pages/p2/image'),
      ],
    );

/// The real wakelock reaches a platform channel that has no handler in a
/// widget-test host, and the reader fires it from `initState` without awaiting
/// — so the failure would land as an unhandled async error rather than
/// anywhere useful. Records the last request so leaving the reader can be
/// checked to actually release the screen.
class _RecordingWakelock implements ReaderWakelock {
  bool? held;

  @override
  Future<void> enable() async => held = true;

  @override
  Future<void> disable() async => held = false;
}

/// The reader only asks for the wakelock when the setting is on, so a test
/// about releasing it has to turn it on first.
const _keepAwakePrefKey = 'settings_keep_screen_awake';

/// The series page these tests land on only has to *be* the right route with
/// the right identity; what it renders is another screen's business. A
/// completer that never completes parks it on its spinner without leaving a
/// pending Timer behind to fail teardown.
List<Override> _pendingSeriesDetail() => [
      sourceSeriesDetailProvider((sourceId: _sourceId, seriesId: _seriesKey))
          .overrideWith((ref) => Completer<SourceSeriesDetailData>().future),
      sourceSeriesDetailProvider(
        (sourceId: _mangaSourceId, seriesId: _mangaSeriesKey),
      ).overrideWith((ref) => Completer<SourceSeriesDetailData>().future),
    ];

/// Mounts the real app — real router, real route table — because the whole
/// bug lives in the shape of the route tree, not in any screen's own code.
Future<ProviderContainer> _pumpApp(
  WidgetTester tester, {
  ReaderWakelock? wakelock,
  bool keepScreenAwake = false,
}) async {
  await tester.binding.setSurfaceSize(const Size(430, 932));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  SharedPreferences.setMockInitialValues(
    testPrefsDefaults({_keepAwakePrefKey: keepScreenAwake}),
  );
  final prefs = await SharedPreferences.getInstance();

  final container = ProviderContainer(
    overrides: [
      apiBaseUrlOverride('http://example.test'),
      sharedPrefsProvider.overrideWithValue(prefs),
      readerWakelockProvider.overrideWithValue(wakelock ?? _RecordingWakelock()),
      authenticatedAuthOverride(),
      activeProfileOverride(),
      ...noDownloadsStoreOverrides(),
      profileSessionReadyOverride(),
      novelChapterPayloadProvider(_novelKey(_chapterOne)).overrideWith(
        (ref) async => _novelChapter(
          chapterKey: _chapterOne,
          number: 1,
          next: _chapterTwo,
        ),
      ),
      novelChapterPayloadProvider(_novelKey(_chapterTwo)).overrideWith(
        (ref) async => _novelChapter(
          chapterKey: _chapterTwo,
          number: 2,
          previous: _chapterOne,
        ),
      ),
      chapterManifestProvider(_mangaKey(_mangaChapterOne))
          .overrideWith((ref) async => _mangaManifest(
                _mangaChapterOne,
                next: _mangaChapterTwo,
              ),),
      chapterManifestProvider(_mangaKey(_mangaChapterTwo))
          .overrideWith((ref) async => _mangaManifest(_mangaChapterTwo)),
      // Answered explicitly, because the reader's CHROME now depends on it:
      // a chapter that turns out to have audio reveals the controls once by
      // itself, and every tap-to-reveal assertion below would then be
      // toggling them off instead of on.
      novelAudioProvider(_novelKey(_chapterOne))
          .overrideWith((ref) async => NovelAudio.none),
      novelAudioProvider(_novelKey(_chapterTwo))
          .overrideWith((ref) async => NovelAudio.none),
      ..._pendingSeriesDetail(),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const ManhwaManiacsApp(),
    ),
  );
  await tester.pump();
  return container;
}

GoRouter _router(ProviderContainer container) =>
    container.read(appRouterProvider);

/// The matched route *pattern*, not the location: go_router spells a
/// slash-bearing key encoded or decoded depending on how the route was
/// reached, but the pattern is stable either way.
String _fullPath(GoRouter router) =>
    router.routerDelegate.currentConfiguration.fullPath;

/// Long enough for both halves of a reader transition. `pumpAndSettle` is not
/// an option — the series page these tests land on parks on a spinner that
/// never stops — and one 400 ms frame is not enough either: leaving a
/// top-level route swaps the root navigator's only page, and the outgoing one
/// is not unmounted until a frame after the incoming one has settled.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

/// The reader's chrome starts hidden — it is revealed by tapping the page,
/// which is the only way to reach the Back button at all.
Future<void> _revealChrome(WidgetTester tester) async {
  await tester.tapAt(const Offset(215, 466));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _tapChrome(WidgetTester tester, String tooltip) async {
  await tester.tap(find.byTooltip(tooltip));
  await _settle(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Novel reader — Back after a chapter change', () {
    testWidgets('a chapter change leaves nothing beneath the reader',
        (tester) async {
      final container = await _pumpApp(tester);
      final router = _router(container);

      // Opened the way the book page opens it: pushed on top of the live
      // series page, so Back has somewhere obvious to go.
      router.go(RoutePaths.sourceSeriesDetail(_sourceId, _seriesKey));
      await _settle(tester);
      unawaited(
        router.push(RoutePaths.novelReader(_sourceId, _seriesKey, _chapterOne)),
      );
      await _settle(tester);
      expect(find.byType(NovelReaderScreen), findsOneWidget);
      expect(router.canPop(), isTrue);

      await _revealChrome(tester);
      await _tapChrome(tester, 'Next chapter');

      // `_openChapter` uses `go`, and the novel reader is registered
      // top-level (Routes.novelReader) — so the rebuilt stack is the reader
      // and nothing else. This is the whole bug in one assertion.
      expect(_fullPath(router), Routes.novelReader);
      expect(
        router.canPop(),
        isFalse,
        reason: 'a top-level route rebuilt by go() has nothing under it',
      );
    });

    testWidgets('the Back button leaves the reader for the book, not nowhere',
        (tester) async {
      final container = await _pumpApp(tester);
      final router = _router(container);

      router.go(RoutePaths.novelReader(_sourceId, _seriesKey, _chapterOne));
      await _settle(tester);
      await _revealChrome(tester);
      await _tapChrome(tester, 'Next chapter');
      expect(find.byType(NovelReaderScreen), findsOneWidget);

      await _revealChrome(tester);
      await _tapChrome(tester, 'Back');

      expect(tester.takeException(), isNull);
      expect(find.byType(NovelReaderScreen), findsNothing);
      expect(_fullPath(router), Routes.sourceSeriesDetail);
      final series = tester.widget<SourceSeriesDetailScreen>(
        find.byType(SourceSeriesDetailScreen),
      );
      expect(series.sourceId, _sourceId);
      // The `/` survived the encode/decode round trip — a raw one would have
      // grown the location an extra segment and matched no route at all.
      expect(series.seriesId, _seriesKey);
    });

    testWidgets('the system back gesture leaves the reader, not the app',
        (tester) async {
      final container = await _pumpApp(tester);
      final router = _router(container);

      router.go(RoutePaths.novelReader(_sourceId, _seriesKey, _chapterOne));
      await _settle(tester);
      await _revealChrome(tester);
      await _tapChrome(tester, 'Next chapter');

      // What Android's back gesture and the hardware key both arrive as.
      // `false` here is the framework being told nobody handled it, which on
      // a phone closes the app mid-book.
      final handled = await WidgetsBinding.instance.handlePopRoute();
      await _settle(tester);

      expect(handled, isTrue);
      expect(find.byType(NovelReaderScreen), findsNothing);
      expect(_fullPath(router), Routes.sourceSeriesDetail);
    });

    testWidgets('Back still returns to the page that opened the reader',
        (tester) async {
      final container = await _pumpApp(tester);
      final router = _router(container);

      router.go(RoutePaths.sourceSeriesDetail(_sourceId, _seriesKey));
      await _settle(tester);
      unawaited(
        router.push(RoutePaths.novelReader(_sourceId, _seriesKey, _chapterOne)),
      );
      await _settle(tester);

      await _revealChrome(tester);
      await _tapChrome(tester, 'Back');

      expect(_fullPath(router), Routes.sourceSeriesDetail);
      // Popped onto the live page rather than rebuilding a second copy of it.
      expect(
        find.byType(SourceSeriesDetailScreen, skipOffstage: false),
        findsOneWidget,
      );
    });

    testWidgets('a long read never accumulates a deep stack', (tester) async {
      final container = await _pumpApp(tester);
      final router = _router(container);

      router.go(RoutePaths.novelReader(_sourceId, _seriesKey, _chapterOne));
      await _settle(tester);

      // Back and forth between two chapters stands in for a thirty-chapter
      // sitting: if `_openChapter` ever stacked, this would leave a pile.
      for (var i = 0; i < 3; i++) {
        await _revealChrome(tester);
        await _tapChrome(tester, 'Next chapter');
        await _revealChrome(tester);
        await _tapChrome(tester, 'Previous chapter');
      }

      expect(find.byType(NovelReaderScreen), findsOneWidget);
      await _revealChrome(tester);
      await _tapChrome(tester, 'Back');

      expect(_fullPath(router), Routes.sourceSeriesDetail);
      // One tap of Back was enough — the reader was one deep, not seven.
      expect(find.byType(NovelReaderScreen), findsNothing);
    });
  });

  // Leaving the reader used to throw before it got this far:
  // `StatefulElement.unmount` marks the element defunct *before* calling
  // `dispose()`, so the `ref.read` that released the wakelock threw
  // `Cannot use "ref" after the widget was disposed` — in release too, since
  // riverpod's check is a plain throw — skipping `super.dispose()` and
  // leaving the screen pinned awake for the rest of the session.
  group('Novel reader — leaving tears down cleanly', () {
    testWidgets('releases the screen it asked to keep awake', (tester) async {
      final wakelock = _RecordingWakelock();
      final container = await _pumpApp(
        tester,
        wakelock: wakelock,
        keepScreenAwake: true,
      );
      final router = _router(container);

      router.go(RoutePaths.novelReader(_sourceId, _seriesKey, _chapterOne));
      await _settle(tester);
      expect(wakelock.held, isTrue);

      await _revealChrome(tester);
      await _tapChrome(tester, 'Back');

      expect(tester.takeException(), isNull);
      expect(find.byType(NovelReaderScreen), findsNothing);
      expect(wakelock.held, isFalse);
    });
  });

  // The manga reader changes chapters with the same `go()`, but its route is
  // nested under the /library tab root (see app_router.dart), so the shell is
  // always rebuilt beneath it and Back has somewhere to land. Asserted rather
  // than assumed, because it is the whole reason only the novel reader broke.
  group('Manga reader — Back after a chapter change', () {
    testWidgets('keeps the tab shell beneath it and still leaves the reader',
        (tester) async {
      final container = await _pumpApp(tester);
      final router = _router(container);

      router.go(
        RoutePaths.reader(_mangaSourceId, _mangaSeriesKey, _mangaChapterOne),
      );
      await _settle(tester);
      expect(find.byType(ReaderScreen), findsOneWidget);

      router.go(
        RoutePaths.reader(_mangaSourceId, _mangaSeriesKey, _mangaChapterTwo),
      );
      await _settle(tester);

      expect(
        router.canPop(),
        isTrue,
        reason: 'the reader is nested under /library, which is rebuilt too',
      );

      await tester.tap(find.byTooltip('Back'));
      await _settle(tester);

      expect(tester.takeException(), isNull);
      expect(find.byType(ReaderScreen), findsNothing);
    });
  });
}
