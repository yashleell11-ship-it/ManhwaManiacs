import type { Metadata, Viewport } from "next";
import { Syne, DM_Sans } from "next/font/google";
import { AppShell } from "@/components/layout/app-shell";
import { ServiceWorkerBoundary } from "@/features/offline";
// Direct, not via the `@/features/preferences` barrel: that barrel also exports
// the settings panels, and the root layout has no business pulling every client
// component in the feature into its module graph to emit one <script>.
import { AppearanceBootScript } from "@/features/preferences/appearance-boot";
import { Providers } from "./providers";
import "./globals.css";

const syne = Syne({
  subsets: ["latin"],
  weight: ["400", "500", "600", "700", "800"],
  variable: "--font-syne",
  display: "swap",
});

const dmSans = DM_Sans({
  subsets: ["latin"],
  weight: ["300", "400", "500", "600"],
  variable: "--font-dm-sans",
  display: "swap",
});

export const metadata: Metadata = {
  title: "ManhwaManiacs",
  description:
    "ManhwaManiacs — read and manage your manga, manhwa and novel library.",
  // `manifest.ts` in this directory generates /manifest.webmanifest; naming it
  // here is what makes the page installable.
  manifest: "/manifest.webmanifest",
  appleWebApp: {
    capable: true,
    title: "Manhwa",
    // iOS has no manifest support worth relying on: the home-screen icon and
    // the status-bar treatment come from these tags instead.
    statusBarStyle: "black-translucent",
  },
  icons: {
    icon: [{ url: "/icons/icon-192.png", sizes: "192x192", type: "image/png" }],
    apple: [{ url: "/icons/apple-touch-icon.png", sizes: "180x180" }],
  },
};

export const viewport: Viewport = {
  // The two canvases an unset preference can paint, in the same order and from
  // the same media query globals.css uses: GitHub Dark's `--mm-bg` in the bare
  // `:root` block, GitHub Light's in the `prefers-color-scheme: light` one. A
  // single dark value here would put a black PWA title bar above a white
  // sign-in page. `useApplyReadingTheme` rewrites the tag to the active
  // palette's background once the profile has resolved.
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#FFFFFF" },
    { media: "(prefers-color-scheme: dark)", color: "#0D1117" },
  ],
  // The reader runs edge to edge; without this an installed iOS window letterboxes.
  viewportFit: "cover",
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html
      lang="en"
      className={`${syne.variable} ${dmSans.variable} antialiased`}
      // `AppearanceBootScript` stamps `data-theme` and `data-preset` on this
      // element before React exists, so the hydrating tree finds attributes the
      // server markup did not contain. That is the whole design, not a bug to
      // be fixed by moving the appearance into the markup — the server cannot
      // know it. This silences the mismatch warning for this element only.
      suppressHydrationWarning
    >
      <head>
        {/*
          First thing in the document, before any stylesheet has painted: reads
          the active profile's stored palette and design preset and stamps
          `data-theme` and `data-preset` on <html>. Without it every cold load
          flashes Eclipse near-black before the chosen theme lands — invisible
          on the dark palettes, a full white-to-black blink on the paper ones —
          and reflows once the preset resolves. See `appearance-boot-source.ts`.
        */}
        <AppearanceBootScript />
      </head>
      <body>
        <Providers>
          {/*
            Registers the service worker and keeps it told which profile is
            looking. Inside Providers because it reads the storage scope that
            ProfileStorageBoundary publishes; a sibling of the shell because it
            renders only the update prompt and must survive every route change.
          */}
          <ServiceWorkerBoundary />
          <AppShell>{children}</AppShell>
        </Providers>
      </body>
    </html>
  );
}
