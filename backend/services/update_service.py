"""Automatic update engine, source-native (spec §4.5).

Each pass diffs every ``followed_series.known_chapters`` snapshot against a live
connector chapter list. New chapters produce an ``update_notifications`` row
(notification only — the client decides whether to download) and refresh
``source_series_cache``. ``known_chapters`` is then updated to the new list.

No auto-download, no ``register_new_chapters_callback``, no ``SeriesTracker``
migration machinery — all removed. Single-process threaded loop unchanged
(``update_scheduler``).
"""

from __future__ import annotations

import json
import logging
import threading
import time
from datetime import timedelta
from typing import Annotated, Any

from fastapi import Depends
from sqlalchemy import delete, func, select
from sqlalchemy.orm import Session

from connectors.ids import fully_unquote
from connectors.registry import list_installed_connectors
from core.config import get_settings
from core.connector_directory import descriptor_for_source
from core.content_rating import (
    TRACKER_RATING_MATURE,
    mature_tracker_case,
    resolve_followed_rating,
    resolve_mature_gate,
)
from core.errors import AppError
from core.time_utils import utcnow
from database.models import (
    FollowedSeries,
    UpdateNotification,
    UpdateRun,
    UpdateSettings,
)
from database.session import SessionLocal, get_db

logger = logging.getLogger(__name__)

# Indirection so tests can drive the sweep's clock deterministically.
_monotonic = time.monotonic

# Retention for the two tables the sweep only ever appends to. ``update_runs``
# gained a row per pass (~35 a day once boot-time sweeps were counted) and a
# notification, once read, was never removed; neither is ever consulted past
# this horizon — the run log is a short diagnostic tail and a read notification
# is a dismissed badge. Unread rows are kept regardless of age: they are the
# owner's still-pending news.
_RUN_HISTORY_KEEP = 200
_READ_NOTIFICATION_TTL = timedelta(days=90)

# One guard per followed-series id, created on first use. Checks reach this
# module from two threads — the scheduler's worker and the request thread of
# ``POST /updates/followed/{id}/check`` — and ``_check_one`` explains what the
# guard protects. Keyed by id and never reaped: a guard is 40-odd bytes and the
# key space is the number of follows on the instance.
_series_guards: dict[int, threading.Lock] = {}
_series_guards_lock = threading.Lock()


def _series_guard(followed_id: int) -> threading.Lock:
    with _series_guards_lock:
        guard = _series_guards.get(followed_id)
        if guard is None:
            guard = threading.Lock()
            _series_guards[followed_id] = guard
        return guard


def _bool(value: Any) -> bool:
    return bool(value)


def _loads(value: str | None) -> list[dict[str, Any]]:
    if not value:
        return []
    try:
        data = json.loads(value)
        return data if isinstance(data, list) else []
    except (ValueError, TypeError):
        return []


