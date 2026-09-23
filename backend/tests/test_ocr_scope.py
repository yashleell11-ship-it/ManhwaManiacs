"""OCR: global storage, scoped access (spec §3.9, §4.4, §7).

``chapter_ocr`` is one row per chapter, not per user — but "global row"
describes the STORAGE, not the authorization. Every path that touches it,
returning stored text (search, ``get_chapter``, ``coverage``) *or writing it*
(``ingest_chapter``), is scoped to the caller's followed series in the active
profile plus that profile's 18+ gate.

``get_chapter`` and ``coverage`` used to take the identity triple and query on
it alone: any authenticated account, on any profile, with the gate shut, could
read the full dialogue transcript of any chapter on any source. The write read
"global" as authorization and had no check at all, so any account could also
*replace* any chapter's transcript. The denial tests below are the ones that
would have caught both.
"""

from __future__ import annotations

import json

import pytest

from core.errors import AppError
from services.followed_series_service import FollowedSeriesService
from services.ocr_ingest_service import OcrIngestService
from services.ocr_search import OcrSearchService
from tests._fakes import FakeBrowse

SRC = "mangadex"
SERIES = "the-dragon-king"


@pytest.fixture
def accounts(make_user, make_profile):
    ua, ub = make_user("a"), make_user("b")
    pa = make_profile(ua.id, "A")
    pb = make_profile(ub.id, "B")
    return {"ua": ua.id, "ub": ub.id, "pa": pa.id, "pb": pb.id}


@pytest.fixture(autouse=True)
def chapter_lists(db_session):
    """The series' chapter lists as ``source_series_cache`` holds them.

    An upload is only taken for a chapter the server has seen for the series;
    the follows these tests seed carry an empty snapshot, so this cache row is
    what makes ``c1``..``c3`` real chapters here.
    """
    from database.models import SourceSeriesCache

    for series_key in (SERIES, "safe-one"):
        db_session.add(
            SourceSeriesCache(
                source_id=SRC,
                series_key=series_key,
                chapters=json.dumps([{"key": k} for k in ("c1", "c2", "c3")]),
            )
        )
    db_session.commit()


def _search_svc(db, user_id, profile_id):
    followed = FollowedSeriesService(
        db, FakeBrowse(), user_id=user_id, profile_id=profile_id
    )
    return OcrSearchService(db, followed)


def _ingest(db, user_id=None, profile_id=None, browse=None):
    return OcrIngestService(
        db, browse or FakeBrowse(), user_id=user_id, profile_id=profile_id
    )


def _seed_transcript(db, accounts, chapter_key="c1", text="the dragon king awakened"):
    return _ingest(db, accounts["ua"], accounts["pa"]).ingest_chapter(
        source_id=SRC,
        series_key=SERIES,
        chapter_key=chapter_key,
        engine="mlkit",
        pages=[{"page": 1, "text": text}],
    )


# --- the row stays global, the write is scoped ---------------------------


def test_ingest_writes_one_global_row(
    db_session, accounts, seed_follow, make_user, make_profile
):
    """Two contributors, one row: the storage is still per-chapter, not
    per-user. Both follow the series — that is now what buys the write — and
    the second is the owner, who alone may replace another's transcript."""
    owner = make_user("owner", is_admin=True)
    owner_profile = make_profile(owner.id, "Owner")
    seed_follow(accounts["ua"], accounts["pa"], source_id=SRC, series_key=SERIES)
    seed_follow(owner.id, owner_profile.id, source_id=SRC, series_key=SERIES)
    r1 = _ingest(db_session, accounts["ua"], accounts["pa"]).ingest_chapter(
        source_id=SRC,
        series_key=SERIES,
        chapter_key="c1",
        engine="mlkit",
        pages=[{"page": 1, "text": "the dragon king awakened"}],
    )
    # a second contributor for the same chapter replaces, not duplicates
    r2 = _ingest(db_session, owner.id, owner_profile.id).ingest_chapter(
        source_id=SRC,
        series_key=SERIES,
        chapter_key="c1",
        engine="apple-vision",
        pages=[{"page": 1, "text": "the dragon king awakened at dawn"}],
    )
    assert r1["source_id"] == r2["source_id"]
    from database.models import ChapterOcr

    rows = db_session.query(ChapterOcr).filter_by(
        source_id=SRC, series_key=SERIES, chapter_key="c1"
    ).all()
    assert len(rows) == 1
    assert rows[0].engine == "apple-vision"  # last engine wins


