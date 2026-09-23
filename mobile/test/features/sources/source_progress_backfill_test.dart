import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloads_scope.dart';
import 'package:manhwamaniacs/features/downloads/store/downloads_store.dart';
import 'package:manhwamaniacs/features/downloads/utils/progress_outbox_batch.dart';
import 'package:manhwamaniacs/features/profiles/models/mood.dart';
import 'package:manhwamaniacs/features/profiles/models/profile.dart';
import 'package:manhwamaniacs/features/profiles/providers/profiles_providers.dart';
import 'package:manhwamaniacs/features/reader/models/reading_progress.dart';
import 'package:manhwamaniacs/features/sources/models/source_chapter_progress.dart';
import 'package:manhwamaniacs/features/sources/providers/source_progress_backfill.dart';
import 'package:manhwamaniacs/features/sources/providers/source_progress_provider.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/downloads_test_support.dart';

const _surviving = 'surviving-as-a-genius-on-borrowed-time-6f7fe6eb';
const _zenith = 'childhood-friend-of-the-zenith-05c7df14';

/// The key the Sources reader stored an Asura chapter under: its chapter id
/// is `<series>:<number>`, so the key holds three ':'.
String _asuraKey(String series, String number) => sourceProgressKey(
      sourceId: 'asurascans',
      seriesId: series,
      chapterId: '$series:$number',
    );

SourceChapterProgress _record(
  DateTime at, {
  int page = 12,
  int pageCount = 40,
  bool completed = false,
}) =>
    SourceChapterProgress(
      page: page,
      pageCount: pageCount,
      completed: completed,
      updatedAt: at,
    );

String _encode(Map<String, SourceChapterProgress> records) => jsonEncode({
      for (final entry in records.entries) entry.key: entry.value.toJson(),
    });

class _ActiveProfile extends ActiveProfileNotifier {
  _ActiveProfile(this._initial);

  final int? _initial;

  @override
  ActiveProfile? build() => _initial == null
      ? null
      : ActiveProfile(
          id: _initial,
          name: 'P$_initial',
          avatarKey: null,
          mood: Mood.neutral,
        );

  void switchTo(int id) => state = ActiveProfile(
        id: id,
        name: 'P$id',
        avatarKey: null,
        mood: Mood.neutral,
      );
}

/// A store whose first outbox write throws, as a database that is not ready
/// yet does.
class _FlakyStore extends DownloadsStore {
  _FlakyStore(DownloadsStore inner)
      : super(
          scopeId: inner.scopeId,
          database: inner.database,
          blobStore: inner.blobStore,
        );

  int failures = 1;

