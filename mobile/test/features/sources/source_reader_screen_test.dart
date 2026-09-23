import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:manhwamaniacs/features/downloads/providers/progress_outbox_provider.dart';
import 'package:manhwamaniacs/features/library/providers/library_read_state.dart';
import 'package:manhwamaniacs/features/reader/models/reader_chapter.dart';
import 'package:manhwamaniacs/features/reader/models/reader_page.dart';
import 'package:manhwamaniacs/features/reader/models/reading_progress.dart';
import 'package:manhwamaniacs/features/sources/models/source_series.dart';
import 'package:manhwamaniacs/features/sources/providers/source_progress_provider.dart';
import 'package:manhwamaniacs/features/sources/providers/source_reader_provider.dart';
import 'package:manhwamaniacs/features/sources/providers/sources_provider.dart';
import 'package:manhwamaniacs/features/sources/screens/source_reader_screen.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

ReaderChapter _onlineChapter({
  String? previousChapterId,
  String? nextChapterId,
}) {
  return ReaderChapter(
    id: 'manga-1:1',
    seriesId: 'manga-1',
    title: 'Chapter 1',
    pageCount: 2,
    sourceId: 'mangadex',
    seriesTitle: 'Solo Leveling',
    previousChapterId: previousChapterId,
    nextChapterId: nextChapterId,
    pages: const [
      ReaderPage(
        id: 'manga-1:1:1',
        number: 1,
        imageUrl: 'http://example.test/sources/mangadex/pages/p1/image',
        width: 800,
        height: 1200,
      ),
      ReaderPage(
        id: 'manga-1:1:2',
        number: 2,
        imageUrl: 'http://example.test/sources/mangadex/pages/p2/image',
        width: 800,
        height: 1200,
      ),
    ],
  );
}

/// Records what the reader hands the outbox instead of storing and sending it.
class _RecordingOutbox extends ProgressOutboxController {
  _RecordingOutbox(super.ref);

  final List<ProgressPush> pushes = [];

  @override
  Future<void> save(ProgressPush push) async => pushes.add(push);
}

/// Records the reader handing its last save over, instead of refreshing.
class _RecordingReadState extends LibraryReadState {
  _RecordingReadState(super.ref);

  int calls = 0;

  @override
  Future<void> afterReading(Future<void> lastSave) async {
    calls++;
    await lastSave;
  }
}

GoRouter _router(Widget child) => GoRouter(
      routes: [GoRoute(path: '/', builder: (_, __) => child)],
    );

