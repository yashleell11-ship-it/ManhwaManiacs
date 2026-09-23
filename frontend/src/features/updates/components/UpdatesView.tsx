"use client";

import Link from "next/link";
import { Bell, BellOff, ChevronRight, Search, TriangleAlert } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { EmptyState } from "@/components/ui/empty-state";
import { OfflineState } from "@/components/ui/offline-state";
import { HeroHeading } from "@/components/premium/HeroHeading";
import { PrimaryPillButton } from "@/components/premium/PrimaryPillButton";
import { useFollowedIndex } from "@/features/library/hooks";
import { useContentModeFilter } from "@/features/content-mode";
// Direct rather than through the `@/features/novels` barrel, which also pulls
// in the novel reader — this screen only links into it, it never renders it.
import {
  useChapterHref,
  useChapterLinksReady,
  type ChapterHref,
} from "@/features/novels/use-chapter-href";
import { formatUtcDateTime } from "@/lib/utc-time";
import { apiErrorMessage, resolveViewState } from "@/lib/view-state";
import { ApiError } from "@/types/api";
import { markAllReadLabel, markAllReadRequest } from "../mark-all";
import { notificationChapterRef } from "../notification-link";
import {
  useManualCheck,
  useMarkAllNotificationsRead,
  useMarkNotificationRead,
  useUpdateNotifications,
  useUpdateRuns,
  useUpdateSettings,
} from "../hooks";
import type { UpdateNotification } from "../types";
import { useCurrentUser } from "@/features/auth/hooks";

/**
 * Notification `created_at` and run `started_at` are UTC serialised from a
 * naive datetime, so they go through `formatUtcDateTime` — a bare `new Date`
 * dated every notification 5.5h early in IST.
 */
function formatWhen(value: string | null): string {
  return formatUtcDateTime(value);
}

function NotificationRow({
  item,
  seriesTitle,
  onRead,
  busy,
  chapterHref,
}: {
  item: UpdateNotification;
  seriesTitle: string | undefined;
  onRead: (id: number) => void;
  busy: boolean;
  chapterHref: ChapterHref;
}) {
  const readerHref = chapterHref(notificationChapterRef(item));
  return (
    <div
      className={`rounded-xl border border-border/40 bg-white/[0.02] p-3 transition-colors hover:border-primary/30 ${
        item.is_read ? "opacity-70" : ""
      }`}
    >
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="font-medium">
            {seriesTitle ?? item.series_key}
            <span className="text-muted"> · {item.chapter_title}</span>
          </p>
          <p className="text-sm text-muted">
            {item.source_id} · {formatWhen(item.created_at)}
          </p>
        </div>
        <div className="flex gap-2">
          <Link
            href={readerHref}
            className="inline-flex h-8 items-center rounded-lg bg-surface-2 px-3 text-sm font-medium text-fg hover:bg-border"
          >
            Read
          </Link>
          {!item.is_read ? (
            <Button
              size="sm"
              variant="ghost"
              disabled={busy}
              onClick={() => onRead(item.id)}
            >
              Mark read
            </Button>
          ) : null}
        </div>
      </div>
    </div>
  );
}

