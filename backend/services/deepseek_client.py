"""Minimal DeepSeek chat client, for novel speaker attribution.

This is the backend's ONLY outbound call to a paid third-party API, and the
only place an API key is held in the process, so the rules it follows are
deliberately stricter than the rest of the HTTP in this codebase.

**The key is read from the environment and nowhere else.** Never from
``Settings``: that model is declared ``extra="allow"`` and is *written back* to
``settings.json`` by ``save_settings`` -- so a key that ever reached it would be
persisted to disk, copied into every database backup, and served to whatever can
read the settings route. ``os.getenv`` inside this module keeps it in process
memory and out of every file this project writes.

**The host is pinned and redirects are refused.** ``httpx`` re-sends the
``Authorization`` header when it follows a redirect to the same host, and a 302
pointing somewhere else is exactly how a key leaks to a host nobody audited.
There is one legitimate destination here, so anything but a direct 2xx from it
is an error rather than something to chase.

**Spending has a hard daily ceiling.** Attribution is cheap per chapter
(~$0.003) and ruinous in a loop: a retry storm, or a re-attribution sweep over a
3,000-chapter series, is the failure mode that turns a nine-cent feature into a
bill. The ceiling is counted in requests, persisted next to ``settings.json`` so
a container restart cannot reset it, and it refuses loudly rather than degrading
quietly.
"""

from __future__ import annotations

import json
import logging
import os
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import httpx

from core.config import SETTINGS_PATH

logger = logging.getLogger(__name__)

#: The one legitimate destination. Built from a constant rather than a setting
#: so no configuration change can redirect a bearer token somewhere else.
API_HOST = "api.deepseek.com"
API_URL = f"https://{API_HOST}/chat/completions"

#: `deepseek-chat` is the cheap non-reasoning model. Attribution is a reading
#: task against rules supplied in the prompt, not a thinking task, and the
#: reasoning model costs several times more for the same answer.
MODEL = "deepseek-chat"

#: Generous: a chapter is ~6,400 tokens in and the model has to read all of it
#: before the first output token. Short enough that a wedged connection cannot
#: hold a worker for minutes.
TIMEOUT_SECONDS = 120.0

#: Requests per UTC day. ~$0.003 each, so this caps a runaway at roughly $1.50 —
#: enough for four full 120-chapter validation passes in one day, and nowhere
#: near enough to matter if something loops.
DAILY_REQUEST_CEILING = 500

_BUDGET_PATH = SETTINGS_PATH.parent / "deepseek-usage.json"


class DeepSeekError(RuntimeError):
    """Any failure to get a usable answer from the API."""


class DeepSeekNotConfigured(DeepSeekError):
    """No API key in the environment."""


class DeepSeekBudgetExhausted(DeepSeekError):
    """The daily request ceiling has been reached."""


def api_key() -> str | None:
    """The key, or None. Read fresh so a restart picks up a rotation."""
    key = os.getenv("DEEPSEEK_API_KEY", "").strip()
    return key or None


def is_configured() -> bool:
    """Whether attribution can run at all.

    Callers use this to degrade to narrator-only rather than raising into a
    request: a missing key is a deployment state, not a bug.
    """
    return api_key() is not None


# --- daily ceiling ---------------------------------------------------------


def _today() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def _read_budget(path: Path) -> tuple[str, int]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return str(data.get("date", "")), int(data.get("requests", 0))
    except (OSError, ValueError, TypeError):
        # A corrupt or missing ledger must not be a free pass; it resets to
        # today at zero, which is the conservative reading either way.
        return _today(), 0


def spent_today(path: Path | None = None) -> int:
    """Requests already made today. Zero on a new day."""
    date, count = _read_budget(path or _BUDGET_PATH)
    return count if date == _today() else 0


def _record_request(path: Path) -> None:
    date, count = _read_budget(path)
    count = count + 1 if date == _today() else 1
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps({"date": _today(), "requests": count}), encoding="utf-8"
        )
    except OSError:
        # Losing a tick of the counter is survivable; failing the call that was
        # already paid for is not.
        logger.warning("could not record DeepSeek usage to %s", path)


