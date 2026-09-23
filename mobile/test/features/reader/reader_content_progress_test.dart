import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/features/reader/models/reader_chapter.dart';
import 'package:manhwamaniacs/features/reader/models/reader_feed.dart';
import 'package:manhwamaniacs/features/reader/models/reader_page.dart';
import 'package:manhwamaniacs/features/reader/utils/page_extents.dart';
import 'package:manhwamaniacs/features/reader/utils/page_layout.dart';
import 'package:manhwamaniacs/features/reader/widgets/reader_content.dart';
import 'package:manhwamaniacs/features/settings/models/reader_defaults.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A chapter is finished when its last page has been read, however short that
/// page is and however fast the reader went past it.
///
/// Both readers file progress through [ReaderContent], and completion is only
/// ever `page >= pageCount` on the page it reports. Two ways that page was
/// never reported: a last page too short to reach the reading line before the
/// list runs out of scroll, and a seam crossed inside the save debounce.

/// Tall pages, then a short last one — the credits banner at the end of the
/// newest chapter of an ongoing series.
ReaderChapter _chapter(
  String id, {
  int pages = 4,
  int lastPageHeight = 2400,
}) =>
    ReaderChapter(
      id: id,
      seriesId: 'series',
      title: 'Chapter $id',
      pageCount: pages,
      pages: [
        for (var n = 1; n <= pages; n++)
          ReaderPage(
            id: '$id:$n',
            number: n,
            imageUrl: 'http://example.test/$id/$n',
            width: 800,
            height: n == pages ? lastPageHeight : 2400,
          ),
      ],
    );

Future<SharedPreferences> _freshPrefs() async {
  SharedPreferences.setMockInitialValues({});
  return SharedPreferences.getInstance();
}

Widget _wrap(SharedPreferences prefs, Widget child) => ProviderScope(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      child: MaterialApp(home: child),
    );

/// A mounted reader, the progress it has saved, and the geometry it lays out
/// with — built the way the reader builds it, seam dividers included, so the
/// offsets below land on the pages they name whatever width the test view is.
typedef _Reader = ({
  List<(String, int)> saved,
  ScrollController controller,
  ReaderPageMetrics metrics,
});

Future<_Reader> _pumpReader(WidgetTester tester, ReaderFeed feed) async {
  final prefs = await _freshPrefs();
  await tester.binding.setSurfaceSize(const Size(430, 932));
  addTearDown(() => tester.binding.setSurfaceSize(null));

  final extents = ReaderPageExtents(feed.pages);
  addTearDown(extents.dispose);
  final saved = <(String, int)>[];
  await tester.pumpWidget(
    _wrap(
      prefs,
      ReaderContent(
        feed: feed,
        scrollStorageKey: 'series:1',
        pageExtents: extents,
        onSaveProgress: (chapter, page) async => saved.add((chapter.id, page)),
        onBack: () {},
        onOpenSeries: () {},
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));

  final viewport = MediaQuery.sizeOf(tester.element(find.byType(ListView)));
  return (
    saved: saved,
    controller: tester.widget<ListView>(find.byType(ListView)).controller!,
    metrics: ReaderPageMetrics.of(
      extents,
      direction: ReadingDirection.vertical,
      fitMode: ReaderFitMode.width,
      viewportWidth: viewport.width,
      viewportHeight: viewport.height,
      leadingInsets: {
        for (var c = 1; c < feed.chapters.length; c++)
          feed.startOfChapter(c): kChapterSeamExtent,
      },
    ),
  );
}

/// An offset that puts the reading line just inside flat page [page].
double _onPage(_Reader reader, int page) =>
    reader.metrics.offsetToPage(page) + 10;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('isAtScrollEnd', () {
    test('is true only within an edge of the real end of the list', () {
      expect(isAtScrollEnd(scrollOffset: 1000, maxScroll: 1000), isTrue);
      expect(isAtScrollEnd(scrollOffset: 980, maxScroll: 1000), isTrue);
      // Overscroll past the end (iOS bounce) is still the end.
      expect(isAtScrollEnd(scrollOffset: 1040, maxScroll: 1000), isTrue);
      expect(isAtScrollEnd(scrollOffset: 900, maxScroll: 1000), isFalse);
      // A list with nothing to scroll is at its end from the first frame.
      expect(isAtScrollEnd(scrollOffset: 0, maxScroll: 0), isTrue);
    });
  });

  group('completion', () {
    testWidgets('a short last page is read at the very bottom of the feed',
        (tester) async {
      // A 300px-tall banner under 2400px pages. The list runs out of scroll
      // with the banner's top still far below the reading line, so the
      // counter used to sit on page 3 of 4 at the very bottom and the chapter
      // was never finished.
      final reader = await _pumpReader(
        tester,
        ReaderFeed.single(_chapter('1', lastPageHeight: 300)),
      );

      reader.controller.jumpTo(reader.controller.position.maxScrollExtent);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(reader.saved.last, ('1', 4));
    });

    testWidgets('the bottom of the feed is not reached a screen early',
        (tester) async {
      final reader = await _pumpReader(
        tester,
        ReaderFeed.single(_chapter('1', lastPageHeight: 300)),
      );

      // Half a screen short of the end: the banner is on screen, but so is
      // most of page 3 — this is still page 3.
      reader.controller
          .jumpTo(reader.controller.position.maxScrollExtent - 466);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(reader.saved.last, ('1', 3));
    });

    testWidgets(
        'a seam crossed inside the save debounce still finishes the chapter '
        'left behind', (tester) async {
      final reader = await _pumpReader(
        tester,
        ReaderFeed.of([_chapter('1'), _chapter('2')]),
      );

      // Onto chapter 1's last page, and straight on into chapter 2 before the
      // 500ms debounce could write it.
      reader.controller.jumpTo(_onPage(reader, 4));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      reader.controller.jumpTo(_onPage(reader, 5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(reader.saved, contains(('1', 4)));
      expect(reader.saved.last, ('2', 1));
    });

    testWidgets('every chapter passed over is finished, not only the last',
        (tester) async {
      // One fling can clear a short chapter between two scroll callbacks.
      final reader = await _pumpReader(
        tester,
        ReaderFeed.of([
          _chapter('1'),
          _chapter('2', pages: 1),
          _chapter('3'),
        ]),
      );

      reader.controller.jumpTo(_onPage(reader, 7));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(reader.saved, containsAll([('1', 4), ('2', 1)]));
      expect(reader.saved.last, ('3', 2));
    });

    testWidgets('crossing back and forth sends the completion once',
        (tester) async {
      final reader = await _pumpReader(
        tester,
        ReaderFeed.of([_chapter('1'), _chapter('2')]),
      );

      for (var i = 0; i < 3; i++) {
        reader.controller.jumpTo(_onPage(reader, 6));
        await tester.pump();
        reader.controller.jumpTo(_onPage(reader, 3));
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 600));

      expect(reader.saved.where((entry) => entry == ('1', 4)), hasLength(1));
    });

    testWidgets('stopping part-way through a chapter does not finish it',
        (tester) async {
      final reader = await _pumpReader(
        tester,
        ReaderFeed.of([_chapter('1'), _chapter('2')]),
      );

      reader.controller.jumpTo(_onPage(reader, 2));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(reader.saved, isNot(contains(('1', 4))));
      expect(reader.saved.last, ('1', 2));
    });
  });
}
