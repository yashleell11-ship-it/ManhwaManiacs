"""App distribution (Android APK, iOS .ipa) + the install page served at ``/``.

Serves whatever the latest ``flutter build apk --release`` produced, the .ipa CI
published, the SideStore source feed that keeps iPhones updated, and the one
page that tells a person which of those they want.

Nothing about a build is written down here. The APK path is fixed by the Flutter
toolchain and overwritten on every build, so pointing at that single file always
serves the newest APK; sizes and dates come off those files' own stat; the
version is parsed live from the Flutter ``pubspec.yaml``; the iOS numbers come
from the metadata CI wrote beside the binary. Shipping a build is therefore the
whole update -- there is no page to edit afterwards, and no way for the page to
advertise a version that isn't the one behind the button.

The page itself is dependency-free by requirement, not by taste: CSS inlined, no
JavaScript, no external requests at all (not even a font CDN). It is served
straight off the backend behind a strict CSP, to people opening it on the phone
they are about to install onto.
"""

from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from html import escape
from pathlib import Path
from typing import NamedTuple

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import FileResponse
from pydantic import BaseModel

from core.config import REPO_ROOT

router = APIRouter(tags=["app"])

# Latest release APK. In the container this is a read-only bind mount populated
# by the deploy (see ops/deploy.sh + docker-compose.yml); ``MM_APK_PATH`` points
# at it. Locally it falls back to the Flutter build output, which Flutter
# overwrites each `flutter build apk --release`, so the path never needs editing.
APK_PATH: Path = Path(
    os.environ.get(
        "MM_APK_PATH",
        str(
            REPO_ROOT
            / "mobile"
            / "build"
            / "app"
            / "outputs"
            / "flutter-apk"
            / "app-release.apk"
        ),
    )
)
# Read live so bumping the app version needs no code change. Overridable via
# ``MM_PUBSPEC_PATH`` since the backend image doesn't ship the mobile project;
# the deploy mounts the pubspec at the default in-container location.
PUBSPEC_PATH: Path = Path(
    os.environ.get("MM_PUBSPEC_PATH", str(REPO_ROOT / "mobile" / "pubspec.yaml"))
)

# Curated marketing screenshots that ship with the mobile project. Served
# read-only under /app/media so the landing page can show the real app. Path is
# env-overridable (``MM_SCREENSHOTS_DIR``) because the backend image doesn't ship
# the mobile project — the deploy mounts the screenshots into the container.
SCREENSHOTS_DIR: Path = Path(
    os.environ.get(
        "MM_SCREENSHOTS_DIR", str(REPO_ROOT / "mobile" / "docs" / "screenshots")
    )
)
_ALLOWED_MEDIA_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp", ".gif"}

# Latest unsigned iOS build. Unlike the APK, this is *not* produced by the deploy
# — building iOS needs macOS, so it comes from the GitHub Actions runner (see
# .github/workflows/ios-build.yml) and is dropped into $DIR/ipa by
# ops/fetch-ios-build.sh. Mounted read-only into the container as /app/ipa.
IPA_PATH: Path = Path(
    os.environ.get(
        "MM_IPA_PATH",
        str(
            REPO_ROOT
            / "mobile"
            / "build"
            / "ios"
            / "iphoneos"
            / "ManhwaManiacs.ipa"
        ),
    )
)

# Version metadata for the published .ipa, written by CI beside the binary (see
# .github/workflows/ios-build.yml) and copied into place by ops/fetch-ios-build.sh.
IOS_META_ENV = "MM_IOS_META_PATH"
IOS_META_NAME = "ios-build.json"

# Absolute base URL used to build the download links inside the SideStore source
# manifest. Those links are fetched by the *phone*, not by this server, so they
# can't be relative and can't be an internal hostname. The deploy sets this to
# https://$APP_HOST; when unset we fall back to the request's own base URL, which
# is what makes the manifest work unchanged on a LAN.
PUBLIC_BASE_URL_ENV = "MM_PUBLIC_BASE_URL"

# Must match PRODUCT_BUNDLE_IDENTIFIER in mobile/ios/Runner.xcodeproj — SideStore
# keys installed apps by bundle id, so a mismatch shows up as a second app rather
# than an update to the existing one.
IOS_BUNDLE_ID = "com.manhwamaniacs.reader"
# Mirrors IPHONEOS_DEPLOYMENT_TARGET in the Xcode project.
IOS_MIN_VERSION = "13.0"

_DEFAULT_VERSION = "1.0.0"
_DEFAULT_BUILD = 1


class AppVersion(BaseModel):
    version: str
    build: int
    apk: str


class ChangelogEntry(BaseModel):
    version: str
    build: int
    date: str
    highlights: list[str]


class Changelog(BaseModel):
    entries: list[ChangelogEntry]


