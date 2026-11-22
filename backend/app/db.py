from __future__ import annotations

from contextlib import contextmanager
from pathlib import Path

from sqlalchemy import create_engine
from sqlalchemy.engine import make_url
from sqlalchemy.schema import CreateIndex, CreateTable
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

from .config import DATABASE_URL


class Base(DeclarativeBase):
    pass


is_sqlite = DATABASE_URL.startswith("sqlite")
if is_sqlite:
    sqlite_path = make_url(DATABASE_URL).database
    if sqlite_path and sqlite_path != ":memory:":
        Path(sqlite_path).parent.mkdir(parents=True, exist_ok=True)

engine = create_engine(
    DATABASE_URL,
    connect_args={"check_same_thread": False} if is_sqlite else {},
)
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False, expire_on_commit=False)


def _sqlite_table_columns(conn, table_name: str) -> list[str]:
    rows = conn.exec_driver_sql(f"PRAGMA table_info({table_name})").fetchall()
    return [row[1] for row in rows]


def _sqlite_table_sql(conn, table_name: str) -> str | None:
    row = conn.exec_driver_sql(
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = :name",
        {"name": table_name},
    ).fetchone()
    if not row:
        return None
    return row[0]


def _sqlite_table_exists(conn, table_name: str) -> bool:
    row = conn.exec_driver_sql(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = :name",
        {"name": table_name},
    ).fetchone()
    return bool(row)


def _migrate_exercises_catalog_item_id(conn) -> None:
    if not _sqlite_table_exists(conn, "exercises"):
        return
    columns = _sqlite_table_columns(conn, "exercises")
    if "catalog_item_id" not in columns:
        conn.exec_driver_sql("ALTER TABLE exercises ADD COLUMN catalog_item_id INTEGER")
    conn.exec_driver_sql(
        "CREATE INDEX IF NOT EXISTS ix_exercises_catalog_item_id ON exercises (catalog_item_id)"
    )


def _migrate_session_sets_duration_seconds(conn) -> None:
    if not _sqlite_table_exists(conn, "session_sets"):
        return
    columns = _sqlite_table_columns(conn, "session_sets")
    if "duration_seconds" not in columns:
        conn.exec_driver_sql("ALTER TABLE session_sets ADD COLUMN duration_seconds INTEGER")


def _migrate_oauth_connections_provider_username(conn) -> None:
    if not _sqlite_table_exists(conn, "oauth_connections"):
        return
    columns = _sqlite_table_columns(conn, "oauth_connections")
    if "provider_username" not in columns:
        conn.exec_driver_sql("ALTER TABLE oauth_connections ADD COLUMN provider_username VARCHAR(120)")


def _migrate_run_exercise_states_tier(conn) -> None:
    columns = _sqlite_table_columns(conn, "run_exercise_states")
    if not columns:
        return

    table_sql = (_sqlite_table_sql(conn, "run_exercise_states") or "").upper()
    has_tier_column = "tier" in columns
    has_tier_unique = "UNIQUE (PLAN_RUN_ID, EXERCISE_ID, TIER)" in table_sql

    if has_tier_column and has_tier_unique:
        return

    conn.exec_driver_sql("ALTER TABLE run_exercise_states RENAME TO run_exercise_states_old")
    conn.exec_driver_sql(
        """
        CREATE TABLE run_exercise_states (
            id INTEGER NOT NULL,
            plan_run_id INTEGER NOT NULL,
            exercise_id INTEGER NOT NULL,
            tier VARCHAR(2),
            current_weight_kg FLOAT NOT NULL,
            failure_count INTEGER NOT NULL,
            needs_new_1rm BOOLEAN NOT NULL,
            last_completed_at DATETIME,
            PRIMARY KEY (id),
            CONSTRAINT uq_run_exercise_state UNIQUE (plan_run_id, exercise_id, tier),
            FOREIGN KEY(plan_run_id) REFERENCES plan_runs (id),
            FOREIGN KEY(exercise_id) REFERENCES exercises (id)
        )
        """
    )

    old_columns = _sqlite_table_columns(conn, "run_exercise_states_old")
    old_has_tier = "tier" in old_columns

    if old_has_tier:
        conn.exec_driver_sql(
            """
            INSERT INTO run_exercise_states (
                id, plan_run_id, exercise_id, tier, current_weight_kg, failure_count, needs_new_1rm, last_completed_at
            )
            SELECT
                id, plan_run_id, exercise_id, tier, current_weight_kg, failure_count, needs_new_1rm, last_completed_at
            FROM run_exercise_states_old
            """
        )
    else:
        conn.exec_driver_sql(
            """
            INSERT INTO run_exercise_states (
                id, plan_run_id, exercise_id, tier, current_weight_kg, failure_count, needs_new_1rm, last_completed_at
            )
            SELECT
                id, plan_run_id, exercise_id, NULL, current_weight_kg, failure_count, needs_new_1rm, last_completed_at
            FROM run_exercise_states_old
            """
        )

    conn.exec_driver_sql("DROP TABLE run_exercise_states_old")
    conn.exec_driver_sql(
        "CREATE INDEX IF NOT EXISTS ix_run_exercise_states_plan_run_id ON run_exercise_states (plan_run_id)"
    )
    conn.exec_driver_sql(
        "CREATE INDEX IF NOT EXISTS ix_run_exercise_states_exercise_id ON run_exercise_states (exercise_id)"
    )


