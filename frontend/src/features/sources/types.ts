/** Connector reachability, as last observed by the server. */
export interface SourceHealth {
  status: string;
  consecutive_failures: number;
  demoted: boolean;
  last_ok_at: string | null;
  last_error_at: string | null;
  last_error: string | null;
  last_checked_at: string | null;
}

export interface SourceSummary {
  id: string;
  name: string;
  description: string;
  browsable: boolean;
  supports_import: boolean;
  icon_url?: string | null;
  /**
   * 18+ connector. `GET /sources` has always carried this — the web type just
   * never modelled it, which is why the web listing had no way to badge or
   * filter adult sources while the mobile one did.
   */
  mature?: boolean;
  /**
   * What this connector serves: `"manga"` (pages) or `"novel"` (prose). The
   * clients branch on it to open the right reader and to scope the app's
   * Manga / Novels mode.
   *
   * Optional because an older backend does not send it — and treating absence
   * as `"manga"` is exactly right: novel sources only appear at all when
   * `MM_NOVELS_ENABLED` is on, and a server that has never heard of the field
   * has no novel connectors to list.
   */
  content_kind?: "manga" | "novel";
  /**
   * Content language where the connector declares one (novel connectors say
   * `"en"`); null/absent for the legacy manga connectors, which never did.
   */
  language?: string | null;
  health?: SourceHealth | null;
}

/**
 * A pinned source as returned by `GET`/`PUT /sources/pins`.
 *
 * Pins live on the server and are scoped to `(user_id, profile_id)`, so they
 * follow the account across devices and never leak between profiles.
 * `source_id` is a connector key, not a foreign key: a connector can be
 * removed, renamed, or hidden by the 18+ gate, in which case the pin is still
 * returned with `available: false` rather than silently vanishing from the
 * user's ordering.
 */
export interface SourcePin {
  source_id: string;
  /** 0-based and dense — identical to the position in the pins array. */
  sort_order: number;
  /** Connector display name; falls back to `source_id` when unresolvable. */
  name: string;
  icon_url: string | null;
  mature: boolean;
  /** False when `source_id` no longer resolves to a source this profile sees. */
  available: boolean;
}

export interface SourceSeriesSummary {
  id: string;
  source_id: string;
  title: string;
  chapter_count: number;
  description: string | null;
  author: string | null;
  artist: string | null;
  status: string | null;
  genres: string[];
  latest_chapter: string | null;
  cover_url: string;
}

export type SourceSeriesDetail = SourceSeriesSummary;

export interface SourceChapterSummary {
  id: string;
  source_id: string;
  series_id: string;
  title: string;
  number: number | null;
  page_count: number;
  release_date: string | null;
}

/**
 * Where a browse page came from, as reported by `GET /sources/{id}/series`.
 *
 * `fresh` — served from the browse cache inside its TTL. `live` — fetched from
 * the connector just now (always the case for a search, which bypasses the
 * cache). `stale` — the connector could not be reached, so the last saved page
 * was served instead of a 502. `fetched_at` is UTC and, like every backend
 * timestamp, carries no offset — parse it with `parseUtcTimestamp`.
 *
 * Optional on the type because a search response and any older backend may not
 * carry it; the UI treats its absence as "nothing to say".
 */
export interface SourceBrowseCache {
  status: "fresh" | "live" | "stale";
  stale: boolean;
  fetched_at: string;
}

export interface PaginatedSourceSeries {
  items: SourceSeriesSummary[];
  page: number;
  page_size: number;
  total: number;
  total_pages: number;
  has_more: boolean;
  cache?: SourceBrowseCache | null;
}

export interface SourceBrowseMode {
  id: string;
  label: string;
}

export type SourceGenre = SourceBrowseMode;

/**
 * A single hit from the federated `GET /sources/search` endpoint, which merges
 * the local library and every enabled remote source into one feed.
 *
 * `series_id` is always a STRING (local ids are numeric strings, source ids are
 * opaque source-defined strings). `cover_url` arrives as a backend-relative
 * `/sources/{id}/series/{key}/cover` path and is resolved against the API base
 * once, where the response lands (`resolveSearchCovers`) — never again after.
 */
export interface GlobalSearchItem {
  /** `"local"` for a library series, `"source"` for a remote source series. */
  kind: "local" | "source";
  /** Source id (e.g. `mangadex`) when `kind === "source"`; null for local. */
  source: string | null;
  series_id: string;
  title: string;
  /** Cover URL, already resolved against the API base; use directly. */
  cover_url: string | null;
  author: string | null;
  /**
   * Catalog size as the source reported it, on source hits only. `0` means
   * "the source did not say" — most search endpoints omit it — not "empty".
   */
  chapter_count?: number | null;
  extra: Record<string, unknown> | null;
}

/**
 * `ok` — the source answered with hits. `empty` — it answered with nothing (or
 * with results the backend discarded as unrelated to the query, in which case
 * `error` carries the explanation). `error` — it did not answer.
 */
export type GlobalSearchGroupStatus = "ok" | "empty" | "error";

/**
 * One section of `GET /sources/search`: the local library plus one entry per
 * queried source.
 *
 * Ordering is decided server-side and must be preserved verbatim — `groups[0]`
 * is the local library, then sources best-relevance-first with empty and failed
 * ones sinking to the bottom. Items inside a group are already best-match-first.
 */
export interface GlobalSearchGroup {
  /** Connector id, or `null` — which is what identifies the local library. */
  source: string | null;
  source_name: string;
  icon_url: string | null;
  status: GlobalSearchGroupStatus;
  /** Always set on `error`; also set on an `empty` group the backend ignored. */
  error: string | null;
  total: number;
  has_more: boolean;
  items: GlobalSearchItem[];
}

export interface GlobalSearchResponse {
  /**
   * Flat, round-robin-interleaved view of `groups`, kept by the backend for
   * older clients. The web renders `groups`.
   */
  items: GlobalSearchItem[];
  groups: GlobalSearchGroup[];
  sources_queried: number;
  sources_failed: number;
  /** Sources this tier did not ask. Absent on an untiered response. */
  sources_deferred?: number;
  tier?: 1 | 2 | null;
  /** Non-null means there is more to fetch; ask again with this tier. */
  next_tier?: 2 | null;
  page: number;
  has_more: boolean;
}
