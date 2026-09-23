import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:manhwamaniacs/app/router/routes.dart';
import 'package:manhwamaniacs/app/theme/app_theme_provider.dart';
import 'package:manhwamaniacs/features/downloads/models/chapter_identity.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloads_scope.dart';
import 'package:manhwamaniacs/features/downloads/providers/progress_outbox_provider.dart';
import 'package:manhwamaniacs/features/downloads/services/blob_store.dart';
import 'package:manhwamaniacs/features/downloads/store/downloads_store.dart';
import 'package:manhwamaniacs/features/novels/models/novel_chapter.dart';
import 'package:manhwamaniacs/features/novels/providers/novel_audio_provider.dart';
import 'package:manhwamaniacs/features/novels/providers/novel_chapter_provider.dart';
import 'package:manhwamaniacs/features/novels/screens/novel_reader_screen.dart';
import 'package:manhwamaniacs/features/reader/models/reading_progress.dart';
import 'package:manhwamaniacs/features/reader/utils/reader_wakelock.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../../support/test_overrides.dart';

const _sourceId = 'novelarchive';
const _seriesKey = 'the-long-book';
const _chapterOne = 'ch-1';
const _chapterTwo = 'ch-2';

/// The shape of the chapter that stayed at 40 of 45 in production: 45
/// ordinary paragraphs, none of them anywhere near a screen tall.
const _paragraphCount = 45;

NovelChapterKey _key(String chapterKey) =>
    (sourceId: _sourceId, seriesKey: _seriesKey, chapterKey: chapterKey);

NovelChapter _chapter(String chapterKey, {String? previous, String? next}) =>
    NovelChapter(
      sourceId: _sourceId,
      seriesKey: _seriesKey,
      chapterKey: chapterKey,
      chapterNumber: chapterKey == _chapterOne ? 1 : 2,
      title: 'Chapter $chapterKey',
      paragraphs: [
        for (var i = 1; i <= _paragraphCount; i++)
          'Paragraph $i. The rain had not stopped since the caravan left the '
              'river crossing, and nobody in the second wagon had said a word '
              'about the thing they had seen on the bank.',
      ],
      previousChapterKey: previous,
      nextChapterKey: next,
      wordCount: 1200,
    );

/// How long the outbox's write to the phone's database takes. Real enough to
/// matter: a save made as the reader leaves finishes it after the reader has
/// gone, and everything the save does after that write happens then too.
const _diskWrite = Duration(seconds: 1);

/// Every save the reader makes, and nothing sent anywhere.
class _RecordingOutbox extends ProgressOutboxController {
  _RecordingOutbox(super.ref);

  final List<ProgressPush> pushes = [];

  @override
  Future<void> save(ProgressPush push) async {
    pushes.add(push);
    await Future<void>.delayed(_diskWrite);
  }
}

/// A downloads store that only answers the two calls a reader makes of it.
/// The database is never opened: it is a future that never completes, so
/// anything else reaching for it would hang the test rather than pass it.
class _RecordingStore extends DownloadsStore {
  _RecordingStore()
      : super(
          scopeId: 'u1p1',
          database: Completer<Database>().future,
          blobStore: Completer<BlobStore>().future,
        );

  final List<ChapterIdentity> markedRead = [];

  @override
  Future<void> markRead(ChapterIdentity id) async => markedRead.add(id);

  @override
  Future<void> clearReadStamp(ChapterIdentity id) async {}
}

class _NoWakelock implements ReaderWakelock {
  @override
  Future<void> enable() async {}

  @override
  Future<void> disable() async {}
}

typedef _Harness = ({
  ProviderContainer container,
  _RecordingOutbox outbox,
  _RecordingStore store,
  GoRouter router,
});

/// The reader alone under a two-route router: itself, and the series page
/// that closing it goes to. What is under test is what it saves as it reads
/// and as it leaves, not the app around it.
Future<_Harness> _pump(WidgetTester tester, {required String opening}) async {
  await tester.binding.setSurfaceSize(const Size(430, 932));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  SharedPreferences.setMockInitialValues(
    testPrefsDefaults({'settings_auto_next_chapter': false}),
  );
  final prefs = await SharedPreferences.getInstance();
  final store = _RecordingStore();
  late _RecordingOutbox outbox;

  final chapters = {
    _chapterOne: _chapter(_chapterOne, next: _chapterTwo),
    _chapterTwo: _chapter(_chapterTwo, previous: _chapterOne),
  };

  final container = ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      readerWakelockProvider.overrideWithValue(_NoWakelock()),
      // No scope, so the open-chapter claim stays out of it: it would release
      // itself in a microtask after this container is gone. The reader asks
      // for the store directly, which is what is recorded here.
      activeDownloadsScopeIdProvider.overrideWithValue(null),
      downloadsStoreProvider.overrideWithValue(store),
      progressOutboxControllerProvider.overrideWith(
        (ref) => outbox = _RecordingOutbox(ref),
      ),
      for (final entry in chapters.entries) ...[
        novelChapterPayloadProvider(_key(entry.key))
            .overrideWith((ref) async => entry.value),
        resolvedNovelChapterProvider(_key(entry.key))
            .overrideWith((ref) async => entry.value),
        playableNovelAudioProvider(_key(entry.key))
            .overrideWith((ref) async => null),
      ],
    ],
  );
  addTearDown(container.dispose);
  // Created up front so the harness can hand it back before the reader's
  // first save asks for it.
  container.read(progressOutboxControllerProvider);

  final router = GoRouter(
    initialLocation: RoutePaths.novelReader(_sourceId, _seriesKey, opening),
    routes: [
      GoRoute(
        path: Routes.novelReader,
        builder: (context, state) => NovelReaderScreen(
          sourceId: state.pathParameters['sourceId']!,
          seriesKey: state.pathParameters['seriesKey']!,
          chapterKey: state.pathParameters['chapterKey']!,
        ),
      ),
      GoRoute(
        path: Routes.sourceSeriesDetail,
        builder: (context, state) => const Scaffold(body: Text('series page')),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: container.read(appThemeProvider),
        routerConfig: router,
      ),
    ),
  );
  await _settle(tester);
  return (container: container, outbox: outbox, store: store, router: router);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

