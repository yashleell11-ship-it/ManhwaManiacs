"""Madara catalog additions from the 2026-09-05 fingerprint sweep.

Four domains arrived labelled "fingerprints as a Madara-theme WordPress site":
kingofshojo.com, mangaeffect.com, mangagg.com and mangasushi.org. Probed
end-to-end from the production VPS container, only mangasushi.org actually
behaves like one, so it is the only catalog line added. The other three are
pinned out by ``test_withdrawn_domains_stay_out_of_the_catalog``, which carries
the reason each one was rejected so a later sweep does not re-add them blind.

Every HTML constant below is a verbatim slice of a page fetched from the VPS on
2026-09-05 -- the /manga/ listing, a ?s= search, a series detail page, the
POST ``{series}/ajax/chapters/`` fragment and a chapter reader. Whole sibling
blocks were dropped to keep the file readable; no markup was rewritten, so the
Madara parsers here run against the theme's real output.

Fail-first evidence, gathered by breaking the fixtures one at a time and
watching this file go red before the assertions were trusted:

* ``/manga/`` -> ``/mangaX/`` in LISTING_HTML, SEARCH_HTML and
  AJAX_CHAPTERS_HTML (defeats every card/chapter anchor regex at once) failed
  the browse, search and chapter tests respectively -- the AJAX break also
  took down both speed tests.
* ``<img`` -> ``<imgX`` in READER_HTML failed the page/find_page test.
* ``post-title`` and ``og:title`` broken in SERIES_HTML failed the detail test.
* Value-level breaks each failed the test that reads them: a changed og:image
  URL and a changed author in SERIES_HTML, ``chapter-74`` -> ``chapter-99`` in
  AJAX_CHAPTERS_HTML, the image host swapped to ``evil.test`` in READER_HTML,
  and a changed series slug in LISTING_HTML.
* Deleting the mangasushi line from the catalog failed 12 of these tests, and
  adding a mangagg line back failed the withdrawal guard.

Worth knowing for the next person: corrupting a single CSS class name is NOT
enough to fail these tests. ``MadaraHtml`` carries loose fallback regexes
(``_card_anchor_loose``, ``_chapter_item_link``, ``_plain_img_src``), so
renaming ``page-item-detail``, ``c-tabs-item__content``, ``wp-manga-chapter``
or ``reading-content`` alone left all 14 tests green. Breaking the href/img
shape is what actually defeats the parser.
"""

from __future__ import annotations

from contextlib import contextmanager
from typing import Any
from unittest.mock import patch

import pytest

from connectors.catalog import MADARA_CATALOG
from connectors.http.client import ConnectorHttpError
from connectors.http.redirect_policy import host_matches_allowlist
from connectors.madara.factory import build_madara_connector_class
from connectors.registry import create_connector, list_installed_connectors

SERIES_ID = "kanzen-kaihi-healer-no-kiseki"
CHAPTER_ID = f"{SERIES_ID}/chapter-36-1"
OTHER_SERIES_ID = (
    "isekai-ni-shoukan-saretan-dakedo-nandemo-kireteshimau-kennou-wo-teni-"
    "ireta-node-easy-mode-deshita"
)

