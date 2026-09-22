/// Saving a chapter's narration to the phone, end to end: what the queue asks
/// the server for, what lands on disk, and what the reader then plays.
///
/// The row is keyed `<chapter>:audio` so it cannot collide with the text row.
/// That key is the store's business and must never reach the server — it used
/// to, which answered 404, so every saved narration failed as "not narrated
/// yet" even for a chapter that was. `audio_download_test.dart` keeps the
/// store's deletion guarantees; this file is the path that fills it.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/app/theme/app_theme.dart';
import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/downloads/models/chapter_identity.dart';
import 'package:manhwamaniacs/features/downloads/models/download_chapter_state.dart';
import 'package:manhwamaniacs/features/downloads/models/saved_chapter.dart';
import 'package:manhwamaniacs/features/downloads/models/storage_cap.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloaded_series_provider.dart';
import 'package:manhwamaniacs/features/downloads/providers/downloads_scope.dart';
import 'package:manhwamaniacs/features/downloads/providers/retention_maintenance_provider.dart';
import 'package:manhwamaniacs/features/downloads/providers/series_download_status_provider.dart';
import 'package:manhwamaniacs/features/downloads/providers/storage_settings_provider.dart';
import 'package:manhwamaniacs/features/downloads/queue/download_queue_controller.dart';
import 'package:manhwamaniacs/features/downloads/services/blob_store.dart';
import 'package:manhwamaniacs/features/downloads/services/device_storage_info.dart';
import 'package:manhwamaniacs/features/downloads/services/retention_maintenance.dart';
import 'package:manhwamaniacs/features/downloads/store/downloads_store.dart';
import 'package:manhwamaniacs/features/novels/models/novel_audio.dart';
import 'package:manhwamaniacs/features/novels/models/novel_audio_format.dart';
import 'package:manhwamaniacs/features/novels/models/novel_chapter.dart';
import 'package:manhwamaniacs/features/novels/providers/novel_audio_provider.dart';
import 'package:manhwamaniacs/features/novels/utils/narration_playback.dart';
import 'package:manhwamaniacs/features/novels/widgets/audiobook_picker_sheet.dart';
import 'package:manhwamaniacs/features/novels/widgets/narration_save_button.dart';
import 'package:manhwamaniacs/features/reader/repositories/reader_repository.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../support/downloads_test_support.dart';
import '../novels/support/fake_novels_repository.dart';

const _chapter =
    (sourceId: 'novelarchive', seriesKey: 'tbate', chapterKey: 'c120');
const _series = (sourceId: 'novelarchive', seriesKey: 'tbate');

/// A two-sentence render, shaped exactly as `GET /novels/audio` sends it.
final _timing = NovelAudio.fromJson({
  'available': true,
  'total_ms': 4200,
  'bytes': 2048,
  'highlight_safe': true,
  'segments': [
    {'i': 0, 'start_ms': 0, 'end_ms': 2000, 'p': 0, 's': 0, 'e': 9, 'speech': false},
    {
      'i': 1,
      'start_ms': 2000,
      'end_ms': 4200,
      'p': 1,
      's': 1,
      'e': 12,
      'speech': true,
      'speaker': 'Arthur',
    },
  ],
});

/// A narration as the server stores it: an Ogg page first, which is what
/// the queue and the reader recognise it by.
final _opus = [
  ...'OggS'.codeUnits,
  ...List<int>.generate(2044, (i) => i % 251),
];

/// The same narration as `format=m4a` answers it: an MP4 file, whose first
/// box is `ftyp` at offset 4.
final _m4a = [
  0, 0, 0, 0x20, ...'ftypM4A '.codeUnits,
  ...List<int>.generate(2036, (i) => (i * 7) % 251),
];

class _ReaderSpy extends Mock implements ReaderRepository {}

class _FixedStorageCapNotifier extends StorageCapNotifier {
  @override
  StorageCap build() => StorageCap.unlimited;
}

class _FixedDeviceStorageInfo implements DeviceStorageInfo {
  @override
  Future<int?> freeSpaceBytes() async => 10 * 1024 * 1024 * 1024;
}

/// The chapter's text, for the half of a narration save that is prose.
class _TextRepository extends FakeNovelsRepository {
  @override
  Future<Result<NovelChapter>> chapter({
    required String sourceId,
    required String seriesKey,
    required String chapterKey,
  }) async =>
      Ok(
        NovelChapter(
          sourceId: sourceId,
          seriesKey: seriesKey,
          chapterKey: chapterKey,
          chapterNumber: 120,
          title: 'The Gate',
          paragraphs: const ['The gate.', 'Arthur spoke.'],
          previousChapterKey: null,
          nextChapterKey: null,
          wordCount: 4,
        ),
      );
}

