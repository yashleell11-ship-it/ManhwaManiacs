"""A local model on the desktop's GPU, for attribution that costs nothing.

Same contract as ``deepseek_client`` — both return ``services.llm.Completion``
— so attribution takes whichever is available without knowing which it got.
The paid client stays as the fallback rather than being replaced: a local
server is a machine that can be off, mid-reboot, or busy rendering audio, and
"the desktop is asleep" should degrade to a few tenths of a cent, not to a
feature that stopped working.

Three rules here differ from the paid client, each for a reason:

**No host pinning.** The DeepSeek client refuses redirects because it carries a
bearer token, and a 302 is how a token reaches a host nobody audited. There is
no credential here, so the address is a plain setting.

**No spending ceiling.** There is nothing to spend. The limit that matters is
VRAM, and that one is not this module's to enforce — see below.

**It runs on the CPU by default, and that is not a compromise.** The first
attempt let it use the GPU. Ollama reported 22.8 GiB "available" on a card with
~11 GiB actually free -- Windows WDDM overcommits VRAM into system RAM, so the
runtime cannot see another process's resident allocation -- loaded against that
figure, and **killed a LoRA training run that was 8,150 steps in.**

Bounding the context and the loaded-model count did not prevent it, because the
problem is not how much this client asks for. It is that the server's own
accounting is wrong about how much is there. The only reliable fix is to stop
it touching the card at all.

The cost of that is latency nobody is waiting on: a chapter's answer is ~400
tokens, so a CPU pass is tens of seconds, on a background job that is free by
definition. The benefit is that the GPU stays entirely for TTS rendering --
which at RTF 1.82 is the real bottleneck, and is the one job that CANNOT run
anywhere else. Spending VRAM on attribution was always spending the scarce
resource on the fungible task.

Set ``MM_LOCAL_LLM_GPU_LAYERS`` above zero to override, on a machine where
nothing else holds the card.
"""

from __future__ import annotations

import logging
import os

import httpx

from services.llm import Completion, LLMError, LLMNotConfigured

logger = logging.getLogger(__name__)

DEFAULT_URL = "http://127.0.0.1:11434"

#: An 8B at 4-bit is ~5 GB and leaves room on a card that is already half full.
#: A 14B would fit the free VRAM on paper and not the variance in practice, and
#: the cost of being wrong is somebody's multi-hour training run.
DEFAULT_MODEL = "qwen3:8b"

#: Bounded on purpose: the KV cache grows with it, and a chapter's prompt is
#: ~2,500 tokens. Room for the largest chapter seen, and nothing spare.
NUM_CTX = 8192

#: Generous — an 8B on CPU is far slower than an API call, and the whole point
#: is that the wait costs nothing.
TIMEOUT_SECONDS = 900.0

#: GPU layers to offload. ZERO by default: see the module docstring. This is
#: the line that stops a free feature from destroying a paid-for training run.
def gpu_layers() -> int:
    try:
        return max(0, int(os.getenv("MM_LOCAL_LLM_GPU_LAYERS", "0")))
    except ValueError:
        return 0


def base_url() -> str:
    return os.getenv("MM_LOCAL_LLM_URL", DEFAULT_URL).rstrip("/")


def model_name() -> str:
    return os.getenv("MM_LOCAL_LLM_MODEL", DEFAULT_MODEL)


def is_available(*, timeout: float = 4.0, transport=None) -> bool:
    """Whether a local server is up AND holds the model we would ask for.

    Both halves matter: a running server with no model answers requests by
    trying to pull several gigabytes mid-chapter.
    """
    try:
        with httpx.Client(timeout=timeout, transport=transport) as client:
            response = client.get(f"{base_url()}/api/tags")
        if response.status_code != 200:
            return False
        names = {m.get("name", "") for m in response.json().get("models", [])}
    except (httpx.HTTPError, ValueError, KeyError, TypeError):
        return False
    wanted = model_name()
    # Ollama reports "qwen3:8b"; tolerate a bare "qwen3" being asked for.
    return any(n == wanted or n.split(":")[0] == wanted for n in names)


def complete_json(
    prompt: str,
    *,
    system: str = "",
    max_tokens: int = 8192,
    temperature: float = 0.0,
    timeout: float = TIMEOUT_SECONDS,
    transport=None,
    **_ignored,
) -> Completion:
    """One JSON-mode completion from the local model.

    ``**_ignored`` so this is a drop-in for the paid client, which takes budget
    arguments that mean nothing here.
    """
    messages: list[dict[str, str]] = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": prompt})

    payload = {
        "model": model_name(),
        "messages": messages,
        "stream": False,
        "format": "json",
        # Qwen3 reasons by default. Attribution is a reading task against text
        # in front of it, and on the paid model the thinking cost two to four
        # times the answer while changing none of it.
        "think": False,
        "options": {
            "temperature": temperature,
            "num_ctx": NUM_CTX,
            "num_predict": max_tokens,
            # The whole safety story, in one field.
            "num_gpu": gpu_layers(),
        },
    }

    try:
        with httpx.Client(timeout=timeout, transport=transport) as client:
            response = client.post(f"{base_url()}/api/chat", json=payload)
    except httpx.HTTPError as exc:
        raise LLMNotConfigured(
            f"local model unreachable at {base_url()}: {type(exc).__name__}"
        ) from exc

    if response.status_code >= 400:
        raise LLMError(f"local model returned HTTP {response.status_code}")

    try:
        body = response.json()
        content = body["message"]["content"]
    except (ValueError, KeyError, TypeError) as exc:
        raise LLMError(f"unexpected local-model response shape: {exc}") from exc

    # Same rule as the paid client, for the same reason: an answer cut off at
    # the token limit parses as "no speaker anywhere", which is
    # indistinguishable from a chapter of pure narration and is stored as a
    # confident, completely wrong result.
    if body.get("done_reason") == "length":
        raise LLMError(
            f"answer truncated at num_predict ({body.get('eval_count', '?')} "
            "tokens); raise max_tokens"
        )
    if not (content or "").strip():
        raise LLMError("local model returned an empty answer")

    return Completion(
        content=content,
        prompt_tokens=int(body.get("prompt_eval_count", 0)),
        completion_tokens=int(body.get("eval_count", 0)),
        model=str(body.get("model") or model_name()),
    )
