# web

SvelteKit frontend for workout tracking.

## Run

```bash
cd web
npm install
npm run dev
```

## Run frontend + backend together (fish)

From `web/`:

```fish
npm run dev:all
```

If you already have backend/frontend running, stop them first so ports 8000 and 5173 are free.

From repo root:

```fish
./scripts/dev-all.fish
```

The dev server proxies these paths to the backend at `http://127.0.0.1:8000`:
- `/graphql`
- `/health`

Optional override:
- `VITE_GRAPHQL_ENDPOINT` (defaults to `/graphql`)

So run backend first (from repo root):

```fish
cd backend
source .venv/bin/activate.fish
uvicorn app.main:app --reload
```

## Current UI

Route-based UI:
- `/` Home summary + start/create CTA
- `/workout` live workout tracking
- `/plan` create/edit plan (GZCLP or custom)
- `/analytics` charts
- `/history` completed session list
- `/settings` 1RM updates, reset, delete plan

Key flows:
- Clear top-level CTA to start workout when a plan exists
- Create plan flow when no plan exists (GZCLP template or custom)
- Numeric-only 1RM entry fields during plan creation
- Edit active plan by adding exercises to existing workouts
- Delete active plan (for testing/reset)
