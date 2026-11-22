from __future__ import annotations

from datetime import datetime, timedelta, timezone

from conftest import (
    SESSION_FIELDS,
    active_plan,
    complete_all_sets,
    finish,
    gql,
    gql_error,
    seed_plan,
    start_workout,
)


# ---------------------------------------------------------------- multiple plans


def test_switching_plans_resumes_each_plans_progress():
    plan_a = seed_plan("A")
    plan_b = seed_plan("B")
    assert active_plan()["id"] == plan_b

    session = start_workout()
    complete_all_sets(session)
    finish(session["id"])
    assert active_plan()["currentWorkoutIndex"] == 1

    gql("mutation($p: Int!) { setActivePlan(planId: $p) { ok } }", p=plan_a)
    assert active_plan()["id"] == plan_a
    assert active_plan()["currentWorkoutIndex"] == 0

    gql("mutation($p: Int!) { setActivePlan(planId: $p) { ok } }", p=plan_b)
    assert active_plan()["currentWorkoutIndex"] == 1


def test_cannot_switch_plans_mid_workout():
    plan_a = seed_plan("A")
    seed_plan("B")
    start_workout()
    result = gql("mutation($p: Int!) { setActivePlan(planId: $p) { ok message } }", p=plan_a)["setActivePlan"]
    assert result["ok"] is False
    assert "in-progress" in result["message"]


# ---------------------------------------------------------------- cancel / undo


def test_cancel_workout_does_not_advance_plan_or_progress():
    seed_plan()
    session = start_workout()
    complete_all_sets(session)
    result = gql("mutation($id: Int!) { cancelWorkout(sessionId: $id) { ok } }", id=session["id"])
    assert result["cancelWorkout"]["ok"] is True

    assert gql("{ activeWorkoutSession { id } }")["activeWorkoutSession"] is None
    assert active_plan()["currentWorkoutIndex"] == 0
    assert gql("{ workoutHistory { sessionId } }")["workoutHistory"] == []

    # Next start gets the same day at the same weight.
    again = start_workout()
    assert again["planWorkoutId"] == session["planWorkoutId"]
    assert again["entries"][0]["plannedWeightKg"] == session["entries"][0]["plannedWeightKg"]


def test_uncomplete_set_and_sets_locked_after_finish():
    seed_plan()
    session = start_workout()
    set_id = session["entries"][0]["sets"][0]["id"]
    gql("mutation($id: Int!) { completeSet(sessionSetId: $id, repsCompleted: 3) { id } }", id=set_id)

    undone = gql(
        "mutation($id: Int!) { uncompleteSet(sessionSetId: $id) { completed repsCompleted } }", id=set_id
    )["uncompleteSet"]
    assert undone == {"completed": False, "repsCompleted": None}

    finish(session["id"])
    message = gql_error("mutation($id: Int!) { uncompleteSet(sessionSetId: $id) { id } }", id=set_id)
    assert "in progress" in message


# ---------------------------------------------------------------- personal records


def _do_day_a(weight_kg: float, reps: int = 3) -> dict:
    """Run day A (squat) at a given weight, then skip day B so the next start is day A again."""
    session = start_workout()
    assert session["planWorkoutName"] == "A"
    complete_all_sets(session, weight_kg=weight_kg, reps=reps)
    finished = finish(session["id"])
    day_b = start_workout()
    complete_all_sets(day_b)
    finish(day_b["id"])
    return finished


def test_personal_records_detected_against_history():
    seed_plan()
    first = _do_day_a(80)
    assert first["personalRecords"] == []  # first time doing the lift: nothing to beat

    same = _do_day_a(80)
    assert same["personalRecords"] == []

    heavier = _do_day_a(90)
    kinds = {pr["kind"]: pr for pr in heavier["personalRecords"]}
    assert set(kinds) == {"WEIGHT", "ESTIMATED_1RM"}
    assert kinds["WEIGHT"]["valueKg"] == 90
    assert kinds["WEIGHT"]["previousKg"] == 80
    assert kinds["WEIGHT"]["exerciseName"] == "Squat"

    history = gql("{ workoutHistory(limit: 50) { sessionId personalRecords { kind } } }")["workoutHistory"]
    by_id = {h["sessionId"]: h for h in history}
    assert len(by_id[heavier["id"]]["personalRecords"]) == 2
    assert by_id[first["id"]]["personalRecords"] == []


# ---------------------------------------------------------------- offline support


PRESCRIPTION = """
{ workoutPrescription {
    planId planWorkoutId workoutName week blockedReason
    entries { planWorkoutExerciseId exerciseName plannedWeightKg plannedSets plannedReps
              sets { setIndex targetReps isAmrap weightKg } }
} }
"""


