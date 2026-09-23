"use client";

import { useCallback, useEffect, useState } from "react";
import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { CommandPalette } from "@/components/command-palette";
import { ShortcutsDialog } from "@/components/keyboard";
import { mobileNav } from "@/config/nav";
import { HELP_SHORTCUT_KEYS, useShortcut } from "@/lib/keyboard";
import { ScrollContainerProvider } from "@/lib/scroll-container";
import {
  isImmersiveNovelPath,
  isImmersivePath,
  isImmersiveReaderPath,
} from "@/lib/reader-route";
import { cn } from "@/lib/cn";
import { useRouteFade } from "./use-route-fade";
import { useUiStore } from "@/stores/ui-store";
// Direct, not via the `@/features/preferences` barrel: that barrel also exports
// the settings panels, and the shell wraps every page.
import { useApplyReadingTheme } from "@/features/preferences/theme-store";
import { useApplyDesignPreset } from "@/features/preferences/preset-store";
import { isPublicAuthPath } from "@/features/auth/access";
import { useCurrentUser } from "@/features/auth/hooks";
import { AuthPending } from "@/features/auth/components/auth-pending";
import { isSessionUnresolved, resolveSessionGate } from "@/features/offline/session-gate";
import { FirstRunHint } from "@/features/library";
import { UpdateBanner } from "@/features/updates";
import {
  isPickerPath,
  moodShellBackground,
  PROFILE_PICKER_PATH,
  ProfileSwitcherChip,
  shouldRedirectToPicker,
  useActiveProfileStore,
  useProfiles,
} from "@/features/profiles";
import { isSelectionGone } from "@/features/profiles/selection";
import { Sidebar } from "./sidebar";
import { Topbar } from "./topbar";

/**
 * Top-level frame selector. Auth screens (login/register) render full-bleed and
 * without a session; every other route renders the authenticated app frame,
 * gated by the route guard in `AuthenticatedShell`.
 */