def _migrate_workout_sessions_client_id(conn) -> None:
    if not _sqlite_table_exists(conn, "workout_sessions"):
        return
    columns = _sqlite_table_columns(conn, "workout_sessions")
    if "client_id" not in columns:
        conn.exec_driver_sql("ALTER TABLE workout_sessions ADD COLUMN client_id VARCHAR(64)")
    conn.exec_driver_sql(
        "CREATE UNIQUE INDEX IF NOT EXISTS ix_workout_sessions_client_id ON workout_sessions (client_id)"
    )


def _sqlite_column_is_not_null(conn, table_name: str, column: str) -> bool:
    for row in conn.exec_driver_sql(f"PRAGMA table_info({table_name})").fetchall():
        if row[1] == column:
            return bool(row[3])
    return False


def _rebuild_table_from_model(conn, table) -> None:
    """Recreate a table to match its SQLAlchemy model (SQLite can't ALTER column nullability).

    Follows SQLite's recommended procedure: create the new table under a temporary name, copy the
    shared columns, drop the old table, then rename. Other tables' foreign keys keep referring to
    the original name, so they stay valid. Foreign key enforcement is off (SQLite default).
    """
    name = table.name
    temp = f"{name}__rebuild"
    old_columns = set(_sqlite_table_columns(conn, name))
    shared = [c.name for c in table.columns if c.name in old_columns]
    column_list = ", ".join(shared)

    conn.exec_driver_sql(f"DROP TABLE IF EXISTS {temp}")
    create_sql = str(CreateTable(table).compile(conn.engine)).strip()
    create_sql = create_sql.replace(f"CREATE TABLE {name} ", f"CREATE TABLE {temp} ", 1)
    conn.exec_driver_sql(create_sql)
    conn.exec_driver_sql(f"INSERT INTO {temp} ({column_list}) SELECT {column_list} FROM {name}")
    conn.exec_driver_sql(f"DROP TABLE {name}")
    conn.exec_driver_sql(f"ALTER TABLE {temp} RENAME TO {name}")
    for index in table.indexes:
        conn.exec_driver_sql(str(CreateIndex(index).compile(conn.engine)))


def _migrate_flexible_workouts(conn) -> None:
    """Allow ad-hoc workouts and mid-workout exercise changes (nullable plan links), plus the
    new name / progression_snapshot / skipped columns."""
    from .models import SessionExerciseEntry, WorkoutSession  # avoid import cycle at module load

    if _sqlite_table_exists(conn, "workout_sessions"):
        columns = _sqlite_table_columns(conn, "workout_sessions")
        if (
            _sqlite_column_is_not_null(conn, "workout_sessions", "plan_run_id")
            or "name" not in columns
            or "progression_snapshot" not in columns
        ):
            _rebuild_table_from_model(conn, WorkoutSession.__table__)

    if _sqlite_table_exists(conn, "session_exercise_entries") and _sqlite_column_is_not_null(
        conn, "session_exercise_entries", "plan_workout_exercise_id"
    ):
        _rebuild_table_from_model(conn, SessionExerciseEntry.__table__)

    if _sqlite_table_exists(conn, "session_sets") and "skipped" not in _sqlite_table_columns(conn, "session_sets"):
        conn.exec_driver_sql("ALTER TABLE session_sets ADD COLUMN skipped BOOLEAN NOT NULL DEFAULT 0")


def _migrate_users_password_hash(conn) -> None:
    if not _sqlite_table_exists(conn, "users"):
        return
    if "password_hash" not in _sqlite_table_columns(conn, "users"):
        conn.exec_driver_sql("ALTER TABLE users ADD COLUMN password_hash VARCHAR(255)")


def _migrate_plan_active_flags(conn) -> None:
    """Make `plans.is_active` the source of truth for the active plan.

    Older databases resolved the active plan from the newest ACTIVE plan run. Ensure each user
    has at most one active plan, and that a user whose active plan was previously implied by a
    plan run gets that plan flagged as active.
    """
    if not _sqlite_table_exists(conn, "plans") or not _sqlite_table_exists(conn, "plan_runs"):
        return

    user_ids = [row[0] for row in conn.exec_driver_sql("SELECT DISTINCT user_id FROM plans").fetchall()]
    for user_id in user_ids:
        active_ids = [
            row[0]
            for row in conn.exec_driver_sql(
                "SELECT id FROM plans WHERE user_id = ? AND is_active = 1 ORDER BY id DESC",
                (user_id,),
            ).fetchall()
        ]
        if len(active_ids) > 1:
            keep_id = active_ids[0]
            conn.exec_driver_sql(
                "UPDATE plans SET is_active = 0 WHERE user_id = ? AND id != ?",
                (user_id, keep_id),
            )
            continue
        if active_ids:
            continue

        row = conn.exec_driver_sql(
            """
            SELECT pr.plan_id FROM plan_runs pr
            JOIN plans p ON p.id = pr.plan_id
            WHERE pr.user_id = ? AND pr.status = 'ACTIVE'
            ORDER BY pr.id DESC LIMIT 1
            """,
            (user_id,),
        ).fetchone()
        if row:
            conn.exec_driver_sql("UPDATE plans SET is_active = 1 WHERE id = ?", (row[0],))


def apply_sqlite_migrations() -> None:
    if not is_sqlite:
        return

    with engine.begin() as conn:
        _migrate_exercises_catalog_item_id(conn)
        _migrate_session_sets_duration_seconds(conn)
        _migrate_oauth_connections_provider_username(conn)
        _migrate_run_exercise_states_tier(conn)
        _migrate_plan_active_flags(conn)
        _migrate_workout_sessions_client_id(conn)
        _migrate_users_password_hash(conn)
        _migrate_flexible_workouts(conn)


@contextmanager
def db_session() -> Session:
    session = SessionLocal()
    try:
        yield session
    finally:
        session.close()
