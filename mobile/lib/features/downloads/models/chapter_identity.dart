/// The opaque `(sourceId, seriesKey, chapterKey)` triple that identifies a
/// chapter everywhere in the source-native client (manifest, reader,
/// progress, and — from 1c-M3 — the on-device store). Never parsed or split;
/// see `docs/superpowers/specs/2026-09-03-mobile-source-native-design.md` §1.
typedef ChapterIdentity = ({
  String sourceId,
  String seriesKey,
  String chapterKey,
});

/// A series identity, for series-level operations (queueing every chapter,
/// pin toggles, per-series storage totals).
typedef SeriesIdentity = ({String sourceId, String seriesKey});

/// What marks a saved row as a chapter's NARRATION rather than its text.
///
/// Audio is a separate `saved_chapters` row keyed on the same chapter with
/// this appended, so the two download, retry, fail and delete independently.
/// The consequence to remember is in [audioIdentity]'s docstring: deleting a
/// chapter must delete its sibling, or the bytes are stranded.
const String kAudioIdentitySuffix = ':audio';

/// The identity of [id]'s narration.
///
/// **Deleting a chapter must also delete this.** The audio row is invisible
/// to the UI — no screen lists it — so an orphan is a couple of megabytes
/// that nothing will ever show and nothing will ever collect: its blob
/// refcount is still held, so `reclaimOrphanBlobs` will not take it either.
ChapterIdentity audioIdentity(ChapterIdentity id) => (
  sourceId: id.sourceId,
  seriesKey: id.seriesKey,
  chapterKey: '${id.chapterKey}$kAudioIdentitySuffix',
);

/// Whether this identity names narration rather than prose.
bool isAudioIdentity(ChapterIdentity id) =>
    id.chapterKey.endsWith(kAudioIdentitySuffix);

/// The chapter an audio identity belongs to.
ChapterIdentity textIdentity(ChapterIdentity id) => isAudioIdentity(id)
    ? (
        sourceId: id.sourceId,
        seriesKey: id.seriesKey,
        chapterKey: id.chapterKey.substring(
          0,
          id.chapterKey.length - kAudioIdentitySuffix.length,
        ),
      )
    : id;
