from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import enum
import re
import secrets

import strawberry
from sqlalchemy import and_, delete, func, or_, select, update

from .config import DEFAULT_USER_NAME
from .db import db_session
from .models import (
    Exercise,
    ExerciseBaseline,
    ExerciseCatalogAlias,
    ExerciseCatalogItem,
    ExerciseCatalogSource,
    ExerciseTier,
    HeartRateSample,
    EquipmentType,
    OAuthConnection,
    OAuthProvider,
    OAuthState,
    Plan,
    PlanRun,
    PlanRunBaseline,
    PlanRunStatus,
    PlanWorkout,
    PlanWorkoutExercise,
    ProgressionProtocol,
    ProgressionType,
    ResetEvent,
    RunExerciseState,
    SessionExerciseEntry,
    SessionSet,
    User,
    UserPreference,
    WorkoutExport,
    WorkoutExportStatus,
    WorkoutSession,
    WorkoutSessionStatus,
)
from .progression import (
    DEFAULT_WEIGHT_INCREMENT_KG,
    evaluate_progression,
    exercise_prescription,
    initial_weight_for_template,
)
from .strava import (
    StravaError,
    build_authorize_url,
    create_activity,
    deauthorize,
    exchange_code_for_token,
    is_strava_configured,
    refresh_access_token,
)

DEFAULT_USER_ID = 1


@strawberry.enum
class GQLProgressionType(enum.Enum):
    NONE = "NONE"
    LINEAR_KG = "LINEAR_KG"
    PERCENT_1RM = "PERCENT_1RM"


@strawberry.enum
class GQLProgressionProtocol(enum.Enum):
    BASIC = "BASIC"
    GZCLP_T1 = "GZCLP_T1"
    GZCLP_T2 = "GZCLP_T2"
    GZCLP_T3 = "GZCLP_T3"


@strawberry.enum
class GQLExerciseTier(enum.Enum):
    T1 = "T1"
    T2 = "T2"
    T3 = "T3"


@strawberry.enum
class GQLWorkoutSessionStatus(enum.Enum):
    IN_PROGRESS = "IN_PROGRESS"
    COMPLETED = "COMPLETED"
    CANCELLED = "CANCELLED"


@strawberry.enum
class GQLExerciseCatalogSource(enum.Enum):
    WGER = "WGER"
    MANUAL = "MANUAL"


@strawberry.enum
class GQLEquipmentType(enum.Enum):
    BARBELL = "BARBELL"
    DUMBBELL = "DUMBBELL"
    MACHINE = "MACHINE"
    CABLE = "CABLE"
    BODYWEIGHT = "BODYWEIGHT"
    KETTLEBELL = "KETTLEBELL"
    BAND = "BAND"
    OTHER = "OTHER"


@strawberry.enum
class GQLWorkoutExportStatus(enum.Enum):
    PENDING = "PENDING"
    SENT = "SENT"
    FAILED = "FAILED"


@strawberry.type
class ExerciseType:
    id: int
    name: str


@strawberry.type
class ExerciseCatalogItemType:
    id: int
    source: GQLExerciseCatalogSource
    source_exercise_id: str
    canonical_name: str
    equipment_type: GQLEquipmentType
    movement_category: str | None
    primary_muscle: str | None


@strawberry.type
class ExerciseCatalogMatchType:
    catalog_item_id: int
    canonical_name: str
    equipment_type: GQLEquipmentType
    matched_alias: str
    source: GQLExerciseCatalogSource


@strawberry.type
class BaselineType:
    exercise_id: int
    exercise_name: str
    baseline_1rm_kg: float


@strawberry.type
class CurrentStatusType:
    plan_run_id: int
    plan_name: str
    week: int
    workout_index: int
    last_workout_at: datetime | None
    days_since_last_workout: int | None
    needs_new_1rm_exercises: list[str]


@strawberry.type
class DashboardType:
    status: CurrentStatusType | None
    baselines: list[BaselineType]
    reset_baselines: list[BaselineType]


@strawberry.type
class SessionSetType:
    id: int
    set_index: int
    target_reps: int | None
    is_amrap: bool
    reps_completed: int | None
    weight_kg: float | None
    duration_seconds: int | None
    completed: bool
    completed_at: datetime | None


@strawberry.type
class SessionExerciseEntryType:
    id: int
    exercise_id: int
    exercise_name: str
    planned_sets: int
    planned_reps: int
    planned_weight_kg: float
    progression_protocol: GQLProgressionProtocol
    tier: GQLExerciseTier | None
    expected_rest_seconds: int
    sets: list[SessionSetType]


@strawberry.type
class WorkoutSessionType:
    id: int
    status: GQLWorkoutSessionStatus
    started_at: datetime
    finished_at: datetime | None
    heart_rate_sample_count: int
    avg_heart_rate_bpm: int | None
    max_heart_rate_bpm: int | None
    entries: list[SessionExerciseEntryType]


@strawberry.type
class HeartRateSampleType:
    id: int
    session_id: int
    recorded_at: datetime
    bpm: int
    source: str | None


@strawberry.type
class WorkoutHistoryExerciseType:
    exercise_id: int
    exercise_name: str
    completed_sets: int
    total_reps: int
    top_weight_kg: float


@strawberry.type
class WorkoutHistoryItemType:
    session_id: int
    plan_run_id: int
    finished_at: datetime | None
    plan_workout_name: str
    workout_sequence_index: int | None
    total_sets: int
    completed_sets: int
    total_volume_kg: float
    total_duration_seconds: int | None
    total_set_duration_seconds: int
    heart_rate_sample_count: int
    avg_heart_rate_bpm: int | None
    max_heart_rate_bpm: int | None
    strava_export_status: GQLWorkoutExportStatus | None
    strava_activity_id: str | None
    strava_activity_url: str | None
    exercises: list[WorkoutHistoryExerciseType]


@strawberry.type
class ExerciseProgressPointType:
    date: datetime
    top_weight_kg: float
    estimated_1rm_kg: float


@strawberry.type
class PlanExerciseType:
    id: int
    exercise_id: int
    exercise_name: str
    sets: int
    reps: int
    target_weight_kg: float
    progression_type: GQLProgressionType
    progression_protocol: GQLProgressionProtocol
    tier: GQLExerciseTier | None
    progression_value: float
    training_max_ratio: float
    amrap_last_set: bool


@strawberry.type
class PlanWorkoutType:
    id: int
    name: str
    sequence_index: int
    exercises: list[PlanExerciseType]


@strawberry.type
class ActivePlanType:
    id: int
    name: str
    total_weeks: int | None
    days_per_week: int
    current_week: int
    current_workout_index: int
    workouts: list[PlanWorkoutType]


@strawberry.input
class SeedExerciseInput:
    name: str
    baseline_1rm_kg: float


@strawberry.input
class SeedPlanWorkoutExerciseInput:
    exercise_name: str
    sets: int = 3
    reps: int = 5
    target_weight_kg: float = 0.0
    progression_type: GQLProgressionType = GQLProgressionType.NONE
    progression_protocol: GQLProgressionProtocol = GQLProgressionProtocol.BASIC
    tier: GQLExerciseTier | None = None
    progression_value: float = 0.0
    training_max_ratio: float | None = None
    amrap_last_set: bool | None = None
    weight_increment_kg: float | None = None


@strawberry.input
class SeedPlanWorkoutInput:
    name: str
    sequence_index: int
    exercises: list[SeedPlanWorkoutExerciseInput]


@strawberry.input
class BaselineInput:
    exercise_id: int
    baseline_1rm_kg: float


@strawberry.input
class HeartRateSampleInput:
    recorded_at: datetime
    bpm: int
    source: str | None = None


@strawberry.input
class AddExerciseToActivePlanInput:
    workout_sequence_index: int
    exercise_name: str
    baseline_1rm_kg: float | None = None
    sets: int = 3
    reps: int = 10
    target_weight_kg: float = 0.0
    progression_type: GQLProgressionType = GQLProgressionType.LINEAR_KG
    progression_protocol: GQLProgressionProtocol = GQLProgressionProtocol.BASIC
    tier: GQLExerciseTier | None = None
    progression_value: float = 2.5
    training_max_ratio: float | None = None
    amrap_last_set: bool | None = None
    weight_increment_kg: float | None = None


@strawberry.type
class MutationResult:
    ok: bool
    message: str


@strawberry.type
class HeartRateIngestResult:
    ok: bool
    message: str
    inserted_count: int


@strawberry.type
class SeedResult:
    ok: bool
    plan_id: int
    plan_run_id: int


@strawberry.type
class ResetResult:
    ok: bool
    message: str
    updated_exercise_count: int


@strawberry.type
class StravaConnectionType:
    configured: bool
    connected: bool
    athlete_id: str | None
    athlete_username: str | None
    scope: str | None
    expires_at: datetime | None
    auto_send_on_finish: bool


@strawberry.type
class StravaAuthStartType:
    ok: bool
    auth_url: str
    message: str


@strawberry.type
class StravaSendResult:
    ok: bool
    message: str
    activity_id: str | None
    activity_url: str | None


@dataclass
class ActivePlanContext:
    plan: Plan
    run: PlanRun


def _now_utc() -> datetime:
    return datetime.utcnow()


def _map_status(status: WorkoutSessionStatus) -> GQLWorkoutSessionStatus:
    return GQLWorkoutSessionStatus(status.value)


def _protocol_default_ratio(protocol: ProgressionProtocol) -> float:
    if protocol == ProgressionProtocol.GZCLP_T1:
        return 0.85
    if protocol == ProgressionProtocol.GZCLP_T2:
        return 0.65
    return 1.0


def _protocol_default_amrap(protocol: ProgressionProtocol) -> bool:
    return protocol in (ProgressionProtocol.GZCLP_T1, ProgressionProtocol.GZCLP_T3)


def _protocol_default_tier(protocol: ProgressionProtocol) -> ExerciseTier | None:
    if protocol == ProgressionProtocol.GZCLP_T1:
        return ExerciseTier.T1
    if protocol == ProgressionProtocol.GZCLP_T2:
        return ExerciseTier.T2
    if protocol == ProgressionProtocol.GZCLP_T3:
        return ExerciseTier.T3
    return None


def _expected_rest_seconds(tier: ExerciseTier | None) -> int:
    return 180 if tier == ExerciseTier.T1 else 90


def _map_export_status(status: WorkoutExportStatus) -> GQLWorkoutExportStatus:
    return GQLWorkoutExportStatus(status.value)


def _format_elapsed(seconds: int) -> str:
    mins = max(0, seconds) // 60
    secs = max(0, seconds) % 60
    return f"{mins}:{secs:02d}"


