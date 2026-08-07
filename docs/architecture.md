# Architecture

## Goals

- Single-user workout tracker with immediate per-set persistence
- Very low GCP cost
- Future path to multi-user

## Cost-first decisions

1. **Single VM** (`e2-micro`)
2. **SQLite** database in local disk
3. **No Cloud SQL, no load balancer** for MVP
4. **Daily DB backups** to GCS

## Core backend modules

- `app/models.py`: SQLAlchemy models
- `app/schema.py`: GraphQL query + mutation layer
- `app/progression.py`: progression strategy logic
- `app/main.py`: FastAPI app wiring + startup DB creation

## Main domain flow

1. Seed plan (workouts/exercises/progression)
2. Start workout session (template -> live session entries + sets)
3. Complete sets individually (commit each set immediately)
4. Finish workout (progression updates + run position update)
5. Query history and exercise progress points for charts
6. Reset to baseline (baseline 1RM + training ratio)

## Progression protocol engine

Each plan exercise has a `progression_protocol` plus progression parameters.
Current protocols:

- `BASIC`: fixed sets/reps, simple progression on success
- `GZCLP_T1`: 5x3 -> 6x2 -> 10x1 failure ladder, AMRAP final set, 3rd failure requires new 1RM
- `GZCLP_T2`: 3x10 -> 3x8 -> 3x6 failure ladder, 3rd failure requires new 1RM
- `GZCLP_T3`: always 3x15, AMRAP final set, increase only if final set >= 25 reps

This design keeps complex logic out of UI and allows future protocols to be added as new handlers in `app/progression.py`.

## Infinite plans

- `plans.total_weeks = NULL` means infinite progression loop.

## Migration path to multi-user

Already prepared by schema:
- `user_id` exists across all major entities.

Later changes:
1. Add auth provider
2. Resolve current user from auth token
3. Migrate SQLite -> Postgres (minimal query changes)
