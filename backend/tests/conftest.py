from __future__ import annotations

import os
import tempfile
from pathlib import Path

import pytest

# Must be configured before `app` is imported: the engine is created at import time.
_TMP_DIR = Path(tempfile.mkdtemp(prefix="workout-tests-"))
os.environ["DATABASE_URL"] = f"sqlite:///{_TMP_DIR / 'test.db'}"

from app.db import Base, apply_sqlite_migrations, engine  # noqa: E402
from app.main import on_startup  # noqa: E402
from app.schema import schema  # noqa: E402


@pytest.fixture(autouse=True)
def fresh_db():
    Base.metadata.drop_all(bind=engine)
    Base.metadata.create_all(bind=engine)
    apply_sqlite_migrations()
    on_startup()
    yield


def gql(query: str, **variables):
    result = schema.execute_sync(query, variable_values=variables)
    if result.errors:
        raise AssertionError([e.message for e in result.errors])
    return result.data


def gql_error(query: str, **variables) -> str:
    result = schema.execute_sync(query, variable_values=variables)
    assert result.errors, "expected a GraphQL error"
    return result.errors[0].message


SEED = """
mutation Seed($name: String!, $activate: Boolean!, $squat: Float!) {
  seedPlan(
    planName: $name
    totalWeeks: null
    activate: $activate
    exercises: [{ name: "Squat", baseline1rmKg: $squat }]
    workouts: [
      { name: "A", sequenceIndex: 0, exercises: [
          { exerciseName: "Squat", progressionProtocol: GZCLP_T1, progressionType: LINEAR_KG, progressionValue: 5 }
      ] }
      { name: "B", sequenceIndex: 1, exercises: [
          { exerciseName: "Curl", sets: 3, reps: 10, targetWeightKg: 10, progressionType: LINEAR_KG, progressionValue: 1 }
      ] }
    ]
  ) { planId }
}
"""


def seed_plan(name: str = "Plan", activate: bool = True, squat: float = 100.0) -> int:
    return gql(SEED, name=name, activate=activate, squat=squat)["seedPlan"]["planId"]


SESSION_FIELDS = """
  id status planWorkoutId planWorkoutName
  entries { id planWorkoutExerciseId exerciseName plannedWeightKg sets { id setIndex targetReps completed repsCompleted weightKg } }
  personalRecords { exerciseName kind valueKg reps previousKg }
"""


def start_workout():
    return gql(f"mutation {{ startWorkout {{ {SESSION_FIELDS} }} }}")["startWorkout"]


def complete_all_sets(session: dict, weight_kg: float | None = None, reps: int | None = None) -> None:
    for entry in session["entries"]:
        for s in entry["sets"]:
            gql(
                "mutation($id: Int!, $reps: Int!, $w: Float) { completeSet(sessionSetId: $id, repsCompleted: $reps, weightKg: $w) { id } }",
                id=s["id"],
                reps=reps if reps is not None else s["targetReps"],
                w=weight_kg,
            )


def finish(session_id: int) -> dict:
    return gql(
        f"mutation($id: Int!) {{ finishWorkout(sessionId: $id) {{ {SESSION_FIELDS} }} }}", id=session_id
    )["finishWorkout"]


def active_plan() -> dict | None:
    return gql("{ activePlan { id name currentWeek currentWorkoutIndex } }")["activePlan"]
