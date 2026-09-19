/**
 * The URL an `<audio>` element loads a rendered chapter from.
 *
 * A plain URL rather than a fetch, because the element streams it itself: the
 * server answers Range requests with a 206, so seeking pulls only the bytes it
 * needs instead of re-downloading twelve minutes of Opus. Routing this through
 * the JSON client would buffer the whole file into memory and throw that away.
 */

import { env } from "@/config/env";
import type { ChapterId } from "@/types/api";

export function novelAudioUrl(ref: ChapterId): string {
  const query = new URLSearchParams({
    source: ref.sourceId,
    series: ref.seriesKey,
    chapter: ref.chapterKey,
  });
  // Encoded as query parameters, never path segments: connector keys are
  // opaque and routinely contain slashes and percent-encoding.
  return `${env.apiUrl}/novels/audio/file?${query.toString()}`;
}
