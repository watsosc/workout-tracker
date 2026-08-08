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

	log "Health checks..."
	curl -fsS http://127.0.0.1:8080/health
	curl -fsS -H 'content-type: application/json' --data '{"query":"query { __typename }"}' http://127.0.0.1:8080/graphql

	log "Deploy complete."
}

main "$@"
