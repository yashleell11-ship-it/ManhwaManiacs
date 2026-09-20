import type { ChapterId, SeriesId } from "@/types/api";
import type { SourceBrowseCache } from "@/features/sources/types";

export type { ChapterId, SeriesId };

/**
 * `GET /novels/chapter?source=&series=&chapter=` — the novel analog of the
 * reader manifest (`backend/services/novel_service.py`).
 *
 * `paragraphs` is SANITIZED PLAIN TEXT, never HTML: the connector strips
 * scripts, styles, ads and aggregator watermark lines before anything is
 * cached, so what arrives here is the canonical storage form (and, later, the
 * TTS input). Rendering it as text rather than `dangerouslySetInnerHTML` is
 * therefore both the safe choice and the accurate one.
 *
 * `cache` is the same block the browse endpoints carry — `stale` means the
 * source could not be reached and this is the last good copy.
 */
export interface NovelChapterPayload {
  source_id: string;
  series_key: string;
  chapter_key: string;
  title: string | null;
  chapter_number: number | null;
  paragraphs: string[];
  /** Adjacent chapter keys, or null at the ends of the series. */
  prev: string | null;
  next: string | null;
  word_count: number;
  cache?: SourceBrowseCache | null;
}

/** One chapter's slot in a bulk window (`POST /novels/chapters`). */
export interface NovelChapterWindowItem {
  /**
   * The key the request asked for, after the server's percent-decoding — not
   * the key inside `chapter`, which a connector is free to normalise.
   */
  chapter_key: string;
  status: "ok" | "error";
  /** Byte-identical to what `GET /novels/chapter` serves, or null. */
  chapter: NovelChapterPayload | null;
  /** Exactly one of `chapter` / `error` is non-null. */
  error: { code: string; status: number; message: string } | null;
}

/**
 * `POST /novels/chapters` — a bounded WINDOW of one book's chapters in a
 * single round trip (`backend/services/novel_service.py.get_chapters_bulk`).
 *
 * `items` is the same length and order as the keys asked for, and degrades per
 * chapter: one chapter failing upstream is an `error` item, not a failed
 * window. `max_chapters` is the server's own cap, echoed on every answer so a
 * client paces by the deployment's stride rather than by a compiled-in number;
 * asking for more than it is a 413 `batch_too_large`.
 */
export interface NovelChapterWindowPayload {
  source_id: string;
  series_key: string;
  max_chapters: number;
  requested: number;
  ok_count: number;
  failed_count: number;
  items: NovelChapterWindowItem[];
}

/** A chapter ready to render, built from the payload by `toNovelChapter`. */
export interface NovelChapterContent {
  sourceId: string;
  seriesKey: string;
  chapterKey: string;
  chapterNumber: number | null;
  title: string;
  paragraphs: string[];
  previousChapterKey: string | null;
  nextChapterKey: string | null;
  wordCount: number;
  /** How many progress buckets this chapter's paragraphs map onto. */
  buckets: number;
  cache: SourceBrowseCache | null;
}


/** One attributed stretch of speech, as `GET /novels/attribution` sends it. */
export type NovelSpeakerSpanPayload = {
  /** Paragraph index into the chapter's `paragraphs`. */
  p: number;
  /** Start offset within that paragraph. */
  s: number;
  /** End offset, exclusive. */
  e: number;
  /** First characters of the attributed text, for proving the offsets. */
  head: string;
  speaker: string;
};

export type NovelAttributionPayload = {
  attributed: boolean;
  /** Who narrates THIS chapter, which in a rotating-POV book is not the series narrator. */
  narrator: string | null;
  /**
   * Identity of the exact text the offsets were computed against. The chapter
   * cache refetches, so this will eventually disagree with what is on screen —
   * which is the whole reason each span also carries a `head`.
   */
  text_fingerprint: string | null;
  spans: NovelSpeakerSpanPayload[];
  /** Ordered by how much each speaks, which is the order colours are assigned. */
  cast: { name: string; gender: string; voice_id: string | null }[];
  /** The series' pinned narration voice, or null to use the derived default. */
  narrator_voice_id: string | null;
};


/** One rendered sentence, as `GET /novels/audio` sends it. */
export type NovelAudioSegmentPayload = {
  i: number;
  start_ms: number;
  end_ms: number;
  p: number;
  s: number;
  e: number;
  voice: string;
  speaker: string | null;
  speech: boolean;
};

export type NovelAudioPayload = {
  available: boolean;
  bytes: number;
  total_ms: number;
  segments: NovelAudioSegmentPayload[];
};

/**
 * One voice a character can be given.
 *
 * `name` and `character` are what a person actually chooses on — nobody picks
 * between `libritts-2803` and `libritts-251`. `pitch_hz` is kept because it is
 * the one number that orders the list the way people ask for it ("something
 * deeper"), and the licence travels with the voice because a voice that cannot
 * say where it came from is not one this project will use.
 */
export type NovelVoicePayload = {
  voice_id: string;
  name: string;
  /** Two words on how it reads, e.g. "deep, steady". */
  character: string;
  gender: string;
  pitch_hz: number;
  expressiveness: number;
  seconds: number;
  license: string;
  attribution: string;
  transcript: string;
};