def test_prescription_is_read_only_and_matches_start():
    seed_plan()
    rx = gql(PRESCRIPTION)["workoutPrescription"]
    assert rx["workoutName"] == "A"
    assert rx["blockedReason"] is None
    assert len(rx["entries"][0]["sets"]) == 5  # GZCLP T1 5x3
    assert rx["entries"][0]["sets"][-1]["isAmrap"] is True

    assert gql("{ activeWorkoutSession { id } }")["activeWorkoutSession"] is None

    session = start_workout()
    assert session["entries"][0]["plannedWeightKg"] == rx["entries"][0]["plannedWeightKg"]


LOG = f"""
mutation Log($input: LogWorkoutInput!) {{ logWorkout(input: $input) {{ {SESSION_FIELDS} heartRateSampleCount }} }}
"""


def _log_input_from_prescription(rx: dict, client_id: str, session_id: int | None = None) -> dict:
    started = datetime(2026, 1, 5, 18, 0, tzinfo=timezone.utc)
    return {
        "clientId": client_id,
        "sessionId": session_id,
        "planWorkoutId": rx["planWorkoutId"],
        "startedAt": started.isoformat(),
        "finishedAt": (started + timedelta(minutes=45)).isoformat(),
        "entries": [
            {
                "planWorkoutExerciseId": e["planWorkoutExerciseId"],
                "plannedSets": e["plannedSets"],
                "plannedReps": e["plannedReps"],
                "plannedWeightKg": e["plannedWeightKg"],
                "sets": [
                    {
                        "setIndex": s["setIndex"],
                        "targetReps": s["targetReps"],
                        "isAmrap": s["isAmrap"],
                        "repsCompleted": s["targetReps"],
                        "weightKg": s["weightKg"],
                        "durationSeconds": 120,
                        "completed": True,
                        "completedAt": (started + timedelta(minutes=5 * s["setIndex"])).isoformat(),
                    }
                    for s in e["sets"]
                ],
            }
            for e in rx["entries"]
        ],
        "heartRateSamples": [
            {"recordedAt": (started + timedelta(seconds=i)).isoformat(), "bpm": 100 + i, "source": "TEST"}
            for i in range(10)
        ],
    }


def test_log_workout_records_progresses_and_is_idempotent():
    seed_plan()
    rx = gql(PRESCRIPTION)["workoutPrescription"]
    payload = _log_input_from_prescription(rx, "client-1")

    logged = gql(LOG, input=payload)["logWorkout"]
    assert logged["status"] == "COMPLETED"
    assert logged["heartRateSampleCount"] == 10
    assert all(s["completed"] for s in logged["entries"][0]["sets"])
    assert active_plan()["currentWorkoutIndex"] == 1

    # A retried upload (e.g. response lost on a bad connection) must not double-log.
    again = gql(LOG, input=payload)["logWorkout"]
    assert again["id"] == logged["id"]
    assert active_plan()["currentWorkoutIndex"] == 1
    assert len(gql("{ workoutHistory { sessionId } }")["workoutHistory"]) == 1

    # Progression ran: next time day A comes round, squat is heavier.
    next_rx = gql(PRESCRIPTION)["workoutPrescription"]
    assert next_rx["workoutName"] == "B"


def test_log_workout_can_finish_a_server_started_session():
    seed_plan()
    server_session = start_workout()
    rx = gql(PRESCRIPTION)["workoutPrescription"]
    payload = _log_input_from_prescription(rx, "client-2", session_id=server_session["id"])

    logged = gql(LOG, input=payload)["logWorkout"]
    assert logged["id"] == server_session["id"]
    assert logged["status"] == "COMPLETED"
    assert gql("{ activeWorkoutSession { id } }")["activeWorkoutSession"] is None


def test_log_workout_rejects_foreign_exercises():
    seed_plan()
    rx = gql(PRESCRIPTION)["workoutPrescription"]
    payload = _log_input_from_prescription(rx, "client-3")
    payload["entries"][0]["planWorkoutExerciseId"] = 99999
    assert "not part of this workout" in gql_error(LOG, input=payload)


def test_heart_rate_uploads_are_deduplicated():
    seed_plan()
    session = start_workout()
    samples = [{"recordedAt": "2026-01-05T18:00:00Z", "bpm": 120}, {"recordedAt": "2026-01-05T18:00:01Z", "bpm": 121}]
    q = "mutation($id: Int!, $s: [HeartRateSampleInput!]!) { appendHeartRateSamples(sessionId: $id, samples: $s) { insertedCount } }"
    assert gql(q, id=session["id"], s=samples)["appendHeartRateSamples"]["insertedCount"] == 2
    assert gql(q, id=session["id"], s=samples)["appendHeartRateSamples"]["insertedCount"] == 0
