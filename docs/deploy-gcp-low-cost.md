# Low-cost deploy on GCP (single-user)

Goal: keep monthly cost near $0 by using free-tier eligible resources.

## 1) Provision VM

- Machine: `e2-micro`
- Region: free-tier eligible (`us-central1`, `us-east1`, `us-west1`)
- Disk: small `pd-standard` (10-20GB)
- No load balancer

## 2) Bootstrap the VM (recommended)

Use the bootstrap script to perform runtime install + deploy in one pass.

From your local machine:

```bash
gcloud compute scp scripts/bootstrap_gce_vm.sh <VM_NAME>:~/ --zone <ZONE>
gcloud compute ssh <VM_NAME> --zone <ZONE> --command \
  "REPO_URL=<YOUR_REPO_URL> DOMAIN=<YOUR_DOMAIN_OR_DUCKDNS> BUCKET=gs://<YOUR_BUCKET> bash ~/bootstrap_gce_vm.sh"
```

- `REPO_URL` is required if `/opt/workout-app` does not already exist.
- `DOMAIN` is optional but recommended for HTTPS via Caddy.
- `BUCKET` is optional (enables backup timer setup).

## 3) Install runtime (manual path)

Install Python 3.11+, git, and optional Caddy/Nginx.

## 4) Deploy backend (manual path)

```bash
cd /opt/workout-app
python -m venv .venv
source .venv/bin/activate
pip install -e backend
```

Use the provided systemd unit template:
- `infra/systemd/workout-api.service`

Install it as `/etc/systemd/system/workout-api.service`, then:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now workout-api
```

Optional Strava integration env (kept off-repo):

```bash
sudo tee /etc/workout-api.env >/dev/null <<'EOF'
STRAVA_CLIENT_ID=your_client_id
STRAVA_CLIENT_SECRET=your_client_secret
STRAVA_REDIRECT_URI=https://your-domain/settings
STRAVA_SCOPES=activity:write,read
EOF
sudo chmod 600 /etc/workout-api.env
sudo systemctl restart workout-api
```

## 5) Deploy frontend (static)

Build locally and copy `web/build/` to the VM (or build on VM):

```bash
cd web
npm ci
npm run build
```

Serve static files with Caddy/Nginx and reverse-proxy `/graphql` to `127.0.0.1:8080`.
This keeps one public endpoint and avoids CORS complexity.

Example Caddyfile:

```caddy
workout.example.com {
  root * /opt/workout-app/web/build

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
```

## 6) Daily SQLite backup

Use provided backup script:

- `scripts/backup_sqlite_to_gcs.sh`
- `infra/systemd/workout-backup.service`
- `infra/systemd/workout-backup.timer`

Install service/timer under `/etc/systemd/system/`, set your bucket, then:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now workout-backup.timer
```

## 7) Cost guardrails

- Set budget alerts at `$1` and `$5`
- Avoid Cloud SQL and load balancer for MVP
- Keep network egress low
- Remove unused static IPs/resources

## 8) Upgrade path

When adding multi-user auth and more traffic:
1. Move DB to Postgres (Cloud SQL or self-managed)
2. Add auth provider
3. Optionally split frontend hosting
