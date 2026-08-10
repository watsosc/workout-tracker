# backend

Python GraphQL API for workout tracking.

## Run locally

```bash
python -m venv .venv
source .venv/bin/activate
pip install -e .
uvicorn app.main:app --reload
```

## Environment variables

- `DATABASE_URL` (default: `sqlite:///./workout.db`)
- `DEFAULT_USER_NAME` (currently informational)
- `STRAVA_CLIENT_ID` (optional, required to enable Strava OAuth/export)
- `STRAVA_CLIENT_SECRET` (optional, required to enable Strava OAuth/export)
- `STRAVA_REDIRECT_URI` (optional, required to enable Strava OAuth/export)
- `STRAVA_SCOPES` (optional, default: `activity:write,read`)

## Exercise catalog (canonical + autocomplete support)

The backend now supports a canonical exercise catalog with equipment metadata.

Main GraphQL fields:
- `exerciseCatalogSearch(query:, limit:)`
- `exerciseCatalogItem(catalogItemId:)`
- `linkExerciseToCatalog(exerciseId:, catalogItemId:)`

Sync from wger (manual run):

```bash
cd backend
source .venv/bin/activate
python -m app.sync_wger_catalog --page-limit 100
```

Useful flags:
- `--max-items 200` (partial sync)
- `--no-deactivate-missing` (do not deactivate missing source items)

## Notes

- Single default user is created automatically (`id=1`).
- Schema is user-scoped, so auth can be added later without table redesign.
- Includes protocol-aware progression engine (`BASIC`, `GZCLP_T1`, `GZCLP_T2`, `GZCLP_T3`).
- Use `setExerciseOneRepMax` when T1/T2 triggers a new-1RM requirement after repeated failures.
