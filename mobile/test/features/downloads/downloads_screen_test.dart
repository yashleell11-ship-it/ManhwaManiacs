import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:manhwamaniacs/app/router/routes.dart';
import 'package:manhwamaniacs/features/downloads/models/download_chapter_state.dart';
import 'package:manhwamaniacs/features/downloads/models/downloaded_series_group.dart';
import 'package:manhwamaniacs/features/downloads/models/saved_chapter.dart';
import 'package:manhwamaniacs/features/downloads/providers/active_download_queue_provider.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloaded_series_provider.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloads_scope.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloads_storage_providers.dart';
import 'package:manhwamaniacs/features/downloads/queue/download_queue_controller.dart';
import 'package:manhwamaniacs/features/downloads/screens/downloads_screen.dart';
import 'package:manhwamaniacs/features/downloads/store/downloads_store.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/test_overrides.dart';

class _MockDownloadsStore extends Mock implements DownloadsStore {}

class _FixedQueueController extends DownloadQueueController {
  _FixedQueueController(this._state);
  final DownloadQueueState _state;
  var storageRetries = 0;

  @override
  DownloadQueueState build() => _state;

  @override
  void retryAfterStorageChange() => storageRetries++;
}

SavedChapter _chapter({
  required int rowId,
  required String chapterKey,
  DownloadChapterState state = DownloadChapterState.complete,
  bool pinned = false,
  int bytes = 1024 * 1024,
  String? error,
  String seriesKey = 'solo-leveling',
  String seriesTitle = 'Solo Leveling',
}) =>
    SavedChapter(
      rowId: rowId,
      scopeId: 'u1p1',
      sourceId: 'asura',
      seriesKey: seriesKey,
      chapterKey: chapterKey,
      chapterNumber: double.tryParse(chapterKey),
      title: null,
      seriesTitle: seriesTitle,
      pageCount: 20,
      bytes: bytes,
      state: state,
      pinned: pinned,
      readAt: null,
      createdAt: DateTime.utc(2026),
      retryCount: 0,
      error: error,
    );

DownloadedSeriesGroup _group(
  List<SavedChapter> chapters, {
  String seriesKey = 'solo-leveling',
  String seriesTitle = 'Solo Leveling',
}) =>
    DownloadedSeriesGroup(
      sourceId: 'asura',
      seriesKey: seriesKey,
      seriesTitle: seriesTitle,
      chapters: chapters,
    );