export function UpdatesView() {
  const settings = useUpdateSettings();
  const notifications = useUpdateNotifications();
  // "Recent checks" is the instance-wide run log, which the API answers for
  // admins only. A member sees the rest of the page and never asks for it.
  const { data: currentUser } = useCurrentUser();
  const isAdmin = currentUser?.is_admin ?? false;
  const runs = useUpdateRuns(isAdmin);
  const manualCheck = useManualCheck();
  const markRead = useMarkNotificationRead();
  const markAllRead = useMarkAllNotificationsRead();
  const { titles } = useFollowedIndex();
  const { filterRows, ready: modeReady, mode, novelsEnabled } = useContentModeFilter();
  // This list keeps novel rows in Novels mode, so it needs the same "which
  // reader?" answer — and the same wait for it — that Statistics, Bookmarks,
  // History and the series page already take. Satisfied immediately on a
  // manga-only deployment.
  const chapterHref = useChapterHref();
  const linksReady = useChapterLinksReady();

  const busy = manualCheck.isPending || markRead.isPending || markAllRead.isPending;
  // Notifications gets its own dedicated empty/error/offline treatment below;
  // keeping it out of this merged banner avoids saying the same failure twice.
  const error = settings.error ?? (isAdmin ? runs.error : null);
  // Scoped to the active content mode; a no-op when novels are disabled. The
  // unread BADGE is a separate server count and stays whole-account — it is
  // "you have unread updates", not "in this mode".
  const rows = filterRows(notifications.data, (row) => row.source_id);
  const notificationsViewState = resolveViewState({
    isLoading: notifications.isLoading || !modeReady || !linksReady,
    error: notifications.error,
    isEmpty: rows.length === 0,
  });

  return (
    <div className="page-shell">
      <div className="page-container mx-auto max-w-4xl space-y-6">
        <div className="flex flex-wrap items-end justify-between gap-4">
          <div>
            <HeroHeading className="leading-none md:text-6xl">Updates</HeroHeading>
            <p className="mt-2 text-sm text-muted">
              New chapters found for the series you follow.
            </p>
          </div>
          <PrimaryPillButton
            disabled={busy}
            onClick={() => manualCheck.mutate({})}
            icon={<Search className="size-4" aria-hidden />}
          >
            Check now
          </PrimaryPillButton>
        </div>

        {error instanceof ApiError ? (
          <div className="rounded-lg border border-danger/30 bg-danger/10 px-4 py-3 text-sm text-danger">
            {error.message ?? "Failed to load updates"}
          </div>
        ) : null}

        <Link
          href="/settings"
          className="group block focus-visible:outline-none"
          aria-label="Open update and notification settings"
        >
          <Card className="transition-colors group-hover:border-primary/40 group-focus-visible:border-primary/60">
            <CardContent className="flex flex-wrap items-center justify-between gap-3 p-4">
              <div className="flex min-w-0 items-center gap-3">
                <span className="flex size-10 shrink-0 items-center justify-center rounded-xl bg-primary/15 text-primary">
                  <Bell className="size-5" aria-hidden />
                </span>
                <div className="min-w-0">
                  <p className="font-medium text-fg">
                    Update &amp; notification settings
                  </p>
                  <p className="mt-0.5 text-sm text-muted">
                    {settings.data
                      ? `${settings.data.enabled ? "Checking" : "Not checking"} every ${settings.data.check_interval_minutes} min · notifications ${settings.data.notify_enabled ? "on" : "off"} · last check ${formatWhen(settings.data.last_run_at)}`
                      : "Configure checks and notifications in Settings."}
                  </p>
                </div>
              </div>
              <ChevronRight
                className="size-5 shrink-0 text-muted transition-transform group-hover:translate-x-0.5 group-hover:text-primary"
                aria-hidden
              />
            </CardContent>
          </Card>
        </Link>

        <Card>
          <CardHeader className="flex flex-row items-center justify-between">
            <CardTitle>Notifications</CardTitle>
            <Button
              size="sm"
              variant="secondary"
              disabled={busy || rows.every((n) => n.is_read)}
              // Clears the mode this list shows, not the whole account: the
              // other mode's chapters were never on screen to be "read".
              onClick={() => markAllRead.mutate(markAllReadRequest(novelsEnabled, mode))}
            >
              {markAllReadLabel(novelsEnabled, mode)}
            </Button>
          </CardHeader>
          <CardContent className="space-y-3">
            {notificationsViewState === "loading" ? (
              <div className="space-y-3" aria-busy="true">
                {Array.from({ length: 3 }).map((_, index) => (
                  <div
                    key={index}
                    className="h-16 animate-pulse rounded-lg bg-surface-2"
                  />
                ))}
              </div>
            ) : notificationsViewState === "offline" ? (
              <OfflineState
                reason="Updates need a connection to check."
                onRetry={() => void notifications.refetch()}
              />
            ) : notificationsViewState === "error" ? (
              <EmptyState
                tone="error"
                icon={TriangleAlert}
                title="Couldn't load notifications"
                description={apiErrorMessage(notifications.error, "Something went wrong.")}
                action={{ label: "Try again", onClick: () => void notifications.refetch() }}
              />
            ) : notificationsViewState === "empty" ? (
              <EmptyState
                icon={BellOff}
                title="No new chapters yet"
                description="Follow a series and this fills in the moment a new chapter is found."
                action={{ label: "Browse Sources", href: "/sources" }}
              />
            ) : (
              rows.map((item) => (
                <NotificationRow
                  key={item.id}
                  item={item}
                  seriesTitle={titles.get(`${item.source_id}:${item.series_key}`)}
                  busy={busy}
                  onRead={(id) => markRead.mutate(id)}
                  chapterHref={chapterHref}
                />
              ))
            )}
          </CardContent>
        </Card>

        {isAdmin ? (
        <Card>
          <CardHeader>
            <CardTitle>Recent checks</CardTitle>
          </CardHeader>
          <CardContent className="space-y-2">
            {runs.isLoading ? (
              <div className="space-y-2" aria-busy="true">
                {Array.from({ length: 3 }).map((_, index) => (
                  <div
                    key={index}
                    className="h-5 animate-pulse rounded bg-surface-2"
                  />
                ))}
              </div>
            ) : (runs.data ?? []).length === 0 ? (
              <p className="text-sm text-muted">No check runs yet.</p>
            ) : (
              (runs.data ?? []).map((run) => (
                <div
                  key={run.id}
                  className="flex flex-wrap justify-between gap-2 text-sm"
                >
                  <span>
                    {run.trigger} · {run.status} · {run.series_checked} series ·{" "}
                    {run.new_chapters_found} new
                  </span>
                  <span className="text-muted">{formatWhen(run.started_at)}</span>
                </div>
              ))
            )}
          </CardContent>
        </Card>
        ) : null}
      </div>
    </div>
  );
}
