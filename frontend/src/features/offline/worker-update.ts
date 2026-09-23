/**
 * What pressing "Reload" on the update prompt should do, given where the new
 * worker has got to by then.
 *
 * Pure so the decision can be tested without a service worker. Another tab, or
 * the installed app, sharing this registration may already have applied the
 * update: its skip-waiting activated the worker, the worker claimed every
 * client, and this tab's `controllerchange` came and went before anyone here
 * was listening for it. Waiting for that event again would wait forever, and
 * posting skip-waiting to a worker that is already active does nothing — which
 * is how the prompt used to sit there with a Reload button that did nothing.
 *
 * - `reload`: the new worker already controls this tab (or has finished
 *   activating), so a plain reload lands on the new bundle.
 * - `skip-waiting`: it is still waiting; ask it to take over and reload when
 *   it does.
 * - `stale`: a newer build replaced it; there is nothing to apply, and the
 *   newer worker is reported by its own install.
 */
export type WorkerUpdateAction = "reload" | "skip-waiting" | "stale";

export function decideWorkerUpdate(
  state: ServiceWorkerState,
  controlsThisPage: boolean,
): WorkerUpdateAction {
  if (state === "redundant") return "stale";
  if (controlsThisPage || state === "activated") return "reload";
  return "skip-waiting";
}
