# Workout App

A **cost-first, single-user workout tracker** built for fast iteration and near-free hosting on GCP.

- **Frontend:** SvelteKit (PWA-friendly)
- **Backend:** FastAPI + Strawberry GraphQL
- **DB:** SQLite (single file)
- **Deployment target:** single GCE VM + systemd + daily GCS backup

> Current behavior is optimized for one user (no auth yet), but the data model is already user-scoped for future multi-user migration.

---

## What you get in v1

### Workout flow
- Start/resume workout from `/workout`
- In-session focused overlay UI (mobile-first)
- Per-set persistence (every set save is immediate)
- Success/fail actions per set
- AMRAP-aware flow (`X+ reps`), custom in-app AMRAP prompt
- Auto-finish when all sets are complete

### Plan management
- Create plan (GZCLP template or custom)
- Add/remove days
- Add/remove exercises
- Drag/drop exercises between days
- Tier-order constraints (T1 → T2 → T3)
- Active plan editing UX aligned with create UX

### Progression + data
- Protocol-aware progression: `BASIC`, `GZCLP_T1`, `GZCLP_T2`, `GZCLP_T3`
- Tier-aware run state (same exercise can progress separately by tier)
- Profile 1RM updates from completed workouts
- Reset progression to **saved plan-start 1RM snapshot**
- Weight units: `lb`/`kg` toggle (default `lb`)
- Displayed load values snap to valid 0.5-unit increments

### Insights
- Analytics charts with axes/ticks
- Exercise progress chart (top set + estimated 1RM)
- Total volume chart (overall + per day of current plan)
- History with per-workout and per-exercise summaries

---

## Tech stack

- **Backend:** Python 3.11+, FastAPI, Strawberry GraphQL, SQLAlchemy
- **Frontend:** SvelteKit 2, Svelte 5, Vite, adapter-static
- **Database:** SQLite (`backend/workout.db` by default)

---

## Project structure

```text
workout-app/
├── backend/                  # FastAPI + GraphQL API
│   └── app/
│       ├── main.py           # FastAPI app + /graphql + /health
│       ├── schema.py         # GraphQL queries/mutations
│       ├── models.py         # SQLAlchemy models
│       ├── progression.py    # Progression engine
│       └── db.py             # DB session + sqlite migrations
├── web/                      # SvelteKit frontend
│   └── src/routes/
│       ├── workout/
│       ├── plan/
│       ├── analytics/
│       ├── history/
│       └── settings/
├── docs/
│   ├── architecture.md
│   ├── deploy-gcp-low-cost.md
│   └── graphql-examples.md
├── infra/systemd/            # systemd service/timer templates
└── scripts/                  # dev + backup scripts
```

---

## Local development

### 1) Backend

```bash
cd backend
python -m venv .venv
source .venv/bin/activate
pip install -e .
uvicorn app.main:app --reload --host 127.0.0.1 --port 8000
```

Backend URLs:
- GraphQL IDE: `http://127.0.0.1:8000/graphql`
- Health: `http://127.0.0.1:8000/health`

### 2) Frontend

```bash
cd web
npm install
npm run dev
```

Frontend URL:
- `http://127.0.0.1:5173`

Vite proxies `/graphql` and `/health` to backend in dev.

### 3) One-command dev (fish)

From repo root:

```fish
./scripts/dev-all.fish
```

> `dev-all.fish` expects backend dependencies to already exist in `backend/.venv`.

Or from `web/`:

```fish
npm run dev:all
```

---

## Build checks

Frontend checks:

```bash
cd web
npm run check
npm run build
```

Backend syntax sanity check:

```bash
python -m py_compile backend/app/schema.py
```

---

## Runtime config

Backend env vars:

- `DATABASE_URL`
  - Default: `sqlite:///.../backend/workout.db`
- `DEFAULT_USER_NAME`
  - Default: `default`
- `STRAVA_CLIENT_ID` (optional; required for Strava integration)
- `STRAVA_CLIENT_SECRET` (optional; required for Strava integration)
- `STRAVA_REDIRECT_URI` (optional; required for Strava integration)
- `STRAVA_SCOPES`
  - Default: `activity:write,read`

Notes:
- A default user (`id=1`) is auto-created at startup.
- SQLite migrations needed for local schema drift are applied at startup.
- On VM/systemd deploys, put secrets in `/etc/workout-api.env` (loaded via `EnvironmentFile=-/etc/workout-api.env`).

---

## Routes

- `/` redirects to `/workout`
- `/workout` active session + workout start
- `/plan` create/edit plan
- `/analytics` charts and trends
- `/history` workout/exercise history + Strava send actions
- `/settings` units, 1RM updates, reset actions, Strava connect/disconnect + auto-send toggle (default off), delete plan

---

## Deployment (low-cost GCP)

Recommended MVP deploy model:
- One `e2-micro` VM
- Backend via systemd on localhost port `8080`
- Static frontend served by Caddy/Nginx
- Reverse proxy `/graphql` and `/health` to backend
- Optional daily SQLite backup to GCS via systemd timer

### First-time VM bootstrap

Use:
- `scripts/bootstrap_gce_vm.sh` (run on VM)

### Ongoing deploys (similar to baseball workflow)

Use:
- `scripts/deploy_gce.sh` (run locally; copies+executes remote deploy script)
- `scripts/deploy_vm_update.sh` (run on VM directly)

Example redeploy from local machine:

```bash
./scripts/deploy_gce.sh
```

With explicit target/branch:

```bash
VM_NAME=workout-tracker ZONE=us-central1-a BRANCH=main ./scripts/deploy_gce.sh
```

See full steps:
- `docs/deploy-gcp-low-cost.md`
- `infra/systemd/workout-api.service`
- `infra/systemd/workout-backup.service`
- `infra/systemd/workout-backup.timer`
- `scripts/backup_sqlite_to_gcs.sh`

---

## API reference/examples

GraphQL examples live in:
- `docs/graphql-examples.md`

---

## Current constraints / assumptions

- Single-user app (no auth yet)
- No multi-tenant API controls yet (don’t expose publicly without basic protection)
- SQLite is intentional for MVP cost; Postgres migration can come with multi-user rollout

---

## Troubleshooting

- **Port already in use (8000/5173):** stop old dev processes before `dev-all.fish`.
- **Frontend can’t reach API:** confirm backend is running and dev proxy target is `127.0.0.1:8000`.
- **Unexpected SQLite behavior:** verify active DB path (`DATABASE_URL`) and that startup migrations completed.
- **No analytics points visible:** complete at least one workout set/session for relevant series.

---

## Documentation

- Architecture: `docs/architecture.md`
- Deploy: `docs/deploy-gcp-low-cost.md`
- GraphQL examples: `docs/graphql-examples.md`
- Backend notes: `backend/README.md`
- Frontend notes: `web/README.md`
