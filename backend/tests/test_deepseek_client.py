"""The backend's only paid third-party call, and its only in-process API key.

Two properties here are worth more than the feature: the key must not reach
disk or a log line, and a runaway loop must not be able to spend without bound.
Everything runs against httpx.MockTransport -- these tests never touch the
network and never need a real key.
"""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from services import deepseek_client as ds

KEY = "sk-test-not-a-real-key-0000000000"


@pytest.fixture(autouse=True)
def _key(monkeypatch):
    monkeypatch.setenv("DEEPSEEK_API_KEY", KEY)


@pytest.fixture
def ledger(tmp_path):
    return tmp_path / "deepseek-usage.json"


def _reply(content="{}", status=200, usage=None, headers=None):
    body = {
        "choices": [{"message": {"content": content}}],
        "usage": usage or {"prompt_tokens": 6400, "completion_tokens": 900},
    }
    return httpx.Response(status, json=body, headers=headers or {})


def _transport(*responses):
    """Serve the given responses in order; record what was sent."""
    seen: list[httpx.Request] = []

    def handle(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return responses[min(len(seen) - 1, len(responses) - 1)]

    t = httpx.MockTransport(handle)
    t.seen = seen  # type: ignore[attr-defined]
    return t


class TestConfiguration:
    def test_a_missing_key_is_a_deployment_state_not_a_crash(self, monkeypatch):
        monkeypatch.delenv("DEEPSEEK_API_KEY", raising=False)

        assert ds.is_configured() is False
        with pytest.raises(ds.DeepSeekNotConfigured):
            ds.complete_json("hi", transport=_transport(_reply()))

    def test_a_blank_key_counts_as_missing(self, monkeypatch):
        # An env var set to "" is how a compose file spells "not set".
        monkeypatch.setenv("DEEPSEEK_API_KEY", "   ")

        assert ds.is_configured() is False

    def test_the_key_is_never_read_from_settings(self):
        # Settings is extra="allow" and is written back to settings.json, so a
        # key that reached it would be persisted to disk and into every backup.
        from core.config import get_settings

        dumped = json.dumps(get_settings().model_dump(), default=str)
        assert KEY not in dumped


class TestRequestShape:
    def test_it_posts_json_mode_to_the_pinned_host(self, ledger):
        t = _transport(_reply('{"spans": []}'))

        ds.complete_json("prompt", system="rules", budget_path=ledger, transport=t)

        sent = t.seen[0]  # type: ignore[attr-defined]
        assert str(sent.url) == "https://api.deepseek.com/chat/completions"
        body = json.loads(sent.content)
        assert body["response_format"] == {"type": "json_object"}
        # An extraction task with a right answer: sampling only adds a chance of
        # a different wrong one, and makes one chapter attribute two ways.
        assert body["temperature"] == 0.0
        assert body["stream"] is False
        assert [m["role"] for m in body["messages"]] == ["system", "user"]

    def test_usage_is_reported_back(self, ledger):
        t = _transport(_reply("{}", usage={"prompt_tokens": 1, "completion_tokens": 2}))

        out = ds.complete_json("p", budget_path=ledger, transport=t)

        assert (out.prompt_tokens, out.completion_tokens) == (1, 2)

    def test_the_body_is_parsed(self, ledger):
        t = _transport(_reply('{"spans": [{"rule": 1}]}'))

        out = ds.complete_json("p", budget_path=ledger, transport=t)

        assert out.json() == {"spans": [{"rule": 1}]}

    def test_a_truncated_answer_is_an_error_not_a_silent_empty(self, ledger):
        # JSON mode does not protect against hitting max_tokens mid-object.
        t = _transport(_reply('{"spans": [{"rul'))

        out = ds.complete_json("p", budget_path=ledger, transport=t)
        with pytest.raises(ds.DeepSeekError):
            out.json()


class TestRetries:
    def test_a_5xx_is_retried_once_and_can_succeed(self, ledger):
        t = _transport(_reply(status=503), _reply('{"ok": true}'))

        out = ds.complete_json("p", budget_path=ledger, transport=t)

        assert out.json() == {"ok": True}
        assert len(t.seen) == 2  # type: ignore[attr-defined]

    def test_an_auth_failure_is_not_retried(self, ledger):
        # Re-sending a bad request with a bad key buys nothing.
        t = _transport(_reply(status=401))

        with pytest.raises(ds.DeepSeekError):
            ds.complete_json("p", budget_path=ledger, transport=t)

        assert len(t.seen) == 1  # type: ignore[attr-defined]

    def test_an_error_never_quotes_the_key_back(self, ledger):
        # This API's auth error echoes the key, masked by them, not by us --
        # and this message goes to logs.
        t = _transport(
            httpx.Response(401, json={"error": {"message": f"key {KEY} is invalid"}})
        )

        with pytest.raises(ds.DeepSeekError) as caught:
            ds.complete_json("p", budget_path=ledger, transport=t)

        assert KEY not in str(caught.value)
        assert "401" in str(caught.value)

    def test_a_redirect_is_refused_rather_than_followed(self, ledger):
        # httpx re-sends Authorization on a redirect it follows. A 302 pointing
        # off-host is exactly how a bearer token reaches an unaudited server.
        t = _transport(
            httpx.Response(302, headers={"location": "https://elsewhere.example/v1"})
        )

        with pytest.raises(ds.DeepSeekError, match="refusing to follow"):
            ds.complete_json("p", budget_path=ledger, transport=t)

        assert len(t.seen) == 1  # type: ignore[attr-defined]


class TestDailyCeiling:
    def test_every_answered_request_is_counted(self, ledger):
        t = _transport(_reply())

        ds.complete_json("p", budget_path=ledger, transport=t)
        ds.complete_json("p", budget_path=ledger, transport=t)

        assert ds.spent_today(ledger) == 2

    def test_a_failed_but_answered_request_still_costs(self, ledger):
        # It was served; whether we could use the answer is our problem.
        t = _transport(_reply(status=400))

        with pytest.raises(ds.DeepSeekError):
            ds.complete_json("p", budget_path=ledger, transport=t)

        assert ds.spent_today(ledger) == 1

    def test_the_ceiling_refuses_loudly(self, ledger):
        ledger.write_text(
            json.dumps({"date": ds._today(), "requests": 500}), encoding="utf-8"
        )
        t = _transport(_reply())

        with pytest.raises(ds.DeepSeekBudgetExhausted):
            ds.complete_json("p", budget_path=ledger, transport=t)

        # And it refuses BEFORE spending.
        assert len(t.seen) == 0  # type: ignore[attr-defined]

    def test_the_ceiling_survives_a_restart(self, ledger):
        # Counted on disk, not in memory: this box redeploys several times a
        # day, and an in-process counter would reset the budget each time.
        ledger.write_text(
            json.dumps({"date": ds._today(), "requests": 7}), encoding="utf-8"
        )

        assert ds.spent_today(ledger) == 7

    def test_yesterdays_spend_does_not_count_against_today(self, ledger):
        yesterday = (datetime.now(timezone.utc) - timedelta(days=1)).strftime("%Y-%m-%d")
        ledger.write_text(
            json.dumps({"date": yesterday, "requests": 499}), encoding="utf-8"
        )

        assert ds.spent_today(ledger) == 0

    def test_a_corrupt_ledger_is_not_a_free_pass(self, ledger):
        ledger.write_text("{not json", encoding="utf-8")

        # Reads as zero-for-today rather than raising or disabling the ceiling.
        assert ds.spent_today(ledger) == 0
        t = _transport(_reply())
        ds.complete_json("p", budget_path=ledger, transport=t)
        assert ds.spent_today(ledger) == 1
