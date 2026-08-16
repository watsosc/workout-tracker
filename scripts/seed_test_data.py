#!/usr/bin/env python3
from __future__ import annotations

import math
import sys
from datetime import datetime, timedelta
from pathlib import Path

from sqlalchemy import and_, delete, select

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))

from app.db import Base, apply_sqlite_migrations, db_session, engine  # noqa: E402
from app.models import (  # noqa: E402
    Exercise,
    ExerciseBaseline,
    HeartRateSample,
    Plan,
    PlanRun,
    PlanRunBaseline,
    PlanRunStatus,
    PlanWorkout,
    PlanWorkoutExercise,
    ProgressionProtocol,
    ProgressionType,
    RunExerciseState,
    SessionExerciseEntry,
    SessionSet,
    User,
    WorkoutSession,
    WorkoutSessionStatus,
)

DEFAULT_USER_ID = 1
SEED_NOTE_PREFIX = "seed-demo"


def _ensure_user(session) -> User:
    user = session.get(User, DEFAULT_USER_ID)
    if user:
        return user
    user = User(id=DEFAULT_USER_ID, name="default")
    session.add(user)
    session.flush()
    return user


def _ensure_exercise(session, name: str, baseline_1rm_kg: float) -> Exercise:
    row = session.scalar(select(Exercise).where(Exercise.name == name))
    if not row:
        row = Exercise(name=name)
        session.add(row)
        session.flush()

    baseline = session.scalar(
        select(ExerciseBaseline).where(
            and_(
                ExerciseBaseline.user_id == DEFAULT_USER_ID,
                ExerciseBaseline.exercise_id == row.id,
            )
        )
    )
    if not baseline:
        baseline = ExerciseBaseline(
            user_id=DEFAULT_USER_ID,
            exercise_id=row.id,
            baseline_1rm_kg=baseline_1rm_kg,
        )
        session.add(baseline)
    else:
        baseline.baseline_1rm_kg = baseline_1rm_kg

    return row