LISTING_HTML = """\
<div class="page-content-listing">
<div class="page-item-detail manga  ">
				                <div id="manga-item-2140" class="item-thumb hover-details c-image-hover" data-post-id="2140">
					                            <a href="https://mangasushi.org/manga/isekai-ni-shoukan-saretan-dakedo-nandemo-kireteshimau-kennou-wo-teni-ireta-node-easy-mode-deshita/" title="Isekai Ni Shoukan Saretan dakedo, Nandemo Kireteshimau Kennou wo Teni Ireta node Easy Mode Deshita">
								<img width="110" height="150"  data-src="https://mangasushi.org/wp-content/uploads/2023/12/isekai-ni-shoukan-110x150.jpg" data-srcset="https://mangasushi.org/wp-content/uploads/2023/12/isekai-ni-shoukan-110x150.jpg 110w, https://mangasushi.org/wp-content/uploads/2023/12/isekai-ni-shoukan-175x238.jpg 175w" data-sizes="(max-width: 110px) 100vw, 110px" class="img-responsive lazyload effect-fade" src="https://mangasushi.org/wp-content/themes/madara/images/dflazy.jpg"  style="padding-top:150px;"  alt="isekai-ni-shoukan"/>                            </a>
							                </div>
                <div class="item-summary">
                    <div class="post-title font-title">
                        <h3 class="h5">
																						                            <a href="https://mangasushi.org/manga/isekai-ni-shoukan-saretan-dakedo-nandemo-kireteshimau-kennou-wo-teni-ireta-node-easy-mode-deshita/">Isekai Ni Shoukan Saretan dakedo, Nandemo Kireteshimau Kennou wo Teni Ireta node Easy Mode Deshita</a>
                        </h3>
                    </div>
                    <div class="meta-item rating">
						<div class="post-total-rating allow_vote"><i class="ion-ios-star ratings_stars rating_current"></i><i class="ion-ios-star ratings_stars rating_current"></i><i class="ion-ios-star ratings_stars rating_current"></i><i class="ion-ios-star ratings_stars rating_current"></i><i class="ion-ios-star-half ratings_stars rating_current_half"></i><span class="score font-meta total_votes">4.5</span></div>                    </div>
                    <div class="list-chapter">
						                    <div class="chapter-item ">

						                        <span class="chapter font-meta">
							<a href="https://mangasushi.org/manga/isekai-ni-shoukan-saretan-dakedo-nandemo-kireteshimau-kennou-wo-teni-ireta-node-easy-mode-deshita/chapter-27/" class="btn-link"> Chapter 27 </a>
						</span>
												
														<span class="post-on font-meta">
									4 hours ago								</span>
								                    </div>
					                    <div class="chapter-item ">

						                        <span class="chapter font-meta">
							<a href="https://mangasushi.org/manga/isekai-ni-shoukan-saretan-dakedo-nandemo-kireteshimau-kennou-wo-teni-ireta-node-easy-mode-deshita/chapter-26/" class="btn-link"> Chapter 26 </a>
						</span>
												
														<span class="post-on font-meta">
									July 13, 2026								</span>
								                    </div>
					                    </div>
                </div>
				
				            </div>

        </div>
		
        <div class="col-12 col-md-6 badge-pos-1">
            <div class="page-item-detail manga  ">
				                <div id="manga-item-1903" class="item-thumb hover-details c-image-hover" data-post-id="1903">
					                            <a href="https://mangasushi.org/manga/kanzen-kaihi-healer-no-kiseki/" title="Kanzen Kaihi Healer no Kiseki">
								<img width="110" height="150"  data-src="https://mangasushi.org/wp-content/uploads/2022/01/kanzen-1-110x150.jpg" data-srcset="https://mangasushi.org/wp-content/uploads/2022/01/kanzen-1-110x150.jpg 110w, https://mangasushi.org/wp-content/uploads/2022/01/kanzen-1-175x238.jpg 175w, https://mangasushi.org/wp-content/uploads/2022/01/kanzen-1-350x476.jpg 350w" data-sizes="(max-width: 110px) 100vw, 110px" class="img-responsive lazyload effect-fade" src="https://mangasushi.org/wp-content/themes/madara/images/dflazy.jpg"  style="padding-top:150px;"  alt="kanzen"/>                            </a>
							                </div>
                <div class="item-summary">
                    <div class="post-title font-title">
                        <h3 class="h5">
																						                            <a href="https://mangasushi.org/manga/kanzen-kaihi-healer-no-kiseki/">Kanzen Kaihi Healer no Kiseki</a>
                        </h3>
                    </div>
                    <div class="meta-item rating">
						<div class="post-total-rating allow_vote"><i class="ion-ios-star ratings_stars rating_current"></i><i class="ion-ios-star ratings_stars rating_current"></i><i class="ion-ios-star ratings_stars rating_current"></i><i class="ion-ios-star ratings_stars rating_current"></i><i class="ion-ios-star-half ratings_stars rating_current_half"></i><span class="score font-meta total_votes">4.3</span></div>                    </div>
                    <div class="list-chapter">
						                    <div class="chapter-item ">

						                        <span class="chapter font-meta">
							<a href="https://mangasushi.org/manga/kanzen-kaihi-healer-no-kiseki/chapter-74/" class="btn-link"> Chapter 74 </a>
						</span>
												
														<span class="post-on font-meta">
									September 1, 2026								</span>
								                    </div>
					                    <div class="chapter-item ">

						                        <span class="chapter font-meta">
							<a href="https://mangasushi.org/manga/kanzen-kaihi-healer-no-kiseki/chapter-73/" class="btn-link"> Chapter 73 </a>
						</span>
												
														<span class="post-on font-meta">
									July 20, 2026								</span>
								                    </div>
					                    </div>
                </div>
				
				            </div>

        </div>
		    </div>
</div>
<div class="page-listing-item">
    <div class="row row-eq-height">
		
        <div class="col-12 col-md-6 badge-pos-1">
            
</div>
"""

