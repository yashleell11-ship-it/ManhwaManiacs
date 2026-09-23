import { create } from "zustand";
import { persist, type PersistStorage, type StorageValue } from "zustand/middleware";
import { toMood } from "./mood";
import { selectionForUser, type ProfileSelection } from "./selection";
import { ACTIVE_PROFILE_STORAGE_KEY } from "./storage-key";
import type { ActiveProfile, Profile } from "./types";

/**
 * Which reading profile is currently active. This is CLIENT state (a per-device
 * selection), not server data, so it lives in zustand + localStorage rather than
 * TanStack Query. The selection gates the app: an authenticated visitor with no
 * active profile is routed to the picker (see `access.ts` + the shell gate).
 *
 * `hasHydrated` tells the gate whether the persisted value has been read back
 * yet; the gate must wait for it so a page load never redirects to the picker
 * before the remembered selection is restored.
 *
 * X-Profile-Id: the active id is exposed via {@link getActiveProfileId} so the
 * HTTP layer can attach it as an `X-Profile-Id` header. That header is wired in
 * the shared `services/http` client (owned elsewhere); until then the selection
 * lives here and is read on demand.
 *
 * The selection records the account it was made under (`ownerUserId`), and the
 * auth layer tells the store who is signed in (`bindSessionUser`) before
 * anything renders for them, so a different account signing in on the same
 * browser starts at the picker instead of inside someone else's profile — see
 * `selection.ts`.
 */
interface ActiveProfileState extends ProfileSelection {
  hasHydrated: boolean;
  /** Who is signed in right now, as the auth layer last reported. Not persisted. */
  sessionUserId: number | null;
  setActiveProfile: (profile: Profile | ActiveProfile) => void;
  clearActiveProfile: () => void;
  /**
   * Record who is signed in (`null` once nobody is) and drop a selection some
   * other account made. A null on its own clears nothing: a session that
   * merely expired keeps the selection for the same user's next sign-in.
   */
  bindSessionUser: (userId: number | null) => void;
  /** Keep the snapshot in sync when the active profile is edited/removed. */
  syncActiveProfile: (profile: Profile) => void;
  setHasHydrated: (value: boolean) => void;
}

/** Reduce a full profile (or an existing snapshot) to the stored snapshot. */
function toSnapshot(profile: Profile | ActiveProfile): ActiveProfile {
  return {
    id: profile.id,
    name: profile.name,
    avatar_key: profile.avatar_key,
    mood: profile.mood,
  };
}

/** What actually goes to localStorage (see `partialize`). */
type PersistedState = ProfileSelection;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/**
 * Narrow a persisted value back to a snapshot, or `null` when it is not one.
 *
 * Every field must have the type the rest of the app assumes without checking:
 * `id` becomes a request header, `name` is rendered, `avatar_key` is looked up,
 * `mood` picks a palette. A field missing or of the wrong type means this is
 * not a snapshot this store wrote, and re-picking a profile once beats
 * rendering a guess. The one thing salvaged is a mood *string* outside the
 * current set — a renamed mood is value drift, not corruption, and `toMood` is
 * the app's documented fallback for exactly that.
 */
function readSnapshot(value: unknown): ActiveProfile | null {
  if (!isRecord(value)) return null;
  const { id, name, avatar_key, mood } = value;
  if (typeof id !== "number" || !Number.isInteger(id)) return null;
  if (typeof name !== "string") return null;
  if (avatar_key !== null && typeof avatar_key !== "string") return null;
  if (typeof mood !== "string") return null;
  return { id, name, avatar_key, mood: toMood(mood) };
}

/** The stored envelope, or `null` for anything that is not a readable one. */
function readEnvelope(raw: string): StorageValue<PersistedState> | null {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return null;
  }
  if (!isRecord(parsed) || !isRecord(parsed.state)) return null;

  // `null` is what a cleared selection persists as; a missing key is not — the
  // envelope always carries it (see `partialize`), so its absence marks a blob
  // some other writer produced.
  const stored = parsed.state.activeProfile;
  const snapshot = stored === null ? null : readSnapshot(stored);
  if (stored !== null && snapshot === null) return null;

  // Absent on every blob written before the owner was recorded — that reads as
  // "owner unknown", not as corruption. Present, it must be a user id.
  const owner = parsed.state.ownerUserId ?? null;
  if (owner !== null && !(typeof owner === "number" && Number.isInteger(owner))) {
    return null;
  }

  const version = parsed.version;
  return {
    state: { activeProfile: snapshot, ownerUserId: owner },
    ...(typeof version === "number" ? { version } : {}),
  };
}

