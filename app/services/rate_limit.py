"""A tiny in-process rate limiter for sign-in attempts.

A single process keeps a sliding window of failures per key (client IP and
username). It is deliberately small: a reverse proxy can add stricter limits,
and the goal here is to stop a loop of password guesses from tying up the
(slow, memory-hard) password hash on a home server.

The state is in memory, so it resets on restart and is per worker. That is an
acceptable trade-off for a single-user library; it still defeats the common
case of one client hammering ``/login`` or ``/api/auth/login``.
"""

from __future__ import annotations

import hashlib
import threading
import time
from collections import deque
from typing import Iterable

_WINDOW_SECONDS = 15 * 60
_MAX_FAILURES = 5
#: Login attempts share one attacker-independent budget: when a flood of
#: distinct usernames would saturate the per-key map, this bucket still
#: throttles the public endpoint itself.
_MAX_GLOBAL_FAILURES = 40
#: Keys mix in attacker-supplied usernames, so the map must stay bounded:
#: buckets whose failures all left the window are dropped, and the map
#: refuses to grow past this many live keys.
_MAX_KEYS = 10_000

_lock = threading.Lock()
_failures: dict[str, deque[float]] = {}

GLOBAL_LOGIN_KEY = "global:login"


def client_key(request) -> str:
    """Best-effort client identity for the limiter (never trusted for auth)."""
    forwarded = request.headers.get("x-forwarded-for", "")
    if forwarded:
        return forwarded.split(",")[0].strip() or "unknown"
    client = getattr(request, "client", None)
    return getattr(client, "host", None) or "unknown"


def _prune(bucket: deque[float], now: float) -> None:
    while bucket and now - bucket[0] > _WINDOW_SECONDS:
        bucket.popleft()


def _evict_expired(now: float) -> None:
    """Forget whole buckets whose failures have all left the window."""
    for key in [
        key
        for key, bucket in _failures.items()
        if not bucket or now - bucket[-1] > _WINDOW_SECONDS
    ]:
        del _failures[key]


def retry_after(keys: Iterable[str], *, limit: int = _MAX_FAILURES) -> int:
    """Seconds until the busiest key may try again (0 when not limited)."""
    now = time.monotonic()
    wait = 0.0
    with _lock:
        for key in keys:
            bucket = _failures.get(key)
            if not bucket:
                continue
            _prune(bucket, now)
            if len(bucket) >= limit:
                wait = max(wait, _WINDOW_SECONDS - (now - bucket[0]))
    return int(wait + 0.999) if wait > 0 else 0


def record_failure(keys: Iterable[str]) -> None:
    now = time.monotonic()
    with _lock:
        if len(_failures) >= _MAX_KEYS:
            # Buckets are keyed by attacker-supplied usernames: drop the ones
            # that can no longer influence the answer before growing the map.
            _evict_expired(now)
        for key in keys:
            bucket = _failures.get(key)
            if bucket is None:
                if len(_failures) >= _MAX_KEYS:
                    continue  # saturated map: the limiter stays best-effort
                bucket = deque()
                _failures[key] = bucket
            _prune(bucket, now)
            bucket.append(now)


def reset(keys: Iterable[str]) -> None:
    with _lock:
        for key in keys:
            _failures.pop(key, None)


def user_login_key(username: str) -> str:
    """Bucket for username-specific throttling.

    The name is attacker input: hash it, so a flood of distinct usernames
    cannot inflate the map with arbitrarily long keys.
    """
    digest = hashlib.sha256(username.casefold().encode("utf-8", "ignore")).hexdigest()
    return f"user:{digest}"


def login_keys(request, username: str) -> list[str]:
    return [f"ip:{client_key(request)}", user_login_key(username), GLOBAL_LOGIN_KEY]


def login_retry_after(request, username: str) -> int:
    """Seconds a login attempt must wait (per-IP/user and global window)."""
    per_key = retry_after(login_keys(request, username)[:-1])
    shared = retry_after([GLOBAL_LOGIN_KEY], limit=_MAX_GLOBAL_FAILURES)
    return max(per_key, shared)


def login_failure(request, username: str) -> None:
    """Record a failed attempt — including on the global bucket."""
    record_failure(login_keys(request, username))


def login_success(request, username: str) -> None:
    reset(login_keys(request, username))