SEARCH_HTML = """\
<div class="c-tabs-item">
<div class="row c-tabs-item__content">
    <div class="col-4 col-md-2">
        <div class="tab-thumb c-image-hover">
			                    <a href="https://mangasushi.org/manga/kanzen-kaihi-healer-no-kiseki/" title="Kanzen Kaihi Healer no Kiseki">
						<img width="193" height="278"  data-src="https://mangasushi.org/wp-content/uploads/2022/01/kanzen-1-193x278.jpg" data-srcset="https://mangasushi.org/wp-content/uploads/2022/01/kanzen-1-193x278.jpg 193w, https://mangasushi.org/wp-content/uploads/2022/01/kanzen-1-125x180.jpg 125w" data-sizes="(max-width: 193px) 100vw, 193px" class="img-responsive lazyload effect-fade" src="https://mangasushi.org/wp-content/themes/madara/images/dflazy.jpg"  style="padding-top:278px;"  alt="kanzen"/>                    </a>
					        </div>
    </div>
    <div class="col-8 col-md-10">
        <div class="tab-summary">
            <div class="post-title">
                <h3 class="h4"><a href="https://mangasushi.org/manga/kanzen-kaihi-healer-no-kiseki/">Kanzen Kaihi Healer no Kiseki</a></h3>
            </div>
            <div class="post-content">
				
                        <div class="post-content_item mg_alternative ">
                            <div class="summary-heading">
                                <h5>
									Alternative                                </h5>
                            </div>
                            <div class="summary-content">
								The Path of the Perfect Evasion Healer, 完全回避ヒーラーの軌跡                            </div>
                        </div>

										                        <div class="post-content_item mg_author ">
                            <div class="summary-heading">
                                <h5>
									Authors                                </h5>
                            </div>
                            <div class="summary-content">
								<a href="https://mangasushi.org/manga-author/puni-chan/">Puni-Chan</a>                            </div>
                        </div>
						
				                        <div class="post-content_item mg_artists ">
                            <div class="summary-heading">
                                <h5>
									Artists                                </h5>
                            </div>

                            <div class="summary-content">
								<a href="https://mangasushi.org/manga-artist/yamato-hina/">Yamato Hina</a>                            </div>
                        </div>
										                        <div class="post-content_item mg_genres ">
                            <div class="summary-heading">
                                <h5>
									Genres                                </h5>
                            </div>
                            <div class="summary-content">
								<a href="https://mangasushi.org/manga-genre/action/">Action</a>, <a href="https://mangasushi.org/manga-genre/adventure/">Adventure</a>, <a href="https://mangasushi.org/manga-genre/comedy/">Comedy</a>, <a href="https://mangasushi.org/manga-genre/drama/">Drama</a>, <a href="https://mangasushi.org/manga-genre/fantasy/">Fantasy</a>, <a href="https://mangasushi.org/manga-genre/romance/">Romance</a>                            </div>
                        </div>
										                        <div class="post-content_item mg_status ">
                            <div class="summary-heading">
                                <h5>
									Status                                </h5>
                            </div>
                            <div class="summary-content">
								OnGoing                            </div>
                        </div>
										                        <div class="post-content_item mg_release ">
                            <div class="summary-heading">
                                <h5>
									Release                                </h5>
                            </div>
                            <div class="summary-content release-year">
								<a href="https://mangasushi.org/manga-release/2019/">2019</a>                            </div>
                        </div>
						            </div>
        </div>
        <div class="tab-meta">
			                    <div class="meta-item latest-chap">
						                            <span class="font-meta">Latest chapter </span>
                            <span class="font-meta chapter"><a href="https://mangasushi.org/manga/kanzen-kaihi-healer-no-kiseki/chapter-74/">Chapter 74</a></span>
						                    </div>
					                        <div class="meta-item post-on">
                            <span class="font-meta">2026-09-01 15:44:58</span>
                        </div>
						                    <div class="meta-item rating">
						<div class="post-total-rating allow_vote"><i class="ion-ios-star ratings_stars rating_current"></i><i class="ion-ios-star ratings_stars rating_current"></i><i class="ion-ios-star ratings_stars rating_current"></i><i class="ion-ios-star ratings_stars rating_current"></i><i class="ion-ios-star-half ratings_stars rating_current_half"></i><span class="score font-meta total_votes">4.3</span></div>                    </div>
					        </div>
    </div>
</div>
                                            </div>
											                                        </div>
                                    </div>
									                        </div>

						

                    </div>
                </div>
            </div>
        </div>
    </div>
        </div><!-- <div class="site-content"> -->

		
			
		
        
</div>
"""

