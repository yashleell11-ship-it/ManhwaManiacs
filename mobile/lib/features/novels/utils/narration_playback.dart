import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:manhwamaniacs/features/novels/models/novel_audio_format.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Where a saved narration is copied to be played on a player that goes by
/// the file's name — see [playsByExtension].
///
/// The temporary directory, never Documents: the copy is disposable (the
/// saved blob is the real one), so it must not show up in the Files app or
/// count against the storage cap, and the OS is welcome to purge it.
final narrationPlaybackCacheProvider = FutureProvider<Directory>((ref) async {
  final temp = await getTemporaryDirectory();
  return Directory(p.join(temp.path, 'narration-playback'));
});

/// How many playback copies are kept. One chapter plays at a time; the rest
/// cover a reader being replaced by the next chapter's while its player is
/// still letting go of the file.
const int kNarrationPlaybackCopies = 3;

final Random _rng = Random();

/// A path [blob] can be played from on a player that decides what a file is
/// by its extension: a copy of it in [cache], named `<blob name><extension>`.
///
/// A copy rather than a link. `dart:io` cannot make hard links, and whether
/// AVPlayer takes its type from a symlink's name or its target's is not
/// something to find out on somebody's phone. A chapter is a few megabytes
/// and the copy is made once — blobs are named by their content hash, so an
/// existing copy of the same size IS the same bytes.
///
/// Written to a temporary name and renamed into place, so a copy that was
/// cut short is never mistaken for a finished one. Older copies beyond
/// [keep] are deleted on the way out.
Future<File> narrationPlaybackFile({
  required File blob,
  required NovelAudioFormat format,
  required Directory cache,
  int keep = kNarrationPlaybackCopies,
}) async {
  final target =
      File(p.join(cache.path, '${p.basename(blob.path)}${format.extension}'));
  final size = await blob.length();
  if (!(target.existsSync() && target.lengthSync() == size)) {
    await cache.create(recursive: true);
    final part = '${target.path}.part${_rng.nextInt(1 << 32)}';
    await blob.copy(part);
    await File(part).rename(target.path);
  } else {
    // Freshly used, so the pruning below keeps it.
    try {
      await target.setLastModified(DateTime.now());
    } catch (_) {}
  }
  await _prune(cache, keep: keep, current: target.path);
  return target;
}

/// Deletes all but the [keep] most recently used copies in [cache], never
/// [current]. Best effort: a copy that will not delete is left for the OS,
/// which purges this directory on its own.
Future<void> _prune(
  Directory cache, {
  required int keep,
  required String current,
}) async {
  try {
    final copies = cache
        .listSync(followLinks: false)
        .whereType<File>()
        .where((f) => f.path != current)
        .toList()
      ..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    for (final stale in copies.skip(keep - 1)) {
      try {
        await stale.delete();
      } catch (_) {}
    }
  } catch (_) {}
}