/// Scroll to the very bottom. The list is built lazily, so its extent is an
/// estimate until the end is laid out: jump to the end it currently admits
/// until that stops moving.
/// Only frames are pumped, never time, so the save debounce is still waiting
/// when this returns.
Future<void> _scrollToBottom(WidgetTester tester) async {
  final scrollable = tester.state<ScrollableState>(
    find
        .descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  final position = scrollable.position;
  for (var i = 0; i < 50; i++) {
    position.jumpTo(position.maxScrollExtent);
    await tester.pump();
    // The extent can shrink under the jump as well as grow, which leaves the
    // position past it; only landing exactly on it is the bottom.
    if (position.pixels == position.maxScrollExtent) break;
  }
  expect(position.pixels, position.maxScrollExtent);
  expect(find.text('Next chapter'), findsOneWidget, reason: 'the foot is up');
}

Future<void> _revealChrome(WidgetTester tester) async {
  await tester.tapAt(const Offset(215, 466));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

List<ProgressPush> _completions(_RecordingOutbox outbox, String chapterKey) => [
      for (final push in outbox.pushes)
        if (push.chapterKey == chapterKey && push.isCompleted) push,
    ];

const ChapterIdentity _one =
    (sourceId: _sourceId, seriesKey: _seriesKey, chapterKey: _chapterOne);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Novel reader — finishing a chapter', () {
    testWidgets('scrolling to the last line saves the chapter as finished',
        (tester) async {
      final h = await _pump(tester, opening: _chapterOne);

      await _scrollToBottom(tester);
      await tester.pump(const Duration(milliseconds: 600));

      final last = h.outbox.pushes.last;
      expect(last.chapterKey, _chapterOne);
      expect(last.lastPage, _paragraphCount);
      expect(last.pageCount, _paragraphCount);
      expect(last.isCompleted, isTrue);
      // The downloaded copy's read-then-expire starts with it.
      await tester.pump(_diskWrite);
      expect(h.store.markedRead, [_one]);
    });

    testWidgets('Next saves the chapter as finished before it moves on',
        (tester) async {
      final h = await _pump(tester, opening: _chapterOne);

      // From the top: tapping Next is the reader saying they are done,
      // wherever the scroll happens to be.
      await _revealChrome(tester);
      await tester.tap(find.byTooltip('Next chapter'));
      await _settle(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('Chapter $_chapterTwo'), findsWidgets);
      final done = _completions(h.outbox, _chapterOne);
      expect(done, hasLength(1));
      expect(done.single.lastPage, _paragraphCount);
      expect(done.single.pageCount, _paragraphCount);
      // Made once the outbox's write has landed, after the reader it came
      // from is gone — exactly when reaching the store through the widget
      // throws.
      await tester.pump(_diskWrite);
      expect(tester.takeException(), isNull);
      expect(h.store.markedRead, [_one]);
    });

    testWidgets('the Next at the foot of the chapter does the same',
        (tester) async {
      final h = await _pump(tester, opening: _chapterOne);

      await _scrollToBottom(tester);
      await tester.tap(find.text('Next chapter'));
      await _settle(tester);
      await tester.pump(_diskWrite);

      expect(tester.takeException(), isNull);
      expect(_completions(h.outbox, _chapterOne), hasLength(1));
      expect(h.store.markedRead, [_one]);
    });

    testWidgets('going back a chapter finishes nothing', (tester) async {
      final h = await _pump(tester, opening: _chapterTwo);

      await _revealChrome(tester);
      await tester.tap(find.byTooltip('Previous chapter'));
      await _settle(tester);

      expect(find.text('Chapter $_chapterOne'), findsWidgets);
      expect(h.outbox.pushes.where((p) => p.isCompleted), isEmpty);
      expect(h.store.markedRead, isEmpty);
    });

    testWidgets('closing at the bottom before the save lands still saves it',
        (tester) async {
      final h = await _pump(tester, opening: _chapterOne);

      await _scrollToBottom(tester);
      // Back inside the half second the scroll save waits for.
      final handled = await WidgetsBinding.instance.handlePopRoute();
      await _settle(tester);

      expect(handled, isTrue);
      expect(tester.takeException(), isNull);
      expect(find.text('series page'), findsOneWidget);
      final done = _completions(h.outbox, _chapterOne);
      expect(done, hasLength(1));
      expect(done.single.lastPage, _paragraphCount);
      await tester.pump(_diskWrite);
      expect(tester.takeException(), isNull);
      expect(h.store.markedRead, [_one]);
    });
  });
}
