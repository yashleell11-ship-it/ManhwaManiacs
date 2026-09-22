/// Which container a narration is asked for in, and how a file on the phone
/// is recognised.
///
/// An iPhone's player cannot open Ogg at all, which is every render the
/// server stores. Asking for the wrong one, or trusting a file to be what
/// was asked for, is an iPhone that shows a play button and plays nothing.
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/features/novels/models/novel_audio_format.dart';
import 'package:manhwamaniacs/features/novels/repositories/novels_repository_impl.dart';
import 'package:manhwamaniacs/features/novels/utils/narration_playback.dart';

final _ogg = [...'OggS'.codeUnits, 0, 2, 0, 0, 0, 0, 0, 0];
final _m4a = [0, 0, 0, 0x20, ...'ftypM4A '.codeUnits, 0, 0];

void main() {
  group('what to ask for', () {
    test('an iPhone asks for MP4; everything else keeps Ogg', () {
      expect(novelAudioFormatFor(TargetPlatform.iOS), NovelAudioFormat.m4a);
      expect(novelAudioFormatFor(TargetPlatform.android), NovelAudioFormat.ogg);
    });

    test('the query says format only when it is not the default', () {
      final ios = novelAudioFileQuery(
        sourceId: 'novelbin',
        seriesKey: 'tbate/x',
        chapterKey: 'c120',
        format: NovelAudioFormat.m4a,
      );
      expect(ios, {
        'source': 'novelbin',
        'series': 'tbate/x',
        'chapter': 'c120',
        'format': 'm4a',
      });
      // Android's request is byte for byte what it always was.
      final android = novelAudioFileQuery(
        sourceId: 'novelbin',
        seriesKey: 'tbate/x',
        chapterKey: 'c120',
        format: NovelAudioFormat.ogg,
      );
      expect(android.containsKey('format'), isFalse);
    });

    test('the repository sends it', () async {
      final adapter = _RecordingAdapter(_m4a);
      final dio = Dio(BaseOptions(baseUrl: 'https://mm.test'))
        ..httpClientAdapter = adapter;

      final result = await NovelsRepositoryImpl(dio).audioBytes(
        sourceId: 'novelbin',
        seriesKey: 'tbate',
        chapterKey: 'c120',
        format: NovelAudioFormat.m4a,
      );

      expect(result.value, _m4a);
      expect(adapter.uris.single.path, '/novels/audio/file');
      expect(adapter.uris.single.queryParameters['format'], 'm4a');
    });
  });

  group('what a file is', () {
    test('reads the container from the first bytes', () {
      expect(sniffNovelAudioFormat(_ogg), NovelAudioFormat.ogg);
      expect(sniffNovelAudioFormat(_m4a), NovelAudioFormat.m4a);
    });

    test('anything else, or too little, is neither', () {
      expect(sniffNovelAudioFormat(const []), isNull);
      expect(sniffNovelAudioFormat('Ogg'.codeUnits), isNull);
      expect(sniffNovelAudioFormat('<html>error</html>'.codeUnits), isNull);
      expect(sniffNovelAudioFormat(List<int>.filled(64, 0)), isNull);
    });

    test('an iPhone plays only MP4; Android plays both', () {
      expect(canPlayNovelAudio(NovelAudioFormat.m4a, TargetPlatform.iOS), isTrue);
      expect(canPlayNovelAudio(NovelAudioFormat.ogg, TargetPlatform.iOS), isFalse);
      expect(
        canPlayNovelAudio(NovelAudioFormat.ogg, TargetPlatform.android),
        isTrue,
      );
      expect(
        canPlayNovelAudio(NovelAudioFormat.m4a, TargetPlatform.android),
        isTrue,
      );
      expect(canPlayNovelAudio(null, TargetPlatform.android), isFalse);
    });

    test('only an iPhone needs the name to say what the file is', () {
      expect(playsByExtension(TargetPlatform.iOS), isTrue);
      expect(playsByExtension(TargetPlatform.android), isFalse);
    });
  });

  group('the playback copy', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('mm-narration-playback-');
    });
    tearDown(() async {
      if (temp.existsSync()) await temp.delete(recursive: true);
    });

    Future<File> blob(String hash, List<int> bytes) async {
      final file = File('${temp.path}/blobs/$hash');
      await file.parent.create(recursive: true);
      return file.writeAsBytes(bytes);
    }

    test('is named for its format and holds the same bytes', () async {
      final saved = await blob('a' * 64, _m4a);
      final cache = Directory('${temp.path}/playback');

      final copy = await narrationPlaybackFile(
        blob: saved,
        format: NovelAudioFormat.m4a,
        cache: cache,
      );

      expect(copy.path, '${cache.path}/${'a' * 64}.m4a');
      expect(await copy.readAsBytes(), _m4a);
      // Nothing half-written is left beside it.
      expect(cache.listSync().map((e) => e.path), [copy.path]);
    });

    test('is made once and reused', () async {
      final saved = await blob('b' * 64, _m4a);
      final cache = Directory('${temp.path}/playback');

      final first = await narrationPlaybackFile(
        blob: saved,
        format: NovelAudioFormat.m4a,
        cache: cache,
      );
      final stamp = first.lastModifiedSync();
      // A copy of the same name and size is the same bytes: blobs are named
      // by their content hash.
      final second = await narrationPlaybackFile(
        blob: saved,
        format: NovelAudioFormat.m4a,
        cache: cache,
      );

      expect(second.path, first.path);
      expect(await second.readAsBytes(), _m4a);
      expect(second.lastModifiedSync().isBefore(stamp), isFalse);
    });

    test('keeps only the most recent few', () async {
      final cache = Directory('${temp.path}/playback');
      final copies = <File>[];
      for (final c in ['1', '2', '3', '4', '5']) {
        final saved = await blob(c * 64, _m4a);
        copies.add(
          await narrationPlaybackFile(
            blob: saved,
            format: NovelAudioFormat.m4a,
            cache: cache,
            keep: 2,
          ),
        );
        // Distinct modification times, whatever the filesystem's resolution.
        await copies.last.setLastModified(
          DateTime(2026, 1, 1, 0, copies.length),
        );
      }

      final left = cache.listSync().map((e) => e.path).toSet();
      expect(left, {copies[3].path, copies[4].path});
    });
  });
}

/// Answers every request with [bytes], and remembers what was asked.
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.bytes);

  final List<int> bytes;
  final List<Uri> uris = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    uris.add(options.uri);
    return ResponseBody.fromBytes(
      bytes,
      200,
      headers: {
        Headers.contentTypeHeader: ['audio/mp4'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
