from __future__ import annotations

import os
from pathlib import Path


BASE_DIR = Path(__file__).resolve().parents[1]
DEFAULT_SQLITE_PATH = BASE_DIR / "workout.db"


def _env_bool(name: str, default: bool = False) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def _load_local_env_file() -> None:
    env_path = BASE_DIR / ".env.local"
    if not env_path.exists():
        return

    for raw_line in env_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if not key or key in os.environ:
            continue
        value = value.strip()
        if (value.startswith('"') and value.endswith('"')) or (
            value.startswith("'") and value.endswith("'")
        ):
            value = value[1:-1]
        os.environ[key] = value


_load_local_env_file()

# Always resolve default SQLite path relative to backend/, not current working directory.
DATABASE_URL = os.getenv("DATABASE_URL", f"sqlite:///{DEFAULT_SQLITE_PATH}")
DEFAULT_USER_NAME = os.getenv("DEFAULT_USER_NAME", "default")

STRAVA_CLIENT_ID = os.getenv("STRAVA_CLIENT_ID")
STRAVA_CLIENT_SECRET = os.getenv("STRAVA_CLIENT_SECRET")
STRAVA_REDIRECT_URI = os.getenv("STRAVA_REDIRECT_URI")
STRAVA_SCOPES = os.getenv("STRAVA_SCOPES", "activity:write,read")
STRAVA_BASE_URL = os.getenv("STRAVA_BASE_URL", "https://www.strava.com")
STRAVA_DEV_FAKE_CONNECT = _env_bool("STRAVA_DEV_FAKE_CONNECT", False)