void main() {
  initSqfliteFfiForTests();

  late TestDownloadsHarness harness;
  late _TextRepository repo;
  late _ReaderSpy reader;

  setUp(() async {
    harness = await TestDownloadsHarness.create();
    repo = _TextRepository()
      ..audioByChapter = {'c120': _timing}
      ..audioBytesByChapter = {'c120': _opus};
    reader = _ReaderSpy();
  });

  tearDown(() async {
    await harness.dispose();
  });

  List<Override> overrides() => [
        downloadsStoreProvider.overrideWithValue(harness.storeFor('u1p1')),
        retentionMaintenanceProvider.overrideWithValue(
          RetentionMaintenance(
            database: harness.openDatabase(),
            blobStore: harness.openBlobStore(),
          ),
        ),
        novelsRepositoryProvider.overrideWithValue(repo),
        readerRepositoryProvider.overrideWithValue(reader),
        deviceStorageInfoProvider.overrideWithValue(_FixedDeviceStorageInfo()),
        storageCapProvider.overrideWith(_FixedStorageCapNotifier.new),
        downloadConcurrencyOverride(),
        narrationPlaybackCacheProvider.overrideWith(
          (ref) async => Directory('${harness.tempDir.path}/playback'),
        ),
      ];

  ProviderContainer container() {
    final c = ProviderContainer(overrides: overrides());
    addTearDown(c.dispose);
    return c;
  }

  Future<void> saveNarration(ProviderContainer c) async {
    final queue = c.read(downloadQueueControllerProvider.notifier);
    await queue.enqueueChapters(
      narrationDownloadRequests(chapter: _chapter, title: 'The Gate'),
    );
    await queue.debugWaitUntilIdle();
  }

  group('the queue', () {
    test('asks the server with the chapter key, never the row key', () async {
      await saveNarration(container());

      expect(repo.audioRequests, ['c120']);
      expect(repo.audioBytesRequests, ['c120']);
      final row =
          await harness.storeFor('u1p1').getChapter(audioIdentity(_chapter));
      expect(row!.state, DownloadChapterState.complete);
      expect(row.kind, DownloadKind.audio);
      // The opus and its timing map.
      expect(row.pageCount, 2);
    });

    test('saves the text beside it, so it reads and plays offline', () async {
      await saveNarration(container());

      final text = await harness.storeFor('u1p1').getChapter(_chapter);
      expect(text!.state, DownloadChapterState.complete);
      expect(text.kind, DownloadKind.novel);
    });

    test('keeps the timing map the audio was rendered with', () async {
      await saveNarration(container());

      final saved =
          await harness.storeFor('u1p1').readSavedNarration(_chapter);
      expect(saved, isNotNull);
      expect(await saved!.audio.readAsBytes(), _opus);
      final timing = NovelAudio.fromJson(saved.timing);
      expect(timing.totalMs, 4200);
      expect(timing.segments, hasLength(2));
      expect(timing.segments.last.speaker, 'Arthur');
      expect(timing.segments.last.paragraph, 1);
      expect(timing.segments.last.end, 12);
      // The highlight's own check still passes against the saved text.
      expect(timing.matchesText(const ['The gate.', 'Arthur spoke.']), isTrue);
    });

    test('a chapter with no audio fails without fetching bytes', () async {
      repo.audioByChapter = {};
      await saveNarration(container());

      final row =
          await harness.storeFor('u1p1').getChapter(audioIdentity(_chapter));
      expect(row!.state, DownloadChapterState.failed);
      expect(row.error, 'This chapter has not been narrated yet.');
      expect(repo.audioBytesRequests, isEmpty);
    });

    test('narration is never primed as a manga manifest window', () async {
      // Two audio rows of one series used to be enough to fire a manifest
      // window for keys no source has.
      final c = container();
      final queue = c.read(downloadQueueControllerProvider.notifier);
      repo
        ..audioByChapter = {'c120': _timing, 'c121': _timing}
        ..audioBytesByChapter = {'c120': _opus, 'c121': _opus};
      await queue.enqueueChapters([
        for (final key in ['c120', 'c121'])
          (
            id: audioIdentity(
              (
                sourceId: _chapter.sourceId,
                seriesKey: _chapter.seriesKey,
                chapterKey: key,
              ),
            ),
            chapterNumber: null,
            title: null,
            seriesTitle: null,
            kind: DownloadKind.audio,
          ),
      ]);
      await queue.debugWaitUntilIdle();

      verifyNever(
        () => reader.manifestWindow(
          sourceId: any(named: 'sourceId'),
          seriesKey: any(named: 'seriesKey'),
          chapterKeys: any(named: 'chapterKeys'),
        ),
      );
      expect(repo.audioBytesRequests.toSet(), {'c120', 'c121'});
    });

    test('deleting the chapter still releases every byte', () async {
      await saveNarration(container());
      final store = harness.storeFor('u1p1');
      expect(await store.scopeBytes(), greaterThan(2048));

      await store.deleteDownload(_chapter);

      expect(await store.scopeBytes(), 0);
      expect(await store.readSavedNarration(_chapter), isNull);
    });
  });

  group('playback', () {
    test('the reader plays the saved file, and asks the server nothing',
        () async {
      final c = container();
      await saveNarration(c);
      repo.audioRequests.clear();

      final playable = await c.read(playableNovelAudioProvider(_chapter).future);

      expect(playable, isNotNull);
      expect(playable!.file, isNotNull);
      expect(await playable.file!.readAsBytes(), _opus);
      expect(playable.audio.segments, hasLength(2));
      expect(repo.audioRequests, isEmpty);
    });

    test('with nothing saved it streams, as it always did', () async {
      final c = container();

      final playable = await c.read(playableNovelAudioProvider(_chapter).future);

      expect(playable!.file, isNull);
      expect(playable.audio.totalMs, 4200);
      expect(repo.audioRequests, ['c120']);
    });

    test('a narration still downloading is not played from disk', () async {
      final store = harness.storeFor('u1p1');
      await store.ensureQueued(
        id: audioIdentity(_chapter),
        kind: DownloadKind.audio,
      );

      expect(await store.readSavedNarration(_chapter), isNull);
    });
  });

  /// An iPhone's player cannot open Ogg at all, and takes a local file's type
  /// from its name. Everything below failed on every iPhone before: the save
  /// was Ogg, and the file had no extension to say otherwise.
  group('on an iPhone', () {
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      repo.audioBytesByChapter = {'c120': _m4a};
    });
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('the queue asks for MP4, and Android still asks for Ogg', () async {
      await saveNarration(container());
      expect(repo.audioBytesFormats, [NovelAudioFormat.m4a]);

      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      repo
        ..audioBytesByChapter = {'c121': _opus}
        ..audioByChapter = {'c121': _timing};
      final c = container();
      final queue = c.read(downloadQueueControllerProvider.notifier);
      await queue.enqueueChapters(
        narrationDownloadRequests(
          chapter: (
            sourceId: _chapter.sourceId,
            seriesKey: _chapter.seriesKey,
            chapterKey: 'c121',
          ),
        ),
      );
      await queue.debugWaitUntilIdle();
      expect(repo.audioBytesFormats, [
        NovelAudioFormat.m4a,
        NovelAudioFormat.ogg,
      ]);
    });

    test('plays the save from a path named .m4a, with the same bytes',
        () async {
      final c = container();
      await saveNarration(c);

      final playable =
          await c.read(playableNovelAudioProvider(_chapter).future);

      final file = playable!.file!;
      expect(file.path, endsWith('.m4a'));
      expect(file.path, startsWith('${harness.tempDir.path}/playback/'));
      expect(await file.readAsBytes(), _m4a);
      // The saved blob itself is untouched and still has no extension.
      final saved =
          await harness.storeFor('u1p1').readSavedNarration(_chapter);
      expect(saved!.audio.path, isNot(endsWith('.m4a')));
      expect(await saved.audio.readAsBytes(), _m4a);
    });

    test('a server that ignores format=m4a leaves nothing saved', () async {
      // It answers Ogg, which this phone would then "have" and never play.
      repo.audioBytesByChapter = {'c120': _opus};
      await saveNarration(container());

      final store = harness.storeFor('u1p1');
      final row = await store.getChapter(audioIdentity(_chapter));
      expect(row!.state, DownloadChapterState.failed);
      expect(row.error, 'The server sent audio this phone cannot play.');
      expect(await store.readSavedNarration(_chapter), isNull);
    });

    test('an Ogg save from before is streamed instead, and says so',
        () async {
      // Saved while the phone still asked for the default.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      repo.audioBytesByChapter = {'c120': _opus};
      final c = container();
      await saveNarration(c);
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      repo.audioRequests.clear();

      final saved = await c.read(savedNarrationProvider(_chapter).future);
      expect(saved!.playable, isFalse);

      final playable =
          await c.read(playableNovelAudioProvider(_chapter).future);
      expect(playable!.file, isNull);
      expect(playable.audio.totalMs, 4200);
      expect(repo.audioRequests, ['c120']);
    });
  });

  group('listing', () {
    test('a narration is not a chapter everywhere else', () async {
      final c = container();
      await saveNarration(c);
      final store = harness.storeFor('u1p1');

      // The offline series page and the table of contents read this: no
      // phantom "c120:audio" chapter beside the real one.
      expect(
        (await store.listChapters()).map((row) => row.chapterKey),
        ['c120'],
      );
      final statuses =
          await c.read(seriesChapterDownloadStatusProvider(_series).future);
      expect(statuses.keys, ['c120']);

      // Asked for in the chapter's own terms.
      final narration =
          await c.read(seriesNarrationStatusProvider(_series).future);
      expect(narration['c120']?.state, DownloadChapterState.complete);
    });

    test('the Downloads screen lists it, so its bytes are never hidden',
        () async {
      final c = container();
      await saveNarration(c);

      final groups = await c.read(downloadedSeriesProvider.future);
      expect(
        groups.single.chapters.map((row) => row.chapterKey).toSet(),
        {'c120', 'c120:audio'},
      );
    });

    test('the storage breakdown counts chapters, not narrations', () async {
      await saveNarration(container());

      final usage = await harness.storeFor('u1p1').seriesBreakdown();
      expect(usage.single.chapterCount, 1);
      expect(usage.single.bytes, greaterThan(2048));
    });

    test('finishing the chapter lets its narration expire with it', () async {
      await saveNarration(container());
      final store = harness.storeFor('u1p1');

      await store.markRead(_chapter);

      expect((await store.getChapter(_chapter))!.readAt, isNotNull);
      expect(
        (await store.getChapter(audioIdentity(_chapter)))!.readAt,
        isNotNull,
      );

      await store.clearReadStamp(_chapter);
      expect(
        (await store.getChapter(audioIdentity(_chapter)))!.readAt,
        isNull,
      );
    });
  });

  /// The two entry points, driven against fakes rather than the FFI store:
  /// sqflite's isolate needs real event-loop turns a widget test's fake clock
  /// does not give it, and a `runAsync` detour deadlocks against the widget's
  /// own connection (see `downloads_storage_card_test.dart`). What reaches
  /// the queue is what matters here; the queue itself is covered above.
  group('the entry points', () {
    late _RecordingQueue queue;

    Future<void> pump(
      WidgetTester tester,
      Widget child, {
      Map<String, ChapterDownloadStatus> saved = const {},
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            // A profile exists, but its database is never opened: nothing
            // below reaches it, and an FFI open on the fake clock would
            // outlive the test.
            downloadsStoreProvider.overrideWithValue(
              DownloadsStore(
                scopeId: 'u1p1',
                database: Completer<Database>().future,
                blobStore: Completer<BlobStore>().future,
              ),
            ),
            novelsRepositoryProvider.overrideWithValue(repo),
            downloadQueueControllerProvider.overrideWith(() => queue),
            seriesNarrationStatusProvider(_series)
                .overrideWith((ref) async => saved),
          ],
          child: MaterialApp(
            theme: AppTheme.dark,
            home: Scaffold(body: child),
          ),
        ),
      );
      await tester.pump();
    }

    setUp(() => queue = _RecordingQueue());

    testWidgets('the reader queues the chapter AND its narration',
        (tester) async {
      await pump(
        tester,
        const NarrationSaveButton(chapter: _chapter, color: Colors.white),
      );

      await tester.tap(find.byKey(const Key('narration-save')));
      await tester.pump();

      expect(
        queue.requests.map((r) => (r.id.chapterKey, r.kind)),
        [('c120', DownloadKind.novel), ('c120:audio', DownloadKind.audio)],
      );
    });

    testWidgets('a saved chapter says so',
        (tester) async {
      await pump(
        tester,
        const NarrationSaveButton(chapter: _chapter, color: Colors.white),
        saved: const {
          'c120': (state: DownloadChapterState.complete, error: null),
        },
      );
      expect(find.byKey(const Key('narration-saved')), findsOneWidget);
      expect(find.byKey(const Key('narration-save')), findsNothing);
    });

    testWidgets('an unplayable save asks to be saved again, and is',
        (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            downloadsStoreProvider.overrideWithValue(
              DownloadsStore(
                scopeId: 'u1p1',
                database: Completer<Database>().future,
                blobStore: Completer<BlobStore>().future,
              ),
            ),
            novelsRepositoryProvider.overrideWithValue(repo),
            downloadQueueControllerProvider.overrideWith(() => queue),
            seriesNarrationStatusProvider(_series).overrideWith(
              (ref) async => const {
                'c120': (state: DownloadChapterState.complete, error: null),
              },
            ),
            savedNarrationProvider(_chapter).overrideWith(
              (ref) async => (
                file: File('saved-before'),
                audio: _timing,
                playable: false,
              ),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.dark,
            home: const Scaffold(
              body: NarrationSaveButton(chapter: _chapter, color: Colors.white),
            ),
          ),
        ),
      );
      await tester.pump();
      // The copy is only examined once the row is known to be complete.
      await tester.pump();

      expect(find.byKey(const Key('narration-saved')), findsNothing);
      await tester.tap(find.byKey(const Key('narration-resave')));
      await tester.pump();

      // The old copy goes, then the chapter is saved afresh.
      expect(queue.cancelled, [audioIdentity(_chapter)]);
      expect(
        queue.requests.map((r) => (r.id.chapterKey, r.kind)),
        [('c120', DownloadKind.novel), ('c120:audio', DownloadKind.audio)],
      );
    });

    testWidgets('a failed save offers a retry', (tester) async {
      await pump(
        tester,
        const NarrationSaveButton(chapter: _chapter, color: Colors.white),
        saved: const {
          'c120': (state: DownloadChapterState.failed, error: 'gone'),
        },
      );
      await tester.tap(find.byKey(const Key('narration-failed')));
      await tester.pump();
      expect(queue.requests.last.id, audioIdentity(_chapter));
    });

    testWidgets(
        'with no render worker the picker still saves what exists, and says '
        'why it cannot narrate', (tester) async {
      await pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => AudiobookPickerSheet.show(
              context,
              sourceId: 'novelarchive',
              seriesKey: 'tbate',
              canRender: false,
              cached: {'c120', 'c121', 'c122'},
              chapters: const [
                (
                  key: 'c120',
                  number: 120,
                  title: 'The Gate',
                  isRead: false,
                  isDownloaded: true,
                ),
                (
                  key: 'c121',
                  number: 121,
                  title: 'Unvoiced',
                  isRead: false,
                  isDownloaded: false,
                ),
                (
                  key: 'c122',
                  number: 122,
                  title: 'Kept',
                  isRead: false,
                  isDownloaded: true,
                ),
              ],
            ),
            child: const Text('open'),
          ),
        ),
        saved: const {
          'c122': (state: DownloadChapterState.complete, error: null),
        },
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Narration of new chapters is not available'),
        findsOneWidget,
      );
      // Only saving is on offer: no way to request a render.
      expect(find.text('Narrate'), findsNothing);
      expect(find.text('Not narrated yet'), findsOneWidget);
      expect(find.text('Saved on this phone'), findsOneWidget);

      // c122 is already on the phone, so only c120 is left to save.
      await tester.tap(find.text('All narrated (1)'));
      await tester.pump();
      await tester.tap(find.text('Save audio of 1 chapter'));
      await tester.pumpAndSettle();

      expect(repo.renderRequests, isEmpty);
      expect(
        queue.requests.map((r) => r.id.chapterKey),
        ['c120', 'c120:audio'],
      );
      expect(
        find.text('Saving the audio of 1 chapter to this phone.'),
        findsOneWidget,
      );
    });
  });
}

/// Records what reaches the queue instead of running it.
class _RecordingQueue extends DownloadQueueController {
  final List<ChapterQueueRequest> requests = [];

  final List<ChapterIdentity> cancelled = [];

  @override
  Future<void> enqueueChapters(Iterable<ChapterQueueRequest> chapters) async {
    requests.addAll(chapters);
  }

  @override
  Future<void> cancelChapter(ChapterIdentity id) async {
    cancelled.add(id);
  }
}