def _ensure_utc(dt: datetime) -> datetime:
    if dt.tzinfo is None:
        return dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def _to_utc_naive(dt: datetime) -> datetime:
    if dt.tzinfo is None:
        return dt
    return dt.astimezone(timezone.utc).replace(tzinfo=None)


def _session_heart_rate_stats(session, workout_session_id: int) -> tuple[int, int | None, int | None]:
    sample_count = int(
        session.scalar(
            select(func.count(HeartRateSample.id)).where(HeartRateSample.session_id == workout_session_id)
        )
        or 0
    )
    if sample_count == 0:
        return 0, None, None

    avg_bpm, max_bpm = session.execute(
        select(
            func.avg(HeartRateSample.bpm),
            func.max(HeartRateSample.bpm),
        ).where(HeartRateSample.session_id == workout_session_id)
    ).one()

    avg_value = int(round(float(avg_bpm))) if avg_bpm is not None else None
    max_value = int(max_bpm) if max_bpm is not None else None
    return sample_count, avg_value, max_value


def _strava_activity_url(activity_id: str) -> str:
    return f"https://www.strava.com/activities/{activity_id}"


def _get_or_create_user_preference(session, user_id: int) -> UserPreference:
    pref = session.scalar(select(UserPreference).where(UserPreference.user_id == user_id))
    if pref:
        return pref

    pref = UserPreference(user_id=user_id, strava_auto_send_on_finish=False)
    session.add(pref)
    session.flush()
    return pref


def _get_oauth_connection(
    session,
    user_id: int,
    provider: OAuthProvider = OAuthProvider.STRAVA,
) -> OAuthConnection | None:
    return session.scalar(
        select(OAuthConnection).where(
            and_(
                OAuthConnection.user_id == user_id,
                OAuthConnection.provider == provider,
            )
        )
    )


def _upsert_oauth_connection_from_token_payload(
    session,
    user_id: int,
    provider: OAuthProvider,
    payload: dict,
) -> OAuthConnection:
    access_token = str(payload.get("access_token") or "").strip()
    refresh_token_value = str(payload.get("refresh_token") or "").strip()
    if not access_token or not refresh_token_value:
        raise ValueError("Strava token response missing access_token or refresh_token")

    athlete = payload.get("athlete") or {}
    athlete_id = athlete.get("id")
    athlete_username = athlete.get("username")
    expires_at_raw = payload.get("expires_at")
    expires_at: datetime | None = None
    if expires_at_raw is not None:
        try:
            expires_at = datetime.utcfromtimestamp(int(expires_at_raw))
        except Exception:
            expires_at = None

    connection = _get_oauth_connection(session, user_id, provider)
    if not connection:
        connection = OAuthConnection(
            user_id=user_id,
            provider=provider,
            access_token=access_token,
            refresh_token=refresh_token_value,
        )
        session.add(connection)

    connection.access_token = access_token
    connection.refresh_token = refresh_token_value
    connection.provider_user_id = str(athlete_id) if athlete_id is not None else connection.provider_user_id
    connection.provider_username = str(athlete_username) if athlete_username else connection.provider_username
    connection.token_type = str(payload.get("token_type") or "") or None
    connection.scope = str(payload.get("scope") or "") or connection.scope
    connection.expires_at = expires_at
    return connection


def _create_oauth_state(session, user_id: int, provider: OAuthProvider) -> str:
    now = _now_utc()
    session.execute(
        delete(OAuthState).where(
            and_(
                OAuthState.user_id == user_id,
                OAuthState.provider == provider,
                or_(OAuthState.expires_at < now, OAuthState.consumed_at.is_not(None)),
            )
        )
    )

    state = secrets.token_urlsafe(32)
    session.add(
        OAuthState(
            user_id=user_id,
            provider=provider,
            state=state,
            expires_at=now + timedelta(minutes=15),
        )
    )
    return state


def _ensure_strava_access_token(session, user_id: int, connection: OAuthConnection) -> str:
    if connection.expires_at is None:
        return connection.access_token

    refresh_at = connection.expires_at - timedelta(seconds=90)
    if _now_utc() < refresh_at:
        return connection.access_token

    payload = refresh_access_token(connection.refresh_token)
    updated = _upsert_oauth_connection_from_token_payload(
        session,
        user_id=user_id,
        provider=OAuthProvider.STRAVA,
        payload=payload,
    )
    session.flush()
    return updated.access_token


def _build_strava_activity_payload(session, workout_session: WorkoutSession) -> dict[str, object]:
    workout = session.get(PlanWorkout, workout_session.plan_workout_id)
    run = session.get(PlanRun, workout_session.plan_run_id)
    plan = session.get(Plan, run.plan_id) if run else None

    entry_rows = session.scalars(
        select(SessionExerciseEntry).where(SessionExerciseEntry.session_id == workout_session.id)
    ).all()
    set_rows = session.scalars(
        select(SessionSet)
        .join(SessionExerciseEntry, SessionExerciseEntry.id == SessionSet.entry_id)
        .where(SessionExerciseEntry.session_id == workout_session.id)
    ).all()

    completed_rows = [x for x in set_rows if x.completed]
    total_volume_kg = sum((x.weight_kg or 0.0) * float(x.reps_completed or 0) for x in completed_rows)
    total_set_duration_seconds = sum(int(x.duration_seconds or 0) for x in completed_rows)

    elapsed_seconds = 0
    if workout_session.finished_at is not None and workout_session.started_at is not None:
        elapsed_seconds = max(0, int((workout_session.finished_at - workout_session.started_at).total_seconds()))
    if elapsed_seconds <= 0:
        elapsed_seconds = max(1, total_set_duration_seconds)

    start_local = _ensure_utc(workout_session.started_at).isoformat(timespec="seconds")

    base_name = workout.name if workout else "Strength Workout"
    if plan and plan.name.strip():
        name = f"{plan.name} · {base_name}"
    else:
        name = base_name
    name = name[:140]

    summary_bits = [
        f"{len(completed_rows)}/{len(set_rows)} sets",
        f"{round(total_volume_kg, 1)} kg volume",
        f"{_format_elapsed(elapsed_seconds)} total",
    ]
    if total_set_duration_seconds > 0:
        summary_bits.append(f"{_format_elapsed(total_set_duration_seconds)} lifting")

    exercise_lines: list[str] = []
    for entry in entry_rows:
        exercise = session.get(Exercise, entry.exercise_id)
        exercise_name = exercise.name if exercise else f"Exercise {entry.exercise_id}"
        completed_for_entry = [x for x in completed_rows if x.entry_id == entry.id]
        if not completed_for_entry:
            continue
        exercise_lines.append(
            f"- {exercise_name}: {len(completed_for_entry)} sets, {sum(int(x.reps_completed or 0) for x in completed_for_entry)} reps"
        )

    description_parts = ["Logged with Workout App", " · ".join(summary_bits)]
    if exercise_lines:
        description_parts.append("\n".join(exercise_lines[:8]))

    description = "\n".join(description_parts)[:1800]

    return {
        "name": name,
        "sport_type": "WeightTraining",
        "start_date_local": start_local,
        "elapsed_time": elapsed_seconds,
        "description": description,
        "trainer": 1,
        "commute": 0,
    }


def _send_workout_to_strava_with_session(
    session,
    user_id: int,
    workout_session: WorkoutSession,
) -> StravaSendResult:
    if workout_session.status != WorkoutSessionStatus.COMPLETED:
        return StravaSendResult(
            ok=False,
            message="Workout session must be completed before export",
            activity_id=None,
            activity_url=None,
        )

    if not is_strava_configured():
        return StravaSendResult(
            ok=False,
            message="Strava is not configured on the server",
            activity_id=None,
            activity_url=None,
        )

    connection = _get_oauth_connection(session, user_id, OAuthProvider.STRAVA)
    if not connection:
        return StravaSendResult(
            ok=False,
            message="Strava is not connected",
            activity_id=None,
            activity_url=None,
        )

    export_row = session.scalar(
        select(WorkoutExport).where(
            and_(
                WorkoutExport.provider == OAuthProvider.STRAVA,
                WorkoutExport.session_id == workout_session.id,
            )
        )
    )
    if export_row and export_row.status == WorkoutExportStatus.SENT and export_row.remote_activity_id:
        return StravaSendResult(
            ok=True,
            message="Workout already sent to Strava",
            activity_id=export_row.remote_activity_id,
            activity_url=export_row.remote_activity_url,
        )

    if not export_row:
        export_row = WorkoutExport(
            user_id=user_id,
            session_id=workout_session.id,
            provider=OAuthProvider.STRAVA,
            status=WorkoutExportStatus.PENDING,
        )
        session.add(export_row)

    payload = _build_strava_activity_payload(session, workout_session)

    try:
        access_token = _ensure_strava_access_token(session, user_id, connection)
        response = create_activity(access_token, payload)
        activity_id_raw = response.get("id")
        if activity_id_raw is None:
            raise StravaError("Strava response missing activity id")
        activity_id = str(activity_id_raw)
    except StravaError as exc:
        export_row.status = WorkoutExportStatus.FAILED
        export_row.last_error = str(exc)[:780]
        export_row.payload_json = payload
        session.commit()
        return StravaSendResult(
            ok=False,
            message=f"Failed to send workout: {exc}",
            activity_id=None,
            activity_url=None,
        )

    export_row.status = WorkoutExportStatus.SENT
    export_row.remote_activity_id = activity_id
    export_row.remote_activity_url = _strava_activity_url(activity_id)
    export_row.payload_json = payload
    export_row.last_error = None
    session.commit()

    return StravaSendResult(
        ok=True,
        message="Workout sent to Strava",
        activity_id=activity_id,
        activity_url=export_row.remote_activity_url,
    )


def _get_default_user(session) -> User:
    user = session.get(User, DEFAULT_USER_ID)
    if user:
        return user

    user = User(id=DEFAULT_USER_ID, name=DEFAULT_USER_NAME)
    session.add(user)
    session.commit()
    return user


def _normalize_text(value: str) -> str:
    value = value.strip().lower()
    value = re.sub(r"[\-_/,]+", " ", value)
    value = re.sub(r"\s+", " ", value)
    return value


def _exercise_name_key(name: str) -> str:
    return _normalize_text(name)


def _map_catalog_source(source: ExerciseCatalogSource) -> GQLExerciseCatalogSource:
    return GQLExerciseCatalogSource(source.value)


def _map_equipment_type(equipment: EquipmentType) -> GQLEquipmentType:
    return GQLEquipmentType(equipment.value)


