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

import threading
import time
from collections import defaultdict, deque
from typing import Iterable

_WINDOW_SECONDS = 15 * 60
_MAX_FAILURES = 5

_lock = threading.Lock()
_failures: dict[str, deque[float]] = defaultdict(deque)


def client_key(request) -> str:
    """Best-effort client identity for the limiter (never trusted for auth)."""
    client = getattr(request, "client", None)
    return getattr(client, "host", None) or "unknown"


def _prune(bucket: deque[float], now: float) -> None:
    while bucket and now - bucket[0] > _WINDOW_SECONDS:
        bucket.popleft()


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
        for key in keys:
            bucket = _failures[key]
            _prune(bucket, now)
            bucket.append(now)


def reset(keys: Iterable[str]) -> None:
    with _lock:
        for key in keys:
            _failures.pop(key, None)
