"use client";

import { useCallback, useEffect, useState, useSyncExternalStore } from "react";
import {
  getStorageScope,
  subscribeStorageScope,
  type StorageScope,
} from "@/lib/scoped-storage";
import {
  getOfflineServerSnapshot,
  getOfflineSnapshot,
  registerOfflineWorker,
  subscribeOffline,
} from "./client";
import type { OfflineState, SavedChapterEntry } from "./types";

/** The worker's last published state, shared by every consumer. */
export function useOfflineState(): OfflineState {
  return useSyncExternalStore(
    subscribeOffline,
    getOfflineSnapshot,
    getOfflineServerSnapshot,
  );
}

/**
 * The active (user, profile), read from the same publisher every scoped store
 * uses. `null` until the session and the profile selection have both resolved —
 * and while it is null nothing offline is shown, because unowned saved chapters
 * are not a thing that should exist.
 */
export function useStorageScope(): StorageScope | null {
  return useSyncExternalStore(
    subscribeStorageScope,
    getStorageScope,
    () => null,
  );
}

export function useSavedChapter(key: string | null): SavedChapterEntry | null {
  const state = useOfflineState();
  if (key === null) return null;
  return state.entries.find((entry) => entry.key === key) ?? null;
}

/**
 * A worker that has installed and is waiting to take over.
 *
 * Reported rather than acted on: the swap replaces the running bundle, so it
 * happens when the reader says so, not in the middle of a page turn.
 *
 * The prompt stays up when ANOTHER tab applies the update: this tab is still
 * running the old bundle, and `applyWorkerUpdate` reloads it straight away in
 * that case. It goes away only when a newer build replaces the reported
 * worker, which then has nothing left to apply; the newer one is reported
 * through its own install.
 */
export function useWorkerUpdate(): { waiting: ServiceWorker | null } {
  const [waiting, setWaiting] = useState<ServiceWorker | null>(null);

  useEffect(() => {
    let cancelled = false;

    const report = (worker: ServiceWorker) => {
      setWaiting(worker);
      worker.addEventListener("statechange", () => {
        if (worker.state !== "redundant") return;
        // Only if it is still the one shown: the worker that replaced it may
        // already have been reported.
        setWaiting((current) => (current === worker ? null : current));
      });
    };

    void registerOfflineWorker().then((registration) => {
      if (!registration || cancelled) return;

      if (registration.waiting && navigator.serviceWorker.controller) {
        report(registration.waiting);
      }

      registration.addEventListener("updatefound", () => {
        const installing = registration.installing;
        if (!installing) return;
        installing.addEventListener("statechange", () => {
          // A worker reaching "installed" while another one controls the page
          // is an UPDATE. Without a controller it is the first install, which
          // has nothing to replace and needs no prompt.
          if (installing.state === "installed" && navigator.serviceWorker.controller) {
            report(installing);
          }
        });
      });
    });

    return () => {
      cancelled = true;
    };
  }, []);

  return { waiting };
}

/**
 * A ticking "now", for the expiry countdowns.
 *
 * The clock is an external system, not a render input: reading `Date.now()`
 * while rendering would differ between the server pass and hydration, and would
 * silently go stale afterwards. Subscribing instead gives one shared minute
 * tick that stops as soon as nothing is watching it. Returns 0 until the first
 * read, which callers treat as "not known yet" rather than 1970.
 */
const CLOCK_TICK_MS = 60_000;

let clockValue = 0;
let clockTimer: number | null = null;
const clockListeners = new Set<() => void>();

function subscribeClock(listener: () => void): () => void {
  clockListeners.add(listener);
  if (clockTimer === null) {
    clockValue = Date.now();
    clockTimer = window.setInterval(() => {
      clockValue = Date.now();
      for (const each of clockListeners) each();
    }, CLOCK_TICK_MS);
  }
  return () => {
    clockListeners.delete(listener);
    if (clockListeners.size === 0 && clockTimer !== null) {
      window.clearInterval(clockTimer);
      clockTimer = null;
    }
  };
}

export function useNow(): number {
  return useSyncExternalStore(
    subscribeClock,
    () => clockValue,
    () => 0,
  );
}

/**
 * Tracks whether the browser thinks it has a connection.
 *
 * `navigator.onLine` only proves a network interface exists, so it is used for
 * wording ("you are offline") and never to decide whether to try a request —
 * the worker decides that by actually failing.
 */
export function useOnlineStatus(): boolean {
  const subscribe = useCallback((listener: () => void) => {
    window.addEventListener("online", listener);
    window.addEventListener("offline", listener);
    return () => {
      window.removeEventListener("online", listener);
      window.removeEventListener("offline", listener);
    };
  }, []);

  return useSyncExternalStore(
    subscribe,
    () => window.navigator.onLine,
    () => true,
  );
}
