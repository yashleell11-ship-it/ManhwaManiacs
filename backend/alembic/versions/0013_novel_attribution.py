"""novel attribution: who speaks each line, and which voice reads it

Revision ID: 0013_novel_attribution
Revises: 0012_audit_indexes
Create Date: 2026-09-19

Per-character narration for novels. Four tables: one cache of what a model
answered about a chapter, and three that hold the series' cast.

**This is NOT character extraction, and must never become it.**
``frontend/AGENTS.md`` records that knowledge-graph / character / world /
timeline extraction was permanently abandoned and is never to be reintroduced,
and a "series cast" table is one column away from looking exactly like the thing
that was abandoned. The line is this: these tables store ONLY what is needed to
pick a voice -- a display name, its aliases, a gender, a voice id, and counts
that decide who is a main. The next person here will want to add
``description``, or ``first_seen_chapter``, or a relationship to another
character. None of that picks a voice. If a column would help a reader
understand the story rather than help a renderer choose a speaker, it does not
belong in this file.

**None of these tables are cache tables.** They are deliberately absent from
``core.cache_tables.CACHE_TABLES``, which the backup script drops. Attribution
is re-BOUGHT from a paid API rather than re-fetched from a source, so dropping
it costs money rather than bandwidth; and the cast carries the owner's own
corrections, which exist nowhere else and cannot be regenerated at all.

**Spans store a speaker LABEL, not a foreign key to the cast.** This is the
decision the rest of the design falls out of. Resolution runs at serve time:
label -> alias -> cast -> voice. So a character who first becomes identifiable
at chapter 800 retroactively gets their voice in chapter 200 without rewriting a
row, and "King Grey is Arthur" is a single INSERT into the alias table that
corrects nine hundred chapters at once. Foreign keys here would have meant
re-attributing the series every time the cast grew.

**The alias is part of the alias table's primary key.** One alias cannot map to
two characters, and the database is what enforces it -- so the failure mode
where a name silently splits a voice in half surfaces as a constraint violation
at write time, rather than as a series that mysteriously reads in two voices.

``text_fingerprint`` is load-bearing: ``novel_chapter_cache`` is a 7-day LRU
that REFETCHES, so the text an attribution was computed against will eventually
be replaced by a re-scrape that may differ. Offsets computed against the old
text would silently highlight the wrong words. Readers compare the fingerprint
and fall back to unhighlighted playback rather than trusting stale offsets.
"""
from __future__ import annotations

from typing import Sequence, Union

import sqlalchemy as sa
from alembic import op

