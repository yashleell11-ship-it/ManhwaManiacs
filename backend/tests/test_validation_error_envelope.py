"""The 422 envelope never echoes the request back.

Pydantic's error list carries each refused value as ``input``. Returned
verbatim, a password of the wrong type came back in the response body, an
oversized OCR upload came back in full, and a lone surrogate escape -- valid
JSON, not encodable as UTF-8 -- made the response itself raise, so the client
got a 500 where it should have got a 422.
"""

from __future__ import annotations


def test_a_refused_value_is_not_echoed(client):
    resp = client.post(
        "/auth/login", json={"username": "someone", "password": ["hunter2-secret"]}
    )
    assert resp.status_code == 422, resp.text
    body = resp.json()
    assert body["code"] == "validation_error"
    assert "hunter2-secret" not in resp.text
    assert all("input" not in error for error in body["details"])
    assert [error["loc"] for error in body["details"]] == [["body", "password"]]


def test_a_lone_surrogate_is_a_422_not_a_500(client):
    resp = client.post(
        "/auth/login",
        content=b'{"username": ["\\ud800"], "password": "x"}',
        headers={"Content-Type": "application/json"},
    )
    assert resp.status_code == 422, resp.text
    assert resp.json()["code"] == "validation_error"


def test_a_surrogate_in_a_body_key_still_renders(client):
    resp = client.post(
        "/auth/login",
        content=b'{"username": "someone", "password": {"\\udfff": 1}}',
        headers={"Content-Type": "application/json"},
    )
    assert resp.status_code == 422, resp.text
