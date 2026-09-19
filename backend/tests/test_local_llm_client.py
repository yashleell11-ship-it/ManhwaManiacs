"""The free model on the desktop, and the one line that keeps it safe.

The first version of this client let the model use the GPU. Ollama reported
22.8 GiB "available" on a card with ~11 GiB actually free -- Windows WDDM
overcommits VRAM into system RAM, so the runtime cannot see another process's
resident allocation -- loaded against that number, and killed a LoRA training
run 8,150 steps in. Bounding the context and the loaded-model count did not
prevent it, because the problem is not how much this client asks for; it is
that the server's own accounting is wrong about what is there.
"""

from __future__ import annotations

import json

import httpx
import pytest
from services import local_llm_client as local
from services.llm import LLMError, LLMNotConfigured


def _transport(handler):
    return httpx.MockTransport(handler)


def _chat(content='{"lines": []}', done="stop", model="qwen3:8b"):
    sent = {}

    def handle(request: httpx.Request) -> httpx.Response:
        sent["body"] = json.loads(request.content)
        sent["url"] = str(request.url)
        return httpx.Response(200, json={
            "model": model, "message": {"content": content},
            "done_reason": done, "prompt_eval_count": 1382, "eval_count": 368,
        })

    return _transport(handle), sent


class TestItCannotTakeTheCard:
    def test_it_asks_for_zero_gpu_layers(self, monkeypatch):
        # THE line. Attribution can run anywhere; TTS rendering can only run on
        # the GPU. Spending VRAM here was spending the scarce resource on the
        # fungible task -- and it cost a training run to learn.
        monkeypatch.delenv("MM_LOCAL_LLM_GPU_LAYERS", raising=False)
        transport, sent = _chat()

        local.complete_json("p", transport=transport)

        assert sent["body"]["options"]["num_gpu"] == 0

    def test_the_override_is_explicit_and_opt_in(self, monkeypatch):
        monkeypatch.setenv("MM_LOCAL_LLM_GPU_LAYERS", "20")
        transport, sent = _chat()

        local.complete_json("p", transport=transport)

        assert sent["body"]["options"]["num_gpu"] == 20

    def test_a_nonsense_override_falls_back_to_zero(self, monkeypatch):
        # A typo in an env var must not hand it the card.
        monkeypatch.setenv("MM_LOCAL_LLM_GPU_LAYERS", "all")

        assert local.gpu_layers() == 0

    def test_a_negative_override_is_zero(self, monkeypatch):
        monkeypatch.setenv("MM_LOCAL_LLM_GPU_LAYERS", "-5")

        assert local.gpu_layers() == 0

    def test_the_context_is_bounded(self, monkeypatch):
        # The KV cache grows with it, and a chapter's prompt is ~2,500 tokens.
        monkeypatch.delenv("MM_LOCAL_LLM_GPU_LAYERS", raising=False)
        transport, sent = _chat()

        local.complete_json("p", transport=transport)

        assert sent["body"]["options"]["num_ctx"] == local.NUM_CTX


class TestRequestShape:
    def test_it_asks_for_json_and_no_thinking(self, monkeypatch):
        monkeypatch.delenv("MM_LOCAL_LLM_GPU_LAYERS", raising=False)
        transport, sent = _chat()

        local.complete_json("p", system="rules", transport=transport)

        assert sent["body"]["format"] == "json"
        assert sent["body"]["think"] is False
        assert sent["body"]["stream"] is False
        assert [m["role"] for m in sent["body"]["messages"]] == ["system", "user"]

    def test_it_reports_what_served_the_request(self, monkeypatch):
        transport, _ = _chat(model="qwen3:14b")

        assert local.complete_json("p", transport=transport).model == "qwen3:14b"

    def test_usage_comes_back(self, monkeypatch):
        transport, _ = _chat()

        out = local.complete_json("p", transport=transport)

        assert (out.prompt_tokens, out.completion_tokens) == (1382, 368)


class TestFailure:
    def test_an_unreachable_server_is_not_configured_not_an_error(self):
        # So the caller falls back to the paid API rather than failing the
        # chapter: "the desktop is asleep" should cost a fraction of a cent.
        def boom(_request):
            raise httpx.ConnectError("refused")

        with pytest.raises(LLMNotConfigured):
            local.complete_json("p", transport=_transport(boom))

    def test_a_truncated_answer_is_an_error(self):
        # Same rule as the paid client, for the same reason: an answer cut off
        # parses as "no speaker anywhere", which is indistinguishable from a
        # chapter of pure narration and stores as confident and wrong.
        transport, _ = _chat(content="", done="length")

        with pytest.raises(LLMError, match="truncated"):
            local.complete_json("p", transport=transport)

    def test_an_empty_answer_is_an_error(self):
        transport, _ = _chat(content="   ")

        with pytest.raises(LLMError, match="empty"):
            local.complete_json("p", transport=transport)

    def test_an_http_error_is_reported(self):
        with pytest.raises(LLMError, match="500"):
            local.complete_json(
                "p", transport=_transport(lambda r: httpx.Response(500, json={}))
            )


class TestAvailability:
    def test_a_server_holding_the_model_is_available(self, monkeypatch):
        monkeypatch.delenv("MM_LOCAL_LLM_MODEL", raising=False)
        transport = _transport(lambda r: httpx.Response(
            200, json={"models": [{"name": "qwen3:8b"}]}))

        assert local.is_available(transport=transport) is True

    def test_a_server_with_no_model_is_NOT_available(self):
        # A running server with nothing loaded answers a request by trying to
        # pull several gigabytes in the middle of a chapter.
        transport = _transport(lambda r: httpx.Response(200, json={"models": []}))

        assert local.is_available(transport=transport) is False

    def test_a_dead_server_is_not_available(self):
        def boom(_request):
            raise httpx.ConnectError("refused")

        assert local.is_available(transport=_transport(boom)) is False
