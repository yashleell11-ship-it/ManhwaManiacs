/// Watching narration requests, and not lying about them.
///
/// Two failures this pins shut. One dropped poll used to end the watch for
/// good — the in-progress label vanished and the finished chapter was never
/// noticed. And with no render worker on the server, a queued job was polled
/// every five seconds and called "in progress" for as long as the page was
/// open, forever.
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:manhwamaniacs/app/theme/app_theme.dart';
import 'package:manhwamaniacs/core/error/app_error.dart';
import 'package:manhwamaniacs/core/network/interceptors/error_interceptor.dart';
import 'package:manhwamaniacs/core/utils/result.dart';
import 'package:manhwamaniacs/features/novels/models/novel_cast.dart';
import 'package:manhwamaniacs/features/novels/providers/series_audio_provider.dart';
import 'package:manhwamaniacs/features/novels/repositories/novels_repository_impl.dart';
import 'package:manhwamaniacs/features/novels/widgets/audiobook_picker_sheet.dart';
import 'package:manhwamaniacs/features/novels/widgets/novel_series_detail_view.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';

import 'support/fake_novels_repository.dart';

const _key = (sourceId: 'novelbin', seriesKey: 'tbate');

NovelAudioJob _job(String status, {String chapter = 'c1'}) => NovelAudioJob(
      jobId: 'job-$chapter',
      chapterKey: chapter,
      status: status,
      progress: 0,
      errorCode: null,
    );

const _dropped = Err<List<NovelAudioJob>>(
  NetworkError(message: 'connection reset'),
);