# Human-readable release notes, newest first. Surfaced on the landing page and
# available as JSON at /app/changelog so the mobile "What's new" screen can
# consume the exact same source of truth.
_RELEASE_NOTES: list[ChangelogEntry] = [
    ChangelogEntry(
        version="2.7.4",
        build=44,
        date="September 2026",
        highlights=[
            "The Library tab picks up where you left off. There is a row "
            "across the top now for whatever you are part-way through, and "
            "tapping it opens that chapter straight away. Getting back into a "
            "book used to mean opening the app, finding the cover, waiting for "
            "the series page and then hunting for the chapter — the website "
            "has had this as one tap the whole time",
            "An update notification finally opens the chapter it is telling "
            "you about. The card had nothing to tap, so the only way to reach "
            "a new chapter was to remember the series and go and find it "
            "yourself",
            "Notifications say which series, not which site. They used to "
            "print 'asurascans' where the name of the thing you follow "
            "belongs, even though the app already knew the title",
            "And the unread count clears itself when you actually read one. "
            "It only went down if you pressed a separate Mark read button, so "
            "the badge was counting chapters you had already finished — which "
            "is a badge you stop believing",
        ],
    ),
    ChangelogEntry(
        version="2.7.3",
        build=43,
        date="September 2026",
        highlights=[
            "Chapter dates now actually show up on the phone. Last release "
            "added them and the website got them; the phone showed nothing for "
            "most sources, because it threw the date away the moment it "
            "arrived unless it was written in one exact format. Manhwa18, "
            "MangaTown, FanFox and MangaFreak all write theirs differently, "
            "and all four came out blank",
            "A chapter posted late last night reads the same on both. The "
            "website counted hours and the phone counted days, so something "
            "put up at 11pm said 'Today' on one and 'Yesterday' on the other. "
            "Both now count days the way you do, in your own timezone rather "
            "than the server's",
            "Dates the server sends without a timezone are no longer read as "
            "local time. That quietly shifted every chapter by your offset, "
            "which is five and a half hours here and enough to land a chapter "
            "on the wrong day",
            "A source that writes its dates in its own words keeps them. If "
            "it says '18 Mar 2021', that is what both the phone and the "
            "website show, instead of one guessing at it and the other giving "
            "up and showing nothing",
        ],
    ),
    ChangelogEntry(
        version="2.7.2",
        build=42,
        date="September 2026",
        highlights=[
            "Every chapter now says when it went up. Recent ones read as an "
            "age, 'Today' or '3d ago', and older ones show the date. It was "
            "already being sent and simply never shown, so a series you follow "
            "gave you no way to tell this morning's chapter from one posted in "
            "2022",
            "MangaDex titles finally have genres. The tags were being looked "
            "for in the wrong place in the response, so every MangaDex series "
            "in the app showed none at all. They are there now",
            "And MangaDex adult titles are gated properly. It rates its own "
            "work, and that rating was being read to build the search and then "
            "thrown away, so an explicit title on that source reached a "
            "profile with the 18+ gate shut. Its own verdict is now believed",
            "The browse and cover caches ask about the series, not just the "
            "source. A page loaded by one profile was being reused for "
            "another, which both leaked adult titles to a shut gate and hid "
            "them from a profile that was allowed them until the cache "
            "expired",
        ],
    ),
    ChangelogEntry(
        version="2.7.1",
        build=41,
        date="September 2026",
        highlights=[
            "The phone can see and remove who signed up. Settings has a "
            "Members list for admins, showing every account with when it "
            "joined, when it was last seen and how many devices it is signed "
            "in on, plus a deactivate switch and a delete. Your own row is "
            "there but you cannot act on it. The website got this last "
            "release; now it is on the device you actually carry",
            "The website stopped snapping and started moving. Covers fade in "
            "as they load instead of forty of them popping in at forty "
            "different moments, grids deal their covers out in a short "
            "cascade instead of appearing in one frame, dialogs and the "
            "selection bar slide in, and the page cross-fades when you move "
            "between sections. The phone has worked this way for a long time; "
            "this is the website catching up",
            "None of that touches the reader. The reading strip measures each "
            "page to hold your place, so it deliberately keeps the plain, "
            "instant behaviour, and moving between chapters never dims the "
            "page you are reading",
            "All of it respects the motion setting. Every animation is scaled "
            "by the design preset you picked, so Cinema stays restrained, and "
            "turning on reduce motion in your phone or browser settings "
            "switches the whole lot off",
        ],
    ),
    ChangelogEntry(
        version="2.7.0",
        build=40,
        date="September 2026",
        highlights=[
            "Aurora Scans works again. Every chapter on it answered "
            "'Chapter not found', because the address the reader builds has "
            "the word chapters in it twice for that source and the server "
            "split it in the wrong place. BeeHentai and ComicLand were broken "
            "the same way and are fixed too",
            "Reading time is actually recorded. Every reading session ever "
            "stored had the same start and end time, because time spent on a "
            "page you had already reached was thrown away. Re-reading a "
            "chapter now counts, and a phone that resends its queue after a "
            "crash no longer counts the same minutes twice",
            "The 18+ gate covers six places it did not. Collections listed "
            "and counted hidden series, following one succeeded and left a "
            "row you could not see or remove, and an adult series listed on "
            "an ordinary source was never hidden at all because only the "
            "source was being checked, never the series",
            "Adult sources can be checked for updates again. The update "
            "sweep was asking the site-wide setting instead of yours, so a "
            "followed series on an adult source could never find a new "
            "chapter and simply looked dead",
            "You can see and remove who signed up. Settings has a Members "
            "list with a deactivate switch and a delete, and deactivating "
            "someone ends their session immediately rather than whenever "
            "their login happens to expire",
            "The phone showed every time in the wrong timezone. Reading "
            "history and updates were shifted by your offset, and because a "
            "bookmark's time decides which copy wins, the phone thought every "
            "bookmark on the server was older than it really was",
            "Saved chapters are safer. The phone could delete a downloaded "
            "chapter another profile had just saved, an app rollback left the "
            "download store permanently unopenable, and on the website a full "
            "browser could quietly throw away your saved chapters or stop "
            "remembering your place with no sign anything went wrong",
            "Restoring a backup can no longer destroy the only copy. The "
            "database being replaced is kept, a damaged file is refused "
            "instead of installed, and a backup from a newer version is set "
            "aside rather than left crash-looping the server",
            "The home screen and the notification list stopped re-sorting "
            "your whole history on every open, and the statistics screen "
            "stopped re-reading every session you have ever had",
        ],
    ),
    ChangelogEntry(
        version="2.6.2",
        build=39,
        date="September 2026",
        highlights=[
            "Read all no longer sends you back. Reading a browsed series as one "
            "scroll threw its window away every three chapters and started "
            "over from the chapter you opened, which is the jump backwards you "
            "kept getting. The fix the last release made to the library reader "
            "now covers the source reader too, and the window is kept for the "
            "whole read",
            "The website had its own version of the jump. The continuous "
            "reader kept re-applying the position it opened at every time a "
            "chapter was added or trimmed, because it was waiting for a "
            "fractional scroll offset the browser rounds and never reports "
            "back. It applies once now, a zoom step no longer re-applies it, "
            "and a chapter trimmed above you is measured at the height it "
            "actually stood at",
            "Fast flings no longer shove you back. When a page above the "
            "screen finished decoding mid-fling, the correction that keeps "
            "your place was overwritten by the very next frame of the fling, "
            "so a tall strip resolving above you moved the reader thousands "
            "of pixels backwards. The fling now continues from where you "
            "actually are",
            "Continue Reading no longer rewinds after you finish a chapter. "
            "Finishing the newest chapter used to make it fall back to the "
            "newest chapter you had not finished, which after a Read-all "
            "session is one you scrolled through two or three chapters ago. "
            "It now offers the chapter after the one you finished, on the "
            "phone, on the website and on the series page",
            "The reader no longer drops to its loading screen mid-read when "
            "something behind the chapter changes, and scrubbing right after "
            "the window slides lands in the chapter on screen rather than "
            "one ahead",
        ],
    ),
    ChangelogEntry(
        version="2.6.1",
        build=38,
        date="September 2026",
        highlights=[
            "The accent is the blue GitHub actually uses. The palette was "
            "mapping code-"
            "highlighting colours rather than interface ones, so the accent was "
            "a syntax purple, errors were orange and success was pale blue \u2014 "
            "all three now use the colours GitHub uses",
            "The phone follows the website: GitHub Dark is its default too. Any "
            "profile that already picked a theme keeps it",
            "The website follows the system light or dark setting again, with "
            "GitHub Light as the light side. A theme you have chosen still wins "
            "over the system",
        ],
    ),
    ChangelogEntry(
        version="2.6.0",
        build=37,
        date="September 2026",
        highlights=[
            "The website is dark by default, GitHub Dark rather than the amber "
            "look \u2014 including the sign-in page, which was gold no matter "
            "which theme you picked, because it painted before any theme had "
            "loaded",
            "Search stopped showing you the previous query. The offline cache "
            "was answering searches from its own store and fetching the real "
            "results for next time, so every search was one behind and a "
            "reload was the only way to catch up",
            "Search runs from a single letter, on every box \u2014 two of them "
            "only searched when you pressed enter",
            "The phone layout is quieter. The site was stacking eleven bands "
            "and twelve controls above the first cover; the app never shows "
            "more than one row of controls, and now neither does the website. "
            "The desktop is unchanged",
            "New pictures on the install page. The old ones were screenshots "
            "of the website rather than the app, and predated novels, the "
            "themes and the presets",
        ],
    ),
    ChangelogEntry(
        version="2.5.0",
        build=36,
        date="September 2026",
        highlights=[
            "Ninety-three sources, up from sixty-four. Twenty-nine new ones, "
            "most of them adult manhwa and manhua, every one checked from the "
            "server all the way through to a page image actually arriving",
            "Seven more were built and then deleted, because they listed "
            "series and could not open one. A source that only ever fails "
            "costs you a tap and a wait to find that out again",
            "Two adult sources were registered as general audience and would "
            "have shown up with the 18+ setting switched off. Both are behind "
            "the gate now",
        ],
    ),
    ChangelogEntry(
        version="2.4.2",
        build=35,
        date="September 2026",
        highlights=[
            "Read all stops sending you back. When the chapter you opened at "
            "re-resolved \u2014 the same chapter, a new object \u2014 the reader "
            "threw the whole run away and started again from where you first "
            "tapped, which after three chapters is three chapters back. The "
            "check meant to prevent that compared object identity, so it never "
            "once matched",
        ],
    ),
    ChangelogEntry(
        version="2.4.1",
        build=34,
        date="September 2026",
        highlights=[
            "Hold a cover on the Library tab to get the menu: open it, "
            "favourite it, or remove it from your library with an undo. The "
            "menu existed but only on the browse screen, not the tab you land "
            "on",
            "Choose how many chapters download at once, in Settings under "
            "Storage. It was strictly one at a time. The ceiling is set by "
            "what your own server can take rather than by how fast a phone "
            "can ask",
        ],
    ),
    ChangelogEntry(
        version="2.4.0",
        build=33,
        date="September 2026",
        highlights=[
            "Read all stops throwing you backwards. It holds three chapters "
            "and slides the window as you read; sliding backwards dropped a "
            "chapter above you without moving the scroll with it, so you lost "
            "your place by a whole chapter \u2014 and scrolling back to find it "
            "put you in range to be thrown again",
            "Read all stops resizing under the reading line on the web. "
            "Chapters were being measured before they had ever been on screen, "
            "and a cold guess for a long strip is five to ten times short, so "
            "every page corrected itself as you reached it",
            "Back works in the novel reader. The button did nothing and the "
            "Android gesture closed the app mid-book",
            "The screen stops staying awake after reading a novel. It was "
            "never being released, for the rest of the session",
            "Where you left off is one rule now. Finishing a chapter cleanly "
            "sent Continue back to chapter one, and the phone, the website and "
            "the home strip each answered the question differently",
            "Two privacy fixes: stored chapter transcripts could be uploaded "
            "and read by any signed-in account, and switching the 18+ setting "
            "off cleared four of the nine caches it filters, leaving mature "
            "series visible in the other five",
            "A page that fails to load says so, instead of leaving 2,600 "
            "pixels of nothing to scroll past",
            "Novels open in the novel reader from a notification, and are "
            "reachable from a phone browser",
            "Search runs once per word instead of once per keystroke, the "
            "notification badge polls once a minute instead of every fifteen "
            "seconds, and the home screen makes its three requests together",
        ],
    ),
    ChangelogEntry(
        version="2.3.0",
        build=32,
        date="September 2026",
        highlights=[
            "Downloads on the web, from the page you are already looking at. "
            "Every chapter row shows whether it is saved, you can tick several "
            "at once or use Next 10 and All unread, and a whole book saves in "
            "one action. Saving was previously possible only from inside the "
            "reader, one chapter at a time",
            "The downloads page can remove a whole series at once, because "
            "undoing a twenty-chapter save one bin icon at a time is not an "
            "undo",
            "Search on some sources returned the first page forever. Scrolling "
            "past it silently repeated the same results",
            "Sources that need a POST were being turned away by their own "
            "front door. A shared piece of the fetching code sent header names "
            "in lower case, which reads as a bot, and two sources had been "
            "working around it rather than it being fixed",
            "The design preset called Flat on the web is called Matte on the "
            "phone. It is one preset, so it now has one name",
            "The 18+ rule had grown five separate copies while it was being "
            "fixed. There is one of it now, and the tests that hold it "
            "reach every screen instead of one each",
        ],
    ),
    ChangelogEntry(
        version="2.2.0",
        build=31,
        date="September 2026",
        highlights=[
            "Your account has its own security settings, on the phone and the "
            "web: change your password, see every device signed in with when "
            "and where it was last used, sign one out, or sign out everywhere",
            "Mature series stay hidden when the 18+ setting is off. They were "
            "correctly hidden from browse and search, but still appeared in "
            "reading history, in stored progress and in new-chapter "
            "notifications",
            "Novels look like books on the phone. The Library shelved them "
            "with titles, authors and length instead of a grid of blank "
            "rectangles \u2014 and a novel opened from your library now opens "
            "in the novel reader rather than the page-by-page manga one",
            "Backup and restore came to the web. The phone could already "
            "export and import; a desktop could not",
            "The reader holds far fewer pages in memory. It used to warm the "
            "next eight pages whatever their size, which on the tallest "
            "sources meant over 400 MB of decoded image at once against a "
            "384 MB budget \u2014 so it threw pages away and re-read them "
            "constantly. It now spends a memory budget instead of counting "
            "pages, and warms further ahead on light sources",
            "The Manga/Novels switch reaches every screen it filters, instead "
            "of only two",
            "Reader tap zones can be retuned on the phone, which the web "
            "could already do \u2014 left, centre and right each get an action",
            "Downloading a whole series stopped opening one request per "
            "chapter. A 300-chapter book was 300 round trips",
            "Read all reached the library series page, collections can be "
            "renamed and have series taken out of them, and reading "
            "statistics follow the Manga/Novels mode the way every other "
            "screen already did",
        ],
    ),
    ChangelogEntry(
        version="2.1.0",
        build=30,
        date="September 2026",
        highlights=[
            "Android now runs at the full refresh rate the panel supports. "
            "The app had been inheriting the display default mode, which on "
            "nearly every "
            "90/120/144 Hz phone is 60 Hz \u2014 so it was drawing at half the "
            "rate the hardware offers. There is a setting if you want the "
            "battery back",
            "Covers load at the size they are actually drawn. A browse page "
            "went from 20.5 MB to 1.4 MB on a phone \u2014 measured against "
            "live images, not estimated",
            "Sixty-four sources, every one verified end to end from the server "
            "\u2014 not just that it lists series, but that a page image "
            "really downloads. Four that could not serve pages were removed "
            "rather than left to waste a tap",
            "MangaKatana went from 23 seconds to 4. Project Gutenberg took "
            "194 seconds to open its browse page and now takes under 3, "
            "because it reads Gutenberg's own catalogue instead of a mirror",
            "Everyone gets their own settings. Themes, design presets and "
            "reader defaults were reachable only by the owner's account, so "
            "anyone else who signed up was locked out of everything the last "
            "release added",
            "The web readers stop repainting on every scroll frame \u2014 prose "
            "no longer re-renders a whole chapter each percent you scroll, and "
            "the manga strip's page memoisation actually works now",
            "A privacy fix: stored chapter transcripts could be read across "
            "profiles and ignored the 18+ setting. They are now scoped to the "
            "profile that made them",
            "The install page at app.manhwamaniacs.xyz is a real page instead "
            "of raw JSON, and the app finally has its own icon on Android",
        ],
    ),
    ChangelogEntry(
        version="2.0.0",
        build=29,
        date="September 2026",
        highlights=[
            "Novels. The app reads books now, not just manhwa — six sources, a "
            "reader built for prose with indented paragraphs and a proper "
            "chapter opener, twelve page palettes from Paper to true black, "
            "and a whole book downloadable for offline reading",
            "Manga and novels stay apart. A switch at the top of the menu puts "
            "the app in one mode or the other, and every screen follows it",
            "Themes: fifteen on the phone, all contrast-checked, each profile "
            "remembering its own",
            "Design presets, separate from colour: Signature, Matte, Compact, "
            "Editorial and Cinema change spacing, surfaces, type and how much "
            "chrome the reader shows. They combine with any theme",
            "A downloaded chapter opens from the phone instead of waiting on "
            "the network, even when you have signal",
            "Download ten chapters at once, or a whole novel, with range "
            "shortcuts instead of tapping every row",
            "Chapters flow into each other — the end of one and the start of "
            "the next are a place in the same scroll, not a page change",
            "Read all: a whole series as one continuous scroll",
            "Statistics built from what you actually read — streaks, daily "
            "activity, time spent, and which sources you read most",
        ],
    ),
    ChangelogEntry(
        version="1.14.0",
        build=28,
        date="September 2026",
        highlights=[
            "15 themes. Settings -> General -> Theme: Nord, Dracula, Catppuccin "
            "(Mocha and Latte), Gruvbox, Tokyo Night, Rose Pine (and Dawn), "
            "Everforest, Solarized dark and light, true-black OLED, a warm "
            "Paper sepia, a clean Daylight - and Eclipse, the look the app "
            "has always had, still the default",
            "Every theme passes a real contrast check - text stays readable "
            "in all of them, not just the pretty screenshots",
            "Each profile remembers its own theme, and switching applies "
            "instantly with a cross-fade - no restart",
            "Reader pages stay on their dark backdrop in every theme, so a "
            "light theme never wraps your chapters in a white frame",
        ],
    ),
    ChangelogEntry(
        version="1.13.0",
        build=27,
        date="September 2026",
        highlights=[
            "Statistics is an actual statistics screen now: reading streaks, "
            "a 30-day activity chart, time spent, busiest hours, per-source "
            "breakdown and recent sessions — built from your real reading, "
            "which the app also only started recording properly today, so it "
            "fills in from here",
            "Late-night chapters count toward the right day. Days were being "
            "bucketed in server time, so reading at 11pm could land on "
            "tomorrow and quietly break a streak",
        ],
    ),
    ChangelogEntry(
        version="1.12.0",
        build=26,
        date="September 2026",
        highlights=[
            "Downloaded chapters open from the library again. The reader could "
            "always read them without a signal, but the series page in front of "
            "it answered a failed fetch with an error, so they were only "
            "reachable from the Downloads tab",
            "Offline, a series lists the chapters you actually have, clearly "
            "marked as the downloaded subset rather than passed off as the "
            "whole series",
            "A chapter row now says what its download is doing — waiting, "
            "downloading with progress, already saved, or failed and "
            "retryable. All four used to look like the same greyed-out button",
            "The reader's back button no longer hides under the Dynamic Island. "
            "Going fullscreen made iOS report no inset for the hidden status "
            "bar, while the cutout itself stayed exactly where it was",
        ],
    ),
    ChangelogEntry(
        version="1.11.0",
        build=25,
        date="September 2026",
        highlights=[
            "Downloads is its own tab now, with a badge when something is "
            "downloading — no more hunting for it under More",
            "You can watch a download happen: which chapter, which page, and "
            "how far through the series, with pause, resume, cancel and retry",
            "When the queue stops it tells you why — storage cap reached, disk "
            "nearly full, or the app was sent to the background (a sideloaded "
            "app cannot download while it is not on screen)",
            "Storage size, retention and Free up space now sit with the "
            "downloads instead of being buried in Settings, and saved series "
            "are listed largest first so it doubles as what is using my space",
            "Export a downloaded chapter as real files — a CBZ or a numbered "
            "folder of pages — into ManhwaManiacs/Exports, readable in the "
            "Files app. The store itself stays content-addressed, so exporting "
            "never disturbs what is downloaded",
        ],
    ),
    ChangelogEntry(
        version="1.10.0",
        build=24,
        date="September 2026",
        highlights=[
            "Search the words inside your downloaded chapters. The phone reads "
            "the text off each page itself, so a search finds a line of "
            "dialogue, not just a title",
            "Sources that had gone dark load again: 3hentai followed its images "
            "to a new host, baozimh reaches its reader, mangakatana labels its "
            "pages correctly, weebcentral finds its chapters, and the Madara "
            "family serves images again",
            "Four sources whose sites no longer exist were removed, so they "
            "stop appearing only to fail",
            "Adult-content filtering takes effect immediately instead of "
            "leaving already-loaded titles on screen",
            "Times and dates across the app are no longer hours off",
            "Opening a series is quicker — its chapter list had been firing "
            "dozens of redundant background requests",
        ],
    ),
    ChangelogEntry(
        version="1.9.0",
        build=23,
        date="September 2026",
        highlights=[
            "Downloads live on your phone now. Save a chapter or a whole "
            "series and it reads with no signal and no server — the thing the "
            "server-side download queue never actually gave you",
            "Choose how much space to give it: 2, 5, 10, 20 GB or unlimited, "
            "with a per-series breakdown and a one-tap Free up space",
            "Chapters you have finished clear themselves 48 hours later, so "
            "the shelf does not silently fill up. Pin anything you want kept, "
            "and re-opening a chapter cancels its expiry",
            "Downloaded chapters appear in the Files app under On My iPhone -> "
            "ManhwaManiacs, so you can browse or delete them yourself",
            "Where you left off now survives reading offline — progress queues "
            "on the device and lands on the server when you reconnect",
            "Browsing a source is instant the second time, and still works "
            "from cache when the source itself is down",
            "Aurora Scans search and Webtoons Canvas series load again",
        ],
    ),
    ChangelogEntry(
        version="1.8.1",
        build=22,
        date="September 2026",
        highlights=[
            "Chapters from Toonily and the dozen sources like it open again. "
            "Their chapter ids contain a slash, which the reader route was "
            "encoding wrongly — every one of them dead-ended on an error screen",
            "Covers and pages load on 18+-enabled profiles. Image requests were "
            "missing the profile header, so the listing showed a series whose "
            "artwork then 404'd",
            "Accounts: you can invite someone with a code instead of leaving "
            "registration open to anyone who finds the site",
            "Chapter titles read \"Chapter 1\" again, not \"Chapter 1.0\"",
            "The app now talks to the rebuilt server, which no longer stores a "
            "single chapter image — downloads are moving onto the phone itself",
        ],
    ),
    ChangelogEntry(
        version="1.8.0",
        build=22,
        date="July 2026",
        highlights=[
            "Reading history works. Nothing had ever recorded a reading "
            "session, so the screen was always empty — as were the statistics "
            "built from it",
            "OCR text and OCR search are now yours alone. Search used to look "
            "across every account's library",
            "A series downloaded from an 18+ source is now marked as such, so "
            "turning 18+ off actually hides it",
            "Several sources fixed, including Tapas and Bbato",
        ],
    ),
    ChangelogEntry(
        version="1.7.0",
        build=21,
        date="July 2026",
        highlights=[
            "The reader no longer throws you backwards mid-chapter. Pages were "
            "laid out on a guess and resized once the image loaded, shoving "
            "everything below them",
            "Drag the bar at the bottom of the reader to jump anywhere in a "
            "chapter",
            "The page counter is gone from the page itself — it lives in the "
            "bottom bar only",
            "Download confirmations no longer pop up over what you are reading",
            "New chapters do not download by themselves any more, and the "
            "download settings are in Settings where you can see them",
            "A downloaded series and a source series now look and work the "
            "same — same layout, same actions, same chapter list",
        ],
    ),
    ChangelogEntry(
        version="1.6.0",
        build=20,
        date="July 2026",
        highlights=[
            "Follow a series straight from its own page — downloading one used "
            "to leave you with no way to be told when the next chapter lands",
            "Reading a chapter? Tap the title to jump to that series and its "
            "full chapter list",
            "Nobody else can reach your series any more. Content is now checked "
            "against your account on every fetch, not just hidden from lists",
            "Fixed a hole where anyone signed in could rename any series",
            "Auto-downloaded chapters now arrive in your library instead of "
            "vanishing into nowhere",
            "Deleting a reading profile no longer strands the series only it "
            "had saved",
            "Website: a source whose name contains a slash now opens the series "
            "you actually clicked",
        ],
    ),
    ChangelogEntry(
        version="1.5.0",
        build=19,
        date="July 2026",
        highlights=[
            "Downloaded series now actually appear in your library — they were "
            "being filed where no profile could see them",
            "Imported CBZ files showed the wrong image for almost every page. "
            "Fixed, and every existing archive corrects itself on next open",
            "Search no longer reports a source's error text verbatim, which "
            "could carry another account's search terms",
            "Dead sources are now recorded and shown instead of silently "
            "returning nothing forever",
            "On the website: read offline. Install it as an app, save a "
            "chapter, and it opens with no connection at all",
            "The website reader gained keyboard shortcuts, page spreads, fit "
            "and zoom controls, and a scrubbable progress bar",
            "Your library on the web now has multi-select, filters that live in "
            "the URL, and a Continue Reading row",
            "Reading position, searches and reader settings no longer follow "
            "you between profiles on a shared browser",
        ],
    ),
    ChangelogEntry(
        version="1.4.0",
        build=18,
        date="July 2026",
        highlights=[
            "Your library is your own — every account, and every profile within "
            "an account, now has its own library, follows and reading progress. "
            "Nothing is shared unless you share it",
            "The 18+ switch actually works — turning it off now hides adult "
            "sources and adult series everywhere, and turning it back on brings "
            "them straight back. Nothing is ever deleted",
            "Search finds what you searched for — one source could previously "
            "flood the page with unrelated titles. Results are now grouped under "
            "each source, with the ones that matched shown first",
            "Sources rebuilt as a searchable list — pin your favourites, and "
            "your pins now follow your account instead of staying on one phone",
            "The Library tab is just the series you follow, and tapping one "
            "opens its full chapter list with the latest chapter up top",
            "The app opens when your server is unreachable instead of signing "
            "you out — though reading still needs the server for now",
            "When a source dies you can move a followed series to another one "
            "and keep your place",
        ],
    ),
    ChangelogEntry(
        version="1.3.2",
        build=17,
        date="July 2026",
        highlights=[
            "Search Everywhere — search now spans every source at once, not "
            "just your library",
            "Your profile picture is back on the Library tab — tap it to switch "
            "profiles",
            "Followed online series now show their real covers instead of a "
            "placeholder",
            "Settings no longer breaks when one section can't load — each part "
            "fails and retries on its own",
            "Turning on mature 18+ content now asks you to confirm",
        ],
    ),
    ChangelogEntry(
        version="1.3.1",
        build=16,
        date="July 2026",
        highlights=[
            "Polish & Privacy — a broad quality pass across the whole app",
            "Everything now stays per profile: reading position, recent searches "
            "and online reading progress no longer leak between profiles",
            "Mature 18+ toggle moved to the top of Settings so it's easy to find",
            "Reader keeps your exact spot on long chapters and no longer stalls "
            "auto-scroll after a chapter change",
            "'Continue' now opens the next unread chapter instead of reopening a "
            "finished one",
            "Faster, smoother search and a cleaner Updates screen with clearer "
            "error messages",
            "Updating from 1.2.x? Uninstall the old app first — the app's "
            "signature changed, so it installs as a separate app",
        ],
    ),
    ChangelogEntry(
        version="1.3.0",
        build=15,
        date="July 2026",
        highlights=[
            "Profiles are now truly separate — follows, reading history, "
            "progress, bookmarks and the 18+ setting are kept per profile",
            "Following a series now works and sticks",
            "New per-profile Mature 18+ toggle in Settings",
            "Fixed Settings crashing on some devices (fonts now ship with the app)",
            "Clearer update screen — shows your installed vs available build with "
            "install guidance",
            "More premium profile-selection animation",
        ],
    ),
    ChangelogEntry(
        version="1.3.0",
        build=14,
        date="July 2026",
        highlights=[
            "All-new Eclipse Warm look — a premium dark redesign across every "
            "screen",
            "Cinematic home with a magnetic continue-reading cover and a "
            "scrolling cover marquee",
            "Refreshed reader with a glass control bar and warm amber progress",
            "New Syne + DM Sans typography and warm amber accents throughout",
        ],
    ),
    ChangelogEntry(
        version="1.2.8",
        build=13,
        date="July 2026",
        highlights=[
            "Cleaner Sources grid — site logos with names only, no clutter",
            "Profile picker shows on every app open with full mood animation",
            "Library tab shows only followed series",
            "Reading history in Settings",
        ],
    ),
    ChangelogEntry(
        version="1.2.8",
        build=12,
        date="July 2026",
        highlights=[
            "Profile picker shows on every app open again (Netflix-style) with "
            "the full ~5 second mood animation",
            "Switch profile from More → Account when you want to change mid-session",
            "Netflix-style full-screen profile pick — mood floods the whole "
            "screen before entering the app",
            "Library tab shows only the series you follow — no dashboard clutter",
            "Reading history in Settings → General",
        ],
    ),
    ChangelogEntry(
        version="1.2.8",
        build=11,
        date="July 2026",
        highlights=[
            "Netflix-style full-screen profile pick — mood floods the whole "
            "screen for ~5 seconds before entering the app",
            "Library tab shows only the series you follow — no dashboard clutter",
            "Reading history in Settings → General",
            "Download queue snackbar auto-dismisses and no longer gets stuck "
            "on the Library tab",
        ],
    ),
    ChangelogEntry(
        version="1.2.7",
        build=10,
        date="July 2026",
        highlights=[
            "Library series now list every chapter from the source — read "
            "online or download the ones you're missing, right from the detail "
            "screen",
            "Correct series covers on the dashboard instead of a chapter's "
            "first page",
            "Swipe down to dismiss the reader settings sheet",
            "Back button on Settings, Updates, Backup, Storage, Diagnostics "
            "and Collections screens",
        ],
    ),
    ChangelogEntry(
        version="1.2.2",
        build=5,
        date="July 2026",
        highlights=[
            "Fresh installs from the official download page connect "
            "automatically — no server URL setup screen",
        ],
    ),
    ChangelogEntry(
        version="1.2.1",
        build=4,
        date="July 2026",
        highlights=[
            "Fresh install identity so the app installs cleanly without "
            "uninstalling any earlier build first",
        ],
    ),
    ChangelogEntry(
        version="1.2.0",
        build=3,
        date="July 2026",
        highlights=[
            "Sepia and grayscale reader color modes for late-night reading",
            "High-refresh-rate support up to 120 Hz on capable displays",
            "App-wide haptics and shimmering loading states",
            "Immersive reader transitions and a cross-fading page backdrop",
            "Live performance and display diagnostics",
        ],
    ),
    ChangelogEntry(
        version="1.1.0",
        build=2,
        date="July 2026",
        highlights=[
            "New More control center: history, bookmarks, statistics and storage",
            "In-app update system with one-tap APK download",
            "Redesigned source browser and source list with pinning",
            "Auto-scroll reading mode",
        ],
    ),
    ChangelogEntry(
        version="1.0.0",
        build=1,
        date="July 2026",
        highlights=[
            "First release: library, multi-source browsing and offline reader",
            "Downloads with pause, resume, retry and queueing",
            "Brightness, warm filter and AMOLED-black reader",
        ],
    ),
]


