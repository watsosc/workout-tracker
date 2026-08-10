#!/usr/bin/env bash
set -euo pipefail

# Bootstrap script for a fresh Debian-based GCE VM.
#
# What it does:
# 1) installs runtime deps (git/python/node/caddy)
# 2) clones or updates this repo
# 3) creates backend venv + installs backend package
# 4) builds frontend static output
# 5) installs/starts workout-api systemd service
# 6) configures Caddy for static web + /graphql and /health reverse proxy
# 7) optionally configures daily SQLite backups to GCS (disabled by default)
#
# Required env (if APP_DIR does not already contain a git repo):
#   REPO_URL=https://github.com/<you>/<repo>.git
#
# Common optional env:
#   BRANCH=main
#   APP_DIR=/opt/workout-app
#   APP_USER=<linux user to run app/systemd service>   (default: current user)
#   DOMAIN=<public domain, e.g. your.duckdns.org>
#   SITE_HOST=<Caddy site label; overrides DOMAIN; defaults to DOMAIN or :80>
#   ENABLE_BACKUPS=1                                   (required to enable backup setup)
#   BUCKET=gs://your-backup-bucket                     (required if ENABLE_BACKUPS=1)
#
# Example:
#   REPO_URL=https://github.com/me/workout-app.git \
#   DOMAIN=myapp.duckdns.org \
#   bash scripts/bootstrap_gce_vm.sh
#
# Backup-enabled example:
#   REPO_URL=https://github.com/me/workout-app.git \
#   DOMAIN=myapp.duckdns.org \
#   ENABLE_BACKUPS=1 BUCKET=gs://my-workout-backups \
#   bash scripts/bootstrap_gce_vm.sh

APP_DIR="${APP_DIR:-/opt/workout-app}"
BRANCH="${BRANCH:-main}"
APP_USER="${APP_USER:-$(id -un)}"
APP_GROUP="${APP_GROUP:-$(id -gn)}"
DOMAIN="${DOMAIN:-}"
SITE_HOST="${SITE_HOST:-${DOMAIN:-:80}}"
ENABLE_BACKUPS="${ENABLE_BACKUPS:-0}"
BUCKET="${BUCKET:-}"
NODE_MAJOR="${NODE_MAJOR:-20}"

if [[ "${ENABLE_BACKUPS}" != "0" && "${ENABLE_BACKUPS}" != "1" ]]; then
	echo "ERROR: ENABLE_BACKUPS must be 0 or 1 (got: ${ENABLE_BACKUPS})" >&2
	exit 1
fi