def _ensure_demo_plan(session, user_id: int) -> tuple[Plan, PlanRun, PlanWorkout, list[PlanWorkoutExercise]]:
    plan = session.scalar(
        select(Plan).where(and_(Plan.user_id == user_id, Plan.name == "Demo iOS Plan"))
    )
    if not plan:
        plan = Plan(user_id=user_id, name="Demo iOS Plan", total_weeks=12, is_active=True)
        session.add(plan)
        session.flush()

    # Make demo plan active for deterministic local testing.
    for other in session.scalars(select(Plan).where(Plan.user_id == user_id)).all():
        other.is_active = other.id == plan.id

    day_a = session.scalar(
        select(PlanWorkout).where(and_(PlanWorkout.plan_id == plan.id, PlanWorkout.sequence_index == 0))
    )
    if not day_a:
        day_a = PlanWorkout(plan_id=plan.id, name="Day A", sequence_index=0)
        session.add(day_a)
        session.flush()

    day_b = session.scalar(
        select(PlanWorkout).where(and_(PlanWorkout.plan_id == plan.id, PlanWorkout.sequence_index == 1))
    )
    if not day_b:
        day_b = PlanWorkout(plan_id=plan.id, name="Day B", sequence_index=1)
        session.add(day_b)
        session.flush()

    bench = _ensure_exercise(session, "Barbell Bench Press", baseline_1rm_kg=110)
    squat = _ensure_exercise(session, "Back Squat", baseline_1rm_kg=145)
    row = _ensure_exercise(session, "Barbell Row", baseline_1rm_kg=100)

    specs = [
        (day_a.id, bench.id, 3, 5, 85.0, ProgressionProtocol.GZCLP_T1),
        (day_a.id, row.id, 3, 8, 62.5, ProgressionProtocol.GZCLP_T2),
        (day_b.id, squat.id, 3, 5, 105.0, ProgressionProtocol.GZCLP_T1),
    ]

    pwe_rows: list[PlanWorkoutExercise] = []
    for workout_id, exercise_id, sets, reps, weight, protocol in specs:
        pwe = session.scalar(
            select(PlanWorkoutExercise).where(
                and_(
                    PlanWorkoutExercise.plan_workout_id == workout_id,
                    PlanWorkoutExercise.exercise_id == exercise_id,
                )
            )
        )
        if not pwe:
            pwe = PlanWorkoutExercise(
                plan_workout_id=workout_id,
                exercise_id=exercise_id,
                sets=sets,
                reps=reps,
                target_weight_kg=weight,
                progression_type=ProgressionType.LINEAR_KG,
                progression_protocol=protocol,
                progression_value=2.5,
                training_max_ratio=1.0,
                amrap_last_set=False,
            )
            session.add(pwe)
            session.flush()
        else:
            pwe.sets = sets
            pwe.reps = reps
            pwe.target_weight_kg = weight
            pwe.progression_protocol = protocol
        pwe_rows.append(pwe)

    run = session.scalar(
        select(PlanRun).where(and_(PlanRun.user_id == user_id, PlanRun.plan_id == plan.id, PlanRun.status == PlanRunStatus.ACTIVE))
    )
    if not run:
        run = PlanRun(
            user_id=user_id,
            plan_id=plan.id,
            current_week=1,
            current_workout_index=0,
            status=PlanRunStatus.ACTIVE,
        )
        session.add(run)
        session.flush()
    else:
        run.current_workout_index = 0
        run.current_week = 1

    # Baseline + run state rows
    for pwe in pwe_rows:
        baseline_val = pwe.target_weight_kg * 1.2
        run_base = session.scalar(
            select(PlanRunBaseline).where(
                and_(PlanRunBaseline.plan_run_id == run.id, PlanRunBaseline.exercise_id == pwe.exercise_id)
            )
        )
        if not run_base:
            session.add(
                PlanRunBaseline(
                    plan_run_id=run.id,
                    exercise_id=pwe.exercise_id,
                    baseline_1rm_kg=baseline_val,
                )
            )

        run_state = session.scalar(
            select(RunExerciseState).where(
                and_(
                    RunExerciseState.plan_run_id == run.id,
                    RunExerciseState.exercise_id == pwe.exercise_id,
                    RunExerciseState.tier.is_(None),
                )
            )
        )
        if not run_state:
            session.add(
                RunExerciseState(
                    plan_run_id=run.id,
                    exercise_id=pwe.exercise_id,
                    tier=None,
                    current_weight_kg=pwe.target_weight_kg,
                    failure_count=0,
                    needs_new_1rm=False,
                )
            )

    return plan, run, day_a, [p for p in pwe_rows if p.plan_workout_id == day_a.id]


def _generate_hr(start_at: datetime, points: int, step_seconds: int, source: str) -> list[HeartRateSample]:
    out: list[HeartRateSample] = []
    for i in range(points):
        bpm = int(round(107.5 + 27.5 * math.sin(i * 0.33)))
        bpm = max(80, min(135, bpm))
        out.append(
            HeartRateSample(
                recorded_at=start_at + timedelta(seconds=i * step_seconds),
                bpm=bpm,
                source=source,
            )
        )
    return out


def _delete_seeded_sessions(session) -> None:
    ids = [
        sid
        for sid in session.scalars(
            select(WorkoutSession.id).where(WorkoutSession.notes.like(f"{SEED_NOTE_PREFIX}%"))
        ).all()
    ]
    if not ids:
        return

    entry_ids = [
        eid
        for eid in session.scalars(
            select(SessionExerciseEntry.id).where(SessionExerciseEntry.session_id.in_(ids))
        ).all()
    ]
    if entry_ids:
        session.execute(delete(SessionSet).where(SessionSet.entry_id.in_(entry_ids)))
        session.execute(delete(SessionExerciseEntry).where(SessionExerciseEntry.id.in_(entry_ids)))
    session.execute(delete(HeartRateSample).where(HeartRateSample.session_id.in_(ids)))
    session.execute(delete(WorkoutSession).where(WorkoutSession.id.in_(ids)))


