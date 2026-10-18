"""Command-line administration.

The first administrator cannot be created from the web UI (nobody can sign in
yet), so it is created here:

    python -m app.cli create-admin

Other handy commands::

    python -m app.cli create-user jane        # an ordinary member
    python -m app.cli list-users
    python -m app.cli set-password jane
    python -m app.cli delete-user jane
"""

from __future__ import annotations

import argparse
import getpass
import sys

from . import models  # noqa: F401  (registers every model on Base.metadata)
from .database import Base, SessionLocal, engine, ensure_schema
from .services import auth
from .services.seed import seed_defaults


def _prepare_database() -> None:
    Base.metadata.create_all(bind=engine)
    ensure_schema()
    db = SessionLocal()
    try:
        seed_defaults(db)
    finally:
        db.close()


def _interactive() -> bool:
    try:
        return sys.stdin is not None and sys.stdin.isatty()
    except (AttributeError, ValueError):
        return False


def _ask_username(given: str | None) -> str:
    if given:
        return given.strip()
    if not _interactive():
        raise SystemExit("A username is required (pass it as an argument).")
    return input("Username: ").strip()


def _ask_password(*, confirm: bool = True) -> str:
    if not _interactive():
        raise SystemExit("A password is required (pass --password).")
    password = getpass.getpass("Password: ")
    if confirm:
        again = getpass.getpass("Repeat password: ")
        if password != again:
            raise SystemExit("Passwords do not match.")
    problem = auth.password_problem(password)
    if problem:
        raise SystemExit(problem)
    return password


def _ask_display_name(given: str | None) -> str | None:
    if given is not None:
        return given.strip() or None
    if not _interactive():
        return None
    value = input("Display name (optional): ").strip()
    return value or None


# --------------------------------------------------------------------------- #
# Commands
# --------------------------------------------------------------------------- #
def cmd_create(args, role: str) -> int:
    _prepare_database()
    db = SessionLocal()
    try:
        username = _ask_username(args.username)
        if role == "admin" and auth.count_active_admins(db) and not args.force:
            print(
                "An administrator already exists. Re-run with --force to add another.",
                file=sys.stderr,
            )
            return 1
        password = args.password or _ask_password()
        display_name = _ask_display_name(args.display_name)
        try:
            user = auth.create_user(
                db,
                username=username,
                password=password,
                role=role,
                display_name=display_name,
            )
        except ValueError as exc:
            print(f"Error: {exc}", file=sys.stderr)
            return 1
        print(f"Created {user.role} “{user.username}” (id {user.id}).")
    finally:
        db.close()
    return 0


def cmd_list(args) -> int:
    _prepare_database()
    db = SessionLocal()
    try:
        users = auth.list_users(db)
        if not users:
            print("No users yet. Create one with: python -m app.cli create-admin")
            return 0
        for user in users:
            state = "active" if user.is_active else "disabled"
            last = user.last_login_at.isoformat() if user.last_login_at else "never"
            print(f"{user.id:>3}  {user.username:<24} {user.role:<7} {state:<9} last login: {last}")
    finally:
        db.close()
    return 0


def cmd_set_password(args) -> int:
    _prepare_database()
    db = SessionLocal()
    try:
        user = auth.get_user_by_username(db, args.username)
        if user is None:
            print(f"No such user: {args.username}", file=sys.stderr)
            return 1
        password = args.password or _ask_password()
        try:
            auth.set_password(db, user, password)
        except ValueError as exc:
            print(f"Error: {exc}", file=sys.stderr)
            return 1
        print(f"Password updated for “{user.username}”. Their sessions were signed out.")
    finally:
        db.close()
    return 0


def cmd_delete_user(args) -> int:
    _prepare_database()
    db = SessionLocal()
    try:
        user = auth.get_user_by_username(db, args.username)
        if user is None:
            print(f"No such user: {args.username}", file=sys.stderr)
            return 1
        auth.delete_user(db, user)
        print(f"Deleted “{args.username}”.")
    except ValueError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    finally:
        db.close()
    return 0


# --------------------------------------------------------------------------- #
# Argument parsing
# --------------------------------------------------------------------------- #
def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="python -m app.cli", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    def add_create(name: str, role: str, help_text: str) -> None:
        p = sub.add_parser(name, help=help_text)
        p.add_argument("username", nargs="?", help="Username (prompted if omitted)")
        p.add_argument("--display-name", help="Friendly name shown in the UI")
        p.add_argument(
            "--password",
            help="Password (avoid on shared machines; prompted if omitted)",
        )
        if role == "admin":
            p.add_argument(
                "--force", action="store_true", help="Allow a second administrator"
            )
        p.set_defaults(func=lambda a, role=role: cmd_create(a, role))

    add_create("create-admin", "admin", "Create an administrator account")
    add_create("create-user", "member", "Create an ordinary member account")

    p = sub.add_parser("list-users", help="List accounts")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("set-password", help="Change a user's password")
    p.add_argument("username")
    p.add_argument("--password", help="Password (prompted if omitted)")
    p.set_defaults(func=cmd_set_password)

    p = sub.add_parser("delete-user", help="Delete an account")
    p.add_argument("username")
    p.set_defaults(func=cmd_delete_user)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except KeyboardInterrupt:
        print("\nAborted.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