class UpdateService:
    def __init__(
        self,
        db: Session,
        *,
        user_id: int | None = None,
        profile_id: int | None = None,
        system: bool = False,
    ) -> None:
        """``system=True`` marks the background worker's service.

        The scheduled sweep runs with no request context and legitimately walks
        every account's rows. A *request*-built service never may, so the flag
        is opt-in and off by default: a caller that forgets it gets the scoped,
        safe behaviour rather than the unrestricted one.
        """
        self._db = db
        self._user_id = user_id
        self._profile_id = profile_id
        self._system = system
        # Resolved once: the gate is a property of the (user, profile) pair,
        # which cannot change mid-request.
        self._gate_cache: bool | None = None

    # --- the 18+ gate ---------------------------------------------------

    def _gate_open(self) -> bool:
        """Is 18+ content allowed for this (user, profile)?

        Resolved through ``resolve_mature_gate`` — the single resolution path.
        Reading ``get_settings().mature_content_enabled`` here instead is what
        once made the in-app toggle inert, and it would make this gate answer
        for the *instance* rather than for the profile holding the phone.
        """
        if self._gate_cache is None:
            self._gate_cache = resolve_mature_gate(
                self._db, self._profile_id, self._user_id
            )
        return self._gate_cache

    # --- global settings ------------------------------------------------

    def get_global_settings(self) -> UpdateSettings:
        row = self._db.get(UpdateSettings, 1)
        if row is None:
            row = UpdateSettings(id=1)
            self._db.add(row)
            self._db.commit()
            self._db.refresh(row)
        return row

    def update_global_settings(self, payload: dict[str, Any]) -> dict[str, Any]:
        row = self.get_global_settings()
        for field in (
            "enabled",
            "notify_enabled",
            "check_on_startup",
        ):
            if field in payload and payload[field] is not None:
                setattr(row, field, bool(payload[field]))
        if payload.get("check_interval_minutes") is not None:
            row.check_interval_minutes = max(5, int(payload["check_interval_minutes"]))
        row.updated_at = utcnow()
        self._db.commit()
        self._db.refresh(row)
        return self.serialize_settings(row)

    @staticmethod
    def serialize_settings(row: UpdateSettings) -> dict[str, Any]:
        return {
            "enabled": _bool(row.enabled),
            "check_interval_minutes": row.check_interval_minutes,
            "notify_enabled": _bool(row.notify_enabled),
            "check_on_startup": _bool(row.check_on_startup),
            "last_run_at": row.last_run_at.isoformat() if row.last_run_at else None,
        }

    # --- notifications ------------------------------------------------

    def _notif_scope(self, stmt):
        """(user, profile) scope for ``update_notifications``.

        The ``user_id`` predicate is **unconditional**, matching
        ``_followed_scope`` below and ``progress_service._scope``. Guarding it
        on ``self._user_id is not None`` — which this did — is the one shape
        that fails *open*: an unscoped service dropped the predicate entirely
        and the statement then spanned every account's notifications. No caller
        reaches it that way today — ``/updates/*`` is not in
        ``auth_service._PUBLIC_ROUTES``, so the route always has a user — but a
        scope whose safety rests on which routes happen to be public is one
        router change away from being wrong, and its siblings fail closed.

        ``profile_id`` is NOT NULL, so ``None`` is the empty legacy bucket
        rather than a wildcard: an unscoped caller correctly sees nothing.
        """
        stmt = stmt.where(UpdateNotification.user_id == self._user_id)
        if self._profile_id is None:
            return stmt.where(UpdateNotification.profile_id.is_(None))
        return stmt.where(UpdateNotification.profile_id == self._profile_id)

    def _mature_case(self):
        """1 when a notification's series is 18+ for this profile, else 0.

        The rule is :func:`core.content_rating.mature_tracker_case` — shared
        outright, rather than copied from ``bookmark_service._mature_case`` as
        it once was, so the badge and every other gated listing cannot disagree
        about what is adult. All this names is the column the source's own
        maturity is read from.
        """
        return mature_tracker_case(UpdateNotification.source_id)

    def _visible_notifications(self, stmt):
        """``_notif_scope`` plus this profile's 18+ gate.

        A notification prints ``series_key`` and ``chapter_title``, so a profile
        with the gate shut was told in plain text about new chapters of its own
        mature series — hidden from it in browse, in the library and on the home
        strips, and listed here. The scope was never the problem; the missing
        gate was.

        ``followed_series_id`` is what resolves the rating, the same technique
        ``continue_reading`` uses, and here it is a single primary-key equality
        because the FK already names the exact row: ``_check_one`` writes the
        notification's ``user_id`` / ``profile_id`` off the very follow it
        diffed, so the joined row is always the caller's own.

        Joined only when the gate is shut, like
        ``reading_stats_service._sessions``: with the gate open there is nothing
        to resolve and the statement keeps its old shape. The join is *outer* so
        a notification whose follow row has gone is not silently dropped — with
        no row to read an override off, ``_mature_case`` falls through to the
        notification's own source, which still hides it if that source is adult.
        """
        stmt = self._notif_scope(stmt)
        if self._gate_open():
            return stmt
        return stmt.outerjoin(
            FollowedSeries,
            UpdateNotification.followed_series_id == FollowedSeries.id,
        ).where(self._mature_case() == 0)

    def list_notifications(
        self, *, unread_only: bool = False, limit: int = 100
    ) -> list[dict[str, Any]]:
        stmt = self._visible_notifications(select(UpdateNotification))
        if unread_only:
            stmt = stmt.where(UpdateNotification.is_read.is_(False))
        stmt = stmt.order_by(UpdateNotification.created_at.desc()).limit(limit)
        return [
            self.serialize_notification(n)
            for n in self._db.execute(stmt).scalars().all()
        ]

    def count_notifications(self, *, unread_only: bool = False) -> int:
        """Cardinality of exactly what ``list_notifications`` would return.

        Gated for the same reason the listing is, and then some: this is the
        unread badge. A count that includes hidden rows discloses that mature
        chapters landed, and leaves the client showing a badge for something the
        user cannot open — the number never goes down however much they read.
        """
        stmt = self._visible_notifications(
            select(func.count()).select_from(UpdateNotification)
        )
        if unread_only:
            stmt = stmt.where(UpdateNotification.is_read.is_(False))
        return int(self._db.execute(stmt).scalar_one() or 0)

    def unread_count(self) -> int:
        return self.count_notifications(unread_only=True)

    @staticmethod
    def serialize_notification(row: UpdateNotification) -> dict[str, Any]:
        return {
            "id": row.id,
            "followed_series_id": row.followed_series_id,
            "source_id": row.source_id,
            "series_key": row.series_key,
            "chapter_key": row.chapter_key,
            "chapter_title": row.chapter_title,
            "chapter_number": row.chapter_number,
            "is_read": _bool(row.is_read),
            "created_at": row.created_at.isoformat() if row.created_at else None,
        }

    def mark_notification_read(self, notification_id: int) -> dict[str, Any]:
        """Mark one of *this profile's visible* notifications read, or 404.

        List / count / read-all are per-profile, so the ``user_id``-only check
        that used to live here let one profile clear a sibling's unread badge by
        guessing an id — the notification stayed invisible to them and simply
        vanished from the owner's count.

        Resolved through ``_visible_notifications`` rather than by hand so
        "addressable" and "listed" are one definition: a row withheld by the
        18+ gate 404s like one that does not exist, which is this codebase's
        convention (``browse_service`` ~L563) and also denies the 200-vs-404
        oracle that would otherwise confirm a hidden notification is there.
        """
        row = self._db.execute(
            self._visible_notifications(
                select(UpdateNotification).where(
                    UpdateNotification.id == notification_id
                )
            )
        ).scalars().one_or_none()
        if row is None:
            raise AppError(
                "Notification not found.", code="not_found", status_code=404
            )
        row.is_read = True
        self._db.commit()
        return self.serialize_notification(row)

    def mark_all_notifications_read(self) -> dict[str, int]:
        """Clear the unread badge — over exactly what the badge counted.

        Gated with the listing, not merely scoped with it: a bulk clear that
        reached rows the profile cannot see would consume its own mature
        notifications unread, so turning the gate back on would surface a
        library of new chapters already marked as seen.
        """
        stmt = self._visible_notifications(
            select(UpdateNotification).where(UpdateNotification.is_read.is_(False))
        )
        rows = self._db.execute(stmt).scalars().all()
        for row in rows:
            row.is_read = True
        self._db.commit()
        return {"updated": len(rows)}

    # --- runs -------------------------------------------------------

    def list_runs(self, *, limit: int = 20) -> list[dict[str, Any]]:
        rows = self._db.execute(
            select(UpdateRun).order_by(UpdateRun.started_at.desc()).limit(limit)
        ).scalars().all()
        return [self.serialize_run(r) for r in rows]

    def count_runs(self) -> int:
        return int(
            self._db.execute(
                select(func.count()).select_from(UpdateRun)
            ).scalar_one()
            or 0
        )

    def get_run(self, run_id: int) -> dict[str, Any]:
        row = self._db.get(UpdateRun, run_id)
        if row is None:
            raise AppError("Run not found.", code="not_found", status_code=404)
        return self.serialize_run(row)

    @staticmethod
    def serialize_run(row: UpdateRun) -> dict[str, Any]:
        return {
            "id": row.id,
            "trigger": row.trigger,
            "status": row.status,
            "series_checked": row.series_checked,
            "new_chapters_found": row.new_chapters_found,
            "error": row.error,
            "started_at": row.started_at.isoformat() if row.started_at else None,
            "finished_at": row.finished_at.isoformat()
            if row.finished_at
            else None,
        }

    def list_sources(self) -> list[dict[str, str]]:
        """Browsable sources, filtered through the caller's 18+ gate.

        ``include_mature`` defaults to True in the registry, so omitting it
        here disclosed every installed adult connector's id and name to
        mature-gated profiles — the exact disclosure ``GET /sources`` /
        ``/sources/health`` / ``/system/source-health`` were built to prevent
        (audit finding 3). The system-scoped service (background sweep) keeps
        the full view; it serves no client.
        """
        include_mature = True if self._system else self._gate_open()
        return [
            {"id": d.source_type, "name": d.name}
            for d in list_installed_connectors(
                browsable_only=True, include_mature=include_mature
            )
        ]

    # --- the check sweep -------------------------------------------

    def _followed_scope(self, stmt):
        stmt = stmt.where(FollowedSeries.user_id == self._user_id)
        if self._profile_id is None:
            return stmt.where(FollowedSeries.profile_id.is_(None))
        return stmt.where(FollowedSeries.profile_id == self._profile_id)

    def _within_gate(self, rows: list[FollowedSeries]) -> list[FollowedSeries]:
        # Ownership is not the only thing that puts a row out of reach. With the
        # gate shut a mature follow is 404 everywhere else it is addressed by id
        # (``followed_series_service.get_detail``), and ``_check_one`` now runs
        # its connector fetch ungated -- so without this a gated profile could
        # still hand its OWN hidden row's id to ``/updates/check`` and drive a
        # fetch it is not allowed to see the result of. Same rating rule as the
        # library listing, so the two cannot disagree about what is adult.
        if self._gate_open():
            return list(rows)
        return [
            r
            for r in rows
            if resolve_followed_rating(r, descriptor_for_source(r.source_id))
            != TRACKER_RATING_MATURE
        ]

    def owned_followed_ids(self) -> list[int]:
        """Every follow in this (user, profile) scope the caller may check.

        The id-less ``POST /updates/check`` used to fall through to the same
        unfiltered statement the scheduler runs, so any member could sweep
        every account's rows -- rewriting their snapshots, consuming their
        notification windows -- and read the aggregate back off the run log.
        A member's "check now" is their own library, resolved here; the
        instance-wide sweep belongs to the scheduler and to admins.

        Filtered silently rather than 404'd like ``resolve_followed_ids``:
        nothing was named, so a follow the gate hides is simply not part of
        the library being checked. The scheduled sweep still covers it.
        """
        rows = self._db.execute(
            self._followed_scope(select(FollowedSeries))
        ).scalars().all()
        return [r.id for r in self._within_gate(rows)]

    def resolve_followed_ids(self, followed_ids: list[int]) -> list[int]:
        """Validate caller-supplied followed-series ids against this scope.

        Without this, ``followed_ids`` was applied to an otherwise unscoped
        statement: **any authenticated user could force a check on any other
        account's row**, rewriting its ``known_chapters`` / ``last_checked_at``
        / ``last_error`` and silently consuming its notification window (a
        chapter diffed away by somebody else's forced check never notifies the
        owner, because the next real run no longer sees it as new).

        Raises 404 rather than filtering silently: an id the caller does not own
        is indistinguishable, to them, from one that does not exist.
        """
        wanted = list(dict.fromkeys(followed_ids))
        if self._system:
            return wanted
        rows = self._db.execute(
            self._followed_scope(
                select(FollowedSeries).where(FollowedSeries.id.in_(wanted))
            )
        ).scalars().all()
        owned = {r.id for r in self._within_gate(rows)}
        missing = [i for i in wanted if i not in owned]
        if missing:
            raise AppError(
                "Followed series not found.",
                code="series_not_found",
                status_code=404,
                details={"followed_ids": missing},
            )
        return wanted

    def run_check(
        self,
        *,
        trigger: str = "manual",
        followed_ids: list[int] | None = None,
        tracker_ids: list[int] | None = None,  # legacy alias
    ) -> dict[str, Any]:
        if followed_ids is None:
            followed_ids = tracker_ids
        # ``[]`` is a real filter, not "no filter". A member whose library is
        # empty asks for a check of nothing; collapsing that to ``None`` (which
        # ``followed_ids or tracker_ids`` did) handed them the instance-wide
        # sweep ``owned_followed_ids`` exists to withhold.
        if followed_ids is not None:
            # Scoped *before* the run row is written, so an out-of-scope id
            # leaves no trace in the run log either.
            followed_ids = self.resolve_followed_ids(followed_ids)
        if trigger == "startup" and not self.startup_sweep_due():
            # No run row either: the row is what a *pass* leaves behind, and the
            # whole point is that no pass happened.
            logger.info(
                "startup update sweep skipped: the last sweep is within the "
                "check interval"
            )
            return self.serialize_run(
                UpdateRun(
                    trigger=trigger,
                    status="skipped",
                    series_checked=0,
                    new_chapters_found=0,
                )
            )
        run = UpdateRun(trigger=trigger, status="running")
        self._db.add(run)
        self._db.commit()
        self._db.refresh(run)

        checked = 0
        new_found = 0
        try:
            # Sweep every followed series: ``known_chapters`` is kept fresh even
            # when the row's ``notify`` flag is off, so flipping it on later does
            # not backfill a notification storm. ``notify`` gates only whether a
            # new chapter produces an ``update_notifications`` row (``_check_one``).
            #
            # The id-less full sweep is deliberately unscoped — it is the
            # scheduler's (and an admin's) job to check every account. Targeted
            # ids went through ``resolve_followed_ids`` above; the route
            # resolves a member's id-less request to their own ids first.
            stmt = select(FollowedSeries)
            if followed_ids is not None:
                stmt = stmt.where(FollowedSeries.id.in_(followed_ids))
            rows = self._db.execute(stmt).scalars().all()

            # Guardrails (audit finding 14): the sweep is a sequential,
            # network-bound walk with a 30s×3-retry budget per fetch, so a
            # large followed set plus a wedged upstream used to make a single
            # run outlast its check interval by hours. Two ceilings, both
            # env-tunable and disabled at 0:
            #   * per-source HTTP budget — once a source has burned its
            #     seconds this pass, its remaining rows are skipped (their
            #     snapshots are untouched; the next run retries them);
            #   * whole-run deadline — the pass stops checking and reports
            #     how much it left on the table.
            cfg = get_settings()
            source_budget = max(0, cfg.update_sweep_source_budget_seconds)
            deadline = max(0, cfg.update_sweep_deadline_minutes) * 60
            sweep_started = _monotonic()
            source_spent: dict[str, float] = {}

            for row in rows:
                if deadline and _monotonic() - sweep_started >= deadline:
                    remaining = len(rows) - checked
                    run.error = (
                        f"Sweep deadline reached; {remaining} of {len(rows)} "
                        "series not checked this pass."
                    )
                    logger.warning("update sweep hit its deadline: %s", run.error)
                    break
                if (
                    source_budget
                    and source_spent.get(row.source_id, 0.0) >= source_budget
                ):
                    logger.debug(
                        "update sweep skipping %s/%s: source budget spent",
                        row.source_id,
                        row.series_key,
                    )
                    continue
                row_started = _monotonic()
                try:
                    new_found += self._check_one(row)
                    checked += 1
                except Exception as exc:  # noqa: BLE001 - one dead source never aborts the sweep
                    # A failure inside a flush leaves the session refusing every
                    # later statement until it is rolled back, so without this
                    # the commit below re-raised, the run row was never
                    # finalised, and one bad row 500'd the whole sweep.
                    self._db.rollback()
                    row.last_error = str(exc)[:500]
                    logger.warning(
                        "update check failed for %s/%s: %s",
                        row.source_id,
                        row.series_key,
                        exc,
                    )
                finally:
                    source_spent[row.source_id] = source_spent.get(
                        row.source_id, 0.0
                    ) + (_monotonic() - row_started)
                self._db.commit()
            run.status = "completed"
        except Exception as exc:  # noqa: BLE001
            # Same reason as the per-row rollback: the run row below must be
            # writable whatever state the failure left the session in.
            self._db.rollback()
            run.status = "failed"
            run.error = str(exc)[:500]
            logger.exception("update run failed")
        finally:
            run.series_checked = checked
            run.new_chapters_found = new_found
            run.finished_at = utcnow()
            settings = self.get_global_settings()
            settings.last_run_at = run.finished_at
            self._db.commit()

        if followed_ids is None:
            self._prune_history()
        return self.serialize_run(run)

    def check_followed_by_id(self, followed_id: int) -> dict[str, Any]:
        return self.run_check(trigger="manual", followed_ids=[followed_id])

    # legacy alias kept for routes/scheduler that still say "tracker"
    def check_tracker_by_id(self, tracker_id: int) -> dict[str, Any]:
        return self.check_followed_by_id(tracker_id)

    def startup_sweep_due(self) -> bool:
        """Whether a boot-time sweep would find anything the last one did not.

        Every deploy recreates the container and every boot queued a full
        sweep, so a day of deploys hit each upstream several times inside one
        check interval (42 ``startup`` runs in three days). The run log already
        records when the instance was last swept; a boot inside the interval
        adds nothing, and the scheduler loop sweeps on schedule regardless.

        Only ``scheduled`` / ``startup`` passes count as evidence: a ``manual``
        run may be one member's per-series check, which says nothing about the
        rest of the instance, and a failed run says nothing at all.
        """
        last = self._db.execute(
            select(func.max(UpdateRun.finished_at)).where(
                UpdateRun.status == "completed",
                UpdateRun.trigger.in_(("scheduled", "startup")),
            )
        ).scalar_one()
        if last is None:
            return True
        interval = max(self.get_global_settings().check_interval_minutes, 5)
        return utcnow() - last >= timedelta(minutes=interval)

    def _prune_history(self) -> None:
        """Bound the run log and the read-notification backlog after a sweep.

        Its own transaction, and never allowed to fail the run it follows: the
        sweep's result is already committed, and a lost prune is a handful of
        rows the next pass removes.
        """
        try:
            keep = (
                select(UpdateRun.id)
                .order_by(UpdateRun.started_at.desc(), UpdateRun.id.desc())
                .limit(_RUN_HISTORY_KEEP)
            )
            self._db.execute(
                delete(UpdateRun)
                .where(UpdateRun.id.not_in(keep))
                .execution_options(synchronize_session=False)
            )
            self._db.execute(
                delete(UpdateNotification)
                .where(
                    UpdateNotification.is_read.is_(True),
                    UpdateNotification.created_at
                    < utcnow() - _READ_NOTIFICATION_TTL,
                )
                .execution_options(synchronize_session=False)
            )
            self._db.commit()
        except Exception:  # noqa: BLE001 - retention must never fail the run it follows
            logger.exception("update history prune failed")
            self._db.rollback()

    def _check_one(self, row: FollowedSeries) -> int:
        """Diff one followed series against its live connector chapter list.

        Returns the number of new chapters found.
        """
        # Local import: browse_service pulls in the connector stack, and the
        # scheduler builds this service on a bare session.
        from services.browse_service import BrowseService
        from services.source_cache_service import SourceCacheService

        # The sweep is a SYSTEM actor with no viewer, so it carries no 18+ gate
        # of its own. Leaving ``mature_enabled`` unset made BrowseService fall
        # back to the global ``mature_content_enabled`` -- False on a stock
        # deployment -- and ``_get_connector`` then 404'd every adult source, so
        # a series followed on one was never checked: ``last_error`` on every
        # run, ``known_chapters`` frozen, its owner never notified. The gate that
        # matters is the *reader's*, and it is applied where the notification is
        # read (``_visible_notifications``); ids arriving from a request have
        # already been gate-checked by ``resolve_followed_ids``.
        browse = BrowseService(mature_enabled=True, db=self._db)
        cache = SourceCacheService(self._db, browse)

        live = browse.get_chapters(row.source_id, row.series_key)

        # Reading the snapshot, diffing it and writing the new one back is one
        # critical section per followed series. The per-series manual check
        # (``POST /updates/followed/{id}/check``) runs this inline on the request
        # thread while the scheduled sweep runs it on a worker thread, and
        # neither took the other's lock — the scheduler's ``_check_lock`` gates
        # only what it submits to its own pool, never the request path: both
        # loaded the row, both diffed the same stale ``known_chapters``, and
        # both inserted a notification for every new chapter — a UNIQUE
        # violation on ``uq_update_notifications_chapter`` raised by the per-row
        # commit in ``run_check``, which fails the entire run rather than the
        # one series. The connector fetch stays outside the guard: it touches
        # nothing shared, and holding a lock across a 30s-per-retry HTTP budget
        # would park the request thread behind the sweep's network wait.
        with _series_guard(row.id):
            # Whoever held the guard may have just committed a newer snapshot,
            # and this row was loaded before the wait. ``None`` means the follow
            # was deleted meanwhile — there is nothing left to update.
            if self._db.get(FollowedSeries, row.id, populate_existing=True) is None:
                return 0
            known = _loads(row.known_chapters)

            if not live and known:
                # A connector that *degrades* to an empty list rather than
                # raising (markup drifted, a soft block, an empty page) is not
                # evidence the series lost every chapter. Writing [] here is
                # unrecoverable: the next run has no baseline, so every chapter
                # released in between never diffs as new and never notifies.
                # Keep the snapshot, record why, and let the next pass try again.
                row.last_error = "Source returned no chapters; snapshot kept."
                logger.warning(
                    "update check for %s/%s returned an empty chapter list; "
                    "keeping the %d-chapter snapshot",
                    row.source_id,
                    row.series_key,
                    len(known),
                )
                return 0

            cache.write_through(row.source_id, row.series_key, {}, live)
            known_keys = {str(c.get("key")) for c in known}

            new_chapters = [c for c in live if str(c["id"]) not in known_keys]
            settings = self.get_global_settings()
            if (
                new_chapters
                and known
                and _bool(row.notify)
                and _bool(settings.notify_enabled)
            ):
                # A chapter notifies a follow once — the guarantee
                # ``uq_update_notifications_chapter`` enforces. A connector that
                # drops a chapter from its listing and lists it again
                # (pagination hiccup, partial parse) makes it "new" a second
                # time, and a listing can even repeat an id within one fetch;
                # neither is an error, so skip what this follow has already been
                # told about instead of letting the INSERT fail the run.
                # Canonicalised on the way OUT too: rows written before keys
                # were canonicalised hold the connector's raw spelling, and
                # comparing those against a canonical key would miss and emit
                # one duplicate notification per such chapter.
                emitted = {
                    fully_unquote(k)
                    for k in self._db.execute(
                        select(UpdateNotification.chapter_key).where(
                            UpdateNotification.followed_series_id == row.id
                        )
                    )
                    .scalars()
                    .all()
                }
                for c in new_chapters:
                    # Canonicalised on the way in, because the notification is
                    # matched against chapter_progress later (progress_service
                    # marks a notification read once its chapter is opened) and
                    # THAT table stores fully_unquote'd keys. Two spellings of
                    # the same chapter would make the match silently find
                    # nothing, which looks exactly like the feature working.
                    key = fully_unquote(str(c["id"]))
                    if key in emitted:
                        continue
                    emitted.add(key)
                    self._db.add(
                        UpdateNotification(
                            user_id=row.user_id,
                            profile_id=row.profile_id,
                            followed_series_id=row.id,
                            source_id=row.source_id,
                            series_key=row.series_key,
                            chapter_key=key,
                            chapter_title=str(c.get("title") or c["id"]),
                            chapter_number=c.get("number"),
                        )
                    )

            row.known_chapters = json.dumps(
                [
                    {
                        "key": c.get("id"),
                        "number": c.get("number"),
                        "title": c.get("title"),
                        "published_at": c.get("release_date"),
                    }
                    for c in live
                ]
            )
            row.last_checked_at = utcnow()
            row.last_error = None
            # Committed before the guard is released: the next checker re-reads
            # this row on entry, and an uncommitted snapshot is one it cannot
            # see. ``run_check`` still commits per row for the paths above.
            self._db.commit()
            return len(new_chapters) if known else 0


def run_check_in_new_session(
    *,
    trigger: str = "scheduled",
    followed_ids: list[int] | None = None,
    tracker_ids: list[int] | None = None,
) -> dict[str, Any]:
    """Entry point for the background worker — owns its own session.

    ``system=True``: there is no request context here, and the scheduled sweep
    legitimately walks every account. Ids that arrive on this path have already
    been ownership-checked by the route that queued them
    (``UpdateService.resolve_followed_ids``).
    """
    if followed_ids is None:
        # Not ``or``: ``[]`` from a member with an empty library must stay an
        # empty check, never widen into the instance-wide sweep.
        followed_ids = tracker_ids
    db = SessionLocal()
    try:
        return UpdateService(db, system=True).run_check(
            trigger=trigger, followed_ids=followed_ids
        )
    finally:
        db.close()


def get_update_service(
    db: Session,
    *,
    user_id: int | None = None,
    profile_id: int | None = None,
) -> UpdateService:
    return UpdateService(db, user_id=user_id, profile_id=profile_id)


def get_update_service_dep(
    db: Annotated[Session, Depends(get_db)],
) -> UpdateService:
    return UpdateService(db)