void main() {
  setUpAll(() {
    registerFallbackValue((sourceId: '', seriesKey: '', chapterKey: ''));
    registerFallbackValue((sourceId: '', seriesKey: ''));
  });

  Future<ProviderContainer> pumpScreen(
    WidgetTester tester, {
    List<DownloadedSeriesGroup> groups = const [],
    List<SavedChapter> queue = const [],
    bool withScope = true,
    DownloadQueueState queueState = const DownloadQueueState(),
    DownloadsStore? store,
  }) async {
    // Tall enough that the queue panel, the "where it lives" note and the
    // series list are all laid out at once — this is a lazy sliver list.
    await tester.binding.setSurfaceSize(const Size(600, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    SharedPreferences.setMockInitialValues(testPrefsDefaults());
    final prefs = await SharedPreferences.getInstance();

    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        if (withScope) ...[
          authenticatedAuthOverride(),
          activeProfileOverride(),
        ],
        downloadedSeriesProvider.overrideWith((ref) async => groups),
        // The Storage tab's card reads real, dedup-aware device bytes, which
        // would otherwise reach sqflite/path_provider with no platform
        // channel behind them — see downloads_storage_card_test.dart.
        totalDeviceDownloadBytesProvider.overrideWith((ref) async => 0),
        seriesStorageBreakdownProvider.overrideWith((ref) async => const []),
        activeDownloadQueueProvider.overrideWith((ref) async => queue),
        downloadQueueControllerProvider
            .overrideWith(() => _FixedQueueController(queueState)),
        if (store != null) downloadsStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: GoRouter(
            initialLocation: Routes.downloads,
            routes: [
              GoRoute(
                path: Routes.downloads,
                builder: (context, state) => const DownloadsScreen(),
              ),
              GoRoute(
                path: '/library/read/:sourceId/:seriesKey/:chapterKey',
                builder: (context, state) =>
                    const Scaffold(body: Text('Reader')),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    return container;
  }

  group('the saved library', () {
    testWidgets('shows an empty state with nothing downloaded', (tester) async {
      await pumpScreen(tester);
      expect(find.text('No downloads yet'), findsOneWidget);
    });

    testWidgets('shows the no-profile state without an active scope',
        (tester) async {
      await pumpScreen(tester, withScope: false);
      expect(find.text('No active profile'), findsOneWidget);
      expect(find.text('No downloads yet'), findsNothing);
      // No scope means no store, so there is nothing to configure either.
      expect(find.text('Storage'), findsNothing);
    });

    testWidgets('lists a series collapsed, with real byte totals',
        (tester) async {
      await pumpScreen(
        tester,
        groups: [
          _group([
            _chapter(rowId: 1, chapterKey: '1', bytes: 2 * 1024 * 1024),
            _chapter(rowId: 2, chapterKey: '2'),
          ]),
        ],
      );

      expect(find.text('Solo Leveling'), findsOneWidget);
      expect(find.text('2 chapters · 3.0 MB'), findsOneWidget);
      // Collapsed by default — chapter rows are not built yet.
      expect(find.text('Downloaded'), findsNothing);
    });

    testWidgets('counts how many of a series are actually saved',
        (tester) async {
      await pumpScreen(
        tester,
        groups: [
          _group([
            _chapter(rowId: 1, chapterKey: '1'),
            _chapter(
              rowId: 2,
              chapterKey: '2',
              state: DownloadChapterState.queued,
              bytes: 0,
            ),
          ]),
        ],
      );

      expect(find.text('1 of 2 chapters saved · 1.0 MB'), findsOneWidget);
    });

    testWidgets('orders series largest first, so the space hog is on top',
        (tester) async {
      await pumpScreen(
        tester,
        groups: [
          _group(
            [_chapter(rowId: 1, chapterKey: '1', bytes: 5 * 1024 * 1024)],
            seriesKey: 'small',
            seriesTitle: 'Small Series',
          ),
          _group(
            [_chapter(rowId: 2, chapterKey: '1', bytes: 900 * 1024 * 1024)],
            seriesKey: 'huge',
            seriesTitle: 'Huge Series',
          ),
        ],
      );

      final huge = tester.getTopLeft(find.text('Huge Series')).dy;
      final small = tester.getTopLeft(find.text('Small Series')).dy;
      expect(huge, lessThan(small));
    });

    testWidgets('expanding a series shows its chapters and their state',
        (tester) async {
      await pumpScreen(
        tester,
        groups: [
          _group([
            _chapter(rowId: 1, chapterKey: '1'),
            _chapter(
              rowId: 2,
              chapterKey: '2',
              state: DownloadChapterState.failed,
              error: 'offline',
            ),
          ]),
        ],
      );

      await tester.tap(find.text('Solo Leveling'));
      await tester.pump();

      // 'Downloaded · <size>' — the note above the list also contains the
      // word "Downloaded", so match the row's own shape.
      expect(find.textContaining('Downloaded · '), findsOneWidget);
      expect(find.textContaining('Failed — offline'), findsOneWidget);
    });

    testWidgets('pinning a series calls the store and refreshes the list',
        (tester) async {
      final store = _MockDownloadsStore();
      when(
        () => store.setSeriesPinned(
          series: any(named: 'series'),
          pinned: any(named: 'pinned'),
        ),
      ).thenAnswer((_) async {});
      await pumpScreen(
        tester,
        groups: [
          _group([_chapter(rowId: 1, chapterKey: '1')]),
        ],
        store: store,
      );

      await tester.tap(find.byKey(const Key('pin-series-asura-solo-leveling')));
      await tester.pump();

      verify(
        () => store.setSeriesPinned(
          series: (sourceId: 'asura', seriesKey: 'solo-leveling'),
          pinned: true,
        ),
      ).called(1);
    });

    testWidgets('removing a chapter calls deleteDownload', (tester) async {
      final store = _MockDownloadsStore();
      when(() => store.deleteDownload(any())).thenAnswer((_) async {});
      await pumpScreen(
        tester,
        groups: [
          _group([_chapter(rowId: 1, chapterKey: '1')]),
        ],
        store: store,
      );

      await tester.tap(find.text('Solo Leveling'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('remove-asura-solo-leveling-1')));
      await tester.pump();

      verify(
        () => store.deleteDownload(
          (sourceId: 'asura', seriesKey: 'solo-leveling', chapterKey: '1'),
        ),
      ).called(1);
    });

    testWidgets('removing downloads lets a queue stopped at the cap retry',
        (tester) async {
      final store = _MockDownloadsStore();
      when(() => store.deleteDownload(any())).thenAnswer((_) async {});
      final container = await pumpScreen(
        tester,
        groups: [
          _group([
            _chapter(rowId: 1, chapterKey: '1'),
            _chapter(rowId: 2, chapterKey: '2'),
          ]),
        ],
        store: store,
        queueState: const DownloadQueueState(
          pauseReason: DownloadQueuePauseReason.cap,
        ),
      );
      final queue = container.read(downloadQueueControllerProvider.notifier)
          as _FixedQueueController;

      await tester.tap(find.text('Solo Leveling'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('remove-asura-solo-leveling-1')));
      await tester.pump();
      expect(queue.storageRetries, 1);

      await tester
          .tap(find.byKey(const Key('series-menu-asura-solo-leveling')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove all downloads'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(queue.storageRetries, 2);
    });

    testWidgets('removing a whole series confirms first, then deletes each',
        (tester) async {
      final store = _MockDownloadsStore();
      when(() => store.deleteDownload(any())).thenAnswer((_) async {});
      await pumpScreen(
        tester,
        groups: [
          _group([
            _chapter(rowId: 1, chapterKey: '1'),
            _chapter(rowId: 2, chapterKey: '2'),
          ]),
        ],
        store: store,
      );

      await tester
          .tap(find.byKey(const Key('series-menu-asura-solo-leveling')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove all downloads'));
      await tester.pumpAndSettle();
      verifyNever(() => store.deleteDownload(any()));

      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      verify(() => store.deleteDownload(any())).called(2);
    });

    testWidgets('says where downloads actually live', (tester) async {
      await pumpScreen(tester);
      expect(
        find.textContaining('stored inside ManhwaManiacs'),
        findsOneWidget,
      );
      expect(find.textContaining('Save to Files'), findsOneWidget);
    });
  });

  group('the live queue', () {
    testWidgets('stays hidden when there is nothing to report', (tester) async {
      await pumpScreen(
        tester,
        groups: [
          _group([_chapter(rowId: 1, chapterKey: '1')]),
        ],
      );
      expect(find.text('Downloading'), findsNothing);
      expect(find.text('Paused'), findsNothing);
    });

    testWidgets('names the chapter and the page it is on', (tester) async {
      final downloading = _chapter(
        rowId: 7,
        chapterKey: '12',
        state: DownloadChapterState.downloading,
      );
      await pumpScreen(
        tester,
        queue: [downloading],
        groups: [
          _group([
            _chapter(rowId: 1, chapterKey: '1'),
            downloading,
          ]),
        ],
        queueState: DownloadQueueState(
          isDownloading: true,
          currentChapter: downloading.identity,
          pagesDone: 8,
          pageTotal: 20,
        ),
      );

      expect(find.text('Downloading'), findsOneWidget);
      expect(find.text('Chapter 12 · page 8 of 20'), findsOneWidget);
      expect(find.text('1 of 2 chapters saved in this series'), findsOneWidget);

      final bar = tester.widget<LinearProgressIndicator>(
        find.byKey(const Key('current-chapter-progress')),
      );
      expect(bar.value, closeTo(0.4, 0.001));
    });

    testWidgets('shows an indeterminate bar before the manifest lands',
        (tester) async {
      final downloading = _chapter(
        rowId: 7,
        chapterKey: '12',
        state: DownloadChapterState.downloading,
      );
      await pumpScreen(
        tester,
        queue: [downloading],
        queueState: DownloadQueueState(
          isDownloading: true,
          currentChapter: downloading.identity,
        ),
      );

      final bar = tester.widget<LinearProgressIndicator>(
        find.byKey(const Key('current-chapter-progress')),
      );
      expect(bar.value, isNull);
      expect(find.textContaining('page 0 of 0'), findsNothing);
    });

    testWidgets('explains a cap pause and offers the way to fix it',
        (tester) async {
      await pumpScreen(
        tester,
        queue: [
          _chapter(
            rowId: 1,
            chapterKey: '1',
            state: DownloadChapterState.queued,
          ),
        ],
        queueState: const DownloadQueueState(
          pauseReason: DownloadQueuePauseReason.cap,
        ),
      );

      expect(find.text('Paused'), findsOneWidget);
      expect(find.textContaining('10 GB limit'), findsOneWidget);

      // The fix lives one tap away on the Storage tab, not in Settings.
      await tester.tap(find.byKey(const Key('queue-open-storage-settings')));
      await tester.pumpAndSettle();
      expect(find.text('Storage cap'), findsOneWidget);
    });

    testWidgets('explains a low-disk pause without blaming the cap',
        (tester) async {
      await pumpScreen(
        tester,
        queue: [
          _chapter(
            rowId: 1,
            chapterKey: '1',
            state: DownloadChapterState.queued,
          ),
        ],
        queueState: const DownloadQueueState(
          pauseReason: DownloadQueuePauseReason.freeSpaceFloor,
        ),
      );

      expect(find.textContaining('almost full'), findsOneWidget);
      expect(
        find.byKey(const Key('queue-open-storage-settings')),
        findsNothing,
      );
    });

    testWidgets('always states that downloads are foreground-only',
        (tester) async {
      await pumpScreen(
        tester,
        queue: [
          _chapter(
            rowId: 1,
            chapterKey: '1',
            state: DownloadChapterState.queued,
          ),
        ],
      );
      expect(
        find.textContaining('only run while ManhwaManiacs is open'),
        findsOneWidget,
      );
    });

    testWidgets('pausing by hand reports itself and offers Resume',
        (tester) async {
      // Resuming restarts the real engine loop, which reads the store — so
      // this needs one, even though the assertion is about the UI.
      final store = _MockDownloadsStore();
      when(store.pendingChapters).thenAnswer((_) async => []);
      await pumpScreen(
        tester,
        store: store,
        queue: [
          _chapter(
            rowId: 1,
            chapterKey: '1',
            state: DownloadChapterState.queued,
          ),
        ],
      );

      await tester.tap(find.byKey(const Key('queue-pause-toggle')));
      await tester.pump();

      expect(find.text('Paused'), findsOneWidget);
      expect(find.textContaining('Paused by you'), findsOneWidget);

      await tester.tap(find.byKey(const Key('queue-resume')));
      await tester.pump();
      expect(find.text('Paused'), findsNothing);
    });

    testWidgets('lists queued chapters on demand, with retry and cancel',
        (tester) async {
      final store = _MockDownloadsStore();
      when(() => store.getChapter(any())).thenAnswer(
        (_) async => _chapter(
          rowId: 2,
          chapterKey: '2',
          state: DownloadChapterState.failed,
        ),
      );
      when(() => store.deleteDownload(any())).thenAnswer((_) async {});
      when(
        () => store.ensureQueued(
          id: any(named: 'id'),
          chapterNumber: any(named: 'chapterNumber'),
          title: any(named: 'title'),
          seriesTitle: any(named: 'seriesTitle'),
        ),
      ).thenAnswer((_) async => 2);
      when(store.pendingChapters).thenAnswer((_) async => []);

      await pumpScreen(
        tester,
        store: store,
        queue: [
          _chapter(
            rowId: 1,
            chapterKey: '1',
            state: DownloadChapterState.queued,
          ),
          _chapter(
            rowId: 2,
            chapterKey: '2',
            state: DownloadChapterState.failed,
            error: 'offline',
          ),
        ],
      );

      expect(find.text('1 in the queue · 1 failed'), findsOneWidget);
      expect(find.byKey(const Key('cancel-1')), findsNothing);

      await tester.tap(find.byKey(const Key('queue-toggle-list')));
      await tester.pumpAndSettle();

      expect(find.text('Solo Leveling · Chapter 1'), findsOneWidget);
      expect(find.textContaining('Failed — offline'), findsOneWidget);
      // Retry is offered only where it means something.
      expect(find.byKey(const Key('retry-2')), findsOneWidget);
      expect(find.byKey(const Key('retry-1')), findsNothing);

      await tester.tap(find.byKey(const Key('cancel-2')));
      await tester.pump();
      verify(
        () => store.deleteDownload(
          (sourceId: 'asura', seriesKey: 'solo-leveling', chapterKey: '2'),
        ),
      ).called(1);
    });

    testWidgets('cancel-all asks before emptying the queue', (tester) async {
      final store = _MockDownloadsStore();
      when(store.unfinishedChapters).thenAnswer((_) async => []);
      await pumpScreen(
        tester,
        store: store,
        queue: [
          _chapter(
            rowId: 1,
            chapterKey: '1',
            state: DownloadChapterState.queued,
          ),
        ],
      );

      await tester.tap(find.byKey(const Key('queue-cancel-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep them'));
      await tester.pumpAndSettle();
      verifyNever(store.unfinishedChapters);

      await tester.tap(find.byKey(const Key('queue-cancel-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel all'));
      await tester.pumpAndSettle();
      verify(store.unfinishedChapters).called(1);
    });
  });

  group('the Storage tab', () {
    testWidgets('puts the cap, the retention interval and Free up space here',
        (tester) async {
      await pumpScreen(tester);

      await tester.tap(find.text('Storage'));
      await tester.pumpAndSettle();

      expect(find.text('Storage cap'), findsOneWidget);
      expect(find.text('Auto-delete after reading'), findsOneWidget);
      expect(find.byKey(const Key('free-up-space')), findsOneWidget);
      expect(find.byKey(const Key('storage-cap-gb20')), findsOneWidget);
    });
  });
}
