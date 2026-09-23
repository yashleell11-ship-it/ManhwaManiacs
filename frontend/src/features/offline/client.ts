import { env } from "@/config/env";
import type { StorageScope } from "@/lib/scoped-storage";
import {
  OFFLINE_MESSAGE,
  isOfflineStateMessage,
  type OfflineReply,
  type SaveChapterRequest,
} from "./protocol";
import type { OfflineState, OfflineWorkerState } from "./types";
import { decideWorkerUpdate } from "./worker-update";

/**
 * The page half of the offline feature: register the worker, tell it which
 * profile is looking, relay requests, and hold the last state it published.
 *
 * A plain module store rather than React state because three unrelated places
 * render it — the reader's save control, the storage screen and the update
 * prompt — and they must never disagree about what is saved.
 */

const EMPTY_STATE: OfflineState = {
  readiness: "pending",
  scopeToken: null,
  entries: [],
  retentionMs: null,
  estimate: null,
  openChapterKey: null,
};

const UNSUPPORTED_STATE: OfflineState = { ...EMPTY_STATE, readiness: "unsupported" };

let snapshot: OfflineState = EMPTY_STATE;
const listeners = new Set<() => void>();

/**
 * Structural equality for what the worker posts: plain JSON, arrays and
 * objects of strings, numbers, booleans and null. Every message arrives as a
 * fresh structured clone, so identity alone says nothing about change.
 */
function sameValue(a: unknown, b: unknown): boolean {
  if (Object.is(a, b)) return true;
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) {
    return false;
  }
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false;
    for (let index = 0; index < a.length; index += 1) {
      if (!sameValue(a[index], b[index])) return false;
    }
    return true;
  }
  const left = a as Record<string, unknown>;
  const right = b as Record<string, unknown>;
  const keys = Object.keys(left);
  if (keys.length !== Object.keys(right).length) return false;
  for (const key of keys) {
    if (!Object.prototype.hasOwnProperty.call(right, key)) return false;
    if (!sameValue(left[key], right[key])) return false;
  }
  return true;
}

/**
 * `next`, built out of `previous` wherever the two agree, and `previous`
 * itself when they agree entirely.
 *
 * While any chapter is saving the worker broadcasts about every 300 ms, and it
 * also answers every tab refocus and every restart with a full snapshot. Most
 * of those say nothing new, and the ones that do usually change one entry. An
 * unchanged entry keeps its old object and an unchanged list keeps its old
 * array, so a consumer that derives from `entries` (a series page's chapter
 * states) can tell by identity that nothing it shows moved.
 */
export function reconcileOfflineState(
  previous: OfflineState,
  next: OfflineState,
): OfflineState {
  const before = new Map(previous.entries.map((entry) => [entry.key, entry]));
  let entriesChanged = next.entries.length !== previous.entries.length;
  const entries = next.entries.map((entry, index) => {
    const old = before.get(entry.key);
    const kept = old !== undefined && sameValue(old, entry) ? old : entry;
    if (kept !== previous.entries[index]) entriesChanged = true;
    return kept;
  });
  const merged: OfflineState = {
    ...next,
    entries: entriesChanged ? entries : previous.entries,
    estimate: sameValue(previous.estimate, next.estimate) ? previous.estimate : next.estimate,
  };
  return sameValue(previous, merged) ? previous : merged;
}

/**
 * Replace the snapshot and tell every subscriber, but only when something
 * actually changed: each subscriber is a React tree, and on a series page that
 * tree is a chapter list with no windowing.
 */
function publish(next: OfflineState): void {
  const merged = reconcileOfflineState(snapshot, next);
  if (merged === snapshot) return;
  snapshot = merged;
  for (const listener of listeners) listener();
}

/**
 * Told about every state message the worker sends, changed or not.
 *
 * `subscribeOffline` stays quiet when a message repeats the last one, which is
 * right for rendering and wrong for one reader: a download queue that gives up
 * on a chapter after the worker has been SILENT for a while. A worker that is
 * still sending the same "saving" state (a run of pages failing, say) is alive,
 * and this is how the queue hears it.
 */
