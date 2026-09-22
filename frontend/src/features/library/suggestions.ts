import type { Suggestion } from "./types";

/**
 * Pure helpers for AI reading suggestions.
 *
 * Pulled out of the view because each one encodes a decision rather than a
 * rendering detail, and a decision is worth a test: what counts as enough of a
 * description to spend a paid request on, how a dropped title is reported, and
 * what makes two suggestions distinct.
 */

/** Shortest description worth sending. Matches the server's own `min_length`. */
export const MIN_PROMPT_LENGTH = 3;

/** Longest. Matches the server's `max_length`; the box truncates rather than erroring. */
export const MAX_PROMPT_LENGTH = 600;

/**
 * Whether this text should be allowed to spend a request.
 *
 * The length floor is the server's, restated here so a two-character prompt
 * is refused before it costs anything rather than after it costs a 422.
 */
export function canSubmitPrompt(prompt: string, isPending: boolean): boolean {
  return !isPending && prompt.trim().length >= MIN_PROMPT_LENGTH;
}

/**
 * How many titles the model named that nothing here carries, said plainly.
 *
 * Returns null at zero so the caller renders nothing rather than "0 skipped".
 * This line exists because the alternative — silently returning four cards
 * when the model offered six — makes a working feature look thin for no
 * visible reason.
 */
export function droppedNotice(dropped: number): string | null {
  if (dropped <= 0) return null;
  const noun = dropped === 1 ? "suggestion" : "suggestions";
  return `${dropped} more ${noun} skipped — no source here carries them.`;
}

/**
 * React key for one suggestion.
 *
 * Keyed on source AND series id, not title: the same book legitimately exists
 * on several sources, and keying on title would collapse two real, separately
 * openable rows into one.
 */
export function suggestionKey(item: Pick<Suggestion, "source" | "series_id">): string {
  return `${item.source ?? "local"}:${item.series_id}`;
}
