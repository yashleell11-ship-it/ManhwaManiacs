"""Shared definition of what counts as mature (18+) content, and the single
place that answers "is the 18+ gate open for this caller right now?".

Everything that gates adult content goes through this module. That is
deliberate: the gate previously lived in two unconnected places -- a global
``Settings.mature_content_enabled`` read by the browse layer and a per-profile
``ReadingProfile.mature_content_enabled`` written by the clients -- so flipping
the switch in the app changed the value the app read back and nothing else.
One resolution path (:func:`resolve_mature_gate`) and one rating rule
(:func:`is_mature_rating` / :func:`mature_rating_predicate`) is what keeps those
two halves from drifting apart again.

Two things are gated, by two signals:

- whole *sources* that are adult by nature (``SourceConnector.is_mature`` /
  ``ConnectorDescriptor.mature``); and
- individual *series* by :func:`resolve_series_rating`, one rule applied to
  whatever signal the surface has -- a follow's stored rating and override
  (:func:`resolve_tracker_rating`), a cached row's, or the genres a connector
  has only just returned.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from sqlalchemy import case, func, literal
from sqlalchemy.orm import Session

from core.connector_directory import gated_source_ids, is_mature_source
from database.models import FollowedSeries, ReadingProfile

if TYPE_CHECKING:  # pragma: no cover - typing only
    from connectors.registry import ConnectorDescriptor

#: Series ``content_rating`` values (compared case-insensitively) that denote
#: adult / 18+ content. Mirrors common source vocabularies -- e.g. MangaDex
#: uses "erotica" and "pornographic".
MATURE_CONTENT_RATINGS: frozenset[str] = frozenset(
    {
        "pornographic",
        "erotica",
        "smut",
        "hentai",
        "adult",
        "mature",
        "nsfw",
        "18+",
        "r18",
        "r-18",
    }
)

#: Resolved maturity of a followed remote series. ``"unknown"`` is a real third
#: state, not a synonym for either of the others -- see
#: :func:`resolve_series_rating`.
TRACKER_RATING_MATURE = "mature"
TRACKER_RATING_SAFE = "safe"
TRACKER_RATING_UNKNOWN = "unknown"


def is_mature_rating(content_rating: str | None) -> bool:
    """Whether a series ``content_rating`` denotes adult (18+) content."""
    if not content_rating:
        return False
    return content_rating.strip().lower() in MATURE_CONTENT_RATINGS


def mature_rating_predicate(column):
    """SQL mirror of :func:`is_mature_rating`: TRUE when ``column`` is adult.

    ``trim`` is applied because the Python rule strips whitespace and the SQL
    rule used not to, so a stored ``" adult"`` was mature in one layer and safe
    in the other. ``coalesce`` is applied because ``IN`` against NULL evaluates
    to NULL, and a ``NOT IN`` filter therefore *dropped* unrated rows instead of
    keeping them -- the opposite of what an unrated row should do (see
    :func:`resolve_series_rating` on why unknown is not treated as adult).
    """
    normalized = func.lower(func.trim(func.coalesce(column, "")))
    return normalized.in_(sorted(MATURE_CONTENT_RATINGS))


def resolve_mature_gate(
    db: Session,
    profile_id: int | None,
    user_id: int | None = None,
) -> bool:
    """Is adult content allowed for this (user, profile) right now?

    The active profile's own toggle is the ONLY thing that opens the gate.
    Every gated read path resolves the gate here so profile "action" having 18+
    off can never affect profile "porn".

    No owned profile -- header absent, naming another account's profile, or an
    account that has none yet -- is CLOSED. The instance-wide
    ``Settings.mature_content_enabled`` used to be the fallback for exactly
    that bucket, which made the gate for a headerless request from an account
    whose every profile has 18+ OFF whatever the admin last wrote there: closed
    today only because the default happens to be False, and the one request
    shape a client cannot fail to produce (drop a header) would have widened
    what it could see. The global still seeds nothing either (see
    ``ProfileService.create_profile``); it survives only for the context-free
    ``BrowseService`` fallback that has no caller at all.

    ``user_id`` is optional only because the callers that predate it already
    pass a ProfileContext-validated id. Pass it whenever you have it: this
    function is deliberately the single resolution path and will attract new
    callers, and one that forwards a raw header would otherwise read another
    account's gate. A mismatch is closed rather than honouring the foreign
    profile.
    """
    if profile_id is not None:
        profile = db.get(ReadingProfile, profile_id)
        if profile is not None and (user_id is None or profile.user_id == user_id):
            return bool(profile.mature_content_enabled)
    return False


def resolve_series_rating(
    content_rating: str | None,
    genres: tuple[str, ...] | list[str] | None = None,
    *,
    mature_override: bool | None = None,
    source_mature: bool = False,
) -> str:
    """Maturity of ONE series, resolved in priority order. The whole rule.

    Every surface that shows a series resolves it here -- a followed row
    (:func:`resolve_tracker_rating`), a browsed catalog row, a cached one --
    because the signals differ per surface but the ORDER they are believed in
    must not. Browse had no rating rule at all until this existed: it gated by
    SOURCE only, so an adult series listed on a general-audience source was
    served to the very profile whose library hides it.

    A remote series has no local row to read a rating off and
    ``connectors.models.Series`` carries no rating field, so the rating has to
    be assembled from what is actually available:

    1. ``mature_override`` -- the user said so explicitly. Wins over everything,
       and is the only signal that works for the many dead connectors where no
       metadata will ever arrive again. Only a followed row can carry one.
    2. ``content_rating``: captured at follow time on a follow, written by the
       metadata cache on a cached row, and derived from ``genres`` here for a
       row that has only just been browsed. All three are
       :func:`rating_from_genres` over the same connector genres, so the
       library and the browser cannot disagree about a series.
    3. The *source's* own maturity: a series on an 18+ source is 18+ by
       construction. Free to evaluate, needs no network, and this is where the
       owner's adult content actually comes from (toonily, nhentai, hentai20…).
    4. Otherwise unknown.

    Where the signal is ambiguous we err towards hiding: a *hint* of adult
    content in rule 2 (any genre matching MATURE_CONTENT_RATINGS) is enough, and
    rule 3 condemns the whole source rather than asking for per-series proof --
    the failure the owner cares about is 18+ content appearing where he did not
    expect it, so a false hide (one tap on "not 18+") costs far less than a
    false show.

    Unknown is deliberately NOT folded into mature, and that is the one place
    this module does not err towards hiding. ``Series.content_rating`` defaults
    to the literal string ``"unknown"`` and nothing populates it on folder
    import, so unknown-as-adult would blank the owner's entire library the first
    time he turned the gate off -- he would turn it back on permanently and the
    gate would protect nothing at all. Unknown is instead surfaced *and marked*
    (serialized as ``rating: "unknown"``) so the client can badge it and offer
    the one-tap override that writes rule 1.
    """
    if mature_override is not None:
        return TRACKER_RATING_MATURE if mature_override else TRACKER_RATING_SAFE
    rating = content_rating or rating_from_genres(genres)
    if rating:
        return TRACKER_RATING_MATURE if is_mature_rating(rating) else TRACKER_RATING_SAFE
    return TRACKER_RATING_MATURE if source_mature else TRACKER_RATING_UNKNOWN


def serialized_series_rating(
    item: dict[str, object], *, source_mature: bool = False
) -> str:
    """:func:`resolve_series_rating` for an already-SERIALIZED series row.

    Cache and listing payloads are dicts, not model rows, and they carry the
    rating under one name and the genres under another. Reaching for them here
    rather than at each call site is what stops a surface from gating on
    ``content_rating`` alone and missing the genre-only rows that are most of
    what a madara source publishes.
    """
    genres = item.get("genres")
    return resolve_series_rating(
        item.get("content_rating"),  # type: ignore[arg-type]
        genres if isinstance(genres, (list, tuple)) else None,
        source_mature=source_mature,
    )


def hidden_by_gate(rating: str, *, gate_open: bool) -> bool:
    """Whether a resolved rating must be withheld from this caller.

    One line, shared, because it is the half of the gate that keeps getting
    written as ``rating != safe``: only MATURE is ever hidden. Unknown is
    visible on purpose (rule 4 above), and a surface that hides it would empty
    itself the first time the owner shut the gate.
    """
    return not gate_open and rating == TRACKER_RATING_MATURE


def resolve_tracker_rating(
    followed: FollowedSeries,
    descriptor: ConnectorDescriptor | None,
) -> str:
    """:func:`resolve_series_rating` read off a *followed remote* series.

    Source-native (spec §3.2): the signals live on the ``followed_series`` row
    (``mature_override`` + ``content_rating``, same semantics as the old
    ``series_trackers`` columns), and the source's own maturity comes from the
    connector descriptor. A follow carries no genres of its own -- the rating
    was derived from them at follow time and stored.

    With no descriptor the source may have been REMOVED rather than never
    existed, and a follow outlives its connector: an adult source's id stays
    adult (:func:`core.connector_directory.is_mature_source`), or deregistering
    it would show its unrated follows to a profile with 18+ off.
    """
    return resolve_series_rating(
        followed.content_rating,
        mature_override=followed.mature_override,
        source_mature=(
            bool(descriptor.mature)
            if descriptor is not None
            else is_mature_source(followed.source_id)
        ),
    )


#: Source-native alias. New callers should use this name.
resolve_followed_rating = resolve_tracker_rating


def mature_tracker_case(source_column):
    """SQL mirror of :func:`resolve_tracker_rating`: 1 when 18+, else 0.

    Same priority order as the Python authority above -- explicit override,
    then the rating captured at follow time, then the source's own maturity --
    read off a joined ``followed_series`` row and ``source_column``, the
    ``source_id`` of whatever table is being gated.

    That column is the *only* thing that differed across the five hand-copied
    versions of this expression this replaced (reading sessions, chapter
    progress twice, bookmarks, notifications), which is why it is the only
    parameter. Five copies of a gate is a drift risk with teeth: the next fix
    to one leaves four unfixed, and the failure is silent -- a series hidden on
    four surfaces and printed by name on the fifth.

    Unknown stays 0, for the reason recorded on :func:`resolve_series_rating`.
    The source half reads :func:`core.connector_directory.gated_source_ids`, not
    the installed adult set, so a removed 18+ source keeps its rows gated here
    exactly as it does in the Python rule.

    The *join* supplying the ``followed_series`` row stays with the caller and
    is deliberately NOT uniform -- outer or inner, conditional or
    unconditional, on the composite key or on a foreign key -- because each
    answers for a different table for reasons recorded at each call site. Only
    the rating rule is shared here; the shape of the read is not.
    """
    mature_sources = gated_source_ids()
    source_mature = (
        case((source_column.in_(mature_sources), 1), else_=0)
        if mature_sources
        else literal(0)
    )
    return case(
        (FollowedSeries.mature_override == 1, 1),
        (FollowedSeries.mature_override == 0, 0),
        (
            FollowedSeries.content_rating.is_not(None),
            case(
                (mature_rating_predicate(FollowedSeries.content_rating), 1),
                else_=0,
            ),
        ),
        else_=source_mature,
    )


def rating_from_genres(genres: tuple[str, ...] | list[str] | None) -> str | None:
    """Derive a stored ``content_rating`` from a connector's genre tuple.

    Madara-family sites routinely tag adult works "Adult", "Mature" or "Smut"
    and expose nothing else machine-readable, so a genre hit is the only rating
    signal available at follow time. Returns the matched vocabulary term (so the
    stored value round-trips through :func:`is_mature_rating`) or ``None`` when
    nothing matched -- ``None`` means "no signal", which resolves to unknown
    rather than to safe.
    """
    for genre in genres or ():
        normalized = (genre or "").strip().lower()
        if normalized in MATURE_CONTENT_RATINGS:
            return normalized
    return None
