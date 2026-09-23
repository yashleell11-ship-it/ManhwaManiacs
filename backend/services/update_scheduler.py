"""Background scheduler and worker for automatic update checks.

Mirrors the OCR/download subsystem lifecycle:
- ``UpdateScheduler`` sleeps between scheduled checks.
- ``UpdateWorkerManager`` runs checks on a thread pool without blocking the API.

It also carries the daily cache retention sweep. That is not an update check,
but it wants exactly what this already has — one daemon thread that wakes on a
timer for the life of the process — and a second scheduler thread to run four
DELETEs a day would be infrastructure bought for nothing.
"""

from __future__ import annotations

import logging
import threading
import time
from concurrent.futures import ThreadPoolExecutor

from core.config import get_settings
from database.session import SessionLocal
from services.source_cache_service import sweep_cache_retention
from services.source_probe_service import reprobe_sources
from services.update_service import UpdateService, run_check_in_new_session

logger = logging.getLogger(__name__)

#: How often the cache retention sweep runs. Daily, because every rule it
#: applies is measured in days — a finer cadence would scan the same four
#: tables to delete nothing. The boot sweep in ``main`` covers the case this
#: cadence is bad at: a source deregistered by a deploy, whose rows should go
#: on the restart that deregistered it rather than up to a day later.
_CACHE_SWEEP_INTERVAL_SECONDS = 24 * 60 * 60

_update_manager: UpdateSchedulerManager | None = None
_update_manager_lock = threading.Lock()


