/**
 * Source-native library types (spec §2, §3.4).
 *
 * The library is the per-profile set of `followed_series` rows. A series is
 * `(source_id, series_key)`; a chapter is `(source_id, series_key,
 * chapter_key)`. There is no local catalog, no `library_id`, no integer series
 * id for domain identity — `followed_id` is only a handle for follow-row
 * mutations (`PATCH`/`DELETE /library/...`).
 */

import type { GlobalSearchItem } from "@/features/sources/types";
import type { SeriesId } from "@/types/api";

export type { SeriesId };

/** One entry in a followed series' known-chapter snapshot / live chapter list. */
export interface KnownChapter {
  key: string;
  number: number | null;
  title: string | null;
  published_at: string | null;
  /** Only present on the cache-backed detail chapter list. */
  page_count?: number | null;
}

/**
 * A followed series as returned by `GET /library/series` items and
 * `POST /library/follow` (backend `FollowedSeriesService.serialize`).
 */
export interface FollowedSeries {
  /** `followed_id` — the follow row's PK. Use for PATCH/DELETE, never routing. */
  id: number;
  source_id: string;
  series_key: string;
  /**
   * The connector's name for the series this key names — equal to
   * `series_key` except on a source whose keys drift (Asura rotates its slug
   * suffixes). Compared against a series page's own `series_identity` to find
   * a follow made under an older key; never fetched with.
   */
  series_identity?: string;
  title: string;
  /**
   * Ready-to-use cover URL. The backend returns either the source's own
   * absolute URL or a backend-relative `/sources/{source}/series/{series}/cover`
   * proxy path — resolve the relative form against the API base with
   * `libraryCoverUrl`.
   */
  cover_url: string;
  is_favorite: boolean;
  reading_status: string;
  notify: boolean;
  sort_order: number;
  content_rating: string;
  /** Effective rating after gate/override resolution ("mature" | "safe" | ...). */
  rating: string;
  mature_override: boolean | null;
  /**
   * The series' whole chapter list — **absent from every list payload**.
   * `GET /library/series`, `/library/recently-updated` and the collection
   * listings omit it (it was ~830 KB of the 832 KB a 40-row page weighed,
   * and no list view draws it); the detail endpoint, `follow` and `patch`
   * still send it, so `SeriesDetail` re-declares it as required. Use
   * `chapter_count` for a count — that is present everywhere.
   */
  known_chapters?: KnownChapter[];
  chapter_count: number;
  last_checked_at: string | null;
  created_at: string | null;
  updated_at: string | null;
  /**
   * Where this profile stands in the series. Sent by the list, `follow` and
   * `patch`; absent elsewhere (the detail page has its own progress overlay).
   * Render it through `read-state.ts`, never inline.
   */
  read_state?: ReadState;
}

/**
 * `FollowedSeriesService._read_states` — this profile's reading of one
 * followed series, computed for a whole list page in one query.
 */
export interface ReadState {
  /** Whether this profile has opened any chapter of the series. */
  started: boolean;
  /** The furthest chapter opened, by reading order; null when not in the list. */
  chapter_key: string | null;
  /** That chapter's printed number, where the source numbers it. */
  chapter_number: number | null;
  /** 1-based position of that chapter in reading order; null when unknown. */
  position: number | null;
  /** How many chapters the known list holds. */
  total: number;
  /** The printed number of the last chapter in reading order, where known. */
  latest_number: number | null;
  /** Chapters past the furthest one opened; null when the position is unknown. */
  new_count: number | null;
}

/** `GET /library/series` — paginated followed-series list. */
export interface SeriesListResponse {
  items: FollowedSeries[];
  total: number;
  page: number;
  per_page: number;
  page_size: number;
  has_next: boolean;
  has_more: boolean;
  total_pages: number;
}

/** Per-chapter reading position overlaid on the detail payload. */
export interface ChapterProgressEntry {
  last_page: number;
  is_completed: boolean;
}