# (filename, title, caption) — screenshots served from SCREENSHOTS_DIR.
_SHOWCASE: list[tuple[str, str, str]] = [
    (
        "shot-library.png",
        "Your shelf, and nothing else",
        "The series you follow, with unread counts — no feed, no filler.",
    ),
    (
        "shot-novels.png",
        "Books, not just comics",
        "Novels get their own shelf and a reader built for prose.",
    ),
    (
        "shot-themes.png",
        "Forty-two themes",
        "Every one contrast-checked, and each profile keeps its own.",
    ),
    (
        "shot-statistics.png",
        "What you actually read",
        "Streaks, time spent, and which sources you come back to.",
    ),
]


def read_app_version() -> AppVersion:
    """Parse ``version: x.y.z+b`` from the Flutter pubspec.

    Falls back to sane defaults if the file is missing or malformed so the
    endpoint never 500s just because the mobile project isn't present.
    """
    version = _DEFAULT_VERSION
    build = _DEFAULT_BUILD
    try:
        for line in PUBSPEC_PATH.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if stripped.startswith("version:"):
                raw = stripped.split(":", 1)[1].strip().strip("'\"")
                name, _, build_str = raw.partition("+")
                if name.strip():
                    version = name.strip()
                if build_str.strip().isdigit():
                    build = int(build_str.strip())
                break
    except OSError:
        pass
    return AppVersion(version=version, build=build, apk="/app/download")


