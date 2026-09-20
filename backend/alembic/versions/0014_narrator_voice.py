"""The narrator's voice becomes a choice instead of a derivation.

Until now the voice reading the narration was computed: the flattest clip in
the pack matching the narrator's gender. That is a reasonable default and a bad
only-option. Flatness correlates with mid-range pitch, so the rule reliably
picked a middling voice and the deepest clips in the pack — the ones an owner
actually reaches for when they want a narrator with some weight — could never
be selected. There was no way to say otherwise, because there was nowhere to
say it.

``narrator_voice_id`` is that somewhere: one voice per series, chosen by the
owner, NULL meaning "carry on deriving it". It sits on the cast-state row
rather than on a cast member because the narrator is a property of the BOOK.
A chapter narrated by a character still reads in that character's own voice —
they are the same person — and this is the fallback for narration belonging to
nobody in the cast.

Nothing about this column describes the story. It stores an id from the voice
pack, which is the same restraint the cast tables keep: what picks a voice,
and nothing that would help a reader understand the book.
"""

from __future__ import annotations

from collections.abc import Sequence
from typing import Union

import sqlalchemy as sa
from alembic import op

revision: str = "0014_narrator_voice"
down_revision: Union[str, Sequence[str], None] = "0013_novel_attribution"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "novel_series_cast_state",
        sa.Column("narrator_voice_id", sa.String(length=64), nullable=True),
    )


def downgrade() -> None:
    # Lossy, and deliberately so: the column holds an owner's decision, and
    # there is nowhere else to put it. Downgrading forgets which voice they
    # chose and the series falls back to the derived one.
    op.drop_column("novel_series_cast_state", "narrator_voice_id")
