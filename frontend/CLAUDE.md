@AGENTS.md

Read `docs/CLAUDE_HANDOFF.md` first. Connectors in `backend/connectors/` are no
longer owned by another tool and may be edited here. The rule for them: a source
that does not work end to end from the VPS (list, open a series, its chapters, its
pages) is removed, not left listed — see how `lilymanga` and `linkmanga` are
recorded in `backend/connectors/catalog.py`.
