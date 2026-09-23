"""Server-side source pins (the Pinned section of the Sources screen).

Pins live on the server, not in client prefs, so they follow the account across
devices, and they are scoped to ``(user_id, profile_id)`` like every other
per-user row: two accounts never see each other's pins, and neither do two
profiles on one account.

``source_id`` is a connector key, not a foreign key -- connectors are code, not
rows. A pinned source can therefore stop resolving: the connector was removed
(linkmanga, lilymanga), the novels flag is off, or the caller's 18+ gate hides
it. Such a pin is omitted from reads and left alone by writes, so it comes back
if the source does.

It used to be returned flagged ``available: false`` so the user could drop it
by hand. That broke every other edit: PUT replaces the whole set, both clients
build it from the full list they were given, so the dead id went back with
every pin or unpin and the request was refused as "Unknown source." -- and in
Novels mode neither client even drew the dead manga row that had to go first.
An adult connector's id is also exactly what the gate withholds everywhere
else, so a pin made while the gate was open had to be hidden anyway.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import Depends
from sqlalchemy import select
from sqlalchemy.orm import Session

from connectors.registry import ConnectorDescriptor, list_installed_connectors
from core.content_rating import resolve_mature_gate
from core.errors import AppError
from core.profile_context import (
    ProfileContext,
    require_profile_context,
    resolve_profile_context,
)
from database.models import SourcePin
from database.session import get_db

SOURCE_ID_MAX = 64


class SourcePinService:
    # Pinning is a shortcut, not a second catalog: enough room for every
    # installed source and no more, so the payload stays bounded.
    MAX_PINS = 50

    def __init__(self, db: Session, ctx: ProfileContext) -> None:
        self._db = db
        self._user_id = ctx.user_id
        self._profile_id = ctx.profile_id

    # --- scoping -------------------------------------------------------------

    def _scoped(self):
        return select(SourcePin).where(
            SourcePin.user_id == self._user_id,
            SourcePin.profile_id == self._profile_id,
        )

    def _mature_enabled(self) -> bool:
        """Active mature gate for this (user, profile)."""
        return resolve_mature_gate(self._db, self._profile_id, self._user_id)

    def _pinnable_sources(self) -> dict[str, ConnectorDescriptor]:
        """Sources the caller can actually see, keyed by connector id.

        Same filter GET /sources applies, so a source hidden behind the mature
        gate can neither be pinned nor surface through an older pin."""
        return {
            descriptor.source_type: descriptor
            for descriptor in list_installed_connectors(
                browsable_only=True,
                include_mature=self._mature_enabled(),
            )
        }

    # --- serialization -------------------------------------------------------

    @staticmethod
    def _serialize(pin: SourcePin, descriptor: ConnectorDescriptor) -> dict[str, object]:
        return {
            "source_id": pin.source_id,
            "sort_order": pin.sort_order,
            "name": descriptor.name,
            "icon_url": descriptor.icon_url,
            "mature": bool(descriptor.mature),
            # Always true now that unresolvable pins are not served; kept
            # because both clients still read it.
            "available": True,
        }

    # --- reads ---------------------------------------------------------------

    def list_pins(self) -> list[dict[str, object]]:
        if self._user_id is None:
            # Pins are owned rows (user_id NOT NULL); the unscoped/legacy bucket
            # has none rather than sharing one global set.
            return []
        available = self._pinnable_sources()
        rows = self._db.execute(
            self._scoped().order_by(SourcePin.sort_order, SourcePin.id)
        ).scalars()
        return [
            self._serialize(pin, available[pin.source_id])
            for pin in rows
            if pin.source_id in available
        ]

    # --- writes --------------------------------------------------------------

    def _validate(
        self,
        source_ids: list[str],
        *,
        available: dict[str, ConnectorDescriptor],
        existing: set[str],
    ) -> list[str]:
        """Normalize the requested set: trimmed, de-duplicated, order preserved.

        Returns only ids that resolve. An id that does not resolve but is
        already one of this profile's pins is dropped, not refused: a client
        holding a list from before its source went away sends it straight
        back, and refusing the whole set over it is what made every pin and
        unpin fail. Only a NEW unresolvable id is an error -- which is still
        how a gated profile is kept from pinning an adult source it cannot see.
        """
        normalized: list[str] = []
        for raw in source_ids:
            if not isinstance(raw, str):
                raise AppError(
                    "Source ids must be strings.",
                    code="invalid_source_pin",
                    status_code=422,
                )
            candidate = raw.strip()
            if not candidate or len(candidate) > SOURCE_ID_MAX:
                raise AppError(
                    "Source ids must be 1-64 characters.",
                    code="invalid_source_pin",
                    status_code=422,
                )
            if candidate not in normalized:
                normalized.append(candidate)

        if len(normalized) > self.MAX_PINS:
            raise AppError(
                f"At most {self.MAX_PINS} sources can be pinned.",
                code="too_many_pins",
                status_code=422,
            )

        unknown = [
            item for item in normalized if item not in available and item not in existing
        ]
        if unknown:
            raise AppError(
                "Unknown source.",
                code="unknown_source",
                status_code=422,
                details={"source_ids": unknown},
            )
        return [item for item in normalized if item in available]

    def replace_pins(self, source_ids: list[str]) -> list[dict[str, object]]:
        """Replace the whole pinned set, in the order given.

        Whole-set replace (not add/remove) because the client owns the ordering:
        it sends the list it wants and gets that exact list back. Rows that
        survive keep their identity so ``created_at`` still records when the
        source was first pinned.
        """
        if self._user_id is None:
            raise AppError(
                "Authentication required.", code="not_authenticated", status_code=401
            )

        available = self._pinnable_sources()
        existing = {
            pin.source_id: pin
            for pin in self._db.execute(self._scoped()).scalars()
        }
        wanted = self._validate(source_ids, available=available, existing=set(existing))

        # A row that does not resolve never reached this caller, so its
        # absence from the list sent back is not a decision about it: deleting
        # it here would turn a read-side omission (a shut 18+ gate, the novels
        # flag off) into data loss the moment the profile re-ordered its pins.
        for source_id, pin in existing.items():
            if source_id not in wanted and source_id in available:
                self._db.delete(pin)

        for order, source_id in enumerate(wanted):
            pin = existing.get(source_id)
            if pin is None:
                self._db.add(
                    SourcePin(
                        user_id=self._user_id,
                        profile_id=self._profile_id,
                        source_id=source_id,
                        sort_order=order,
                    )
                )
            elif pin.sort_order != order:
                pin.sort_order = order

        self._db.commit()
        return self.list_pins()


def get_source_pin_service(
    db: Annotated[Session, Depends(get_db)],
    ctx: Annotated[ProfileContext, Depends(resolve_profile_context)],
) -> SourcePinService:
    """Read path: a bad/absent profile header degrades to the unscoped bucket."""
    return SourcePinService(db, ctx)


def require_source_pin_service(
    db: Annotated[Session, Depends(get_db)],
    ctx: Annotated[ProfileContext, Depends(require_profile_context)],
) -> SourcePinService:
    """Write path: an account that owns profiles must name the one it is
    writing for, so pins can never land in the wrong profile's set."""
    return SourcePinService(db, ctx)
