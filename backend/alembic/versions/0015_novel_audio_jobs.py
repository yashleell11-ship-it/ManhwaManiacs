"""The render queue: what has been asked for, and what became of it.

Audio is the first thing this server produces that it cannot produce itself.
Chapter text is fetched, attribution is bought from a model in seconds, but a
chapter of speech is roughly nine minutes on a GPU that lives in the owner's
house, behind a home NAT, and is asleep half the time. So the server cannot
call out to it; the box has to come and ask. That is what this table is for —
a queue the renderer pulls from, and a receipt saying what it did.

**Deliberately not a cache table.** Membership in ``CACHE_TABLES`` means every
backup DELETEs the table, and a backup taken while a worker is six minutes
into a render would leave it heartbeating against a row that no longer exists,
throwing the render away. Beyond that, the rule already written for
``novel_chapter_attribution`` applies unchanged: rows that are re-BOUGHT
rather than re-fetched stay out of the caches. These are bought with GPU time
on a card that is also a training run's.

The partial unique index is the double-enqueue guard. Pressing "Make
audiobook" twice on the same chapter has to be cheap and idempotent, not two
nine-minute renders racing to write the same file.
"""

from __future__ import annotations

from collections.abc import Sequence
from typing import Union

import sqlalchemy as sa
from alembic import op

revision: str = "0015_novel_audio_jobs"
down_revision: Union[str, Sequence[str], None] = "0014_narrator_voice"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "novel_audio_jobs",
        sa.Column("id", sa.String(length=32), primary_key=True),
        sa.Column("source_id", sa.String(length=64), nullable=False),
        sa.Column("series_key", sa.String(length=512), nullable=False),
        sa.Column("chapter_key", sa.String(length=512), nullable=False),
        sa.Column("chapter_number", sa.Float(), nullable=True),
        sa.Column("text_fingerprint", sa.String(length=64), nullable=False),
        sa.Column(
            "status", sa.String(length=16), nullable=False, server_default="queued"
        ),
        sa.Column("attempts", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("priority", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("worker_id", sa.String(length=64), nullable=True),
        sa.Column("lease_until", sa.DateTime(), nullable=True),
        sa.Column("segment_count", sa.Integer(), nullable=True),
        sa.Column(
            "progress_segments", sa.Integer(), nullable=False, server_default="0"
        ),
        sa.Column("error_code", sa.String(length=48), nullable=True),
        sa.Column("error_detail", sa.String(length=500), nullable=True),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.Column("started_at", sa.DateTime(), nullable=True),
        sa.Column("finished_at", sa.DateTime(), nullable=True),
    )
    # Partial, so the constraint binds only while a job is IN FLIGHT. A
    # chapter rendered last week must not block asking for it again after the
    # cast changed, and a row that failed must not block a retry.
    op.create_index(
        "uq_novel_audio_job_active",
        "novel_audio_jobs",
        ["source_id", "series_key", "chapter_key"],
        unique=True,
        sqlite_where=sa.text("status IN ('queued','planning','rendering')"),
    )
    op.create_index(
        "ix_novel_audio_job_pick",
        "novel_audio_jobs",
        ["status", "priority", "created_at"],
    )
    op.create_index(
        "ix_novel_audio_job_series",
        "novel_audio_jobs",
        ["source_id", "series_key"],
    )


def downgrade() -> None:
    # Lossy, and there is nowhere else for it to go: the queue is the only
    # record of what was asked for and what it cost. Downgrading forgets the
    # history; the AUDIO on disk is untouched and still plays.
    op.drop_index("ix_novel_audio_job_series", table_name="novel_audio_jobs")
    op.drop_index("ix_novel_audio_job_pick", table_name="novel_audio_jobs")
    op.drop_index("uq_novel_audio_job_active", table_name="novel_audio_jobs")
    op.drop_table("novel_audio_jobs")
