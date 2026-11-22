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
- Undo the last logged set; after the final set you confirm **Finish** (so mistakes can still be fixed)
- Failed sets ask how many reps you actually did; **Change weight** applies to the remaining sets
- Mid-workout changes from the **Exercises** panel: skip, swap, add a set, add an exercise
  - Skipping an exercise entirely leaves its progression unchanged; stopping partway counts as a fail
  - Swapped/added exercises and extra sets are logged but don't drive plan progression
- **Empty workouts** outside the plan (logged in history, plan untouched)
- **Edit or delete finished workouts** from History. For your most recent workout, progression is
  undone and re-applied with the fixes; older workouts are corrected in history/PRs/charts only
- Exit menu: finish early (applies progression) or **discard** the workout (no progression, plan doesn't advance)
- Warm-up ramp (bar → ~40/60/80%) and plates-per-side for barbell lifts (lb: 45 bar, kg: 20 bar)
- Personal records (heaviest weight, estimated 1RM) shown when a workout finishes and in History
- iOS: rest-over notifications, and **offline logging** — workouts are recorded on the phone and
  uploaded when there's signal (see `ios/README.md`)

### Plan management
- Create plan (GZCLP template or custom)
- Multiple plans: one active at a time, switch/deactivate/delete from `/plan` (web) or Settings → Plans (iOS); each plan keeps its own progress
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
├── ios/                      # SwiftUI iOS frontend (no plan tab)
│   └── WorkoutTrackerIOS/
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
python -m pip install --upgrade pip
pip install .
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

### 3) One-command dev (shell)

From repo root:

```bash
./scripts/dev-all.sh --web
```

Or to launch the native iOS frontend in a **local iOS Simulator** (not hardware):

```bash
./scripts/dev-all.sh --ios
```

You can choose a preferred simulator device (default is `iPhone 16`):

```bash
./scripts/dev-all.sh --ios --ios-device "iPhone 16"
```

List simulator options:

```bash
./scripts/dev-all.sh --ios --ios-list-devices
```

Force mock heart-rate stream in the iOS app (80-135 bpm loop):

```bash
./scripts/dev-all.sh --ios --ios-mock-heart-rate
```

> `dev-all.sh` expects backend dependencies to already exist in `backend/.venv`.

From repo root (or from `web/`) you can run:

```bash
npm run dev:all:web
npm run dev:all:ios
npm run dev:all:ios:iphone16
npm run dev:all:ios:mockhr
```

Seed local test data (active + completed sessions and heart-rate samples):

```bash
# with backend venv active and deps installed
npm run seed:test-data
```

---

## Build checks

Frontend checks:

```bash
cd web
npm run check
npm run build
```

Tests (everything at once: `./scripts/test-all.sh`):

| Suite | Command | Covers |
|---|---|---|
| Backend | `cd backend && pip install '.[dev]' && python -m pytest` | GraphQL API, progression, auth, migrations-era behaviour |
| Web unit | `cd web && npm test` | plate/warm-up math, in-workout set logic |
| Web e2e | `cd web && npx playwright install chromium && npm run test:e2e` | real browser against a throwaway backend: sign-in, full workout, history edit/delete, empty workout |
| iOS unit | `xcodebuild test -project ios/WorkoutTrackerIOS.xcodeproj -scheme WorkoutTrackerIOS -destination 'platform=iOS Simulator,name=iPhone 17'` | local workout model, upload queue (stubbed network), old-data compatibility |
| iOS integration | `./scripts/test-ios-integration.sh` | the app's sync code against a live backend |

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

## Sign-in

The API is open until you set a login, then every request needs a session:

```bash
cd backend
python -m app.manage set-password          # prompts for username + password
python -m app.manage sign-out-everywhere   # revoke all sessions (e.g. lost phone)
python -m app.manage disable-login         # back to no login
```

- Web: `/login` form; the server sets an HttpOnly session cookie.
- iOS: a sign-in sheet appears when needed; the session token is kept in the Keychain.
- Passwords are stored as scrypt hashes; sessions expire after 180 days unused; 5 failed attempts
  from one address lock it out for 15 minutes.
- The backend logs a warning at startup while no password is set.

---

## Current constraints / assumptions

- Single-user app: one username/password login (see **Sign-in** below), not per-user accounts
- SQLite is intentional for MVP cost; Postgres migration can come with multi-user rollout

---

## Troubleshooting

- **Port already in use (8000/5173):** stop old dev processes before `dev-all.sh`.
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
