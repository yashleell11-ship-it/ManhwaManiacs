import type { MetadataRoute } from "next";

/**
 * Web app manifest — what makes the web client installable.
 *
 * This is the whole point of the PWA route: on iOS, on-device offline reading
 * is a 5-6 week native project gated by sideloading, a Podfile.lock only a
 * cloud Mac can regenerate, and no dependable background execution (see
 * docs/OFFLINE_READING.md). Installed from the browser there is no app store,
 * no certificate and no 7-day re-sign — the same reader, saved to the home
 * screen.
 *
 * `display: standalone` (not `fullscreen`) keeps the status bar: the reader is
 * used in bed and knowing the time and the battery level matters more than the
 * last 40px. The reader's own fullscreen toggle still exists for the strip.
 *
 * Icons reuse the shipping brand mark from
 * `mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png`,
 * downscaled — no new artwork. The same file is declared `maskable` because it
 * genuinely is: the white "M" occupies x 0.269-0.731, y 0.341-0.658 of the
 * canvas, so its furthest corner sits 0.28 of the canvas from the centre, well
 * inside the 0.4 safe-zone radius an adaptive mask can crop to, and the amber
 * gradient behind it is full-bleed so there is no transparent corner to expose.
 */
export default function manifest(): MetadataRoute.Manifest {
  return {
    name: "ManhwaManiacs",
    short_name: "Manhwa",
    // Novels are named explicitly because they are not a footnote here: they
    // are the most-read surface on this instance by a wide margin, and a
    // description that lists only comics tells a reader the app does not do
    // the thing they mostly use it for.
    description:
      "Read and manage your manga, manhwa and novel library — with chapters saved for offline reading.",
    // Landing on the library rather than "/" because an installed icon is
    // pressed to read. "/" is now a bare redirect here anyway, and naming the
    // destination directly saves the installed window a round trip on launch.
    start_url: "/library",
    scope: "/",
    display: "standalone",
    orientation: "portrait-primary",
    // Matches --color-bg in globals.css (GitHub Dark, the default palette). The
    // splash and the OS chrome have to be the same near-black as the app or the
    // launch flashes white.
    background_color: "#0D1117",
    theme_color: "#0D1117",
    categories: ["books", "entertainment"],
    icons: [
      {
        src: "/icons/icon-192.png",
        sizes: "192x192",
        type: "image/png",
        purpose: "any",
      },
      {
        src: "/icons/icon-512.png",
        sizes: "512x512",
        type: "image/png",
        purpose: "any",
      },
      {
        src: "/icons/icon-512.png",
        sizes: "512x512",
        type: "image/png",
        purpose: "maskable",
      },
    ],
  };
}
