"""Accounts, passwords and tokens.

Everything to do with *who* may use the app lives here: creating users, checking
passwords and issuing/validating the opaque tokens used by the web session
cookie and by the desktop/mobile API clients.

Passwords are hashed with ``hashlib.scrypt`` (a memory-hard KDF shipped with
Python), so no third-party crypto dependency is needed. Tokens are random
128-bit-ish strings; only their SHA-256 hash is stored.
"""

from __future__ import annotations

import hashlib
import hmac
import re
import secrets
from datetime import datetime, timedelta, timezone

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from ..config import settings
from ..i18n import _
from ..models import Token, User
from ..models.token import KIND_API, KIND_WEB  # noqa: F401  (re-exported)
from ..models.user import ROLE_ADMIN, ROLE_MEMBER, ROLES  # noqa: F401

# --------------------------------------------------------------------------- #
# Password hashing (stdlib scrypt)
# --------------------------------------------------------------------------- #
_SCRYPT_N = 2 ** 14
_SCRYPT_R = 8
_SCRYPT_P = 1
_SCRYPT_DKLEN = 32

MIN_PASSWORD_LENGTH = 8

#: Prefix for every raw token, so a leaked string is recognisable to scanners
#: (GitHub and friends look for ``bj_``-style patterns).
TOKEN_PREFIX = "bj_"

_USERNAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
_MIN_USERNAME_LENGTH = 3
_MAX_USERNAME_LENGTH = 80


def hash_password(password: str) -> str:
    """Return a self-describing ``scrypt$…`` hash string for ``password``."""
    salt = secrets.token_bytes(16)
    derived = hashlib.scrypt(
        password.encode("utf-8"),
        salt=salt,
        n=_SCRYPT_N,
        r=_SCRYPT_R,
        p=_SCRYPT_P,
        dklen=_SCRYPT_DKLEN,
    )
    return f"scrypt${_SCRYPT_N}${_SCRYPT_R}${_SCRYPT_P}${salt.hex()}${derived.hex()}"


def verify_password(password: str, stored: str | None) -> bool:
    """Check ``password`` against a hash produced by :func:`hash_password`."""
    if not stored:
        return False
    try:
        scheme, n, r, p, salt_hex, hash_hex = stored.split("$")
        if scheme != "scrypt":
            return False
        derived = hashlib.scrypt(
            password.encode("utf-8"),
            salt=bytes.fromhex(salt_hex),
            n=int(n),
            r=int(r),
            p=int(p),
            dklen=len(bytes.fromhex(hash_hex)) or _SCRYPT_DKLEN,
        )
    except (ValueError, TypeError):
        return False
    return hmac.compare_digest(derived, bytes.fromhex(hash_hex))


# A throwaway hash used to keep the timing of a failed login similar to a
# successful one when the username does not exist.
_DUMMY_HASH = hash_password("not-a-real-password")


def password_problem(password: str | None) -> str | None:
    """Return a human-readable problem with ``password``, or ``None`` if fine."""
    if not password:
        return _("A password is required.")
    if len(password) < MIN_PASSWORD_LENGTH:
        return _("The password must be at least %(n)s characters long.") % {
            "n": MIN_PASSWORD_LENGTH
        }
    return None


# --------------------------------------------------------------------------- #
# Usernames
# --------------------------------------------------------------------------- #
def normalize_username(value: str | None) -> str:
    return (value or "").strip()


def username_problem(username: str | None) -> str | None:
    username = normalize_username(username)
    if not username:
        return _("A username is required.")
    if len(username) < _MIN_USERNAME_LENGTH or len(username) > _MAX_USERNAME_LENGTH:
        return _("The username must be between %(lo)s and %(hi)s characters.") % {
            "lo": _MIN_USERNAME_LENGTH,
            "hi": _MAX_USERNAME_LENGTH,
        }
    if not _USERNAME_RE.match(username):
        return _(
            "The username may only contain letters, digits, dots, dashes and underscores."
        )
    return None


# --------------------------------------------------------------------------- #
# Time helpers (SQLite hands datetimes back naive)
# --------------------------------------------------------------------------- #
def _now() -> datetime:
    return datetime.now(timezone.utc)


def _aware(value: datetime | None) -> datetime | None:
    if value is None:
        return None
    return value if value.tzinfo is not None else value.replace(tzinfo=timezone.utc)


def _is_expired(expires_at: datetime | None) -> bool:
    when = _aware(expires_at)
    return when is not None and when <= _now()


# --------------------------------------------------------------------------- #
# Users
# --------------------------------------------------------------------------- #
def get_user(db: Session, user_id: int) -> User | None:
    return db.get(User, user_id)


def get_user_by_username(db: Session, username: str) -> User | None:
    name = normalize_username(username)
    if not name:
        return None
    return db.scalar(select(User).where(func.lower(User.username) == name.lower()))


def list_users(db: Session) -> list[User]:
    return list(db.scalars(select(User).order_by(func.lower(User.username))))


def count_users(db: Session) -> int:
    return db.scalar(select(func.count(User.id))) or 0


def count_active_admins(db: Session, *, exclude_id: int | None = None) -> int:
    stmt = select(func.count(User.id)).where(
        User.role == ROLE_ADMIN, User.is_active.is_(True)
    )
    if exclude_id is not None:
        stmt = stmt.where(User.id != exclude_id)
    return db.scalar(stmt) or 0


