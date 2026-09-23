"""users.last_login_at: backfill it from the sessions an account already has

Revision ID: 0016_backfill_last_login
Revises: 0015_novel_audio_jobs
Create Date: 2026-09-23

Registering signs an account in, but until recently only ``/auth/login``
stamped ``last_login_at``, so every account that has only ever registered has
a NULL there while holding a live session. The owner's Members screen reads
that as "never signed in · 1 session" for an account in daily use, and on a
90-day remember-me session it stays that way for months, because nothing sends
the account back through ``/auth/login``. Registration stamps the column now;
this fills in the accounts that registered before it did.

A session is only ever created by ``/auth/register`` or ``/auth/login``, so
the newest one an account holds is its last sign-in, and that is the value
written. An account with no sessions left keeps its NULL: nothing on record
says when it last signed in, and "never" is the honest reading of that.

Data only, and idempotent: it touches only NULL rows, so a re-run or a row a
login has already stamped is left alone.

REVERSIBILITY. ``downgrade()`` is a no-op on purpose. A backfilled value is
indistinguishable from one a login wrote afterwards, so there is no way to
NULL only what this revision filled in, and blanking the column would erase
real sign-ins.
"""
from __future__ import annotations

from typing import Sequence, Union

from alembic import op

revision: str = "0016_backfill_last_login"
down_revision: Union[str, Sequence[str], None] = "0015_novel_audio_jobs"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute(
        """
        UPDATE users
           SET last_login_at = (
                 SELECT max(sessions.created_at)
                   FROM sessions
                  WHERE sessions.user_id = users.id
               )
         WHERE last_login_at IS NULL
           AND EXISTS (
                 SELECT 1
                   FROM sessions
                  WHERE sessions.user_id = users.id
                    AND sessions.created_at IS NOT NULL
               )
        """
    )


def downgrade() -> None:
    pass
