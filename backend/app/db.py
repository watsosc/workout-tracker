from __future__ import annotations

from contextlib import contextmanager
from pathlib import Path

from sqlalchemy import create_engine
from sqlalchemy.engine import make_url
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


def apply_sqlite_migrations() -> None:
    if not is_sqlite:
        return

    with engine.begin() as conn:
        _migrate_exercises_catalog_item_id(conn)
        _migrate_run_exercise_states_tier(conn)


@contextmanager
def db_session() -> Session:
    session = SessionLocal()
    try:
        yield session
    finally:
        session.close()