def _ios_meta_path() -> Path:
    """Location of the published .ipa's version metadata (sits beside the .ipa).

    Resolved per call rather than at import so it follows ``IPA_PATH``, which the
    deploy points at a bind mount.
    """
    configured = os.environ.get(IOS_META_ENV, "").strip()
    if configured:
        return Path(configured)
    return IPA_PATH.parent / IOS_META_NAME


def read_ios_release(ipa: Path) -> tuple[str, str, str]:
    """``(version, buildVersion, date)`` describing the published .ipa.

    Prefers the metadata CI wrote next to the binary, because neither obvious
    local source is trustworthy: this server can't read a version out of an .ipa,
    and its own pubspec checkout knows nothing about the build number CI stamped
    into that binary.

    Falls back field by field to the pubspec (and the .ipa's mtime) so an .ipa
    published before CI emitted metadata — or a truncated/garbled file — still
    yields a usable manifest instead of a 500.
    """
    info = read_app_version()
    version = info.version
    build = str(info.build)
    date = datetime.fromtimestamp(ipa.stat().st_mtime, tz=timezone.utc).strftime(
        "%Y-%m-%d"
    )

    try:
        meta = json.loads(_ios_meta_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return version, build, date
    if not isinstance(meta, dict):
        return version, build, date

    raw_version = meta.get("version")
    if isinstance(raw_version, str) and raw_version.strip():
        version = raw_version.strip()
    raw_build = meta.get("buildVersion")
    if isinstance(raw_build, (str, int)) and str(raw_build).strip().isdigit():
        build = str(raw_build).strip()
    raw_date = meta.get("date")
    if isinstance(raw_date, str) and raw_date.strip():
        date = raw_date.strip()
    return version, build, date


def _public_base_url(request: Request | None = None) -> str:
    """Absolute origin the phone should use for manifest download links.

    ``request`` is optional only for the install page, which can be rendered
    without one; the manifest always has a request in hand, so its links are
    always absolute, which is the property that actually matters (they are
    fetched by the phone, not by this server).
    """
    configured = os.environ.get(PUBLIC_BASE_URL_ENV, "").strip()
    if configured:
        return configured.rstrip("/")
    if request is None:
        return ""
    return str(request.base_url).rstrip("/")


def build_ios_source(request: Request) -> dict:
    """Build the AltStore/SideStore source manifest for the iOS build.

    The ``versions`` list is empty when no .ipa has been published yet — that is
    a valid source, and SideStore renders it as an app with nothing installable
    rather than failing to add the source at all.

    SideStore decides an update exists by comparing ``version`` /
    ``buildVersion`` against what is installed, so both must describe the .ipa
    actually behind ``downloadURL`` — they come from :func:`read_ios_release`,
    not from this server's pubspec. CI bumps the build number on every run, so
    pushing code is enough to surface an update; the pubspec ``version:`` only
    controls the human-readable name.
    """
    base = _public_base_url(request)

    versions: list[dict] = []
    if IPA_PATH.is_file():
        stat = IPA_PATH.stat()
        ios_version, ios_build, ios_date = read_ios_release(IPA_PATH)
        entry: dict = {
            "version": ios_version,
            "buildVersion": ios_build,
            "date": ios_date,
            "downloadURL": f"{base}/app/ios/download",
            "size": stat.st_size,
            "minOSVersion": IOS_MIN_VERSION,
        }
        notes = next(
            (e for e in _RELEASE_NOTES if e.version == ios_version),
            None,
        )
        if notes is not None:
            entry["localizedDescription"] = "\n".join(
                f"• {h}" for h in notes.highlights
            )
        versions.append(entry)

    return {
        "name": "ManhwaManiacs",
        "subtitle": "The iOS build of your ManhwaManiacs reader",
        "website": base,
        "tintColor": "#7C5CFF",
        "apps": [
            {
                "name": "ManhwaManiacs",
                "bundleIdentifier": IOS_BUNDLE_ID,
                "developerName": "ManhwaManiacs",
                "subtitle": "Manga & manhwa reader",
                # Deliberately does NOT claim offline reading. Downloads are
                # fetched and stored by the server, and the phone streams pages
                # from it, so "download for offline reading" was untrue -- see
                # docs/OFFLINE_READING.md for the on-device work that would make
                # it true. Advertising it before it exists is how a listing ends
                # up promising something the app cannot do.
                "localizedDescription": (
                    "Read manga and manhwa from your own ManhwaManiacs server. "
                    "Every account and profile keeps its own library, follows "
                    "and reading position. Download chapters to your server and "
                    "search every source at once."
                ),
                "iconURL": f"{base}/app/media/app-icon.png",
                "category": "entertainment",
                # Kept in step with _SHOWCASE by construction rather than by
                # hand: two hand-maintained lists of the same filenames is how
                # the SideStore manifest ends up pointing at images the landing
                # page no longer ships.
                "screenshots": [
                    f"{base}/app/media/{name}" for name, _title, _caption in _SHOWCASE
                ],
                "versions": versions,
            }
        ],
        "news": [],
    }


def _format_size(num_bytes: int) -> str:
    size = float(num_bytes)
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024 or unit == "GB":
            return f"{size:.1f} {unit}" if unit != "B" else f"{int(size)} B"
        size /= 1024
    return f"{size:.1f} GB"


# ── Install page ─────────────────────────────────────────────────────────────
#
# One page, one column, no build step, no JavaScript and no external requests --
# not even a font CDN. It is served straight off the backend behind a strict
# CSP, and the people it is written for open it on the phone they are about to
# install onto, over whatever connection they happen to have.
#
# It is ordered install-first: what this is, then the two buttons, then the
# reasons to care. Everything factual on it -- version, build, file sizes,
# dates, release notes -- is read at request time from the same sources the
# JSON endpoints use, so shipping a new build updates this page by itself and
# there is no second place to remember to edit.

# The app mark, drawn rather than fetched.
#
# There *is* an /app/media/app-icon.png, but it is still the stock Flutter logo
# (so is the Android launcher icon; only the iOS asset catalogue carries the real
# amber "M"). Putting a Flutter logo at the top of the page a stranger uses to
# decide whether this is a real app is worse than drawing the mark, so this is
# the iOS icon reproduced as a path: no request, no file to mount, and it cannot
# regress to a placeholder. Replace this with the real asset once
# mobile/docs/screenshots/app-icon.png is the actual icon -- the SideStore
# manifest's iconURL points at that same wrong file and wants the same fix.
_MARK = (
    '<svg class="icon" viewBox="0 0 100 100" role="img" aria-label="ManhwaManiacs">'
    '<defs><linearGradient id="m" x1="0" y1="0" x2="1" y2="1">'
    '<stop offset="0" stop-color="#F5A00B"/><stop offset="1" stop-color="#D2740A"/>'
    "</linearGradient></defs>"
    '<rect width="100" height="100" rx="23" fill="url(#m)"/>'
    '<path fill="#fff" d="M22 68V32h9l19 26 19-26h9v36h-8V45L53 68h-6L30 45v23z"/>'
    "</svg>"
)

# The no-install option, and for a good number of visitors the right answer.
# Env-overridable so a preview/staging deploy points at its own frontend rather
# than sending its testers to production.
WEB_APP_URL: str = os.environ.get(
    "MM_WEB_APP_URL", "https://manhwamaniacs.xyz"
).rstrip("/")

# Where a first-time iPhone visitor gets the thing that makes the feed usable.
SIDESTORE_URL = "https://sidestore.io"

# How many older releases sit behind the "Earlier versions" disclosure. The
# newest release is always shown expanded; a few more are one tap away, and the
# rest of the history stays in /app/changelog where it belongs. Small on
# purpose: the whole list is thousands of words, and this page has five seconds
# of a stranger's attention.
_OLDER_RELEASES = 3

_MONTHS = (
    "Jan",
    "Feb",
    "Mar",
    "Apr",
    "May",
    "Jun",
    "Jul",
    "Aug",
    "Sep",
    "Oct",
    "Nov",
    "Dec",
)


def _format_day(moment: datetime) -> str:
    """``5 Sep 2026`` -- no ``%-d``/``%e``, which are not portable."""
    return f"{moment.day} {_MONTHS[moment.month - 1]} {moment.year}"


def _pretty_date(raw: str) -> str:
    """Render an ISO date from the CI metadata the way the rest of the page does.

    Anything that isn't ``YYYY-MM-DD`` is passed through untouched: the field is
    free text written by CI, and showing it verbatim beats guessing.
    """
    try:
        return _format_day(datetime.strptime(raw, "%Y-%m-%d"))
    except ValueError:
        return raw


class _Artifact(NamedTuple):
    """What the page can honestly say about one downloadable build."""

    available: bool
    size: str
    date: str


def _artifact(path: Path) -> _Artifact:
    """Size and date read off the file itself, or a plain "not there" answer.

    ``is_file()`` rather than ``exists()`` on purpose: in production these are
    read-only bind mounts, and an unpublished one surfaces as an empty
    *directory*. Treating that as a build is how the page ends up offering a
    button that 404s.
    """
    if not path.is_file():
        return _Artifact(False, "", "")
    stat = path.stat()
    return _Artifact(
        True,
        _format_size(stat.st_size),
        _format_day(datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc)),
    )


