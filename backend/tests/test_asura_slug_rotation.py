"""One Asura series, several keys: follows and notifications must still agree.

Asura appends eight hex digits to every series slug and changes them
site-wide every few days, while the old slug keeps resolving. Production holds
The Great Mage Returns After 4000 Years under -53fc8424, -6f7fe6eb, -05c7df14
and -08677664, with follows made under the oldest and Browse handing out the
newest. Compared by exact key, the same series then looked like two: a second
Follow press inserted a duplicate (every new chapter notified twice), and
reading a chapter under the new key never cleared the notification stored
under the old one.

The connector answers "same series?" (``series_identity``); keys themselves
are left exactly as stored, so rows under old suffixes keep working.
"""

from __future__ import annotations

import pytest

from connectors.asurascans.connector import AsuraScansConnector
from database.models import FollowedSeries, UpdateNotification
from services.followed_series_service import FollowedSeriesService
from services.progress_service import ProgressInput, ProgressService
from tests._fakes import FakeBrowse

SRC = "asurascans"
BASE = "the-great-mage-returns-after-4000-years"
OLD = f"{BASE}-08677664"
NEW = f"{BASE}-05c7df14"


@pytest.fixture
def acct(make_user, make_profile):
    user = make_user("reader")
    profile = make_profile(user.id, "Main")
    return user.id, profile.id


def _library(db, uid, pid) -> FollowedSeriesService:
    browse = FakeBrowse()
    browse.down = True  # no source is ever contacted; follow survives outages
    return FollowedSeriesService(db, browse, user_id=uid, profile_id=pid)


def _follows(db, uid, pid) -> list[FollowedSeries]:
    return (
        db.query(FollowedSeries)
        .filter_by(user_id=uid, profile_id=pid)
        .order_by(FollowedSeries.id)
        .all()
    )


# --- the connector's answer ---------------------------------------------------


def test_asura_keys_that_differ_only_in_the_rotating_suffix_name_one_series():
    connector = AsuraScansConnector()

    assert connector.series_identity(OLD) == connector.series_identity(NEW)
    assert connector.chapter_identity(f"{OLD}:275") == connector.chapter_identity(
        f"{NEW}:275"
    )
    # Everything else still tells series and chapters apart.
    assert connector.series_identity(OLD) != connector.series_identity(
        "the-great-mage-08677664"
    )
    assert connector.chapter_identity(f"{OLD}:275") != connector.chapter_identity(
        f"{NEW}:274"
    )
    # A slug with no suffix is its own identity, not an empty string.
    assert connector.series_identity(BASE) == BASE


def test_keys_themselves_are_left_alone():
    """The identity is only for comparing: the API is still asked with the
    exact suffixed key, since whether the bare slug resolves is unknown."""
    connector = AsuraScansConnector()

    assert connector._normalize_series_id(OLD) == OLD


# --- follow ---------------------------------------------------------------------


def test_following_under_the_new_key_finds_the_follow_under_the_old_one(
    db_session, acct, seed_follow
):
    uid, pid = acct
    old = seed_follow(uid, pid, source_id=SRC, series_key=OLD, title="TGMR")

    result = _library(db_session, uid, pid).follow(SRC, NEW)

    assert result["id"] == old.id
    follows = _follows(db_session, uid, pid)
    assert [row.series_key for row in follows] == [OLD], (
        "a second follow of the same series was inserted -- every new chapter "
        "would now be notified twice"
    )


def test_a_different_series_sharing_the_prefix_is_still_its_own_follow(
    db_session, acct, seed_follow
):
    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key=OLD)

    _library(db_session, uid, pid).follow(SRC, "the-great-mage-05c7df14")

    assert len(_follows(db_session, uid, pid)) == 2


def test_another_profiles_follow_is_not_this_profiles(
    db_session, make_user, make_profile, seed_follow
):
    user = make_user("household")
    a = make_profile(user.id, "A")
    b = make_profile(user.id, "B")
    seed_follow(user.id, a.id, source_id=SRC, series_key=OLD)

    _library(db_session, user.id, b.id).follow(SRC, NEW)

    assert [row.series_key for row in _follows(db_session, user.id, b.id)] == [NEW]


def test_a_source_whose_keys_do_not_drift_compares_exactly(
    db_session, acct, seed_follow
):
    # Only Asura says its suffix is noise. The same shape on any other source
    # is part of the key, and two keys are two series.
    uid, pid = acct
    seed_follow(uid, pid, source_id="mangadex", series_key=OLD)

    _library(db_session, uid, pid).follow("mangadex", NEW)

    assert len(_follows(db_session, uid, pid)) == 2


