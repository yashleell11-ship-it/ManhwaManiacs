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


def _reply(content="{}", status=200, usage=None, headers=None, model="deepseek-flash",
           finish="stop"):
    body = {
        "choices": [{"message": {"content": content}, "finish_reason": finish}],
        "usage": usage or {"prompt_tokens": 6400, "completion_tokens": 900},
        "model": model,
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

    def test_it_records_what_served_the_request_not_what_was_asked(self, ledger):
        # DeepSeek aliases ids: a request for one name comes back stamped with
        # another. Storing the REQUESTED name would put a model in the database
        # that never ran, and an attribution nobody can audit afterwards.
        t = _transport(_reply("{}", model="deepseek-v9-surprise"))

        out = ds.complete_json("p", budget_path=ledger, transport=t)

        assert out.model == "deepseek-v9-surprise"
        assert json.loads(t.seen[0].content)["model"] == ds.MODEL  # type: ignore[attr-defined]

    def test_a_response_with_no_model_falls_back_to_the_requested_one(self, ledger):
        t = _transport(httpx.Response(200, json={
            "choices": [{"message": {"content": "{}"}}], "usage": {},
        }))

        assert ds.complete_json("p", budget_path=ledger, transport=t).model == ds.MODEL

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


class TestTruncation:
    """The failure that cost six real chapters and looked like success.

    This model reasons before answering and bills the reasoning as output, so a
    budget sized for the visible answer is spent entirely on thinking: content
    comes back EMPTY with finish_reason "length". Parsed as an answer, an empty
    object means "no speaker for any line" -- which is indistinguishable from a
    chapter of pure narration, and was stored as a confident, paid-for,
    completely wrong result.
    """

    def test_a_truncated_answer_is_an_error_not_an_empty_one(self, ledger):
        t = _transport(_reply(
            "", finish="length",
            usage={"prompt_tokens": 1493, "completion_tokens": 2000,
                   "completion_tokens_details": {"reasoning_tokens": 2000}},
        ))

        with pytest.raises(ds.DeepSeekError, match="truncated"):
            ds.complete_json("p", budget_path=ledger, transport=t)

    def test_the_error_says_where_the_budget_went(self, ledger):
        # "Truncated" alone sends you looking at the prompt. The reasoning
        # count is what points at max_tokens.
        t = _transport(_reply(
            "", finish="length",
            usage={"prompt_tokens": 1, "completion_tokens": 16000,
                   "completion_tokens_details": {"reasoning_tokens": 16000}},
        ))

        with pytest.raises(ds.DeepSeekError) as caught:
            ds.complete_json("p", budget_path=ledger, transport=t)

        assert "16000" in str(caught.value) and "reasoning" in str(caught.value)

    def test_truncation_still_counts_against_the_daily_budget(self, ledger):
        # It was served and billed. Failing to count it would let a
        # misconfigured budget spend without bound.
        t = _transport(_reply("", finish="length"))

        with pytest.raises(ds.DeepSeekError):
            ds.complete_json("p", budget_path=ledger, transport=t)

        assert ds.spent_today(ledger) == 1

    def test_an_empty_answer_that_did_not_truncate_is_also_an_error(self, ledger):
        t = _transport(_reply("   ", finish="stop"))

        with pytest.raises(ds.DeepSeekError, match="empty"):
            ds.complete_json("p", budget_path=ledger, transport=t)


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

    def test_a_missing_ledger_is_a_fresh_allowance(self, ledger):
        # No file at all is the ordinary state before the first request ever
        # made against this path -- a fresh deployment, or (as in every other
        # test in this file) a `ledger` fixture that never wrote one. That is
        # not the same claim as "we cannot prove what was spent" below, and
        # must not be refused the way a corrupt file now is.
        assert not ledger.exists()
        assert ds.spent_today(ledger) == 0

    def test_a_corrupt_ledger_is_refused_not_a_free_pass(self, ledger):
        # A ledger that EXISTS but cannot be trusted -- truncated JSON is
        # exactly what a crash mid-write used to leave behind -- must not
        # read as zero-spent. Zero-spent is a FRESH allowance, the most
        # permissive answer available, and handing it out precisely when the
        # ledger can no longer prove what was already charged is how a
        # crash-and-restart loop turns a 60/day ceiling into unlimited spend.
        ledger.write_text("{not json", encoding="utf-8")

        assert ds.spent_today(ledger) >= ds.DAILY_REQUEST_CEILING
        t = _transport(_reply())
        with pytest.raises(ds.DeepSeekBudgetExhausted):
            ds.complete_json("p", budget_path=ledger, transport=t)
        assert len(t.seen) == 0  # type: ignore[attr-defined]

    def test_wrong_permissions_are_refused_the_same_way(self, ledger):
        ledger.write_text(
            json.dumps({"date": ds._today(), "requests": 1}), encoding="utf-8"
        )
        ledger.chmod(0o000)
        try:
            assert ds.spent_today(ledger) >= ds.DAILY_REQUEST_CEILING
        finally:
            # So pytest can clean up tmp_path afterwards.
            ledger.chmod(0o644)

    def test_a_directory_where_the_ledger_should_be_refuses_not_spends(self, ledger):
        # A ledger every read AND every write fails against -- simulated here
        # as a directory sitting at the ledger's path -- must refuse rather
        # than fall through to treating the unreadable ledger as zero-spent.
        # The old comment called a lost write "survivable" on the theory that
        # only the counter tick was lost; the actual failure mode is worse:
        # a ledger that can never be read successfully reports zero spent on
        # EVERY subsequent call, which is unlimited spend, not one lost tick.
        ledger.mkdir()
        t = _transport(_reply())

        with pytest.raises(ds.DeepSeekBudgetExhausted):
            ds.complete_json("p", budget_path=ledger, transport=t)

        assert len(t.seen) == 0  # type: ignore[attr-defined]
        assert ds.spent_today(ledger) >= ds.DAILY_REQUEST_CEILING

    def test_the_write_is_atomic_no_temp_file_survives(self, ledger):
        # A crash between the temp-file write and the rename must never leave
        # a `.tmp-<pid>` sibling for something to later mistake for the
        # ledger -- and a successful write must leave none behind either.
        ds._record_request(ledger)

        siblings = list(ledger.parent.iterdir())
        assert siblings == [ledger]
        assert ds.spent_today(ledger) == 1


class TestAccountShare:
    """A per-account share under the global ceiling (``AccountBudget``).

    The global ledger alone let one account spend a feature's whole day. The
    share is a second ledger keyed by account, and it must keep every rule
    the global one has: refuse before spending, survive a restart, write
    atomically, and read a corrupt file as exhausted, never as fresh.
    """

    @pytest.fixture
    def accounts(self, tmp_path):
        return tmp_path / "accounts.json"

    def _share(self, accounts, who="7", ceiling=2):
        return ds.AccountBudget(path=accounts, account=who, ceiling=ceiling)

    def test_each_answered_request_is_charged_to_both_ledgers(
        self, ledger, accounts
    ):
        t = _transport(_reply())

        ds.complete_json(
            "p", budget_path=ledger, account_budget=self._share(accounts),
            transport=t,
        )

        assert ds.spent_today(ledger) == 1
        assert ds.account_spent_today(accounts, "7") == 1
        on_disk = json.loads(accounts.read_text(encoding="utf-8"))
        assert on_disk == {"date": ds._today(), "accounts": {"7": 1}}

    def test_a_spent_share_refuses_before_spending_with_the_global_open(
        self, ledger, accounts
    ):
        t = _transport(_reply())
        share = self._share(accounts, ceiling=2)
        for _ in range(2):
            ds.complete_json(
                "p", budget_path=ledger, account_budget=share, transport=t
            )

        with pytest.raises(ds.DeepSeekBudgetExhausted):
            ds.complete_json(
                "p", budget_path=ledger, account_budget=share, transport=t
            )

        assert len(t.seen) == 2  # type: ignore[attr-defined]
        assert ds.spent_today(ledger) == 2

    def test_one_accounts_spend_is_not_anothers(self, ledger, accounts):
        t = _transport(_reply())
        for _ in range(2):
            ds.complete_json(
                "p", budget_path=ledger,
                account_budget=self._share(accounts, "1"), transport=t,
            )

        ds.complete_json(
            "p", budget_path=ledger,
            account_budget=self._share(accounts, "2"), transport=t,
        )

        assert ds.account_spent_today(accounts, "1") == 2
        assert ds.account_spent_today(accounts, "2") == 1

    def test_yesterdays_shares_do_not_count_against_today(self, accounts):
        yesterday = (datetime.now(timezone.utc) - timedelta(days=1)).strftime("%Y-%m-%d")
        accounts.write_text(
            json.dumps({"date": yesterday, "accounts": {"7": 9, "8": 4}}),
            encoding="utf-8",
        )

        assert ds.account_spent_today(accounts, "7") == 0
        ds._record_account_request(self._share(accounts))
        on_disk = json.loads(accounts.read_text(encoding="utf-8"))
        # A new day starts every account at zero, not just the one charged.
        assert on_disk == {"date": ds._today(), "accounts": {"7": 1}}

    @pytest.mark.parametrize(
        "content", ["{not json", "[1, 2]", '{"date": "x", "accounts": [1]}']
    )
    def test_an_unreadable_share_ledger_refuses_every_account(
        self, ledger, accounts, content
    ):
        accounts.write_text(content, encoding="utf-8")
        t = _transport(_reply())

        assert ds.account_spent_today(accounts, "7") >= ds.DAILY_REQUEST_CEILING
        assert ds.account_spent_today(accounts, "new") >= ds.DAILY_REQUEST_CEILING
        with pytest.raises(ds.DeepSeekBudgetExhausted):
            ds.complete_json(
                "p", budget_path=ledger,
                account_budget=self._share(accounts, ceiling=10), transport=t,
            )
        assert len(t.seen) == 0  # type: ignore[attr-defined]

    def test_recording_never_rewrites_an_unreadable_share_ledger(self, accounts):
        # Rewriting it from scratch would hand every account a fresh day and
        # erase the one sign that a human needs to look.
        accounts.write_text("{trunc", encoding="utf-8")

        ds._record_account_request(self._share(accounts))

        assert accounts.read_text(encoding="utf-8") == "{trunc"

    def test_the_share_write_is_atomic_no_temp_file_survives(self, accounts):
        ds._record_account_request(self._share(accounts))

        assert list(accounts.parent.iterdir()) == [accounts]
        assert ds.account_spent_today(accounts, "7") == 1

    def test_concurrent_charges_to_different_accounts_are_all_kept(
        self, accounts
    ):
        # One file holds every account. Two requests finishing together must
        # not both read the same counts and have the second write drop the
        # first one's tick.
        import threading

        def charge(who: str) -> None:
            for _ in range(25):
                ds._record_account_request(self._share(accounts, who))

        threads = [
            threading.Thread(target=charge, args=(str(n),)) for n in range(8)
        ]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()

        on_disk = json.loads(accounts.read_text(encoding="utf-8"))
        assert on_disk["accounts"] == {str(n): 25 for n in range(8)}
