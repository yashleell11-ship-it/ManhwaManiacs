import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/library/providers/library_read_state.dart';
import 'package:manhwamaniacs/features/reader/models/bookmark.dart';
import 'package:manhwamaniacs/features/reader/models/chapter_manifest.dart';
import 'package:manhwamaniacs/features/reader/models/chapter_manifest_window.dart';
import 'package:manhwamaniacs/features/reader/models/reading_progress.dart';
import 'package:manhwamaniacs/features/reader/providers/reader_chapter_provider.dart';
import 'package:manhwamaniacs/features/reader/repositories/reader_repository.dart';
import 'package:manhwamaniacs/features/reader/screens/reader_screen.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../support/test_overrides.dart';

const _sourceId = 'asurascans';
const _seriesKey = 'solo-leveling';
const _chapterKey = '1';

class _FakeReaderRepository implements ReaderRepository {
  int saveProgressCalls = 0;

  @override
  Future<Result<ChapterManifest>> manifest({
    required String sourceId,
    required String seriesKey,
    required String chapterKey,
  }) async =>
      Ok(_sampleManifest());

  @override
  Future<Result<ReadingProgress>> saveProgress(ProgressPush push) async {
    saveProgressCalls++;
    return Ok(
      ReadingProgress(
        id: 1,
        sourceId: push.sourceId,
        seriesKey: push.seriesKey,
        chapterKey: push.chapterKey,
        chapterNumber: push.chapterNumber,
        lastPage: push.lastPage,
        pageCount: push.pageCount,
        scrollOffsetPx: push.scrollOffsetPx,
        isCompleted: push.isCompleted,
        timeSpentSeconds: push.timeSpentSeconds,
      ),
    );
  }

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
  Future<Result<BookmarkSyncResult>> syncBookmarks(List<BookmarkOp> ops) async =>
      Ok(
        BookmarkSyncResult(
          received: ops.length,
          created: ops.length,
          updated: 0,
          tombstoned: 0,
          rejected: 0,
          serverIds: {
            for (final op in ops) op.bookmark.clientId: 1,
          },
        ),
      );

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
  Future<Result<void>> deleteBookmark(int bookmarkId) async => const Ok(null);

  @override
  Future<Result<ChapterManifestWindow>> manifestWindow({
    required String sourceId,
    required String seriesKey,
    required List<String> chapterKeys,
  }) =>
      throw UnimplementedError();
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

ChapterManifest _sampleManifest() {
  return const ChapterManifest(
    sourceId: _sourceId,
    seriesKey: _seriesKey,
    chapterKey: _chapterKey,
    chapterNumber: 1,
    pageCount: 2,
    prev: null,
    next: '2',
    pages: [
      ManifestPage(number: 1, url: '/sources/$_sourceId/pages/101/image'),
      ManifestPage(number: 2, url: '/sources/$_sourceId/pages/102/image'),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReaderScreen', () {
    testWidgets('renders chapter controls and page indicator', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final repo = _FakeReaderRepository();

      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPrefsProvider.overrideWithValue(prefs),
            readerRepositoryProvider.overrideWithValue(repo),
            apiBaseUrlOverride('http://127.0.0.1:8000'),
          ],
          child: const MaterialApp(
            home: ReaderScreen(
              sourceId: _sourceId,
              seriesKey: _seriesKey,
              chapterKey: _chapterKey,
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Chapter 1'), findsOneWidget);
      expect(find.textContaining('Page 1 / 2'), findsOneWidget);
      expect(find.byTooltip('Back'), findsOneWidget);

      // Save bookmark is in the reader settings sheet.
      await tester.tap(find.byTooltip('Reader settings'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Save bookmark'), findsOneWidget);
    });

    testWidgets('shows retry state on chapter load failure', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPrefsProvider.overrideWithValue(prefs),
            chapterManifestProvider(
              (sourceId: _sourceId, seriesKey: _seriesKey, chapterKey: _chapterKey),
            ).overrideWith((ref) async {
              throw Exception('network failure');
            }),
          ],
          child: const MaterialApp(
            home: ReaderScreen(
              sourceId: _sourceId,
              seriesKey: _seriesKey,
              chapterKey: _chapterKey,
            ),
          ),
        ),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Go back'), findsOneWidget);
    });

    testWidgets('closing the reader refreshes the library shelves',
        (tester) async {
      // The Library tab and the resume strip stay mounted under the reader,
      // so without this they kept saying "Not started" after a read.
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.binding.setSurfaceSize(const Size(430, 932));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      late _RecordingReadState readState;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPrefsProvider.overrideWithValue(prefs),
            readerRepositoryProvider.overrideWithValue(_FakeReaderRepository()),
            apiBaseUrlOverride('http://127.0.0.1:8000'),
            libraryReadStateProvider.overrideWith(
              (ref) => readState = _RecordingReadState(ref),
            ),
          ],
          child: const MaterialApp(
            home: ReaderScreen(
              sourceId: _sourceId,
              seriesKey: _seriesKey,
              chapterKey: _chapterKey,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(readState.calls, 0);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      expect(readState.calls, 1);
    });
  });
}
