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
/// be a worse page than one that simply does not mark anything.
final seriesAudioProvider = FutureProvider.autoDispose
    .family<NovelSeriesAudio, NovelSeriesKey>((ref, key) async {
      final result = await ref
          .watch(novelsRepositoryProvider)
          .seriesAudio(sourceId: key.sourceId, seriesKey: key.seriesKey);
      return result.isErr
          ? (rendered: <String>{}, narratable: <String>{})
          : result.value;
    });

/// What has been asked for on this book, and where each render got to.
///
/// Polls ONLY while something is actually in flight, and stops the moment
/// nothing is. A render is minutes long and usually there is nothing running,
/// so a fixed interval would be a request every few seconds forever to say
/// "still nothing" — on a two-core server that also serves the reading.
final novelAudioJobsProvider = StreamProvider.autoDispose
    .family<List<NovelAudioJob>, NovelSeriesKey>((ref, key) async* {
      final repository = ref.watch(novelsRepositoryProvider);

      Future<List<NovelAudioJob>> read() async {
        final result = await repository.audioJobs(
          sourceId: key.sourceId,
          seriesKey: key.seriesKey,
        );
        return result.isErr ? const <NovelAudioJob>[] : result.value;
      }

      var jobs = await read();
      yield jobs;

      while (jobs.any((job) => job.isActive)) {
        await Future<void>.delayed(const Duration(seconds: 5));
        jobs = await read();
        yield jobs;
        if (!jobs.any((job) => job.isActive)) {
          // A render just finished, so the coverage this page marks from is
          // stale. Refreshing here rather than on a timer means the new
          // chapter is listenable the moment it lands.
          ref.invalidate(seriesAudioProvider(key));
        }
      }
    });
