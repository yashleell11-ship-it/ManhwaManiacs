"""What every language-model client in this project returns, and raises.

Two clients answer the same question — a paid one at DeepSeek and a free one
on the desktop's GPU — and attribution takes whichever is available. That only
works if they are genuinely interchangeable, so the shape they share lives
here rather than in either of them. The alternative, one client importing the
other's dataclass, quietly makes the local path depend on the paid one.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any


class LLMError(RuntimeError):
    """Any failure to get a usable answer out of a model."""


class LLMNotConfigured(LLMError):
    """This client has nothing to talk to — no key, or no server."""


class LLMBudgetExhausted(LLMError):
    """A spending ceiling was reached. Never raised by a local model."""


@dataclass(frozen=True)
class Completion:
    """One answered request."""

    content: str
    prompt_tokens: int
    completion_tokens: int
    #: What actually served the request, as the server reports it — not what
    #: was asked for. The two differ whenever a model id is an alias, and an
    #: attribution is only auditable if it names the model that really ran.
    model: str = ""

    def json(self) -> Any:
        """The parsed body. Raises LLMError if it is not JSON.

        JSON mode makes this unlikely, not impossible: an answer truncated
        mid-object is well-formed as far as the server is concerned and
        unparseable here.
        """
        try:
            return json.loads(self.content)
        except ValueError as exc:
            raise LLMError(f"model returned unparseable JSON: {exc}") from exc
