"use client";

import { useRef, useState } from "react";
import { cn } from "@/lib/cn";
import { parsePageInput, scrubPercent } from "../scrub";
import type { ReadingDirection } from "../types";

interface ScrubBarProps {
  page: number;
  pageCount: number;
  direction: ReadingDirection;
  onSeek: (page: number) => void;
  className?: string;
}

/**
 * Chapter position: a draggable rail plus a jump-to-page field.
 *
 * The rail is a real `<input type="range">` under a styled track. That buys
 * pointer drags, click-to-jump and touch for free, keeps it operable by
 * keyboard and screen reader, and — because the keyboard registry treats a
 * focused input as "typing" — stops the reader's own arrow keys from
 * double-stepping while the handle has focus.
 */
export function ScrubBar({
  page,
  pageCount,
  direction,
  onSeek,
  className,
}: ScrubBarProps) {
  const [draft, setDraft] = useState("");
  // While the handle is being dragged it shows where the user is pointing, not
  // where the reader has landed. The strip reports its page back from measured
  // scroll offsets, and letting that tug the handle mid-drag makes it stick.
  const [dragPage, setDragPage] = useState<number | null>(null);
  const rtl = direction === "rtl";
  const total = Math.max(1, pageCount);
  const current = Math.min(total, Math.max(1, dragPage ?? page));
  const percent = scrubPercent(current, total);

  const jumpInputRef = useRef<HTMLInputElement>(null);
  const submitJump = (event: React.FormEvent) => {
    event.preventDefault();
    const target = parsePageInput(draft, pageCount);
    if (target == null) return;
    setDraft("");
    onSeek(target);
    // Hand focus back to the page. A focused text box holds the reader's
    // controls on screen (chrome-autohide), so leaving it focused after the
    // jump kept the bar up for the rest of the chapter.
    jumpInputRef.current?.blur();
  };

  return (
    <div className={cn("flex items-center gap-3", className)}>
      {/* The range itself is transparent, so the focus ring has to live on the
          wrapper or keyboard users get no indication of where they are. */}
      <div className="relative flex h-6 min-w-0 flex-1 items-center rounded-full focus-within:ring-2 focus-within:ring-primary/50">
        <div className="h-1.5 w-full overflow-hidden rounded-full bg-white/10">
          <div
            className="h-full rounded-full bg-primary shadow-[0_0_10px_color-mix(in_srgb,var(--mm-primary)_45%,transparent)]"
            style={{ width: `${percent}%`, marginLeft: rtl ? "auto" : undefined }}
          />
        </div>
        <span
          aria-hidden
          className="pointer-events-none absolute top-1/2 size-3.5 rounded-full border border-primary/60 bg-primary shadow-glow"
          style={
            rtl
              ? { right: `${percent}%`, transform: "translate(50%, -50%)" }
              : { left: `${percent}%`, transform: "translate(-50%, -50%)" }
          }
        />
        <input
          type="range"
          min={1}
          max={total}
          step={1}
          value={current}
          dir={rtl ? "rtl" : "ltr"}
          disabled={pageCount <= 1}
          aria-label="Chapter position"
          aria-valuetext={`Page ${current} of ${total}`}
          onChange={(event) => {
            const next = Number(event.target.value);
            setDragPage(next);
            onSeek(next);
          }}
          onPointerUp={() => setDragPage(null)}
          onBlur={() => setDragPage(null)}
          onKeyUp={() => setDragPage(null)}
          onKeyDown={(event) => {
            if (event.key === "Escape") event.currentTarget.blur();
          }}
          className="absolute inset-0 m-0 h-full w-full cursor-pointer appearance-none bg-transparent opacity-0 disabled:cursor-default focus-visible:outline-none"
        />
      </div>

      <form onSubmit={submitJump} className="flex shrink-0 items-center gap-1.5">
        <label htmlFor="reader-jump-to-page" className="sr-only">
          Jump to page
        </label>
        <input
          ref={jumpInputRef}
          id="reader-jump-to-page"
          inputMode="numeric"
          autoComplete="off"
          value={draft}
          placeholder={String(current)}
          onChange={(event) => setDraft(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Escape") {
              setDraft("");
              event.currentTarget.blur();
            }
          }}
          className={cn(
            "h-8 w-14 rounded-lg border border-border/60 bg-white/[0.04] px-2 text-center",
            "font-mono text-xs tabular-nums text-fg placeholder:text-muted/60",
            "focus-visible:border-primary/40 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40",
          )}
        />
        <span className="font-mono text-xs tabular-nums text-muted">/ {total}</span>
      </form>
    </div>
  );
}