revision: str = "0013_novel_attribution"
down_revision: Union[str, Sequence[str], None] = "0012_audit_indexes"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # --- what a model said about one chapter -------------------------------
    # Keyed on the same identity triple as novel_chapter_cache, so an
    # attribution is found by the same key the text is.
    op.create_table(
        "novel_chapter_attribution",
        sa.Column("source_id", sa.String(length=64), primary_key=True),
        sa.Column("series_key", sa.String(length=512), primary_key=True),
        sa.Column("chapter_key", sa.String(length=512), primary_key=True),
        # Proof the offsets below still describe the text being rendered.
        sa.Column("text_fingerprint", sa.String(length=64), nullable=False),
        sa.Column("paragraph_count", sa.Integer(), nullable=False),
        # "quoted" | "emdash" | "none" -- em-dash chapters are recorded as
        # segmented-but-not-attributable rather than retried forever.
        sa.Column("style", sa.String(length=16), nullable=False),
        # JSON array of {p, s, e, head, ord, cont, speaker, rule}. `speaker` is
        # a LABEL, resolved against the alias table at serve time.
        sa.Column("spans", sa.Text(), nullable=False),
        sa.Column("pov", sa.Text(), nullable=True),
        # Per-label he/she tallies, so gender is decided from accumulated
        # evidence across chapters rather than from one paragraph.
        sa.Column("pronoun_counts", sa.Text(), nullable=True),
        # ok | no_dialogue | unattributable | failed
        sa.Column("status", sa.String(length=16), nullable=False),
        sa.Column("model", sa.String(length=64), nullable=True),
        sa.Column("prompt_tokens", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("completion_tokens", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("attributed_at", sa.DateTime(), nullable=False),
    )
    # The recast pass walks every attributed chapter of one series in order.
    op.create_index(
        "ix_novel_attribution_series",
        "novel_chapter_attribution",
        ["source_id", "series_key"],
    )

    # --- the cast, which is only ever a voice-picking table ----------------
    op.create_table(
        "novel_series_cast",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True),
        sa.Column("source_id", sa.String(length=64), nullable=False),
        sa.Column("series_key", sa.String(length=512), nullable=False),
        sa.Column("display_name", sa.String(length=128), nullable=False),
        # normalize_name() output; the join key every alias resolves to.
        sa.Column("normalized_name", sa.String(length=128), nullable=False),
        # male | female | unknown. From pronoun counts, NEVER from the name:
        # transliterated names carry no signal a heuristic can read, and a wrong
        # guess is wrong on every line that character ever speaks. "unknown"
        # routes to the narrator, which is why it is a real value and not a gap.
        sa.Column("gender", sa.String(length=8), nullable=False, server_default="unknown"),
        sa.Column("voice_id", sa.String(length=64), nullable=True),
        sa.Column("line_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("chapter_count", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("is_pov", sa.Boolean(), nullable=False, server_default="0"),
        # An owner correction. A recast may update counts on a locked row but
        # must never overwrite its gender, voice or display name -- silently
        # reverting a correction is the failure this column exists to prevent.
        sa.Column("locked", sa.Boolean(), nullable=False, server_default="0"),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.UniqueConstraint(
            "source_id",
            "series_key",
            "normalized_name",
            name="uq_novel_cast_identity",
        ),
    )
    op.create_index(
        "ix_novel_cast_series", "novel_series_cast", ["source_id", "series_key"]
    )

    # --- aliases: the alias itself is the key ------------------------------
    op.create_table(
        "novel_series_alias",
        sa.Column("source_id", sa.String(length=64), primary_key=True),
        sa.Column("series_key", sa.String(length=512), primary_key=True),
        # In the PRIMARY KEY on purpose: one alias cannot point at two
        # characters, and the database refuses the ambiguity rather than
        # letting a series quietly read in two voices.
        sa.Column("alias_normalized", sa.String(length=128), primary_key=True),
        sa.Column("alias_display", sa.String(length=128), nullable=False),
        sa.Column(
            "cast_id",
            sa.Integer(),
            sa.ForeignKey("novel_series_cast.id", ondelete="CASCADE"),
            nullable=False,
        ),
        # Owner-declared merges ("King Grey is Arthur") survive every recast.
        sa.Column("locked", sa.Boolean(), nullable=False, server_default="0"),
        sa.Column("created_at", sa.DateTime(), nullable=False),
    )
    op.create_index("ix_novel_alias_cast", "novel_series_alias", ["cast_id"])

    # --- per-series bookkeeping -------------------------------------------
    op.create_table(
        "novel_series_cast_state",
        sa.Column("source_id", sa.String(length=64), primary_key=True),
        sa.Column("series_key", sa.String(length=512), primary_key=True),
        sa.Column(
            "chapters_attributed", sa.Integer(), nullable=False, server_default="0"
        ),
        # Bumped whenever the cast changes, so a client can tell that a voice
        # assignment it cached is stale without diffing the cast itself.
        sa.Column("cast_version", sa.Integer(), nullable=False, server_default="0"),
        sa.Column("last_recast_at", sa.DateTime(), nullable=True),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
    )


def downgrade() -> None:
    op.drop_table("novel_series_cast_state")
    op.drop_index("ix_novel_alias_cast", table_name="novel_series_alias")
    op.drop_table("novel_series_alias")
    op.drop_index("ix_novel_cast_series", table_name="novel_series_cast")
    op.drop_table("novel_series_cast")
    op.drop_index(
        "ix_novel_attribution_series", table_name="novel_chapter_attribution"
    )
    op.drop_table("novel_chapter_attribution")