def seed() -> None:
    Base.metadata.create_all(bind=engine)
    apply_sqlite_migrations()

    with db_session() as session:
        user = _ensure_user(session)
        plan, run, day_a, day_a_exercises = _ensure_demo_plan(session, user.id)

        _delete_seeded_sessions(session)

        now = datetime.utcnow()

        # Completed session for history/testing
        completed = WorkoutSession(
            user_id=user.id,
            plan_run_id=run.id,
            plan_workout_id=day_a.id,
            status=WorkoutSessionStatus.COMPLETED,
            started_at=now - timedelta(hours=6),
            finished_at=now - timedelta(hours=5, minutes=35),
            notes=f"{SEED_NOTE_PREFIX}:completed",
        )
        session.add(completed)
        session.flush()

        for pwe in day_a_exercises:
            entry = SessionExerciseEntry(
                session_id=completed.id,
                plan_workout_exercise_id=pwe.id,
                exercise_id=pwe.exercise_id,
                planned_sets=pwe.sets,
                planned_reps=pwe.reps,
                planned_weight_kg=pwe.target_weight_kg,
            )
            session.add(entry)
            session.flush()
            for set_idx in range(pwe.sets):
                session.add(
                    SessionSet(
                        entry_id=entry.id,
                        set_index=set_idx,
                        target_reps=pwe.reps,
                        is_amrap=False,
                        reps_completed=pwe.reps,
                        weight_kg=pwe.target_weight_kg,
                        duration_seconds=45 + (set_idx * 4),
                        completed=True,
                        completed_at=(now - timedelta(hours=5, minutes=58 - set_idx * 8)),
                    )
                )

        for sample in _generate_hr(now - timedelta(hours=6), points=140, step_seconds=10, source="SEED_COMPLETED"):
            sample.session_id = completed.id
            session.add(sample)

        # In-progress session for workout screen/testing
        active = WorkoutSession(
            user_id=user.id,
            plan_run_id=run.id,
            plan_workout_id=day_a.id,
            status=WorkoutSessionStatus.IN_PROGRESS,
            started_at=now - timedelta(minutes=18),
            notes=f"{SEED_NOTE_PREFIX}:active",
        )
        session.add(active)
        session.flush()

        for pwe in day_a_exercises:
            entry = SessionExerciseEntry(
                session_id=active.id,
                plan_workout_exercise_id=pwe.id,
                exercise_id=pwe.exercise_id,
                planned_sets=pwe.sets,
                planned_reps=pwe.reps,
                planned_weight_kg=pwe.target_weight_kg,
            )
            session.add(entry)
            session.flush()
            for set_idx in range(pwe.sets):
                completed_flag = pwe.exercise_id == day_a_exercises[0].exercise_id and set_idx == 0
                session.add(
                    SessionSet(
                        entry_id=entry.id,
                        set_index=set_idx,
                        target_reps=pwe.reps,
                        is_amrap=False,
                        reps_completed=pwe.reps if completed_flag else None,
                        weight_kg=pwe.target_weight_kg if completed_flag else None,
                        duration_seconds=40 if completed_flag else None,
                        completed=completed_flag,
                        completed_at=(now - timedelta(minutes=16)) if completed_flag else None,
                    )
                )

        for sample in _generate_hr(now - timedelta(minutes=4), points=240, step_seconds=1, source="SEED_ACTIVE"):
            sample.session_id = active.id
            session.add(sample)

        session.commit()

        print("Seeded demo data:")
        print(f"- Plan: {plan.name} (id={plan.id})")
        print(f"- Active run: id={run.id}")
        print(f"- Completed session: id={completed.id}")
        print(f"- Active in-progress session: id={active.id}")
        print("- Heart-rate samples: looping 80-135 bpm pattern generated")


if __name__ == "__main__":
    seed()