def _feed_url(request: Request | None) -> str:
    """Absolute URL of the SideStore source feed, for pasting into the phone.

    Absolute because it is typed/pasted into another app, which has no notion of
    this page's origin -- a relative path would be meaningless there.
    """
    base = _public_base_url(request)
    return f"{base}/app/source.json" if base else "/app/source.json"


def _render_android(apk: _Artifact) -> str:
    if not apk.available:
        return """
    <section class="card">
      <h2>Android</h2>
      <p class="unavailable">No Android build published yet.</p>
      <p>Nothing to install here for the moment — read in your browser instead,
        using the link below.</p>
    </section>"""
    return f"""
    <section class="card">
      <h2>Android</h2>
      <a class="btn" href="/app/download">Download for Android</a>
      <p class="meta">{escape(apk.size)} · updated {escape(apk.date)}</p>
      <p>Tap the button, then open the file once it has downloaded. Android will
        ask, once, whether to allow installs from your browser — allow it, then
        tap Install. That's the whole thing.</p>
    </section>"""


def _render_iphone(ipa: _Artifact, feed_url: str, release: str) -> str:
    if not ipa.available:
        return """
    <section class="card">
      <h2>iPhone</h2>
      <p class="unavailable">No iPhone build published yet.</p>
      <p>When there is one it will appear here. Until then the website below
        works on an iPhone with nothing to install.</p>
    </section>"""
    return f"""
    <section class="card">
      <h2>iPhone</h2>
      <p>Apple does not let a website install an app, so the iPhone route needs
        <a href="{escape(SIDESTORE_URL)}" rel="noopener">SideStore</a> — a free
        app that installs apps like this one. Install SideStore first.</p>
      <p>Then open SideStore, go to <strong>Sources</strong>, tap
        <strong>+</strong>, and paste this address:</p>
      <p class="url">{escape(feed_url)}</p>
      <p>ManhwaManiacs appears in that source, ready to install — and every
        later update turns up in the same place.</p>
      <p class="meta">{escape(release)} · {escape(ipa.size)} ·
        updated {escape(ipa.date)}</p>
    </section>"""


