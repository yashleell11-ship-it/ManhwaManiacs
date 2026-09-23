"""Failures a connector turned into an empty answer, kept for whoever asked.

Most connector families answer a failed series page with ``None`` and a failed
chapter list with ``[]`` -- the reader gets "not found" or an empty list, which
is the behaviour they want. But that also hides the failure from the one caller
that needs to tell "the site said no such series" from "the site blocked us":
source health. linkmanga (Madara) was blocked on exactly its series pages, and
every open of one came back as a quiet ``None`` that counted as nothing.

So a connector that swallows a failure notes it here, and a caller that cares
wraps its call in :func:`capture` and reads what was noted. Nothing about the
connector's return value changes, and no request is added.

A ``ContextVar`` rather than a field on the connector: connectors are
process-wide singletons shared by every request thread, and a field would hand
one reader's failure to another reader's request.
"""

from __future__ import annotations

from contextlib import contextmanager
from contextvars import ContextVar
from typing import Iterator

_sink: ContextVar[list[BaseException] | None] = ContextVar(
    "connector_swallowed_failures", default=None
)


def note(exc: BaseException) -> None:
    """Record a failure the calling connector is about to swallow.

    A no-op when nobody is capturing, which is every background caller.
    """
    sink = _sink.get()
    if sink is not None:
        sink.append(exc)


@contextmanager
def capture() -> Iterator[list[BaseException]]:
    """Collect every failure noted inside the block, oldest first.

    The list stays readable after the block exits. A capture nested inside
    another hands what it saw on to the outer one as well, so an inner
    observer never hides a failure from an outer one.
    """
    outer = _sink.get()
    sink: list[BaseException] = []
    token = _sink.set(sink)
    try:
        yield sink
    finally:
        _sink.reset(token)
        if outer is not None:
            outer.extend(sink)