const heardListeners = new Set<() => void>();

export function subscribeWorkerHeard(listener: () => void): () => void {
  heardListeners.add(listener);
  return () => {
    heardListeners.delete(listener);
  };
}

export function getOfflineSnapshot(): OfflineState {
  return snapshot;
}

/** Stable across renders on the server, where there is no worker at all. */
export function getOfflineServerSnapshot(): OfflineState {
  return EMPTY_STATE;
}

export function subscribeOffline(listener: () => void): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

export function isServiceWorkerSupported(): boolean {
  return (
    typeof window !== "undefined" &&
    "serviceWorker" in window.navigator &&
    window.isSecureContext
  );
}

/**
 * The API base as an absolute URL.
 *
 * Mirrors `resolveApiBase` in `services/http.ts:14`: production serves the
 * backend same-origin under `/api` and dev points at a separate origin. The
 * worker is told the result because a cached URL has to be recognised as an API
 * call in both shapes, and the worker cannot read `NEXT_PUBLIC_API_URL`.
 */
export function resolveApiBase(): string {
  const base = env.apiUrl;
  if (/^https?:\/\//i.test(base)) return base;
  if (typeof window !== "undefined") return `${window.location.origin}${base}`;
  return base;
}

/**
 * Whether the worker runs at all.
 *
 * Off in development unless explicitly asked for: `next dev` serves JS chunks
 * from URLs that are not content-hashed, so the cache-first rule for build
 * assets would happily serve this morning's bundle after an edit. Production
 * builds hash every chunk, which is what makes that rule safe.
 */
export function shouldRegisterWorker(): boolean {
  if (!isServiceWorkerSupported()) return false;
  if (process.env.NODE_ENV === "production") return true;
  return process.env.NEXT_PUBLIC_ENABLE_SW === "1";
}

let registrationPromise: Promise<ServiceWorkerRegistration | null> | null = null;
let workerEventsWired = false;

export function registerOfflineWorker(): Promise<ServiceWorkerRegistration | null> {
  if (!shouldRegisterWorker()) {
    publish(UNSUPPORTED_STATE);
    return Promise.resolve(null);
  }
  if (registrationPromise) return registrationPromise;

  wireWorkerEvents();
  registrationPromise = window.navigator.serviceWorker
    // `updateViaCache: "none"` so neither sw.js nor the policy it imports can be
    // answered from the HTTP cache — an undetectable worker update is how a
    // stale shell becomes permanent.
    .register("/sw.js", { scope: "/", updateViaCache: "none" })
    .catch(() => {
      publish(UNSUPPORTED_STATE);
      return null;
    });
  return registrationPromise;
}

/**
 * Announced by the worker when it starts, including the silent restart the
 * browser performs after terminating an idle one. Not part of `OFFLINE_MESSAGE`
 * because nothing here asks for it: this is the worker speaking first.
 */
const WORKER_STARTED_EVENT = "mm-offline/worker-started";

function wireWorkerEvents(): void {
  if (workerEventsWired || !isServiceWorkerSupported()) return;
  workerEventsWired = true;
  const container = window.navigator.serviceWorker;
  container.addEventListener("message", (event: MessageEvent) => {
    if ((event.data as { type?: unknown } | null)?.type === WORKER_STARTED_EVENT) {
      // A restarted worker has forgotten which profile this tab is on, and
      // until it is told again it can only answer this tab from the network.
      republishScope();
      return;
    }
    if (!isOfflineStateMessage(event.data)) return;
    applyWorkerState(event.data.state);
  });
  // The worker that takes over on `controllerchange` is a different worker
  // from the one this tab introduced itself to — a new build another tab chose
  // to activate, or a page loaded before any worker existed being claimed —
  // and the start announcement above cannot reach it: a new worker announces
  // itself while it is still installing, so the reply goes to the OLD worker,
  // the one `serviceWorker.ready` still names at that moment.
  container.addEventListener("controllerchange", republishScope);
  // Coming back to the front is the other moment, and the cheapest one. The
  // worker may have been stopped and restarted any number of times while this
  // tab was hidden; re-introducing the tab once, as it is looked at, costs one
  // message and closes whatever gap the two events above leave.
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") republishScope();
  });
}