def _find_catalog_item_for_name(session, exercise_name: str) -> ExerciseCatalogItem | None:
    key = _exercise_name_key(exercise_name)
    if not key:
        return None

    alias_match = session.scalar(
        select(ExerciseCatalogAlias)
        .where(
            and_(
                ExerciseCatalogAlias.alias_normalized == key,
                ExerciseCatalogAlias.is_active.is_(True),
            )
        )
        .order_by(ExerciseCatalogAlias.id.asc())
    )
    if alias_match:
        return session.get(ExerciseCatalogItem, alias_match.catalog_item_id)

    return session.scalar(
        select(ExerciseCatalogItem)
        .where(
            and_(
                ExerciseCatalogItem.name_normalized == key,
                ExerciseCatalogItem.is_active.is_(True),
            )
        )
        .order_by(ExerciseCatalogItem.id.asc())
    )


def _get_or_create_exercise_by_name(session, exercise_name: str) -> Exercise:
    name = exercise_name.strip()
    if not name:
        raise ValueError("exercise_name must not be empty")

    existing = session.scalar(
        select(Exercise)
        .where(func.lower(Exercise.name) == name.lower())
        .order_by(Exercise.id.asc())
    )
    if existing:
        if existing.catalog_item_id is None:
            catalog_item = _find_catalog_item_for_name(session, name)
            if catalog_item:
                existing.catalog_item_id = catalog_item.id
        return existing

    catalog_item = _find_catalog_item_for_name(session, name)
    exercise = Exercise(name=name, catalog_item_id=catalog_item.id if catalog_item else None)
    session.add(exercise)
    session.flush()
    return exercise


def _active_plan_context(session, user_id: int) -> ActivePlanContext | None:
    run = session.scalar(
        select(PlanRun)
        .where(and_(PlanRun.user_id == user_id, PlanRun.status == PlanRunStatus.ACTIVE))
        .order_by(PlanRun.id.desc())
    )
    if not run:
        return None

    plan = session.get(Plan, run.plan_id)
    if not plan:
        return None
    return ActivePlanContext(plan=plan, run=run)


def _build_session_type(session, workout_session: WorkoutSession) -> WorkoutSessionType:
    entries = session.scalars(
        select(SessionExerciseEntry)
        .where(SessionExerciseEntry.session_id == workout_session.id)
        .order_by(SessionExerciseEntry.id.asc())
    ).all()
    out_entries: list[SessionExerciseEntryType] = []

    for entry in entries:
        sets = session.scalars(
            select(SessionSet)
            .where(SessionSet.entry_id == entry.id)
            .order_by(SessionSet.set_index.asc())
        ).all()
        exercise = session.get(Exercise, entry.exercise_id)
        template = session.get(PlanWorkoutExercise, entry.plan_workout_exercise_id)
        protocol = (
            GQLProgressionProtocol(template.progression_protocol.value)
            if template
            else GQLProgressionProtocol.BASIC
        )
        tier = GQLExerciseTier(template.tier.value) if template and template.tier else None
        expected_rest = _expected_rest_seconds(template.tier if template else None)

        out_entries.append(
            SessionExerciseEntryType(
                id=entry.id,
                exercise_id=entry.exercise_id,
                exercise_name=exercise.name if exercise else f"Exercise {entry.exercise_id}",
                planned_sets=entry.planned_sets,
                planned_reps=entry.planned_reps,
                planned_weight_kg=entry.planned_weight_kg,
                progression_protocol=protocol,
                tier=tier,
                expected_rest_seconds=expected_rest,
                sets=[
                    SessionSetType(
                        id=s.id,
                        set_index=s.set_index,
                        target_reps=s.target_reps,
                        is_amrap=s.is_amrap,
                        reps_completed=s.reps_completed,
                        weight_kg=s.weight_kg,
                        duration_seconds=s.duration_seconds,
                        completed=s.completed,
                        completed_at=s.completed_at,
                    )
                    for s in sets
                ],
            )
        )

    hr_count, hr_avg, hr_max = _session_heart_rate_stats(session, workout_session.id)

    return WorkoutSessionType(
        id=workout_session.id,
        status=_map_status(workout_session.status),
        started_at=workout_session.started_at,
        finished_at=workout_session.finished_at,
        heart_rate_sample_count=hr_count,
        avg_heart_rate_bpm=hr_avg,
        max_heart_rate_bpm=hr_max,
        entries=out_entries,
    )


def _get_workouts_in_plan(session, plan_id: int) -> list[PlanWorkout]:
    return session.scalars(
        select(PlanWorkout).where(PlanWorkout.plan_id == plan_id).order_by(PlanWorkout.sequence_index.asc())
    ).all()


def _get_plan_templates_for_workout(session, plan_workout_id: int) -> list[PlanWorkoutExercise]:
    return session.scalars(
        select(PlanWorkoutExercise)
        .where(PlanWorkoutExercise.plan_workout_id == plan_workout_id)
        .order_by(PlanWorkoutExercise.id.asc())
    ).all()


def _template_for_exercise_in_plan(
    session,
    plan_id: int,
    exercise_id: int,
) -> PlanWorkoutExercise | None:
    return session.scalar(
        select(PlanWorkoutExercise)
        .join(PlanWorkout, PlanWorkout.id == PlanWorkoutExercise.plan_workout_id)
        .where(and_(PlanWorkout.plan_id == plan_id, PlanWorkoutExercise.exercise_id == exercise_id))
        .order_by(PlanWorkout.sequence_index.asc(), PlanWorkoutExercise.id.asc())
    )


def _get_baseline(session, user_id: int, exercise_id: int) -> ExerciseBaseline | None:
    return session.scalar(
        select(ExerciseBaseline).where(
            and_(ExerciseBaseline.user_id == user_id, ExerciseBaseline.exercise_id == exercise_id)
        )
    )


def _get_plan_run_baseline(session, plan_run_id: int, exercise_id: int) -> PlanRunBaseline | None:
    return session.scalar(
        select(PlanRunBaseline).where(
            and_(PlanRunBaseline.plan_run_id == plan_run_id, PlanRunBaseline.exercise_id == exercise_id)
        )
    )


def _upsert_plan_run_baseline(
    session,
    plan_run_id: int,
    exercise_id: int,
    baseline_1rm_kg: float,
) -> PlanRunBaseline:
    row = _get_plan_run_baseline(session, plan_run_id, exercise_id)
    if row:
        row.baseline_1rm_kg = baseline_1rm_kg
        return row

    row = PlanRunBaseline(
        plan_run_id=plan_run_id,
        exercise_id=exercise_id,
        baseline_1rm_kg=baseline_1rm_kg,
    )
    session.add(row)
    session.flush()
    return row


def _get_or_create_run_state(
    session,
    plan_run_id: int,
    exercise_id: int,
    tier: ExerciseTier | None,
    default_weight: float,
) -> RunExerciseState:
    state = session.scalar(
        select(RunExerciseState).where(
            and_(
                RunExerciseState.plan_run_id == plan_run_id,
                RunExerciseState.exercise_id == exercise_id,
                RunExerciseState.tier == tier,
            )
        )
    )
    if state:
        return state

    state = RunExerciseState(
        plan_run_id=plan_run_id,
        exercise_id=exercise_id,
        tier=tier,
        current_weight_kg=default_weight,
        failure_count=0,
        needs_new_1rm=False,
    )
    session.add(state)
    session.flush()
    return state


def _days_since(reference: datetime | None) -> int | None:
    if reference is None:
        return None
    delta = _now_utc().date() - reference.date()
    return delta.days


def _exercise_label(exercise_name: str, tier: ExerciseTier | None) -> str:
    if tier is None:
        return exercise_name
    return f"{exercise_name} ({tier.value})"


def _round_to_increment(weight_kg: float, increment_kg: float) -> float:
    inc = increment_kg if increment_kg > 0 else DEFAULT_WEIGHT_INCREMENT_KG
    steps = int((max(0.0, weight_kg) / inc) + 0.5)
    return round(steps * inc, 3)


def _estimated_1rm_from_sets(session_sets: list[SessionSet]) -> float | None:
    estimates: list[float] = []
    for s in session_sets:
        if not s.completed:
            continue
        if s.reps_completed is None or s.reps_completed <= 0:
            continue
        if s.weight_kg is None or s.weight_kg <= 0:
            continue
        estimates.append(s.weight_kg * (1.0 + (s.reps_completed / 30.0)))

    if not estimates:
        return None
    return round(max(estimates), 2)


def _to_plan_exercise_type(session, row: PlanWorkoutExercise) -> PlanExerciseType:
    exercise = session.get(Exercise, row.exercise_id)
    tier = GQLExerciseTier(row.tier.value) if row.tier else None
    return PlanExerciseType(
        id=row.id,
        exercise_id=row.exercise_id,
        exercise_name=exercise.name if exercise else f"Exercise {row.exercise_id}",
        sets=row.sets,
        reps=row.reps,
        target_weight_kg=row.target_weight_kg,
        progression_type=GQLProgressionType(row.progression_type.value),
        progression_protocol=GQLProgressionProtocol(row.progression_protocol.value),
        tier=tier,
        progression_value=row.progression_value,
        training_max_ratio=row.training_max_ratio,
        amrap_last_set=row.amrap_last_set,
    )


def _active_plan_type(session, user_id: int) -> ActivePlanType | None:
    ctx = _active_plan_context(session, user_id)
    if not ctx:
        return None

    workouts = _get_workouts_in_plan(session, ctx.plan.id)
    out_workouts: list[PlanWorkoutType] = []
    for workout in workouts:
        exercise_rows = _get_plan_templates_for_workout(session, workout.id)
        out_workouts.append(
            PlanWorkoutType(
                id=workout.id,
                name=workout.name,
                sequence_index=workout.sequence_index,
                exercises=[_to_plan_exercise_type(session, row) for row in exercise_rows],
            )
        )

    return ActivePlanType(
        id=ctx.plan.id,
        name=ctx.plan.name,
        total_weeks=ctx.plan.total_weeks,
        days_per_week=len(out_workouts),
        current_week=ctx.run.current_week,
        current_workout_index=ctx.run.current_workout_index,
        workouts=out_workouts,
    )