ProviderContainer _container(FakeNovelsRepository repo) {
  final container = ProviderContainer(
    overrides: [
      novelsRepositoryProvider.overrideWithValue(repo),
      novelAudioJobsPollIntervalProvider.overrideWithValue(
        const Duration(milliseconds: 1),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Every value the jobs stream emits, in order.
List<List<NovelAudioJob>> _record(ProviderContainer container) {
  final seen = <List<NovelAudioJob>>[];
  container.listen(
    novelAudioJobsProvider(_key),
    (_, next) {
      final value = next.valueOrNull;
      if (value != null && !next.isLoading) seen.add(value);
    },
    fireImmediately: true,
  );
  return seen;
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 500 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(condition(), isTrue, reason: 'condition never became true');
}

void main() {
  group('polling', () {
    test('a dropped poll keeps the last jobs and the watch goes on', () async {
      final repo = FakeNovelsRepository()
        ..audioJobsResults = [
          Ok([_job('rendering')]),
          _dropped,
          Ok([_job('rendering')]),
          Ok([_job('done')]),
        ];
      final container = _container(repo);
      final seen = _record(container);

      await _until(() => repo.audioJobsCalls >= 4);
      await _until(() => seen.isNotEmpty && seen.last.single.status == 'done');

      // The failure never surfaced as "nothing in flight".
      expect(seen.every((jobs) => jobs.isNotEmpty), isTrue);
      expect(repo.audioJobsCalls, 4);
    });

    test('the finish refreshes which chapters have audio', () async {
      final repo = FakeNovelsRepository()
        ..audioJobsResults = [
          Ok([_job('rendering')]),
          _dropped,
          Ok([_job('done')]),
        ];
      final container = _container(repo);
      _record(container);

      await _until(() => repo.audioJobsCalls >= 3);
      // Once for the page, once more because a render actually finished.
      await _until(() => repo.seriesAudioCalls >= 2);
    });

    test('a failed poll alone does not refresh coverage', () async {
      // The old loop invalidated coverage after a FAILED poll too — a
      // wasted refetch that saw nothing new.
      final repo = FakeNovelsRepository()
        ..audioJobsResults = [
          Ok([_job('rendering')]),
          _dropped,
          _dropped,
          Ok([_job('rendering')]),
        ];
      final container = _container(repo);
      _record(container);

      await _until(() => repo.audioJobsCalls >= 5);
      expect(repo.seriesAudioCalls, 1);
    });

    test('a first poll that fails reads as nothing, and keeps asking',
        () async {
      final repo = FakeNovelsRepository()
        ..audioJobsResults = [
          _dropped,
          Ok([_job('queued')]),
          const Ok(<NovelAudioJob>[]),
        ];
      final container = _container(repo);
      final seen = _record(container);

      await _until(() => repo.audioJobsCalls >= 3);
      await _until(() => seen.length >= 3);
      expect(seen.first, isEmpty);
      expect(seen[1].single.status, 'queued');
    });

    test('with no render worker it never polls at all', () async {
      final repo = FakeNovelsRepository()
        ..seriesAudioResult = const Ok(
          (rendered: <String>{}, narratable: {'c1'}, canRender: false),
        )
        ..audioJobsResults = [
          Ok([_job('queued')]),
        ];
      final container = _container(repo);
      final seen = _record(container);

      await _until(() => seen.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(repo.audioJobsCalls, 0);
      // A job queued before the worker went away is not "in progress".
      expect(seen.last, isEmpty);
    });
  });

  group('the words on the button', () {
    test('a queued job is waiting, never "in progress"', () {
      final label = audiobookButtonLabel(
        canRender: true,
        running: 0,
        waiting: 3,
        rendered: 2,
      );
      expect(label, 'Make audiobook · 3 waiting for the narration PC');
      expect(label, isNot(contains('in progress')));
    });

    test('in progress only for what a render box is working on', () {
      expect(
        audiobookButtonLabel(
          canRender: true,
          running: 1,
          waiting: 2,
          rendered: 0,
        ),
        'Making audiobook · 1 in progress, 2 waiting',
      );
    });

    test('with no worker, jobs are not talked about at all', () {
      expect(
        audiobookButtonLabel(
          canRender: false,
          running: 0,
          waiting: 4,
          rendered: 5,
        ),
        // Nor "make": nothing can be made. What exists can still be saved.
        'Audiobook · 5 narrated',
      );
    });

    test('skipped chapters say why', () {
      expect(
        skippedNarrationLine({
          'c1': 'already_queued',
          'c2': 'already_queued',
          'c3': 'chapter_not_cached',
        }),
        'Skipped: 2 already asked for, 1 not downloaded to the server yet.',
      );
    });
  });

  testWidgets('no render worker: not offered, and said plainly',
      (tester) async {
    final repo = FakeNovelsRepository()
      ..seriesAudioResult = const Ok(
        (rendered: <String>{}, narratable: {'c1'}, canRender: false),
      );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          novelsRepositoryProvider.overrideWithValue(repo),
        ],
        child: MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(
            body: AudiobookButton(
              sourceId: 'novelbin',
              seriesKey: 'tbate',
              chapters: [
                (
                  key: 'c1',
                  number: 1,
                  title: 'One',
                  isRead: false,
                  isDownloaded: false,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(kNarrationUnavailable), findsOneWidget);
    final button = tester.widget<OutlinedButton>(find.byType(OutlinedButton));
    expect(button.onPressed, isNull);
    expect(repo.audioJobsCalls, 0);
  });

  group('GET /novels/audio/series', () {
    Future<bool> canRenderFrom(Map<String, dynamic> body) async {
      final dio = Dio(BaseOptions(baseUrl: 'https://mm.test'))
        ..httpClientAdapter = _JsonAdapter(body)
        ..interceptors.add(ErrorInterceptor());
      final result = await NovelsRepositoryImpl(dio)
          .seriesAudio(sourceId: 'novelbin', seriesKey: 'tbate');
      return result.value.canRender;
    }

    test('reads can_render', () async {
      expect(
        await canRenderFrom({'chapters': <String>[], 'narratable': <String>[], 'can_render': true}),
        isTrue,
      );
      expect(
        await canRenderFrom({'chapters': <String>[], 'narratable': <String>[], 'can_render': false}),
        isFalse,
      );
    });

    test('a server that predates the flag cannot render', () async {
      expect(await canRenderFrom({'chapters': <String>[], 'narratable': <String>[]}), isFalse);
    });
  });
}

class _JsonAdapter implements HttpClientAdapter {
  _JsonAdapter(this.body);

  final Map<String, dynamic> body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async =>
      ResponseBody.fromString(
        jsonEncode(body),
        200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );

  @override
  void close({bool force = false}) {}
}