/**
 * Say the scope again, if there is one to say. A tab that has not published
 * yet has nothing to repeat: sending null here would tell the worker "nobody"
 * for a profile that is still resolving.
 */
function republishScope(): void {
  if (scopePublished) void publishScope(publishedScope);
}

function applyWorkerState(state: OfflineWorkerState): void {
  const entries = Array.isArray(state.entries) ? state.entries : [];
  publish({
    ...state,
    entries,
    readiness: state.scopeToken === null ? "unscoped" : "ready",
  });
  for (const listener of heardListeners) listener();
  if (entries.length > 0) ensurePersistentStorage();
}

/**
 * Whether this page load has already asked. Once is enough here: Chrome
 * decides silently from site engagement and installation, neither of which a
 * tab switch changes, and Firefox asks the user, who should not be asked on
 * every tab switch. Every save asks again anyway.
 */
let persistenceRequested = false;

/**
 * The moment the page learns this profile has downloads is the moment they
 * are worth protecting. The request at save time covers the chapter being
 * saved; it does nothing for the ones already sitting in best-effort storage
 * because an earlier request was denied, or was never made.
 */
function ensurePersistentStorage(): void {
  if (persistenceRequested) return;
  persistenceRequested = true;
  void requestPersistentStorage();
}

/**
 * Round-trip a message to the worker. Resolves rather than rejects on failure:
 * every caller here is best-effort, and a worker that is asleep, gone or slow
 * must degrade to "offline saving is unavailable", never to a thrown error in
 * the reader.
 */
async function ask(message: Record<string, unknown>, timeoutMs = 15_000): Promise<OfflineReply> {
  if (!isServiceWorkerSupported()) return { ok: false, reason: "unsupported" };
  let registration: ServiceWorkerRegistration | undefined;
  try {
    registration = await window.navigator.serviceWorker.ready;
  } catch {
    return { ok: false, reason: "unavailable" };
  }
  const worker = registration.active;
  if (!worker) return { ok: false, reason: "unavailable" };

  return new Promise<OfflineReply>((resolve) => {
    const channel = new MessageChannel();
    const timer = window.setTimeout(() => {
      channel.port1.close();
      resolve({ ok: false, reason: "timeout" });
    }, timeoutMs);
    channel.port1.onmessage = (event: MessageEvent) => {
      window.clearTimeout(timer);
      channel.port1.close();
      resolve((event.data as OfflineReply) ?? { ok: false, reason: "empty" });
    };
    worker.postMessage(message, [channel.port2]);
  });
}

/**
 * The scope this tab last told the worker about. Remembered because only the
 * page knows it: a worker that restarts loses which profile each tab is on, and
 * has to be told the same thing again.
 */
let publishedScope: StorageScope | null = null;
let scopePublished = false;

/**
 * Tell the worker whose caches to use. Sent on mount and on every profile
 * switch, and said again whenever the tab has reason to think the worker does
 * not know (`wireWorkerEvents`); a null scope publishes "nobody", which makes
 * the worker stop serving saved content rather than fall back to the last
 * profile's.
 */
export async function publishScope(scope: StorageScope | null): Promise<void> {
  if (!shouldRegisterWorker()) return;
  publishedScope = scope;
  scopePublished = true;
  const reply = await ask({
    type: OFFLINE_MESSAGE.setScope,
    scope,
    apiBase: resolveApiBase(),
  });
  if (reply.ok && reply.state) {
    applyWorkerState(reply.state);
    return;
  }
  if (!reply.ok) publish({ ...EMPTY_STATE, readiness: "pending" });
}

export async function refreshOfflineState(): Promise<void> {
  const reply = await ask({ type: OFFLINE_MESSAGE.getState });
  if (reply.ok && reply.state) applyWorkerState(reply.state);
}

