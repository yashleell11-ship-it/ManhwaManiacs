"""Madara-factory source catalog — live connectors only.

Pruned 2026-07-27: dead/parked/CF-blocked sites removed after E2E probe.
"""

from __future__ import annotations

from connectors.madara.config import MadaraSiteConfig


def _site(
    source_id: str,
    display_name: str,
    domain: str,
    *,
    url_segment: str = "manga",
    listing_post_type: str | None = None,
    mature: bool = False,
    use_cf: bool = True,
    extra_image_hosts: frozenset[str] = frozenset(),
) -> MadaraSiteConfig:
    return MadaraSiteConfig(
        source_id=source_id,
        display_name=display_name,
        base_url=f"https://{domain}",
        url_segment=url_segment,
        listing_post_type=listing_post_type,
        mature=mature,
        use_cf=use_cf,
        extra_image_hosts=extra_image_hosts,
    )


# fmt: off
MADARA_CATALOG: tuple[MadaraSiteConfig, ...] = (
    # --- Live Madara sources (E2E verified 2026-07-27) ----------------------
    # Removed 2026-09-04 after an end-to-end probe from the VPS:
    #   pawmanga  - pawmanga.com is a fingerprint-redirect parking page, 0 series
    #   topmanhua - cdn.topmanhua.net is permanently 526 (CF cannot validate the
    #               origin cert) and topmanhua.com now 302s to a monetisation
    #               domain, so no page image can ever be served.
    #
    # Removed 2026-09-05, each one added earlier the same day and then failed
    # end-to-end from the production container. The rule the owner set is that
    # a source that only ever errors is worse than an absent one, so these are
    # deleted rather than parked. Every reason below reproduced identically on
    # two independent runs, so none of them is a bad moment on the network:
    #   topmanhua  - re-added at topmanhua.net on the finding that it served
    #                every page image from its own /wp-content/uploads. It does
    #                not: the reader's first page resolves to
    #                cdn.topmanhua.net, which is the same 526 recorded above,
    #                so browse/detail/chapters/pages all pass and the image
    #                bytes never arrive. This is the exact failure the note
    #                above warned would come back, and it did.
    #   manhuatop  - browse 404s on every segment the connector will try:
    #                the configured /manhua/, then the /manga/ and /serie/
    #                fallbacks. Nothing lists, so nothing downstream runs.
    #   rawdex     - browse 404s the same way, ending on /serie/.
    #   mangayy    - browse/search/detail all pass and then get_chapters
    #                returns 0 chapters for the first series, so no series can
    #                be opened.
    #   manhwa68   - identical shape to mangayy: 0 chapters after a clean
    #                detail.
    #   manhwatoon - cdn.manhwatoon.me serves page bytes under a bogus
    #                ``text/plain; charset=koi8-r``, which _safe_image_media_type
    #                clamps to application/octet-stream, and the image proxy
    #                refuses that. The entry's own note called for an eyes-on
    #                reader check; this is that check, and it failed.
    #   toonizy    - every page image is a redirect to cdn.toonizy.com, and the
    #                proxy does not follow redirects, so no page renders.
    #
    # Removed 2026-09-05 after the VPS probe died in the TLS handshake, not in
    # HTTP:
    #   manhuakey - the registration expired 2026-09-04T08:48:55Z and Namecheap
    #               repointed the name 13 hours later, so .com now delegates
    #               manhuakey.com to dns101/dns102.registrar-servers.com and
    #               every public resolver answers with the parking lander's
    #               IPs. That host carries no certificate for the name, so it
    #               completes the TCP connect and then drops the ClientHello --
    #               the UNEXPECTED_EOF_WHILE_READING the probe reported. It
    #               drops it identically under OpenSSL and under curl_cffi's
    #               BoringSSL impersonation, with SNI and without, and at a
    #               forced TLS 1.2, so use_cf=True was never going to save it.
    #               Port 80 does answer, with a Namecheap "registration has
    #               expired" ad page. The WordPress origin is still up behind
    #               Cloudflare but only stale DNS still points at it; from the
    #               VPS a pinned Cloudflare IP answers 403. Restoring this is
    #               one line if the owner renews inside the redemption window.
    #
    # Probed and DELIBERATELY NOT ADDED 2026-09-05 (all four fingerprinted as
    # Madara from the outside; three do not behave like it). Do not re-add
    # without re-probing from the VPS:
    #   kingofshojo.com - not Madara at all. Runs the Themesia "mangareader"
    #               theme: chapters live at the site root as
    #               /<series>-chapter-<n>/, there is no wp-manga markup, and
    #               admin-ajax.php answers manga_get_chapters with 400 "0".
    #               Needs a bespoke connector, not a catalog line.
    #   mangaeffect.com - a permanent 301 to www.mangaread.org for every path,
    #               i.e. a second domain for the `mangaread` entry above.
    #   mangagg.com - genuine Madara (url_segment "comic"), and browse/search/
    #               detail/pages/image bytes all work, but the install
    #               publishes only the newest 24 chapters of every series
    #               through every enumerable route (36/36 sampled series
    #               returned exactly 24, none starting at chapter 1; the
    #               chapter-1 URLs are live but unreachable from any listing).
    #               A source you can never start reading from the beginning.
    #
    # Probed 2026-09-05 and NOT catalog lines -- real catalogues worth having,
    # but none of them runs Madara, so each needs a bespoke connector instead
    # of a ``_site(...)`` entry:
    #   simply-hentai.com - Next.js SSR; the catalogue lives in __NEXT_DATA__
    #               and /api/search 404s, so there is no JSON API to call.
    #   timelesstoons.org - custom SSR app with opaque /chapter/<hex>-<hex>/
    #               ids, and every image behind the generic wsrv.nl proxy.
    #   wnacg.com - MeiuPic album CMS, gallery-per-work like nhentai; images
    #               on sharded t*/img*.qy0.ru hosts.
    #   xcomic.me - Qwik SSR aggregator; MangaDex's tag vocabulary but its own
    #               ids and self-hosted /_f/ images, so not a MangaDex proxy.
    #   xyzcomics.com - WordPress + Themify, one post per work, and its front
    #               page is /multkomix/ rather than /.
    #   yaoimangaonline.com - WordPress on the Herald magazine theme: zero
    #               wp-manga markup, no admin-ajax, no /manga/ post type.
    #               Every post is one chapter at a flat permalink and series
    #               exist only as /tag/ pages, so a connector would have to
    #               synthesise series from tags and chapter order from post
    #               titles. Adult, so mature=True if it is ever built.
    #
    # Probed 2026-09-05 (shard 12) and NOT added, the only genuine Madara of
    # the batch: zazamanga.com (canonical www.zazamanga.com, the apex 301s).
    # The install strips trailing slashes and two shared MadaraHtml patterns
    # require them, so the generic connector parses the live HTML into
    # nothing. parse_series_list returns 0 items -- every card anchor is
    # href="…/manga/<slug>" with no trailing "/", which none of the four
    # _card_anchor patterns accept -- and parse_chapters returns 0, because
    # rows are <div class="wp-manga-chapter"> while _chapter_link matches
    # only <li class="wp-manga-chapter"> and _chapter_item_link only
    # <div class="chapter-item">. parse_chapter_pages is the one stage that
    # already works: 140 pages off img-r1.2xstorage.com, single-quoted src
    # and all, since _img_src accepts either quote. Widening those two
    # patterns is a mappers.py change affecting every Madara site, so it is
    # not a catalog decision; with it applied locally the site parsed 12
    # series/page and 112 chapters and the entry would be
    #   _site("zazamanga", "ZazaManga", "www.zazamanga.com", mature=True,
    #         extra_image_hosts=frozenset({"2xstorage.com", "zinmanga1.com"}))
    # mature=True: the front page mixes explicitly adult titles in with
    # general series. Covers sit on 2xstorage as well, so that allowlist is
    # load-bearing for browse and not only for page images.
    _site("mangaread", "MangaRead", "mangaread.org"),
    _site("manhuaplus", "ManhuaPlus", "manhuaplus.com", extra_image_hosts=frozenset({"cdn.manhuaplus.com"})),
    _site("manhuahot", "ManhuaHot", "manhuahot.com", use_cf=False, mature=True),
    _site("manhuanext", "ManhuaNext", "manhuanext.com", use_cf=False, mature=True),
    _site("manhwaclub", "ManhwaClub", "manhwaclub.net", mature=True, use_cf=False),
    _site("manhwatop", "ManhwaTop", "manhwatop.com", mature=True, use_cf=False),
    _site("manhwaden", "ManhwaDen", "manhwaden.com", mature=True, use_cf=False, extra_image_hosts=frozenset({"remanhwa.me"})),
    _site("manhwanex", "ManhwaNex", "manhwanex.com", mature=True, use_cf=False),
    _site("s2manga", "S2Manga", "s2read.com", use_cf=False),
    # Added 2026-09-05 after an end-to-end probe from the VPS container.
    # Real Madara (wp-content/themes/madara), /manga/ series pages, chapters
    # from the per-series ``{series}/ajax/chapters/`` endpoint — its
    # /wp-admin/admin-ajax.php answers manga_get_chapters with 400, so the
    # connector settles on the relative shape after one probe. Plain httpx
    # cleared every stage from the OVH egress (~120 requests, no challenge),
    # so use_cf=False buys the cheaper client; covers and page images are all
    # on mangasushi.org itself, so the host-derived allowlist already covers
    # them and no extra_image_hosts are needed. Genres are stock-Madara with
    # 2 adult-tagged series site-wide, so it stays a general (non-mature)
    # source like mangaread/manhuaplus.
    _site("mangasushi", "MangaSushi", "mangasushi.org", use_cf=False),
    # Added 2026-09-05 (shard 5) after an end-to-end probe from the VPS.
    # Stock Madara: /manga/ listing, the per-series ``ajax/chapters/`` POST
    # and 55 wp-manga-chapter-img pages all answered, and every page image is
    # self-hosted, so the host-derived allowlist already covers them.
    # Flipped to mature 2026-09-05. The earlier non-mature reading rested on
    # /manga-genre/adult/, /mature/, /smut/ and /ecchi/ all 404ing, but this
    # install publishes no genre taxonomy at all -- a series page carries no
    # genres-content block and no genre/tag markup of any kind -- so those
    # 404s were never evidence about the content. The titles are: 11 of 53
    # distinct series across listing pages 1-5 are explicitly sexual
    # ("I Like You Who Can Have Sex with Anyone", "Official Adultery?",
    # "Netorare Tsuihousareta...", "108P!"), and ?m_orderby=views puts more of
    # them at the top. It also shares works with hentaihand. Mixed ecchi
    # catalogue with no site-side signal, so it must sit behind the gate.
    _site("kokomangas", "KokoMangas", "kokomangas.com", mature=True),
    # Madara under a renamed theme directory (themes/linkmanga), so it
    # fingerprints on wp-manga/page-item-detail, not on the theme path. Its
    # own ``{series}/ajax/chapters/`` soft-fails by returning the whole page,
    # so the /wp-admin/admin-ajax.php manga_get_chapters flow is the one that
    # works here. Lists start at ch-001, so the full backlog is reachable --
    # not the mangagg 24-chapter trap. mature=True is positively established:
    # /manga-genre/adult/, /mature/, /smut/ and /ecchi/ each return 200 with
    # populated series, and sampled titles are adult manhwa. A minority of
    # series (e.g. vigilante-part-2) point their page images at
    # f1link.linkmanga.com and those files are genuinely missing (nginx 404);
    # allowlisting the host keeps the SSRF guard from stacking a second,
    # more confusing failure on top of the 404.
    _site("linkmanga", "LinkManga", "linkmanga.com", mature=True, extra_image_hosts=frozenset({"f1link.linkmanga.com"})),
    #
    # Shard 5 also probed these 2026-09-05 and DELIBERATELY NOT ADDED — every
    # one is reachable and has real content, but none is Madara, so a catalog
    # line would register a source that only errors. Do not re-add without
    # re-probing from the VPS:
    #   hivetoons.org - the best general-audience candidate of the shard and
    #               the one worth a bespoke connector: custom SSR app with an
    #               embedded JSON payload, /series/<slug>/chapter-<n>, 34 page
    #               images verified on a sampled chapter, mainstream manhwa
    #               (Reborn Rich, Lookism), so mature=False when written.
    #               Note the image host drops the "s" — storage.hivetoon.com,
    #               not hivetoons — so the SSRF allowlist needs it spelled out.
    #   hiperdex.tv - no longer the old Madara Hiperdex. A React SPA catch-all
    #               serves every path and the real data lives behind /api/trpc,
    #               which answers 401 "Invalid or missing API Key" on every
    #               route. Adult, and unreachable without reversing that key.
    #   kaliscan.me - live general-audience catalogue on a bespoke PHP stack
    #               (own /az-list/, /top/, /status/ routes, no wp-content
    #               anywhere) with a JS-driven reader that names no image host
    #               in the served HTML. Full hand-written connector or nothing.
    #   kingcomix.com - WordPress but the theme is "ultimatecomix", not Madara:
    #               no wp-manga markup, no chapter ajax, no /manga/ segment.
    #               Flat gallery-style porn-comic posts at the site root, i.e.
    #               the freeadultcomix/allporncomic family. Adult if written.
    #   kunmanga.online - the trap of the shard: it copies Madara's CSS class
    #               names (wp-manga x70, page-item-detail x20) while having no
    #               wp-content, no theme path, no admin-ajax.php, and Madara's
    #               trailing slash missing from chapter URLs. A ZinManga
    #               rebuild (cdn.zinmanga1.com), general-audience, bespoke.
    #   lustoon.com - Next.js, /comic/<slug>/chapter-N, images on
    #               media.lustoon.com and readable, but the markup emits
    #               http:// (521) so URLs must be rewritten to https, page
    #               URLs come out of the __next_f payload rather than <img>
    #               tags, and the library is only ~32 series. Adult if written.
    _site(
        "allporncomic",
        "AllPornComic",
        "allporncomic.com",
        url_segment="porncomic",
        mature=True,
        use_cf=False,
        extra_image_hosts=frozenset({"cdn.allporncomic.com"}),
    ),
    _site("apcomics", "APComics", "apcomics.org", mature=True, use_cf=False),
    _site("cocomic", "CoComic", "cocomic.co", mature=True, use_cf=False),
    # Serves its page images from its manhwaclub.net sibling, so the image
    # proxy's SSRF allowlist needs that host or every page is rejected before
    # a request is made (the site browses and paginates fine regardless).
    _site(
        "manga18x",
        "Manga18x",
        "manga18x.net",
        mature=True,
        use_cf=False,
        extra_image_hosts=frozenset({"manhwaclub.net"}),
    ),
    _site("cucumbermanga", "CucumberManga", "cucumbermanga.com", mature=True, use_cf=False),
    # lilymanga removed 2026-09-22 after an end-to-end probe from the VPS.
    # It browses, searches and lists chapters perfectly — and then every page
    # image is a 522 from its own CDN (glcomic.lilymanga.net), three times in
    # a row, while lilymanga.net itself answers 200. The site is serving URLs
    # to an origin that no longer responds, so a reader can open a chapter and
    # never see a panel. Registered, that is a source which looks alive and
    # cannot be read; restoring it is this one line if their CDN returns.
    _site("mangadistrict", "MangaDistrict", "mangadistrict.com", url_segment="series", listing_post_type="wp-manga", mature=True, use_cf=False),
    # Added 2026-09-05 after an end-to-end probe from the VPS. Three sibling
    # installs from one operator (identical Madara title template) whose
    # catalogues are niche-partitioned -- western parody comics, futanari,
    # yuri -- with fully disjoint slug sets, so they complement each other and
    # allporncomic rather than duplicating them. Plain curl cleared browse,
    # series and chapter on all three from the OVH egress, so use_cf=False
    # buys the cheaper client; every cover and page image is self-hosted under
    # /wp-content/uploads/, so the host-derived allowlist already covers them
    # and no extra_image_hosts are needed. Chapters come from the per-series
    # ``{series}/ajax/chapters/`` endpoint -- admin-ajax.php answers
    # manga_get_chapters with 400 on all three, so the connector settles on
    # the relative shape after one probe.
    #
    # hentaixcomic and hentaixyuri ship the simple-cloudflare-turnstile plugin
    # (hentaixyuri also honeypot + page-links-to) and reference
    # challenges.cloudflare.com, but it gated no read path from the VPS -- it
    # appears to guard only the comment/login forms. Flip these to use_cf=True
    # if browse ever starts coming back as a challenge page.
    _site("hentaixcomic", "HentaiXComic", "hentaixcomic.com", mature=True, use_cf=False),
    _site("hentaixdickgirl", "HentaiXDickgirl", "hentaixdickgirl.com", mature=True, use_cf=False),
    _site("hentaixyuri", "HentaiXYuri", "hentaixyuri.com", mature=True, use_cf=False),
    # jinmangas.com is nothing but a 301 to this name, so the redirect target
    # is what gets registered. Textbook Madara behind Cloudflare with no
    # challenge; the per-series ajax/chapters/ endpoint returned 60 chapters
    # and every cover is on mangafree.info itself. Mature: the catalogue is
    # uncensored 18+ manhwa throughout.
    _site("mangafree", "MangaFree", "mangafree.info", mature=True),
    # Added 2026-09-05 after end-to-end probes from the VPS egress. Stock
    # Madara (wp-content/themes/madara plus a child theme), cleared
    # browse/search/detail/chapters/pages/image-bytes on the plain
    # SyncConnectorHttpClient, so use_cf=False buys the cheaper client. Each
    # one's /wp-admin/admin-ajax.php answers manga_get_chapters with 400, so
    # like mangasushi above they settle on the per-series
    # ``{series}/ajax/chapters/`` shape after a single probe.
    #
    # Five entries were added here; three survive. mangayy and manhuatop were
    # removed 2026-09-05 (see the header record). Of the three, only mangatop
    # is a general aggregator whose Adult/Mature genres are a small slice of a
    # mainstream catalogue with no 18+ interstitial -- the same line already
    # drawn for mangaread/manhuaplus/mangasushi. mangamaniacs and mangaowl are
    # adult catalogues and are flagged.
    #
    # Explicitly yaoi/smut: the site titles itself "Read the best yaoi manga
    # and manhwa online for free" and the first sampled series carries
    # Omegaverse + Smut, so mature is not a judgement call here. Page images
    # sit on an images.* sibling the host-derived allowlist does not reach;
    # covers are on the apex. Cosmetic wart: page 1's pagination advertises
    # only page 2 so the reported total is wrong, but each page advertises the
    # next, so api_has_more still walks the (deep) catalogue forward.
    _site("mangamaniacs", "MangaManiacs", "mangamaniacs.org", mature=True, use_cf=False, extra_image_hosts=frozenset({"images.mangamaniacs.org"})),
    # Series live at /read-1/<slug>/, so the segment is the whole trick; that
    # path paginates natively to page 222 (~3300 series) and needs no
    # listing_post_type override. This zone's bot-fight rule is header-shape
    # sensitive — a UA-only httpx GET is answered 403 while the production
    # client's own header block passed every request — so use_cf=False is
    # correct but the default headers are load-bearing here.
    # Flipped to mature 2026-09-05: this is an adult BL catalogue, and the
    # site tags it as one. Its own series pages for the most-viewed works
    # (dark-fall, roses-and-champagne, jinx) each carry Adult + Mature + Smut
    # + Yaoi genres, and ?m_orderby=views leads with "WET SAND [UNCENSORED
    # VERSION R19+]" and "Milk My Strawberries (Uncensored)". The entry was
    # added with no maturity note at all, so it defaulted to visible with the
    # 18+ gate shut.
    _site("mangaowl", "MangaOwl", "mangaowl.io", url_segment="read-1", mature=True, use_cf=False),
    # 4 of 9 sampled chapters serve their pages from u1.manhuatop.org, and
    # every chapter also embeds a manhuatop.org promo banner inside a
    # wp-manga-chapter-img tag that the mapper extracts as a page — without
    # that host the image proxy rejects those pages before requesting them.
    # Pagination is a sliding window (page N links N-1..N+1), so the reported
    # total is meaningless; browse still walks forward one page at a time.
    _site("mangatop", "MangaTop", "mangatop.org", url_segment="series", use_cf=False, extra_image_hosts=frozenset({"manhuatop.org"})),
    # Added 2026-09-05 after end-to-end probes from the VPS egress. Five were
    # added; three survive -- manhwa68 and manhwatoon were removed 2026-09-05
    # (see the header record). All are stock Madara (page-item-detail cards,
    # wp-manga-chapter rows) whose /wp-admin/admin-ajax.php answers
    # manga_get_chapters with 400 or 403, so like mangasushi above they settle
    # on the per-series ``{series}/ajax/chapters/`` shape after a single
    # probe. Every one is explicitly adult -- 18+ badges on the listings,
    # adult/smut genre taxonomies, hentai doujinshi titles -- hence
    # mature=True throughout.
    #
    # Series live under /manhwa/, not /manga/: the wp-manga sitemap and the
    # /manhwa-genre/ taxonomy both use that segment, and the homepage is an
    # Elementor landing page rather than the archive. Hostinger origin with no
    # Cloudflare; page images are self-hosted under /wp-content/uploads/.
    # Worth knowing before touching the mapper: this child theme emits
    # src=" https://..." with a leading space inside the attribute value, so
    # the URL has to be stripped before it is requested.
    _site("manhwacomics", "ManhwaComics", "manhwacomics.com", url_segment="manhwa", mature=True, use_cf=False),
    # LiteSpeed origin with no Cloudflare in front; covers and page images are
    # both on the site host. Not a second domain for the `mangaread` entry
    # above -- different host, different catalogue.
    _site("manhwareads", "ManhwaReads", "manhwareads.com", mature=True, use_cf=False),
    # Madara under a reskinned child theme (wp-content/themes/axiix), so a
    # theme-path fingerprint misses it while the markup is stock. Both ajax
    # chapter shapes are dead here -- ajax/chapters/ 404s, admin-ajax answers
    # 400 "0" -- but the chapter list is embedded in the detail HTML, so
    # _fetch_ajax_chapters is never reached. Page images are on himg.nl, which
    # the allowlist therefore needs. This install re-serves 8muses-sourced
    # scans, so expect heavy title overlap with the eightmuses connector; that
    # one targets a different backend, so this is not a duplicate.
    _site("milftoon", "Milftoon", "milftoon.xxx", url_segment="comics", mature=True, extra_image_hosts=frozenset({"himg.nl"})),
    #
    # Also probed 2026-09-05 in the same sweep and DELIBERATELY NOT ADDED.
    # All three are live and reachable from the VPS; none is a catalog line:
    #   manhwabuddy.com - real and working, but a bespoke PHP+jQuery CMS with
    #               no WordPress fingerprint at all: /manhwa/<slug>/chapter-N/,
    #               /genre/<g>/, /page/N/, pages on img01.manhwabuddy.com.
    #               Deep and adult, so worth a connector -- just not this file.
    #   manhwaread.org - WordPress but not Madara: its own theme plus a
    #               'mangomic-core' plugin, Madara-shaped by URL only.
    #               ajax/chapters/ 404s and admin-ajax 400s (the full chapter
    #               list is inline instead), and the reader ships an empty
    #               <div id="imagesList"> that single-chapter.min.js hydrates,
    #               so page images have to be reverse-engineered first.
    #               Distinct from both mangaread.org and manhwaread.com.
    #   manhwa-18.com - Spanish-language adult blog on a bespoke WP theme.
    #               Flat: series and chapters are sibling root-level posts
    #               with nothing to key off, /manhwa/ and /episodio/ hold test
    #               junk, and a single chapter pulls its pages from
    #               imageshack.com, blogger.googleusercontent.com and
    #               2/4.bp.blogspot.com -- four allowlist entries of rot-prone
    #               hotlinks. Skip unless Spanish coverage is wanted.
    #
    # Also probed 2026-09-05 and DELIBERATELY NOT ADDED. Do not re-add without
    # re-probing from the VPS:
    #   mangazin.org - works, but it is mangatop.org's weaker twin rather than
    #               a second source. Listing pages 1+2 share 23 of 25 slugs
    #               with it, both hotlink manhuatop.org theme assets, and the
    #               same chapter resolves to the same storage path
    #               (manga_6ed26d1f…/chapter_0/ch_0_1.jpg) on both, differing
    #               only in CDN hostname. Where mangatop returned 9/9 on
    #               sampled image fetches, mangazin's older chapters point at
    #               cdn-2.mangazin.org, which 404s every path tried — mangatop
    #               serves those same chapters fine from st-2.
    #   mangatx.cc - not Madara: Themesia (eplister/chapternum/bixbox, no
    #               wp-manga markup), so it needs a bespoke connector rather
    #               than a catalog line, and it would be mature=True (the
    #               front page leads with uncensored 18+ manhwa and the pages
    #               are hosted on manga18.us). Worth writing if someone wants
    #               it — the series page server-renders the complete chapter
    #               list (3876 chapters on Martial Peak, no ajax) and the
    #               reader emits plain <img src>. The blocker is discovery:
    #               no working listing pagination was found (/manga-list/ tops
    #               out at 43 series, page 2 302s to the homepage) and /?s=
    #               returns a link set indistinguishable from the homepage's.
    #   manhuagui.com - custom Chinese CMS (Kanmanhua), not WordPress. Deep,
    #               general-audience, and it answers the VPS cleanly from a
    #               bare non-Cloudflare origin, but the reader ships ~7KB of
    #               packed JS (window["\x65\x76\x61\x6c"], SMH.imgData) and the
    #               i.hamreus.com URLs it unpacks to carry signed query
    #               params, so pages cannot be scraped with the regex every
    #               Madara source uses. Needs a JS unpacker plus signature
    #               handling.

    # Added 2026-09-05 after an end-to-end probe from the VPS. Madara
    # (themes/madara + madara-child) on url_segment "adult-comics": this install
    # answers 200 with the 100815-byte homepage for every unknown path, so the
    # segment had to be read off real series hrefs rather than probed. Chapters
    # are inline on the series page (its relative ajax/chapters/ endpoint 400s),
    # which the connector's inline fallback already covers, and every page image
    # is on comicsvalley.com itself. Left at use_cf=True: the homepage is served
    # from Cloudflare APO cache, so a plain client clearing a cache HIT says
    # nothing about what a MISS would do.
    #
    # NOT a second registration of the hand-crafted ``comicsvalley`` connector:
    # that one reads comicsvalley.NET (/manga/, manga-genre taxonomies,
    # translated doujin/manhwa). This is a separate WordPress install by the
    # same operator - comic-genre/comic-tag taxonomies, western/Indian 3DX
    # library, and .com slugs 302 on .net. The display name carries the TLD
    # because the operator brands both sites "Comics Valley".
    _site("comicsvalleycom", "ComicsValley (.com)", "comicsvalley.com", url_segment="adult-comics", mature=True),
    # Stock Madara on url_segment "porncomic" (/manga/ 404s). admin-ajax
    # answers manga_get_chapters with 400, so the connector settles on the
    # relative ``{series}/ajax/chapters/`` shape after one probe, exactly like
    # mangasushi; plain httpx cleared every stage from the OVH egress with no
    # challenge, so use_cf=False buys the cheaper client. Covers and page images
    # are all self-hosted, so the host-derived allowlist covers them.
    _site("gedecomix", "GEDE Comix", "gedecomix.com", url_segment="porncomic", mature=True, use_cf=False),

    # Added 2026-09-05 after an end-to-end probe from the VPS. All three are
    # genuine Madara (wp-content/themes/madara, /manga/ series pages,
    # wp-manga-chapter-img readers) that cleared browse, search, detail,
    # chapter and page-image bytes on plain httpx with no challenge at any
    # stage, so use_cf=False buys the cheaper client. Each serves its own
    # page images out of /wp-content/uploads/WP-manga/data/, so the
    # host-derived allowlist already covers them and no extra_image_hosts are
    # needed. All three are adult catalogues end to end (Smut/Yaoi/Uncensored
    # throughout; mangahe bills itself "Read Free Hentai Manga Here"), so
    # mature=True is load-bearing here, not cosmetic. mangafree.info probed
    # the same way in the same pass and is already registered above.
    #
    # Per-site quirks worth knowing before debugging one of them:
    #   manga18free - the reader emits its page image src with an http://
    #               scheme that 301s to https on the same host (mangafree
    #               above does the same). The allowlist matches on host so the
    #               proxy still permits it, but the fetcher has to follow that
    #               redirect or it stores the 301 body instead of the bytes.
    #   mangaforfree - the relative {series}/ajax/chapters/ route soft-404s
    #               with the whole detail page (91887 bytes), so the chapter
    #               list has to come from admin-ajax manga_get_chapters. The
    #               two-shape probe settles there on its own; this is the
    #               mirror image of the mangasushi note above.
    #   mangahe - series slugs are numeric (/manga/49241/) rather than word
    #               slugs. Fine while the connector follows hrefs, but nothing
    #               may derive a slug from a title for this source.
    _site("manga18free", "Manga18Free", "manga18free.com", mature=True, use_cf=False),
    _site("mangaforfree", "MangaForFree", "mangaforfree.com", mature=True, use_cf=False),
    _site("mangahe", "MangaHe", "mangahe.com", mature=True, use_cf=False),
    # Probed in the same pass 2026-09-05 and DELIBERATELY NOT ADDED. All four
    # are reachable from the VPS; none of them is a catalog line:
    #   magustoon.org - not Madara at all (bespoke SSR JS app: /auth/signin,
    #               /_vcomics, page images on storage.magustoon.org, wsrv.nl
    #               as a thumbnail proxy). It is also a coin-gated store - one
    #               sampled chapter list carried 31 "locked" markers, 14
    #               "Locked" labels, 21 "Purchase" buttons and "Login
    #               Required" - and the catalogue is novel-weighted. Would be
    #               a bespoke connector for a mostly paywalled library. It is
    #               general-audience romance/fantasy, so if it is ever added
    #               it must NOT carry the mature flag.
    #   mangadass.com / mangadna.com - one shared custom PHP + client-side JS
    #               engine (identical asset fingerprint; they borrow Madara's
    #               page-item-detail class name and nothing else - no
    #               wp-content, no admin-ajax, no WordPress). Both read
    #               cleanly with plain curl and both are adult, so they are
    #               worth a bespoke connector later - one connector serves
    #               both - but their page images live on img01.mangadass.com
    #               and cdn01.mangadna.com, which the SSRF allowlist would
    #               need, and homepage listings are JS-rendered so browse has
    #               to go through /manga and /manga-genre/{g}.
    #   mangadrama.com - WordPress on the init-manga theme, Madara-lookalike
    #               but not Madara, and coin-paywalled: WooCommerce loads on
    #               chapter pages and the i18n blob carries "Chapter unlocked
    #               successfully" / "Insufficient balance". Two series'
    #               chapter-1 pages fetched 155KB each and neither contained a
    #               single page image. There is nothing readable to scrape
    #               anonymously, whatever connector it got.


    # Added 2026-09-05 after an end-to-end probe from the VPS. It was probed
    # alongside rawdex, which was removed 2026-09-05 (see the header record).
    # A real Madara install whose /wp-admin/admin-ajax.php answers
    # manga_get_chapters with 400, so the connector settles on the per-series
    # ``{series}/ajax/chapters/`` shape after one probe, exactly like
    # mangasushi above. Cloudflare fronts it but never challenged the egress,
    # so use_cf=False buys the cheaper client. Unambiguously adult: its own
    # <title> is "Read Hot Smut Yaoi manga and manhwa in English Free".
    #
    # petrotechsociety.org is a repurposed domain (it reads like a former
    # petroleum-industry society), so the branding may churn — health-check it
    # before a release. Its apex 301s to www, hence the host below.
    _site(
        "petrotechsociety",
        "PetroTechSociety",
        "www.petrotechsociety.org",
        mature=True,
        use_cf=False,
        extra_image_hosts=frozenset({"space.petrotechsociety.org"}),
    ),
    # Probed 2026-09-05 and DELIBERATELY NOT ADDED — both are genuine Madara and
    # reachable, but both default to Madara *paged* reading, where a plain
    # chapter GET renders exactly one <img class="wp-manga-chapter-img">
    # (data-image-paged="0"). MadaraHtml.parse_chapter_pages only falls back to
    # the chapter_preloaded_images array when it finds *no* img tag, so that one
    # tag wins and every chapter would read as a single credits page. Appending
    # ?style=list returns the full set (decadencescans housekibako ch1: 1 -> 15;
    # seraphic bitter-x-sweet ch1: 1 -> 15, heartless ch1: 41), but the
    # wpmanga-reading-style cookie does not, so these need a per-site
    # chapter-query knob on MadaraSiteConfig before they can be catalogued:
    #   reader.decadencescans.com - josei/shoujo scanlation, ~80-90 series.
    #   seraphic-deviltry.com     - adult BL, ~36 series, LiteSpeed, no CF.
    #
    # Probed 2026-09-05 and NOT catalogable at all — none is Madara or Themesia,
    # so each needs a hand-written connector rather than a catalog line:
    #   o1ee.com        - bespoke Chinese-language CMS on obfuscated /eeil/
    #                     routes, images on res.44q4.com, /symoh/verify age gate.
    #   saymanhwa.com   - custom server-rendered app, locale-prefixed
    #                     /en/series/<slug>, images on img.saymanhwa.com; check
    #                     how much of the library sits behind its /en/vip tier
    #                     before anyone invests in a connector.
    #   schale.network  - JSON-API SPA (same backend as shupogaki.moe; register
    #                     only one). Browse/detail are free, but reader pages
    #                     come from /books/data/...?crt=<clearance>, computed
    #                     client-side by the bundle's dr.Clearance routine, and
    #                     images rotate across six *.erocdn.net shards.
    #   templetoons.com - Next.js SPA; only /comics and /comic/<slug> exist,
    #                     images on media.templetoons.com.
    # --- Shard 1, probed from the VPS 2026-09-05 ---------------------------
    # Six of this shard's nine sites are reachable and real but are NOT Madara,
    # so none of them can be a catalog line; each needs bespoke connector code.
    # Recorded here so they are not re-probed from scratch:
    #   18mh.net       - bespoke PHP/ZUI, /comic/detail/<id> + /comic/chapter/
    #                    <id>/<n>. Works end to end, but page image URLs are
    #                    time-signed (xi.dzuxta.cn ?auth_key=<ts>-0-0-<md5>),
    #                    so they must be read fresh per chapter. Best adult
    #                    connector candidate in the shard.
    #   9hentai.so     - Laravel + Vue SPA over a public JSON API (POST
    #                    /api/getBook). Fully working from the OVH egress, no
    #                    challenge; an nhentai-shaped connector plus
    #                    i.9hentai.so in the allowlist would land it.
    #   asmotoon.com   - in-house SPA, /series/<slug> + /chapter/<hex>-<hex>.
    #                    /library lists all 225 series in one request, but page
    #                    images are bare relative .avif names behind the
    #                    wsrv.nl proxy and some chapters sit behind a coin gate.
    #   boylove.cc     - ThinkPHP-style Chinese BL site; the chapter list is
    #                    fetched client-side, so the XHR has to be found first.
    #   55comic.com    - UNADDABLE, not merely bespoke: its imageSite bucket
    #                    prefix no longer holds the objects, so every cover and
    #                    every page 404s with NoSuchKey, and merge_img.js
    #                    reassembles each page from vertical slices on a canvas
    #                    that our image proxy cannot descramble.
    #
    # Genuine Madara (wp-content/themes/madara + madara-child) with
    # comic-genre/comic-author taxonomies, hence url_segment "comic". Chapters
    # come from the relative ``{series}/ajax/chapters/`` endpoint, the same
    # shape as mangasushi. Plain httpx cleared browse, detail, chapters and a
    # 1.17MB page image from the OVH egress, so use_cf=False; covers and page
    # images are all on allporncomics.co itself, so no extra_image_hosts.
    # Rapid sequential paging earned a 429 at page 10, so keep rates modest.
    #
    # Two near-misses that are deliberately not treated as duplicates. It is
    # not the `allporncomic` entry above - that is allporncomic.com, Western
    # porn comics under /porncomic/, zero slug overlap with this Korean adult
    # manhwa under /comic/. It IS the host the `comicsvalley` connector already
    # borrows as its reader (comicsvalley/mappers.py READER_BASE), but browsing
    # it directly is worth its own entry: across the first 3 listing pages the
    # two share only 11 of ~72 slugs, and comicsvalley.net bottoms out at 2
    # pages of listing against 5+ here.
    _site("allporncomicsco", "AllPornComics (.co)", "allporncomics.co", url_segment="comic", mature=True, use_cf=False),
    # Stock Madara under /read/; admin-ajax answers manga_get_chapters with
    # 400, so the connector settles on ``{series}/ajax/chapters/``. The image
    # CDN is the opaque 3r21zkocdpp9f subdomain rather than anything derived
    # from the site host, and it serves the covers (/book_thumbnail/) as well
    # as the pages, so without it in extra_image_hosts the proxy's SSRF
    # allowlist rejects every image the source has. It is a config value and
    # not a per-response token: the same subdomain came back across repeated
    # fetches from two different egresses, resolving to the apex's own
    # Cloudflare IPs. book-genre/book-author taxonomies hint at a custom post
    # type, but /read/ and /read/page/2/ both paginate without a
    # listing_post_type override, so it stays None.
    _site("doujindistrict", "Doujin District", "doujindistrict.com", url_segment="read", mature=True, use_cf=False, extra_image_hosts=frozenset({"3r21zkocdpp9f.doujindistrict.com"})),
    # base_url carries the www host deliberately: the apex 302s to it, so
    # registering doujinhq.club would make every single request pay a
    # redirect. Series live under /dj/ (/read/ and /series/ both 404); /manga/
    # also answers 200 but that is the theme's catch-all, not the series
    # archive. The detail page ships no inline chapter list, only /feed/, so
    # ``{series}/ajax/chapters/`` is the only route to them - it works. Page
    # images are lazyloaded from cdn.doujinhq.club, so the extractor reads
    # data-src and the allowlist needs that host.
    _site("doujinhq", "DoujinHQ", "www.doujinhq.club", url_segment="dj", mature=True, use_cf=False, extra_image_hosts=frozenset({"cdn.doujinhq.club"})),
    # Added 2026-09-05. Stock Madara sitting behind Cloudflare -- every hit
    # from the VPS comes back with a cf-ray -- so it keeps the impersonating
    # client. Yaoi/yuri/hentai webtoons, hence mature. Page images live on
    # yaoihub.org itself under /wp-content/uploads/WP-manga/data/, so the
    # host-derived allowlist already covers them. LiteSpeed Cache lazyloads
    # them, but the extractor already reads data-src and trims the whitespace
    # this install leaves inside the attribute value.
    _site("yaoihub", "YaoiHub", "yaoihub.org", mature=True),
    # Added 2026-09-05 after an end-to-end probe from the VPS. Two independent
    # English BL/yaoi smut Madara installs (themes/madara plus a child theme)
    # that cleared browse, wp-manga-search-manga, detail, chapter and page
    # image bytes. Both apexes 301 to their www host, so the www name is the
    # base_url or every request pays a redirect first. Adult end to end --
    # orchisasia titles itself "Read Hottest Smut Yaoi BL Manhwa & Manga for
    # Free", paritehaber "Yaoi BL Smut Manhwa Manga Webtoon English" -- so
    # mature=True is load-bearing here, not cosmetic. They are not mirrors of
    # each other: no real slug overlap and different page-image storage.
    #
    # Left at use_cf=True on both. Plain curl cleared browse, admin-ajax search
    # and a 89-image chapter page from a non-VPS egress, but no plain-httpx
    # pass was recorded from the OVH container, and both zones are Cloudflare
    # -fronted; flip to use_cf=False if the cheaper client is ever wanted.
    #
    # orchisasia serves page images off cdn.orchisasia.org (89 of them in the
    # sampled chapter) while covers stay on the site host, so without that
    # extra host the image proxy's allowlist rejects every page before it is
    # requested. Its segment is "comic", not the default.
    _site(
        "orchisasia",
        "Orchisasia",
        "www.orchisasia.org",
        url_segment="comic",
        mature=True,
        extra_image_hosts=frozenset({"cdn.orchisasia.org"}),
    ),
    # Everything is self-hosted under /wp-content/uploads/WP-manga/ on the site
    # host, so no extra_image_hosts. Chapter slugs are numbered oddities
    # ("no-0012-therapy-session-012-being-happy") but they are ordinary Madara
    # child posts, so the stock factory handles them. Despite the Turkish
    # finance-sounding domain this is a genuine English BL manhwa reader.
    _site("paritehaber", "Paritehaber", "www.paritehaber.com", mature=True),
    #
    # Probed alongside those two on 2026-09-05 and DELIBERATELY NOT ADDED. All
    # six are reachable and real; none is a catalog line. Do not re-add without
    # re-probing from the VPS:
    #   octopusmanga.com - the trap of the batch. Genuine Madara and every
    #               stage up to the chapter page works, but the install runs
    #               wp-manga-chapter-images-protection: chapter HTML carries
    #               ZERO wp-manga-chapter-img tags and instead ships an
    #               AES/CryptoJS blob (chapter-protector-data +
    #               wpmangaprotectornonce) decrypted client-side, leaving only
    #               empty page-break placeholders. Confirmed on two chapters,
    #               so it is site-wide. A stock line here yields a source whose
    #               every chapter opens to zero pages. Its archive also lives
    #               at /manga-2/, so it would need a route override too. Adult
    #               (Yaoi/Smut/Mature) if anyone ever writes the decryption.
    #   multporn.net - Drupal, not WordPress (/sites/ asset paths, xmlns:og on
    #               <html>, no wp-content anywhere). Large real catalogue at
    #               /manga, /comics and /alphabetical_order_manga/A..Z, all
    #               images self-hosted. Bespoke connector, not a config line.
    #   nhentai.xxx - custom PHP, and verified NOT an nhentai.net mirror: the
    #               same /g/546000/ id resolves to a different work on each, so
    #               it does not duplicate the hand-crafted ``nhentai`` source.
    #               Fully server-rendered, no challenge on any path, image
    #               bytes fetch with a site Referer. Worth a bespoke connector
    #               on the ehentai/hentaifox template; its SSRF allowlist would
    #               need the whole i1-i5.nhentaimg.com shard set.
    #   myhentaigallery.com - custom PHP (/gallery/thumbnails/{id},
    #               /a/category/{id}, /page/{n}). Real and fully server
    #               rendered, no challenge, but bespoke; its CDN is
    #               cdn.myhentaicomics.com and the image path embeds the
    #               human-readable title WITH SPACES, so any connector must
    #               URL-encode path segments rather than pass them through.
    #   onlythebesthentai.com - plain WordPress on the generic Neve theme, no
    #               wp-manga markup and no admin-ajax chapter loading, so the
    #               Madara factory cannot touch it. Doujin posts sit flat at
    #               the site root (/<slug>/), i.e. gallery-per-post rather than
    #               series+chapters, which fits the app's model poorly.
    #   manhwazone.com - Laravel + Vite, not WordPress. Real catalogue
    #               (/explore, a 76-genre taxonomy) and MIXED, not general
    #               audience: hentai/erotica/ecchi sit alongside shounen, so it
    #               would be mature=True. Expensive and not recommended: the
    #               series page server-renders metadata but ZERO chapter
    #               hrefs (chapter list is client-side, /api/series 404s), so
    #               the endpoint has to be reverse-engineered out of the Vite
    #               bundle -- and an unrendered `item.web_url ?? (` template
    #               literal leaks into hrefs, hinting part of the catalogue
    #               links out to third-party hosts. Owner decision before
    #               anyone spends connector time on it.
    # Added 2026-09-05 after an end-to-end probe from the VPS and a second
    # pass from this workstation. Two unrelated adult Madara installs, slug
    # sets disjoint from each other and from every registered source. Plain
    # curl cleared apex, listing, series, chapter and image bytes on both, so
    # use_cf=False buys the cheaper client.
    #
    # HentaiSco REMOVED 2026-09-09 after an end-to-end sweep of every
    # registered connector. It is not down and it is not blocked -- it stopped
    # being a Madara site. Two changes, found in that order:
    #
    #   1. It is behind a Cloudflare challenge now (``cf-mitigated: challenge``
    #      on the apex), which the entry's ``use_cf=False`` cannot clear. That
    #      part was a one-word fix and the CF client did clear it.
    #   2. Underneath, the site has been rebuilt as a JavaScript app. The
    #      archive moved from /hentai/ to /hentai-list/, and that page is 93 KB
    #      of bundle references (/build/assets/) with ZERO ``wp-manga`` markers
    #      and no series links in the HTML. /manga/ and /webtoon/ 404;
    #      /wp-json/ 301s away; no JSON API answers on the obvious paths.
    #
    # So the Madara reader cannot see anything here whatever the client does.
    # Re-adding it means writing a new connector against whatever API that
    # bundle talks to, the way aurorascans reads QiManga -- not restoring this
    # line. Everything else in this catalog was verified working end to end in
    # the same sweep.
    # HentaiSyaoi names Madara in its generator meta and is the plain case:
    # /manga/ segment, chapters from the per-series ``{series}/ajax/chapters/``
    # endpoint (admin-ajax answers manga_get_chapters with 400, so the
    # connector settles on the relative shape after one probe), page images
    # self-hosted under /wp-content/uploads/WP-manga/data/. Yaoi doujinshi,
    # mostly oneshots.
    _site("hentaisyaoi", "HentaiSyaoi", "hentaisyaoi.com", mature=True, use_cf=False),
    # Probed alongside those two on 2026-09-05 and DELIBERATELY NOT ADDED:
    #   hentai4free.net - fingerprints as Madara from the outside (104
    #               "madara" and 588 "wp-manga" markers, /hentai/ segment, and
    #               a bare /hentai/ that 302s onto one series, so it would
    #               have needed listing_post_type="wp-manga"), but the
    #               operator replaced the reader with an in-house plugin,
    #               h4f-reader-engine-v2. Chapter pages carry ZERO
    #               wp-manga-chapter-img tags, no chapter_preloaded_images and
    #               no reading-content div -- the 29 page images sit in a
    #               <script type="application/json" id="h4f-r2-data"> blob the
    #               reader hydrates from. All three strategies in
    #               parse_chapter_pages miss it, so a stock line here yields a
    #               source that browses and lists chapters and then opens
    #               every chapter to zero pages. Confirmed on two chapters and
    #               under ?style=list, so it is site-wide. The images are on
    #               hentai4free.net itself under the usual
    #               /wp-content/uploads/WP-manga/data/ path, so one more
    #               fallback in madara/mappers.py would land it -- a connector
    #               change, not a catalog line. Adult throughout.
)
# fmt: on

# Alias — entire catalog is production-safe after prune.
MADARA_LIVE: frozenset[str] = frozenset(s.source_id for s in MADARA_CATALOG)

HANDCRAFTED_CONNECTORS: frozenset[str] = frozenset({
    "mangadex", "asurascans", "mangakatana", "demonicscans", "nhentai",
    "18porncomic", "3hentai", "8muses", "akuma", "asmhentai", "aurorascans", "beehentai",
    "baozimh", "comicasura", "comicsvalley", "comicland", "doujins", "ehentai", "elftoon", "flamescans",
    "freeadultcomix", "galaxymanga", "hentai20", "hentaifox", "hentaiera",
    "webtoons", "weebcentral", "tapas",
})
