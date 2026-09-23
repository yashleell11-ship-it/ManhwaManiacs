/// What a series screen knows about reading position.
///
/// The screens used to read only this phone's store, which the novel reader
/// never writes: a book read in the novel reader, or on the web, showed
/// nothing read and offered "Start reading" however far in the reader was.
/// They now read the server's rows for the series as well, merged
/// furthest-wins with the phone's own.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/library/utils/resume_location.dart';
import 'package:manhwamaniacs/features/reader/models/reading_progress.dart';
import 'package:manhwamaniacs/features/reader/repositories/reader_repository.dart';
import 'package:manhwamaniacs/features/sources/providers/source_progress_provider.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/reading_navigation_cases.dart';
import '../../support/test_overrides.dart';

class _SeriesProgressRepository implements ReaderRepository {
  _SeriesProgressRepository(this.rows);

  final List<ReadingProgress> rows;
  final asked = <String>[];

  @override
  Future<Result<List<ReadingProgress>>> seriesProgress({
    required String sourceId,
    required String seriesKey,
  }) async {
    asked.add('$sourceId/$seriesKey');
    return Ok(rows);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

ReadingProgress _row(
  String key,
  int page,
  int pageCount, {
  bool completed = false,
  required DateTime at,
}) =>
    ReadingProgress(
      id: 1,
      sourceId: 'novelbin',
      seriesKey: 'tbate',
      chapterKey: key,
      chapterNumber: double.parse(key),
      lastPage: page,
      pageCount: pageCount,
      scrollOffsetPx: 0,
      isCompleted: completed,
      lastReadAt: at,
      timeSpentSeconds: 0,
    );

Future<ProviderContainer> _container(
  _SeriesProgressRepository repo, {
  bool withProfile = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPrefsProvider.overrideWithValue(prefs),
      readerRepositoryProvider.overrideWithValue(repo),
      if (withProfile) activeProfileOverride(),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

const _tbate = (sourceId: 'novelbin', seriesId: 'tbate');

void main() {
  test('the book page resumes from rows only the server holds', () async {
    // The owner's TBATE: key 122 finished in the novel reader, then five
    // seconds on the prologue. Neither is in this phone's store.
    final repo = _SeriesProgressRepository([
      _row('122', 55, 55, completed: true, at: DateTime.utc(2026, 9, 19, 22)),
      _row('1', 13, 16, at: DateTime.utc(2026, 9, 20, 8)),
    ]);
    final container = await _container(repo);
    final sub = container.listen(sourceSeriesProgressProvider(_tbate), (_, __) {});
    addTearDown(sub.close);

    await container.read(sourceSeriesServerProgressProvider(_tbate).future);
    final progress = container.read(sourceSeriesProgressProvider(_tbate));

    expect(repo.asked, ['novelbin/tbate']);
    expect(progress['1']!.page, 13);
    expect(progress['1']!.pageCount, 16);
    expect(
      seriesContinue(chapters: caseBook('tbate'), progress: progress),
      (kind: SeriesContinueKind.resume, point: (chapterKey: '123', page: 1)),
    );
  });

  test("a page this phone just recorded wins over the server's older one",
      () async {
    final repo = _SeriesProgressRepository([
      _row('5', 9, 71, at: DateTime.utc(2026, 9, 4, 11)),
    ]);
    final container = await _container(repo);
    final sub = container.listen(sourceSeriesProgressProvider(_tbate), (_, __) {});
    addTearDown(sub.close);
    await container.read(sourceSeriesServerProgressProvider(_tbate).future);

    await container.read(sourceProgressProvider.notifier).record(
          sourceId: 'novelbin',
          seriesId: 'tbate',
          chapterId: '5',
          page: 17,
          pageCount: 71,
        );

    expect(container.read(sourceSeriesProgressProvider(_tbate))['5']!.page, 17);
  });

  test('asks nothing with no reading profile in scope', () async {
    final repo = _SeriesProgressRepository([
      _row('5', 9, 71, at: DateTime.utc(2026, 9, 4, 11)),
    ]);
    final container = await _container(repo, withProfile: false);

    final server =
        await container.read(sourceSeriesServerProgressProvider(_tbate).future);

    expect(server, isEmpty);
    expect(repo.asked, isEmpty);
  });
}