def test_empty_upload_never_clobbers_a_good_transcript(
    db_session, accounts, seed_follow
):
    seed_follow(accounts["ua"], accounts["pa"], source_id=SRC, series_key=SERIES)
    ing = _ingest(db_session, accounts["ua"], accounts["pa"])
    ing.ingest_chapter(
        source_id=SRC, series_key=SERIES, chapter_key="c2",
        engine="mlkit", pages=[{"page": 1, "text": "important dialogue here"}],
    )
    ing.ingest_chapter(
        source_id=SRC, series_key=SERIES, chapter_key="c2",
        engine="mlkit", pages=[{"page": 1, "text": ""}],
    )
    from database.models import ChapterOcr

    row = db_session.query(ChapterOcr).filter_by(chapter_key="c2").one()
    assert row.word_count == 3
    assert "important" in row.full_text


def test_a_follower_cannot_replace_another_accounts_transcript(
    db_session, accounts, seed_follow
):
    """Following is self-service, so the follow gate alone let any account on
    open registration follow the owner's series and overwrite the transcript
    he reads as his overlay and his search results. The row is global and
    keeps no history, so the overwrite destroyed the real scan."""
    seed_follow(accounts["ua"], accounts["pa"], source_id=SRC, series_key=SERIES)
    seed_follow(accounts["ub"], accounts["pb"], source_id=SRC, series_key=SERIES)
    _seed_transcript(db_session, accounts, text="the dragon king awakened")

    with pytest.raises(AppError) as err:
        _ingest(db_session, accounts["ub"], accounts["pb"]).ingest_chapter(
            source_id=SRC,
            series_key=SERIES,
            chapter_key="c1",
            engine="mlkit",
            pages=[{"page": 1, "text": "attacker supplied dialogue"}],
        )
    assert err.value.status_code == 409
    assert err.value.code == "ocr_transcript_taken"

    from database.models import ChapterOcr

    row = db_session.query(ChapterOcr).filter_by(chapter_key="c1").one()
    assert row.full_text == "the dragon king awakened"
    assert row.contributed_by_user_id == accounts["ua"]


def test_a_contributor_may_still_rescan_its_own_transcript(
    db_session, accounts, seed_follow
):
    seed_follow(accounts["ua"], accounts["pa"], source_id=SRC, series_key=SERIES)
    _seed_transcript(db_session, accounts, text="the dragon king awakened")
    _seed_transcript(db_session, accounts, text="the dragon king awakened at dawn")

    from database.models import ChapterOcr

    row = db_session.query(ChapterOcr).filter_by(chapter_key="c1").one()
    assert row.full_text == "the dragon king awakened at dawn"


def test_a_transcript_with_no_recorded_contributor_is_the_owners_to_replace(
    db_session, accounts, seed_follow, make_user, make_profile
):
    from database.models import ChapterOcr

    seed_follow(accounts["ua"], accounts["pa"], source_id=SRC, series_key=SERIES)
    _seed_transcript(db_session, accounts, text="an old scan")
    row = db_session.query(ChapterOcr).filter_by(chapter_key="c1").one()
    row.contributed_by_user_id = None
    db_session.commit()

    with pytest.raises(AppError) as err:
        _seed_transcript(db_session, accounts, text="a newer scan")
    assert err.value.status_code == 409

    owner = make_user("owner", is_admin=True)
    owner_profile = make_profile(owner.id, "Owner")
    seed_follow(owner.id, owner_profile.id, source_id=SRC, series_key=SERIES)
    _ingest(db_session, owner.id, owner_profile.id).ingest_chapter(
        source_id=SRC,
        series_key=SERIES,
        chapter_key="c1",
        engine="mlkit",
        pages=[{"page": 1, "text": "the owner's scan"}],
    )
    db_session.refresh(row)
    assert row.full_text == "the owner's scan"
    assert row.contributed_by_user_id == owner.id


