import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/features/novels/models/novel_cast.dart';
import 'package:manhwamaniacs/features/novels/repositories/novels_repository.dart';
import 'package:manhwamaniacs/shared/providers/repository_providers.dart';

/// Which book, for the two providers below.
typedef NovelSeriesKey = ({String sourceId, String seriesKey});

/// Which chapters of this book already have audio.
///
/// One request per page rather than one per chapter: a long novel is several
/// hundred chapters and all but a handful answer "no".
///
/// A failure resolves to "none" rather than throwing. The table of contents
/// is readable with or without this; an error screen over a decoration would
/// be a worse page than one that simply does not mark anything. That includes
/// `canRender: false` — a server the phone cannot reach cannot take a request
/// either, so not offering one is the true answer for as long as that lasts.
final seriesAudioProvider = FutureProvider.autoDispose
    .family<NovelSeriesAudio, NovelSeriesKey>((ref, key) async {
      final result = await ref
          .watch(novelsRepositoryProvider)
          .seriesAudio(sourceId: key.sourceId, seriesKey: key.seriesKey);
      return result.isErr
          ? (rendered: <String>{}, narratable: <String>{}, canRender: false)
          : result.value;
    });

/// The pace of [novelAudioJobsProvider] while a render is running. A seam so
/// tests can poll in milliseconds rather than wait out real seconds.
final novelAudioJobsPollIntervalProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 5),
);

/// How much slower to poll when every job is only WAITING for a render box.
///
/// A queued job still has to be watched — a worker that frees up picks it up
/// and the page should see it move — but nothing about it changes every five
/// seconds, and this server has two cores and also serves the reading.
const int _waitingSlowdown = 3;

/// The ceiling on backing off after failed polls, as a multiple of the
/// interval: a minute at the real pace. A server that is down stays polled,
/// just rarely, so the page notices when it comes back.
const int _maxBackoff = 12;

/// What has been asked for on this book, and where each render got to.
///
/// Polls ONLY while something is actually in flight, and stops the moment a
/// SUCCESSFUL answer says nothing is. A render is minutes long and usually
/// there is nothing running, so a fixed interval would be a request every few
/// seconds forever to say "still nothing".
///
/// Two ways this used to go wrong, both now closed:
///
/// * One failed poll ended it for good. A dropped signal or a deploy's 502
///   turned into an empty list, which read as "nothing in flight", so the
///   loop exited, the in-progress label vanished, and the chapter finishing
///   later was never noticed. A failure now keeps the last known jobs and
///   tries again, backing off.
/// * With no render worker configured nothing ever claims a job, so a queued
///   one polled every five seconds for as long as the page was open. When the
///   server says it cannot render, this does not poll at all.
final novelAudioJobsProvider = StreamProvider.autoDispose
    .family<List<NovelAudioJob>, NovelSeriesKey>((ref, key) async* {
      final repository = ref.watch(novelsRepositoryProvider);
      final interval = ref.watch(novelAudioJobsPollIntervalProvider);
      var disposed = false;
      ref.onDispose(() => disposed = true);

      // Only the flag, not the whole answer: the refresh below re-fetches
      // coverage when a render lands, and that must not restart this watch
      // just to ask the jobs again.
      final canRender = await ref.watch(
        seriesAudioProvider(key).selectAsync((audio) => audio.canRender),
      );
      if (disposed) return;
      if (!canRender) {
        // Nothing can move, so there is nothing to watch — and a job queued
        // before the worker went away is not "in progress" either.
        yield const <NovelAudioJob>[];
        return;
      }

      List<NovelAudioJob>? jobs;
      var failures = 0;
      while (true) {
        final result = await repository.audioJobs(
          sourceId: key.sourceId,
          seriesKey: key.seriesKey,
        );
        if (disposed) return;

        if (result.isOk) {
          final wasActive = jobs?.any((job) => job.isActive) ?? false;
          failures = 0;
          jobs = result.value;
          yield jobs;
          if (!jobs.any((job) => job.isActive)) {
            if (wasActive) {
              // A render just finished, so the coverage this page marks from
              // is stale. Refreshing here rather than on a timer means the
              // new chapter is listenable the moment it lands — and only on a
              // real finish, never on a poll that merely failed.
              ref.invalidate(seriesAudioProvider(key));
            }
            return;
          }
        } else {
          failures++;
          if (jobs == null) {
            // Nothing known yet. Say so rather than leaving the page loading,
            // and keep asking.
            jobs = const <NovelAudioJob>[];
            yield jobs;
          }
          // Otherwise the last good answer stands: a transient failure is
          // not news that the jobs went away.
        }

        final pace = jobs.any((job) => job.isRunning)
            ? interval
            : interval * _waitingSlowdown;
        await Future<void>.delayed(
          failures == 0
              ? pace
              : interval *
                    (1 << (failures > 4 ? 4 : failures)).clamp(1, _maxBackoff),
        );
        if (disposed) return;
      }
    });
