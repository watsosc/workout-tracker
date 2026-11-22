from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from app import auth
from app.main import app
from app.manage import set_password

PLANS = {"query": "{ plans { id } }"}
STATUS = {"query": "{ authStatus { authRequired signedIn username } }"}


def login_body(username: str, password: str) -> dict:
    return {
        "query": "mutation($u: String!, $p: String!) { login(username: $u, password: $p) { ok message token username } }",
        "variables": {"u": username, "p": password},
    }


@pytest.fixture(autouse=True)
def reset_throttle():
    auth.login_throttle = auth.LoginThrottle()
    yield


@pytest.fixture
def client():
    return TestClient(app)


def is_unauthenticated(response) -> bool:
    errors = response.json().get("errors") or []
    return any((e.get("extensions") or {}).get("code") == "UNAUTHENTICATED" for e in errors)


def test_api_is_open_until_a_password_is_set(client):
    assert client.post("/graphql", json=PLANS).json() == {"data": {"plans": []}}
    assert client.post("/graphql", json=STATUS).json()["data"]["authStatus"]["authRequired"] is False


def test_password_hashing_round_trip():
    stored = auth.hash_password("correct horse")
    assert stored.startswith("scrypt$") and "correct horse" not in stored
    assert auth.verify_password("correct horse", stored)
    assert not auth.verify_password("wrong", stored)
    assert not auth.verify_password("x", None)


def test_browser_login_with_cookie(client):
    set_password("Sean", "correct horse")

    assert is_unauthenticated(client.post("/graphql", json=PLANS))
    status = client.post("/graphql", json=STATUS).json()["data"]["authStatus"]
    assert status == {"authRequired": True, "signedIn": False, "username": None}

    bad = client.post("/graphql", json=login_body("sean", "nope")).json()["data"]["login"]
    assert bad["ok"] is False and bad["token"] is None

    # Username is case-insensitive.
    ok = client.post("/graphql", json=login_body("sean", "correct horse"))
    assert ok.json()["data"]["login"]["ok"] is True
    cookie = ok.headers["set-cookie"]
    assert auth.SESSION_COOKIE in cookie and "HttpOnly" in cookie and "samesite=lax" in cookie.lower()

    assert client.post("/graphql", json=PLANS).json() == {"data": {"plans": []}}
    assert client.post("/graphql", json=STATUS).json()["data"]["authStatus"]["username"] == "Sean"

    client.post("/graphql", json={"query": "mutation { logout { ok } }"})
    assert is_unauthenticated(client.post("/graphql", json=PLANS))


def test_native_login_with_bearer_token(client):
    set_password("sean", "correct horse")
    token = client.post("/graphql", json=login_body("sean", "correct horse")).json()["data"]["login"]["token"]
    client.cookies.clear()

    headers = {"Authorization": f"Bearer {token}"}
    assert client.post("/graphql", json=PLANS, headers=headers).json() == {"data": {"plans": []}}
    assert is_unauthenticated(client.post("/graphql", json=PLANS, headers={"Authorization": "Bearer junk"}))

    client.post("/graphql", json={"query": "mutation { logout { ok } }"}, headers=headers)
    assert is_unauthenticated(client.post("/graphql", json=PLANS, headers=headers))


def test_public_fields_cannot_smuggle_private_ones(client):
    set_password("sean", "correct horse")
    mixed = {"query": "{ authStatus { signedIn } plans { id } }"}
    assert is_unauthenticated(client.post("/graphql", json=mixed))


def test_repeated_failures_are_throttled(client):
    set_password("sean", "correct horse")
    for _ in range(5):
        client.post("/graphql", json=login_body("sean", "wrong"))
    blocked = client.post("/graphql", json=login_body("sean", "correct horse")).json()["data"]["login"]
    assert blocked["ok"] is False and "Too many" in blocked["message"]


def test_changing_password_signs_out_existing_sessions(client):
    set_password("sean", "correct horse")
    token = client.post("/graphql", json=login_body("sean", "correct horse")).json()["data"]["login"]["token"]
    set_password("sean", "battery staple")
    client.cookies.clear()
    assert is_unauthenticated(client.post("/graphql", json=PLANS, headers={"Authorization": f"Bearer {token}"}))