SERIES_HTML = """\
<head>
<meta property="og:title" content="Kanzen Kaihi Healer no Kiseki"/>
<meta property="og:image" content="https://mangasushi.org/wp-content/uploads/2022/01/kanzen-1.jpg"/>
</head>
<div class="profile-manga summary-layout-1 lazy" style="" data-bg="https://mangasushi.org/wp-content/themes/madara/images/bg-search.jpg">
    <div class="container">
        <div class="row">
            <div class="col-12 col-sm-12 col-md-12">
				
        <div class="c-breadcrumb-wrapper" >

			
                        <div class="c-breadcrumb">
                            <ol class="breadcrumb">
                                <li>
                                    <a href="https://mangasushi.org/">
										Home                                    </a>
                                </li>
								                                <li>
                                    <a href="https://mangasushi.org/manga/">
										All Mangas                                    </a>
                                </li>
																
								                                            <li>
                                                <a href="https://mangasushi.org/manga-genre/action/">
													Action                                                </a>
                                            </li>
										
								                                    <li>
                                        <a href="https://mangasushi.org/manga/kanzen-kaihi-healer-no-kiseki/">
											Kanzen Kaihi Healer no Kiseki                                        </a>
                                    </li>
								
								
                            </ol>
                        </div>

																		        </div>

	                <div class="post-title">
                                        
                    <h1>
						Kanzen Kaihi Healer no Kiseki                    </h1>
                </div>
                <div class="tab-summary ">
                        <div class="summary_image">
        <a href="https://mangasushi.org/manga/kanzen-kaihi-healer-no-kiseki/">
            <img width="193" height="278"  data-src="https://mangasushi.org/wp-content/uploads/2022/01/kanzen-1-193x278.jpg" data-srcset="https://mangasushi.org/wp-content/uploads/2022/01/kanzen-1-193x278.jpg 193w, https://mangasushi.org/wp-content/uploads/2022/01/kanzen-1-125x180.jpg 125w" data-sizes="(max-width: 193px) 100vw, 193px" class="img-responsive lazyload effect-fade" src="https://mangasushi.org/wp-content/themes/madara/images/dflazy.jpg"  style="padding-top:278px;"  alt="kanzen"/>        </a>
    </div>
<div class="summary_content_wrap">
    <div class="summary_content">
        <div class="post-content">
            <div class="loader-inner ball-pulse">
    <div></div>
    <div></div>
    <div></div>
</div>            
            	 <div class="post-rating">
	<div class="post-total-rating allow_vote"><i class="ion-ios-star ratings_stars rating_current"></i><i class="ion-ios-star ratings_stars rating_current"></i><i class="ion-ios-star ratings_stars rating_current"></i><i class="ion-ios-star ratings_stars rating_current"></i><i class="ion-ios-star-half ratings_stars rating_current_half"></i><span class="score font-meta total_votes">4.3</span></div><div class="user-rating allow_vote"><i class="ion-ios-star-outline ratings_stars"></i><i class="ion-ios-star-outline ratings_stars"></i><i class="ion-ios-star-outline ratings_stars"></i><i class="ion-ios-star-outline ratings_stars"></i><i class="ion-ios-star-outline ratings_stars"></i><span class="score font-meta total_votes">Your Rating</span></div><input type="hidden" class="rating-post-id" value="1903"></div>

<div class="post-content_item">
	<div class="summary-heading">
		<h5>Rating</h5>
	</div>	
	<div class="summary-content vote-details" vocab="https://schema.org/" typeof="AggregateRating">
		<span property="itemReviewed" typeof="Book"><span class="rate-title" property="name" title="Kanzen Kaihi Healer no Kiseki">Kanzen Kaihi Healer no Kiseki</span></span><span> <span> Average <span property="ratingValue" id="averagerate"> 4.3</span> / <span property="bestRating">5</span> </span> </span> out of <span property="ratingCount" id="countrate">69</span>	</div>	
</div>
	 <div class="post-content_item">
	<div class="summary-heading">
		<h5>
			Rank		</h5>
	</div>
	<div class="summary-content">
		 6th, it has 2.2M monthly views	</div>
</div>
<div class="post-content_item">
	<div class="summary-heading">
		<h5>
			Alternative		</h5>
	</div>
	<div class="summary-content">
		The Path of the Perfect Evasion Healer, 完全回避ヒーラーの軌跡	</div>
</div>

<div class="post-content_item">
	<div class="summary-heading">
		<h5>
			Author(s)		</h5>
	</div>
	<div class="summary-content">
		<div class="author-content">
			<a href="https://mangasushi.org/manga-author/puni-chan/" rel="tag">Puni-Chan</a>		</div>
	</div>
</div>
<div class="post-content_item">
	<div class="summary-heading">
		<h5>
			Artist(s)		</h5>
	</div>
	<div class="summary-content">
		<div class="artist-content">
			<a href="https://mangasushi.org/manga-artist/yamato-hina/" rel="tag">Yamato Hina</a>		</div>
	</div>
</div>

<div class="post-content_item">
	<div class="summary-heading">
		<h5>
			Genre(s)		</h5>
	</div>
	<div class="summary-content">
		<div class="genres-content">
			<a href="https://mangasushi.org/manga-genre/action/" rel="tag">Action</a>, <a href="https://mangasushi.org/manga-genre/adventure/" rel="tag">Adventure</a>, <a href="https://mangasushi.org/manga-genre/comedy/" rel="tag">Comedy</a>, <a href="https://mangasushi.org/manga-genre/drama/" rel="tag">Drama</a>, <a href="https://mangasushi.org/manga-genre/fantasy/" rel="tag">Fantasy</a>, <a href="https://mangasushi.org/manga-genre/romance/" rel="tag">Romance</a>		</div>
	</div>
</div>

<div class="post-content_item">
	<div class="summary-heading">
		<h5>
			Type		</h5>
	</div>
	<div class="summary-content">
		Manga	</div>
</div>
            
                        
        </div>
        <div class="post-status">
        
            	 
	 <div class="post-content_item">
	<div class="summary-heading">
		<h5>
			Release		</h5>
	</div>
	<div class="summary-content">
		<a href="https://mangasushi.org/manga-release/2019/" rel="tag">2019</a>	</div>
</div>
<div class="post-content_item">
	<div class="summary-heading">
		<h5>
			Status		</h5>
	</div>
	<div class="summary-content">
		OnGoing	</div>
</div><div class="manga-action">
		<div class="count-comment">
		<div class="action_icon">
			<a href="#manga-discussion"><i class="icon ion-md-chatbubbles"></i></a>
		</div>
		<div class="action_detail">
							<span>2 comments</span>
					</div>
	</div>
			</div>
        </div>
        
        
<div id="init-links" class="nav-links">
				<a href="#" id="btn-read-last" class="c-btn c-btn_style-1">
			Read First</a>
			<a href="#" id="btn-read-first" class="c-btn c-btn_style-1">Read Last</a>
			</div>

    </div>
</div>                </div>
            </div>
        </div>
    </div>
</div>

<div class="c-page-content style-1">
    <div class="content-area">
        <div class="container">
            <div class="row ">
                <div class="main-col col-md-12 col-sm-12 sidebar-hidden">
                    <!-- container & no-sidebar-->
                    <div class="main-col-inner">
                        <div class="c-page">
                            <!-- <div class="c-page__inner"> -->
                            <div class="c-page__content">
                                
                                    
<div class="summary__content show-more">
                                            <div data-v-0f9c270b="">
<div class="readmore" data-v-f4058476="" data-v-0253f0b0="" data-v-0f9c270b="">
<div data-v-f4058476="">
<div class="py-2 text-sm !py-0" data-v-0253f0b0="" data-v-f4058476="">
<div class="md-md-container">
<p>A college student, Sakurai Hiroki was summoned to another world to defeat the Demon Lord. And since he got “Priest” as a job, his starting Recovery Stat was more than enough to heal any wounds, so he dumped all of his Stat Points into Evasion. In other words, he’s aiming for an Evasion Healer who will never get hit by enemy attacks. But unfortunately, people in that world couldn’t understand his ideal! The King got angry against him and labelled him as useless almost immediately! And thus, the story of how Hiroki become an odd Healer who can even avoid Dungeon Boss’ attacks with ease has started!!</p></div>
<div id="manga-chapters-holder" data-id="1903"><i class="fas fa-spinner fa-spin fa-3x"></i></div>
"""

