"use client";

import { useState } from "react";
import { Bell, BellRing } from "lucide-react";
import { Button } from "@/components/ui/button";
import { ApiError } from "@/types/api";
import type { SeriesId } from "@/types/api";
import { cn } from "@/lib/cn";
import { followKey, useFollow, useFollowedIndex, useUnfollow } from "../hooks";

interface FollowButtonProps {
  /** The series to follow / unfollow. */
  series: SeriesId;
  /**
   * The follow-row id when already known (detail payloads carry it). When
   * omitted the button resolves follow state from the shared followed index.
   */
  followedId?: number | null;
  /** Icon-only rendering for dense surfaces such as a grid card. */
  compact?: boolean;
  className?: string;
}

/**
 * Follow / unfollow a `(source, series_key)` — the single library-membership
 * control (spec §3.4, merges `SeriesFollowButton` + `LibraryMembershipButton`).
 * Following a series adds it to the profile's library and enables update
 * checks; unfollowing removes the row (reading progress survives).
 *
 * Only a button that does not know its follow-row id subscribes to the followed
 * index. Every library card passes its id, and each of up to 200 cards used to
 * hold its own observer on the whole followed set anyway — re-rendering on each
 * of its fetches — for a lookup it never read.
 */
export function FollowButton(props: FollowButtonProps) {
  return props.followedId != null ? (
    <FollowToggle {...props} resolvedId={props.followedId} />
  ) : (
    <IndexedFollowButton {...props} />
  );
}

function IndexedFollowButton(props: FollowButtonProps) {
  const { index } = useFollowedIndex();
  return <FollowToggle {...props} resolvedId={index.get(followKey(props.series)) ?? null} />;
}

function FollowToggle({
  series,
  resolvedId,
  compact = false,
  className,
}: FollowButtonProps & { resolvedId: number | null }) {
  const follow = useFollow();
  const unfollow = useUnfollow();
  const [error, setError] = useState<string | null>(null);

  const isFollowed = resolvedId !== null;
  const busy = follow.isPending || unfollow.isPending;

  const toggle = async () => {
    setError(null);
    try {
      if (isFollowed && resolvedId !== null) {
        await unfollow.mutateAsync(resolvedId);
      } else {
        await follow.mutateAsync(series);
      }
    } catch (cause) {
      setError(
        cause instanceof ApiError ? cause.message : "Failed to update your library.",
      );
    }
  };

  const label = isFollowed ? "Unfollow" : "Follow";
  const Icon = isFollowed ? BellRing : Bell;

  if (compact) {
    return (
      <button
        type="button"
        onClick={(event) => {
          event.preventDefault();
          event.stopPropagation();
          void toggle();
        }}
        disabled={busy}
        aria-label={label}
        title={error ?? label}
        className={cn(
          // A solid fill rather than a frosted one: this sits on every library
          // card, and each `backdrop-blur` was its own render pass redrawn on
          // every scroll frame for a frost too small to see over a cover.
          "z-10 flex size-8 items-center justify-center rounded-full bg-black/60 transition-colors disabled:opacity-50",
          isFollowed ? "text-primary" : "text-white/70 hover:text-white",
          error && "text-danger",
          className,
        )}
      >
        <Icon className="size-4" aria-hidden />
      </button>
    );
  }

  return (
    <div className={cn("flex flex-col items-start gap-1", className)}>
      <Button
        variant={isFollowed ? "secondary" : "primary"}
        disabled={busy}
        onClick={() => void toggle()}
        aria-label={label}
        className={cn(
          "rounded-full",
          isFollowed && "bg-primary/20 text-primary hover:bg-primary/30",
        )}
      >
        <Icon className={cn("size-4", isFollowed && "fill-primary/20")} aria-hidden />
        {unfollow.isPending
          ? "Unfollowing…"
          : follow.isPending
            ? "Following…"
            : isFollowed
              ? "Following"
              : "Follow"}
      </Button>
      {error ? <p className="text-xs text-danger">{error}</p> : null}
    </div>
  );
}
