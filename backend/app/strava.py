from __future__ import annotations

import json
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from .config import (
    STRAVA_BASE_URL,
    STRAVA_CLIENT_ID,
    STRAVA_CLIENT_SECRET,
    STRAVA_REDIRECT_URI,
    STRAVA_SCOPES,
)


class StravaError(RuntimeError):
    pass


def is_strava_configured() -> bool:
    return bool(STRAVA_CLIENT_ID and STRAVA_CLIENT_SECRET and STRAVA_REDIRECT_URI)


def build_authorize_url(state: str) -> str:
    if not is_strava_configured():
        raise StravaError("Strava OAuth not configured")

    query = urlencode(
        {
            "client_id": STRAVA_CLIENT_ID,
            "redirect_uri": STRAVA_REDIRECT_URI,
            "response_type": "code",
            "approval_prompt": "auto",
            "scope": STRAVA_SCOPES,
            "state": state,
        }
    )
    return f"{STRAVA_BASE_URL.rstrip('/')}/oauth/authorize?{query}"


def _request_json(
    method: str,
    path: str,
    form_data: dict[str, Any] | None = None,
    access_token: str | None = None,
) -> dict[str, Any]:
    url = f"{STRAVA_BASE_URL.rstrip('/')}{path}"
    body: bytes | None = None
    headers = {"accept": "application/json"}

    if form_data is not None:
        encoded = urlencode(form_data)
        body = encoded.encode("utf-8")
        headers["content-type"] = "application/x-www-form-urlencoded"

    if access_token:
        headers["authorization"] = f"Bearer {access_token}"

    req = Request(url, data=body, headers=headers, method=method)
    try:
        with urlopen(req, timeout=30) as resp:
            payload = resp.read().decode("utf-8")
            return json.loads(payload) if payload else {}
    except HTTPError as exc:
        detail = ""
        try:
            payload = exc.read().decode("utf-8")
            parsed = json.loads(payload)
            detail = parsed.get("message") or payload
        except Exception:
            detail = str(exc)
        raise StravaError(f"Strava API error ({exc.code}): {detail}") from exc
    except URLError as exc:
        raise StravaError(f"Strava API connection error: {exc}") from exc


def exchange_code_for_token(code: str) -> dict[str, Any]:
    if not is_strava_configured():
        raise StravaError("Strava OAuth not configured")

    return _request_json(
        "POST",
        "/oauth/token",
        {
            "client_id": STRAVA_CLIENT_ID,
            "client_secret": STRAVA_CLIENT_SECRET,
            "code": code,
            "grant_type": "authorization_code",
        },
    )


def refresh_access_token(refresh_token: str) -> dict[str, Any]:
    if not is_strava_configured():
        raise StravaError("Strava OAuth not configured")

    return _request_json(
        "POST",
        "/oauth/token",
        {
            "client_id": STRAVA_CLIENT_ID,
            "client_secret": STRAVA_CLIENT_SECRET,
            "grant_type": "refresh_token",
            "refresh_token": refresh_token,
        },
    )


def deauthorize(access_token: str) -> dict[str, Any]:
    return _request_json(
        "POST",
        "/oauth/deauthorize",
        access_token=access_token,
    )


def create_activity(access_token: str, payload: dict[str, Any]) -> dict[str, Any]:
    return _request_json(
        "POST",
        "/api/v3/activities",
        form_data=payload,
        access_token=access_token,
    )