/**
 * `GET /library/series/{followed_id}` — the follow row plus cache meta, the
 * live chapter list, and a `chapter_key -> progress` overlay.
 */
export interface SeriesDetail extends FollowedSeries {
  /** Present on the detail payload (narrowed from the optional above). */
  known_chapters: KnownChapter[];
  description: string | null;
  author: string | null;
  genres: string[] | null;
  chapters: KnownChapter[];
  progress: Record<string, ChapterProgressEntry>;
}

/**
 * `POST` / `DELETE /library/follow` outcome — the follow row after the write,
 * or `null` once unfollowed.
 */
export type FollowMutationResult = FollowedSeries | null;

/** `GET /library/continue-reading` item (progress-service shape). */
export interface ContinueReadingItem {
  source_id: string;
  series_key: string;
  chapter_key: string;
  chapter_number: number | null;
  last_page: number;
  page_count: number;
  last_read_at: string | null;
}

/**
 * The `sort` values `GET /library/series` understands
 * (`FollowedSeriesService.list_series`). A leading `-` reverses.
 */
export type SeriesSort =
  | "title"
  | "sort_title"
  | "sort_order"
  | "updated_at"
  | "recently_updated"
  | "created_at"
  | "recently_added";

/** Reading-status filter used by the toolbar. `all` is the client-only default. */
export type SeriesFilter = "all" | "unread" | "reading" | "completed" | "on_hold" | "plan_to_read" | "dropped";

// --- Collections ---

export interface Collection {
  id: number;
  name: string;
  description: string | null;
  sort_order: number;
  series_count: number;
}

export interface CollectionRef {
  id: number;
  name: string;
}

export interface CollectionSeriesRef {
  source_id: string;
  series_key: string;
  sort_order: number;
}

export interface CollectionDetail extends Collection {
  series: CollectionSeriesRef[];
}

// --- Search ---

export type SearchResponse = SeriesListResponse;

// --- Recommendations ---

/** `GET /library/recommendations` — top genres over the followed set. */
export interface RecommendationGenre {
  genre: string;
  weight: number;
}

export type RecommendationsResponse = RecommendationGenre[];

// --- Reading history ---

/**
 * `GET /reader/history` row (progress-service `_serialize`), plus the book it
 * is a position in (`_with_titles`).
 */
export interface ReadingHistoryItem {
  id: number;
  source_id: string;
  series_key: string;
  chapter_key: string;
  chapter_number: number | null;
  last_page: number;
  page_count: number;
  scroll_offset_px: number;
  is_completed: boolean;
  started_at: string | null;
  last_read_at: string | null;
  completed_at: string | null;
  time_spent_seconds: number;
  /** Null when the book has aged out of the server's series cache. */
  series_title: string | null;
  /**
   * As stored in the series cache — in production the backend-RELATIVE
   * `/sources/{src}/series/{key}/cover` path. Resolve it with
   * `historyCoverSrc`, never hand it to an `<img>` as-is.
   */
  cover_url: string | null;
}

// --- Statistics ---

/**
 * The five numbers every roll-up in the statistics payload reports, in the one
 * shape `ReadingStatsService._roll` emits (`backend/services/reading_stats_service.py`).
 */
export interface ReadingRollup {
  sessions: number;
  pages_read: number;
  chapters_read: number;
  series_read: number;
  /**
   * Wall-clock seconds, with each individual session clamped to
   * `range.session_cap_seconds` — a chapter left open on a locked phone is a
   * client that stopped talking, not nine hours of reading.
   */
  seconds_read: number;
}

/** One day of the dense daily series. `date` is a LOCAL calendar day, not a timestamp. */
export interface DailyReading extends ReadingRollup {
  /** `"YYYY-MM-DD"` at `range.timezone_offset_minutes`. Use `parseCalendarDay`, never `parseUtcTimestamp`. */
  date: string;
}

/** One of 24 hour buckets, always dense and always in `hour` order. */
export interface HourlyReading {
  /** 0–23, at `range.timezone_offset_minutes`. */
  hour: number;
  sessions: number;
  pages_read: number;
  seconds_read: number;
}