/** localStorage, or `null` where there is none (SSR) or it is blocked. */
function deviceStorage(): Storage | null {
  try {
    return typeof window === "undefined" ? null : window.localStorage;
  } catch {
    return null;
  }
}

/**
 * The persisted selection, read TOTALLY.
 *
 * The shell's profile gate blocks on `hasHydrated`, and zustand only flips it
 * on the success path: one unreadable byte in this key — a truncated write, a
 * write that died on quota, a shape from an older build — used to throw out of
 * hydration and strand the app on a loading screen forever, with no recovery a
 * reader could find short of clearing site data. So anything that does not read
 * back as a selection is treated as "nothing stored" AND wiped, which makes the
 * next load clean instead of repeating the same failure.
 */
const activeProfileStorage: PersistStorage<PersistedState> = {
  getItem: (name) => {
    // A read that throws (storage revoked mid-session) would surface as a
    // hydration error — the same dead end as a bad blob, so the same answer.
    try {
      const storage = deviceStorage();
      if (!storage) return null;
      const raw = storage.getItem(name);
      if (raw === null) return null;
      const envelope = readEnvelope(raw);
      if (envelope === null) storage.removeItem(name);
      return envelope;
    } catch {
      return null;
    }
  },
  setItem: (name, value) => {
    // A device that cannot remember the selection still has to run.
    try {
      deviceStorage()?.setItem(name, JSON.stringify(value));
    } catch {
      /* full or blocked storage costs persistence, never the interaction */
    }
  },
  removeItem: (name) => {
    try {
      deviceStorage()?.removeItem(name);
    } catch {
      /* same as setItem */
    }
  },
};

export const useActiveProfileStore = create<ActiveProfileState>()(
  persist(
    (set, get) => ({
      activeProfile: null,
      ownerUserId: null,
      hasHydrated: false,
      sessionUserId: null,
      setActiveProfile: (profile) =>
        set({ activeProfile: toSnapshot(profile), ownerUserId: get().sessionUserId }),
      clearActiveProfile: () => set({ activeProfile: null, ownerUserId: null }),
      bindSessionUser: (userId) => {
        if (get().sessionUserId !== userId) set({ sessionUserId: userId });
        if (userId === null) return;
        const current = get();
        const next = selectionForUser(current, userId);
        if (
          next.activeProfile !== current.activeProfile ||
          next.ownerUserId !== current.ownerUserId
        ) {
          set(next);
        }
      },
      syncActiveProfile: (profile) => {
        const current = get().activeProfile;
        if (current && current.id === profile.id) {
          set({ activeProfile: toSnapshot(profile) });
        }
      },
      setHasHydrated: (value) => set({ hasHydrated: value }),
    }),
    {
      name: ACTIVE_PROFILE_STORAGE_KEY,
      storage: activeProfileStorage,
      // Persist only the selection and its owner; `hasHydrated` and the
      // session user are runtime-only.
      partialize: (state) => ({
        activeProfile: state.activeProfile,
        ownerUserId: state.ownerUserId,
      }),
      // The gate opens on EVERY path. zustand calls this back with an undefined
      // state when hydration threw — exactly the case that must not strand the
      // app — so fall back to the pre-hydration state handed to the factory,
      // whose `setHasHydrated` closes over the same `set`.
      onRehydrateStorage: (before) => (state) => {
        const store = state ?? before;
        store.setHasHydrated(true);
        // A user the auth layer reported before the stored selection was read
        // back still gets the owner check.
        if (store.sessionUserId !== null) store.bindSessionUser(store.sessionUserId);
      },
    },
  ),
);

/**
 * The active profile id for the HTTP layer to attach as `X-Profile-Id`, or
 * `null` when no profile is selected. Reads the store outside React so it can be
 * called from the framework-agnostic request pipeline.
 */
export function getActiveProfileId(): number | null {
  return useActiveProfileStore.getState().activeProfile?.id ?? null;
}