def _render_release(entry: ChangelogEntry) -> str:
    notes = "".join(f"<li>{escape(note)}</li>" for note in entry.highlights)
    return f"""
    <section class="card">
      <h2>What's new in {escape(entry.version)}</h2>
      <p class="meta">{escape(entry.date)} · build {entry.build}</p>
      <ul>{notes}</ul>
    </section>"""


def _render_older_releases() -> str:
    older = _RELEASE_NOTES[1 : 1 + _OLDER_RELEASES]
    if not older:
        return ""
    items = "".join(
        f"""
        <h3>{escape(entry.version)} <span class="meta">{escape(entry.date)}</span></h3>
        <ul>{"".join(f"<li>{escape(n)}</li>" for n in entry.highlights)}</ul>"""
        for entry in older
    )
    return f"""
    <details class="card">
      <summary>Earlier versions</summary>
      {items}
    </details>"""


def _render_shots(cache_key: str) -> str:
    """Two real screenshots, and only ones actually on disk.

    The deploy mounts these in; a missing mount must degrade to no pictures, not
    to two broken-image icons on the page a new user is judging the app by.
    """
    present = [
        (name, title)
        for name, title, _caption in _SHOWCASE
        if (SCREENSHOTS_DIR / name).is_file()
    ][:2]
    if not present:
        return ""
    shots = "".join(
        f"""
      <img src="/app/media/{escape(name)}?v={escape(cache_key)}"
           alt="{escape(title)}" loading="lazy" decoding="async" />"""
        for name, title in present
    )
    return f'\n    <section class="shots">{shots}\n    </section>'