# --- search ---------------------------------------------------------------


def test_search_is_scoped_to_the_callers_followed_series(
    db_session, accounts, seed_follow
):
    # A follows the series, B does not.
    seed_follow(accounts["ua"], accounts["pa"], source_id=SRC, series_key=SERIES)
    _seed_transcript(db_session, accounts, text="the crimson dragon roared")

    a_hits = _search_svc(db_session, accounts["ua"], accounts["pa"]).search("crimson")
    b_hits = _search_svc(db_session, accounts["ub"], accounts["pb"]).search("crimson")

    assert [h["chapter_key"] for h in a_hits["items"]] == ["c1"]
    assert b_hits["items"] == []  # B does not follow the series


def test_following_the_series_reveals_the_existing_global_ocr(
    db_session, accounts, seed_follow
):
    seed_follow(accounts["ua"], accounts["pa"], source_id=SRC, series_key=SERIES)
    _seed_transcript(db_session, accounts, text="a whisper in the dark tower")
    # B now follows it → the global row becomes visible to B.
    seed_follow(accounts["ub"], accounts["pb"], source_id=SRC, series_key=SERIES)
    b_hits = _search_svc(db_session, accounts["ub"], accounts["pb"]).search("whisper")
    assert [h["chapter_key"] for h in b_hits["items"]] == ["c1"]


# --- get_chapter / coverage: the follow scope -----------------------------


def test_coverage_lists_ocr_chapters_for_a_series(db_session, accounts, seed_follow):
    seed_follow(accounts["ua"], accounts["pa"], source_id=SRC, series_key=SERIES)
    ing = _ingest(db_session, accounts["ua"], accounts["pa"])
    for key in ("c1", "c3"):
        ing.ingest_chapter(
            source_id=SRC, series_key=SERIES, chapter_key=key,
            engine="mlkit", pages=[{"page": 1, "text": f"text for {key}"}],
        )
    cov = ing.coverage(SRC, SERIES)
    assert {c["chapter_key"] for c in cov["chapters"]} == {"c1", "c3"}


def test_get_chapter_reads_back_for_the_profile_that_follows(
    db_session, accounts, seed_follow
):
    seed_follow(accounts["ua"], accounts["pa"], source_id=SRC, series_key=SERIES)
    _seed_transcript(db_session, accounts)
    got = _ingest(db_session, accounts["ua"], accounts["pa"]).get_chapter(
        SRC, SERIES, "c1"
    )
    assert got is not None
    assert got["page_texts"][0]["text"] == "the dragon king awakened"


def test_get_chapter_is_withheld_from_an_account_that_does_not_follow(
    db_session, accounts, seed_follow
):
    """The reported hole: B asked for A's series by raw triple and got the text.

    B is a whole other account on its own profile, and never followed anything.
    """
    seed_follow(accounts["ua"], accounts["pa"], source_id=SRC, series_key=SERIES)
    _seed_transcript(db_session, accounts)

    assert (
        _ingest(db_session, accounts["ub"], accounts["pb"]).get_chapter(
            SRC, SERIES, "c1"
        )
        is None
    )


def test_coverage_is_withheld_from_an_account_that_does_not_follow(
    db_session, accounts, seed_follow
):
    seed_follow(accounts["ua"], accounts["pa"], source_id=SRC, series_key=SERIES)
    _seed_transcript(db_session, accounts)

    cov = _ingest(db_session, accounts["ub"], accounts["pb"]).coverage(SRC, SERIES)
    assert cov["chapters"] == []


def test_a_second_profile_of_the_same_account_cannot_read_the_first_profiles_series(
    db_session, make_user, make_profile, seed_follow
):
    """Same user, same session — only the profile differs.

    A cross-profile leak has shipped here before, so the scope is the *pair*:
    a follow on profile "A" must not unlock the transcript on profile "B".
    """
    user = make_user("shared")
    a = make_profile(user.id, "A")
    b = make_profile(user.id, "B", sort_order=1)
    seed_follow(user.id, a.id, source_id=SRC, series_key=SERIES)
    _ingest(db_session, user.id, a.id).ingest_chapter(
        source_id=SRC, series_key=SERIES, chapter_key="c1",
        engine="mlkit", pages=[{"page": 1, "text": "a line only A follows"}],
    )

    assert _ingest(db_session, user.id, a.id).get_chapter(SRC, SERIES, "c1") is not None
    assert _ingest(db_session, user.id, b.id).get_chapter(SRC, SERIES, "c1") is None
    assert _ingest(db_session, user.id, b.id).coverage(SRC, SERIES)["chapters"] == []