def test_a_follow_and_the_new_key_page_carry_one_identity(
    db_session, acct, seed_follow
):
    """A client can tell a new-key page is followed without parsing keys.

    The follow keeps the key it was made under, and Browse serves the page
    under this week's; both payloads carry the connector's identity, so the
    Follow button on the new page reads "Following" instead of offering a
    press that hands back the old follow and changes nothing on screen.
    """
    from connectors.models import Series
    from services.browse_service import _serialize_series

    uid, pid = acct
    seed_follow(uid, pid, source_id=SRC, series_key=OLD, title="TGMR")

    followed = _library(db_session, uid, pid).list_series()["items"]
    page = _serialize_series(Series(id=NEW, title="TGMR"), SRC)

    assert [row["series_key"] for row in followed] == [OLD]
    assert followed[0]["series_identity"] == page["series_identity"]
    # A source whose keys do not drift names a series by its key alone.
    other = _serialize_series(Series(id=OLD, title="TGMR"), "mangadex")
    assert other["series_identity"] == OLD


# --- reading clears the notification ----------------------------------------------


def _notify(db, uid, pid, follow, *, source_id=SRC, series_key=OLD, number=275):
    row = UpdateNotification(
        user_id=uid,
        profile_id=pid,
        followed_series_id=follow.id,
        source_id=source_id,
        series_key=series_key,
        chapter_key=f"{series_key}:{number}",
        chapter_title=f"Chapter {number}",
        chapter_number=float(number),
    )
    db.add(row)
    db.commit()
    db.refresh(row)
    return row


def _read(db, uid, pid, *, source_id=SRC, series_key=NEW, number=275) -> None:
    ProgressService(db, user_id=uid, profile_id=pid).save_one(
        ProgressInput(
            source_id=source_id,
            series_key=series_key,
            chapter_key=f"{series_key}:{number}",
            chapter_number=float(number),
            last_page=3,
            page_count=20,
        )
    )


def test_reading_under_the_new_key_clears_the_notification_under_the_old_one(
    db_session, acct, seed_follow
):
    uid, pid = acct
    follow = seed_follow(uid, pid, source_id=SRC, series_key=OLD)
    notif = _notify(db_session, uid, pid, follow)

    _read(db_session, uid, pid)

    db_session.refresh(notif)
    assert notif.is_read, (
        "chapter 275 was read from Browse's key and the notification under the "
        "follow's key is still unread -- the badge never goes down"
    )
    # The stored key is untouched: the follow and its notifications still
    # agree with each other.
    assert notif.series_key == OLD


def test_reading_another_chapter_under_the_new_key_leaves_it_alone(
    db_session, acct, seed_follow
):
    uid, pid = acct
    follow = seed_follow(uid, pid, source_id=SRC, series_key=OLD)
    notif = _notify(db_session, uid, pid, follow)

    _read(db_session, uid, pid, number=274)

    db_session.refresh(notif)
    assert not notif.is_read


def test_reading_a_series_sharing_the_prefix_leaves_it_alone(
    db_session, acct, seed_follow
):
    uid, pid = acct
    follow = seed_follow(uid, pid, source_id=SRC, series_key=OLD)
    notif = _notify(db_session, uid, pid, follow)

    _read(db_session, uid, pid, series_key="the-great-mage-05c7df14")

    db_session.refresh(notif)
    assert not notif.is_read


def test_another_profiles_reading_leaves_this_profiles_badge_alone(
    db_session, make_user, make_profile, seed_follow
):
    user = make_user("household")
    a = make_profile(user.id, "A")
    b = make_profile(user.id, "B")
    follow = seed_follow(user.id, a.id, source_id=SRC, series_key=OLD)
    notif = _notify(db_session, user.id, a.id, follow)

    _read(db_session, user.id, b.id)

    db_session.refresh(notif)
    assert not notif.is_read


def test_a_source_whose_keys_do_not_drift_clears_exactly(
    db_session, acct, seed_follow
):
    uid, pid = acct
    follow = seed_follow(uid, pid, source_id="mangadex", series_key=OLD)
    notif = _notify(db_session, uid, pid, follow, source_id="mangadex")

    _read(db_session, uid, pid, source_id="mangadex")

    db_session.refresh(notif)
    assert not notif.is_read
