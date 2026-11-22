"""Mid-workout changes, ad-hoc workouts, and editing/deleting finished workouts."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from conftest import SESSION_FIELDS, active_plan, complete_all_sets, finish, gql, seed_plan, start_workout

SESSION = SESSION_FIELDS.replace("sets { id", "sets { id skipped")


def next_day_a_weight() -> float:
    """Squat weight the next time day A is prescribed (skips through day B if needed)."""
    rx = gql("{ workoutPrescription { workoutName entries { exerciseName plannedWeightKg } } }")["workoutPrescription"]
    if rx["workoutName"] != "A":
        b = start_workout()
        complete_all_sets(b)
        finish(b["id"])
        rx = gql("{ workoutPrescription { workoutName entries { exerciseName plannedWeightKg } } }")["workoutPrescription"]
    return rx["entries"][0]["plannedWeightKg"]


def mutate(query: str, **variables) -> dict:
    return next(iter(gql(query, **variables).values()))


# ---------------------------------------------------------------- mid-workout


def test_skipping_an_exercise_entirely_leaves_progression_alone():
    seed_plan()
    session = start_workout()
    before = session["entries"][0]["plannedWeightKg"]
    entry_id = session["entries"][0]["id"]

    skipped = mutate(f"mutation($e: Int!) {{ skipExercise(entryId: $e) {{ {SESSION} }} }}", e=entry_id)
    assert all(s["skipped"] for s in skipped["entries"][0]["sets"])
    finish(session["id"])

    assert active_plan()["currentWorkoutIndex"] == 1  # the day still counts as done
    assert next_day_a_weight() == before


def test_partial_exercise_counts_as_failed_and_extra_sets_do_not_count():
    seed_plan()
    session = start_workout()
    entry = session["entries"][0]
    before = entry["plannedWeightKg"]

    # Complete all prescribed sets, then add an extra set and fail it badly: still a success.
    complete_all_sets(session)
    extra = mutate(f"mutation($e: Int!) {{ addSet(entryId: $e) {{ {SESSION} }} }}", e=entry["id"])
    extra_set = extra["entries"][0]["sets"][-1]
    assert extra_set["setIndex"] == len(entry["sets"]) + 1
    gql("mutation($i: Int!) { completeSet(sessionSetId: $i, repsCompleted: 0) { id } }", i=extra_set["id"])
    finish(session["id"])
    assert next_day_a_weight() > before


def test_swapped_and_added_exercises_are_logged_without_progression():
    seed_plan()
    session = start_workout()
    entry = session["entries"][0]
    before = entry["plannedWeightKg"]

    swapped = mutate(
        f'mutation($e: Int!) {{ swapExercise(entryId: $e, exerciseName: "Leg Press") {{ {SESSION} }} }}', e=entry["id"]
    )
    assert swapped["entries"][0]["exerciseName"] == "Leg Press"
    added = mutate(
        f'mutation($s: Int!) {{ addExerciseToWorkout(sessionId: $s, exerciseName: "Plank", sets: 2, reps: 1, weightKg: 0) {{ {SESSION} }} }}',
        s=session["id"],
    )
    assert added["entries"][1]["exerciseName"] == "Plank"
    assert added["entries"][1]["planWorkoutExerciseId"] is None
    assert len(added["entries"][1]["sets"]) == 2

    complete_all_sets(added)
    finished = finish(session["id"])
    assert finished["status"] == "COMPLETED"
    assert next_day_a_weight() == before  # squat wasn't done, so no progression


def test_empty_workout_is_logged_without_touching_the_plan():
    seed_plan()
    session = mutate(f'mutation {{ startEmptyWorkout(name: "Arms") {{ {SESSION} }} }}')
    assert session["planWorkoutId"] is None and session["planWorkoutName"] == "Arms"
    session = mutate(
        f'mutation($s: Int!) {{ addExerciseToWorkout(sessionId: $s, exerciseName: "Curl", sets: 2, reps: 10, weightKg: 15) {{ {SESSION} }} }}',
        s=session["id"],
    )
    complete_all_sets(session)
    finish(session["id"])

    assert active_plan()["currentWorkoutIndex"] == 0
    history = gql("{ workoutHistory { planWorkoutName planRunId completedSets } }")["workoutHistory"]
    assert history == [{"planWorkoutName": "Arms", "planRunId": None, "completedSets": 2}]


def test_completing_a_set_with_a_different_weight_is_recorded():
    seed_plan()
    session = start_workout()
    set_id = session["entries"][0]["sets"][0]["id"]
    gql("mutation($i: Int!) { completeSet(sessionSetId: $i, repsCompleted: 2, weightKg: 61.5) { id } }", i=set_id)
    current = gql("{ activeWorkoutSession { entries { sets { weightKg repsCompleted } } } }")
    assert current["activeWorkoutSession"]["entries"][0]["sets"][0] == {"weightKg": 61.5, "repsCompleted": 2}


# ---------------------------------------------------------------- offline upload with changes


def test_log_workout_supports_ad_hoc_swaps_extras_and_skips():
    seed_plan()
    rx = gql("{ workoutPrescription { planWorkoutId entries { planWorkoutExerciseId plannedSets plannedReps plannedWeightKg sets { setIndex targetReps isAmrap weightKg } } } }")["workoutPrescription"]
    t0 = datetime(2026, 1, 5, 18, 0, tzinfo=timezone.utc)
    entry = rx["entries"][0]
    payload = {
        "clientId": "offline-flex",
        "planWorkoutId": rx["planWorkoutId"],
        "startedAt": t0.isoformat(),
        "finishedAt": (t0 + timedelta(minutes=30)).isoformat(),
        "entries": [
            {   # planned squat, skipped entirely
                "planWorkoutExerciseId": entry["planWorkoutExerciseId"],
                "plannedSets": entry["plannedSets"], "plannedReps": entry["plannedReps"],
                "plannedWeightKg": entry["plannedWeightKg"],
                "sets": [{"setIndex": s["setIndex"], "targetReps": s["targetReps"], "weightKg": s["weightKg"], "skipped": True} for s in entry["sets"]],
            },
            {   # added mid-workout
                "exerciseName": "Lunge", "plannedSets": 1, "plannedReps": 10, "plannedWeightKg": 20,
                "sets": [{"setIndex": 1, "targetReps": 10, "weightKg": 22.5, "repsCompleted": 10, "completed": True,
                          "completedAt": (t0 + timedelta(minutes=10)).isoformat()}],
            },
        ],
    }
    logged = mutate(f"mutation($i: LogWorkoutInput!) {{ logWorkout(input: $i) {{ {SESSION} }} }}", i=payload)
    assert [e["exerciseName"] for e in logged["entries"]] == ["Squat", "Lunge"]
    assert all(s["skipped"] for s in logged["entries"][0]["sets"])
    assert logged["entries"][1]["sets"][0]["weightKg"] == 22.5

    ad_hoc = dict(payload, clientId="offline-adhoc", planWorkoutId=None, name="Hotel gym", entries=[payload["entries"][1]])
    logged = mutate(f"mutation($i: LogWorkoutInput!) {{ logWorkout(input: $i) {{ {SESSION} }} }}", i=ad_hoc)
    assert logged["planWorkoutId"] is None and logged["planWorkoutName"] == "Hotel gym"


# ---------------------------------------------------------------- editing / deleting history

EDIT = """mutation($s: Int!, $sets: [SetEditInput!]!) {
  updateWorkout(sessionId: $s, sets: $sets) { ok message progressionRecalculated }
}"""
DELETE = "mutation($s: Int!) { deleteWorkout(sessionId: $s) { ok message progressionRecalculated } }"


def _finish_day_a(reps: int):
    session = start_workout()
    complete_all_sets(session, reps=reps)
    return finish(session["id"])


def test_editing_latest_workout_recalculates_progression():
    seed_plan()
    before = gql("{ workoutPrescription { entries { plannedWeightKg } } }")["workoutPrescription"]["entries"][0]["plannedWeightKg"]
    finished = _finish_day_a(reps=1)  # failed every set of 5x3 -> weight stays
    squat_sets = finished["entries"][0]["sets"]

    # Oops, they were all actually successful.
    result = gql(EDIT, s=finished["id"], sets=[{"sessionSetId": s["id"], "repsCompleted": 3} for s in squat_sets])["updateWorkout"]
    assert result["ok"] and result["progressionRecalculated"]
    assert active_plan()["currentWorkoutIndex"] == 1  # advanced once, not twice
    assert next_day_a_weight() > before


def test_editing_an_older_workout_only_changes_history():
    seed_plan()
    first = _finish_day_a(reps=3)
    _later = start_workout()
    complete_all_sets(_later)
    finish(_later["id"])

    edit = [{"sessionSetId": first["entries"][0]["sets"][0]["id"], "repsCompleted": 3, "weightKg": 200}]
    result = gql(EDIT, s=first["id"], sets=edit)["updateWorkout"]
    assert result["ok"] and not result["progressionRecalculated"]
    stored = gql("query($s: Int!) { workoutSession(sessionId: $s) { entries { sets { weightKg } } } }", s=first["id"])
    assert stored["workoutSession"]["entries"][0]["sets"][0]["weightKg"] == 200


def test_deleting_latest_workout_undoes_its_progression():
    seed_plan()
    before = gql("{ workoutPrescription { workoutName entries { plannedWeightKg } } }")["workoutPrescription"]
    finished = _finish_day_a(reps=3)
    assert active_plan()["currentWorkoutIndex"] == 1

    result = gql(DELETE, s=finished["id"])["deleteWorkout"]
    assert result["ok"] and result["progressionRecalculated"]
    after = gql("{ workoutPrescription { workoutName entries { plannedWeightKg } } }")["workoutPrescription"]
    assert after == before
    assert gql("{ workoutHistory { sessionId } }")["workoutHistory"] == []


def test_cannot_edit_in_progress_workout_via_history():
    seed_plan()
    session = start_workout()
    result = gql(EDIT, s=session["id"], sets=[])["updateWorkout"]
    assert result["ok"] is False
    assert "Discard" in gql(DELETE, s=session["id"])["deleteWorkout"]["message"]