class UpdateSchedulerManager:
    """Coordinates scheduled and on-demand update checks."""

    def __init__(self, *, max_workers: int | None = None) -> None:
        settings = get_settings()
        self._max_workers = max_workers or settings.update_workers
        self._executor: ThreadPoolExecutor | None = None
        self._scheduler_thread: threading.Thread | None = None
        self._stop_event = threading.Event()
        self._check_lock = threading.Lock()
        self._started = False
        #: ``None`` until something has swept for this manager. Not 0.0: on
        #: Linux ``monotonic()`` counts from system boot, so a zero baseline
        #: silently means "already swept" for the first day of uptime.
        self._last_cache_sweep: float | None = None

    def start(self) -> None:
        if self._started:
            return
        self._stop_event.clear()
        self._executor = ThreadPoolExecutor(
            max_workers=self._max_workers,
            thread_name_prefix="update-worker",
        )
        self._scheduler_thread = threading.Thread(
            target=self._scheduler_loop,
            name="update-scheduler",
            daemon=True,
        )
        self._started = True
        # Boot already swept (main lifespan), so the first scheduled sweep is a
        # day from now rather than immediately.
        self._last_cache_sweep = time.monotonic()
        # Commit the singleton settings row BEFORE any thread reads it, so the
        # scheduler thread and the startup-check always see a committed row and
        # never race to INSERT it simultaneously.
        self._ensure_settings_row()
        self._scheduler_thread.start()
        self._maybe_run_startup_check()

    def stop(self) -> None:
        self._stop_event.set()
        if self._executor is not None:
            self._executor.shutdown(wait=False, cancel_futures=True)
            self._executor = None
        if self._scheduler_thread is not None:
            self._scheduler_thread.join(timeout=2.0)
            self._scheduler_thread = None
        self._started = False

    @property
    def is_running(self) -> bool:
        """Whether the background worker pool is active (i.e. checks execute
        asynchronously). False in test/dev configurations started with
        ``run_workers=False``, where there is no worker thread to dispatch to."""
        return self._started

    def trigger_check(
        self,
        *,
        trigger: str = "manual",
        tracker_ids: list[int] | None = None,
    ) -> bool:
        """Queue an update check on the background worker pool.

        Returns False if the worker pool isn't running, or if a check is
        already in progress. Never blocks the caller — the check itself
        always executes on a worker thread, not the calling thread.
        """
        if not self._started or self._executor is None:
            return False
        if not self._check_lock.acquire(blocking=False):
            return False

        def _run() -> None:
            try:
                run_check_in_new_session(trigger=trigger, tracker_ids=tracker_ids)
            except Exception:
                logger.exception("Update check worker failed")
            finally:
                self._check_lock.release()

        self._executor.submit(_run)
        return True

    def _ensure_settings_row(self) -> None:
        """Create and commit the update_settings singleton before any thread touches it."""
        db = SessionLocal()
        try:
            UpdateService(db).get_global_settings()
            db.commit()
        except Exception:
            db.rollback()
            logger.exception("Failed to initialize update_settings singleton")
        finally:
            db.close()

    def _maybe_run_startup_check(self) -> None:
        db = SessionLocal()
        try:
            service = UpdateService(db)
            settings = service.get_global_settings()
            if settings.check_on_startup and settings.enabled:
                self.trigger_check(trigger="startup")
            db.commit()
        except Exception:
            db.rollback()
            logger.exception("Startup update check failed to queue")
        finally:
            db.close()

    def _scheduler_loop(self) -> None:
        sleep_seconds = self._first_sleep_seconds()
        while not self._stop_event.is_set():
            if self._stop_event.wait(timeout=sleep_seconds):
                break
            self._tick()
            sleep_seconds = max(self._current_interval_minutes() * 60, 60)

    def _first_sleep_seconds(self) -> float:
        """How long to wait before the first tick after boot.

        A full interval from the boot is right when the boot swept, and wrong
        when it did not: the startup check is skipped while the last sweep is
        still inside the interval, so sleeping a whole interval from there put
        the next sweep up to twice the interval after the last one — 113
        minutes on a 60-minute cadence, after every deploy. So when the last
        sweep is recent, wake when its interval runs out instead. When it is
        not, the startup check is sweeping right now (or was turned off), and
        a full interval from here is the next one.
        """
        full = max(self._current_interval_minutes() * 60, 60)
        db = SessionLocal()
        try:
            remaining = UpdateService(db).seconds_until_sweep_due()
        except Exception:
            logger.exception("Could not time the first scheduled sweep")
            return full
        finally:
            db.close()
        if remaining <= 0:
            return full
        return max(min(remaining, full), 60)

    def _tick(self) -> None:
        """One scheduler cycle: trigger a sweep iff scheduled checks are on.

        ``settings.enabled`` used to change only the sleep interval — the
        sweep itself ran regardless, so "disabled" still hammered every
        upstream on the config-default cadence (noted in audit findings
        1/5/6/7). Disabled now means no scheduled sweep; manual checks via
        ``POST /updates/check`` still work.

        Cache retention runs first and unconditionally: turning update checks
        off is a statement about contacting upstreams, not about letting the
        disk fill.
        """
        self._maybe_sweep_caches()
        self._reap_render_leases()
        self._maybe_reprobe_sources()
        if self._scheduled_checks_enabled():
            self.trigger_check(trigger="scheduled")

    def _reap_render_leases(self) -> None:
        """Put back render jobs whose box stopped answering.

        Unconditional, like the cache sweep and for a stronger reason: this is
        not about contacting anything. The render box is a desktop in a house.
        It sleeps, it reboots, it loses Wi-Fi mid-chapter — and without this
        the job it was holding says ``rendering`` forever and no worker will
        ever claim that chapter again.

        The lease is a wall clock precisely so this can run here, in a
        different process from the one that wrote it and usually after a
        restart. A monotonic clock would be meaningless across that boundary.
        """
        try:
            from database.session import SessionLocal
            from services.novel_render_queue import reap_expired
        except Exception:  # pragma: no cover - import guard
            return
        try:
            with SessionLocal() as db:
                if reap_expired(db):
                    db.commit()
        except Exception:
            # A scheduler tick must never die on this. The next tick tries
            # again, and a lease that is already expired stays expired.
            logger.exception("render lease reap failed")

    def _maybe_reprobe_sources(self) -> None:
        """Re-check a few sources nobody follows, so a dead one can recover.

        On the scheduler thread for the same reasons the cache sweep is: no
        request is waiting on it, and it must not take a worker or queue behind
        the single-check lock.

        There is no in-memory "last run" timer here on purpose. The cache sweep
        can use time.monotonic() because main's lifespan sweeps at boot and a
        restart therefore loses nothing; there is no boot counterpart for this,
        so a monotonic clock would re-probe on every container start — and this
        box redeploys several times a day. `source_health.last_checked_at` is
        already a persistent per-source clock, so selection reads that instead
        and a restart changes nothing.

        Obeys the same switch as the update sweep: "updates off" has to mean
        this process does not contact upstreams, and a background probe is
        exactly the kind of traffic someone turning that off means to stop.
        """
        if not self._scheduled_checks_enabled():
            return
        db = SessionLocal()
        try:
            probed = reprobe_sources(db)
            if probed:
                logger.info("re-probed %d source(s) for health", len(probed))
        except Exception:
            db.rollback()
            logger.exception("Source re-probe failed")
        finally:
            db.close()

    def _maybe_sweep_caches(self) -> None:
        """Run the cache retention sweep at most once a day.

        On the scheduler thread rather than the worker pool: it is four DELETEs
        against tables no request is waiting on, so it must not take a worker
        an update check could be using, and it must not queue behind the
        single-check lock that check holds for its whole sweep.
        """
        now = time.monotonic()
        if (
            self._last_cache_sweep is not None
            and now - self._last_cache_sweep < _CACHE_SWEEP_INTERVAL_SECONDS
        ):
            return
        self._last_cache_sweep = now
        db = SessionLocal()
        try:
            sweep_cache_retention(db)
        except Exception:
            db.rollback()
            logger.exception("Cache retention sweep failed")
        finally:
            db.close()

    def _scheduled_checks_enabled(self) -> bool:
        db = SessionLocal()
        try:
            return bool(UpdateService(db).get_global_settings().enabled)
        except Exception:
            # Fail open: a transient DB error must not silently kill the
            # update feature.
            return True
        finally:
            db.close()

    def _current_interval_minutes(self) -> int:
        db = SessionLocal()
        try:
            service = UpdateService(db)
            settings = service.get_global_settings()
            if not settings.enabled:
                return get_settings().update_check_interval_minutes
            return max(settings.check_interval_minutes, 5)
        except Exception:
            return get_settings().update_check_interval_minutes
        finally:
            db.close()


def get_update_manager() -> UpdateSchedulerManager:
    global _update_manager
    with _update_manager_lock:
        if _update_manager is None:
            _update_manager = UpdateSchedulerManager()
        return _update_manager


def reset_update_manager_for_tests(manager: UpdateSchedulerManager | None = None) -> None:
    global _update_manager
    with _update_manager_lock:
        if _update_manager is not None:
            _update_manager.stop()
        _update_manager = manager
