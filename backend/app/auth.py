"""Username/password auth with server-side sessions.

The password is set from the command line (`python -m app.manage set-password`). Until one is set,
the API stays open (local dev). Clients get a session token from the `login` mutation: browsers
receive it as an HttpOnly cookie, native clients send it as `Authorization: Bearer <token>`.
"""

from __future__ import annotations

import hashlib
import hmac
import secrets
import threading
import time
from datetime import datetime, timedelta

from sqlalchemy import delete, func, select
from sqlalchemy.orm import Session

from .models import AuthSession, User

SESSION_COOKIE = "workout_session"
SESSION_IDLE_DAYS = 180  # sessions expire after this long without use
COOKIE_MAX_AGE_SECONDS = 400 * 24 * 3600  # browsers cap cookie lifetimes at ~400 days

_SCRYPT_N, _SCRYPT_R, _SCRYPT_P = 2**14, 8, 1


# ------------------------------------------------------------------ passwords


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.scrypt(password.encode(), salt=salt, n=_SCRYPT_N, r=_SCRYPT_R, p=_SCRYPT_P, dklen=32)
    return f"scrypt${_SCRYPT_N}${_SCRYPT_R}${_SCRYPT_P}${salt.hex()}${digest.hex()}"


def verify_password(password: str, stored: str | None) -> bool:
    if not stored:
        return False
    try:
        scheme, n, r, p, salt_hex, digest_hex = stored.split("$")
        if scheme != "scrypt":
            return False
        digest = hashlib.scrypt(
            password.encode(), salt=bytes.fromhex(salt_hex), n=int(n), r=int(r), p=int(p), dklen=32
        )
    except (ValueError, TypeError):
        return False
    return hmac.compare_digest(digest.hex(), digest_hex)


# Burn comparable time when the username is unknown so response timing doesn't reveal it.
_DUMMY_HASH = hash_password(secrets.token_hex(8))


# ------------------------------------------------------------------ sessions


def _token_hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def auth_required(session: Session) -> bool:
    return bool(session.scalar(select(func.count(User.id)).where(User.password_hash.is_not(None))))


def authenticate(session: Session, username: str, password: str) -> User | None:
    user = session.scalar(
        select(User).where(func.lower(User.name) == username.strip().lower(), User.password_hash.is_not(None))
    )
    if user is None:
        verify_password(password, _DUMMY_HASH)
        return None
    return user if verify_password(password, user.password_hash) else None


def create_session(session: Session, user: User, user_agent: str | None) -> str:
    token = secrets.token_urlsafe(32)
    now = datetime.utcnow()
    session.add(
        AuthSession(
            user_id=user.id,
            token_hash=_token_hash(token),
            created_at=now,
            last_used_at=now,
            expires_at=now + timedelta(days=SESSION_IDLE_DAYS),
            user_agent=(user_agent or "")[:200] or None,
        )
    )
    return token


def resolve_session(session: Session, token: str | None) -> AuthSession | None:
    """Return the live session for a token, sliding its expiry forward (at most once an hour)."""
    if not token:
        return None
    row = session.scalar(select(AuthSession).where(AuthSession.token_hash == _token_hash(token)))
    now = datetime.utcnow()
    if row is None or row.expires_at <= now:
        return None
    if now - row.last_used_at > timedelta(hours=1):
        row.last_used_at = now
        row.expires_at = now + timedelta(days=SESSION_IDLE_DAYS)
        session.commit()
    return row


def revoke_session(session: Session, token: str | None) -> None:
    if token:
        session.execute(delete(AuthSession).where(AuthSession.token_hash == _token_hash(token)))


def revoke_all_sessions(session: Session, user_id: int) -> int:
    return session.execute(delete(AuthSession).where(AuthSession.user_id == user_id)).rowcount or 0


# ------------------------------------------------------------------ brute-force throttling


class LoginThrottle:
    """In-memory limit on failed logins per client address (single-process deployment)."""

    def __init__(self, max_failures: int = 5, window_seconds: int = 15 * 60) -> None:
        self.max_failures = max_failures
        self.window_seconds = window_seconds
        self._failures: dict[str, list[float]] = {}
        self._lock = threading.Lock()

    def _recent(self, key: str, now: float) -> list[float]:
        recent = [t for t in self._failures.get(key, []) if now - t < self.window_seconds]
        self._failures[key] = recent
        return recent

    def retry_after(self, key: str) -> int:
        """Seconds until another attempt is allowed (0 = allowed now)."""
        now = time.monotonic()
        with self._lock:
            recent = self._recent(key, now)
            if len(recent) < self.max_failures:
                return 0
            return max(1, int(self.window_seconds - (now - recent[0])))

    def record_failure(self, key: str) -> None:
        with self._lock:
            self._recent(key, time.monotonic()).append(time.monotonic())

    def reset(self, key: str) -> None:
        with self._lock:
            self._failures.pop(key, None)


login_throttle = LoginThrottle()
