"use client";

import { useEffect, useId, useLayoutEffect, useRef } from "react";
import { cn } from "@/lib/cn";
import { Button } from "@/components/ui/button";
import { openDialogFocus } from "./dialog-focus";

interface DialogProps {
  open: boolean;
  onClose: () => void;
  title: string;
  children: React.ReactNode;
  className?: string;
}

const FOCUSABLE =
  'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])';

export function Dialog({ open, onClose, title, children, className }: DialogProps) {
  const panelRef = useRef<HTMLDivElement>(null);
  // Per-instance: a fixed "dialog-title" id collides the moment two dialogs are
  // mounted at once (a confirm inside a sheet), and duplicate ids make
  // `aria-labelledby` point at whichever the browser found first.
  const titleId = useId();

  // Callers pass `onClose` inline, so it is a new function on every render.
  // Escape reads the latest one through this ref, which keeps it out of the
  // effect below — see `dialog-focus.ts` for what keying on it cost.
  const onCloseRef = useRef(onClose);
  useLayoutEffect(() => {
    onCloseRef.current = onClose;
  });

  // Once per open: take focus, trap Tab, and hand focus back on close or
  // unmount (a dialog closed by unmounting it runs this cleanup too).
  useEffect(() => {
    if (!open) return;

    const focus = openDialogFocus({
      previous: document.activeElement as HTMLElement | null,
      focusables: () =>
        Array.from(panelRef.current?.querySelectorAll<HTMLElement>(FOCUSABLE) ?? []),
      active: () => document.activeElement as HTMLElement | null,
      onEscape: () => onCloseRef.current(),
      schedule: (run) => requestAnimationFrame(run),
      cancel: (handle) => cancelAnimationFrame(handle),
    });

    const onKeyDown = (event: KeyboardEvent) => focus.onKeyDown(event);
    window.addEventListener("keydown", onKeyDown);
    return () => {
      window.removeEventListener("keydown", onKeyDown);
      focus.release();
    };
  }, [open]);

  if (!open) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center p-4">
      {/* Click-outside target only. Hidden from assistive tech and out of the
          tab order: announcing a full-screen "Close dialog" button before the
          dialog's own content is noise, and Escape plus the Close button below
          already give keyboard and screen-reader users the same way out.

          A denser scrim and no blur. The scrim covers the whole viewport, so
          a blur here re-sampled every pixel of the screen on each frame of the
          entrance animations and on every change underneath, and the panel's
          own glass blurred it a second time. At 85% the page behind is dimmed
          further than under the old 80% frosted scrim, so the dialog stands
          off it as clearly, and the panel keeps its one glass pass over only
          its own area, so the panel itself looks exactly as it did. */}
      <button
        type="button"
        aria-hidden
        tabIndex={-1}
        className="overlay-in absolute inset-0 bg-bg/85 transition-opacity"
        onClick={onClose}
      />
      <div
        ref={panelRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby={titleId}
        className={cn(
          // `max-h` + `overflow-y-auto` so a dialog taller than the viewport
          // (a long form, an on-screen keyboard eating half a short phone
          // screen) scrolls internally instead of clipping its Close button or
          // its bottom actions off-screen.
          "panel-in glass-panel relative z-10 flex max-h-[calc(100dvh-2rem)] w-full max-w-lg flex-col overflow-y-auto rounded-2xl border border-border/50 p-6 shadow-glass",
          className,
        )}
      >
        <div className="mb-4 flex items-start justify-between gap-4">
          <h2 id={titleId} className="text-lg font-semibold text-fg">
            {title}
          </h2>
          <Button
            variant="ghost"
            size="icon"
            onClick={onClose}
            aria-label="Close"
            // 44px tap target — every dialog on the app funnels its close
            // action through this one button, phone included.
            className="-mr-2 -mt-2 h-11 w-11 shrink-0"
          >
            ×
          </Button>
        </div>
        {children}
      </div>
    </div>
  );
}
