import type { ActiveProfile } from "./types";

/**
 * Whose remembered profile selection this is, and when to let it go.
 *
 * The selection is a per-device value under one fixed localStorage key, and it
 * outlived the account it was chosen under. Signing out left it in place, so
 * the next account to sign in on the same browser skipped the picker and sent
 * the previous account's profile id as `X-Profile-Id`. The server reads a
 * foreign id as "no profile" without an error, so that account saw an empty
 * library, history and updates, under the other person's name, avatar and
 * mood, with 18+ closed — until its first write came back 404 and bounced it
 * to the picker. A profile deleted from another device stayed selected the
 * same way.
 *
 * Pure and free of React so the node test environment can hold it.
 */

/** The persisted half of the store: the snapshot and the account that chose it. */
export interface ProfileSelection {
  activeProfile: ActiveProfile | null;
  /**
   * The user the selection was made under. `null` on a blob written before
   * this was recorded: it is adopted by the first account seen, and
   * {@link isSelectionGone} drops it once that account's list proves it
   * foreign — forcing every existing reader back through the picker once
   * would buy nothing that check does not already give.
   */
  ownerUserId: number | null;
}

const NONE: ProfileSelection = { activeProfile: null, ownerUserId: null };

/**
 * The selection as it stands once `userId` is known to be signed in: kept when
 * that account made it, adopted when nobody is recorded, dropped when another
 * account did. Returns the input itself when nothing changes.
 */
export function selectionForUser(
  selection: ProfileSelection,
  userId: number,
): ProfileSelection {
  if (selection.activeProfile === null) {
    return selection.ownerUserId === null ? selection : NONE;
  }
  if (selection.ownerUserId === userId) return selection;
  if (selection.ownerUserId === null) {
    return { activeProfile: selection.activeProfile, ownerUserId: userId };
  }
  return NONE;
}

export interface ProfileListState {
  /** The account's profiles, when the list has loaded. */
  profiles: readonly { id: number }[] | undefined;
  /** The last fetch succeeded. */
  isSuccess: boolean;
  /** A fetch is in flight; the list in hand may be about to change. */
  isFetching: boolean;
}

/**
 * The selected profile no longer belongs to this account — deleted on another
 * device, or never this account's to begin with.
 *
 * Only a list that loaded, and is not being replaced, may say so. A list still
 * loading, or one that failed (offline, a 5xx), knows nothing about the
 * selection, and treating it as empty would send every offline reader to the
 * picker.
 */
export function isSelectionGone(
  activeId: number | null,
  { profiles, isSuccess, isFetching }: ProfileListState,
): boolean {
  if (activeId === null || !isSuccess || isFetching || !profiles) return false;
  return !profiles.some((profile) => profile.id === activeId);
}
