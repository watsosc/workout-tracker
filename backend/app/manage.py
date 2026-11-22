"""Admin commands.

    python -m app.manage set-password [--username NAME]   # set/change the login (prompts for password)
    python -m app.manage sign-out-everywhere              # revoke all sessions (e.g. lost phone)
    python -m app.manage disable-login                    # remove the password (API becomes open)
"""

from __future__ import annotations

import argparse
import getpass
import sys

from . import auth
from .db import db_session
from .main import on_startup
from .models import User
from .schema import DEFAULT_USER_ID

MIN_PASSWORD_LENGTH = 8


def _prompt_password() -> str:
    while True:
        password = getpass.getpass("New password: ")
        if len(password) < MIN_PASSWORD_LENGTH:
            print(f"Use at least {MIN_PASSWORD_LENGTH} characters.")
            continue
        if getpass.getpass("Repeat password: ") != password:
            print("Passwords didn't match.")
            continue
        return password


def set_password(username: str | None, password: str | None = None) -> None:
    with db_session() as session:
        user = session.get(User, DEFAULT_USER_ID)
        assert user is not None
        name = (username or input(f"Username [{user.name}]: ").strip() or user.name).strip()
        user.name = name
        user.password_hash = auth.hash_password(password if password is not None else _prompt_password())
        revoked = auth.revoke_all_sessions(session, user.id)
        session.commit()
    print(f"Login set for '{name}'. Sign-in is now required." + (f" Signed out {revoked} session(s)." if revoked else ""))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m app.manage", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sp = sub.add_parser("set-password", help="set or change the login username/password")
    sp.add_argument("--username")
    sub.add_parser("sign-out-everywhere", help="revoke every session")
    sub.add_parser("disable-login", help="remove the password so the API no longer requires sign-in")
    args = parser.parse_args(argv)

    on_startup()  # ensure tables/migrations/default user exist

    if args.command == "set-password":
        set_password(args.username)
    elif args.command == "sign-out-everywhere":
        with db_session() as session:
            count = auth.revoke_all_sessions(session, DEFAULT_USER_ID)
            session.commit()
        print(f"Signed out {count} session(s).")
    elif args.command == "disable-login":
        with db_session() as session:
            user = session.get(User, DEFAULT_USER_ID)
            user.password_hash = None
            auth.revoke_all_sessions(session, DEFAULT_USER_ID)
            session.commit()
        print("Login disabled: the API is open again.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
