#!/usr/bin/env bash
set -euo pipefail

# Local helper: copies deploy_vm_update.sh to the VM and runs it.
#
# Optional env:
#   VM_NAME=workout-tracker
#   ZONE=us-central1-a
#   REMOTE_SCRIPT=/tmp/workout_deploy_vm_update.sh
#   APP_DIR=/opt/workout-app
#   BRANCH=main
#   RESTART_CADDY=0
#
# Example:
#   BRANCH=main ./scripts/deploy_gce.sh

VM_NAME="${VM_NAME:-workout-tracker}"
ZONE="${ZONE:-us-central1-a}"
# Outside any home dir so the app owner (below) can read it whoever we SSH in as.
REMOTE_SCRIPT="${REMOTE_SCRIPT:-/tmp/workout_deploy_vm_update.sh}"
APP_DIR="${APP_DIR:-/opt/workout-app}"
BRANCH="${BRANCH:-main}"
RESTART_CADDY="${RESTART_CADDY:-0}"

if [[ "${RESTART_CADDY}" != "0" && "${RESTART_CADDY}" != "1" ]]; then
	echo "ERROR: RESTART_CADDY must be 0 or 1 (got: ${RESTART_CADDY})" >&2
	exit 1
fi

echo "[deploy-gce] Copying deploy script to ${VM_NAME}..."
gcloud compute scp scripts/deploy_vm_update.sh "${VM_NAME}:${REMOTE_SCRIPT}" --zone "${ZONE}"

# Run as the owner of APP_DIR (the user the service runs as), not the SSH user: the SSH username
# depends on the machine you deploy from, and running as anyone else breaks git ("dubious
# ownership"), the venv, and can leave the SQLite DB unwritable by the service.
echo "[deploy-gce] Running deploy script on ${VM_NAME} as the app owner..."
gcloud compute ssh "${VM_NAME}" --zone "${ZONE}" --command \
"chmod 755 ${REMOTE_SCRIPT} && OWNER=\$(stat -c %U '${APP_DIR}') && echo \"[deploy-gce] app owner: \$OWNER\" && sudo -u \"\$OWNER\" -H env APP_DIR='${APP_DIR}' BRANCH='${BRANCH}' RESTART_CADDY='${RESTART_CADDY}' bash ${REMOTE_SCRIPT}"

echo "[deploy-gce] Done."