def create_user(
    db: Session,
    *,
    username: str,
    password: str,
    role: str = ROLE_MEMBER,
    display_name: str | None = None,
) -> User:
    """Create a user, raising :class:`ValueError` on bad/duplicate input."""
    username = normalize_username(username)
    problem = username_problem(username) or password_problem(password)
    if problem:
        raise ValueError(problem)
    if role not in ROLES:
        raise ValueError(_("Unknown role “%s”.") % role)
    if get_user_by_username(db, username) is not None:
        raise ValueError(_("That username is already taken."))

    user = User(
        username=username,
        display_name=(display_name or "").strip() or None,
        password_hash=hash_password(password),
        role=role,
        is_active=True,
    )
    db.add(user)
    db.commit()
    db.refresh(user)
    return user


def update_user(
    db: Session,
    user: User,
    *,
    display_name=...,
    role=...,
    is_active=...,
    password: str | None = None,
) -> User:
    """Update a user. Pass ``...`` to leave a field untouched."""
    if display_name is not ...:
        user.display_name = (display_name or "").strip() or None

    if role is not ... and role != user.role:
        if role not in ROLES:
            raise ValueError(_("Unknown role “%s”.") % role)
        if user.role == ROLE_ADMIN and role != ROLE_ADMIN and count_active_admins(
            db, exclude_id=user.id
        ) == 0:
            raise ValueError(_("There must be at least one active administrator."))
        user.role = role

    if is_active is not ... and bool(is_active) != user.is_active:
        if not is_active and user.is_admin and count_active_admins(
            db, exclude_id=user.id
        ) == 0:
            raise ValueError(_("There must be at least one active administrator."))
        user.is_active = bool(is_active)
        if not user.is_active:
            # Deactivating a user logs their devices out immediately.
            revoke_user_tokens(db, user)

    if password:
        problem = password_problem(password)
        if problem:
            raise ValueError(problem)
        user.password_hash = hash_password(password)
        revoke_user_tokens(db, user)

    db.commit()
    db.refresh(user)
    return user


def set_password(db: Session, user: User, password: str) -> User:
    return update_user(db, user, password=password)


def authenticate(db: Session, username: str, password: str) -> User | None:
    """Return the matching active user, or ``None``."""
    user = get_user_by_username(db, username)
    if user is None:
        # Waste the same effort so a missing username is not obviously faster.
        verify_password(password or "", _DUMMY_HASH)
        return None
    if not verify_password(password or "", user.password_hash):
        return None
    if not user.is_active:
        return None
    user.last_login_at = _now()
    db.commit()
    return user


def delete_user(db: Session, user: User) -> None:
    if user.is_admin and count_active_admins(db, exclude_id=user.id) == 0:
        raise ValueError(_("There must be at least one active administrator."))
    db.delete(user)
    db.commit()


# --------------------------------------------------------------------------- #
# Tokens
# --------------------------------------------------------------------------- #
def hash_token(raw: str) -> str:
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def create_token(
    db: Session,
    user: User,
    *,
    kind: str = KIND_WEB,
    label: str | None = None,
    ttl_days: int | None = None,
) -> tuple[str, Token]:
    """Issue a new token; returns ``(raw_token, Token)``.

    Only the hash of ``raw_token`` is stored — show it to the client once.
    """
    raw = TOKEN_PREFIX + secrets.token_urlsafe(32)
    ttl = settings.session_ttl_days if ttl_days is None else ttl_days
    token = Token(
        user_id=user.id,
        token_hash=hash_token(raw),
        kind=kind,
        label=(label or "").strip()[:120] or None,
        csrf_token=secrets.token_urlsafe(24) if kind == KIND_WEB else None,
        expires_at=_now() + timedelta(days=ttl) if ttl else None,
    )
    db.add(token)
    db.commit()
    db.refresh(token)
    return raw, token


def get_token(db: Session, raw: str | None, *, kind: str | None = None) -> Token | None:
    """Look up a live token by its raw value, or ``None``."""
    if not raw:
        return None
    token = db.scalar(
        select(Token).where(Token.token_hash == hash_token(raw))
    )
    if token is None or token.revoked_at is not None:
        return None
    if kind is not None and token.kind != kind:
        return None
    if _is_expired(token.expires_at):
        return None
    if token.user is None or not token.user.is_active:
        return None
    return token


def touch_token(db: Session, token: Token) -> None:
    """Record use and slide the expiry forward (at most once an hour)."""
    now = _now()
    last = _aware(token.last_used_at)
    if last is not None and (now - last) < timedelta(hours=1):
        return
    token.last_used_at = now
    if token.expires_at is not None and settings.session_ttl_days:
        token.expires_at = now + timedelta(days=settings.session_ttl_days)
    db.commit()


def revoke_token(db: Session, token: Token) -> None:
    token.revoked_at = _now()
    db.commit()


def revoke_user_tokens(db: Session, user: User, *, kind: str | None = None) -> None:
    now = _now()
    for token in list(user.tokens):
        if token.revoked_at is not None:
            continue
        if kind is not None and token.kind != kind:
            continue
        token.revoked_at = now
    db.commit()
