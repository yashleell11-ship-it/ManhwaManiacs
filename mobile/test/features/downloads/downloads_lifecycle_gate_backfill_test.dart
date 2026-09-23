import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/downloads/providers/bookmark_outbox_provider.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloads_scope.dart';
import 'package:manhwamaniacs/features/downloads/providers/retention_maintenance_provider.dart';
import 'package:manhwamaniacs/features/downloads/queue/download_queue_controller.dart';
import 'package:manhwamaniacs/features/downloads/services/retention_maintenance.dart';
import 'package:manhwamaniacs/features/downloads/store/downloads_store.dart';
import 'package:manhwamaniacs/features/downloads/widgets/downloads_lifecycle_gate.dart';
import 'package:manhwamaniacs/features/reader/models/reading_progress.dart';
import 'package:manhwamaniacs/features/reader/repositories/reader_repository.dart';
import 'package:manhwamaniacs/features/sources/models/source_chapter_progress.dart';
import 'package:manhwamaniacs/features/sources/providers/source_progress_backfill.dart';
import 'package:manhwamaniacs/features/sources/providers/source_progress_provider.dart';
import 'package:manhwamaniacs/shared/providers/core_providers.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/test_overrides.dart';

const _series = 'surviving-as-a-genius-on-borrowed-time-6f7fe6eb';

/// An outbox kept in memory, so the gate can be pumped in a widget test
/// without a database behind it.
class _MemoryOutboxStore extends Fake implements DownloadsStore {
  @override
  String get scopeId => 'u1p1';

  final Map<int, ProgressPush> rows = {};
  var _nextId = 1;

  @override
  Future<void> enqueueProgress(ProgressPush push) async {
    rows[_nextId++] = push;
  }

  @override
  Future<List<(int, ProgressPush)>> pendingProgressOutbox() async => [
        for (final entry in rows.entries) (entry.key, entry.value),
      ];

  @override
  Future<void> clearProgressOutbox(List<int> outboxIds) async {
    outboxIds.forEach(rows.remove);
  }
}

class _Repo extends Mock implements ReaderRepository {}

class _Bookmarks extends Fake implements BookmarkOutboxController {
  @override
  Future<bool> flush() async => true;

  @override
  Future<bool> sync() async => true;
}

/// Its sweep throws (Fake), which the gate already swallows.
class _Retention extends Fake implements RetentionMaintenance {}

class _IdleQueue extends DownloadQueueController {
  @override
  DownloadQueueState build() => const DownloadQueueState();

  @override
  void resumePendingOnLaunch() {}

  @override
  void setForeground(bool foreground) {}
}

final _scope = StateProvider<String?>((ref) => null);

void main() {
  setUpAll(() => registerFallbackValue(<ProgressPush>[]));

  final readAt = DateTime.utc(2026, 9, 20, 20, 46, 12);

  Future<({ProviderContainer container, List<List<ProgressPush>> sent})>
      pumpGate(WidgetTester tester, {required String? scope}) async {
    SharedPreferences.setMockInitialValues(
      testPrefsDefaults({
        sourceProgressStorageKey(1): jsonEncode({
          sourceProgressKey(
            sourceId: 'asurascans',
            seriesId: _series,
            chapterId: '$_series:94',
          ): SourceChapterProgress(
            page: 31,
            pageCount: 31,
            completed: true,
            updatedAt: readAt,
          ).toJson(),
        }),
      }),
    );
    final prefs = await SharedPreferences.getInstance();
    final store = _MemoryOutboxStore();
    final sent = <List<ProgressPush>>[];
    final repo = _Repo();
    when(() => repo.saveProgressBatch(any())).thenAnswer((invocation) async {
      final batch = invocation.positionalArguments.first as List<ProgressPush>;
      sent.add(batch);
      return Ok((saved: batch.length, advanced: batch.length));
    });

    final container = ProviderContainer(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        activeProfileOverride(),
        _scope.overrideWith((ref) => scope),
        activeDownloadsScopeIdProvider.overrideWith((ref) => ref.watch(_scope)),
        downloadsStoreProvider.overrideWith(
          (ref) => ref.watch(activeDownloadsScopeIdProvider) == null
              ? null
              : store,
        ),
        readerRepositoryProvider.overrideWithValue(repo),
        bookmarkOutboxControllerProvider.overrideWithValue(_Bookmarks()),
        retentionMaintenanceProvider.overrideWithValue(_Retention()),
        downloadQueueControllerProvider.overrideWith(_IdleQueue.new),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const DownloadsLifecycleGate(child: SizedBox()),
      ),
    );
    await tester.pump();
    await tester.pump();
    return (container: container, sent: sent);
  }

  testWidgets('launch with a profile: stranded Sources-tab progress is queued '
      'and sent in the same flush, dated when it was read', (tester) async {
    final (:container, :sent) = await pumpGate(tester, scope: 'u1p1');

    final pushed = sent.expand((batch) => batch).toList();
    expect(pushed, hasLength(1));
    final push = pushed.single;
    expect(push.seriesKey, _series);
    expect(push.chapterKey, '$_series:94');
    expect(push.chapterNumber, 94);
    expect(push.isCompleted, isTrue);
    expect(push.timeSpentSeconds, 0);
    expect(push.lastReadAt, readAt);
    expect(
      container.read(sharedPrefsProvider).getBool(sourceProgressBackfilledKey(1)),
      isTrue,
    );
  });

  testWidgets('a session that resolves after launch is backfilled then, and '
      'only once', (tester) async {
    final (:container, :sent) = await pumpGate(tester, scope: null);
    expect(sent, isEmpty);

    container.read(_scope.notifier).state = 'u1p1';
    await tester.pump();
    await tester.pump();
    expect(sent.expand((batch) => batch).map((p) => p.chapterKey), [
      '$_series:94',
    ]);

    // Signed out and back in: the flag is set, nothing is queued again.
    container.read(_scope.notifier).state = null;
    await tester.pump();
    container.read(_scope.notifier).state = 'u1p1';
    await tester.pump();
    await tester.pump();
    expect(sent.expand((batch) => batch), hasLength(1));
  });
}
