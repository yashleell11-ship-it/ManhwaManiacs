import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloads_scope.dart';
import 'package:manhwamaniacs/features/downloads/providers/progress_outbox_provider.dart';
import 'package:manhwamaniacs/features/downloads/utils/progress_outbox_batch.dart';
import 'package:manhwamaniacs/features/downloads/utils/progress_outbox_priority.dart';
import 'package:manhwamaniacs/features/reader/models/reading_progress.dart';
import 'package:manhwamaniacs/features/reader/repositories/reader_repository.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/downloads_test_support.dart';

class _Repo extends Mock implements ReaderRepository {}

ProgressPush _push(
  String series,
  String chapter, {
  String source = 'asurascans',
  double? number,
  DateTime? at,
}) =>
    ProgressPush(
      sourceId: source,
      seriesKey: series,
      chapterKey: chapter,
      chapterNumber: number,
      lastPage: 3,
      pageCount: 20,
      lastReadAt: at,
    );

void main() {
  group('chapterNumberFromKey', () {
    test('reads the number off an Asura key whose series holds dashes', () {
      expect(
        chapterNumberFromKey(
          sourceId: 'asurascans',
          chapterKey: 'surviving-as-a-genius-on-borrowed-time-6f7fe6eb:94',
        ),
        94,
      );
      expect(
        chapterNumberFromKey(
          sourceId: 'demonicscans',
          chapterKey: 'Magic-Emperor:904.5',
        ),
        904.5,
      );
    });

    test('is null wherever the tail is not certainly a chapter number', () {
      // Tapas: the tail is an episode id.
      expect(
        chapterNumberFromKey(sourceId: 'tapas', chapterKey: 'slug:2345678'),
        isNull,
      );
      // Asura's slug fallback when the API gave no number.
      expect(
        chapterNumberFromKey(
          sourceId: 'asurascans',
          chapterKey: 'mage-05c7df14:chapter-epilogue',
        ),
        isNull,
      );
      expect(
        chapterNumberFromKey(sourceId: 'asurascans', chapterKey: '94'),
        isNull,
      );
    });
  });

  group('rankProgressForKeeping', () {
    test('furthest per series first, then most recent, then newest-first', () {
      final t = DateTime.utc(2026, 9, 20);
      final pushes = [
        _push('a', 'a:10', at: t), // 0: a's furthest, oldest
        _push('a', 'a:3', at: t.add(const Duration(hours: 3))), // 1: a recent
        _push('a', 'a:4', at: t.add(const Duration(hours: 1))), // 2
        _push('b', 'b:1', at: t.add(const Duration(hours: 2))), // 3: b both
        _push('a', 'a:5', at: t.add(const Duration(hours: 2))), // 4
      ];

      final ranked = rankProgressForKeeping(pushes);

      expect(ranked.furthest, 2);
      expect(ranked.order, [0, 3, 1, 4, 2]);
    });

    test('a series with no numbers keeps its most recent read on top', () {
      final t = DateTime.utc(2026, 9, 20);
      final ranked = rankProgressForKeeping([
        _push('s', 'x', source: 'mangadex', at: t.add(const Duration(days: 1))),
        _push('s', 'y', source: 'mangadex', at: t),
      ]);
      expect(ranked.order.first, 0);
      expect(ranked.furthest, 1);
    });
  });

  group('outboxGroupsToDrop', () {
    CollapsedProgress group(int id, ProgressPush push) =>
        (outboxIds: [id], push: push);

    test('never drops a series’ furthest chapter, even over the cap', () {
      final t = DateTime.utc(2026, 9, 20);
      final groups = [
        for (var i = 0; i < 4; i++)
          group(i, _push('s$i', 's$i:${i + 1}', at: t)),
      ];
      expect(outboxGroupsToDrop(groups, max: 2), isEmpty);
    });

    test('drops the oldest non-furthest chapters first', () {
      final t = DateTime.utc(2026, 9, 20);
      final groups = [
        group(0, _push('a', 'a:50', at: t)),
        for (var i = 1; i <= 5; i++)
          group(i, _push('a', 'a:$i', at: t.add(Duration(hours: i)))),
      ];
      // Keep 3: the furthest (a:50), the most recent (a:5), then a:4.
      expect(outboxGroupsToDrop(groups, max: 3), {1, 2, 3});
    });
  });

  group('ProgressOutboxController compaction', () {
    initSqfliteFfiForTests();
    setUpAll(() => registerFallbackValue(<ProgressPush>[]));

    late TestDownloadsHarness harness;
    setUp(() async => harness = await TestDownloadsHarness.create());
    tearDown(() async => harness.dispose());

    test('an offline backlog past the ceiling keeps each series’ '
        'furthest chapter, however old it is', () async {
      final repo = _Repo();
      when(() => repo.saveProgressBatch(any())).thenAnswer(
        (_) async => const Err(NetworkError(message: 'offline')),
      );
      final store = harness.storeFor('u1p1');
      final container = ProviderContainer(
        overrides: [
          downloadsStoreProvider.overrideWithValue(store),
          readerRepositoryProvider.overrideWithValue(repo),
        ],
      );
      addTearDown(container.dispose);
      final controller = container.read(progressOutboxControllerProvider);

      // The furthest chapter of a long series, read first — so it is the
      // oldest row in the outbox by far.
      await controller.save(
        _push(
          'mage-08677664',
          'mage-08677664:275',
          number: 275,
        ),
      );
      // Then a re-read of every chapter before it, and a pile of reading in
      // another series: a different chapter each time, so nothing folds.
      const saves = kProgressOutboxMaxGroups + 101;
      for (var i = 1; i <= saves; i++) {
        await controller.save(
          i < 275
              ? _push('mage-08677664', 'mage-08677664:$i')
              : _push('other', 'other-c$i', source: 'mangadex'),
        );
      }

      final queued = await store.pendingProgressOutbox();
      final chapters = queued.map((row) => row.$2.chapterKey).toSet();
      expect(chapters, contains('mage-08677664:275'));
      expect(queued.length, lessThanOrEqualTo(kProgressOutboxMaxGroups + 100));
    });
  });
}