@strawberry.type
class Query:
    @strawberry.field
    def exercises(self) -> list[ExerciseType]:
        with db_session() as session:
            rows = session.scalars(select(Exercise).order_by(Exercise.name.asc())).all()
            return [ExerciseType(id=r.id, name=r.name) for r in rows]

    @strawberry.field
    def exercise_catalog_item(self, catalog_item_id: int) -> ExerciseCatalogItemType | None:
        with db_session() as session:
            row = session.get(ExerciseCatalogItem, catalog_item_id)
            if not row or not row.is_active:
                return None
            return ExerciseCatalogItemType(
                id=row.id,
                source=_map_catalog_source(row.source),
                source_exercise_id=row.source_exercise_id,
                canonical_name=row.canonical_name,
                equipment_type=_map_equipment_type(row.equipment_type),
                movement_category=row.movement_category,
                primary_muscle=row.primary_muscle,
            )

    @strawberry.field
    def exercise_catalog_search(self, query: str, limit: int = 12) -> list[ExerciseCatalogMatchType]:
        key = _exercise_name_key(query)
        if not key:
            return []

        result_limit = max(1, min(limit, 50))
        like_value = f"%{key}%"

        with db_session() as session:
            rows = session.execute(
                select(ExerciseCatalogAlias, ExerciseCatalogItem)
                .join(ExerciseCatalogItem, ExerciseCatalogItem.id == ExerciseCatalogAlias.catalog_item_id)
                .where(
                    and_(
                        ExerciseCatalogAlias.is_active.is_(True),
                        ExerciseCatalogItem.is_active.is_(True),
                        or_(
                            ExerciseCatalogAlias.alias_normalized.like(like_value),
                            ExerciseCatalogItem.name_normalized.like(like_value),
                        ),
                    )
                )
                .order_by(ExerciseCatalogAlias.id.asc())
                .limit(max(result_limit * 12, 80))
            ).all()

            scored: dict[int, tuple[tuple[int, int, str], ExerciseCatalogMatchType]] = {}

            for alias, item in rows:
                alias_key = alias.alias_normalized
                name_key = item.name_normalized

                if alias_key == key or name_key == key:
                    score = 0
                elif alias_key.startswith(key) or name_key.startswith(key):
                    score = 1
                elif f" {key}" in alias_key or f" {key}" in name_key:
                    score = 2
                else:
                    score = 3

                match = ExerciseCatalogMatchType(
                    catalog_item_id=item.id,
                    canonical_name=item.canonical_name,
                    equipment_type=_map_equipment_type(item.equipment_type),
                    matched_alias=alias.alias,
                    source=_map_catalog_source(item.source),
                )
                rank = (score, len(alias.alias), item.canonical_name.lower())
                previous = scored.get(item.id)
                if previous is None or rank < previous[0]:
                    scored[item.id] = (rank, match)

            if len(scored) < result_limit:
                fallback_items = session.scalars(
                    select(ExerciseCatalogItem)
                    .where(
                        and_(
                            ExerciseCatalogItem.is_active.is_(True),
                            ExerciseCatalogItem.name_normalized.like(like_value),
                        )
                    )
                    .order_by(ExerciseCatalogItem.canonical_name.asc())
                    .limit(result_limit * 2)
                ).all()
                for item in fallback_items:
                    if item.id in scored:
                        continue
                    score = 1 if item.name_normalized.startswith(key) else 3
                    match = ExerciseCatalogMatchType(
                        catalog_item_id=item.id,
                        canonical_name=item.canonical_name,
                        equipment_type=_map_equipment_type(item.equipment_type),
                        matched_alias=item.canonical_name,
                        source=_map_catalog_source(item.source),
                    )
                    rank = (score, len(item.canonical_name), item.canonical_name.lower())
                    scored[item.id] = (rank, match)

            ordered = [pair[1] for pair in sorted(scored.values(), key=lambda x: x[0])]
            return ordered[:result_limit]

    @strawberry.field
    def active_plan(self) -> ActivePlanType | None:
        with db_session() as session:
            user = _get_default_user(session)
            return _active_plan_type(session, user.id)

    @strawberry.field
    def strava_connection(self) -> StravaConnectionType:
        with db_session() as session:
            user = _get_default_user(session)
            row = _get_oauth_connection(session, user.id, OAuthProvider.STRAVA)
            pref = session.scalar(select(UserPreference).where(UserPreference.user_id == user.id))
            return StravaConnectionType(
                configured=is_strava_configured(),
                connected=row is not None,
                athlete_id=row.provider_user_id if row else None,
                athlete_username=row.provider_username if row else None,
                scope=row.scope if row else None,
                expires_at=row.expires_at if row else None,
                auto_send_on_finish=bool(pref and pref.strava_auto_send_on_finish),
            )

    @strawberry.field
    def dashboard(self) -> DashboardType:
        with db_session() as session:
            user = _get_default_user(session)
            ctx = _active_plan_context(session, user.id)

            baseline_rows = session.scalars(
                select(ExerciseBaseline)
                .where(ExerciseBaseline.user_id == user.id)
                .order_by(ExerciseBaseline.exercise_id.asc())
            ).all()
            baselines: list[BaselineType] = []
            for b in baseline_rows:
                exercise = session.get(Exercise, b.exercise_id)
                baselines.append(
                    BaselineType(
                        exercise_id=b.exercise_id,
                        exercise_name=exercise.name if exercise else f"Exercise {b.exercise_id}",
                        baseline_1rm_kg=b.baseline_1rm_kg,
                    )
                )

            if not ctx:
                return DashboardType(status=None, baselines=baselines, reset_baselines=[])

            workouts = _get_workouts_in_plan(session, ctx.plan.id)

            reset_exercise_ids: set[int] = set()
            for workout in workouts:
                templates = _get_plan_templates_for_workout(session, workout.id)
                for t in templates:
                    reset_exercise_ids.add(t.exercise_id)

            reset_baselines: list[BaselineType] = []
            for exercise_id in sorted(reset_exercise_ids):
                run_baseline = _get_plan_run_baseline(session, ctx.run.id, exercise_id)
                baseline_value = run_baseline.baseline_1rm_kg if run_baseline else None
                if baseline_value is None:
                    baseline = _get_baseline(session, user.id, exercise_id)
                    baseline_value = baseline.baseline_1rm_kg if baseline else None
                if baseline_value is None:
                    continue
                exercise = session.get(Exercise, exercise_id)
                reset_baselines.append(
                    BaselineType(
                        exercise_id=exercise_id,
                        exercise_name=exercise.name if exercise else f"Exercise {exercise_id}",
                        baseline_1rm_kg=baseline_value,
                    )
                )

            reset_baselines.sort(key=lambda b: b.exercise_name.lower())
            workout_index = min(ctx.run.current_workout_index, max(len(workouts) - 1, 0))

            last_workout = session.scalar(
                select(WorkoutSession)
                .where(
                    and_(
                        WorkoutSession.user_id == user.id,
                        WorkoutSession.status == WorkoutSessionStatus.COMPLETED,
                    )
                )
                .order_by(WorkoutSession.finished_at.desc())
            )

            needs_reset_rows = session.scalars(
                select(RunExerciseState).where(
                    and_(
                        RunExerciseState.plan_run_id == ctx.run.id,
                        RunExerciseState.needs_new_1rm.is_(True),
                    )
                )
            ).all()
            needs_reset_names: list[str] = []
            for row in needs_reset_rows:
                exercise = session.get(Exercise, row.exercise_id)
                exercise_name = exercise.name if exercise else f"Exercise {row.exercise_id}"
                needs_reset_names.append(_exercise_label(exercise_name, row.tier))

            status = CurrentStatusType(
                plan_run_id=ctx.run.id,
                plan_name=ctx.plan.name,
                week=ctx.run.current_week,
                workout_index=workout_index,
                last_workout_at=last_workout.finished_at if last_workout else None,
                days_since_last_workout=_days_since(last_workout.finished_at if last_workout else None),
                needs_new_1rm_exercises=needs_reset_names,
            )
            return DashboardType(status=status, baselines=baselines, reset_baselines=reset_baselines)

    @strawberry.field
    def active_workout_session(self) -> WorkoutSessionType | None:
        with db_session() as session:
            user = _get_default_user(session)
            ws = session.scalar(
                select(WorkoutSession)
                .where(
                    and_(
                        WorkoutSession.user_id == user.id,
                        WorkoutSession.status == WorkoutSessionStatus.IN_PROGRESS,
                    )
                )
                .order_by(WorkoutSession.started_at.desc())
            )
            if not ws:
                return None
            return _build_session_type(session, ws)

    @strawberry.field
    def session_heart_rate_samples(
        self,
        session_id: int,
        limit: int = 1200,
    ) -> list[HeartRateSampleType]:
        with db_session() as session:
            user = _get_default_user(session)
            workout_session = session.get(WorkoutSession, session_id)
            if not workout_session or workout_session.user_id != user.id:
                return []

            safe_limit = max(1, min(limit, 5000))
            rows = session.scalars(
                select(HeartRateSample)
                .where(HeartRateSample.session_id == session_id)
                .order_by(HeartRateSample.recorded_at.asc(), HeartRateSample.id.asc())
                .limit(safe_limit)
            ).all()

            return [
                HeartRateSampleType(
                    id=row.id,
                    session_id=row.session_id,
                    recorded_at=row.recorded_at,
                    bpm=row.bpm,
                    source=row.source,
                )
                for row in rows
            ]

    @strawberry.field
    def workout_history(self, limit: int = 20) -> list[WorkoutHistoryItemType]:
        with db_session() as session:
            user = _get_default_user(session)
            sessions = session.scalars(
                select(WorkoutSession)
                .where(
                    and_(
                        WorkoutSession.user_id == user.id,
                        WorkoutSession.status == WorkoutSessionStatus.COMPLETED,
                    )
                )
                .order_by(WorkoutSession.finished_at.desc())
                .limit(limit)
            ).all()

            out: list[WorkoutHistoryItemType] = []
            for s in sessions:
                workout = session.get(PlanWorkout, s.plan_workout_id)
                entry_rows = session.scalars(
                    select(SessionExerciseEntry).where(SessionExerciseEntry.session_id == s.id)
                ).all()
                set_rows = session.scalars(
                    select(SessionSet)
                    .join(SessionExerciseEntry, SessionExerciseEntry.id == SessionSet.entry_id)
                    .where(SessionExerciseEntry.session_id == s.id)
                ).all()
                completed_rows = [x for x in set_rows if x.completed]
                total_volume_kg = sum((x.weight_kg or 0.0) * float(x.reps_completed or 0) for x in completed_rows)
                total_set_duration_seconds = sum(int(x.duration_seconds or 0) for x in completed_rows)
                total_duration_seconds = None
                if s.finished_at is not None and s.started_at is not None:
                    total_duration_seconds = max(0, int((s.finished_at - s.started_at).total_seconds()))

                exercise_items: list[WorkoutHistoryExerciseType] = []
                for entry in entry_rows:
                    entry_sets = [row for row in completed_rows if row.entry_id == entry.id]
                    if not entry_sets:
                        continue
                    exercise = session.get(Exercise, entry.exercise_id)
                    total_reps = sum(int(row.reps_completed or 0) for row in entry_sets)
                    top_weight_kg = max((row.weight_kg or entry.planned_weight_kg) for row in entry_sets)
                    exercise_items.append(
                        WorkoutHistoryExerciseType(
                            exercise_id=entry.exercise_id,
                            exercise_name=exercise.name if exercise else f"Exercise {entry.exercise_id}",
                            completed_sets=len(entry_sets),
                            total_reps=total_reps,
                            top_weight_kg=round(float(top_weight_kg), 2),
                        )
                    )

                hr_count, hr_avg, hr_max = _session_heart_rate_stats(session, s.id)

                export_row = session.scalar(
                    select(WorkoutExport)
                    .where(
                        and_(
                            WorkoutExport.session_id == s.id,
                            WorkoutExport.provider == OAuthProvider.STRAVA,
                        )
                    )
                    .order_by(WorkoutExport.id.desc())
                )

                out.append(
                    WorkoutHistoryItemType(
                        session_id=s.id,
                        plan_run_id=s.plan_run_id,
                        finished_at=s.finished_at,
                        plan_workout_name=workout.name if workout else f"Workout {s.plan_workout_id}",
                        workout_sequence_index=workout.sequence_index if workout else None,
                        total_sets=len(set_rows),
                        completed_sets=len(completed_rows),
                        total_volume_kg=round(total_volume_kg, 2),
                        total_duration_seconds=total_duration_seconds,
                        total_set_duration_seconds=total_set_duration_seconds,
                        heart_rate_sample_count=hr_count,
                        avg_heart_rate_bpm=hr_avg,
                        max_heart_rate_bpm=hr_max,
                        strava_export_status=(
                            _map_export_status(export_row.status) if export_row else None
                        ),
                        strava_activity_id=export_row.remote_activity_id if export_row else None,
                        strava_activity_url=export_row.remote_activity_url if export_row else None,
                        exercises=exercise_items,
                    )
                )

            return out

    @strawberry.field
    def exercise_progress(self, exercise_id: int, limit: int = 50) -> list[ExerciseProgressPointType]:
        with db_session() as session:
            user = _get_default_user(session)
            rows = session.execute(
                select(SessionSet, WorkoutSession)
                .join(SessionExerciseEntry, SessionExerciseEntry.id == SessionSet.entry_id)
                .join(WorkoutSession, WorkoutSession.id == SessionExerciseEntry.session_id)
                .where(
                    and_(
                        WorkoutSession.user_id == user.id,
                        SessionExerciseEntry.exercise_id == exercise_id,
                        SessionSet.completed.is_(True),
                        WorkoutSession.status == WorkoutSessionStatus.COMPLETED,
                    )
                )
                .order_by(WorkoutSession.finished_at.asc())
            ).all()

            grouped: dict[datetime, list[SessionSet]] = defaultdict(list)
            for set_row, workout in rows:
                when = workout.finished_at or workout.started_at
                grouped[when].append(set_row)

            points: list[ExerciseProgressPointType] = []
            for when, sets in grouped.items():
                top = max((s.weight_kg or 0.0) for s in sets)
                best_est_1rm = max(
                    ((s.weight_kg or 0.0) * (1.0 + ((s.reps_completed or 0) / 30.0))) for s in sets
                )
                points.append(
                    ExerciseProgressPointType(
                        date=when,
                        top_weight_kg=round(top, 2),
                        estimated_1rm_kg=round(best_est_1rm, 2),
                    )
                )

            return points[-limit:]