def render_landing_html(request: Request | None = None) -> str:
    """The whole install page: self-contained HTML, built from live state."""
    info = read_app_version()
    cache_key = f"{info.version}.{info.build}"
    apk = _artifact(APK_PATH)
    ipa = _artifact(IPA_PATH)
    ios_release = ""
    if ipa.available:
        # The .ipa's own numbers, not this server's pubspec: CI stamps the build
        # it published, and the two legitimately differ (an iOS build lags a
        # deploy, or runs ahead of one). Claiming the pubspec version next to an
        # older binary would be a lie the visitor cannot check.
        ios_version, ios_build, ios_date = read_ios_release(IPA_PATH)
        ios_release = f"{ios_version} (build {ios_build})"
        ipa = _Artifact(True, ipa.size, _pretty_date(ios_date))

    body = f"""
  <main>
    <header class="head">
      {_MARK}
      <h1>ManhwaManiacs</h1>
      <p class="version">Version {escape(info.version)} · build {info.build}</p>
      <p class="tagline">Manga, manhwa and novels on your phone. One library
        across every source, and chapters you can download and read with no
        signal at all.</p>
    </header>
{_render_android(apk)}
{_render_iphone(ipa, _feed_url(request), ios_release)}
    <a class="card web" href="{escape(WEB_APP_URL)}">
      <strong>Or just read in your browser</strong>
      <span>{escape(WEB_APP_URL.split("//", 1)[-1])} — nothing to install, works
        on anything.</span>
    </a>
{_render_shots(cache_key)}
{_render_release(_RELEASE_NOTES[0]) if _RELEASE_NOTES else ""}
{_render_older_releases()}
    <footer>ManhwaManiacs · {escape(info.version)} ({info.build})</footer>
  </main>"""

    return (
        '<!doctype html>\n<html lang="en">\n<head>\n'
        '  <meta charset="utf-8" />\n'
        '  <meta name="viewport" content="width=device-width, initial-scale=1" />\n'
        '  <meta name="color-scheme" content="dark light" />\n'
        '  <meta name="theme-color" content="#101013" />\n'
        '  <meta name="description" content="Install ManhwaManiacs — a manga, '
        'manhwa and novel reader for Android and iPhone." />\n'
        "  <title>Install ManhwaManiacs</title>\n"
        f"  <style>{_CSS}</style>\n"
        f"</head>\n<body>{body}\n</body>\n</html>\n"
    )