AJAX_CHAPTERS_HTML = """\
<div class="listing-chapters_wrap">
<ul class="main version-chap no-volumn">
<li class="wp-manga-chapter    ">
																
								<a href="https://mangasushi.org/manga/kanzen-kaihi-healer-no-kiseki/chapter-74/">
									Chapter 74								</a>

																	<span class="chapter-release-date">
										<i>September 1, 2026</i>									</span>
																
								
							</li>
							
						
							
<li class="wp-manga-chapter    ">
																
								<a href="https://mangasushi.org/manga/kanzen-kaihi-healer-no-kiseki/chapter-73/">
									Chapter 73								</a>

																	<span class="chapter-release-date">
										<i>July 20, 2026</i>									</span>
																
								
							</li>
							
						
							
<li class="wp-manga-chapter    ">
																
								<a href="https://mangasushi.org/manga/kanzen-kaihi-healer-no-kiseki/chapter-72/">
									Chapter 72								</a>

																	<span class="chapter-release-date">
										<i>June 23, 2026</i>									</span>
																
								
							</li>
							
						
							
<li class="wp-manga-chapter    ">
																
								<a href="https://mangasushi.org/manga/kanzen-kaihi-healer-no-kiseki/chapter-03/">
									Chapter 03								</a>

																	<span class="chapter-release-date">
										<i>January 17, 2022</i>									</span>
																
								
							</li>
							
						
							
<li class="wp-manga-chapter    ">
																
								<a href="https://mangasushi.org/manga/kanzen-kaihi-healer-no-kiseki/chapter-02/">
									Chapter 02								</a>

																	<span class="chapter-release-date">
										<i>January 17, 2022</i>									</span>
																
								
							</li>
							
						
							
<li class="wp-manga-chapter    ">
																
								<a href="https://mangasushi.org/manga/kanzen-kaihi-healer-no-kiseki/chapter-01/">
									Chapter 01								</a>

																	<span class="chapter-release-date">
										<i>January 17, 2022</i>									</span>
																
								
							</li>
							
						
						
							
</ul>
</div>
"""

READER_HTML = """\
<div class="reading-content">
<img id="image-0" data-src="			
			https://mangasushi.org/wp-content/uploads/WP-manga/data/manga_61e3ccac92767/cd9a03d7903c50d7c0221aa322ab502d/00.jpg" class="wp-manga-chapter-img img-responsive lazyload effect-fade">
<img id="image-1" data-src="			
			https://mangasushi.org/wp-content/uploads/WP-manga/data/manga_61e3ccac92767/cd9a03d7903c50d7c0221aa322ab502d/01.jpg" class="wp-manga-chapter-img img-responsive lazyload effect-fade">
<img id="image-2" data-src="			
			https://mangasushi.org/wp-content/uploads/WP-manga/data/manga_61e3ccac92767/cd9a03d7903c50d7c0221aa322ab502d/02-3.jpg" class="wp-manga-chapter-img img-responsive lazyload effect-fade">
<img id="image-3" data-src="			
			https://mangasushi.org/wp-content/uploads/WP-manga/data/manga_61e3ccac92767/cd9a03d7903c50d7c0221aa322ab502d/04.jpg" class="wp-manga-chapter-img img-responsive lazyload effect-fade">
<img id="image-16" data-src="			
			https://mangasushi.org/wp-content/uploads/WP-manga/data/manga_61e3ccac92767/cd9a03d7903c50d7c0221aa322ab502d/17.jpg" class="wp-manga-chapter-img img-responsive lazyload effect-fade">
</div>
"""


