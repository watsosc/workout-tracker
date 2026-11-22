#!/usr/bin/env bash
# Compile the iOS app's sync code for macOS and run it against a throwaway backend.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="${BACKEND_PYTHON:-$ROOT/backend/.venv/bin/python}"
PORT="${PORT:-8766}"
WORK="$(mktemp -d)"
trap 'kill "${SERVER_PID:-}" 2>/dev/null || true; rm -rf "$WORK"' EXIT

export DATABASE_URL="sqlite:///$WORK/test.db"
cd "$ROOT/backend"
"$PY" - <<'PY'
from app.main import on_startup
from app.manage import set_password
from app.schema import schema
on_startup()
set_password("sean", "correct horse")
result = schema.execute_sync('''mutation { seedPlan(planName: "H", totalWeeks: null,
  exercises: [{name: "Squat", baseline1rmKg: 100}],
  workouts: [{name: "A", sequenceIndex: 0, exercises: [{exerciseName: "Squat", progressionProtocol: GZCLP_T1}]},
             {name: "B", sequenceIndex: 1, exercises: [{exerciseName: "Curl"}]}]) { planId } }''')
assert not result.errors, result.errors
PY
# Server output goes to a file (the test triggers some errors on purpose); shown only on failure.
"$PY" -m uvicorn app.main:app --host 127.0.0.1 --port "$PORT" --log-level warning >"$WORK/server.log" 2>&1 &
SERVER_PID=$!

APP="$ROOT/ios/WorkoutTrackerIOS"
xcrun swiftc -o "$WORK/harness" \
  "$APP/Models/WorkoutModels.swift" "$APP/Core/WeightUnit.swift" "$APP/Core/GraphQLClient.swift" \
  "$APP/Core/WorkoutAPI.swift" "$APP/Core/OfflineWorkoutStore.swift" "$APP/Shared/BarbellMath.swift" \
  "$ROOT/ios/IntegrationTests/main.swift"

for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$PORT/health" >/dev/null && break; sleep 0.2; done
if ! WORKOUT_GRAPHQL_ENDPOINT="http://127.0.0.1:$PORT/graphql" "$WORK/harness"; then
  echo "--- server log ---"; cat "$WORK/server.log"; exit 1
fi