/**
 * Ask the browser to keep this origin's storage.
 *
 * Without it, saved chapters live in "best effort" storage the browser may
 * clear under pressure — precisely the bytes the user asked to keep. Chrome
 * grants it silently on an engaged/installed origin, Firefox prompts, and
 * Safari has no such API and treats an installed web app as persistent already,
 * so a `false` here is not an error, only an unmet request.
 */
export async function requestPersistentStorage(): Promise<boolean> {
  if (typeof window === "undefined" || !window.navigator.storage?.persist) return false;
  try {
    if (await window.navigator.storage.persisted()) return true;
    return await window.navigator.storage.persist();
  } catch {
    return false;
  }
}

export async function saveChapterOffline(request: SaveChapterRequest): Promise<OfflineReply> {
  void requestPersistentStorage();
  return ask({ type: OFFLINE_MESSAGE.saveChapter, payload: request });
}

export function cancelChapterSave(key: string): Promise<OfflineReply> {
  return ask({ type: OFFLINE_MESSAGE.cancelSave, key });
}

export function removeSavedChapter(scope: StorageScope, key: string): Promise<OfflineReply> {
  return ask({ type: OFFLINE_MESSAGE.removeChapter, scope, key });
}

export function markChapterOpened(scope: StorageScope, key: string): Promise<OfflineReply> {
  return ask({ type: OFFLINE_MESSAGE.markOpened, scope, key });
}

export function markChapterFinished(scope: StorageScope, key: string): Promise<OfflineReply> {
  return ask({ type: OFFLINE_MESSAGE.markFinished, scope, key });
}

export function markChapterClosed(key: string): Promise<OfflineReply> {
  return ask({ type: OFFLINE_MESSAGE.chapterClosed, key });
}

/** The launch/resume sweep: expiry first, then pressure eviction. */
export function sweepOffline(
  scope: StorageScope,
  protectKey: string | null,
): Promise<OfflineReply> {
  return ask({ type: OFFLINE_MESSAGE.sweep, scope, protectKey });
}

export function setOfflineRetention(
  scope: StorageScope,
  retentionMs: number | null,
): Promise<OfflineReply> {
  return ask({ type: OFFLINE_MESSAGE.setRetention, scope, retentionMs });
}

export function clearOfflineScope(scope: StorageScope): Promise<OfflineReply> {
  return ask({ type: OFFLINE_MESSAGE.clearScope, scope });
}

/**
 * The manual escape hatch. Unregisters the worker and drops every cache this
 * origin holds, so a caching bug can always be walked out of from inside the
 * app rather than from devtools.
 */
export async function resetServiceWorker(): Promise<void> {
  if (!isServiceWorkerSupported()) return;
  try {
    const registrations = await window.navigator.serviceWorker.getRegistrations();
    await Promise.all(registrations.map((registration) => registration.unregister()));
    const names = await window.caches.keys();
    await Promise.all(names.map((name) => window.caches.delete(name)));
  } finally {
    window.location.reload();
  }
}

/**
 * The worker this tab already asked to take over, so a second tap does not
 * arm a second reload. Per worker, not a flag: a flag set for a worker a newer
 * build later replaced would turn every tap on the newer one into a no-op.
 */
let updateRequestedFor: ServiceWorker | null = null;

/**
 * Activate a waiting worker, then reload once it takes over.
 *
 * The reload is armed only here: `controllerchange` also fires the first time a
 * worker claims a page, and reloading on that would bounce every visitor once
 * on their first visit for no reason. When another tab has already applied
 * the update that event is gone, so the reload happens now instead
 * (`decideWorkerUpdate`).
 */
export async function applyWorkerUpdate(waiting: ServiceWorker): Promise<void> {
  const action = decideWorkerUpdate(
    waiting.state,
    window.navigator.serviceWorker.controller === waiting,
  );
  if (action === "reload") {
    window.location.reload();
    return;
  }
  if (action === "stale" || updateRequestedFor === waiting) return;
  updateRequestedFor = waiting;
  window.navigator.serviceWorker.addEventListener(
    "controllerchange",
    () => {
      window.location.reload();
    },
    { once: true },
  );
  waiting.postMessage({ type: OFFLINE_MESSAGE.skipWaiting });
}