def _config(source_id: str):
    for cfg in MADARA_CATALOG:
        if cfg.source_id == source_id:
            return cfg
    return None


def _fresh_connector():
    """A connector instance nobody else has warmed.

    ``create_connector`` hands out a shared singleton, and this connector
    remembers per-site facts (the AJAX chapter shape, series/page caches). The
    tests below assert on how many requests a flow costs, so they need an
    instance with cold caches.
    """
    cfg = _config("mangasushi")
    assert cfg is not None, "mangasushi missing from MADARA_CATALOG"
    return build_madara_connector_class(cfg)()


@contextmanager
def _mock_live_html(connector, *, series_html: str = SERIES_HTML):
    """Serve the VPS captures and record every request the connector makes.

    ``post_text`` reproduces what mangasushi.org actually answers: its
    /wp-admin/admin-ajax.php returns 400 for ``manga_get_chapters``, and the
    chapters only come back from the per-series relative endpoint.
    """
    calls: list[tuple[str, str]] = []

    def get_text(path: str, *, params: Any = None) -> str:
        calls.append(("GET", path))
        if path == "/":
            return SEARCH_HTML
        if path == f"/manga/{SERIES_ID}/":
            return series_html
        if path.startswith(f"/manga/{SERIES_ID}/chapter-"):
            return READER_HTML
        if path.startswith("/manga"):
            return LISTING_HTML
        raise AssertionError(f"unexpected GET {path}")

    def post_text(path: str, *, data: Any = None, extra_headers: Any = None) -> str:
        calls.append(("POST", path))
        if path == "/wp-admin/admin-ajax.php":
            raise ConnectorHttpError(
                "Client error '400 Bad Request'", status_code=400
            )
        if path == f"/manga/{SERIES_ID}/ajax/chapters/":
            return AJAX_CHAPTERS_HTML
        raise AssertionError(f"unexpected POST {path}")

    with (
        patch.object(connector._http, "get_text", side_effect=get_text),
        patch.object(connector._http, "post_text", side_effect=post_text),
    ):
        yield calls


# ---------------------------------------------------------------------------
# The entry itself
# ---------------------------------------------------------------------------


def test_mangasushi_is_registered_with_the_probed_options() -> None:
    """Each option is a VPS observation, not a default worth drifting.

    ``use_cf=False`` because plain httpx cleared ~120 requests from the OVH
    egress with no challenge; ``mature=False`` because the site is general
    manga with 2 adult-tagged series; no ``extra_image_hosts`` because every
    cover and page image is served from mangasushi.org itself.
    """
    cfg = _config("mangasushi")
    assert cfg is not None
    assert cfg.base_url == "https://mangasushi.org"
    assert cfg.url_segment == "manga"
    assert cfg.listing_post_type is None
    assert cfg.use_cf is False
    assert cfg.mature is False
    assert cfg.extra_image_hosts == frozenset()

    connector = create_connector("mangasushi")
    assert connector.source_type == "mangasushi"
    assert connector.display_name == "MangaSushi"


def test_withdrawn_domains_stay_out_of_the_catalog() -> None:
    """Three of the four probed domains must not become catalog entries.

    kingofshojo.com runs the Themesia "mangareader" theme, not Madara: no
    wp-manga markup, chapters at the site root as /<series>-chapter-<n>/, and
    admin-ajax.php answers manga_get_chapters with 400 "0".
    mangaeffect.com is a permanent 301 to www.mangaread.org, which is already
    the ``mangaread`` entry, so adding it would duplicate a live source.
    mangagg.com is real Madara but publishes only the newest 24 chapters of
    every series through every enumerable route (36/36 sampled series returned
    exactly 24, none starting at chapter 1), so no series can be started.
    """
    hosts = {cfg.site_host for cfg in MADARA_CATALOG}
    assert "kingofshojo.com" not in hosts
    assert "mangaeffect.com" not in hosts
    assert "mangagg.com" not in hosts
    # mangaeffect.com redirects here, so the content is already reachable.
    assert "mangaread.org" in hosts


def test_expired_manhuakey_domain_stays_withdrawn() -> None:
    """manhuakey.com lapsed, so it cannot be reached at all -- not merely blocked.

    The registration expired 2026-09-04 and .com now delegates the name to
    Namecheap's registrar-hold nameservers, whose parking host holds no
    certificate for it: from the VPS every TLS ClientHello is dropped
    (UNEXPECTED_EOF_WHILE_READING) under OpenSSL and under curl_cffi's
    BoringSSL impersonation alike, so no client setting reaches the site.
    Re-adding the entry would only cost a reader a tap and a timeout.
    """
    assert "manhuakey" not in {cfg.source_id for cfg in MADARA_CATALOG}
    assert "manhuakey.com" not in {cfg.site_host for cfg in MADARA_CATALOG}