export interface SourceReading extends ReadingRollup {
  source_id: string;
  /** The connector's display name, or the raw id when it is no longer installed. */
  name: string;
}

/** Per-series roll-up. `series_read` is omitted server-side — it is always 1. */
export interface SeriesReading extends Omit<ReadingRollup, "series_read"> {
  source_id: string;
  series_key: string;
  /** From the follow row; `null` once the series is unfollowed (its history still counts). */
  title: string | null;
  cover_url: string | null;
  last_read_at: string | null;
}

export interface RecentSession {
  source_id: string;
  series_key: string;
  chapter_key: string;
  chapter_number: number | null;
  title: string | null;
  pages_read: number;
  seconds_read: number;
  started_at: string | null;
  ended_at: string | null;
}

/**
 * `GET /library/statistics` (`FollowedSeriesService.statistics` +
 * `ReadingStatsService.build`).
 *
 * The first four fields are the original library-shape payload and keep their
 * meaning; everything below them comes from `reading_sessions`, which the
 * backend recorded for months before anything read it back.
 *
 * Two different clocks live in here and mixing them up is the bug this project
 * has already fixed twice:
 *  - `*_at` fields are naive-UTC instants — `parseUtcTimestamp` them.
 *  - `daily[].date` and `streak.last_active_date` are calendar days already
 *    bucketed at `range.timezone_offset_minutes` — `parseCalendarDay` them.
 */
export interface Statistics {
  followed_total: number;
  favorites: number;
  by_reading_status: Record<string, number>;
  chapters_completed: number;

  range: {
    days: number;
    /** Naive-UTC instant the window opens at. */
    since: string | null;
    /** Naive-UTC "now". */
    until: string | null;
    /** Minutes EAST of UTC, echoed back from the request so a chart can label honestly. */
    timezone_offset_minutes: number;
    /** Per-session clamp applied to every `seconds_read`. */
    session_cap_seconds: number;
  };
  /** All time, ignoring `range.days`. */
  totals: ReadingRollup & {
    first_session_at: string | null;
    last_session_at: string | null;
  };
  /** The selected window only. */
  window: ReadingRollup;
  streak: {
    current_days: number;
    longest_days: number;
    /** Calendar day, or `null` when nothing has ever been read. */
    last_active_date: string | null;
  };
  /** Dense: one entry per day in the window, zeros included. */
  daily: DailyReading[];
  /** Always 24 entries, hour 0 through 23. */
  by_hour: HourlyReading[];
  /** Top sources in the window by pages read (server caps the list). */
  by_source: SourceReading[];
  /** Top series in the window by pages read (server caps the list). */
  by_series: SeriesReading[];
  /** The last few sessions, deliberately NOT clipped to the window. */
  recent_sessions: RecentSession[];
}

/**
 * One AI suggestion: a series this server can actually open, plus why.
 *
 * It extends `GlobalSearchItem` because that is literally what it is — the
 * server only ever picks suggestions out of its own catalog cache, so a
 * suggestion opens through the same route a search hit does. Titles the model
 * named that no configured source carries never arrive here; they are counted
 * in `dropped` and discarded, because a card that cannot be opened is worse
 * than one fewer card.
 */
export interface Suggestion extends GlobalSearchItem {
  /** The model's one line on why this fits. May be empty. */
  why: string;
}

export interface SuggestResponse {
  items: Suggestion[];
  /** How many titles the model named that nothing here carries. */
  dropped: number;
  /** Requests left in today's allowance. */
  remaining_today: number;
  model: string;
}

/**
 * Whether suggestions can run, answered without running one.
 *
 * An unconfigured key is a deployment state, not an error — so the client
 * hides the prompt box rather than offering a button that 503s on tap.
 */
export interface SuggestAvailability {
  available: boolean;
  /** `ok` · `not_configured` · `budget_exhausted`. */
  reason: string;
  remaining_today: number;
  daily_ceiling: number;
}