Widget _wrap(
  List<Override> overrides,
  Widget child,
) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp.router(routerConfig: _router(child)),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SourceReaderScreen', () {
    testWidgets('shows loading skeleton while fetching', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // A completer that is never completed keeps the provider pending without
      // leaving a Timer alive (a Future.delayed would, failing test teardown).
      final completer = Completer<ReaderChapter>();

      await tester.pumpWidget(
        _wrap(
          [
            sharedPrefsProvider.overrideWithValue(prefs),
            sourceReaderPayloadProvider((
              sourceId: 'mangadex',
              seriesId: 'manga-1',
              chapterId: 'manga-1:1',
            ),).overrideWith((ref) => completer.future),
          ],
          const SourceReaderScreen(
            sourceId: 'mangadex',
            seriesId: 'manga-1',
            chapterId: 'manga-1:1',
          ),
        ),
      );

      // First frame starts the future; skeleton renders immediately.
      await tester.pump();
      expect(find.text('Loading chapter…'), findsOneWidget);
    });

    testWidgets('renders online chapter title and pages',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _wrap(
          [
            sharedPrefsProvider.overrideWithValue(prefs),
            sourceReaderPayloadProvider((
              sourceId: 'mangadex',
              seriesId: 'manga-1',
              chapterId: 'manga-1:1',
            ),).overrideWith((ref) async => _onlineChapter()),
          ],
          const SourceReaderScreen(
            sourceId: 'mangadex',
            seriesId: 'manga-1',
            chapterId: 'manga-1:1',
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Chapter 1'), findsOneWidget);
      expect(find.textContaining('Page 1 / 2'), findsOneWidget);
    });

    testWidgets('offers a bookmark — most reading starts in this tab',
        (tester) async {
      // This screen used to pass showBookmark: false, so the Sources reader was
      // the only one of the three that could not make a bookmark, while the
      // Bookmarks screen's empty state told the reader to "tap the bookmark
      // icon in either reader". The bookmarks table had zero rows in production.
      //
      // The assertion that was here before checked find.text('Save bookmark')
      // findsNothing WITHOUT opening the more-options sheet that row lives in,
      // so it passed whatever the flag said and proved nothing.
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _wrap(
          [
            sharedPrefsProvider.overrideWithValue(prefs),
            sourceReaderPayloadProvider((
              sourceId: 'mangadex',
              seriesId: 'manga-1',
              chapterId: 'manga-1:1',
            ),).overrideWith((ref) async => _onlineChapter()),
          ],
          const SourceReaderScreen(
            sourceId: 'mangadex',
            seriesId: 'manga-1',
            chapterId: 'manga-1:1',
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.tap(find.byTooltip('Reader settings'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Save bookmark'), findsOneWidget);
    });

    testWidgets('enables prev/next buttons when payload provides chapter ids',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        _wrap(
          [
            sharedPrefsProvider.overrideWithValue(prefs),
            sourceReaderPayloadProvider((
              sourceId: 'mangadex',
              seriesId: 'manga-1',
              chapterId: 'manga-1:1',
            ),).overrideWith(
              (ref) async => _onlineChapter(
                previousChapterId: 'manga-1:0',
                nextChapterId: 'manga-1:2',
              ),
            ),
          ],
          const SourceReaderScreen(
            sourceId: 'mangadex',
            seriesId: 'manga-1',
            chapterId: 'manga-1:1',
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Open more-options sheet to inspect chapter-nav buttons.
      await tester.tap(find.byTooltip('Reader settings'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final prevButton = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('Prev'),
          matching: find.byType(OutlinedButton),
        ),
      );
      final nextButton = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('Next'),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(prevButton.enabled, isTrue);
      expect(nextButton.enabled, isTrue);
    });

    testWidgets('shows retry state on load failure', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      await tester.pumpWidget(
        _wrap(
          [
            sharedPrefsProvider.overrideWithValue(prefs),
            sourceReaderPayloadProvider((
              sourceId: 'mangadex',
              seriesId: 'manga-1',
              chapterId: 'manga-1:1',
            ),).overrideWith((ref) async {
              throw Exception('network failure');
            }),
          ],
          const SourceReaderScreen(
            sourceId: 'mangadex',
            seriesId: 'manga-1',
            chapterId: 'manga-1:1',
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Go back'), findsOneWidget);
    });
  });

  group('SourceReaderScreen progress', () {
    const chapterKey = (
      sourceId: 'mangadex',
      seriesId: 'manga-1',
      chapterId: 'manga-1:1',
    );
    const series = (sourceId: 'mangadex', seriesId: 'manga-1');

    late _RecordingReadState readState;

    Future<_RecordingOutbox> pumpReader(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      late _RecordingOutbox outbox;
      await tester.pumpWidget(
        _wrap(
          [
            sharedPrefsProvider.overrideWithValue(prefs),
            progressOutboxControllerProvider.overrideWith(
              (ref) => outbox = _RecordingOutbox(ref),
            ),
            libraryReadStateProvider.overrideWith(
              (ref) => readState = _RecordingReadState(ref),
            ),
            sourceReaderPayloadProvider(chapterKey)
                .overrideWith((ref) async => _onlineChapter()),
            sourceSeriesDetailProvider(series).overrideWith(
              (ref) async => const SourceSeriesDetailData(
                series: SourceSeriesSummary(
                  id: 'manga-1',
                  sourceId: 'mangadex',
                  title: 'Solo Leveling',
                  chapterCount: 1,
                  genres: [],
                  coverUrl: '',
                ),
                chapters: [
                  SourceChapterSummary(
                    id: 'manga-1:1',
                    sourceId: 'mangadex',
                    seriesId: 'manga-1',
                    title: 'Chapter 1',
                    number: 1,
                    pageCount: 2,
                  ),
                ],
              ),
            ),
          ],
          const SourceReaderScreen(
            sourceId: 'mangadex',
            seriesId: 'manga-1',
            chapterId: 'manga-1:1',
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      return outbox;
    }

    testWidgets('a page read here is pushed to the server outbox',
        (tester) async {
      // This reader used to keep progress on the phone alone, so a chapter
      // read from the Sources tab never reached the server: no progress row,
      // no reading time, and the web and the home shelf never saw it.
      final outbox = await pumpReader(tester);

      // The series page the reader sits on holds its chapter list open; the
      // number progress is filed under comes from there.
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SourceReaderScreen)),
      );
      final keepAlive = container.listen(
        sourceSeriesDetailProvider(series),
        (_, __) {},
      );
      addTearDown(keepAlive.close);
      await tester.pump();

      await tester.pump(const Duration(milliseconds: 600));

      expect(outbox.pushes, isNotEmpty);
      final push = outbox.pushes.last;
      expect(push.sourceId, 'mangadex');
      expect(push.seriesKey, 'manga-1');
      expect(push.chapterKey, 'manga-1:1');
      expect(push.lastPage, 1);
      expect(push.pageCount, 2);
      expect(push.isCompleted, isFalse);
      expect(push.chapterNumber, 1);

      // The phone's own record is still written, for the series page.
      final local = container.read(sourceProgressProvider.notifier).progressFor(
            sourceId: 'mangadex',
            seriesId: 'manga-1',
            chapterId: 'manga-1:1',
          );
      expect(local?.page, 1);
    });

    testWidgets('the save made on the way out of the reader is pushed too',
        (tester) async {
      // ReaderContent flushes its pending save from dispose(). The screen used
      // to reach its providers through `ref` at that moment, which throws on a
      // deactivated element — and the error was swallowed, dropping the very
      // save that finishes the chapter.
      final outbox = await pumpReader(tester);

      final list = tester.widget<ListView>(find.byType(ListView)).controller!;
      list.jumpTo(list.position.maxScrollExtent);
      await tester.pump();
      // Leave before the 500ms debounce fires.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      expect(outbox.pushes, isNotEmpty);
      final push = outbox.pushes.last;
      expect(push.chapterKey, 'manga-1:1');
      expect(push.lastPage, 2);
      expect(push.isCompleted, isTrue);
    });

    testWidgets('closing the reader refreshes the library shelves',
        (tester) async {
      // The Library tab and the resume strip stay mounted under the reader,
      // so without this they kept saying "Not started" after a read.
      await pumpReader(tester);
      expect(readState.calls, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      expect(readState.calls, 1);
    });
  });
}