def test_cloudflare_challenged_linkmanga_stays_removed() -> None:
    """linkmanga lists ten covers and then cannot open a single one of them.

    Probed from the VPS 2026-09-23: the front page and /manga/ answer 200, but
    every series page and every ?s= search is a Cloudflare managed challenge
    (403, cf-mitigated: challenge) even through curl_cffi's chrome131
    impersonation, so get_series is None and get_chapters is empty. The
    re-probe only looks at the listing, which still passes, so re-adding the
    entry would bring back a source that shows as healthy and cannot be read.
    Re-probe series pages and search from the VPS before restoring it.
    """
    assert "linkmanga" not in {cfg.source_id for cfg in MADARA_CATALOG}
    assert "linkmanga.com" not in {cfg.site_host for cfg in MADARA_CATALOG}
    # The registry is what browse, search and the re-probe actually read.
    installed = {
        d.source_type
        for d in list_installed_connectors(browsable_only=False, include_mature=True)
    }
    assert "linkmanga" not in installed


def test_sources_that_failed_the_2026_09_05_read_path_stay_deleted() -> None:
    """Seven entries added 2026-09-05 could not be read from production, twice.

    Each was probed end-to-end from inside the production container and then
    re-probed independently; every failure below reproduced identically, so
    none is a bad moment on the network. Browse or detail passing is not the
    bar -- the bar is a reader getting page bytes.

    topmanhua is the one to read twice before re-adding anything. It was
    removed 2026-09-04 because cdn.topmanhua.net answers 526, then re-added
    the next day at the sibling apex topmanhua.net on the finding that the new
    host served its own images. It does not: the reader's first page still
    resolves to cdn.topmanhua.net and still 526s, so a second removal cost the
    same probe budget as the first. A different domain is not evidence of a
    different image host.
    """
    ids = {cfg.source_id for cfg in MADARA_CATALOG}
    hosts = {cfg.site_host for cfg in MADARA_CATALOG}
    # browse 404s on the configured segment and on both LISTING_FALLBACKS.
    assert "manhuatop" not in ids
    assert "rawdex" not in ids
    # browse/detail pass, then get_chapters returns 0 chapters.
    assert "mangayy" not in ids
    assert "manhwa68" not in ids
    # pages resolve, then the bytes never arrive: a 526 CDN (topmanhua), a
    # bogus content-type clamped to octet-stream (manhwatoon), and a redirect
    # the image proxy will not follow (toonizy).
    assert "topmanhua" not in ids
    assert "topmanhua.net" not in hosts
    assert "manhwatoon" not in ids
    assert "toonizy" not in ids


def test_kokomangas_and_mangaowl_sit_behind_the_18_plus_gate() -> None:
    """Both shipped non-mature 2026-09-05 while serving adult work.

    kokomangas was cleared as non-mature because /manga-genre/adult/, /mature/,
    /smut/ and /ecchi/ all 404 -- but the install publishes no genre taxonomy
    at all, so those 404s said nothing about the content. 11 of 53 distinct
    series across listing pages 1-5 are explicitly sexual.

    mangaowl was added with no maturity note, so it defaulted to visible with
    the gate shut. Its own series pages for the most-viewed works carry
    Adult + Mature + Smut + Yaoi genres.

    A catalog line with no ``mature=`` is a line that ships to a profile with
    the gate closed, which is why both are asserted here rather than trusted
    to the comment above them.
    """
    for source_id in ("kokomangas", "mangaowl"):
        cfg = _config(source_id)
        assert cfg is not None, f"{source_id} missing from MADARA_CATALOG"
        assert cfg.mature is True, source_id


def test_catalog_source_ids_stay_unique() -> None:
    """Two configs with one source_id would silently drop a source.

    ``madara_connector_classes`` dedupes by source_id, so a copy-paste in the
    catalog loses a site with no error anywhere.
    """
    ids = [cfg.source_id for cfg in MADARA_CATALOG]
    assert len(ids) == len(set(ids)), sorted(
        {i for i in ids if ids.count(i) > 1}
    )


# ---------------------------------------------------------------------------
# Parsing the live captures
# ---------------------------------------------------------------------------


def test_browse_parses_the_live_listing() -> None:
    connector = _fresh_connector()
    with _mock_live_html(connector):
        listing = connector.get_series_list(1)

    assert [s.id for s in listing.items] == [OTHER_SERIES_ID, SERIES_ID]
    kanzen = listing.items[1]
    assert kanzen.title == "Kanzen Kaihi Healer no Kiseki"
    assert kanzen.cover_url is not None
    assert kanzen.cover_url.startswith("https://mangasushi.org/wp-content/uploads/")


def test_search_parses_the_live_result_card() -> None:
    connector = _fresh_connector()
    with _mock_live_html(connector) as calls:
        results = connector.search_series("kanzen", 1)

    assert [s.id for s in results.items] == [SERIES_ID]
    assert results.items[0].title == "Kanzen Kaihi Healer no Kiseki"
    assert ("GET", "/") in calls