export function AppShell({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();

  // Above the auth branch on purpose: the site theme paints the login and
  // register screens too. Those screens get `honourBootTheme: false`, which
  // restores the DEFAULT palette there even if a boot-applied one was carried
  // in by a client-side redirect — without a session the scope never resolves,
  // so nothing else would ever clear it, and a login form wearing the last
  // profile's palette announces on a shared machine who was here.
  useApplyReadingTheme(!isPublicAuthPath(pathname));
  // The shape half of the same decision, on the same terms: applied live from
  // a token bundle, so changing it reflows the page in place rather than
  // asking anyone to restart or reload.
  useApplyDesignPreset(!isPublicAuthPath(pathname));

  if (isPublicAuthPath(pathname)) {
    return <>{children}</>;
  }

  return <AuthenticatedShell>{children}</AuthenticatedShell>;
}

/**
 * Drops the remembered profile once this account's own list shows it is gone —
 * deleted on another device (the phone), or never this account's at all.
 *
 * Nothing else on the web would notice: the server reads an id it does not
 * recognise as "no profile" without an error, so every list simply came back
 * empty until the first write answered 404. Clearing sends the gate above to
 * the picker. Only a list that loaded may clear it; see `isSelectionGone`.
 */
function StaleProfileCheck() {
  const activeId = useActiveProfileStore((s) => s.activeProfile?.id ?? null);
  const clearActiveProfile = useActiveProfileStore((s) => s.clearActiveProfile);
  const { data: profiles, isSuccess, isFetching } = useProfiles();
  const gone = isSelectionGone(activeId, { profiles, isSuccess, isFetching });

  useEffect(() => {
    if (gone) clearActiveProfile();
  }, [gone, clearActiveProfile]);

  return null;
}

/**
 * The persistent application frame: sidebar + topbar + scrollable content.
 * Owns app-global shortcuts that act on the shell itself, and guards every
 * route it wraps — an unauthenticated visitor is redirected to /login and only
 * a resolved, signed-in session renders the frame.
 */
function AuthenticatedShell({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  const router = useRouter();
  const { data: user, isLoading, error: sessionError } = useCurrentUser();
  const activeProfile = useActiveProfileStore((s) => s.activeProfile);
  const profilesHydrated = useActiveProfileStore((s) => s.hasHydrated);
  const toggleSidebar = useUiStore((s) => s.toggleSidebar);
  const closeMobileSidebar = useUiStore((s) => s.closeMobileSidebar);
  const setSidebarCollapsed = useUiStore((s) => s.setSidebarCollapsed);
  const shortcutsOpen = useUiStore((s) => s.shortcutsOpen);
  const toggleShortcuts = useUiStore((s) => s.toggleShortcuts);
  const closeShortcuts = useUiStore((s) => s.closeShortcuts);
  const [scrollContainer, setScrollContainer] = useState<HTMLElement | null>(null);

  // Both readers lose the app chrome; only the manga one gets the obsidian
  // page, because the novel reader paints its own reading palette and a
  // near-black shell under a Paper page would defeat the point of choosing it.
  const isMangaChapter = isImmersiveReaderPath(pathname);
  const isNovelChapter = isImmersiveNovelPath(pathname);
  const isReaderChapter = isImmersivePath(pathname);
  // Cross-fades <main> when the route under it changes. Reads the scroller out
  // of the state ScrollContainerProvider already keeps, so no second ref has to
  // be merged onto the element.
  useRouteFade(scrollContainer, pathname);

  const assignScrollContainer = useCallback((node: HTMLElement | null) => {
    setScrollContainer(node);
  }, []);

  useEffect(() => {
    const media = window.matchMedia("(max-width: 1023px)");
    const apply = () => {
      if (media.matches) {
        setSidebarCollapsed(true);
      }
    };
    apply();
    media.addEventListener("change", apply);
    return () => media.removeEventListener("change", apply);
  }, [setSidebarCollapsed]);

  useEffect(() => {
    closeMobileSidebar();
  }, [pathname, closeMobileSidebar]);

  useShortcut({
    id: "shell.toggle-sidebar",
    keys: "mod+b",
    description: "Toggle the sidebar",
    group: "General",
    handler: useCallback(() => toggleSidebar(), [toggleSidebar]),
  });

  // App-wide, so "what can I press here?" has the same answer on every screen.
  // The reader used to own this binding and list only its own group; the sheet
  // now reads the whole live registry (see `ShortcutsDialog`).
  useShortcut({
    id: "shell.shortcuts",
    keys: HELP_SHORTCUT_KEYS,
    description: "Show keyboard shortcuts",
    group: "General",
    handler: useCallback(() => toggleShortcuts(), [toggleShortcuts]),
  });

  // Route guard: once the /auth/me probe settles, send unauthenticated visitors
  // to /login. `useCurrentUser` reports 401 as `null` (not an error), so a
  // missing session is `!user` here.
  //
  // A probe that never REACHED the server is a different thing and must not
  // redirect: offline, /login is just as unreachable as the page being left,
  // so the reader would be bounced away from chapters already saved on the
  // device. See `features/offline/session-gate.ts`.
  const sessionGate = resolveSessionGate({
    isLoading,
    hasUser: Boolean(user),
    error: sessionError,
  });

  useEffect(() => {
    if (sessionGate === "redirect") {
      router.replace("/login");
    }
  }, [sessionGate, router]);

  // Profile gate: a signed-in visitor who hasn't chosen a reading profile is
  // routed to the picker. This runs AFTER auth (never instead of the remembered
  // login) and waits for the persisted selection to hydrate, so a reload never
  // bounces to the picker before the last choice is restored.
  useEffect(() => {
    if (isSessionUnresolved(sessionGate)) return;
    if (
      shouldRedirectToPicker({
        authenticated: true,
        hydrated: profilesHydrated,
        hasActiveProfile: Boolean(activeProfile),
        pathname,
      })
    ) {
      router.replace(PROFILE_PICKER_PATH);
    }
  }, [sessionGate, profilesHydrated, activeProfile, pathname, router]);

  // Resolving the session, or redirecting an unauthenticated visitor. An
  // unanswered probe is neither: the app renders on what this device already
  // has, and the guard above takes over the moment the server can be reached.
  if (isSessionUnresolved(sessionGate)) {
    return <AuthPending />;
  }

  // The picker renders full-bleed (no sidebar/topbar) and owns its own
  // background — it is the profile hand-off screen, not an in-app page.
  if (isPickerPath(pathname)) {
    return <div className="h-dvh w-full overflow-hidden">{children}</div>;
  }

  // Tint the whole shell with the active profile's mood (muted, dark). The
  // reader keeps its obsidian background via the `bg-obsidian` override below.
  const shellBackground = moodShellBackground(activeProfile?.mood ?? "default");

  return (
    <div
      className="flex h-dvh w-full overflow-hidden bg-bg transition-[background] duration-500"
      style={{ background: shellBackground }}
    >
      {/* First tab stop on every page. `focus:` rather than `focus-visible:`
          so it also appears for a pointer-driven focus, and z-60 so it is not
          covered by the topbar or the update banner. */}
      <a
        href="#main-content"
        className="sr-only focus:not-sr-only focus:absolute focus:left-4 focus:top-4 focus:z-[70] focus:rounded-lg focus:bg-primary focus:px-4 focus:py-2 focus:font-medium focus:text-primary-fg focus:shadow-glow"
      >
        Skip to content
      </a>

      {/* A phone held sideways is 812x375: wide enough for `md:` to unhide the
          desktop rail, short enough that the rail plus the reader's own control
          bar leave a letterbox to read in. Height is what separates that case
          from a genuine desktop window, so the reader — and only the reader —
          drops the rail below 500px of viewport. `!hidden` because the base
          class already resolves to `md:flex` at this width. */}
      <Sidebar className={isReaderChapter ? "[@media(max-height:500px)]:!hidden" : undefined} />
      <StaleProfileCheck />

      <div className="relative flex min-w-0 flex-1 flex-col">
        {/* The novel reader paints its own page, and that page can be cream.
            The app's dark bar sitting across the top of it reads as a second
            header and as a hole punched in the book — the same reason the
            reader's type panel borrows the reading palette instead of the
            app's chrome. The running head carries the back arrow, the progress
            and the settings, so nothing is lost with it gone.

            The manga reader keeps the bar exactly as it has always had it: its
            page is obsidian, so the chrome above it agrees with it. */}
        {isNovelChapter ? null : <Topbar hideOnReader={isMangaChapter} />}
        {/* Quick profile hand-off, anchored in the topbar band. Hidden on the
            reader (its topbar is hidden) and on narrow screens where the bar is
            crowded — switching is also available under Settings → Profiles. */}
        {!isReaderChapter ? (
          <ProfileSwitcherChip className="absolute left-1/2 top-2.5 z-40 hidden -translate-x-1/2 lg:flex" />
        ) : null}
        {/* Renders nothing once anything is followed, or on a route where it
            would be redundant (see `shouldShowFirstRunHint`). */}
        {!isReaderChapter ? <FirstRunHint /> : null}
        <ScrollContainerProvider container={scrollContainer}>
          <main
            id="main-content"
            ref={assignScrollContainer}
            tabIndex={-1}
            className={cn(
              // `overscroll-y-contain`: this is the app's only scroller, and on
              // iOS Safari a flick past its end otherwise chains to the document
              // and fires the browser's own rubber-band / pull-to-refresh. In a
              // reader — where reaching the end of a chapter and flicking again
              // is the normal gesture — that reloads the page out from under
              // the reader. Contained here, the scroll simply stops.
              "flex-1 overflow-y-auto overscroll-y-contain outline-none",
              isMangaChapter && "bg-obsidian",
              // Clears the floating tab pill (56px tall + its 16px inset and
              // safe-area padding) so the last row of covers is never under it.
              !isReaderChapter && "max-md:pb-24",
            )}
          >
            {children}
          </main>
        </ScrollContainerProvider>

        {/* Mobile hybrid nav: glass bottom tab bar. Hidden on desktop (sidebar
            takes over) and inside the immersive reader. */}
        {!isReaderChapter ? <MobileBottomNav /> : null}
      </div>

      {/* Fixed to the layout root, outside the reader scroll container. */}
      <UpdateBanner />

      {/* Always mounted so its ⌘K binding is registered; renders nothing until
          opened. Inside the authenticated shell because half of what it offers
          (the library, the installed sources, sign out) needs a session. */}
      <CommandPalette />

      {/* Mounted at the shell root so it paints above page chrome — including
          the reader's fixed controls — on every route. */}
      <ShortcutsDialog open={shortcutsOpen} onClose={closeShortcuts} />
    </div>
  );
}

function isTabActive(pathname: string, href: string): boolean {
  if (href === "/") {
    return pathname === "/";
  }
  return pathname === href || pathname.startsWith(`${href}/`);
}

/**
 * Bottom tab bar for narrow viewports (`md:hidden`).
 *
 * A floating, rounded, frosted pill rather than a full-bleed bar — the same
 * shape as the Flutter client's `NavigationBar`: inset by 16px, 20px radius,
 * surface at 0.90 alpha, a border from the palette, and a shadow that is one
 * part black and one part primary. The active destination gets a wash of the
 * primary behind it and only the active label is shown, matching
 * `NavigationDestinationLabelBehavior.onlyShowSelected`.
 *
 * ### Why the frost is fill and not `backdrop-filter`
 *
 * This pill floats over `<main>`, which is the app's ONLY scroller, so a
 * `backdrop-filter` here makes the compositor re-sample and re-blur everything
 * behind it on every frame of every library and browse scroll — the one place
 * in the app where that cost is paid continuously rather than once. It is the
 * cost `presets.css` calls the single most expensive thing this interface does,
 * and the pill was paying it even under Matte and Editorial, the two presets
 * whose whole point is `--shape-panel-blur: 0`.
 *
 * It was also buying very little. A blur only erases detail finer than its
 * radius, and what moves behind this pill is a poster grid whose variation is
 * cover-sized — an order of magnitude coarser than 18px, so almost all of it
 * survived the blur. What actually hides the covers is the fill: at 0.85 alpha
 * 15% of the backdrop still reached the eye, and 0.90 cuts that to 10%. The
 * pill therefore hides what slides under it slightly BETTER than the blurred
 * version did, for the cost of compositing one solid colour.
 *
 * The two shadows stay. A shadow is painted from this element's own geometry
 * rather than sampled from the page behind it, so scrolling does not re-compute
 * it — the blur was the per-frame half of the glass, not the depth.
 *
 * `pb-[env(safe-area-inset-bottom)]` keeps it clear of the iOS home indicator
 * when the site is installed and running edge to edge.
 */
function MobileBottomNav() {
  const pathname = usePathname();

  return (
    <nav
      aria-label="Primary"
      className="pointer-events-none absolute inset-x-0 bottom-0 z-30 px-4 pb-[max(env(safe-area-inset-bottom),0.5rem)] md:hidden"
    >
      {/* The accent half of the drop shadow reads from the palette rather than
          a literal hex, so the bar keeps its lift in every theme instead of
          casting one theme's glow under a Nord or a Daylight. */}
      <div className="pointer-events-auto flex items-stretch gap-1 rounded-[20px] border border-border bg-surface/90 p-1.5 shadow-[0_6px_20px_rgba(0,0,0,0.43),0_4px_24px_color-mix(in_srgb,var(--mm-primary)_9%,transparent)]">
        {mobileNav.map((item) => {
          const active = isTabActive(pathname, item.href);
          const Icon = item.icon;
          return (
            <Link
              key={item.href}
              href={item.href}
              aria-current={active ? "page" : undefined}
              className={cn(
                // `min-h-11` = 44px, the smallest target a thumb hits reliably.
                // `py-2` alone gave a 38px tab, and five of them share a 375px
                // bar, so every one of them was under the line.
                "flex min-h-11 flex-1 flex-col items-center justify-center gap-0.5 rounded-2xl py-2 transition-colors",
                active ? "bg-primary/12 text-primary" : "text-muted hover:text-fg",
              )}
            >
              <Icon className="size-[22px] shrink-0" aria-hidden />
              {/* Only the active label renders, so five destinations fit a phone
                  without truncating. The inactive labels stay in the tree for
                  assistive tech. */}
              <span
                className={cn(
                  "max-w-full truncate text-[0.6875rem] font-semibold leading-none",
                  !active && "sr-only",
                )}
              >
                {item.label}
              </span>
            </Link>
          );
        })}
      </div>
    </nav>
  );
}
