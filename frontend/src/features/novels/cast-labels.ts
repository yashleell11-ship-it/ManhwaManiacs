import { apiErrorMessage } from "@/lib/view-state";
import type { NovelVoicePayload } from "./types";

/**
 * What the cast panel calls a character's voice, and what it says when a
 * change is refused.
 *
 * Pulled out of the components because each of these is a claim about what
 * the rendered audio will do, and a wrong claim here is the bug: the panel
 * used to label every character without a pinned voice "narrator", while the
 * render plan gives each of them an automatically assigned voice of their own
 * (matched on gender, handed out in speaking order). The reader was told one
 * thing and heard another.
 */

/** Label of the picker row that clears a pinned voice (`voice_id: null`). */
export const AUTOMATIC_VOICE = "Automatic voice";

/** What an unpinned character is shown as reading in. */
export const AUTOMATIC = "Automatic";

/**
 * The voice named next to a character.
 *
 * A pinned voice the roster does not list (a clip taken out of the pack) is
 * shown by its id rather than as automatic: the render plan applies a pin as
 * it stands, so calling it automatic would be the same wrong claim again.
 */
export function castVoiceLabel(
  voiceId: string | null,
  voices: readonly NovelVoicePayload[] | undefined,
): string {
  if (!voiceId) return AUTOMATIC;
  return voices?.find((voice) => voice.voice_id === voiceId)?.name ?? voiceId;
}

/**
 * The picker's first row, which sends `voice_id: null`.
 *
 * The same request means slightly different things for the two things the
 * picker casts: a character goes back to whatever the automatic pass gives
 * them, and the narration goes back to the book's derived default. Neither is
 * "read as narrator" — a character's lines are never folded into the
 * narration voice by clearing their pin.
 */
export function automaticVoiceOption(forNarration: boolean): {
  title: string;
  detail: string;
} {
  return {
    title: AUTOMATIC_VOICE,
    detail: forNarration
      ? "The book's default narration voice"
      : "Assigned automatically, not pinned",
  };
}

/**
 * The line shown when a voice change fails, or null when nothing failed.
 *
 * The server's own message wins: changing a voice is an administrator's
 * action, and "Administrator access required." tells a reader why their
 * press did nothing, where a generic failure (or silence, which is what this
 * used to be) leaves them pressing it again.
 */
export function voiceChangeError(error: unknown): string | null {
  if (error === null || error === undefined) return null;
  return apiErrorMessage(error, "The voice could not be changed. Try again.");
}
