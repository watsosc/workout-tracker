#!/usr/bin/env bash
# Start a throwaway backend for the e2e tests: fresh SQLite DB, a known login, and a seeded plan.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PY="${BACKEND_PYTHON:-$ROOT/backend/.venv/bin/python}"
PORT="${E2E_API_PORT:-8010}"
DB_DIR="$(mktemp -d)"
export DATABASE_URL="sqlite:///$DB_DIR/e2e.db"

cd "$ROOT/backend"
"$PY" - <<'PY'
from app.main import on_startup
from app.manage import set_password
from app.schema import schema

on_startup()
set_password("e2e", "e2e-password")
result = schema.execute_sync("""
mutation {
  seedPlan(
    planName: "E2E Plan"
    totalWeeks: null
    exercises: [{ name: "Squat", baseline1rmKg: 100 }]
    workouts: [
      { name: "Day A", sequenceIndex: 0, exercises: [
        { exerciseName: "Squat", progressionProtocol: GZCLP_T1, tier: T1, progressionType: LINEAR_KG, progressionValue: 2.5 }
        { exerciseName: "Lat Pulldown", sets: 2, reps: 10, targetWeightKg: 40, progressionProtocol: BASIC, progressionType: LINEAR_KG, progressionValue: 2.5 }
      ] }
      { name: "Day B", sequenceIndex: 1, exercises: [
        { exerciseName: "Curl", sets: 2, reps: 10, targetWeightKg: 10, progressionProtocol: BASIC, progressionType: LINEAR_KG, progressionValue: 1 }
      ] }
    ]
  ) { planId }
}
""")
assert not result.errors, result.errors
PY
exec "$PY" -m uvicorn app.main:app --host 127.0.0.1 --port "$PORT" --log-level warning
