/**
 * What a library card says about where the reader is in a followed series.
 *
 * Every follow is created as "reading" and nobody ever changes it, so the
 * shelf used to print "Reading" under series the owner had followed as a
 * to-read note and never opened. The list now carries the server's
 * `read_state` for each row, and these helpers turn it into the card's words.
 *
 * Mirrors `mobile/lib/features/library/utils/read_state_label.dart` — both
 * clients describe the same series the same way.
 */

import { readingStatusLabel } from "./reading-stats";
import type { FollowedSeries, ReadState } from "./types";

/** Above this the pill stops counting; "3183 new" is noise, not information. */
const NEW_COUNT_CAP = 99;

function formatNumber(value: number): string {
  // 4 → "4", 12.5 → "12.5": printed chapter numbers, not measurements.
  return String(value);
}

/**
 * "Not started", "Ch 5 of 120", or null when the row carries no read state
 * (so the caller keeps whatever it said before).
 *
 * Printed numbers are used only when both ends have one and they are in
 * order; otherwise the position in the list is honest where a mix is not —
 * "Ch 12 of 10" is what a numbered chapter over an unnumbered tail would say.
 */
export function readStateLabel(state: ReadState | null | undefined): string | null {
  if (!state) return null;
  if (!state.started) return "Not started";
  const { chapter_number: number, latest_number: latest, position, total } = state;
  if (position != null) {
    if (number != null && latest != null && number <= latest) {
      return `Ch ${formatNumber(number)} of ${formatNumber(latest)}`;
    }
    return `Ch ${position} of ${total}`;
  }
  // Started, but on a chapter the known list no longer carries.
  if (number != null) return `Ch ${formatNumber(number)}`;
  return "Started";
}

/**
 * Chapters past the furthest one opened — 0 for a series never started, where
 * every chapter is "unread" but none is "new" to this reader.
 */
export function readStateNewCount(state: ReadState | null | undefined): number {
  if (!state?.started || state.new_count == null) return 0;
  return Math.max(0, state.new_count);
}

/** "2 new", "99+ new", or null for none. */
export function newCountLabel(count: number): string | null {
  if (count <= 0) return null;
  return count > NEW_COUNT_CAP ? `${NEW_COUNT_CAP}+ new` : `${count} new`;
}

/** A shelf row's note: "Ch 5 of 120 · 2 new", "Not started", or null. */
export function readStateNote(state: ReadState | null | undefined): string | null {
  const label = readStateLabel(state);
  if (label == null) return null;
  const fresh = newCountLabel(readStateNewCount(state));
  return fresh ? `${label} · ${fresh}` : label;
}

/**
 * A novel shelf row's note: where the reader is, else — for a row with no
 * read state — the reading-status word the shelf always printed.
 */
export function followedShelfNote(
  series: Pick<FollowedSeries, "reading_status" | "read_state">,
): string | null {
  const note = readStateNote(series.read_state);
  if (note) return note;
  return series.reading_status ? readingStatusLabel(series.reading_status) : null;
}

/**
 * The library grid card's and list row's meta line: where the reader is and
 * what is waiting, else — for a row with no read state — the chapter count.
 */
export function seriesCardMeta(
  series: Pick<FollowedSeries, "chapter_count" | "read_state">,
): string {
  return readStateNote(series.read_state) ?? `${series.chapter_count} chapters`;
}

/**
 * The shelf card's one muted line: where the reader is, else — for a row
 * with no read state — the chapter count it always showed, else nothing.
 */
export function followedCardSubtitle(
  series: Pick<FollowedSeries, "chapter_count" | "read_state">,
): string | null {
  const label = readStateLabel(series.read_state);
  if (label) return label;
  if (series.chapter_count <= 0) return null;
  return series.chapter_count === 1 ? "1 chapter" : `${series.chapter_count} chapters`;
}