  @override
  Future<void> enqueueProgress(ProgressPush push) {
    if (failures > 0) {
      failures--;
      throw StateError('database not open');
    }
    return super.enqueueProgress(push);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  initSqfliteFfiForTests();

  group('parseSourceProgressKey', () {
    test('an Asura key splits at its series, whatever the chapter holds', () {
      final parts = parseSourceProgressKey(_asuraKey(_surviving, '94'));
      expect(parts, isNotNull);
      expect(parts!.sourceId, 'asurascans');
      expect(parts.seriesId, _surviving);
      expect(parts.chapterId, '$_surviving:94');
    });

    test('a decimal Asura chapter keeps its whole id', () {
      final parts = parseSourceProgressKey(_asuraKey(_zenith, '107.5'));
      expect(parts!.seriesId, _zenith);
      expect(parts.chapterId, '$_zenith:107.5');
    });

    test('a key with one separator left is split there', () {
      final parts = parseSourceProgressKey(
        sourceProgressKey(
          sourceId: 'mangadex',
          seriesId: '32d76d19-8a05',
          chapterId: 'a1c7c817-4e59',
        ),
      );
      expect(parts!.seriesId, '32d76d19-8a05');
      expect(parts.chapterId, 'a1c7c817-4e59');
    });

    test('a known series settles a split the key alone cannot', () {
      const key = 'webtoons:list:123:ep:4';
      expect(parseSourceProgressKey(key), isNull);
      final parts = parseSourceProgressKey(
        key,
        knownSeries: {('webtoons', 'list:123')},
      );
      expect(parts!.seriesId, 'list:123');
      expect(parts.chapterId, 'ep:4');
    });

    test('no source, or nothing after it, is no key', () {
      expect(parseSourceProgressKey('asurascans'), isNull);
      expect(parseSourceProgressKey(':series:chapter'), isNull);
      expect(parseSourceProgressKey('asurascans:series'), isNull);
    });
  });

  group('planSourceProgressBackfill', () {
    final readAt = DateTime.utc(2026, 9, 20, 20, 46, 12);

    test('each record becomes a push dated when it was read, with no '
        'reading time', () {
      final plan = planSourceProgressBackfill({
        _asuraKey(_surviving, '94'): _record(
          readAt,
          page: 31,
          pageCount: 31,
          completed: true,
        ),
      });

      final push = plan.single;
      expect(push.sourceId, 'asurascans');
      expect(push.seriesKey, _surviving);
      expect(push.chapterKey, '$_surviving:94');
      expect(push.chapterNumber, 94);
      expect(push.lastPage, 31);
      expect(push.pageCount, 31);
      expect(push.isCompleted, isTrue);
      expect(push.timeSpentSeconds, 0);
      expect(push.lastReadAt, readAt);
    });

    test('a chapter number is sent only when the key spells one out', () {
      final plan = planSourceProgressBackfill({
        'tapas:some-slug:some-slug:2345678': _record(readAt),
        _asuraKey(_zenith, 'side-story'): _record(readAt),
      });
      expect(plan.map((p) => p.chapterNumber), everyElement(isNull));
    });

    test('over budget, every series keeps its furthest and latest chapter',
        () {
      final records = {
        // Surviving: read up to 94 a while ago, then a re-read of chapter 3.
        _asuraKey(_surviving, '94'): _record(readAt),
        for (var n = 10; n < 20; n++)
          _asuraKey(_surviving, '$n'):
              _record(readAt.subtract(Duration(days: 30 - n))),
        _asuraKey(_surviving, '3'): _record(readAt.add(const Duration(days: 1))),
        // Zenith: chapters 1-107, the furthest also the oldest record.
        _asuraKey(_zenith, '107'): _record(readAt.subtract(const Duration(days: 60))),
        for (var n = 1; n < 107; n++)
          _asuraKey(_zenith, '$n'):
              _record(readAt.subtract(Duration(days: 59, minutes: 200 - n))),
      };

      final plan = planSourceProgressBackfill(records, budget: 5);
      final chapters = plan.map((p) => p.chapterKey).toSet();

      expect(plan, hasLength(5));
      expect(chapters, contains('$_surviving:94'));
      expect(chapters, contains('$_surviving:3'));
      expect(chapters, contains('$_zenith:107'));
      expect(chapters, contains('$_zenith:106'));
      // Then the newest of the rest.
      expect(chapters, contains('$_surviving:19'));
      // Queued oldest read first.
      final stamps = plan.map((p) => p.lastReadAt!).toList();
      expect(stamps, orderedEquals([...stamps]..sort()));
    });

    test('a budget smaller than the series count still keeps every '
        'series’ furthest chapter', () {
      final plan = planSourceProgressBackfill(
        {
          _asuraKey(_surviving, '94'): _record(readAt),
          _asuraKey(_surviving, '93'): _record(readAt),
          _asuraKey(_zenith, '107'): _record(readAt),
        },
        budget: 0,
      );
      expect(
        plan.map((p) => p.chapterKey).toSet(),
        {'$_surviving:94', '$_zenith:107'},
      );
    });

    test('a record whose key cannot be split is left out', () {
      final plan = planSourceProgressBackfill({
        'webtoons:list:123:ep:4': _record(readAt),
        _asuraKey(_surviving, '94'): _record(readAt),
      });
      expect(plan.map((p) => p.chapterKey), ['$_surviving:94']);
    });
  });

  group('SourceProgressBackfill.run', () {
    late TestDownloadsHarness harness;
    late SharedPreferences prefs;
    final readAt = DateTime.utc(2026, 9, 20, 20, 46, 12);

    setUp(() async {
      harness = await TestDownloadsHarness.create();
    });

    tearDown(() async {
      await harness.dispose();
    });

    Future<ProviderContainer> containerWith(
      Map<String, Object> stored, {
      int? profileId = 1,
      DownloadsStore Function(String scopeId)? storeFor,
    }) async {
      SharedPreferences.setMockInitialValues(stored);
      prefs = await SharedPreferences.getInstance();
      final stores = <String, DownloadsStore>{};
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          activeProfileProvider.overrideWith(() => _ActiveProfile(profileId)),
          downloadsStoreProvider.overrideWith((ref) {
            final id = ref.watch(activeProfileProvider)?.id;
            if (id == null) return null;
            final scope = 'u1p$id';
            return stores[scope] ??=
                (storeFor ?? harness.storeFor)(scope);
          }),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    Future<List<ProgressPush>> queued(String scopeId) async => [
          for (final (_, push)
              in await harness.storeFor(scopeId).pendingProgressOutbox())
            push,
        ];

    test('queues every stored record with its own read time and no reading '
        'time, then sets the flag', () async {
      final container = await containerWith({
        sourceProgressStorageKey(1): _encode({
          _asuraKey(_surviving, '94'): _record(readAt, page: 31, pageCount: 31),
          _asuraKey(_zenith, '107'):
              _record(readAt.subtract(const Duration(days: 1)), page: 6),
        }),
      });

      await container.read(sourceProgressBackfillProvider).run();

      final rows = await queued('u1p1');
      expect(rows, hasLength(2));
      final surviving = rows.singleWhere((p) => p.seriesKey == _surviving);
      expect(surviving.chapterKey, '$_surviving:94');
      expect(surviving.chapterNumber, 94);
      expect(surviving.lastReadAt, readAt);
      expect(surviving.timeSpentSeconds, 0);
      expect(surviving.lastPage, 31);
      final zenith = rows.singleWhere((p) => p.seriesKey == _zenith);
      expect(zenith.lastReadAt, readAt.subtract(const Duration(days: 1)));
      expect(zenith.timeSpentSeconds, 0);
      expect(prefs.getBool(sourceProgressBackfilledKey(1)), isTrue);
    });

    test('runs once: a later launch queues nothing again', () async {
      final container = await containerWith({
        sourceProgressStorageKey(1): _encode({
          _asuraKey(_surviving, '94'): _record(readAt),
        }),
      });
      final backfill = container.read(sourceProgressBackfillProvider);

      await backfill.run();
      final store = harness.storeFor('u1p1');
      final first = await store.pendingProgressOutbox();
      expect(first, hasLength(1));
      // Delivered, as a flush would.
      await store.clearProgressOutbox([for (final (id, _) in first) id]);

      await backfill.run();
      await backfill.run();
      expect(await store.pendingProgressOutbox(), isEmpty);
    });

    test('overlapping triggers share one run', () async {
      final container = await containerWith({
        sourceProgressStorageKey(1): _encode({
          _asuraKey(_surviving, '94'): _record(readAt),
        }),
      });
      final backfill = container.read(sourceProgressBackfillProvider);

      await Future.wait([backfill.run(), backfill.run(), backfill.run()]);

      expect(await queued('u1p1'), hasLength(1));
    });

    test('each profile is backfilled from its own records into its own '
        'outbox, once', () async {
      final container = await containerWith({
        sourceProgressStorageKey(1): _encode({
          _asuraKey(_surviving, '94'): _record(readAt),
        }),
        sourceProgressStorageKey(2): _encode({
          _asuraKey(_zenith, '12'): _record(readAt),
        }),
      });
      final backfill = container.read(sourceProgressBackfillProvider);

      await backfill.run();
      (container.read(activeProfileProvider.notifier) as _ActiveProfile)
          .switchTo(2);
      await backfill.run();
      await backfill.run();

      expect(
        (await queued('u1p1')).map((p) => p.chapterKey),
        ['$_surviving:94'],
      );
      expect(
        (await queued('u1p2')).map((p) => p.chapterKey),
        ['$_zenith:12'],
      );
      expect(prefs.getBool(sourceProgressBackfilledKey(1)), isTrue);
      expect(prefs.getBool(sourceProgressBackfilledKey(2)), isTrue);
    });

    test('a failure leaves the flag unset, and the next run completes it',
        () async {
      final container = await containerWith(
        {
          sourceProgressStorageKey(1): _encode({
            _asuraKey(_surviving, '94'): _record(readAt),
          }),
        },
        storeFor: (scope) => _FlakyStore(harness.storeFor(scope)),
      );
      final backfill = container.read(sourceProgressBackfillProvider);

      await backfill.run(); // must not throw
      expect(prefs.getBool(sourceProgressBackfilledKey(1)), isNull);
      expect(await queued('u1p1'), isEmpty);

      await backfill.run();
      expect(prefs.getBool(sourceProgressBackfilledKey(1)), isTrue);
      expect(
        (await queued('u1p1')).single.lastReadAt,
        readAt,
      );
    });

    test('no profile or no store: nothing runs and no flag is set', () async {
      final container = await containerWith(
        {
          sourceProgressStorageKey(1): _encode({
            _asuraKey(_surviving, '94'): _record(readAt),
          }),
        },
        profileId: null,
      );

      await container.read(sourceProgressBackfillProvider).run();

      expect(prefs.getBool(sourceProgressBackfilledKey(1)), isNull);
    });

    test('a nearly full outbox takes only what fits, furthest chapters first',
        () async {
      final container = await containerWith({
        sourceProgressStorageKey(1): _encode({
          _asuraKey(_surviving, '94'):
              _record(readAt.subtract(const Duration(days: 9))),
          for (var n = 1; n < 10; n++)
            _asuraKey(_surviving, '$n'):
                _record(readAt.subtract(Duration(days: 9 - n))),
        }),
      });
      final store = harness.storeFor('u1p1');
      for (var i = 0; i < kProgressOutboxMaxGroups - 2; i++) {
        await store.enqueueProgress(
          ProgressPush(
            sourceId: 'mangadex',
            seriesKey: 'other',
            chapterKey: 'c$i',
            lastPage: 1,
            lastReadAt: readAt,
          ),
        );
      }

      await container.read(sourceProgressBackfillProvider).run();

      final backfilled = (await queued('u1p1'))
          .where((p) => p.seriesKey == _surviving)
          .map((p) => p.chapterKey)
          .toSet();
      expect(backfilled, {'$_surviving:94', '$_surviving:9'});
    });
  });
}