if [[ "${ENABLE_BACKUPS}" == "1" ]]; then
	if [[ -z "${BUCKET}" ]]; then
		echo "ERROR: BUCKET is required when ENABLE_BACKUPS=1" >&2
		exit 1
	fi
	if [[ ! "${BUCKET}" =~ ^gs:// ]]; then
		echo "ERROR: BUCKET must start with gs:// (got: ${BUCKET})" >&2
		exit 1
	fi
fi

SUDO=""
if [[ "${EUID}" -ne 0 ]]; then
	SUDO="sudo"
fi

log() {
	echo "[bootstrap] $*"
}

need_cmd() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "ERROR: missing required command: $1" >&2
		exit 1
	fi
}

apt_install_base() {
	log "Installing base packages..."
	$SUDO apt-get update
	$SUDO apt-get install -y \
		ca-certificates \
		curl \
		git \
		python3 \
		python3-venv \
		python3-pip \
		sqlite3 \
		caddy
}

install_or_upgrade_node() {
	local install_node=0
	if ! command -v node >/dev/null 2>&1; then
		install_node=1
	else
		local major
		major="$(node -v | sed -E 's/^v([0-9]+).*/\1/')"
		if [[ "${major}" -lt "${NODE_MAJOR}" ]]; then
			install_node=1
		fi
	fi

	if [[ "${install_node}" -eq 1 ]]; then
		log "Installing Node.js ${NODE_MAJOR}.x ..."
		curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | $SUDO -E bash -
		$SUDO apt-get install -y nodejs
	else
		log "Node.js already present: $(node -v)"
	fi
}

prepare_repo() {
	local parent_dir
	parent_dir="$(dirname "${APP_DIR}")"
	$SUDO mkdir -p "${parent_dir}"
	$SUDO chown "${APP_USER}:${APP_GROUP}" "${parent_dir}"

	if [[ -d "${APP_DIR}/.git" ]]; then
		log "Repo exists at ${APP_DIR}; updating ${BRANCH}..."
		git -C "${APP_DIR}" fetch --all --prune
		git -C "${APP_DIR}" checkout "${BRANCH}"
		git -C "${APP_DIR}" pull --ff-only origin "${BRANCH}"
	else
		if [[ -z "${REPO_URL:-}" ]]; then
			echo "ERROR: REPO_URL is required when ${APP_DIR} is not already a git repo." >&2
			exit 1
		fi
		log "Cloning ${REPO_URL} (${BRANCH}) into ${APP_DIR}..."
		git clone --branch "${BRANCH}" "${REPO_URL}" "${APP_DIR}"
	fi

	$SUDO chown -R "${APP_USER}:${APP_GROUP}" "${APP_DIR}"
}

setup_backend_venv() {
	log "Setting up backend virtualenv and dependencies..."
	python3 -m venv "${APP_DIR}/.venv"
	"${APP_DIR}/.venv/bin/pip" install --upgrade pip
	"${APP_DIR}/.venv/bin/pip" install -e "${APP_DIR}/backend"
}

build_frontend() {
	log "Building frontend..."
	pushd "${APP_DIR}/web" >/dev/null
	npm ci
	npm run build
	popd >/dev/null
}

install_workout_api_service() {
	log "Installing workout-api.service ..."
	local tmp
	tmp="$(mktemp)"
	cat >"${tmp}" <<EOF
[Unit]
Description=Workout App API
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
WorkingDirectory=${APP_DIR}
Environment=DATABASE_URL=sqlite:///${APP_DIR}/backend/workout.db
EnvironmentFile=-/etc/workout-api.env
ExecStart=${APP_DIR}/.venv/bin/uvicorn app.main:app --app-dir ${APP_DIR}/backend --host 127.0.0.1 --port 8080
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
	$SUDO install -o root -g root -m 0644 "${tmp}" /etc/systemd/system/workout-api.service
	rm -f "${tmp}"
	$SUDO systemctl daemon-reload
	$SUDO systemctl enable --now workout-api
}

configure_caddy() {
	log "Configuring Caddy site (${SITE_HOST}) ..."
	local tmp
	tmp="$(mktemp)"
	cat >"${tmp}" <<EOF
${SITE_HOST} {
  root * ${APP_DIR}/web/build

  handle /graphql* {
    reverse_proxy 127.0.0.1:8080
  }

  handle /health {
    reverse_proxy 127.0.0.1:8080
  }

  handle {
    try_files {path} {path}.html {path}/ /index.html
    file_server
  }
}
EOF
	$SUDO install -o root -g root -m 0644 "${tmp}" /etc/caddy/Caddyfile
	rm -f "${tmp}"
	$SUDO caddy validate --config /etc/caddy/Caddyfile
	$SUDO systemctl enable --now caddy
	$SUDO systemctl reload caddy
}

configure_backups_if_requested() {
	if [[ "${ENABLE_BACKUPS}" != "1" ]]; then
		log "Backups disabled (ENABLE_BACKUPS=0); skipping backup timer setup."
		return
	fi

	if ! command -v gcloud >/dev/null 2>&1; then
		log "WARNING: gcloud is not installed. Backup service will be installed but fail until gcloud is available."
	fi

	log "Configuring daily backup timer for bucket ${BUCKET} ..."
	chmod +x "${APP_DIR}/scripts/backup_sqlite_to_gcs.sh"

	local svc_tmp timer_tmp
	svc_tmp="$(mktemp)"
	timer_tmp="$(mktemp)"

	cat >"${svc_tmp}" <<EOF
[Unit]
Description=Workout DB backup to GCS

[Service]
Type=oneshot
User=${APP_USER}
Environment=BUCKET=${BUCKET}
ExecStart=${APP_DIR}/scripts/backup_sqlite_to_gcs.sh
EOF

	cat >"${timer_tmp}" <<'EOF'
[Unit]
Description=Daily workout DB backup

[Timer]
OnCalendar=*-*-* 06:30:00 UTC
Persistent=true

[Install]
WantedBy=timers.target
EOF

	$SUDO install -o root -g root -m 0644 "${svc_tmp}" /etc/systemd/system/workout-backup.service
	$SUDO install -o root -g root -m 0644 "${timer_tmp}" /etc/systemd/system/workout-backup.timer
	rm -f "${svc_tmp}" "${timer_tmp}"
	$SUDO systemctl daemon-reload
	$SUDO systemctl enable --now workout-backup.timer
}

print_status() {
	log "Done. Service status:"
	$SUDO systemctl --no-pager --full status workout-api || true
	$SUDO systemctl --no-pager --full status caddy || true
	if [[ "${ENABLE_BACKUPS}" == "1" ]]; then
		$SUDO systemctl --no-pager --full status workout-backup.timer || true
	fi

	echo
	log "Health check (local):"
	curl -fsS http://127.0.0.1:8080/health || true

	echo
	log "If DNS points here, app should be reachable at:"
	echo "  https://${DOMAIN:-<your-domain>}"
}

main() {
	need_cmd bash
	need_cmd curl
	need_cmd python3

	apt_install_base
	install_or_upgrade_node
	prepare_repo
	setup_backend_venv
	build_frontend
	install_workout_api_service
	configure_caddy
	configure_backups_if_requested
	print_status
}

main "$@"
