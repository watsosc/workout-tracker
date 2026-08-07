from __future__ import annotations

import enum
from datetime import datetime

from sqlalchemy import (
    JSON,
    Boolean,
    DateTime,
    Enum,
    Float,
    ForeignKey,
    Integer,
    String,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from .db import Base


class ProgressionType(str, enum.Enum):
    NONE = "NONE"
    LINEAR_KG = "LINEAR_KG"
    PERCENT_1RM = "PERCENT_1RM"


class ProgressionProtocol(str, enum.Enum):
    BASIC = "BASIC"
    GZCLP_T1 = "GZCLP_T1"
    GZCLP_T2 = "GZCLP_T2"
    GZCLP_T3 = "GZCLP_T3"


class ExerciseTier(str, enum.Enum):
    T1 = "T1"
    T2 = "T2"
    T3 = "T3"


class WorkoutSessionStatus(str, enum.Enum):
    IN_PROGRESS = "IN_PROGRESS"
    COMPLETED = "COMPLETED"
    CANCELLED = "CANCELLED"


class PlanRunStatus(str, enum.Enum):
    ACTIVE = "ACTIVE"
    COMPLETED = "COMPLETED"


class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    name: Mapped[str] = mapped_column(String(120), unique=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)


class Exercise(Base):
    __tablename__ = "exercises"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    name: Mapped[str] = mapped_column(String(120), unique=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)


class ExerciseBaseline(Base):
    __tablename__ = "exercise_baselines"
    __table_args__ = (UniqueConstraint("user_id", "exercise_id", name="uq_user_exercise_baseline"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    exercise_id: Mapped[int] = mapped_column(ForeignKey("exercises.id"), index=True)
    baseline_1rm_kg: Mapped[float] = mapped_column(Float)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


class Plan(Base):
    __tablename__ = "plans"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    name: Mapped[str] = mapped_column(String(160))
    total_weeks: Mapped[int | None] = mapped_column(Integer, nullable=True)
    is_active: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)


class PlanWorkout(Base):
    __tablename__ = "plan_workouts"
    __table_args__ = (UniqueConstraint("plan_id", "sequence_index", name="uq_plan_workout_sequence"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    plan_id: Mapped[int] = mapped_column(ForeignKey("plans.id"), index=True)
    name: Mapped[str] = mapped_column(String(120))
    sequence_index: Mapped[int] = mapped_column(Integer)


class PlanWorkoutExercise(Base):
    __tablename__ = "plan_workout_exercises"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    plan_workout_id: Mapped[int] = mapped_column(ForeignKey("plan_workouts.id"), index=True)
    exercise_id: Mapped[int] = mapped_column(ForeignKey("exercises.id"), index=True)
    sets: Mapped[int] = mapped_column(Integer)
    reps: Mapped[int] = mapped_column(Integer)
    target_weight_kg: Mapped[float] = mapped_column(Float)
    progression_type: Mapped[ProgressionType] = mapped_column(
        Enum(ProgressionType), default=ProgressionType.NONE
    )
    progression_protocol: Mapped[ProgressionProtocol] = mapped_column(
        Enum(ProgressionProtocol), default=ProgressionProtocol.BASIC
    )
    tier: Mapped[ExerciseTier | None] = mapped_column(Enum(ExerciseTier), nullable=True)
    progression_value: Mapped[float] = mapped_column(Float, default=0.0)
    training_max_ratio: Mapped[float] = mapped_column(Float, default=1.0)
    amrap_last_set: Mapped[bool] = mapped_column(Boolean, default=False)
    progression_meta: Mapped[dict | None] = mapped_column(JSON, nullable=True)

    exercise: Mapped[Exercise] = relationship()


class PlanRun(Base):
    __tablename__ = "plan_runs"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    plan_id: Mapped[int] = mapped_column(ForeignKey("plans.id"), index=True)
    current_week: Mapped[int] = mapped_column(Integer, default=1)
    current_workout_index: Mapped[int] = mapped_column(Integer, default=0)
    status: Mapped[PlanRunStatus] = mapped_column(Enum(PlanRunStatus), default=PlanRunStatus.ACTIVE)
    started_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)


class PlanRunBaseline(Base):
    __tablename__ = "plan_run_baselines"
    __table_args__ = (UniqueConstraint("plan_run_id", "exercise_id", name="uq_plan_run_baseline"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    plan_run_id: Mapped[int] = mapped_column(ForeignKey("plan_runs.id"), index=True)
    exercise_id: Mapped[int] = mapped_column(ForeignKey("exercises.id"), index=True)
    baseline_1rm_kg: Mapped[float] = mapped_column(Float)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


class RunExerciseState(Base):
    __tablename__ = "run_exercise_states"
    __table_args__ = (
        UniqueConstraint("plan_run_id", "exercise_id", "tier", name="uq_run_exercise_state"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    plan_run_id: Mapped[int] = mapped_column(ForeignKey("plan_runs.id"), index=True)
    exercise_id: Mapped[int] = mapped_column(ForeignKey("exercises.id"), index=True)
    tier: Mapped[ExerciseTier | None] = mapped_column(Enum(ExerciseTier), nullable=True)
    current_weight_kg: Mapped[float] = mapped_column(Float)
    failure_count: Mapped[int] = mapped_column(Integer, default=0)
    needs_new_1rm: Mapped[bool] = mapped_column(Boolean, default=False)
    last_completed_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)


class WorkoutSession(Base):
    __tablename__ = "workout_sessions"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    plan_run_id: Mapped[int] = mapped_column(ForeignKey("plan_runs.id"), index=True)
    plan_workout_id: Mapped[int] = mapped_column(ForeignKey("plan_workouts.id"), index=True)
    status: Mapped[WorkoutSessionStatus] = mapped_column(
        Enum(WorkoutSessionStatus), default=WorkoutSessionStatus.IN_PROGRESS
    )
    started_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    finished_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    notes: Mapped[str | None] = mapped_column(String, nullable=True)


class SessionExerciseEntry(Base):
    __tablename__ = "session_exercise_entries"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    session_id: Mapped[int] = mapped_column(ForeignKey("workout_sessions.id"), index=True)
    plan_workout_exercise_id: Mapped[int] = mapped_column(
        ForeignKey("plan_workout_exercises.id"), index=True
    )
    exercise_id: Mapped[int] = mapped_column(ForeignKey("exercises.id"), index=True)
    planned_sets: Mapped[int] = mapped_column(Integer)
    planned_reps: Mapped[int] = mapped_column(Integer)
    planned_weight_kg: Mapped[float] = mapped_column(Float)

    exercise: Mapped[Exercise] = relationship()


class SessionSet(Base):
    __tablename__ = "session_sets"
    __table_args__ = (UniqueConstraint("entry_id", "set_index", name="uq_entry_set_index"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    entry_id: Mapped[int] = mapped_column(ForeignKey("session_exercise_entries.id"), index=True)
    set_index: Mapped[int] = mapped_column(Integer)
    target_reps: Mapped[int | None] = mapped_column(Integer, nullable=True)
    is_amrap: Mapped[bool] = mapped_column(Boolean, default=False)
    reps_completed: Mapped[int | None] = mapped_column(Integer, nullable=True)
    weight_kg: Mapped[float | None] = mapped_column(Float, nullable=True)
    completed: Mapped[bool] = mapped_column(Boolean, default=False)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)


class ResetEvent(Base):
    __tablename__ = "reset_events"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    plan_run_id: Mapped[int] = mapped_column(ForeignKey("plan_runs.id"), index=True)
    training_max_ratio: Mapped[float] = mapped_column(Float)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
