from __future__ import annotations

from fastapi import FastAPI
from strawberry.fastapi import GraphQLRouter

from .config import DEFAULT_USER_NAME
from .db import Base, apply_sqlite_migrations, db_session, engine
from .models import User
from .schema import DEFAULT_USER_ID, schema


app = FastAPI(title="Workout App API")
app.include_router(GraphQLRouter(schema, graphql_ide="graphiql"), prefix="/graphql")


@app.on_event("startup")
def on_startup() -> None:
    Base.metadata.create_all(bind=engine)
    apply_sqlite_migrations()
    with db_session() as session:
        if not session.get(User, DEFAULT_USER_ID):
            session.add(User(id=DEFAULT_USER_ID, name=DEFAULT_USER_NAME))
            session.commit()


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}
