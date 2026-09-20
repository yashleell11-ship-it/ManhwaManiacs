/// Offline narration, and the one thing about it that can silently cost you.
///
/// Audio is a SEPARATE `saved_chapters` row from the chapter's text, keyed on
/// the same chapter with `:audio` appended. That buys refcounting, the
/// storage cap, retention and export for free — but it means no screen lists
/// the audio row, so an orphan is a couple of megabytes that nothing will
/// ever show and nothing will ever collect. `reclaimOrphanBlobs` will not
/// take it either: its refcount is still held.
///
/// Everything here exists to make that leak impossible to reintroduce.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/features/downloads/models/chapter_identity.dart';
import 'package:manhwamaniacs/features/downloads/models/download_chapter_state.dart';
import 'package:manhwamaniacs/features/downloads/models/saved_chapter.dart';
import 'package:manhwamaniacs/features/downloads/store/downloads_store.dart';

import '../../support/downloads_test_support.dart';

const _chapter =
    (sourceId: 'novelarchive', seriesKey: 'tbate', chapterKey: 'c120');

Future<void> _saveText(DownloadsStore store) async {
  final rowId = await store.ensureQueued(
    id: _chapter,
    kind: DownloadKind.novel,
  );
  await store.updateManifestInfo(rowId: rowId, pageCount: 1);
  await store.saveNovelText(rowId: rowId, chapter: {'paragraphs': <String>[]});
  await store.markCompleteIfAllPagesPresent(rowId);
}

Future<void> _saveAudio(DownloadsStore store, {List<int>? bytes}) async {
  final rowId = await store.ensureQueued(
    id: audioIdentity(_chapter),
    kind: DownloadKind.audio,
  );
  await store.updateManifestInfo(rowId: rowId, pageCount: 1);
  await store.saveAudio(rowId: rowId, bytes: bytes ?? List.filled(2048, 7));
  await store.markCompleteIfAllPagesPresent(rowId);
}

void main() {
  initSqfliteFfiForTests();

  late TestDownloadsHarness harness;

  setUp(() async {
    harness = await TestDownloadsHarness.create();
  });

  tearDown(() async {
    await harness.dispose();
  });

  group('identity', () {
    test('audio hangs off the chapter it belongs to', () {
      final audio = audioIdentity(_chapter);

      expect(audio.sourceId, _chapter.sourceId);
      expect(audio.seriesKey, _chapter.seriesKey);
      expect(audio.chapterKey, 'c120:audio');
      expect(isAudioIdentity(audio), isTrue);
      expect(isAudioIdentity(_chapter), isFalse);
    });

    test('and converts back, so a row can name its chapter', () {
      expect(textIdentity(audioIdentity(_chapter)), _chapter);
      // Already text: unchanged rather than truncated.
      expect(textIdentity(_chapter), _chapter);
    });
  });

  group('independence', () {
    test('text is readable offline before any audio exists', () async {
      // The whole reason audio is its own row. Hung off the text row, a
      // chapter would stay incomplete — and therefore unreadable offline —
      // until two megabytes of speech finished arriving.
      final store = harness.storeFor('u1p1');

      await _saveText(store);

      final text = await store.getChapter(_chapter);
      expect(text, isNotNull);
      expect(text!.state, DownloadChapterState.complete);
      expect(await store.getChapter(audioIdentity(_chapter)), isNull);
    });

    test('audio can be saved without the text', () async {
      // Somebody who only wants to listen. Nothing requires the pair.
      final store = harness.storeFor('u1p1');

      await _saveAudio(store);

      expect(await store.getChapter(audioIdentity(_chapter)), isNotNull);
      expect(await store.getChapter(_chapter), isNull);
    });

    test('the audio row records itself as audio', () async {
      final store = harness.storeFor('u1p1');

      await _saveAudio(store);

      final row = await store.getChapter(audioIdentity(_chapter));
      expect(row!.kind, DownloadKind.audio);
      expect(row.kind.isAudio, isTrue);
      expect(row.kind.isNovel, isFalse);
    });
  });

  group('deleting a chapter takes its narration with it', () {
    test('no audio row survives deleting the chapter', () async {
      // The leak this whole file exists for.
      final store = harness.storeFor('u1p1');
      await _saveText(store);
      await _saveAudio(store);

      await store.deleteDownload(_chapter);

      expect(await store.getChapter(_chapter), isNull);
      expect(await store.getChapter(audioIdentity(_chapter)), isNull);
      expect(await store.listChapters(), isEmpty);
    });

    test('the bytes are released, not just the row', () async {
      // A row deleted while its blob refcount is still held is the worst
      // version of this bug: the file stays on disk and the orphan sweep
      // refuses it, so nothing ever reclaims it.
      final store = harness.storeFor('u1p1');
      await _saveText(store);
      await _saveAudio(store);
      final before = await store.scopeBytes();
      expect(before, greaterThan(2000));

      await store.deleteDownload(_chapter);

      expect(await store.scopeBytes(), 0);
    });

    test('deleting audio alone leaves the text readable', () async {
      // "I want the words but not the megabytes" has to work.
      final store = harness.storeFor('u1p1');
      await _saveText(store);
      await _saveAudio(store);

      await store.deleteDownload(audioIdentity(_chapter));

      expect(await store.getChapter(audioIdentity(_chapter)), isNull);
      expect(await store.getChapter(_chapter), isNotNull);
    });

    test('deleting a chapter with no audio is not an error', () async {
      final store = harness.storeFor('u1p1');
      await _saveText(store);

      await store.deleteDownload(_chapter);

      expect(await store.listChapters(), isEmpty);
    });
  });

  group('the blob store is shared, as it is for pages', () {
    test('two profiles saving the same audio store one copy', () async {
      // Content-addressed like any other blob, so a household reading the
      // same book does not pay for it twice.
      final a = harness.storeFor('u1p1');
      final b = harness.storeFor('u1p2');
      final bytes = List.filled(4096, 3);

      await _saveAudio(a, bytes: bytes);
      final afterOne = await a.scopeBytes();
      await _saveAudio(b, bytes: bytes);

      expect(await b.scopeBytes(), afterOne);
    });

    test("one profile deleting does not take the other's audio", () async {
      final a = harness.storeFor('u1p1');
      final b = harness.storeFor('u1p2');
      final bytes = List.filled(4096, 3);
      await _saveAudio(a, bytes: bytes);
      await _saveAudio(b, bytes: bytes);

      await a.deleteDownload(_chapter);

      expect(await b.getChapter(audioIdentity(_chapter)), isNotNull);
      expect(await b.scopeBytes(), greaterThan(0));
    });
  });
}
