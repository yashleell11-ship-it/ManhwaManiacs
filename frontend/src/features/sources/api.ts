import { env } from "@/config/env";
import { withCoverWidth } from "@/lib/cover-url";
import { http } from "@/services/http";
import type {
  GlobalSearchResponse,
  PaginatedSourceSeries,
  SourceBrowseMode,
  SourceGenre,
  SourceChapterSummary,
  SourcePin,
  SourceSeriesDetail,
  SourceSummary,
} from "./types";

/**
 * Resolve a source-served image path (a cover, a connector icon) against the
 * API base, leaving an absolute URL alone.
 *
 * `sizes` is the caller's `next/image` hint for the box the image is painted
 * into; on a cover it becomes the proxy's `?w=` and the backend renders to fit.
 * Callers that are not painting a cover — the source icons — pass nothing, and
 * nothing changes for them. See `lib/cover-url.ts`.
 */
export function sourceImageUrl(path: string, sizes?: string | null): string {
  if (path.startsWith("http://") || path.startsWith("https://")) {
    return withCoverWidth(path, sizes);
  }
  const normalized = path.startsWith("/") ? path.slice(1) : path;
  return withCoverWidth(`${env.apiUrl}/${normalized}`, sizes);
}

export interface SourceReaderChapterResponse {
  mode: "local" | "remote";
  source_id: string | null;
  series_id: string;
  id: string;
  title: string;
  number: number | null;
  page_count: number;
  pages: Array<{
    id: string;
    chapter_id: string;
    number: number;
    width: number | null;
    height: number | null;
    image_url: string;
  }>;
  previous_chapter_id: string | null;
  next_chapter_id: string | null;
  series_title?: string | null;
}

export const sourcesApi = {
  listSources: () => http.get<SourceSummary[]>("/sources"),

  // Federated search across the local library AND every enabled remote source.
  federatedSearch: (
    params: { q: string; page?: number; per_page?: number; tier?: 1 | 2 },
  ) =>
    http.get<GlobalSearchResponse>("/sources/search", { query: params }),

  listPins: () => http.get<SourcePin[]>("/sources/pins"),

  // Whole-set replace, not add/remove: the client owns the ordering, sends the
  // list it wants, and gets that exact list back.
  replacePins: (sourceIds: string[]) =>
    http.put<SourcePin[]>("/sources/pins", { source_ids: sourceIds }),

  browseModes: (sourceId: string) =>
    http.get<SourceBrowseMode[]>(`/sources/${encodeURIComponent(sourceId)}/browse-modes`),

  genres: (sourceId: string) =>
    http.get<SourceGenre[]>(`/sources/${encodeURIComponent(sourceId)}/genres`),

  listSeries: (
    sourceId: string,
    params: {
      page?: number;
      query?: string;
      sort?: string;
      genre?: string;
      /** Bypass the server's browse cache and refetch from the connector. */
      refresh?: boolean;
    },
  ) =>
    http.get<PaginatedSourceSeries>(
      `/sources/${encodeURIComponent(sourceId)}/series`,
      { query: params },
    ),

  getSeries: (sourceId: string, seriesId: string) =>
    http.get<SourceSeriesDetail>(
      `/sources/${encodeURIComponent(sourceId)}/series/${encodeURIComponent(seriesId)}`,
    ),

  getChapters: (sourceId: string, seriesId: string) =>
    http.get<SourceChapterSummary[]>(
      `/sources/${encodeURIComponent(sourceId)}/series/${encodeURIComponent(seriesId)}/chapters`,
    ),

  getReaderChapter: (sourceId: string, seriesId: string, chapterId: string) =>
    http.get<SourceReaderChapterResponse>(
      // Chapter ids may contain `/` (Madara/Toonily). Encode each segment so
      // the backend `:path` converter still sees the slash-separated form.
      `/sources/${encodeURIComponent(sourceId)}/series/${encodeURIComponent(seriesId)}/chapters/${chapterId
        .split("/")
        .map(encodeURIComponent)
        .join("/")}/reader`,
    ),
};
