#!/usr/bin/env bash
set -euo pipefail

# Local helper: copies deploy_vm_update.sh to the VM and runs it.
#
# Optional env:
#   VM_NAME=workout-tracker
#   ZONE=us-central1-a
#   REMOTE_SCRIPT=~/deploy_vm_update.sh
#   APP_DIR=/opt/workout-app
#   BRANCH=main
#   RESTART_CADDY=0
#
# Example:
#   BRANCH=main ./scripts/deploy_gce.sh

VM_NAME="${VM_NAME:-workout-tracker}"
ZONE="${ZONE:-us-central1-a}"
REMOTE_SCRIPT="${REMOTE_SCRIPT:-~/deploy_vm_update.sh}"
APP_DIR="${APP_DIR:-/opt/workout-app}"
BRANCH="${BRANCH:-main}"
RESTART_CADDY="${RESTART_CADDY:-0}"

if [[ "${RESTART_CADDY}" != "0" && "${RESTART_CADDY}" != "1" ]]; then
	echo "ERROR: RESTART_CADDY must be 0 or 1 (got: ${RESTART_CADDY})" >&2
	exit 1
fi

echo "[deploy-gce] Copying deploy script to ${VM_NAME}..."
gcloud compute scp scripts/deploy_vm_update.sh "${VM_NAME}:${REMOTE_SCRIPT}" --zone "${ZONE}"

echo "[deploy-gce] Running deploy script on ${VM_NAME}..."
gcloud compute ssh "${VM_NAME}" --zone "${ZONE}" --command \
"chmod +x ${REMOTE_SCRIPT} && APP_DIR='${APP_DIR}' BRANCH='${BRANCH}' RESTART_CADDY='${RESTART_CADDY}' bash ${REMOTE_SCRIPT}"

echo "[deploy-gce] Done."