@dataclass(frozen=True)
class Completion:
    """One answered request."""

    content: str
    prompt_tokens: int
    completion_tokens: int

    def json(self) -> Any:
        """The parsed body. Raises DeepSeekError if it is not JSON.

        JSON mode makes this very unlikely, not impossible -- a truncated answer
        (hitting max_tokens mid-object) is still well-formed as far as the API
        is concerned and unparseable here.
        """
        try:
            return json.loads(self.content)
        except ValueError as exc:
            raise DeepSeekError(f"model returned unparseable JSON: {exc}") from exc


def complete_json(
    prompt: str,
    *,
    system: str = "",
    max_tokens: int = 2000,
    temperature: float = 0.0,
    timeout: float = TIMEOUT_SECONDS,
    ceiling: int = DAILY_REQUEST_CEILING,
    budget_path: Path | None = None,
    transport: httpx.BaseTransport | None = None,
) -> Completion:
    """One JSON-mode completion.

    Retries exactly once, and only for failures that a second attempt can
    plausibly fix: a transport error, a 429, or a 5xx. A 400 or a 401 is
    re-sending a bad request with a bad key, which costs money on some APIs and
    buys nothing on any.

    ``temperature=0`` because this is an extraction task with a right answer --
    sampling only adds a chance of a different wrong one, and makes the same
    chapter attribute differently on two runs.
    """
    key = api_key()
    if key is None:
        raise DeepSeekNotConfigured(
            "DEEPSEEK_API_KEY is not set; attribution cannot run"
        )

    path = budget_path or _BUDGET_PATH
    used = spent_today(path)
    if used >= ceiling:
        raise DeepSeekBudgetExhausted(
            f"daily DeepSeek ceiling reached ({used}/{ceiling} requests); "
            "refusing to spend more today"
        )

    messages: list[dict[str, str]] = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})

    payload = {
        "model": MODEL,
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "response_format": {"type": "json_object"},
        "stream": False,
    }

    last: Exception | None = None
    for attempt in (1, 2):
        try:
            with httpx.Client(
                timeout=timeout,
                # The whole point: a redirect must never carry this header to a
                # host that was not audited.
                follow_redirects=False,
                transport=transport,
            ) as client:
                response = client.post(
                    API_URL,
                    headers={
                        "Authorization": f"Bearer {key}",
                        "Content-Type": "application/json",
                    },
                    json=payload,
                )
        except httpx.HTTPError as exc:
            # str(exc) can embed the request URL but never the headers, so this
            # is safe to log; the key is not in it.
            last = DeepSeekError(f"DeepSeek request failed: {type(exc).__name__}")
            logger.warning("DeepSeek attempt %d transport error: %s", attempt, exc)
            if attempt == 1:
                time.sleep(2)
                continue
            raise last from exc

        # Paid for the moment it was answered, whatever the status.
        _record_request(path)

        if response.status_code in (429, 500, 502, 503, 504) and attempt == 1:
            logger.warning("DeepSeek returned %d; retrying once", response.status_code)
            time.sleep(2)
            continue

        if 300 <= response.status_code < 400:
            # follow_redirects=False means httpx hands the 3xx back rather than
            # re-sending the Authorization header somewhere new. Name it
            # explicitly: falling through to the JSON parse would report this
            # as a malformed body and hide a redirect nobody expected.
            raise DeepSeekError(
                f"DeepSeek redirected (HTTP {response.status_code}); refusing to "
                "follow it with a bearer token"
            )

        if response.status_code >= 400:
            # Never echo the body: an auth error from this API quotes the key
            # back, masked by them but not by us, and this message reaches logs.
            raise DeepSeekError(
                f"DeepSeek returned HTTP {response.status_code}"
            )

        try:
            body = response.json()
            choice = body["choices"][0]["message"]["content"]
            usage = body.get("usage") or {}
        except (ValueError, KeyError, IndexError, TypeError) as exc:
            raise DeepSeekError(f"unexpected DeepSeek response shape: {exc}") from exc

        return Completion(
            content=choice,
            prompt_tokens=int(usage.get("prompt_tokens", 0)),
            completion_tokens=int(usage.get("completion_tokens", 0)),
        )

    raise last or DeepSeekError("DeepSeek request failed")
