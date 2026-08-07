#!/usr/bin/env bash
set -euo pipefail

DB_PATH="${DB_PATH:-/opt/workout-app/backend/workout.db}"
BUCKET="${BUCKET:?BUCKET env var required, e.g. gs://my-workout-backups}"
TMP_FILE="$(mktemp /tmp/workout.XXXXXX.db)"

sqlite3 "$DB_PATH" ".backup '$TMP_FILE'"
gcloud storage cp "$TMP_FILE" "$BUCKET/workout-$(date +%F).db"
gcloud storage cp "$TMP_FILE" "$BUCKET/workout-latest.db"
rm -f "$TMP_FILE"

echo "Backup complete -> $BUCKET"
