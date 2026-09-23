"""Process-lifetime index over the connector registry.

``connectors.registry.list_installed_connectors()`` rebuilds every
``ConnectorDescriptor`` from scratch and re-sorts the list on every call — ~50
dataclass constructions, each of which computes an icon URL. That is fine once
per response and ruinous once per *row*: the library serializer resolves a 18+
rating per followed series, and each resolution asked the registry for the
whole list and scanned it linearly. A 300-series library therefore built ~15600
descriptors to answer 300 questions of the form "is this source id adult?".

This module answers those questions from a dict built once. The registry is
static after import (``_register_builtin_connectors()`` runs at module import
and nothing registers later in production), so the only input that can change
within a process is the ``MM_NOVELS_ENABLED`` flag — which the registry itself
re-reads per call so both states stay testable in one process. The cache is
therefore keyed on that flag rather than being unconditional: flipping it (as
``tests/test_novels_flag.py`` does) rebuilds the index instead of serving a
stale one.

Read-only: nothing here mutates the registry, and callers that need the full
descriptor list for a *response* should keep calling the registry directly.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from connectors.excluded import RETIRED_MATURE_SOURCES
from connectors.registry import list_installed_connectors
from core.config import get_settings

if TYPE_CHECKING:  # pragma: no cover - typing only
    from connectors.registry import ConnectorDescriptor

#: (novels_enabled, registry size) -> index. The registry size is part of the
#: key so a test that registers an extra connector into ``_REGISTRY`` is not
#: served a stale index; it costs one ``len()`` per lookup.
_CACHE: dict[tuple[bool, int], dict[str, "ConnectorDescriptor"]] = {}


def _cache_key() -> tuple[bool, int]:
    from connectors.registry import _REGISTRY

    return (bool(getattr(get_settings(), "novels_enabled", False)), len(_REGISTRY))


def descriptors_by_source() -> dict[str, "ConnectorDescriptor"]:
    """``source_type -> ConnectorDescriptor`` for every installed connector.

    The returned dict is shared and must not be mutated by callers.
    """
    key = _cache_key()
    index = _CACHE.get(key)
    if index is None:
        index = {d.source_type: d for d in list_installed_connectors()}
        _CACHE[key] = index
    return index


def descriptor_for_source(source_id: str) -> "ConnectorDescriptor | None":
    """The descriptor for one source id, or ``None`` when it is not installed."""
    return descriptors_by_source().get(source_id)


def known_source_ids() -> frozenset[str]:
    """Every source id the connector code still defines.

    Reads ``_REGISTRY`` rather than :func:`descriptors_by_source` on purpose:
    the question this answers is "does this source still exist in the build?",
    and a novel source with ``MM_NOVELS_ENABLED`` off does exist — it is hidden
    from every listing surface, not deleted. Answering from the flag-filtered
    index would make the cache retention sweep
    (``services.source_cache_service.sweep_cache_retention``) delete every
    novel row the moment the flag went off, and refetch them all when it came
    back on. A source removed from ``connectors/catalog.py`` or added to
    ``connectors.excluded.EXCLUDED_CONNECTORS`` is absent from both.

    Not memoized: the one caller runs twice a day, and a stale answer here
    deletes rows.
    """
    from connectors.registry import _REGISTRY

    return frozenset(_REGISTRY)


def mature_source_ids() -> tuple[str, ...]:
    """Sorted ids of the sources that are adult by nature.

    Sorted so the tuple is a stable SQL ``IN`` parameter list — an unstable
    order would give SQLAlchemy a different cache key for the same query.
    """
    return tuple(sorted(d.source_type for d in descriptors_by_source().values() if d.mature))


def is_mature_source(source_id: str | None) -> bool:
    """Whether rows naming ``source_id`` are 18+ by virtue of the source alone.

    The installed descriptor answers when there is one. When there is not, the
    id may still be a *removed* adult source
    (:data:`connectors.excluded.RETIRED_MATURE_SOURCES`), and rows naming it --
    follows, progress, bookmarks -- outlive the connector. Answering "not
    mature" for those would turn every deregistration of an 18+ source into a
    disclosure: a follow with no stored rating of its own drops from mature to
    unknown, and unknown is shown to a profile with 18+ off.

    A novel source hidden by ``MM_NOVELS_ENABLED`` is also descriptor-less
    here, and is not in the retired set, so it keeps the answer it had.
    """
    descriptor = descriptor_for_source(source_id) if source_id else None
    if descriptor is not None:
        return bool(descriptor.mature)
    return source_id in RETIRED_MATURE_SOURCES


def gated_source_ids() -> tuple[str, ...]:
    """Sorted ids :func:`is_mature_source` answers yes for -- the SQL side.

    :func:`mature_source_ids` stays the installed set on purpose: it is what the
    listing surfaces count and show. This is what a *row* is judged by, so it
    adds the retired adult ids, minus any that have been re-registered (an
    installed descriptor wins, as in :func:`is_mature_source`). Sorted for the
    same SQL-cache reason.
    """
    installed = descriptors_by_source()
    return tuple(
        sorted(
            {d.source_type for d in installed.values() if d.mature}
            | (RETIRED_MATURE_SOURCES - installed.keys())
        )
    )


def reset_cache() -> None:
    """Drop the memo. For tests that mutate the registry in place."""
    _CACHE.clear()
