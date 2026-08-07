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

## Notes

- Single default user is created automatically (`id=1`).
- Schema is user-scoped, so auth can be added later without table redesign.
- Includes protocol-aware progression engine (`BASIC`, `GZCLP_T1`, `GZCLP_T2`, `GZCLP_T3`).
- Use `setExerciseOneRepMax` when T1/T2 triggers a new-1RM requirement after repeated failures.