def test_series_detail_parses_metadata_from_the_live_page() -> None:
    connector = _fresh_connector()
    with _mock_live_html(connector):
        series = connector.get_series(SERIES_ID)

    assert series is not None
    assert series.title == "Kanzen Kaihi Healer no Kiseki"
    assert series.status == "OnGoing"
    assert series.author == "Puni-Chan"
    assert series.artist == "Yamato Hina"
    assert "Action" in series.genres and "Fantasy" in series.genres
    assert series.cover_url == (
        "https://mangasushi.org/wp-content/uploads/2022/01/kanzen-1.jpg"
    )
    assert series.description and "Demon Lord" in series.description


def test_chapters_come_from_the_relative_ajax_endpoint() -> None:
    """mangasushi ships an empty chapter holder and fills it over AJAX.

    Its admin-ajax route is dead (400), so the connector has to fall through
    to ``{series}/ajax/chapters/`` -- and the chapter ids, numbering and order
    all have to survive that fragment.
    """
    connector = _fresh_connector()
    with _mock_live_html(connector) as calls:
        chapters = connector.get_chapters(SERIES_ID)

    assert ("POST", f"/manga/{SERIES_ID}/ajax/chapters/") in calls
    assert [c.id for c in chapters] == [
        f"{SERIES_ID}/chapter-01",
        f"{SERIES_ID}/chapter-02",
        f"{SERIES_ID}/chapter-03",
        f"{SERIES_ID}/chapter-72",
        f"{SERIES_ID}/chapter-73",
        f"{SERIES_ID}/chapter-74",
    ]
    # Oldest first, and the site's own numbering kept as a float.
    assert [c.number for c in chapters] == [1.0, 2.0, 3.0, 72.0, 73.0, 74.0]


def test_chapter_pages_and_find_page_round_trip() -> None:
    connector = _fresh_connector()
    with _mock_live_html(connector) as calls:
        pages = connector.get_chapter_pages(CHAPTER_ID)
        found = connector.find_page(pages[0].id)

    assert len(pages) == 5
    assert all(p.remote_url.startswith("https://mangasushi.org/wp-content/uploads/")
               for p in pages)
    assert pages[0].remote_url.endswith("/00.jpg")
    assert found == pages[0]
    # One reader fetch serves every page in the chapter -- page-image
    # resolution must never cost a request per page.
    assert [c for c in calls if c[0] == "GET"].count(
        ("GET", f"/manga/{CHAPTER_ID}/")
    ) == 1


# ---------------------------------------------------------------------------
# Speed properties
# ---------------------------------------------------------------------------


def test_detail_and_chapters_share_one_series_fetch() -> None:
    """Opening a series must not download its page twice.

    ``get_series`` resolves the chapter list from the HTML it is already
    holding and caches it, so the ``get_chapters`` the UI issues straight
    afterwards costs no further request.
    """
    connector = _fresh_connector()
    with _mock_live_html(connector) as calls:
        series = connector.get_series(SERIES_ID)
        chapters = connector.get_chapters(SERIES_ID)

    assert series is not None
    assert len(chapters) == 6
    assert series.chapter_count == 6
    series_gets = [c for c in calls if c == ("GET", f"/manga/{SERIES_ID}/")]
    assert len(series_gets) == 1, calls


def test_dead_admin_ajax_route_is_probed_once_per_site() -> None:
    """The 400 from admin-ajax.php is a fact about the install, so cache it.

    Without the remembered shape every series open would pay a wasted round
    trip to an endpoint this site has never served.
    """
    connector = _fresh_connector()
    with _mock_live_html(connector) as calls:
        connector.get_chapters(SERIES_ID)
        connector._chapter_list_cache.pop(SERIES_ID)
        connector._series_cache.pop(SERIES_ID)
        connector.get_chapters(SERIES_ID)

    admin_posts = [c for c in calls if c == ("POST", "/wp-admin/admin-ajax.php")]
    relative_posts = [
        c for c in calls if c == ("POST", f"/manga/{SERIES_ID}/ajax/chapters/")
    ]
    assert len(admin_posts) == 1, calls
    assert len(relative_posts) == 2, calls


# ---------------------------------------------------------------------------
# Image proxy
# ---------------------------------------------------------------------------


def test_page_image_hosts_pass_the_proxy_allowlist() -> None:
    """Every page image is on the site host, so the derived allowlist is enough.

    The image proxy rejects a host that is not allowlisted before it makes any
    request, which is how a browsable-but-unreadable source happens.
    """
    allowed = create_connector("mangasushi").allowed_image_hosts
    assert host_matches_allowlist("mangasushi.org", allowed)
    assert not host_matches_allowlist("notmangasushi.org", allowed)


def test_image_fetch_headers_carry_referer_and_browser_user_agent() -> None:
    """The proxy forwards only these headers upstream."""
    headers = create_connector("mangasushi").image_fetch_headers()
    assert headers["Referer"] == "https://mangasushi.org/"
    assert headers["User-Agent"].startswith("Mozilla/5.0")
    assert "python-httpx" not in headers["User-Agent"]


@pytest.mark.parametrize("bad_host", ["mangasushi.org.evil.test", "evil.test"])
def test_image_allowlist_rejects_lookalike_hosts(bad_host: str) -> None:
    allowed = create_connector("mangasushi").allowed_image_hosts
    assert not host_matches_allowlist(bad_host, allowed)
