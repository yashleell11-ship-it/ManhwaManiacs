"""Reading a chapter clears its "new chapter" notification.

``is_read`` used to move only when someone pressed a button — the only writers
were reachable from the two routes in ``routes/updates.py``. So a chapter read
normally left its notification unread forever, and the unread badge counted
chapters already finished. That badge is the only thing in the product whose job
is to bring the reader back, and one that lies is one they stop looking at.
"""

from __future__ import annotations

# NOTE: is_read round-trips as SQLite's 0/1, not Python's False/True, so every
# assertion here is a truthiness check. `is True` fails on the value 1.

import pytest
from database.models import UpdateNotification
from services.progress_service import ProgressInput, ProgressService

SRC = "asurascans"
SERIES = "the-great-mage-returns"
CHAPTER = "the-great-mage-returns/chapters/273"


def _push(**kw) -> ProgressInput:
    base = dict(
        source_id=SRC,
        series_key=SERIES,
        chapter_key=CHAPTER,
        chapter_number=273.0,
        last_page=3,
        page_count=20,
    )
    base.update(kw)
    return ProgressInput(**base)


@pytest.fixture
def acct(make_user, make_profile):
    user = make_user("reader")
    profile = make_profile(user.id, "Main")
    return user.id, profile.id


def _notify(db, uid, pid, follow_id, *, chapter_key=CHAPTER, series_key=SERIES):
    row = UpdateNotification(
        user_id=uid,
        profile_id=pid,
        followed_series_id=follow_id,
        source_id=SRC,
        series_key=series_key,
        chapter_key=chapter_key,
        chapter_title="Chapter 273",
        chapter_number=273.0,
    )
    db.add(row)
    db.commit()
    db.refresh(row)
    return row


def test_reading_the_chapter_marks_its_notification_read(
    db_session, acct, seed_follow
):
    uid, pid = acct
    follow = seed_follow(uid, pid, source_id=SRC, series_key=SERIES)
    notif = _notify(db_session, uid, pid, follow.id)
    assert not notif.is_read

    ProgressService(db_session, user_id=uid, profile_id=pid).save_one(_push())

    db_session.refresh(notif)
    assert notif.is_read, (
        "the chapter was read and its notification is still unread -- the badge "
        "is counting a chapter that has been finished"
    )


def test_a_partial_read_is_enough(db_session, acct, seed_follow):
    # Opening the chapter at all is the acknowledgement; waiting for completion
    # would leave the badge lit through the whole of a long chapter.
    uid, pid = acct
    follow = seed_follow(uid, pid, source_id=SRC, series_key=SERIES)
    notif = _notify(db_session, uid, pid, follow.id)

    ProgressService(db_session, user_id=uid, profile_id=pid).save_one(
        _push(last_page=1, page_count=90)
    )

    db_session.refresh(notif)
    assert notif.is_read


def test_another_chapter_leaves_it_alone(db_session, acct, seed_follow):
    uid, pid = acct
    follow = seed_follow(uid, pid, source_id=SRC, series_key=SERIES)
    notif = _notify(db_session, uid, pid, follow.id)

    ProgressService(db_session, user_id=uid, profile_id=pid).save_one(
        _push(chapter_key=f"{SERIES}/chapters/272", chapter_number=272.0)
    )

    db_session.refresh(notif)
    assert not notif.is_read, (
        "reading chapter 272 cleared the notification for 273"
    )


def test_one_profile_reading_does_not_clear_anothers_badge(
    db_session, make_user, make_profile, seed_follow
):
    # The live box has two profiles following the same novel. Each gets its own
    # notification row, and the wrong WHERE clause here would silently mark the
    # other person's chapter read -- the same class of cross-profile leak that
    # has shipped in this codebase twice.
    a = make_user("alice")
    b = make_user("bob")
    pa = make_profile(a.id, "A")
    pb = make_profile(b.id, "B")
    fa = seed_follow(a.id, pa.id, source_id=SRC, series_key=SERIES)
    fb = seed_follow(b.id, pb.id, source_id=SRC, series_key=SERIES)
    na = _notify(db_session, a.id, pa.id, fa.id)
    nb = _notify(db_session, b.id, pb.id, fb.id)

    ProgressService(db_session, user_id=a.id, profile_id=pa.id).save_one(_push())

    db_session.refresh(na)
    db_session.refresh(nb)
    assert na.is_read
    assert not nb.is_read, "Alice reading cleared Bob's unread badge"


def test_a_percent_encoded_key_still_matches(db_session, acct, seed_follow):
    # THE trap this whole design turns on. chapter_progress stores
    # fully_unquote'd keys (progress_service._apply_one); update_service used to
    # store the connector's raw spelling. Where the two differ the UPDATE
    # matches zero rows and the feature looks implemented while doing nothing.
    # No live key differs today, which is exactly why this needs a test.
    uid, pid = acct
    raw = "series/chapters/ch%2F41"
    unquoted = "series/chapters/ch/41"
    follow = seed_follow(uid, pid, source_id=SRC, series_key=SERIES)
    # Stored canonically, the way update_service now writes it.
    notif = _notify(db_session, uid, pid, follow.id, chapter_key=unquoted)

    # The client pushes the raw, still-encoded spelling.
    ProgressService(db_session, user_id=uid, profile_id=pid).save_one(
        _push(chapter_key=raw)
    )

    db_session.refresh(notif)
    assert notif.is_read, (
        "the encoded and decoded spellings of one chapter did not meet"
    )


def test_an_already_read_notification_is_not_rewritten(
    db_session, acct, seed_follow
):
    uid, pid = acct
    follow = seed_follow(uid, pid, source_id=SRC, series_key=SERIES)
    notif = _notify(db_session, uid, pid, follow.id)
    notif.is_read = True
    db_session.commit()

    ProgressService(db_session, user_id=uid, profile_id=pid).save_one(_push())

    db_session.refresh(notif)
    assert notif.is_read
