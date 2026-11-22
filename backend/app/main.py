from __future__ import annotations

import logging

from fastapi import FastAPI, Request, Response
from strawberry.fastapi import GraphQLRouter

from . import auth
from .config import DEFAULT_USER_NAME
from .db import Base, apply_sqlite_migrations, db_session, engine
from .models import User
from .schema import DEFAULT_USER_ID, schema

logger = logging.getLogger("workout.api")


def _session_token(request: Request) -> str | None:
    header = request.headers.get("authorization", "")
    scheme, _, value = header.partition(" ")
    if scheme.lower() == "bearer" and value.strip():
        return value.strip()
    return request.cookies.get(auth.SESSION_COOKIE) or None


async def get_context(request: Request, response: Response) -> dict:
    """Resolve the caller's session. Merged into Strawberry's default context (request/response)."""
    token = _session_token(request)
    with db_session() as session:
        required = auth.auth_required(session)
        row = auth.resolve_session(session, token)
        user = session.get(User, row.user_id) if row else None
        return {
            "auth_required": required,
            "user_id": user.id if user else None,
            "username": user.name if user else None,
            "session_token": token if row else None,
        }


app = FastAPI(title="Workout App API")
app.include_router(
    GraphQLRouter(schema, context_getter=get_context, graphql_ide="graphiql"),
    prefix="/graphql",
)


@app.on_event("startup")
def on_startup() -> None:
    Base.metadata.create_all(bind=engine)
    apply_sqlite_migrations()
    with db_session() as session:
        if not session.get(User, DEFAULT_USER_ID):
            session.add(User(id=DEFAULT_USER_ID, name=DEFAULT_USER_NAME))
            session.commit()
        if not auth.auth_required(session):
            logger.warning(
                "No login password is set: the API is open to anyone who can reach it. "
                "Run `python -m app.manage set-password` to require sign-in."
            )


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}