# Inlined because the page must render with zero extra requests, and there is
# one page: a stylesheet would be a second round trip and a second file to keep
# in step for no benefit. Dark by default with the light palette behind
# prefers-color-scheme -- a system-level preference, not a theme system.
_CSS = """
*,*::before,*::after{box-sizing:border-box}
:root{
  --bg:#101013;--card:#1a1a1f;--line:#2c2c34;
  --fg:#ececf1;--muted:#a0a0ab;--accent:#f59e0b;--on-accent:#1a1200;
}
@media (prefers-color-scheme:light){
  :root{
    --bg:#faf9f7;--card:#ffffff;--line:#e3e1dd;
    --fg:#1b1b1f;--muted:#5f5f6b;--accent:#b45309;--on-accent:#ffffff;
  }
}
body{
  margin:0;padding:32px 20px 64px;background:var(--bg);color:var(--fg);
  font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
  font-size:16px;line-height:1.6;-webkit-text-size-adjust:100%;
}
main{max-width:34rem;margin:0 auto;display:grid;gap:20px}
h1,h2,h3{margin:0;line-height:1.25;letter-spacing:-.01em}
p{margin:0}
a{color:var(--accent)}

.head{text-align:center;display:grid;gap:10px;justify-items:center;padding:8px 0 4px}
.icon{width:84px;height:84px;border-radius:20px;display:block}
h1{font-size:30px;font-weight:700}
.version{color:var(--muted);font-size:14px}
.tagline{color:var(--muted);max-width:30rem}

.card{
  background:var(--card);border:1px solid var(--line);border-radius:16px;
  padding:22px;display:grid;gap:12px;
}
h2{font-size:20px;font-weight:700}
.card p{color:var(--muted)}
.card strong{color:var(--fg)}

.btn{
  display:block;text-align:center;background:var(--accent);color:var(--on-accent);
  font-size:17px;font-weight:700;text-decoration:none;
  padding:16px 20px;border-radius:12px;min-height:56px;line-height:24px;
}
.meta{font-size:14px}
.unavailable{color:var(--fg);font-weight:600}

.url{
  color:var(--fg);font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
  font-size:14px;word-break:break-all;background:var(--bg);
  border:1px solid var(--line);border-radius:10px;padding:12px 14px;
  -webkit-user-select:all;user-select:all;
}

.web{text-decoration:none;color:inherit;gap:4px}
.web span{color:var(--muted);font-size:15px}

.shots{display:grid;grid-template-columns:1fr 1fr;gap:14px}
.shots img{
  width:100%;height:auto;border-radius:14px;border:1px solid var(--line);
  display:block;background:var(--card);
}

.card ul{margin:0;padding-left:20px;color:var(--muted);display:grid;gap:8px}
.card h3{font-size:16px;margin-top:16px}
.card h3 .meta{color:var(--muted);font-weight:400}
summary{font-size:17px;font-weight:700;cursor:pointer}

footer{color:var(--muted);font-size:13px;text-align:center;padding-top:8px}

/* The screenshots stay two-up at every width on purpose. Stacked full-width on
   a phone they are portrait screenshots roughly a screen tall each, which buries
   the release notes under 1500px of pictures; side by side they stay a glance. */
@media (max-width:380px){
  body{padding:24px 16px 48px}
}
"""


@router.get("/app/version", response_model=AppVersion)
def app_version() -> AppVersion:
    """Latest app version metadata, read live from the Flutter pubspec."""
    return read_app_version()


@router.get("/app/changelog", response_model=Changelog)
def app_changelog() -> Changelog:
    """Structured release notes, newest first (also shown on the landing page)."""
    return Changelog(entries=_RELEASE_NOTES)


@router.get("/app/media/{name}")
def app_media(name: str) -> FileResponse:
    """Serve a bundled marketing screenshot (read-only, no path traversal)."""
    safe = Path(name).name
    path = SCREENSHOTS_DIR / safe
    if path.suffix.lower() not in _ALLOWED_MEDIA_SUFFIXES or not path.is_file():
        raise HTTPException(status_code=404, detail="Media not found.")
    return FileResponse(path)


@router.get("/app/download")
def app_download() -> FileResponse:
    """Serve the latest release APK as a download."""
    if not APK_PATH.is_file():
        raise HTTPException(
            status_code=404,
            detail="APK not built yet. Run `flutter build apk --release`.",
        )
    info = read_app_version()
    return FileResponse(
        path=APK_PATH,
        media_type="application/vnd.android.package-archive",
        filename=f"manhwamaniacs-{info.version}.apk",
    )


@router.get("/app/source.json")
def app_ios_source(request: Request) -> dict:
    """SideStore/AltStore source manifest.

    Added as a source inside SideStore on the phone; SideStore then polls this
    and offers an in-app update whenever the version here outruns the installed
    one, which is what removes the laptop from the update loop.
    """
    return build_ios_source(request)


@router.get("/app/ios/download")
def app_ios_download() -> FileResponse:
    """Serve the latest unsigned iOS build (fetched from CI, not built here)."""
    if not IPA_PATH.is_file():
        raise HTTPException(
            status_code=404,
            detail="No iOS build published yet. Run ops/fetch-ios-build.sh.",
        )
    version, build, _ = read_ios_release(IPA_PATH)
    return FileResponse(
        path=IPA_PATH,
        media_type="application/octet-stream",
        filename=f"manhwamaniacs-{version}-{build}.ipa",
    )
