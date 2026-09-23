"""Source IDs omitted from the active connector registry.

Only sources that still have connector code (or legacy aliases) but must not
register. Madara dead sites were removed from ``catalog.py`` instead.

Adding a line here is a deregistration, and a deregistration now also disposes
of the source's cached rows: ``services.source_cache_service`` sweeps every
cache table for source ids the registry no longer knows, on the next boot and
daily after that. Nothing else to do — and nothing to undo either, since a line
removed from here simply refetches.
"""

from __future__ import annotations

EXCLUDED_CONNECTORS: frozenset[str] = frozenset({
    # --- External / never catalogued ----------------------------------------
    "comick",
    "bato",  # shut down Jan 2026
    "cartoonmad",  # Afternic parked
    "dragontea",  # Cloudflare JS wall
    "comix_to",  # signed API; blocks server access
    "gingertoon",  # CF-protected admin-ajax catalog
    "hentai3z",  # placeholder stub
    "hentaiyes",  # affiliate hub, no catalog
    # --- Hand-crafted but dead (code kept for fixtures) -----------------------
    "1stkissmanga",  # 1stkissmanga.io parked / unreachable
    # Deregistered 2026-09-04 after an end-to-end probe from the VPS. Each of
    # these could only ever error in the UI, so leaving them registered cost
    # users a broken source rather than buying us an eventual recovery.
    "coffeemanga",  # coffeemanga.ink 404s every path (/, /manga/, sitemap, wp-json)
    "harimanga",  # harimanga.vip TLS handshake aborts; .com redirects to a lander
    # Deregistered 2026-09-04 after the speed/health audit. Every request to
    # the apex read-times-out (91.7s before giving up -- it was the single
    # slowest thing in the registry, and it only ever produced an error), and
    # www.cmanhua.com now serves the stock "IIS Windows Server" placeholder,
    # so there is no origin left to fix a connector against.
    "cmanhua",
    # Deregistered 2026-09-05 after an end-to-end probe from the VPS. Weeb
    # Central itself is healthy from here -- browse, search, detail and
    # chapters all pass in about two seconds -- but two of the four CDN zones
    # it shards page images across, official.lowee.us and scans.lastation.us,
    # answer this deployment's OVH address with a Cloudflare WAF block page:
    # "Sorry, you have been blocked", our own IP echoed back, and no challenge
    # to solve. It is the egress IP and nothing else. Measured from inside the
    # production container, every one of these 403s on both zones and 200s on
    # hot.planeptune.us over the identical code path: a bare GET, the
    # connector's Referer + User-Agent, a full browser header block
    # (Accept/Accept-Language/Sec-Fetch-*/UA-CH), and four curl_cffi
    # impersonation profiles across Chrome, Safari and Firefox. The same bare
    # GET from a residential line returns the PNG. The zones are not mirrors
    # of each other -- a blocked path 404s on the reachable planeptune.us and
    # compsci88.com hosts -- and the container has no IPv6 route to try their
    # AAAA records from. Sampled serially the same day: of the 21 series on
    # browse page 1 (Latest Updates) that resolved to a page URL, all 21 were
    # on a blocked zone, and 7 of 20 on the Popularity page were. So the
    # default catalogue is unreadable here, and the connector cannot tell a
    # readable series from an unreadable one until the reader is already open
    # on broken images. Delete this line the day the deployment reads from
    # residential egress; the connector and its fixtures are untouched and
    # still pass.
    "weebcentral",
})


#: Adult source ids whose connector is no longer registered: removed from
#: ``catalog.py``, deleted outright, or listed in :data:`EXCLUDED_CONNECTORS`.
#:
#: A source's maturity is a property of its id, and it outlives the connector.
#: Follows, pins, progress and bookmarks on a removed source are not deleted
#: with it, and a follow whose genres carried no Adult/Mature/Smut tag stores
#: no ``content_rating`` of its own -- the ONLY thing keeping it off a profile
#: with 18+ off was the installed descriptor's ``mature=True``. Deregistering
#: the source took that away, the row resolved to "unknown", which is shown,
#: and a series hidden the day before appeared by title and cover in that
#: profile's library and Continue shelf. A removal must not be a disclosure,
#: so through ``core.connector_directory.is_mature_source`` an id listed here
#: stays 18+ for as long as rows naming it exist.
#:
#: Append the id whenever an adult source goes; nothing ever needs to come
#: out. A source that returns to the catalogue is harmless here, because an
#: installed descriptor always wins over this set.
#:
#: Every id git history shows registered with ``mature=True`` and no longer
#: registered, by when it went. Rows naming the ones that went before the
#: 2026-07-27 wipe cannot be in the live database, but listing them costs
#: nothing and a restored backup is exactly where they would come back from.
RETIRED_MATURE_SOURCES: frozenset[str] = frozenset({
    # 2026-07-14 -- catalogue lines moved to hand-written connectors or dropped.
    "bato",
    "cmanhua",  # connector code kept and excluded above; still MATURE = True
    "comix_to",
    "gingertoon",
    "hentai3z",
    "hentaiyes",
    # 2026-07-27 -- the catalogue prune.
    "allhenscan",
    "asiatoon",
    "hentai2read",
    "hentai4free",
    "hentaicity",
    "hentaihere",
    "heytoon",
    "hiperdex",
    "hitomi",
    "honeytoon",
    "kingcomix",
    "lezhin",
    "lunatoons",
    "luscious",
    "lustoon",
    "mangago",
    "manhuaus",
    "manhwa_raw",
    "manhwahub",
    "manhwazone",
    "manytoon",
    "multporn",
    "myhentaicomics",
    "myhentaigallery",
    "nhentai_com",
    "olympusbiblioteca",
    "palcomix",
    "pururin",
    "shibamanga",
    "simplyhentai",
    "svscomics",
    "toomics",
    "toongod",
    "topton",
    "tsumino",
    "wfwf",
    "xyzcomics",
    "yaoimangaonline",
    # 2026-09-04 onwards -- end-to-end probes from the VPS.
    "pawmanga",
    "bbato",
    "toonily",
    "manhwa68",
    "manhwatoon",
    "rawdex",
    "toonizy",
    "hentaisco",
    "lilymanga",
    "linkmanga",
    # Missed on the first pass, found by diffing every ``mature=True`` source
    # git history ever registered against the installed registry.
    "topmanhua",  # 2026-09-05 -- its CDN answers 526 for every page image
    "toonilyme",  # deregistered as a duplicate of beehentai (registry.py)
})
