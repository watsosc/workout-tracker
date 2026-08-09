#!/usr/bin/env bash
set -euo pipefail

# Fast redeploy script to run ON the VM.
#
# Pulls latest code, rebuilds backend/frontend, restarts services, and runs health checks.
#
# Optional env:
#   APP_DIR=/opt/workout-app
#   BRANCH=main
#   RESTART_CADDY=0        # set 1 to validate+reload Caddy
#
# Example:
#   BRANCH=main bash ~/deploy_vm_update.sh

APP_DIR="${APP_DIR:-/opt/workout-app}"
BRANCH="${BRANCH:-main}"
RESTART_CADDY="${RESTART_CADDY:-0}"

if [[ "${RESTART_CADDY}" != "0" && "${RESTART_CADDY}" != "1" ]]; then
	echo "ERROR: RESTART_CADDY must be 0 or 1 (got: ${RESTART_CADDY})" >&2
	exit 1
fi

SUDO=""
if [[ "${EUID}" -ne 0 ]]; then
	SUDO="sudo"
fi

log() {
	echo "[deploy-vm] $*"
}

wait_for_health() {
	local attempts="${1:-30}"
	local delay="${2:-1}"
	local i
	for ((i=1; i<=attempts; i++)); do
		if curl -fsS --max-time 3 http://127.0.0.1:8080/health >/dev/null 2>&1; then
			return 0
		fi
		sleep "${delay}"
	done
	return 1
}

need_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "ERROR: missing command: $1" >&2
		exit 1
	fi
}

main() {
	need_cmd git
	need_cmd python3
	need_cmd npm
	need_cmd curl

	if [[ ! -d "${APP_DIR}/.git" ]]; then
		echo "ERROR: ${APP_DIR} is not a git checkout. Run bootstrap first." >&2
		exit 1
	fi

	log "Updating repository (${BRANCH})..."
	git -C "${APP_DIR}" fetch --all --prune
	git -C "${APP_DIR}" checkout "${BRANCH}"
	git -C "${APP_DIR}" pull --ff-only origin "${BRANCH}"

	log "Installing backend dependencies..."
	if [[ ! -x "${APP_DIR}/.venv/bin/pip" ]]; then
		python3 -m venv "${APP_DIR}/.venv"
	fi
	"${APP_DIR}/.venv/bin/pip" install -e "${APP_DIR}/backend"

	log "Applying DB schema/migrations..."
	pushd "${APP_DIR}/backend" >/dev/null
	DATABASE_URL="sqlite:///${APP_DIR}/backend/workout.db" "${APP_DIR}/.venv/bin/python" -c "from app.db import Base, engine, apply_sqlite_migrations; Base.metadata.create_all(bind=engine); apply_sqlite_migrations()"
	popd >/dev/null

	log "Building frontend..."
	pushd "${APP_DIR}/web" >/dev/null
	npm ci
	npm run build
	popd >/dev/null

	log "Restarting workout-api..."
	$SUDO systemctl daemon-reload
	$SUDO systemctl restart workout-api

	if [[ "${RESTART_CADDY}" == "1" ]]; then
		log "Validating and reloading Caddy..."
		$SUDO caddy validate --config /etc/caddy/Caddyfile
		$SUDO systemctl reload caddy
	fi

	log "Checking service status..."
	$SUDO systemctl --no-pager --full status workout-api | sed -n '1,12p'
	$SUDO systemctl --no-pager --full status caddy | sed -n '1,12p' || true

	log "Waiting for API health..."
	if ! wait_for_health 45 1; then
		echo "ERROR: API did not become healthy on 127.0.0.1:8080 in time" >&2
		$SUDO systemctl --no-pager --full status workout-api || true
		$SUDO journalctl -u workout-api -n 120 --no-pager || true
		exit 1
	fi

	log "Health checks..."
	curl -fsS --max-time 5 http://127.0.0.1:8080/health
	curl -fsS --max-time 8 -H 'content-type: application/json' --data '{"query":"query { __typename }"}' http://127.0.0.1:8080/graphql

	log "Deploy complete."
}

main "$@"
