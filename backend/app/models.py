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


class ExerciseCatalogSource(str, enum.Enum):
    WGER = "WGER"
    MANUAL = "MANUAL"


class EquipmentType(str, enum.Enum):
    BARBELL = "BARBELL"
    DUMBBELL = "DUMBBELL"
    MACHINE = "MACHINE"
    CABLE = "CABLE"
    BODYWEIGHT = "BODYWEIGHT"
    KETTLEBELL = "KETTLEBELL"
    BAND = "BAND"
    OTHER = "OTHER"


class ExerciseAliasKind(str, enum.Enum):
    SOURCE_NAME = "SOURCE_NAME"
    SHORT_NAME = "SHORT_NAME"
    ABBREVIATION = "ABBREVIATION"
    USER_ADDED = "USER_ADDED"


class OAuthProvider(str, enum.Enum):
    STRAVA = "STRAVA"


class WorkoutExportStatus(str, enum.Enum):
    PENDING = "PENDING"
    SENT = "SENT"
    FAILED = "FAILED"


class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    name: Mapped[str] = mapped_column(String(120), unique=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)


class OAuthConnection(Base):
    __tablename__ = "oauth_connections"
    __table_args__ = (UniqueConstraint("user_id", "provider", name="uq_user_oauth_provider"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    provider: Mapped[OAuthProvider] = mapped_column(Enum(OAuthProvider), index=True)
    provider_user_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    provider_username: Mapped[str | None] = mapped_column(String(120), nullable=True)
    access_token: Mapped[str] = mapped_column(String(512))
    refresh_token: Mapped[str] = mapped_column(String(512))
    token_type: Mapped[str | None] = mapped_column(String(40), nullable=True)
    scope: Mapped[str | None] = mapped_column(String(500), nullable=True)
    expires_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


class OAuthState(Base):
    __tablename__ = "oauth_states"
    __table_args__ = (UniqueConstraint("provider", "state", name="uq_provider_oauth_state"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    provider: Mapped[OAuthProvider] = mapped_column(Enum(OAuthProvider), index=True)
    state: Mapped[str] = mapped_column(String(120), index=True)
    expires_at: Mapped[datetime] = mapped_column(DateTime)
    consumed_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)


class ExerciseCatalogItem(Base):
    __tablename__ = "exercise_catalog_items"
    __table_args__ = (
        UniqueConstraint("source", "source_exercise_id", name="uq_exercise_catalog_source_item"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    source: Mapped[ExerciseCatalogSource] = mapped_column(
        Enum(ExerciseCatalogSource), default=ExerciseCatalogSource.WGER, index=True
    )
    source_exercise_id: Mapped[str] = mapped_column(String(64), index=True)
    canonical_name: Mapped[str] = mapped_column(String(200))
    name_normalized: Mapped[str] = mapped_column(String(220), index=True)
    equipment_type: Mapped[EquipmentType] = mapped_column(Enum(EquipmentType), default=EquipmentType.OTHER)
    movement_category: Mapped[str | None] = mapped_column(String(80), nullable=True)
    primary_muscle: Mapped[str | None] = mapped_column(String(120), nullable=True)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)
    raw_payload_json: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    last_synced_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)


class ExerciseCatalogAlias(Base):
    __tablename__ = "exercise_catalog_aliases"
    __table_args__ = (
        UniqueConstraint("catalog_item_id", "alias_normalized", name="uq_catalog_alias_normalized"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    catalog_item_id: Mapped[int] = mapped_column(ForeignKey("exercise_catalog_items.id"), index=True)
    alias: Mapped[str] = mapped_column(String(200))
    alias_normalized: Mapped[str] = mapped_column(String(220), index=True)
    alias_kind: Mapped[ExerciseAliasKind] = mapped_column(
        Enum(ExerciseAliasKind), default=ExerciseAliasKind.SOURCE_NAME
    )
    is_active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


class Exercise(Base):
    __tablename__ = "exercises"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    name: Mapped[str] = mapped_column(String(120), unique=True)
    catalog_item_id: Mapped[int | None] = mapped_column(
        ForeignKey("exercise_catalog_items.id"), nullable=True, index=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)

    catalog_item: Mapped[ExerciseCatalogItem | None] = relationship()


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
    duration_seconds: Mapped[int | None] = mapped_column(Integer, nullable=True)
    completed: Mapped[bool] = mapped_column(Boolean, default=False)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)


class WorkoutExport(Base):
    __tablename__ = "workout_exports"
    __table_args__ = (UniqueConstraint("provider", "session_id", name="uq_workout_export_provider_session"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    session_id: Mapped[int] = mapped_column(ForeignKey("workout_sessions.id"), index=True)
    provider: Mapped[OAuthProvider] = mapped_column(Enum(OAuthProvider), index=True)
    status: Mapped[WorkoutExportStatus] = mapped_column(
        Enum(WorkoutExportStatus), default=WorkoutExportStatus.PENDING
    )
    remote_activity_id: Mapped[str | None] = mapped_column(String(64), nullable=True)
    remote_activity_url: Mapped[str | None] = mapped_column(String(220), nullable=True)
    payload_json: Mapped[dict | None] = mapped_column(JSON, nullable=True)
    last_error: Mapped[str | None] = mapped_column(String(800), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


class ResetEvent(Base):
    __tablename__ = "reset_events"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), index=True)
    plan_run_id: Mapped[int] = mapped_column(ForeignKey("plan_runs.id"), index=True)
    training_max_ratio: Mapped[float] = mapped_column(Float)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
