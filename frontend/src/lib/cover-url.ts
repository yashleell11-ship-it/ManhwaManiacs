/**
 * The client half of the cover proxy's `?w=` contract.
 *
 * The backend renders a cover at a requested width and SNAPS that width onto
 * its own closed ladder (`backend/services/image_resize.py`), reporting what it
 * actually served in `X-Cover-Width`. That ladder is deliberately NOT mirrored
 * here: a second copy of it in the client is a second source of truth that
 * drifts the first time a rung moves, and the whole reason the server snaps is
 * so a client may ask for any width at all. So the only thing decided here is
 * how many DEVICE pixels a cover box is — the CSS width of the box times the
 * device pixel ratio — and the server decides what to render.
 *
 * WHY THIS MATTERS. Without a width the proxy streams the source's original:
 * measured on MangaDex, 1.64 MB average into a 153x230 CSS px slot, ~34 MB for
 * one 24-cover browse page. Wired up, the same page is ~1 MB.
 *
 * ### The box comes from the `sizes` hint
 *
 * Every cover already declares its box to `next/image` as a `sizes` string, and
 * that string is the one place the responsive width of the box is written down.
 * Rather than add a second per-call-site constant beside it — which would be
 * wrong the moment a grid gains a column — the same string is handed to the URL
 * builder and evaluated against the real viewport. Call sites therefore pass a
 * display width, never a rendered width: `sizes` in, `?w=` out.
 *
 * `next/image` cannot do this itself. Its optimizer fetches without cookies and
 * the cover route requires `mm_session`, so every cover renders `unoptimized`
 * and no `srcset` is generated — see the note in `next.config.ts`.
 */

import { imagePixelRatio } from "./device-pixels";

/**
 * The viewport assumed when there is no `window`, alongside the shared pixel
 * ratio in `device-pixels.ts` and for the same reason: these builders have to
 * stay pure functions under Node, and no cover is ever server-rendered.
 */
const SSR_VIEWPORT_WIDTH = 1280;

/**
 * The route's own declared range for `w` is 1..10000, and a value outside it is
 * a 422 — a broken cover rather than a heavy one. This is that range, NOT the
 * snap ladder: anything past the largest rung is snapped down server-side, so
 * clamping here only keeps an absurd hint on a 4K panel from failing outright.
 */
const MAX_REQUEST_WIDTH = 10000;

/** The proxy route every resizable cover ends with: `/sources/{s}/series/{k}/cover`. */
const COVER_PROXY_SUFFIX = "/cover";

/**
 * One `sizes` entry: an optional `(max-width: Npx)` / `(min-width: Npx)`
 * condition followed by a length. Lengths are `Npx`, `Nvw`, or the
 * `calc(Nvw - Mpx)` form a grid cell needs — a column of a `grid-cols-2 gap-4`
 * inside `p-6` padding is exactly `calc(50vw - 32px)` and nothing else.
 */
const SIZES_ENTRY =
  /^(?:\(\s*(min|max)-width\s*:\s*(\d+(?:\.\d+)?)px\s*\)\s+)?(?:calc\(\s*(\d+(?:\.\d+)?)vw\s*([+-])\s*(\d+(?:\.\d+)?)px\s*\)|(\d+(?:\.\d+)?)(px|vw))$/;

function viewportWidth(): number {
  if (typeof window === "undefined") {
    return SSR_VIEWPORT_WIDTH;
  }
  const width = window.innerWidth;
  return Number.isFinite(width) && width > 0 ? width : SSR_VIEWPORT_WIDTH;
}

/**
 * The CSS width a `sizes` hint resolves to at `viewport`, or null when the hint
 * uses syntax this does not model.
 *
 * Null is the safe answer, not a guess: an unrecognised hint means the caller
 * gets the original cover — heavy, but correct — where a guessed width would
 * mean a permanently blurry box that nothing reports.
 */
export function coverCssWidth(
  sizes: string,
  viewport: number = viewportWidth(),
): number | null {
  for (const raw of sizes.split(",")) {
    const match = SIZES_ENTRY.exec(raw.trim());
    if (!match) {
      return null;
    }
    const bound: string | undefined = match[1];
    if (bound) {
      const edge = Number(match[2]);
      if (bound === "max" ? viewport > edge : viewport < edge) {
        continue;
      }
    }
    const calcVw: string | undefined = match[3];
    if (calcVw) {
      const offset = Number(match[5]);
      return (viewport * Number(calcVw)) / 100 + (match[4] === "-" ? -offset : offset);
    }
    const value = Number(match[6]);
    return match[7] === "vw" ? (viewport * value) / 100 : value;
  }
  return null;
}

/** Device pixels to ask the proxy for, or null when the hint is unusable. */
export function coverRequestWidth(sizes: string): number | null {
  const cssWidth = coverCssWidth(sizes);
  if (cssWidth === null || !(cssWidth > 0)) {
    return null;
  }
  const width = Math.round(cssWidth * imagePixelRatio());
  return Math.min(Math.max(width, 1), MAX_REQUEST_WIDTH);
}

/**
 * Whether `url` addresses the cover proxy, and so understands `?w=`.
 *
 * A cover URL is not always ours: `libraryCoverUrl` and `sourceImageUrl` pass
 * absolute source URLs straight through, and appending a query to a third
 * party's CDN URL ranges from useless to breaking a signed link. The route's
 * own `/cover` suffix is the test, which works the same whether the proxy path
 * was resolved against a same-origin `/api` base or an absolute one.
 */
function isCoverProxyUrl(url: string): boolean {
  return url.split(/[?#]/, 1)[0].endsWith(COVER_PROXY_SUFFIX);
}

/**
 * Add the width a `sizes` hint implies to a cover proxy URL.
 *
 * Returns `url` untouched for anything that is not ours to resize, for a
 * missing hint, and for a hint that did not parse — every fallback lands on
 * "serve the original", which is what the product did before this existed.
 */
export function withCoverWidth(url: string, sizes?: string | null): string {
  if (!sizes || !isCoverProxyUrl(url)) {
    return url;
  }
  const width = coverRequestWidth(sizes);
  if (width === null) {
    return url;
  }
  return `${url}${url.includes("?") ? "&" : "?"}w=${width}`;
}
