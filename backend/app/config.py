from __future__ import annotations

import os
from pathlib import Path


BASE_DIR = Path(__file__).resolve().parents[1]
DEFAULT_SQLITE_PATH = BASE_DIR / "workout.db"

# Always resolve default SQLite path relative to backend/, not current working directory.
DATABASE_URL = os.getenv("DATABASE_URL", f"sqlite:///{DEFAULT_SQLITE_PATH}")
DEFAULT_USER_NAME = os.getenv("DEFAULT_USER_NAME", "default")

STRAVA_CLIENT_ID = os.getenv("STRAVA_CLIENT_ID")
STRAVA_CLIENT_SECRET = os.getenv("STRAVA_CLIENT_SECRET")
STRAVA_REDIRECT_URI = os.getenv("STRAVA_REDIRECT_URI")
STRAVA_SCOPES = os.getenv("STRAVA_SCOPES", "activity:write,read")
STRAVA_BASE_URL = os.getenv("STRAVA_BASE_URL", "https://www.strava.com")
