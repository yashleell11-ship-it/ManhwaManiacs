import { afterEach, describe, expect, it, vi } from "vitest";

import { isSelectionGone, selectionForUser, type ProfileSelection } from "./selection";
import { ACTIVE_PROFILE_STORAGE_KEY as KEY } from "./storage-key";
import type { ActiveProfile } from "./types";

const YASH = 1;
const ANTHONY = 4;
const ACTION: ActiveProfile = { id: 1, name: "action", avatar_key: "a", mood: "default" };

describe("selectionForUser", () => {
  const mine: ProfileSelection = { activeProfile: ACTION, ownerUserId: YASH };

  it("keeps the selection for the account that made it", () => {
    expect(selectionForUser(mine, YASH)).toBe(mine);
  });

  it("drops it when another account signs in on the same browser", () => {
    expect(selectionForUser(mine, ANTHONY)).toEqual({ activeProfile: null, ownerUserId: null });
  });

  it("adopts a selection stored before owners were recorded", () => {
    expect(selectionForUser({ activeProfile: ACTION, ownerUserId: null }, YASH)).toEqual({
      activeProfile: ACTION,
      ownerUserId: YASH,
    });
  });

  it("has nothing to do without a selection", () => {
    const none: ProfileSelection = { activeProfile: null, ownerUserId: null };
    expect(selectionForUser(none, YASH)).toBe(none);
  });
});

describe("isSelectionGone", () => {
  const loaded = { isSuccess: true, isFetching: false };

  it("is gone when this account's list does not carry it", () => {
    expect(isSelectionGone(1, { ...loaded, profiles: [{ id: 3 }] })).toBe(true);
  });

  it("stays while the list carries it", () => {
    expect(isSelectionGone(3, { ...loaded, profiles: [{ id: 2 }, { id: 3 }] })).toBe(false);
  });

  it("is never judged on a list that has not loaded, failed, or is being replaced", () => {
    expect(isSelectionGone(1, { profiles: undefined, isSuccess: false, isFetching: true })).toBe(false);
    // Offline: the fetch failed and there is no list to judge by.
    expect(isSelectionGone(1, { profiles: undefined, isSuccess: false, isFetching: false })).toBe(false);
    // A refetch in flight may be about to add the profile just created.
    expect(isSelectionGone(1, { profiles: [{ id: 3 }], isSuccess: true, isFetching: true })).toBe(false);
  });

  it("has nothing to judge without a selection", () => {
    expect(isSelectionGone(null, { ...loaded, profiles: [] })).toBe(false);
  });
});

/* ---- the store, run against an in-memory localStorage ---- */

class MemoryStorage {
  private readonly entries = new Map<string, string>();
  get length() { return this.entries.size; }
  key(i: number) { return [...this.entries.keys()][i] ?? null; }
  getItem(k: string) { return this.entries.get(k) ?? null; }
  setItem(k: string, v: string) { this.entries.set(k, String(v)); }
  removeItem(k: string) { this.entries.delete(k); }
  clear() { this.entries.clear(); }
}

const g = globalThis as unknown as Record<string, unknown>;

async function loadStore(seed: string | null) {
  vi.resetModules();
  const storage = new MemoryStorage();
  if (seed !== null) storage.setItem(KEY, seed);
  g.window = { localStorage: storage };
  const mod = await import("./store");
  return { store: mod.useActiveProfileStore, getActiveProfileId: mod.getActiveProfileId, storage };
}

const envelope = (state: unknown) => JSON.stringify({ state, version: 0 });

afterEach(() => {
  delete g.window;
});

describe("the active-profile store across accounts", () => {
  it("a selection made by one account is dropped when another signs in", async () => {
    const { store, getActiveProfileId, storage } = await loadStore(null);
    store.getState().bindSessionUser(YASH);
    store.getState().setActiveProfile(ACTION);
    expect(JSON.parse(storage.getItem(KEY)!).state.ownerUserId).toBe(YASH);

    // Signed out by expiry (not by the button): the selection stays…
    store.getState().bindSessionUser(null);
    expect(getActiveProfileId()).toBe(ACTION.id);

    // …and is gone the moment a different account is reported.
    store.getState().bindSessionUser(ANTHONY);
    expect(getActiveProfileId()).toBeNull();
  });

  it("the same account signing back in keeps its selection", async () => {
    const { store, getActiveProfileId } = await loadStore(null);
    store.getState().bindSessionUser(YASH);
    store.getState().setActiveProfile(ACTION);
    store.getState().bindSessionUser(null);
    store.getState().bindSessionUser(YASH);
    expect(getActiveProfileId()).toBe(ACTION.id);
  });

  it("a stored selection is checked against the account on the next load", async () => {
    const { store, getActiveProfileId } = await loadStore(
      envelope({ activeProfile: ACTION, ownerUserId: YASH }),
    );
    expect(getActiveProfileId()).toBe(ACTION.id);
    store.getState().bindSessionUser(ANTHONY);
    expect(getActiveProfileId()).toBeNull();
  });

  it("a blob from before owners were recorded still hydrates, and is adopted", async () => {
    const { store, getActiveProfileId, storage } = await loadStore(envelope({ activeProfile: ACTION }));
    expect(store.getState().hasHydrated).toBe(true);
    expect(getActiveProfileId()).toBe(ACTION.id);
    store.getState().bindSessionUser(YASH);
    expect(getActiveProfileId()).toBe(ACTION.id);
    expect(JSON.parse(storage.getItem(KEY)!).state.ownerUserId).toBe(YASH);
  });

  it("an owner that is not a user id is a blob this store never wrote", async () => {
    const { getActiveProfileId, storage } = await loadStore(
      envelope({ activeProfile: ACTION, ownerUserId: "1" }),
    );
    expect(getActiveProfileId()).toBeNull();
    expect(storage.getItem(KEY)).not.toContain('"ownerUserId":"1"');
  });

  it("clearing forgets the owner along with the profile", async () => {
    const { store, storage } = await loadStore(null);
    store.getState().bindSessionUser(YASH);
    store.getState().setActiveProfile(ACTION);
    store.getState().clearActiveProfile();
    expect(JSON.parse(storage.getItem(KEY)!).state).toEqual({ activeProfile: null, ownerUserId: null });
  });
});