def test_an_unscoped_service_reads_nothing(db_session, accounts, seed_follow):
    """No user, no profile — the anonymous/legacy bucket owns no library."""
    seed_follow(accounts["ua"], accounts["pa"], source_id=SRC, series_key=SERIES)
    _seed_transcript(db_session, accounts)

    unscoped = _ingest(db_session)
    assert unscoped.get_chapter(SRC, SERIES, "c1") is None
    assert unscoped.coverage(SRC, SERIES)["chapters"] == []


# --- get_chapter / coverage: the 18+ gate ---------------------------------


def test_mature_series_is_withheld_while_the_profiles_gate_is_shut(
    db_session, make_user, make_profile, seed_follow
):
    """One account, two profiles, both following the same 18+ series.

    Only ``mature_content_enabled`` differs. Resolving the gate from
    ``get_settings()`` in the service instead of from the (user, profile) — the
    bug that once made the in-app toggle inert — makes both calls agree and
    this fail.
    """
    user = make_user("mixed")
    shut = make_profile(user.id, "Kid", mature_content_enabled=False)
    open_ = make_profile(user.id, "Grown", mature_content_enabled=True, sort_order=1)
    for pid in (shut.id, open_.id):
        seed_follow(
            user.id, pid, source_id=SRC, series_key=SERIES, mature_override=True
        )
    _ingest(db_session, user.id, open_.id).ingest_chapter(
        source_id=SRC, series_key=SERIES, chapter_key="c1",
        engine="mlkit", pages=[{"page": 1, "text": "adult dialogue"}],
    )

    assert _ingest(db_session, user.id, shut.id).get_chapter(SRC, SERIES, "c1") is None
    assert _ingest(db_session, user.id, shut.id).coverage(SRC, SERIES)["chapters"] == []

    allowed = _ingest(db_session, user.id, open_.id)
    assert allowed.get_chapter(SRC, SERIES, "c1") is not None
    assert [c["chapter_key"] for c in allowed.coverage(SRC, SERIES)["chapters"]] == ["c1"]


def test_a_safe_series_on_the_same_profile_is_unaffected_by_the_shut_gate(
    db_session, make_user, make_profile, seed_follow
):
    """The gate hides the 18+ row, not the whole library."""
    user = make_user("mixed2")
    shut = make_profile(user.id, "Kid", mature_content_enabled=False)
    seed_follow(
        user.id, shut.id, source_id=SRC, series_key="safe-one", mature_override=False
    )
    _ingest(db_session, user.id, shut.id).ingest_chapter(
        source_id=SRC, series_key="safe-one", chapter_key="c1",
        engine="mlkit", pages=[{"page": 1, "text": "wholesome dialogue"}],
    )
    assert (
        _ingest(db_session, user.id, shut.id).get_chapter(SRC, "safe-one", "c1")
        is not None
    )


def test_mature_source_is_not_found_rather_than_forbidden(
    db_session, accounts, seed_follow
):
    """A mature *source* with the gate shut answers exactly as browse does.

    404 and never 403: an off-limits resource has to be indistinguishable from
    an absent one, or its existence is the disclosure.
    """
    browse = FakeBrowse()
    browse.mature_sources = {SRC}
    browse.gate_open = False
    seed_follow(accounts["ua"], accounts["pa"], source_id=SRC, series_key=SERIES)
    _seed_transcript(db_session, accounts)

    gated = _ingest(db_session, accounts["ua"], accounts["pa"], browse=browse)
    for call in (
        lambda: gated.get_chapter(SRC, SERIES, "c1"),
        lambda: gated.coverage(SRC, SERIES),
    ):
        with pytest.raises(AppError) as exc:
            call()
        assert exc.value.status_code == 404
        assert exc.value.code == "source_not_found"