@strawberry.type
class Mutation:
    @strawberry.mutation
    def append_heart_rate_samples(
        self,
        session_id: int,
        samples: list[HeartRateSampleInput],
    ) -> HeartRateIngestResult:
        if not samples:
            return HeartRateIngestResult(ok=True, message="No samples provided", inserted_count=0)
        if len(samples) > 5000:
            return HeartRateIngestResult(
                ok=False,
                message="Too many samples in one request (max 5000)",
                inserted_count=0,
            )

        with db_session() as session:
            user = _get_default_user(session)
            workout_session = session.get(WorkoutSession, session_id)
            if not workout_session or workout_session.user_id != user.id:
                return HeartRateIngestResult(
                    ok=False,
                    message="Workout session not found",
                    inserted_count=0,
                )
            if workout_session.status == WorkoutSessionStatus.CANCELLED:
                return HeartRateIngestResult(
                    ok=False,
                    message="Cannot attach heart-rate samples to cancelled workout",
                    inserted_count=0,
                )

            inserted_count = 0
            for item in samples:
                bpm = int(item.bpm)
                if bpm < 20 or bpm > 255:
                    return HeartRateIngestResult(
                        ok=False,
                        message=f"Invalid bpm value {bpm}. Expected range: 20-255",
                        inserted_count=0,
                    )

                session.add(
                    HeartRateSample(
                        session_id=workout_session.id,
                        recorded_at=_to_utc_naive(item.recorded_at),
                        bpm=bpm,
                        source=(item.source or "BLE")[:40],
                    )
                )
                inserted_count += 1

            session.commit()
            return HeartRateIngestResult(
                ok=True,
                message="Heart-rate samples saved",
                inserted_count=inserted_count,
            )

    @strawberry.mutation
    def start_strava_auth(self) -> StravaAuthStartType:
        if not is_strava_configured():
            return StravaAuthStartType(
                ok=False,
                auth_url="",
                message="Strava is not configured on the server",
            )

        with db_session() as session:
            user = _get_default_user(session)
            state = _create_oauth_state(session, user.id, OAuthProvider.STRAVA)
            try:
                auth_url = build_authorize_url(state)
            except StravaError as exc:
                return StravaAuthStartType(ok=False, auth_url="", message=str(exc))

            session.commit()
            return StravaAuthStartType(ok=True, auth_url=auth_url, message="Open URL to connect Strava")

    @strawberry.mutation
    def connect_strava(self, code: str, state: str) -> MutationResult:
        if not is_strava_configured():
            return MutationResult(ok=False, message="Strava is not configured on the server")

        clean_code = code.strip()
        clean_state = state.strip()
        if not clean_code or not clean_state:
            return MutationResult(ok=False, message="Missing OAuth code/state")

        with db_session() as session:
            user = _get_default_user(session)
            valid_state = session.scalar(
                select(OAuthState).where(
                    and_(
                        OAuthState.user_id == user.id,
                        OAuthState.provider == OAuthProvider.STRAVA,
                        OAuthState.state == clean_state,
                        OAuthState.consumed_at.is_(None),
                        OAuthState.expires_at >= _now_utc(),
                    )
                )
            )
            if not valid_state:
                return MutationResult(ok=False, message="Invalid or expired Strava OAuth state")

            try:
                payload = exchange_code_for_token(clean_code)
                _upsert_oauth_connection_from_token_payload(
                    session,
                    user_id=user.id,
                    provider=OAuthProvider.STRAVA,
                    payload=payload,
                )
            except (StravaError, ValueError) as exc:
                return MutationResult(ok=False, message=f"Strava connect failed: {exc}")

            valid_state.consumed_at = _now_utc()
            session.commit()
            return MutationResult(ok=True, message="Connected Strava")

    @strawberry.mutation
    def disconnect_strava(self) -> MutationResult:
        with db_session() as session:
            user = _get_default_user(session)
            connection = _get_oauth_connection(session, user.id, OAuthProvider.STRAVA)
            if not connection:
                return MutationResult(ok=True, message="Strava already disconnected")

            try:
                deauthorize(connection.access_token)
            except StravaError:
                pass

            session.execute(delete(OAuthConnection).where(OAuthConnection.id == connection.id))
            session.commit()
            return MutationResult(ok=True, message="Disconnected Strava")

    @strawberry.mutation
    def set_strava_auto_send_on_finish(self, enabled: bool) -> MutationResult:
        with db_session() as session:
            user = _get_default_user(session)
            pref = _get_or_create_user_preference(session, user.id)
            pref.strava_auto_send_on_finish = enabled
            session.commit()
            return MutationResult(
                ok=True,
                message=(
                    "Strava auto-send enabled"
                    if enabled
                    else "Strava auto-send disabled"
                ),
            )

    @strawberry.mutation
    def send_workout_to_strava(self, session_id: int) -> StravaSendResult:
        with db_session() as session:
            user = _get_default_user(session)
            workout_session = session.get(WorkoutSession, session_id)
            if not workout_session or workout_session.user_id != user.id:
                return StravaSendResult(
                    ok=False,
                    message="Workout session not found",
                    activity_id=None,
                    activity_url=None,
                )

            return _send_workout_to_strava_with_session(
                session,
                user_id=user.id,
                workout_session=workout_session,
            )

    @strawberry.mutation
    def link_exercise_to_catalog(
        self,
        exercise_id: int,
        catalog_item_id: int | None,
    ) -> MutationResult:
        with db_session() as session:
            exercise = session.get(Exercise, exercise_id)
            if not exercise:
                return MutationResult(ok=False, message="exercise_id not found")

            if catalog_item_id is None:
                exercise.catalog_item_id = None
                session.commit()
                return MutationResult(ok=True, message=f"Unlinked catalog item from {exercise.name}")

            catalog_item = session.get(ExerciseCatalogItem, catalog_item_id)
            if not catalog_item or not catalog_item.is_active:
                return MutationResult(ok=False, message="catalog_item_id not found or inactive")

            exercise.catalog_item_id = catalog_item.id
            session.commit()
            return MutationResult(ok=True, message=f"Linked {exercise.name} to {catalog_item.canonical_name}")

    @strawberry.mutation
    def seed_plan(
        self,
        plan_name: str,
        total_weeks: int | None,
        workouts: list[SeedPlanWorkoutInput],
        exercises: list[SeedExerciseInput],
        days_per_week: int | None = None,
    ) -> SeedResult:
        with db_session() as session:
            user = _get_default_user(session)

            by_name: dict[str, Exercise] = {}
            baseline_by_name: dict[str, float] = {}

            for ex in exercises:
                key = _exercise_name_key(ex.name)
                if key in baseline_by_name and baseline_by_name[key] != ex.baseline_1rm_kg:
                    raise ValueError(
                        f"exercise '{ex.name.strip()}' has conflicting baseline_1rm_kg values"
                    )

                baseline_by_name[key] = ex.baseline_1rm_kg
                exercise = _get_or_create_exercise_by_name(session, ex.name)
                by_name[key] = exercise

                baseline = _get_baseline(session, user.id, exercise.id)
                if baseline:
                    baseline.baseline_1rm_kg = ex.baseline_1rm_kg
                else:
                    session.add(
                        ExerciseBaseline(
                            user_id=user.id,
                            exercise_id=exercise.id,
                            baseline_1rm_kg=ex.baseline_1rm_kg,
                        )
                    )

            if days_per_week is not None and days_per_week <= 0:
                raise ValueError("days_per_week must be > 0")

            if days_per_week is None:
                days_per_week = len(workouts) if workouts else 1

            if len(workouts) > days_per_week:
                raise ValueError("days_per_week cannot be smaller than number of workouts provided")

            sequence_indexes = [w.sequence_index for w in workouts]
            if len(set(sequence_indexes)) != len(sequence_indexes):
                raise ValueError("workout sequence_index values must be unique")

            if any(idx < 0 for idx in sequence_indexes):
                raise ValueError("workout sequence_index must be >= 0")

            if any(idx >= days_per_week for idx in sequence_indexes):
                raise ValueError("workout sequence_index must be < days_per_week")

            session.execute(
                update(Plan)
                .where(and_(Plan.user_id == user.id, Plan.is_active.is_(True)))
                .values(is_active=False)
            )

            plan = Plan(user_id=user.id, name=plan_name, total_weeks=total_weeks, is_active=True)
            session.add(plan)
            session.flush()

            workout_by_index = {w.sequence_index: w for w in workouts}
            used_exercise_ids: set[int] = set()

            for index in range(days_per_week):
                w = workout_by_index.get(index)
                name = w.name if w and w.name.strip() else f"Day {index + 1}"
                pw = PlanWorkout(plan_id=plan.id, name=name, sequence_index=index)
                session.add(pw)
                session.flush()

                if not w:
                    continue

                for wex in w.exercises:
                    key = _exercise_name_key(wex.exercise_name)
                    ex_model = by_name.get(key)
                    if not ex_model:
                        ex_model = _get_or_create_exercise_by_name(session, wex.exercise_name)
                        by_name[key] = ex_model

                    protocol = ProgressionProtocol(wex.progression_protocol.value)
                    tier = ExerciseTier(wex.tier.value) if wex.tier else _protocol_default_tier(protocol)
                    amrap_last_set = (
                        _protocol_default_amrap(protocol)
                        if wex.amrap_last_set is None
                        else wex.amrap_last_set
                    )
                    training_max_ratio = (
                        _protocol_default_ratio(protocol)
                        if wex.training_max_ratio is None
                        else wex.training_max_ratio
                    )
                    weight_increment_kg = (
                        DEFAULT_WEIGHT_INCREMENT_KG
                        if wex.weight_increment_kg is None
                        else wex.weight_increment_kg
                    )
                    if weight_increment_kg <= 0:
                        raise ValueError("weight_increment_kg must be > 0")

                    target_weight_kg = wex.target_weight_kg
                    if protocol in (ProgressionProtocol.GZCLP_T1, ProgressionProtocol.GZCLP_T2):
                        baseline_1rm = baseline_by_name.get(key)
                        if baseline_1rm is None:
                            existing_baseline = _get_baseline(session, user.id, ex_model.id)
                            baseline_1rm = existing_baseline.baseline_1rm_kg if existing_baseline else None
                        if baseline_1rm is None:
                            raise ValueError(
                                f"baseline_1rm_kg required for {wex.exercise_name} when using {protocol.value}"
                            )
                        target_weight_kg = max(0.0, baseline_1rm * training_max_ratio)

                    target_weight_kg = _round_to_increment(target_weight_kg, weight_increment_kg)

                    session.add(
                        PlanWorkoutExercise(
                            plan_workout_id=pw.id,
                            exercise_id=ex_model.id,
                            sets=wex.sets,
                            reps=wex.reps,
                            target_weight_kg=target_weight_kg,
                            progression_type=ProgressionType(wex.progression_type.value),
                            progression_protocol=protocol,
                            tier=tier,
                            progression_value=wex.progression_value,
                            training_max_ratio=training_max_ratio,
                            amrap_last_set=amrap_last_set,
                            progression_meta={"weight_increment_kg": weight_increment_kg},
                        )
                    )
                    used_exercise_ids.add(ex_model.id)

            run = PlanRun(user_id=user.id, plan_id=plan.id, current_week=1, current_workout_index=0)
            session.add(run)
            session.flush()

            for exercise_id in used_exercise_ids:
                baseline = _get_baseline(session, user.id, exercise_id)
                if not baseline:
                    continue
                _upsert_plan_run_baseline(
                    session,
                    plan_run_id=run.id,
                    exercise_id=exercise_id,
                    baseline_1rm_kg=baseline.baseline_1rm_kg,
                )

            session.commit()

            return SeedResult(ok=True, plan_id=plan.id, plan_run_id=run.id)

    @strawberry.mutation
    def add_exercise_to_active_plan(self, input: AddExerciseToActivePlanInput) -> MutationResult:
        if input.sets <= 0 or input.reps <= 0:
            return MutationResult(ok=False, message="sets and reps must be > 0")
        if input.target_weight_kg < 0 or input.progression_value < 0:
            return MutationResult(ok=False, message="weights/progression must be >= 0")

        protocol = ProgressionProtocol(input.progression_protocol.value)
        requires_baseline = protocol in (ProgressionProtocol.GZCLP_T1, ProgressionProtocol.GZCLP_T2)
        if requires_baseline and (input.baseline_1rm_kg is None or input.baseline_1rm_kg <= 0):
            return MutationResult(ok=False, message="baseline_1rm_kg must be > 0 for GZCLP T1/T2")
        if input.baseline_1rm_kg is not None and input.baseline_1rm_kg <= 0:
            return MutationResult(ok=False, message="baseline_1rm_kg must be > 0")

        with db_session() as session:
            user = _get_default_user(session)
            ctx = _active_plan_context(session, user.id)
            if not ctx:
                return MutationResult(ok=False, message="No active plan. Create one first.")

            workout = session.scalar(
                select(PlanWorkout).where(
                    and_(
                        PlanWorkout.plan_id == ctx.plan.id,
                        PlanWorkout.sequence_index == input.workout_sequence_index,
                    )
                )
            )
            if not workout:
                return MutationResult(
                    ok=False,
                    message=f"Workout with sequence index {input.workout_sequence_index} not found in active plan",
                )

            tier = ExerciseTier(input.tier.value) if input.tier else _protocol_default_tier(protocol)
            amrap_last_set = (
                _protocol_default_amrap(protocol)
                if input.amrap_last_set is None
                else input.amrap_last_set
            )
            training_max_ratio = (
                _protocol_default_ratio(protocol)
                if input.training_max_ratio is None
                else input.training_max_ratio
            )
            weight_increment_kg = (
                DEFAULT_WEIGHT_INCREMENT_KG
                if input.weight_increment_kg is None
                else input.weight_increment_kg
            )
            if weight_increment_kg <= 0:
                return MutationResult(ok=False, message="weight_increment_kg must be > 0")

            exercise = _get_or_create_exercise_by_name(session, input.exercise_name)

            baseline = _get_baseline(session, user.id, exercise.id)
            if input.baseline_1rm_kg is not None:
                if baseline:
                    baseline.baseline_1rm_kg = input.baseline_1rm_kg
                else:
                    baseline = ExerciseBaseline(
                        user_id=user.id,
                        exercise_id=exercise.id,
                        baseline_1rm_kg=input.baseline_1rm_kg,
                    )
                    session.add(baseline)

            target_weight_kg = input.target_weight_kg
            if requires_baseline:
                baseline_value = float(input.baseline_1rm_kg or 0)
                target_weight_kg = max(0.0, baseline_value * training_max_ratio)
            target_weight_kg = _round_to_increment(target_weight_kg, weight_increment_kg)

            session.add(
                PlanWorkoutExercise(
                    plan_workout_id=workout.id,
                    exercise_id=exercise.id,
                    sets=input.sets,
                    reps=input.reps,
                    target_weight_kg=target_weight_kg,
                    progression_type=ProgressionType(input.progression_type.value),
                    progression_protocol=protocol,
                    tier=tier,
                    progression_value=input.progression_value,
                    training_max_ratio=training_max_ratio,
                    amrap_last_set=amrap_last_set,
                    progression_meta={"weight_increment_kg": weight_increment_kg},
                )
            )

            _get_or_create_run_state(
                session,
                plan_run_id=ctx.run.id,
                exercise_id=exercise.id,
                tier=tier,
                default_weight=target_weight_kg,
            )

            if not _get_plan_run_baseline(session, ctx.run.id, exercise.id):
                baseline_value = baseline.baseline_1rm_kg if baseline else None
                if baseline_value is not None:
                    _upsert_plan_run_baseline(
                        session,
                        plan_run_id=ctx.run.id,
                        exercise_id=exercise.id,
                        baseline_1rm_kg=baseline_value,
                    )

            session.commit()
            return MutationResult(ok=True, message=f"Added {exercise.name} to workout '{workout.name}'")

    @strawberry.mutation
    def add_day_to_active_plan(self, day_name: str | None = None) -> MutationResult:
        with db_session() as session:
            user = _get_default_user(session)
            ctx = _active_plan_context(session, user.id)
            if not ctx:
                return MutationResult(ok=False, message="No active plan. Create one first.")

            workouts = _get_workouts_in_plan(session, ctx.plan.id)
            next_index = len(workouts)
            name = day_name.strip() if day_name and day_name.strip() else f"Day {next_index + 1}"

            session.add(PlanWorkout(plan_id=ctx.plan.id, name=name, sequence_index=next_index))
            session.commit()
            return MutationResult(ok=True, message=f"Added {name}")

    @strawberry.mutation
    def remove_day_from_active_plan(self, sequence_index: int) -> MutationResult:
        if sequence_index < 0:
            return MutationResult(ok=False, message="sequence_index must be >= 0")

        with db_session() as session:
            user = _get_default_user(session)
            ctx = _active_plan_context(session, user.id)
            if not ctx:
                return MutationResult(ok=False, message="No active plan. Create one first.")

            workouts = _get_workouts_in_plan(session, ctx.plan.id)
            if len(workouts) <= 1:
                return MutationResult(ok=False, message="Plan must keep at least one day")

            workout = session.scalar(
                select(PlanWorkout).where(
                    and_(
                        PlanWorkout.plan_id == ctx.plan.id,
                        PlanWorkout.sequence_index == sequence_index,
                    )
                )
            )
            if not workout:
                return MutationResult(ok=False, message=f"Day {sequence_index} not found")

            has_exercises = session.scalar(
                select(PlanWorkoutExercise.id).where(PlanWorkoutExercise.plan_workout_id == workout.id)
            )
            if has_exercises:
                return MutationResult(
                    ok=False,
                    message="Day has exercises. Move them to another day before removing this day.",
                )

            removed_name = workout.name
            session.execute(delete(PlanWorkout).where(PlanWorkout.id == workout.id))

            remaining = session.scalars(
                select(PlanWorkout)
                .where(
                    and_(
                        PlanWorkout.plan_id == ctx.plan.id,
                        PlanWorkout.sequence_index > sequence_index,
                    )
                )
                .order_by(PlanWorkout.sequence_index.asc())
            ).all()
            for row in remaining:
                row.sequence_index -= 1

            run = ctx.run
            if run.current_workout_index > sequence_index:
                run.current_workout_index -= 1
            elif run.current_workout_index == sequence_index:
                run.current_workout_index = max(0, run.current_workout_index - 1)

            session.commit()
            return MutationResult(ok=True, message=f"Removed {removed_name}")

    @strawberry.mutation
    def move_exercise_to_day(
        self,
        plan_exercise_id: int,
        target_workout_sequence_index: int,
    ) -> MutationResult:
        if target_workout_sequence_index < 0:
            return MutationResult(ok=False, message="target_workout_sequence_index must be >= 0")

        with db_session() as session:
            user = _get_default_user(session)
            ctx = _active_plan_context(session, user.id)
            if not ctx:
                return MutationResult(ok=False, message="No active plan. Create one first.")

            row = session.get(PlanWorkoutExercise, plan_exercise_id)
            if not row:
                return MutationResult(ok=False, message="plan_exercise_id not found")

            source_workout = session.get(PlanWorkout, row.plan_workout_id)
            if not source_workout or source_workout.plan_id != ctx.plan.id:
                return MutationResult(ok=False, message="Exercise does not belong to active plan")

            target_workout = session.scalar(
                select(PlanWorkout).where(
                    and_(
                        PlanWorkout.plan_id == ctx.plan.id,
                        PlanWorkout.sequence_index == target_workout_sequence_index,
                    )
                )
            )
            if not target_workout:
                return MutationResult(
                    ok=False,
                    message=f"Target day {target_workout_sequence_index} not found",
                )

            if target_workout.id == source_workout.id:
                return MutationResult(ok=True, message="Exercise already on selected day")

            row.plan_workout_id = target_workout.id
            session.commit()
            return MutationResult(
                ok=True,
                message=f"Moved exercise to {target_workout.name}",
            )

    @strawberry.mutation
    def remove_exercise_from_active_plan(self, plan_exercise_id: int) -> MutationResult:
        with db_session() as session:
            user = _get_default_user(session)
            ctx = _active_plan_context(session, user.id)
            if not ctx:
                return MutationResult(ok=False, message="No active plan. Create one first.")

            row = session.get(PlanWorkoutExercise, plan_exercise_id)
            if not row:
                return MutationResult(ok=False, message="plan_exercise_id not found")

            workout = session.get(PlanWorkout, row.plan_workout_id)
            if not workout or workout.plan_id != ctx.plan.id:
                return MutationResult(ok=False, message="Exercise does not belong to active plan")

            exercise = session.get(Exercise, row.exercise_id)
            exercise_name = exercise.name if exercise else f"Exercise {row.exercise_id}"

            same_tier_filter = (
                PlanWorkoutExercise.tier.is_(None)
                if row.tier is None
                else PlanWorkoutExercise.tier == row.tier
            )
            state_tier_filter = (
                RunExerciseState.tier.is_(None)
                if row.tier is None
                else RunExerciseState.tier == row.tier
            )

            remaining_same_tier = session.scalar(
                select(PlanWorkoutExercise.id)
                .join(PlanWorkout, PlanWorkout.id == PlanWorkoutExercise.plan_workout_id)
                .where(
                    and_(
                        PlanWorkout.plan_id == ctx.plan.id,
                        PlanWorkoutExercise.exercise_id == row.exercise_id,
                        PlanWorkoutExercise.id != row.id,
                        same_tier_filter,
                    )
                )
            )
            remaining_any = session.scalar(
                select(PlanWorkoutExercise.id)
                .join(PlanWorkout, PlanWorkout.id == PlanWorkoutExercise.plan_workout_id)
                .where(
                    and_(
                        PlanWorkout.plan_id == ctx.plan.id,
                        PlanWorkoutExercise.exercise_id == row.exercise_id,
                        PlanWorkoutExercise.id != row.id,
                    )
                )
            )

            session.execute(delete(PlanWorkoutExercise).where(PlanWorkoutExercise.id == row.id))

            if not remaining_same_tier:
                session.execute(
                    delete(RunExerciseState).where(
                        and_(
                            RunExerciseState.plan_run_id == ctx.run.id,
                            RunExerciseState.exercise_id == row.exercise_id,
                            state_tier_filter,
                        )
                    )
                )

            if not remaining_any:
                session.execute(
                    delete(PlanRunBaseline).where(
                        and_(
                            PlanRunBaseline.plan_run_id == ctx.run.id,
                            PlanRunBaseline.exercise_id == row.exercise_id,
                        )
                    )
                )

            session.commit()
            return MutationResult(ok=True, message=f"Removed {exercise_name} from active plan")

    @strawberry.mutation
    def delete_active_plan(self) -> MutationResult:
        with db_session() as session:
            user = _get_default_user(session)
            ctx = _active_plan_context(session, user.id)
            if not ctx:
                return MutationResult(ok=False, message="No active plan to delete")

            runs = session.scalars(
                select(PlanRun).where(PlanRun.plan_id == ctx.plan.id)
            ).all()
            run_ids = [r.id for r in runs]

            if run_ids:
                session_ids = session.scalars(
                    select(WorkoutSession.id).where(WorkoutSession.plan_run_id.in_(run_ids))
                ).all()
            else:
                session_ids = []

            if session_ids:
                entry_ids = session.scalars(
                    select(SessionExerciseEntry.id).where(SessionExerciseEntry.session_id.in_(session_ids))
                ).all()
            else:
                entry_ids = []

            if entry_ids:
                session.execute(delete(SessionSet).where(SessionSet.entry_id.in_(entry_ids)))
                session.execute(delete(SessionExerciseEntry).where(SessionExerciseEntry.id.in_(entry_ids)))

            if session_ids:
                session.execute(delete(HeartRateSample).where(HeartRateSample.session_id.in_(session_ids)))
                session.execute(delete(WorkoutExport).where(WorkoutExport.session_id.in_(session_ids)))
                session.execute(delete(WorkoutSession).where(WorkoutSession.id.in_(session_ids)))

            if run_ids:
                session.execute(delete(RunExerciseState).where(RunExerciseState.plan_run_id.in_(run_ids)))
                session.execute(delete(PlanRunBaseline).where(PlanRunBaseline.plan_run_id.in_(run_ids)))
                session.execute(delete(ResetEvent).where(ResetEvent.plan_run_id.in_(run_ids)))
                session.execute(delete(PlanRun).where(PlanRun.id.in_(run_ids)))

            workout_ids = session.scalars(
                select(PlanWorkout.id).where(PlanWorkout.plan_id == ctx.plan.id)
            ).all()
            if workout_ids:
                session.execute(
                    delete(PlanWorkoutExercise).where(PlanWorkoutExercise.plan_workout_id.in_(workout_ids))
                )
                session.execute(delete(PlanWorkout).where(PlanWorkout.id.in_(workout_ids)))

            session.execute(delete(Plan).where(Plan.id == ctx.plan.id))
            session.commit()
            return MutationResult(ok=True, message=f"Deleted plan '{ctx.plan.name}'")

    @strawberry.mutation
    def start_workout(self, plan_workout_id: int | None = None) -> WorkoutSessionType:
        with db_session() as session:
            user = _get_default_user(session)

            existing = session.scalar(
                select(WorkoutSession)
                .where(
                    and_(
                        WorkoutSession.user_id == user.id,
                        WorkoutSession.status == WorkoutSessionStatus.IN_PROGRESS,
                    )
                )
                .order_by(WorkoutSession.started_at.desc())
            )
            if existing:
                return _build_session_type(session, existing)

            ctx = _active_plan_context(session, user.id)
            if not ctx:
                raise ValueError("No active plan run found. Seed a plan first.")

            workouts = _get_workouts_in_plan(session, ctx.plan.id)
            if not workouts:
                raise ValueError("Active plan has no workouts.")

            if plan_workout_id is not None:
                workout = session.get(PlanWorkout, plan_workout_id)
                if workout is None or workout.plan_id != ctx.plan.id:
                    raise ValueError("plan_workout_id not in active plan")
            else:
                workout_index = ctx.run.current_workout_index
                if workout_index >= len(workouts):
                    workout_index = 0
                workout = workouts[workout_index]

            templates = _get_plan_templates_for_workout(session, workout.id)

            needs_reset_exercises: list[str] = []
            for t in templates:
                baseline = _get_baseline(session, user.id, t.exercise_id)
                default_weight = initial_weight_for_template(
                    t,
                    baseline.baseline_1rm_kg if baseline else None,
                )
                state = _get_or_create_run_state(
                    session,
                    plan_run_id=ctx.run.id,
                    exercise_id=t.exercise_id,
                    tier=t.tier,
                    default_weight=default_weight,
                )
                if not state.needs_new_1rm:
                    continue

                if baseline is None:
                    exercise = session.get(Exercise, t.exercise_id)
                    exercise_name = exercise.name if exercise else f"Exercise {t.exercise_id}"
                    needs_reset_exercises.append(_exercise_label(exercise_name, t.tier))
                    continue

                state.current_weight_kg = initial_weight_for_template(t, baseline.baseline_1rm_kg)
                state.failure_count = 0
                state.needs_new_1rm = False

            if needs_reset_exercises:
                names = ", ".join(needs_reset_exercises)
                raise ValueError(
                    f"Update 1RM before continuing for: {names}. "
                    "Go to Settings and set the missing 1RM values, then start workout again."
                )

            ws = WorkoutSession(
                user_id=user.id,
                plan_run_id=ctx.run.id,
                plan_workout_id=workout.id,
                status=WorkoutSessionStatus.IN_PROGRESS,
            )
            session.add(ws)
            session.flush()

            for t in templates:
                baseline = _get_baseline(session, user.id, t.exercise_id)
                default_weight = initial_weight_for_template(
                    t,
                    baseline.baseline_1rm_kg if baseline else None,
                )
                state = _get_or_create_run_state(
                    session,
                    plan_run_id=ctx.run.id,
                    exercise_id=t.exercise_id,
                    tier=t.tier,
                    default_weight=default_weight,
                )
                prescription = exercise_prescription(t, state)

                entry = SessionExerciseEntry(
                    session_id=ws.id,
                    plan_workout_exercise_id=t.id,
                    exercise_id=t.exercise_id,
                    planned_sets=prescription.sets,
                    planned_reps=prescription.reps,
                    planned_weight_kg=state.current_weight_kg,
                )
                session.add(entry)
                session.flush()

                for index, item in enumerate(prescription.set_prescriptions, start=1):
                    session.add(
                        SessionSet(
                            entry_id=entry.id,
                            set_index=index,
                            target_reps=item.target_reps,
                            is_amrap=item.is_amrap,
                            reps_completed=None,
                            weight_kg=state.current_weight_kg,
                            completed=False,
                        )
                    )

            session.commit()
            return _build_session_type(session, ws)

    @strawberry.mutation
    def complete_set(
        self,
        session_set_id: int,
        reps_completed: int,
        weight_kg: float | None = None,
        duration_seconds: int | None = None,
    ) -> SessionSetType:
        if reps_completed < 0:
            raise ValueError("reps_completed must be >= 0")
        if duration_seconds is not None and duration_seconds < 0:
            raise ValueError("duration_seconds must be >= 0")

        with db_session() as session:
            sset = session.get(SessionSet, session_set_id)
            if not sset:
                raise ValueError("session_set_id not found")

            sset.reps_completed = reps_completed
            sset.weight_kg = weight_kg if weight_kg is not None else sset.weight_kg
            sset.duration_seconds = duration_seconds
            sset.completed = True
            sset.completed_at = _now_utc()
            session.commit()

            return SessionSetType(
                id=sset.id,
                set_index=sset.set_index,
                target_reps=sset.target_reps,
                is_amrap=sset.is_amrap,
                reps_completed=sset.reps_completed,
                weight_kg=sset.weight_kg,
                duration_seconds=sset.duration_seconds,
                completed=sset.completed,
                completed_at=sset.completed_at,
            )

    @strawberry.mutation
    def finish_workout(self, session_id: int) -> WorkoutSessionType:
        with db_session() as session:
            ws = session.get(WorkoutSession, session_id)
            if not ws:
                raise ValueError("session_id not found")
            if ws.status != WorkoutSessionStatus.IN_PROGRESS:
                return _build_session_type(session, ws)

            ws.status = WorkoutSessionStatus.COMPLETED
            ws.finished_at = _now_utc()

            run = session.get(PlanRun, ws.plan_run_id)
            if not run:
                raise ValueError("Plan run not found for workout session")

            entries = session.scalars(
                select(SessionExerciseEntry).where(SessionExerciseEntry.session_id == ws.id)
            ).all()

            for entry in entries:
                template = session.get(PlanWorkoutExercise, entry.plan_workout_exercise_id)
                if not template:
                    continue

                sets = session.scalars(
                    select(SessionSet)
                    .where(SessionSet.entry_id == entry.id)
                    .order_by(SessionSet.set_index.asc())
                ).all()

                estimated_1rm = _estimated_1rm_from_sets(sets)
                baseline = _get_baseline(session, ws.user_id, entry.exercise_id)
                if estimated_1rm is not None:
                    if baseline is None:
                        baseline = ExerciseBaseline(
                            user_id=ws.user_id,
                            exercise_id=entry.exercise_id,
                            baseline_1rm_kg=estimated_1rm,
                        )
                        session.add(baseline)
                    elif estimated_1rm > baseline.baseline_1rm_kg:
                        baseline.baseline_1rm_kg = estimated_1rm

                baseline_1rm_kg = baseline.baseline_1rm_kg if baseline else None
                state = _get_or_create_run_state(
                    session,
                    plan_run_id=run.id,
                    exercise_id=entry.exercise_id,
                    tier=template.tier,
                    default_weight=entry.planned_weight_kg,
                )

                result = evaluate_progression(
                    template=template,
                    state=state,
                    baseline_1rm_kg=baseline_1rm_kg,
                    session_sets=sets,
                )

                if result.needs_new_1rm and baseline_1rm_kg is not None:
                    state.current_weight_kg = initial_weight_for_template(template, baseline_1rm_kg)
                    state.failure_count = 0
                    state.needs_new_1rm = False
                else:
                    state.current_weight_kg = result.next_weight_kg
                    state.failure_count = result.failure_count
                    state.needs_new_1rm = result.needs_new_1rm

                state.last_completed_at = _now_utc()

            plan = session.get(Plan, run.plan_id)
            workouts = _get_workouts_in_plan(session, run.plan_id)
            if workouts:
                run.current_workout_index += 1
                if run.current_workout_index >= len(workouts):
                    run.current_workout_index = 0
                    run.current_week += 1

                    if plan and plan.total_weeks is not None and run.current_week > plan.total_weeks:
                        run.status = PlanRunStatus.COMPLETED
                        run.completed_at = _now_utc()

            session.commit()

            pref = session.scalar(select(UserPreference).where(UserPreference.user_id == ws.user_id))
            should_auto_send = bool(pref and pref.strava_auto_send_on_finish)
            if should_auto_send:
                _send_workout_to_strava_with_session(
                    session,
                    user_id=ws.user_id,
                    workout_session=ws,
                )

            return _build_session_type(session, ws)

    @strawberry.mutation
    def set_exercise_one_rep_max(
        self,
        exercise_id: int,
        one_rep_max_kg: float,
    ) -> MutationResult:
        if one_rep_max_kg <= 0:
            raise ValueError("one_rep_max_kg must be > 0")

        with db_session() as session:
            user = _get_default_user(session)
            baseline = _get_baseline(session, user.id, exercise_id)
            if baseline:
                baseline.baseline_1rm_kg = one_rep_max_kg
            else:
                baseline = ExerciseBaseline(
                    user_id=user.id,
                    exercise_id=exercise_id,
                    baseline_1rm_kg=one_rep_max_kg,
                )
                session.add(baseline)

            ctx = _active_plan_context(session, user.id)
            if ctx:
                templates = session.scalars(
                    select(PlanWorkoutExercise)
                    .join(PlanWorkout, PlanWorkout.id == PlanWorkoutExercise.plan_workout_id)
                    .where(
                        and_(
                            PlanWorkout.plan_id == ctx.plan.id,
                            PlanWorkoutExercise.exercise_id == exercise_id,
                        )
                    )
                ).all()

                unique_templates: dict[tuple[int, ExerciseTier | None], PlanWorkoutExercise] = {}
                for template in templates:
                    key = (template.exercise_id, template.tier)
                    unique_templates.setdefault(key, template)

                for template in unique_templates.values():
                    state = _get_or_create_run_state(
                        session,
                        plan_run_id=ctx.run.id,
                        exercise_id=exercise_id,
                        tier=template.tier,
                        default_weight=initial_weight_for_template(template, one_rep_max_kg),
                    )
                    state.current_weight_kg = initial_weight_for_template(template, one_rep_max_kg)
                    state.failure_count = 0
                    state.needs_new_1rm = False

            session.commit()

            exercise = session.get(Exercise, exercise_id)
            exercise_name = exercise.name if exercise else f"Exercise {exercise_id}"
            return MutationResult(ok=True, message=f"Updated 1RM for {exercise_name}")

    @strawberry.mutation
    def reset_to_baseline(
        self,
        training_max_ratio: float = 1.0,
        baseline_overrides: list[BaselineInput] | None = None,
    ) -> ResetResult:
        with db_session() as session:
            user = _get_default_user(session)
            ctx = _active_plan_context(session, user.id)
            if not ctx:
                return ResetResult(ok=False, message="No active plan run to reset", updated_exercise_count=0)

            if training_max_ratio <= 0:
                return ResetResult(
                    ok=False,
                    message="training_max_ratio must be > 0",
                    updated_exercise_count=0,
                )

            for item in (baseline_overrides or []):
                if item.baseline_1rm_kg <= 0:
                    return ResetResult(
                        ok=False,
                        message=f"baseline_1rm_kg must be > 0 for exercise_id={item.exercise_id}",
                        updated_exercise_count=0,
                    )

                row = _get_baseline(session, user.id, item.exercise_id)
                if row:
                    row.baseline_1rm_kg = item.baseline_1rm_kg
                else:
                    session.add(
                        ExerciseBaseline(
                            user_id=user.id,
                            exercise_id=item.exercise_id,
                            baseline_1rm_kg=item.baseline_1rm_kg,
                        )
                    )

                _upsert_plan_run_baseline(
                    session,
                    plan_run_id=ctx.run.id,
                    exercise_id=item.exercise_id,
                    baseline_1rm_kg=item.baseline_1rm_kg,
                )

            workouts = _get_workouts_in_plan(session, ctx.plan.id)
            workout_ids = [w.id for w in workouts]
            templates = session.scalars(
                select(PlanWorkoutExercise).where(PlanWorkoutExercise.plan_workout_id.in_(workout_ids))
            ).all()

            template_by_track: dict[tuple[int, ExerciseTier | None], PlanWorkoutExercise] = {}
            for t in templates:
                template_by_track.setdefault((t.exercise_id, t.tier), t)

            updates = 0
            for (exercise_id, tier), template in template_by_track.items():
                run_baseline = _get_plan_run_baseline(session, ctx.run.id, exercise_id)
                if not run_baseline:
                    baseline = _get_baseline(session, user.id, exercise_id)
                    if baseline:
                        run_baseline = _upsert_plan_run_baseline(
                            session,
                            plan_run_id=ctx.run.id,
                            exercise_id=exercise_id,
                            baseline_1rm_kg=baseline.baseline_1rm_kg,
                        )

                baseline_1rm_kg = run_baseline.baseline_1rm_kg if run_baseline else None
                reset_weight = initial_weight_for_template(template, baseline_1rm_kg)

                state = _get_or_create_run_state(
                    session,
                    plan_run_id=ctx.run.id,
                    exercise_id=exercise_id,
                    tier=tier,
                    default_weight=reset_weight,
                )

                state.current_weight_kg = reset_weight
                state.failure_count = 0
                state.needs_new_1rm = False
                state.last_completed_at = None
                updates += 1

            ctx.run.current_week = 1
            ctx.run.current_workout_index = 0

            session.add(
                ResetEvent(
                    user_id=user.id,
                    plan_run_id=ctx.run.id,
                    training_max_ratio=training_max_ratio,
                )
            )

            session.commit()
            return ResetResult(
                ok=True,
                message="Progress reset to saved plan-start 1RM values",
                updated_exercise_count=updates,
            )


schema = strawberry.Schema(query=Query, mutation=Mutation)
